<#
.SYNOPSIS
    Automates steps 2-5 of the GHCR_PAT rotation procedure documented in README.md section 10.

.DESCRIPTION
    Step 1 (generating the new classic PAT with the `read:packages` scope on
    github.com/settings/tokens) stays manual on purpose - GitHub exposes no API to create a
    PAT on your behalf, and this script never should either. Run this AFTER you already have
    the new token value and picked its expiry date in GitHub's UI.

    From there, this script chains what README section 10 always described as steps 2-5, run
    by hand until now:
      2. gh secret set GHCR_PAT
      3. Trigger a real `terraform apply` (needs the terraform-ci.yml `apply` job to accept
         workflow_dispatch - see the Sprint 6 STRIDE remediation comment on that job; without
         that change this script's step 3/4 would silently do nothing useful).
      4. az webapp restart on both App Services, so they re-pull the image with fresh registry
         credentials.
      5. Update .github/secrets-inventory.json's GHCR_PAT expiry and push it.

    The token value is never written to disk, never echoed, and never logged - it lives only in
    a SecureString in memory for the lifetime of this script.

.PARAMETER ExpiresOn
    The expiry date you chose when creating the new token on github.com/settings/tokens,
    format yyyy-MM-dd. Required - this script has no way to know it otherwise.

.PARAMETER NewToken
    The new PAT value, as a SecureString. If omitted, you'll be prompted (input hidden).

.EXAMPLE
    ./scripts/rotate-ghcr-pat.ps1 -ExpiresOn 2026-12-04
    (prompts for the token value, hidden)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$ExpiresOn,

    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$NewToken,

    [string]$Repo = "epiph11/ArkCloudInfra",
    [string]$Workflow = "terraform-ci.yml",
    [string]$ResourceGroup = "rg-arkcloud-dev",
    [string]$ApiAppName = "app-arkcloud-api-dev",
    [string]$WebAppName = "app-arkcloud-web-dev",
    [string]$InventoryPath = $null
)

$ErrorActionPreference = "Stop"

# $PSScriptRoot evaluated inside the param() block's own default value is unreliable under
# `powershell -File <relative path>` invocation (confirmed twice in practice, 2026-08-27:
# resolves to an empty string, turning "$PSScriptRoot/../.github/..." into "/../.github/...",
# which Get-Content then treats as an absolute path off the current drive root). Computing it
# here instead, from $MyInvocation in the script's own body (not the param block), is the
# reliable form regardless of how the script is invoked.
if (-not $InventoryPath) {
    $InventoryPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "../.github/secrets-inventory.json"
}

function Assert-Tool($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name is required on PATH (gh, az) - install/login before running this script."
    }
}
Assert-Tool gh
Assert-Tool az

if (-not $NewToken) {
    $NewToken = Read-Host -AsSecureString -Prompt "New GHCR_PAT value (input hidden)"
}
$plainToken = [System.Net.NetworkCredential]::new("", $NewToken).Password
if ([string]::IsNullOrWhiteSpace($plainToken)) {
    throw "Empty token - aborting before touching anything."
}

try {
    # --- Step 2: gh secret set -------------------------------------------------------------
    # --body (not a piped/stdin value) avoids the trailing-newline corruption class of bug
    # already hit once in this project (README section 5) when a secret was set via an
    # interactive paste instead.
    Write-Host "==> Setting GHCR_PAT secret on $Repo..."
    $plainToken | gh secret set GHCR_PAT --repo $Repo --body -
    if ($LASTEXITCODE -ne 0) { throw "gh secret set failed (exit $LASTEXITCODE)." }

    # --- Step 3: trigger a real apply -------------------------------------------------------
    Write-Host "==> Triggering $Workflow on $Repo (workflow_dispatch)..."
    $before = Get-Date
    gh workflow run $Workflow --repo $Repo --ref main
    if ($LASTEXITCODE -ne 0) { throw "gh workflow run failed (exit $LASTEXITCODE)." }

    Write-Host "==> Waiting for the new run to register..."
    $runId = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $runs = gh run list --repo $Repo --workflow $Workflow --limit 5 --json databaseId,createdAt,event `
            | ConvertFrom-Json
        $match = $runs | Where-Object {
            $_.event -eq "workflow_dispatch" -and [DateTime]$_.createdAt -ge $before.ToUniversalTime().AddSeconds(-5)
        } | Select-Object -First 1
        if ($match) { $runId = $match.databaseId; break }
    }
    if (-not $runId) { throw "Could not find the triggered run after 60s - check the Actions tab manually before re-running this script." }

    Write-Host "==> Watching run $runId (this blocks until the apply job finishes)..."
    gh run watch $runId --repo $Repo --exit-status
    if ($LASTEXITCODE -ne 0) {
        throw "Run $runId did not succeed (exit $LASTEXITCODE). GHCR_PAT secret is already updated, but the apply did NOT complete - do not restart the App Services yet. Check the run before re-triggering."
    }

    # --- Step 4: restart both App Services ---------------------------------------------------
    Write-Host "==> Restarting $ApiAppName..."
    az webapp restart --resource-group $ResourceGroup --name $ApiAppName | Out-Null

    Write-Host "==> Restarting $WebAppName..."
    az webapp restart --resource-group $ResourceGroup --name $WebAppName | Out-Null

    # --- Step 5: update the inventory + push --------------------------------------------------
    Write-Host "==> Updating $InventoryPath (expires_on -> $ExpiresOn)..."
    $raw = Get-Content $InventoryPath -Raw
    $updated = $raw -replace '("name":\s*"GHCR_PAT"[\s\S]*?"expires_on":\s*)"[^"]+"', "`$1`"$ExpiresOn`""
    if ($updated -eq $raw) { throw "Regex replace matched nothing - inventory file format may have changed, update it by hand instead." }
    Set-Content -Path $InventoryPath -Value $updated -NoNewline

    Push-Location "$PSScriptRoot/.."
    try {
        git add .github/secrets-inventory.json
        git commit -m "chore(secrets): rotate GHCR_PAT, new expiry $ExpiresOn"
        git push origin main
    }
    finally {
        Pop-Location
    }

    Write-Host "==> Done. GHCR_PAT rotated, apply confirmed green, both App Services restarted, inventory updated and pushed."
}
finally {
    # Best-effort scrub - PowerShell strings are immutable so this isn't a hard guarantee, but
    # there's no reason to hold a reference to the plaintext token any longer than needed.
    Remove-Variable plainToken -ErrorAction SilentlyContinue
}
