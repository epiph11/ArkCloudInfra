<#
.SYNOPSIS
    SUPERSEDED FOR AWS -- do not use -Cloud aws or -Cloud both anymore. Kept only for the Azure
    path, which is still blocked (see below).

.DESCRIPTION
    Originally step 1 of the STRIDE "Elevation of privilege" (flow 3) remediation. Turned out to
    be unusable as written: both Postgres servers are private (VNet/VPC-only, no public access),
    so this script can never reach them from outside the cloud -- confirmed by a real
    "Name or service not known" DNS failure when first run, then by the Terraform network config
    itself (publicNetworkAccess: Disabled, delegatedSubnet set, on both clouds).

    AWS: fixed by folding this script's job into modules/aws/secret-rotation's rotation Lambda
    itself (target_role = "app", see environments/dev/main.tf's aws_secret_rotation_app_role and
    lambda/rotate.py's TARGET_ROLE branching). That Lambda already runs inside the VPC for the
    existing master-password rotation, so it can reach RDS with no new network path to build --
    its first invocation (triggered automatically by `terraform apply`) both creates the role
    AND sets its first real password. Nothing left to run manually for AWS.

    Azure: still blocked. The Automation Runbook has no VNet integration today (it only calls the
    management-plane API for the master account, which needs no network access) -- extending it
    to run real SQL needs a Hybrid Runbook Worker or equivalent inside vnet-arkcloud-dev first
    (tracked separately). Until that exists, there is no working path to bootstrap arkcloud_app
    on Azure -- running this script with -Cloud azure will hit the same DNS failure AWS did.

.PARAMETER Cloud
    Which server(s) to bootstrap: azure, aws, or both (default). Only "azure" still applies, and
    only once the Hybrid Runbook Worker work above lands -- passing "aws" or "both" today will
    just fail on the private RDS endpoint, the same failure this whole rework started from.

.EXAMPLE
    ./scripts/bootstrap-app-role.ps1 -Cloud azure
    (Azure only -- will still fail today, see .DESCRIPTION, kept for when the network path exists)
#>
[CmdletBinding()]
param(
    [ValidateSet("azure", "aws", "both")]
    [string]$Cloud = "both",

    [string]$AzureHost = "psql-arkcloud-dev.postgres.database.azure.com",
    [string]$AwsHost = "psql-arkcloud-dev.cdkcy22mykjm.eu-west-1.rds.amazonaws.com",
    [int]$Port = 5432,
    [string]$Database = "arkcloud",
    [string]$AdminUser = "arkcloudadmin",

    [string]$KeyVaultName = "kv-arkcloud-dev",
    [string]$AwsSecretName = "arkcloud/arkcloud-dev/arkcloud-app-role",

    [string]$SqlFile = "$PSScriptRoot/sql/bootstrap-arkcloud-app-role.sql"
)

$ErrorActionPreference = "Stop"

function Assert-Tool($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name is required on PATH - install/login before running this script."
    }
}
Assert-Tool psql

if (-not (Test-Path $SqlFile)) {
    throw "SQL file not found at $SqlFile"
}

# Generated once, reused for both clouds -- this project's two Postgres instances are
# independent databases, but there's no reason arkcloud_app needs a different password on each,
# and a single value is simpler to stash/track.
Write-Host "==> Generating arkcloud_app password..."
$bytes = New-Object byte[] 32
# RandomNumberGenerator.Fill() is a static method that only exists on modern .NET (Core/5+).
# Windows PowerShell 5.1 runs on .NET Framework 4.x, which only has the instance-based
# Create()/GetBytes() API -- using that instead makes this work on both PS 5.1 and PS 7.
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $rng.GetBytes($bytes)
}
finally {
    $rng.Dispose()
}
# Base64 can contain '+', '/', '=' -- all awkward in a connection string or a shell-quoted psql
# variable. Same "exclude troublesome punctuation" reasoning as rotate.py / the Azure runbook.
$appPassword = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''

function Invoke-Bootstrap($pgHost, $adminPassword) {
    Write-Host "==> Running bootstrap SQL against $pgHost..."
    $env:PGPASSWORD = $adminPassword
    try {
        psql "host=$pgHost port=$Port dbname=$Database user=$AdminUser sslmode=require" `
            -v "app_password=$appPassword" `
            -v "ON_ERROR_STOP=1" `
            -f $SqlFile
        if ($LASTEXITCODE -ne 0) { throw "psql against $pgHost failed (exit $LASTEXITCODE)." }
    }
    finally {
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
}

if ($Cloud -in "azure", "both") {
    Assert-Tool az
    $azureAdminPw = Read-Host -AsSecureString -Prompt "Azure arkcloudadmin password (input hidden)"
    $plainAzureAdminPw = [System.Net.NetworkCredential]::new("", $azureAdminPw).Password
    Invoke-Bootstrap -pgHost $AzureHost -adminPassword $plainAzureAdminPw
    Remove-Variable plainAzureAdminPw

    Write-Host "==> Stashing arkcloud_app password in Key Vault ($KeyVaultName)..."
    az keyvault secret set --vault-name $KeyVaultName --name "ArkCloudAppRole--Password" --value $appPassword | Out-Null
}

if ($Cloud -in "aws", "both") {
    Assert-Tool aws
    $awsAdminPw = Read-Host -AsSecureString -Prompt "AWS arkcloudadmin password (input hidden)"
    $plainAwsAdminPw = [System.Net.NetworkCredential]::new("", $awsAdminPw).Password
    Invoke-Bootstrap -pgHost $AwsHost -adminPassword $plainAwsAdminPw
    Remove-Variable plainAwsAdminPw

    Write-Host "==> Stashing arkcloud_app password in Secrets Manager ($AwsSecretName)..."
    $exists = aws secretsmanager describe-secret --secret-id $AwsSecretName 2>$null
    if ($LASTEXITCODE -eq 0) {
        aws secretsmanager put-secret-value --secret-id $AwsSecretName --secret-string $appPassword | Out-Null
    }
    else {
        aws secretsmanager create-secret --name $AwsSecretName --secret-string $appPassword | Out-Null
    }
}

Remove-Variable appPassword -ErrorAction SilentlyContinue
Write-Host "==> Done. arkcloud_app role created/updated, password stashed. App Services still use arkcloudadmin -- not switched over yet (see roadmap step 2/3/4)."
