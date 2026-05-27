#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-provision hook: ensures BASTION_ALLOWED_SOURCE_IP is set in the azd environment.

.DESCRIPTION
    The bastionAllowedSourceIPs parameter in main.parameters.json uses ${BASTION_ALLOWED_SOURCE_IP}.
    If not set, the Bastion NSG rule gets an empty source address and ARM rejects the deployment.
    This hook auto-detects the caller's public IP and sets the variable if it is missing.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔═══════════════════════════════════════╗"
Write-Host "║            PRE-PROVISION HOOK         ║"
Write-Host "╚═══════════════════════════════════════╝"
Write-Host ""

# Check if already set in the azd environment
Write-Host "► Checking BASTION_ALLOWED_SOURCE_IP in azd environment..."
$existing = azd env get-value BASTION_ALLOWED_SOURCE_IP 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
    Write-Host "  ✔ Already set: $existing"
} else {
    Write-Host "  ⚠ Not set — auto-detecting public IP..."
    $myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10).Trim()
    $cidr = "$myIp/32"
    Write-Host "  ✔ Detected IP: $myIp  →  setting BASTION_ALLOWED_SOURCE_IP=$cidr"
    azd env set BASTION_ALLOWED_SOURCE_IP $cidr
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to set BASTION_ALLOWED_SOURCE_IP in azd environment."
        exit 1
    }
}

Write-Host ""
Write-Host "► Pre-provision checks complete. Proceeding with azd provision..."
Write-Host ""
