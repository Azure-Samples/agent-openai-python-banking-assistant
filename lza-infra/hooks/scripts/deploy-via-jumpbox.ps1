<#
.SYNOPSIS
    deploy-via-jumpbox.ps1 — Automate code transfer and deployment to a
    network-isolated jump box without an interactive Bastion session.

.DESCRIPTION
    This script eliminates the need to open an interactive Azure Bastion
    session for deployments in network-isolated (zero trust) environments.

    It supports two code-transfer strategies:
      • SCP via Bastion tunnel  (-SourcePath)  — for private / local code
      • git clone via Run-Command (-GitRepoUrl) — for public repositories

    After transferring code, it can run azd deploy on the VM via
    `az vm run-command invoke`, validate the deployment with a health
    probe, and deallocate the VM to save cost.

    Requires:
      • Azure CLI 2.60+ with the bastion extension (for SCP mode)
      • PowerShell 7.4+
      • Contributor role on the resource group
      • For SCP mode: Bastion Standard SKU with tunneling enabled,
        and OpenSSH Server running on the jump box VM

.PARAMETER ResourceGroup
    Resource group containing the jump box, Bastion, and application resources.
    Falls back to AZURE_RESOURCE_GROUP from the current azd environment.

.PARAMETER VmName
    Name of the jump box VM. Auto-discovered if omitted (looks for VMs with
    'testvm' or 'jumpbox' in the name).

.PARAMETER SourcePath
    Local directory to copy to the jump box via SCP through a Bastion tunnel.
    Mutually exclusive with -GitRepoUrl.

.PARAMETER GitRepoUrl
    Public Git repository URL to clone on the jump box via az vm run-command.
    Mutually exclusive with -SourcePath.

.PARAMETER GitBranch
    Branch to checkout after clone/pull. Defaults to the repository default.

.PARAMETER RemotePath
    Destination path on the jump box. Defaults to 'C:\github\app'.

.PARAMETER VmAdminUsername
    SSH username for SCP. Defaults to 'azureuser'.

.PARAMETER LocalTunnelPort
    Local port for the Bastion SSH tunnel. Defaults to 50022.

.PARAMETER HealthEndpoint
    Relative URL path to probe after deployment (e.g., '/api/health').
    Probed from the VM via curl. Defaults to '/api/health'.

.PARAMETER ValidateOnly
    Skip code transfer and deployment; only run the health probe.

.PARAMETER IgnoreFile
    Path to a .jumpboxignore file with gitignore-like patterns for SCP exclusions.
    If omitted, looks for '.jumpboxignore' in the lza-infra/ directory (script root).
    Falls back to the ExcludeDirs default if no file is found.

.PARAMETER ExcludeDirs
    Directories to exclude from SCP copy. Used as fallback when no .jumpboxignore
    file is found. Defaults to a sensible set (.git, node_modules, .venv, etc.).

.EXAMPLE
    # Private repo: copy local code and deploy via azd
    ./scripts/deploy-via-jumpbox.ps1 `
        -ResourceGroup rg-myapp `
        -SourcePath . `
        -RemotePath 'C:\github\myapp' `
        -AzdDeploy -AzdEnvName myenv -AzdWorkingDir lza-infra

.EXAMPLE
    # Public repo: clone and deploy
    ./scripts/deploy-via-jumpbox.ps1 `
        -ResourceGroup rg-myapp `
        -GitRepoUrl 'https://github.com/org/repo.git' `
        -RemotePath 'C:\github\myapp' `
        -AzdDeploy -AzdEnvName myenv

.EXAMPLE
    # Validate only (health probe from VM)
    ./scripts/deploy-via-jumpbox.ps1 `
        -ResourceGroup rg-myapp `
        -ValidateOnly
#>

[CmdletBinding(DefaultParameterSetName = 'SCP')]
param(
    [Parameter()]
    [string] $ResourceGroup,

    [Parameter()]
    [string] $VmName,

    [Parameter(ParameterSetName = 'SCP')]
    [string] $SourcePath,

    [Parameter(ParameterSetName = 'Git')]
    [string] $GitRepoUrl,

    [Parameter(ParameterSetName = 'Git')]
    [string] $GitBranch,

    [Parameter()]
    [string] $RemotePath = 'C:\github\app',

    [Parameter(ParameterSetName = 'SCP')]
    [string] $VmAdminUsername = 'azureuser',

    [Parameter(ParameterSetName = 'SCP')]
    [int] $LocalTunnelPort = 50022,

    [Parameter(ParameterSetName = 'SCP')]
    [string] $StorageAccountName,

    [Parameter()]
    [string] $AzdEnvName,

    [Parameter()]
    [string] $AzdWorkingDir,

    [Parameter()]
    [switch] $AzdDeploy,

    [Parameter()]
    [string[]] $HealthProbeUrls,

    [Parameter()]
    [switch] $ValidateOnly,

    [Parameter()]
    [string] $BastionName,

    [Parameter()]
    [string] $VmResourceId,

    [Parameter(ParameterSetName = 'SCP')]
    [string] $IgnoreFile,

    [Parameter(ParameterSetName = 'SCP')]
    [string[]] $ExcludeDirs = @(
        '.git', '.github', '.azure', '.venv', '.temp', '.pytest_cache', '.mypy_cache',
        'node_modules', 'dist', 'build', 'infra', 'docs', 'spec', 'requirements', '__pycache__'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper functions
function Write-Step  { param([string]$msg) Write-Host "`n========== $msg ==========" -ForegroundColor Cyan }
function Write-Ok    { param([string]$msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn  { param([string]$msg) Write-Host "[!]  $msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$msg) Write-Host "[X]  $msg" -ForegroundColor Red }
function Write-Info  { param([string]$msg) Write-Host "[>]  $msg" -ForegroundColor White }

function Read-JumpboxIgnore {
    <#
    .SYNOPSIS
        Parse a .jumpboxignore file (gitignore-like syntax) into directory and file exclusion lists.
    .DESCRIPTION
        Supports:
          - Comments (lines starting with #)
          - Blank lines (ignored)
          - Directory patterns (ending with /) → added to ExcludeDirs
          - Glob patterns (containing * or ?) → added to ExcludeFiles
          - Plain names → added to ExcludeDirs (treated as directory names)
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $excludeDirsList  = [System.Collections.Generic.List[string]]::new()
    $excludeFilesList = [System.Collections.Generic.List[string]]::new()

    $lines = Get-Content -Path $Path -ErrorAction Stop
    foreach ($line in $lines) {
        $line = $line.Trim()
        # Skip comments and blank lines
        if (-not $line -or $line.StartsWith('#')) { continue }

        if ($line.EndsWith('/')) {
            # Directory pattern — strip trailing slash for robocopy
            $excludeDirsList.Add($line.TrimEnd('/'))
        } elseif ($line -match '[*?]') {
            # Glob/wildcard — treat as file pattern
            $excludeFilesList.Add($line)
        } else {
            # Plain name — treat as directory (most common use case)
            $excludeDirsList.Add($line)
        }
    }

    return @{
        Dirs  = $excludeDirsList.ToArray()
        Files = $excludeFilesList.ToArray()
    }
}
#endregion

#region Validate Azure CLI session
Write-Step "Validating Azure CLI session"
try {
    $account = az account show -o json 2>&1 | ConvertFrom-Json
    Write-Ok "Logged in as $($account.user.name) on subscription $($account.name)"
} catch {
    Write-Err "Not logged into Azure CLI. Run 'az login' first."
    exit 1
}
#endregion

#region Resolve resource group
if (-not $ResourceGroup) {
    $ResourceGroup = $env:AZURE_RESOURCE_GROUP
}
if (-not $ResourceGroup) {
    $ResourceGroup = (azd env get-values 2>&1 | Select-String '^AZURE_RESOURCE_GROUP=' |
        ForEach-Object { $_ -replace '.*=\s*"?([^"]+)"?.*', '$1' } | Select-Object -First 1)
    if (-not $ResourceGroup) {
        Write-Err "ResourceGroup not specified and AZURE_RESOURCE_GROUP not found in azd env."
        exit 1
    }
}
Write-Ok "Resource group: $ResourceGroup"
#endregion

#region Discover VM
Write-Step "Discovering jump box VM"
# Prefer parameter > env var > az discovery
if (-not $VmName) { $VmName = $env:VM_NAME }
if (-not $VmName) {
    Write-Info "VM_NAME not set — discovering via Azure CLI..."
    $VmName = az vm list -g $ResourceGroup `
        --query "[?contains(name, 'testvm') || contains(name, 'jumpbox')].name | [0]" `
        -o tsv 2>&1
    if (-not $VmName) {
        Write-Err "No jump box VM found in $ResourceGroup. Specify -VmName or set VM_NAME env var."
        exit 1
    }
}
$VmName = $VmName.Trim()
Write-Ok "VM: $VmName"

# Resolve VM resource ID: parameter > env var > az lookup
if (-not $VmResourceId) { $VmResourceId = $env:VM_RESOURCE_ID }
if (-not $VmResourceId) {
    Write-Info "VM_RESOURCE_ID not set — resolving via Azure CLI..."
    $VmResourceId = az vm show -g $ResourceGroup -n $VmName --query id -o tsv 2>&1
    if (-not $VmResourceId) {
        Write-Err "Could not resolve VM resource ID for $VmName in $ResourceGroup."
        exit 1
    }
} else {
    Write-Ok "VM resource ID: (from env/param)"
}
$vmResourceId = $VmResourceId
#endregion

#region Ensure VM is running
Write-Step "Checking VM power state"
$vmState = az vm get-instance-view -g $ResourceGroup -n $VmName `
    --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" `
    -o tsv 2>&1

$vmStartedByUs = $false
if ($vmState -ne 'PowerState/running') {
    Write-Warn "VM is $vmState — starting..."
    $vmStartOut = az vm start -g $ResourceGroup -n $VmName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to start VM ${VmName}: $vmStartOut"
        exit 1
    }
    $vmStartedByUs = $true
    Write-Ok "VM started."
} else {
    Write-Ok "VM is running."
}
#endregion

#region Run-Command helper
function Invoke-VmCommand {
    param(
        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string] $Script
    )

    Write-Info "$Label"

    # Write script to a temp file to avoid shell quoting issues
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $Script -Encoding UTF8

    $rawJson = az vm run-command invoke `
        -g $ResourceGroup `
        -n $VmName `
        --command-id RunPowerShellScript `
        --scripts "@$($tmpFile.FullName)" `
        -o json 2>&1

    $rc = $LASTEXITCODE
    Remove-Item $tmpFile.FullName -ErrorAction SilentlyContinue

    if ($rc -ne 0) {
        if ($rawJson) { Write-Host ($rawJson -join "`n") }
        Write-Err "$Label failed (az cli exit code $rc)."
        return $false
    }

    # Parse stdout and stderr from the VM run-command JSON response.
    # value[0] = stdout (ComponentStatus/StdOut), value[1] = stderr (ComponentStatus/StdErr)
    $stdout = ''; $stderr = ''
    try {
        $parsed = ($rawJson -join "`n") | ConvertFrom-Json
        foreach ($entry in $parsed.value) {
            if ($entry.code -match 'StdOut') { $stdout = $entry.message }
            if ($entry.code -match 'StdErr') { $stderr = $entry.message }
        }
    } catch {
        # JSON parsing failed — treat raw output as stdout
        $stdout = $rawJson -join "`n"
    }

    if ($stdout) { Write-Host $stdout }

    # Non-empty stderr means the VM script wrote errors or exited with non-zero
    if ($stderr -and $stderr.Trim().Length -gt 0) {
        Write-Host "--- VM stderr ---"
        Write-Host $stderr
        Write-Err "$Label failed (VM script reported errors)."
        return $false
    }

    Write-Ok "$Label completed."
    return $true
}
#endregion

if (-not $ValidateOnly) {

    #region Code transfer
    Write-Step "Transferring code to jump box"

    if ($SourcePath) {
        # ---------- Blob transfer via storage account ----------
        $SourcePath = (Resolve-Path $SourcePath).Path

        Write-Info "Source: $SourcePath"
        Write-Info "Destination: ${VmName}:${RemotePath}"

        # Ensure remote directory exists
        $mkdirResult = Invoke-VmCommand -Label "Create remote directory" -Script @"
if (-not (Test-Path '$RemotePath')) {
    New-Item -ItemType Directory -Path '$RemotePath' -Force | Out-Null
    Write-Output 'Created $RemotePath'
} else {
    Write-Output '$RemotePath already exists'
}
"@
        if (-not $mkdirResult) { exit 1 }

        # Stage source: copy to temp dir excluding patterns from .jumpboxignore
        # Resolve ignore file: parameter > .jumpboxignore next to this script's lza-infra root > fallback to ExcludeDirs
        $excludeFiles = @()
        $resolvedIgnoreFile = $IgnoreFile
        if (-not $resolvedIgnoreFile) {
            # Script is at lza-infra/hooks/scripts/deploy-via-jumpbox.ps1 → 3 levels up to lza-infra/
            $scriptRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
            $resolvedIgnoreFile = Join-Path $scriptRoot '.jumpboxignore'
        }
        if ($resolvedIgnoreFile -and (Test-Path $resolvedIgnoreFile)) {
            Write-Info "Loading exclusions from: $resolvedIgnoreFile"
            $ignoreRules = Read-JumpboxIgnore -Path $resolvedIgnoreFile
            $ExcludeDirs  = $ignoreRules.Dirs
            $excludeFiles = $ignoreRules.Files
        }

        Write-Info "Staging source (excluding dirs: $($ExcludeDirs -join ', '))..."
        if ($excludeFiles.Count -gt 0) {
            Write-Info "Excluding files: $($excludeFiles -join ', ')"
        }
        $stageDir = Join-Path ([System.IO.Path]::GetTempPath()) ("jumpbox-deploy-{0}" -f [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $stageDir | Out-Null

        $robocopyArgs = @($SourcePath, $stageDir, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
        if ($ExcludeDirs.Count -gt 0)  { $robocopyArgs += '/XD'; $robocopyArgs += $ExcludeDirs }
        if ($excludeFiles.Count -gt 0) { $robocopyArgs += '/XF'; $robocopyArgs += $excludeFiles }
        & robocopy @robocopyArgs | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Err "Failed to stage source tree (robocopy exit $LASTEXITCODE)."
            exit 1
        }
        $fileCount = (Get-ChildItem $stageDir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
        $totalSize = (Get-ChildItem $stageDir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        Write-Ok ("Staged $fileCount files ({0:N1} MB)" -f ($totalSize / 1MB))

        # Compress staged files into zip for blob transfer
        Write-Info "Compressing staged files..."
        $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) ("jumpbox-payload-{0}.zip" -f [guid]::NewGuid().ToString('N').Substring(0,8))
        Compress-Archive -Path "$stageDir\*" -DestinationPath $zipPath -CompressionLevel Optimal
        $zipSize = (Get-Item $zipPath).Length
        Write-Ok ("Compressed to {0:N2} MB" -f ($zipSize / 1MB))

        # Discover storage account: parameter > env var > az lookup
        $storageAcct = $StorageAccountName
        if (-not $storageAcct) { $storageAcct = $env:AZURE_STORAGE_ACCOUNT_NAME }
        if (-not $storageAcct) {
            Write-Info "Discovering storage account in $ResourceGroup..."
            $storageAcct = az storage account list -g $ResourceGroup `
                --query "[?starts_with(name, 'st') && !starts_with(name, 'staif')].name | [0]" -o tsv 2>&1
        }
        if (-not $storageAcct) {
            $storageAcct = az storage account list -g $ResourceGroup `
                --query "[0].name" -o tsv 2>&1
        }
        if (-not $storageAcct) {
            Write-Err "No storage account found in $ResourceGroup for blob transfer."
            Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            exit 1
        }
        $storageAcct = $storageAcct.Trim()
        Write-Ok "Storage account: $storageAcct"

        # Temporarily enable public network access for upload
        Write-Info "Enabling public network access on storage account (temporary)..."
        $previousAccess = az storage account show -n $storageAcct -g $ResourceGroup `
            --query 'publicNetworkAccess' -o tsv 2>&1
        $netUpdateOut = az storage account update -g $ResourceGroup -n $storageAcct `
            --public-network-access Enabled --default-action Allow -o none 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Failed to enable public network access: $netUpdateOut"
            exit 1
        }
        # Wait for network rule propagation (5s is often insufficient)
        Start-Sleep -Seconds 15

        try {
            # Upload using RBAC auth (requires Storage Blob Data Contributor on the caller)
            $containerName = 'jumpbox-transfer'
            $blobName = "payload-{0}.zip" -f [guid]::NewGuid().ToString('N').Substring(0,8)
            # Retry container create — network rule propagation can take 15-60s
            $containerOk = $false
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                $containerErr = az storage container create --account-name $storageAcct --name $containerName `
                    --auth-mode login -o none 2>&1
                if ($LASTEXITCODE -eq 0) { $containerOk = $true; break }
                Write-Warn "Container create attempt $attempt/4 failed (network rules propagating). Retrying in 15s..."
                Start-Sleep -Seconds 15
            }
            if (-not $containerOk) {
                Write-Err "Container create failed after 4 attempts: $containerErr"
                exit 1
            }
            Write-Info "Uploading $([math]::Round($zipSize/1MB,2)) MB to blob..."
            $uploadErr = az storage blob upload --account-name $storageAcct --container-name $containerName `
                --name $blobName --file $zipPath --auth-mode login --overwrite -o none 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Blob upload failed: $uploadErr"
                exit 1
            }
            Write-Ok "Uploaded to $storageAcct/$containerName/$blobName"

            # Generate a user-delegation SAS URL (valid 30 min) so the VM can download
            # via Invoke-WebRequest without needing Azure CLI auth
            $expiry = (Get-Date).AddMinutes(30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $sasToken = az storage blob generate-sas --account-name $storageAcct `
                --container-name $containerName --name $blobName `
                --permissions r --expiry $expiry --auth-mode login --as-user -o tsv 2>&1
            if ($LASTEXITCODE -ne 0 -or -not $sasToken) {
                Write-Err "SAS token generation failed: $sasToken"
                exit 1
            }
            $sasUrl = "https://${storageAcct}.blob.core.windows.net/${containerName}/${blobName}?${sasToken}"

            # Download and extract on VM via run-command
            $downloadResult = Invoke-VmCommand -Label "Download and extract payload on VM" -Script @"
`$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path 'C:\temp' -Force | Out-Null
New-Item -ItemType Directory -Path '$RemotePath' -Force | Out-Null
Write-Output 'Downloading payload from blob storage...'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri '$sasUrl' -OutFile 'C:\temp\payload.zip' -UseBasicParsing
`$size = (Get-Item 'C:\temp\payload.zip').Length
Write-Output "Downloaded: `$([math]::Round(`$size/1MB, 2)) MB"
Write-Output 'Extracting...'
Expand-Archive -Path 'C:\temp\payload.zip' -DestinationPath '$RemotePath' -Force
Remove-Item 'C:\temp\payload.zip' -Force
Write-Output "Files extracted: `$((Get-ChildItem '$RemotePath' -Recurse -File).Count)"
"@
            if (-not $downloadResult) {
                Write-Err "Failed to download/extract payload on VM."
                exit 1
            }
            Write-Ok "Files transferred to ${VmName}:${RemotePath}"

        } finally {
            # Restore storage account network access
            if ($previousAccess -eq 'Disabled') {
                Write-Info "Restoring storage account network isolation..."
                $restoreOut = az storage account update -g $ResourceGroup -n $storageAcct `
                    --public-network-access Disabled -o none 2>&1
                if ($LASTEXITCODE -ne 0) { Write-Warn "Failed to restore network isolation: $restoreOut" }
            }
            # Cleanup: delete blob, remove local temp files
            $deleteOut = az storage blob delete --account-name $storageAcct --container-name $containerName `
                --name $blobName --auth-mode login -o none 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Warn "Blob cleanup failed: $deleteOut" }
            Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }

    } elseif ($GitRepoUrl) {
        # ---------- git clone via Run-Command ----------
        $branchArg = if ($GitBranch) { "--branch $GitBranch" } else { "" }

        $cloneScript = @"
`$ErrorActionPreference = 'Stop'
if (Test-Path '$RemotePath\.git') {
    Write-Output 'Repository exists — pulling latest...'
    Set-Location '$RemotePath'
    git fetch --all 2>&1
    $(if ($GitBranch) { "git checkout '$GitBranch' 2>&1" } else { "" })
    git pull 2>&1
    Write-Output 'Pull complete.'
} else {
    Write-Output 'Cloning repository...'
    git clone $branchArg '$GitRepoUrl' '$RemotePath' 2>&1
    Write-Output 'Clone complete.'
}
Write-Output "HEAD: `$(git -C '$RemotePath' rev-parse --short HEAD)"
"@
        $result = Invoke-VmCommand -Label "Clone/pull repository on VM" -Script $cloneScript
        if (-not $result) { exit 1 }

    } else {
        Write-Warn "No -SourcePath or -GitRepoUrl specified. Skipping code transfer."
        Write-Info "Assuming code is already present at $RemotePath on the VM."
    }
    #endregion

    #region Restore azd environment on VM
    if ($AzdEnvName) {
        Write-Step "Restoring azd environment on VM"
        $azdDir = if ($AzdWorkingDir) { "$RemotePath\$AzdWorkingDir" } else { $RemotePath }

        # Strategy: copy local .env file directly to VM (azd env refresh doesn't work
        # with managed identity — "not logged in" even after azd auth login --managed-identity)
        $localAzdRoot = if ($AzdWorkingDir) { Join-Path $SourcePath $AzdWorkingDir } else { $SourcePath }
        if (-not $localAzdRoot) {
            # Fallback: resolve from script location (lza-infra/hooks/scripts/ → lza-infra/)
            $localAzdRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        }
        $localEnvFile = Join-Path $localAzdRoot ".azure\$AzdEnvName\.env"

        if (Test-Path $localEnvFile) {
            Write-Info "Copying local azd env file to VM: $localEnvFile"
            $envContent = Get-Content -Path $localEnvFile -Raw
            # Strip BOM if present in source
            if ($envContent.StartsWith([char]0xFEFF)) { $envContent = $envContent.Substring(1) }
            $envBytes = [System.Text.Encoding]::UTF8.GetBytes($envContent)
            $envB64 = [Convert]::ToBase64String($envBytes)

            $copyEnvScript = @"
`$ErrorActionPreference = 'Stop'
`$envDir = '$azdDir\.azure\$AzdEnvName'
New-Item -ItemType Directory -Path `$envDir -Force | Out-Null
`$bytes = [Convert]::FromBase64String('$envB64')
[System.IO.File]::WriteAllBytes("`$envDir\.env", `$bytes)
`$lineCount = (Get-Content "`$envDir\.env").Count
Write-Output "azd env file written: `$lineCount variables to `$envDir\.env"
"@
            $result = Invoke-VmCommand -Label "Copy azd env ($AzdEnvName)" -Script $copyEnvScript
            if (-not $result) {
                Write-Warn "Failed to copy azd env file — deploy may still work if env vars are passed explicitly."
            }
        } else {
            Write-Warn "Local azd env file not found: $localEnvFile"
            Write-Warn "Skipping azd env restore. Ensure .env is present on the VM or pass env vars explicitly."
        }
    }
    #endregion

    #region AzdDeploy
    if ($AzdDeploy) {
        $azdDeployDir = if ($AzdWorkingDir) { "$RemotePath\$AzdWorkingDir" } else { $RemotePath }

        Write-Step "Running azd deploy on VM (working dir: $azdDeployDir)"

        # Read .env locally to check if network isolation is active (ACR is private)
        $localAzdRoot = if ($AzdWorkingDir) { Join-Path $SourcePath $AzdWorkingDir } else { $SourcePath }
        if (-not $localAzdRoot) {
            $localAzdRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        }
        $localEnvFile = Join-Path $localAzdRoot ".azure\$AzdEnvName\.env"
        $acrEndpointLocal = ''
        $acrRgLocal = ''
        if (Test-Path $localEnvFile) {
            $lines = Get-Content $localEnvFile
            $epLine = $lines | Where-Object { $_ -match '^AZURE_CONTAINER_REGISTRY_ENDPOINT=' }
            if ($epLine) { $acrEndpointLocal = ($epLine -split '=', 2)[1].Trim().Trim('"') }
            $rgLine = $lines | Where-Object { $_ -match '^AZURE_RESOURCE_GROUP=' }
            if ($rgLine) { $acrRgLocal = ($rgLine -split '=', 2)[1].Trim().Trim('"') }
        }
        $acrNameLocal = if ($acrEndpointLocal) { $acrEndpointLocal.Split('.')[0] } else { '' }

        # Check current ACR public access state to decide if we need to toggle.
        # IMPORTANT: When ACR public access is disabled via `--public-network-enabled false`,
        # Azure implicitly sets networkRuleSet.defaultAction to Deny. Re-enabling with
        # `--public-network-enabled true` alone is NOT enough — the defaultAction stays Deny
        # and blocks all IPs. We must also pass `--default-action Allow` to restore access.
        # After deploy, we disable public access again (which implicitly overrides all rules).
        $needAcrToggle = $false
        if ($acrNameLocal) {
            $currentAccess = az acr show -n $acrNameLocal --query "publicNetworkAccess" -o tsv 2>$null
            if ($currentAccess -eq 'Disabled') {
                $needAcrToggle = $true
                Write-Info "ACR '$acrNameLocal' has publicNetworkAccess=Disabled"
                Write-Info "Temporarily enabling public access for remote build (azd deploy remoteBuild:true)..."
                az acr update -n $acrNameLocal --public-network-enabled true --default-action Allow -o none 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "Failed to enable public access on ACR '$acrNameLocal'"
                    exit 1
                }
                Write-Info "ACR public access enabled. Will be re-disabled after deploy."
            }
        }

        $azdDeployScript = @"
`$ErrorActionPreference = 'Stop'
Set-Location '$azdDeployDir'

Write-Output 'Logging in with managed identity...'
az login --identity 2>&1 | Out-Null
if (`$LASTEXITCODE -ne 0) { Write-Error 'az login --identity failed'; exit 1 }

Write-Output 'Authenticating azd with managed identity...'
azd auth login --managed-identity
if (`$LASTEXITCODE -ne 0) { Write-Error 'azd auth login failed'; exit 1 }

Write-Output 'Running azd deploy -e $AzdEnvName ...'
azd deploy --no-prompt -e '$AzdEnvName'
Write-Output "azd deploy exit code: `$LASTEXITCODE"
exit `$LASTEXITCODE
"@

        try {
            $result = Invoke-VmCommand -Label "azd deploy" -Script $azdDeployScript
            if (-not $result) {
                Write-Err "azd deploy failed. Check output above."
                exit 1
            }
        } finally {
            # Always re-disable public access if we toggled it, even on failure
            if ($needAcrToggle) {
                Write-Info "Re-disabling public access on ACR '$acrNameLocal'..."
                az acr update -n $acrNameLocal --public-network-enabled false -o none 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "WARNING: Failed to re-disable public access on ACR '$acrNameLocal'. Please disable manually."
                } else {
                    Write-Info "ACR public access re-disabled."
                }
            }
        }
    }
    #endregion
}

#region Health probes
if ($HealthProbeUrls -and $HealthProbeUrls.Count -gt 0) {
    Write-Step "Running health probes from VM ($($HealthProbeUrls.Count) endpoint(s))"

    # Build a single script that probes all URLs sequentially
    $probeLines = @()
    $probeLines += "`$ErrorActionPreference = 'Continue'"
    $probeLines += "`$allPassed = `$true"
    $probeLines += ""

    foreach ($url in $HealthProbeUrls) {
        $probeLines += @"
# ─── Probe: $url ───
Write-Output ''
Write-Output 'Probing $url ...'
`$probeOk = `$false
for (`$i = 1; `$i -le 6; `$i++) {
    `$out = curl.exe -sS --ssl-no-revoke -m 30 -w '|HTTP_%{http_code}' '$url' 2>&1
    `$raw = (`$out | Out-String).TrimEnd()
    if (`$raw -match '\|HTTP_([0-9]{3})\s*`$') {
        `$code = `$Matches[1]
        `$body = `$raw -replace '\|HTTP_[0-9]{3}\s*`$', ''
        if (`$code -match '^2[0-9]{2}`$') {
            Write-Output "  PROBE_OK: $url (HTTP `$code)"
            `$probeOk = `$true
            break
        }
        Write-Output "  Attempt `$i/6: HTTP `$code"
    } else {
        Write-Output "  Attempt `$i/6: no valid response"
    }
    Start-Sleep -Seconds 10
}
if (-not `$probeOk) {
    Write-Output "  PROBE_FAILED: $url — could not reach after 6 attempts."
    `$allPassed = `$false
}
"@
        $probeLines += ""
    }

    $probeLines += @"
Write-Output ''
if (`$allPassed) {
    Write-Output 'ALL_PROBES_PASSED'
} else {
    Write-Output 'SOME_PROBES_FAILED'
    exit 1
}
"@

    $probeScript = $probeLines -join "`n"
    $result = Invoke-VmCommand -Label "Health probes" -Script $probeScript
    if (-not $result) {
        Write-Err "One or more health probes failed."
        Write-Err "  Check logs: az containerapp logs show -g $ResourceGroup -n <app-name> --tail 50"
        exit 1
    }
}
#endregion

Write-Host ""
Write-Ok "Done."
