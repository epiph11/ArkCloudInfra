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
# The two steps the runbook performs are deliberately in this order:
#   1. Change the password on the server.
#   2. Write the new connection string to Key Vault (connection_string_secret_name).
# Doing (2) before (1) would be worse — Key Vault would advertise a password the server hasn't
# accepted yet.
#
# A third step — restarting the API App Service — existed here before the Sprint 6 STRIDE
# cutover (task #69), back when ArkCloud.API read this exact secret directly and needed a kick
# to pick up the new value. Removed once the app moved to arkcloud_app instead: nothing consumes
# this secret live anymore, so there is nothing left to restart on its behalf. See
# connection_string_secret_name's description in variables.tf for what this secret is for now.
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

# Audit IAM (Sprint 6) : les deux "Contributor" d'origine ci-dessous ont été remplacés par des
# rôles personnalisés. "Contributor" scopé à une seule ressource limite bien le *rayon d'action*
# (ce serveur/cet App Service précis, rien d'autre), mais pas les *actions permises dessus* — il
# autorise resize, suppression, changement de réseau, etc., alors que le runbook ci-dessus ne
# fait jamais qu'un PATCH sur le mot de passe et un POST /restart. Vérifié contre la liste
# officielle des opérations RBAC (learn.microsoft.com/.../permissions/databases et
# .../web-and-mobile) avant d'écrire les actions ci-dessous — pas supposées.
#
# Le cas Postgres reste imparfait par construction de l'API Azure, pas par manque de rigueur ici :
# le changement de mot de passe passe par un PATCH générique sur la ressource entière
# (properties.administratorLoginPassword), et Azure RBAC n'expose pas d'action distincte pour
# "changer seulement le mot de passe" — le contrôle d'accès s'arrête au niveau de l'opération
# HTTP (write), pas du champ modifié dans le corps de la requête. `write` reste donc nécessaire,
# mais ce rôle personnalisé retire déjà ce que "Contributor" ajoutait sans rapport avec ce besoin :
# delete, et surtout le fait que "Contributor" est un rôle générique qui s'applique à TOUT type de
# ressource Azure — un rôle personnalisé limité aux deux actions ci-dessous ne peut, par
# construction, jamais rien faire d'autre que lire/écrire un serveur PostgreSQL Flexible.
resource "azurerm_role_definition" "postgres_password_rotate" {
  name        = "arkcloud-${var.name_prefix}-postgres-password-rotate"
  scope       = var.resource_group_id
  description = "Lecture + écriture d'un serveur PostgreSQL Flexible Server — suffisant pour y changer le mot de passe admin via PATCH, rien de plus (pas de delete, pas d'accès à un autre type de ressource)."

  permissions {
    actions = [
      "Microsoft.DBforPostgreSQL/flexibleServers/read",
      "Microsoft.DBforPostgreSQL/flexibleServers/write",
    ]
    not_actions = []
  }

  assignable_scopes = [var.resource_group_id]
}

resource "azurerm_role_assignment" "rotation_postgres" {
  scope              = var.postgres_server_id
  role_definition_id = azurerm_role_definition.postgres_password_rotate.role_definition_resource_id
  principal_id       = azurerm_automation_account.rotation.identity[0].principal_id
}

# "Secrets Officer" (write), not "Secrets User" (read) — the API's identity only reads; this
# runbook has to overwrite the connection string after each rotation. Déjà le rôle intégré le
# plus étroit possible pour ce besoin (Azure RBAC pour Key Vault ne descend pas au niveau d'un
# secret individuel) — pas de rôle personnalisé nécessaire ici, contrairement aux deux autres.
resource "azurerm_role_assignment" "rotation_key_vault" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_automation_account.rotation.identity[0].principal_id
}

# App Service restart role/assignment REMOVED at the Sprint 6 STRIDE cutover (task #69): the
# runbook no longer restarts app-arkcloud-api-dev after rotating arkcloudadmin's password,
# because the running app doesn't read this secret at all anymore (it connects as arkcloud_app —
# see connection_string_secret_name's description in variables.tf). Keeping this role assignment
# would have meant an identity retaining a real permission (restart a production App Service)
# for an action nothing triggers anymore — exactly the kind of unused-but-still-granted access
# this whole remediation exists to close, so it's deleted rather than left dormant.

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

    Write-Output "Password update accepted (HTTP $($response.StatusCode)). Confirming it has actually been applied."

    # The Azure REST call is asynchronous: a 202 means "accepted", not "done". Polling for
    # state=Ready alone is NOT sufficient, because immediately after the PATCH the server is
    # still Ready (it hasn't started applying anything yet) — the loop would exit on the first
    # check having verified nothing. The AWS side hit exactly this class of bug and failed with
    # "password authentication failed" on the very next step.
    #
    # So instead of trusting the server's own state field, verify the outcome directly: poll the
    # long-running-operation URL Azure returns in Azure-AsyncOperation (or Location), which
    # reports Succeeded/Failed for THIS specific change.
    $asyncUri = $response.Headers | Where-Object { $_.Key -eq "Azure-AsyncOperation" } | Select-Object -First 1 -ExpandProperty Value
    if (-not $asyncUri) {
      $asyncUri = $response.Headers | Where-Object { $_.Key -eq "Location" } | Select-Object -First 1 -ExpandProperty Value
    }

    $deadline = (Get-Date).AddMinutes(15)

    if ($asyncUri) {
      do {
        Start-Sleep -Seconds 15
        $op = Invoke-AzRestMethod -Method GET -Uri $asyncUri
        $opStatus = ($op.Content | ConvertFrom-Json).status
        Write-Output "  operation status: $opStatus"

        if ($opStatus -eq "Failed" -or $opStatus -eq "Canceled") {
          throw "Password update operation reported '$opStatus'. Nothing has been written to Key Vault - the old password is still the live one. Details: $($op.Content)"
        }
        if ((Get-Date) -gt $deadline) {
          throw "Password update did not complete within 15 minutes (last status: $opStatus). Not writing to Key Vault - check the server state before re-running."
        }
      } while ($opStatus -ne "Succeeded")
    }
    else {
      # No async header returned — fall back to watching the server leave and re-enter Ready,
      # with a fixed initial delay so a still-unstarted update can't be mistaken for a finished
      # one. Less precise than the operation URL, hence only a fallback.
      Write-Output "  no async operation header returned; falling back to polling server state."
      Start-Sleep -Seconds 30
      do {
        $check = Invoke-AzRestMethod -Method GET -Uri $serverUri
        $state = ($check.Content | ConvertFrom-Json).properties.state
        Write-Output "  server state: $state"
        if ((Get-Date) -gt $deadline) {
          throw "Server did not return to Ready within 15 minutes (last state: $state). Not writing to Key Vault - check the server before re-running."
        }
        if ($state -ne "Ready") { Start-Sleep -Seconds 15 }
      } while ($state -ne "Ready")
    }

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

    # Splatting rather than backtick line continuations: a backtick inside this Terraform
    # heredoc is passed through literally, and an earlier version of this runbook failed at
    # runtime with "A positional parameter cannot be found that accepts argument '`'" because
    # of exactly that. Splatting keeps the call readable without any escaping to get wrong.
    $kvUri = "https://${var.key_vault_name}.vault.azure.net/secrets/${var.connection_string_secret_name}?api-version=7.4"
    $kvParams = @{
      Method      = "PUT"
      Uri         = $kvUri
      Headers     = @{ Authorization = "Bearer $kvToken" }
      ContentType = "application/json"
      Body        = (@{ value = $connectionString } | ConvertTo-Json)
    }
    Invoke-RestMethod @kvParams | Out-Null

    Write-Output "Key Vault secret '${var.connection_string_secret_name}' updated."
    Write-Output "Rotation complete. This is the admin credential only -- ArkCloud.API connects as arkcloud_app and never reads this secret, so no App Service restart is needed here (see this runbook's header comment)."
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
