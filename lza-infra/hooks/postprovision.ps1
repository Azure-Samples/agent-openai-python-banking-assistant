# =============================================================================
# postprovision.ps1 — App deploy orchestrator (generic)
# Handles network-isolated deployment via jump box + azd deploy after
# 'azd provision'. Control-plane steps (Entra ID, Graph API, etc.) are
# defined as individual hook entries in azure.yaml and run before this script.
#
# All scripts are idempotent and safe to re-run.
#
# Usage:
#   postprovision.ps1 [<BaseUrl1> <BaseUrl2> ...] [-HealthSuffix <path>]
#   Base URLs for health probes are passed as positional arguments from
#   azure.yaml. The health suffix (default: /health) is appended to each.
#   When no URLs are provided, health probing is skipped.
#
# Network isolation handling:
#   When NETWORK_ISOLATION=True and we are NOT running from inside the VNet
#   (RUN_FROM_JUMPBOX != 'true'), app deploy steps are delegated to the
#   jump box VM via deploy-via-jumpbox.ps1.
# =============================================================================
param(
    # Base URLs for health probes (passed from azure.yaml run: args)
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $HealthProbeBaseUrls = @(),

    # Path suffix appended to each base URL for health probing
    [string] $HealthSuffix = '/health'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ─── Resolve solution name from azure.yaml ──────────────────────────────────
$azdYamlPath = Join-Path $ScriptDir '..\azure.yaml'
$solutionName = 'unknown-solution'
if (Test-Path $azdYamlPath) {
    $match = Select-String -Path $azdYamlPath -Pattern '^\s*name:\s*(.+)' | Select-Object -First 1
    if ($match) { $solutionName = $match.Matches[0].Groups[1].Value.Trim() }
}

# ─── Detect execution context ───────────────────────────────────────────────
$networkIsolation = $env:NETWORK_ISOLATION -eq 'True'
$runFromJumpbox   = $env:RUN_FROM_JUMPBOX -eq 'true'

Write-Host ""
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host " $solutionName — App Deploy" -ForegroundColor Cyan
if ($networkIsolation) {
    $modeLabel = if ($runFromJumpbox) { "VNet (local execution)" } else { "External (jump box delegation)" }
    Write-Host " Network isolation: ON — Mode: $modeLabel" -ForegroundColor Cyan
}
Write-Host "===========================================" -ForegroundColor Cyan

# ─── Resolve azd outputs ────────────────────────────────────────────────────
Write-Host "Resolving azd environment outputs..."
$resourceGroup           = $env:AZURE_RESOURCE_GROUP
$keyVaultName            = $env:KEY_VAULT_NAME

if (-not $resourceGroup -or -not $keyVaultName) {
    Write-Error "Required azd environment variables not set. Ensure 'azd provision' completed successfully."
    exit 1
}

Write-Host "  Resource Group:  $resourceGroup"
Write-Host "  Key Vault:       $keyVaultName"

# ─── Filter health probe base URLs (remove empty/whitespace entries) ────────
$HealthProbeBaseUrls = @($HealthProbeBaseUrls | Where-Object { $_ -and $_.Trim() })

# =============================================================================
# APP DEPLOY STEPS — require access to private endpoints
# =============================================================================

if ($networkIsolation -and -not $runFromJumpbox) {
    # ─── External mode: delegate app deploy to the jump box ──────────────────
    Write-Host ""
    Write-Host "─────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host " Network isolation detected — delegating app deploy"       -ForegroundColor Yellow
    Write-Host " to jump box via deploy-via-jumpbox.ps1"                   -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────────────────────" -ForegroundColor Yellow

    $jumpboxScript = Join-Path $ScriptDir 'scripts\deploy-via-jumpbox.ps1'
    if (-not (Test-Path $jumpboxScript)) {
        Write-Error "deploy-via-jumpbox.ps1 not found at $jumpboxScript"
        exit 1
    }

    # Build arguments hashtable from azd env vars (no az CLI discovery needed)
    $repoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
    $jumpboxArgs = @{
        ResourceGroup       = $resourceGroup
        SourcePath          = $repoRoot
        RemotePath          = 'C:\github\app'
    }

    # VM identity — from Bicep outputs, avoids az vm list / az vm show
    if ($env:VM_NAME)         { $jumpboxArgs['VmName']       = $env:VM_NAME }
    if ($env:VM_RESOURCE_ID)  { $jumpboxArgs['VmResourceId'] = $env:VM_RESOURCE_ID }
    if ($env:BASTION_NAME)    { $jumpboxArgs['BastionName']  = $env:BASTION_NAME }

    # Restore azd environment on jump box (avoids copying .azure folder)
    $azdEnv = $env:ENVIRONMENT_NAME
    if (-not $azdEnv) {
        $azdEnv = (azd env get-values 2>$null | Select-String '^ENVIRONMENT_NAME=' |
            ForEach-Object { $_ -replace '.*=\s*"?([^"]+)"?.*', '$1' } | Select-Object -First 1)
    }
    if ($azdEnv) {
        $jumpboxArgs['AzdEnvName']    = $azdEnv
        # Derive azd working dir from script location (hooks/ is one level below azure.yaml)
        $azdWorkingDir = Split-Path -Leaf (Resolve-Path (Join-Path $ScriptDir '..')).Path
        $jumpboxArgs['AzdWorkingDir'] = $azdWorkingDir
    }

    # Deploy via azd on the jump box (uses ACR Task agent pool for VNet builds)
    $jumpboxArgs['AzdDeploy'] = $true

    # Health probes: build from base URLs passed as script arguments
    if ($HealthProbeBaseUrls.Count -gt 0) {
        $probeUrls = @($HealthProbeBaseUrls | ForEach-Object { $_.TrimEnd('/') + $HealthSuffix })
        $jumpboxArgs['HealthProbeUrls'] = $probeUrls
        Write-Host "  Health probes: $($probeUrls -join ', ')" -ForegroundColor DarkGray
    } else {
        Write-Host "  Health probes: SKIPPED (no base URLs provided)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Invoking deploy-via-jumpbox.ps1 with:" -ForegroundColor DarkGray
    $jumpboxArgs.GetEnumerator() | ForEach-Object { Write-Host "  -$($_.Key) $($_.Value)" -ForegroundColor DarkGray }

    & $jumpboxScript @jumpboxArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "deploy-via-jumpbox.ps1 failed (exit code $LASTEXITCODE)."
        exit $LASTEXITCODE
    }

} else {
    # ─── VNet mode or no network isolation: run app deploy steps inline ──────
    # Add app deploy configuration steps here (steps that require private
    # endpoint access, e.g., Blob uploads, Logic Apps workflow deployment).
    # These scripts live in hooks/scripts/ and are called inline because
    # they cannot run as separate azure.yaml hooks when network isolation
    # is enabled — they need to execute on the jump box.

    # & "$ScriptDir\scripts\configure-blob.ps1"
    # & "$ScriptDir\scripts\configure-logic-apps.ps1"

    Write-Host ""
    Write-Host "App deploy config steps: no steps configured yet." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "===========================================" -ForegroundColor Green
Write-Host " App deploy completed successfully." -ForegroundColor Green
Write-Host "===========================================" -ForegroundColor Green
Write-Host ""
if ($networkIsolation -and -not $runFromJumpbox) {
    Write-Host "Next steps:"
    Write-Host "  1. The jump box has been used to run app deploy steps."
    Write-Host "  2. Container images were built on the ACR Task agent pool"
    Write-Host "     (VNet-injected, zero-trust) and deployed to Container Apps."
    Write-Host ""
} else {
    Write-Host "Next steps:"
    Write-Host "  1. Run 'azd deploy' to build & push container images."
    Write-Host "  2. See project documentation for additional configuration."
    Write-Host ""
}
