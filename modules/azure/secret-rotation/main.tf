# ---------------------------------------------------------------------------
# Automatic PostgreSQL admin password rotation — Azure side (Sprint 6).
#
# Closes the gap README.md §10 documented as "procedure only, no automation": the password
# actually rotates on a schedule now, with no human in the loop and no credential stored
# anywhere in this repo or in Terraform state.
#
# Same Automation Account pattern as modules/azure/cost-guard (system-assigned identity,
# least-privilege role assignments, PowerShell runbook), with one meaningful difference: this
# one is driven by an azurerm_automation_schedule on a fixed interval, not by an Action Group
# reacting to an event.
#
# The three steps the runbook performs are deliberately in this order:
#   1. Change the password on the server.
#   2. Write the new connection string to Key Vault.
#   3. Restart the API App Service.
# There is an unavoidable window between (1) and (3) where the running app still holds the old
# password and its DB calls fail. That's why rotation_start_time should be an off-peak hour.
# Doing (2) before (1) would be worse — Key Vault would advertise a password the server hasn't
# accepted yet.
#
# NOT handled here, on purpose: the AWS-side Postgres password (see modules/aws/secret-rotation,
# which uses Secrets Manager's native rotation instead — different mechanism, same 90-day
# policy), the JWT signing key (rotating it invalidates every active token, and ArkCloud.API has
# no multi-key/kid support to roll over gracefully — deliberately left manual, README §10), and
# GHCR_PAT (a GitHub PAT, no Azure API can rotate it; a real automation would need a GitHub App).
# ---------------------------------------------------------------------------

resource "azurerm_automation_account" "rotation" {
  name                = "aa-${var.name_prefix}-secret-rotation"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# Three separate least-privilege assignments rather than one broad Contributor on the resource
# group — each scoped to exactly the one resource the runbook touches.
resource "azurerm_role_assignment" "rotation_postgres" {
  scope                = var.postgres_server_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.rotation.identity[0].principal_id
}

# "Secrets Officer" (write), not "Secrets User" (read) — the API's identity only reads; this
# runbook has to overwrite the connection string after each rotation.
resource "azurerm_role_assignment" "rotation_key_vault" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_automation_account.rotation.identity[0].principal_id
}

resource "azurerm_role_assignment" "rotation_app_service" {
  scope                = var.app_service_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.rotation.identity[0].principal_id
}

resource "azurerm_automation_runbook" "rotate_postgres_password" {
  name                    = "Rotate-ArkCloudPostgresPassword"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.rotation.name
  runbook_type            = "PowerShell"
  log_progress            = true
  log_verbose             = true

  # Everything below goes through the Azure REST API (Invoke-AzRestMethod for the ARM control
  # plane, Invoke-RestMethod + a scoped token for Key Vault's data plane) rather than the
  # service-specific Az.* cmdlets. That's not stylistic: the first real run of this runbook
  # failed with "Update-AzPostgreSqlFlexibleServer is not recognized" because Automation
  # Accounts ship a frozen module set — Az.PostgreSql 1.1.0 here, which predates the Flexible
  # Server cmdlets entirely. Chasing module upgrades inside the Automation Account would have
  # to be redone for every module and every version bump; Invoke-AzRestMethod lives in
  # Az.Accounts, which is guaranteed present (Connect-AzAccount already works), so this has no
  # version-dependent surface at all.
  #
  # No password value is ever logged or returned — Write-Output lines describe steps without
  # echoing the secret.
  content = <<-EOT
    param()

    $ErrorActionPreference = "Stop"

    Connect-AzAccount -Identity | Out-Null

    Write-Output "Starting rotation of the PostgreSQL admin password for '${var.postgres_server_name}'."

    # 32 chars from a deliberately punctuation-free alphabet: Npgsql connection strings are
    # semicolon/equals-delimited, and characters like ; = ' " would need quoting/escaping that
    # varies between the connection string, PowerShell, JSON, and the REST payload. 62^32 of
    # entropy is far beyond what's needed here, so nothing is lost by excluding them.
    $alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $newPassword = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })

    # --- Step 1: change the password on the server -------------------------------------------
    # First, so that if it fails nothing else has happened and the old password stays valid
    # everywhere. PATCH on a Flexible Server is asynchronous (202), hence the poll below.
    $serverUri = "https://management.azure.com${var.postgres_server_id}?api-version=2024-08-01"
    $body = @{ properties = @{ administratorLoginPassword = $newPassword } } | ConvertTo-Json -Depth 5

    $response = Invoke-AzRestMethod -Method PATCH -Uri $serverUri -Payload $body
    if ($response.StatusCode -ge 400) {
      throw "Password update failed with HTTP $($response.StatusCode): $($response.Content)"
    }

    Write-Output "Password update accepted (HTTP $($response.StatusCode)). Waiting for the server to report Ready."

    # Bounded poll — a stuck server should fail the job loudly rather than hang until Azure's
    # own 3-hour runbook limit kills it with no useful message.
    $deadline = (Get-Date).AddMinutes(15)
    do {
      Start-Sleep -Seconds 15
      $check = Invoke-AzRestMethod -Method GET -Uri $serverUri
      $state = ($check.Content | ConvertFrom-Json).properties.state
      Write-Output "  server state: $state"
      if ((Get-Date) -gt $deadline) {
        throw "Server did not return to Ready within 15 minutes (last state: $state). The password may or may not have been applied - check the server before re-running."
      }
    } while ($state -ne "Ready")

    # --- Step 2: publish the new connection string to Key Vault -------------------------------
    # Only now that the server has accepted the password, so Key Vault never advertises a
    # credential the database would reject.
    $connectionString = "Host=${var.postgres_server_fqdn};Port=5432;Database=${var.postgres_database_name};Username=${var.postgres_admin_username};Password=$newPassword;Ssl Mode=Require"

    # Key Vault is a data-plane API, so it needs a token for the vault audience specifically,
    # not the ARM one Invoke-AzRestMethod uses. Az.Accounts changed Get-AzAccessToken to return
    # a SecureString in newer versions — handle both rather than pin to whichever this
    # Automation Account happens to have.
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://vault.azure.net"
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
      $kvToken = [System.Net.NetworkCredential]::new("", $tokenResponse.Token).Password
    } else {
      $kvToken = $tokenResponse.Token
    }

    $kvUri = "https://${var.key_vault_name}.vault.azure.net/secrets/${var.connection_string_secret_name}?api-version=7.4"
    Invoke-RestMethod -Method PUT -Uri $kvUri ``
      -Headers @{ Authorization = "Bearer $kvToken" } ``
      -ContentType "application/json" ``
      -Body (@{ value = $connectionString } | ConvertTo-Json) | Out-Null

    Write-Output "Key Vault secret '${var.connection_string_secret_name}' updated."

    # --- Step 3: restart the API so it picks up the new value ---------------------------------
    # App Service caches Key Vault references; without this the app keeps using the now-invalid
    # old password until its own refresh interval elapses.
    $restartUri = "https://management.azure.com${var.app_service_id}/restart?api-version=2023-12-01"
    $restart = Invoke-AzRestMethod -Method POST -Uri $restartUri
    if ($restart.StatusCode -ge 400) {
      throw "App Service restart failed with HTTP $($restart.StatusCode): $($restart.Content)"
    }

    Write-Output "API restarted. Rotation complete."
    Write-Output "Remember to update .github/secrets-inventory.json's last_rotated date so secret-expiry-check.yml stops asking for a manual rotation."
  EOT

  tags = var.tags
}

resource "azurerm_automation_schedule" "rotation" {
  name                    = "sched-${var.name_prefix}-postgres-rotation"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.rotation.name
  frequency               = "Day"
  interval                = var.rotation_interval_days
  start_time              = var.rotation_start_time
  timezone                = "Etc/UTC"
  description             = "Rotates the PostgreSQL admin password every ${var.rotation_interval_days} days."

  # start_time is only meaningful at creation; once Azure has the schedule it tracks its own
  # next-run time. Without this, every apply after the start_time has passed would show a diff
  # (and fail validation, since Azure rejects a start_time in the past).
  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "rotation" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.rotation.name
  runbook_name            = azurerm_automation_runbook.rotate_postgres_password.name
  schedule_name           = azurerm_automation_schedule.rotation.name
}
