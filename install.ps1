<#
.SYNOPSIS
  Install, upgrade, or manage the NTAScanUploader Windows service (NSSM-based).

.DESCRIPTION
  Run from an elevated PowerShell:

    # Install or upgrade (auto-detects existing service)
    irm https://raw.githubusercontent.com/GetSamAI/NTAScanUploader/main/install.ps1 | iex

  Or download and use explicit actions:

    .\install.ps1                    # install or upgrade (auto)
    .\install.ps1 -Action uninstall
    .\install.ps1 -Action start
    .\install.ps1 -Action stop
    .\install.ps1 -Action restart
    .\install.ps1 -Action status
    .\install.ps1 -Action logs

  Unattended install (skip prompts):
    .\install.ps1 -ApiKey "..." -BaseUrl "https://..." -DeviceCode "..." -WatchPath "D:\FTPServer\Data\Arch"
#>

[CmdletBinding()]
param(
    [ValidateSet("auto","install","upgrade","uninstall","start","stop","restart","status","logs")]
    [string]$Action      = "auto",
    [string]$InstallDir  = "D:\NTAScanUploader",
    [string]$ServiceName = "NTAScanUploader",
    [string]$ApiKey,
    [string]$BaseUrl,
    [string]$DeviceCode,
    [string]$WatchPath,
    [switch]$SkipConfig,
    [string]$GitHubRepo  = "GetSamAI/NTAScanUploader-dist",
    [string]$NssmUrl     = "https://nssm.cc/release/nssm-2.24.zip"
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        throw "This script must be run from an elevated PowerShell (Run as administrator)."
    }
}

function Service-Exists {
    return ($null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue))
}

function Ensure-InstallDir {
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
}

function Ensure-LocalScript {
    $dest = Join-Path $InstallDir "install.ps1"
    # If running from disk inside InstallDir already, nothing to do
    if ($PSCommandPath -and ((Resolve-Path -Path $PSCommandPath -ErrorAction SilentlyContinue).Path -eq (Resolve-Path -Path $dest -ErrorAction SilentlyContinue).Path)) { return }
    Write-Host "Saving install.ps1 to $dest for future management..."
    $url = "https://raw.githubusercontent.com/$GitHubRepo/main/install.ps1"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        Write-Warning "Could not download install.ps1 from $url ($_). You can copy it manually later."
    }
}

function Ensure-Nssm {
    $nssm = Join-Path $InstallDir "nssm.exe"
    if (Test-Path $nssm) { return $nssm }

    Write-Host "Downloading NSSM from $NssmUrl ..."
    $tmp = Join-Path $env:TEMP ("nssm-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp "nssm.zip"
    Invoke-WebRequest -Uri $NssmUrl -OutFile $zip -UseBasicParsing

    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { "win64" } else { "win32" }
    $src = Get-ChildItem -Path $tmp -Recurse -Filter "nssm.exe" |
        Where-Object { $_.DirectoryName -match [regex]::Escape($arch) } |
        Select-Object -First 1
    if (-not $src) {
        throw "Could not locate $arch\nssm.exe inside the downloaded NSSM archive."
    }
    Copy-Item -Path $src.FullName -Destination $nssm -Force
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return $nssm
}

function Get-LatestReleaseAsset {
    Write-Host "Fetching latest release info from GitHub..."
    $headers = @{ "User-Agent" = "NTAScanUploader-Installer" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubRepo/releases/latest" -Headers $headers -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -eq "upload_script.exe" } | Select-Object -First 1
    if (-not $asset) {
        throw "Release $($release.tag_name) has no upload_script.exe asset."
    }
    return [PSCustomObject]@{
        Tag = $release.tag_name
        Url = $asset.browser_download_url
    }
}

function Download-File {
    param([string]$Url, [string]$Dest)
    Write-Host "Downloading $Url ..."
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
}

function Build-ConfigObject {
    param(
        [string]$ApiKeyValue,
        [string]$BaseUrlValue,
        [string]$DeviceCodeValue,
        [string]$WatchPathValue
    )
    return [ordered]@{
        api_key                    = $ApiKeyValue
        base_url                   = $BaseUrlValue
        watch_path                 = $WatchPathValue
        deviceCode                 = $DeviceCodeValue
        keep_alive_status          = "online"
        keep_alive_interval        = 60
        video_queue_name           = "video_queue.db"
        json_queue_name            = "json_queue.db"
        failed_upload_queue_name   = "failed_upload_queue.db"
        file_type_function_map     = [ordered]@{
            ".mp4"  = "upload_scan_video"
            ".json" = "scanner_result_json_upload"
        }
        ignore_files               = @("finish.json")
        video_workers              = 2
        json_workers               = 6
        retry_workers              = 1
        max_retries                = 3
        retry_interval             = 120
        max_total_retries          = 20
        timeout_internet_connection = 8
        use_blob_storage           = $true
        logging                    = [ordered]@{
            level         = "INFO"
            file          = "uploader_log.log"
            format        = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
            queue_maxsize = 10000
            max_bytes     = 10485760
            backup_count  = 5
        }
    }
}

function Prompt-ConfigInteractive {
    function Ask($label, $default) {
        if ($default) {
            $answer = Read-Host "$label [$default]"
            if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
            return $answer
        }
        $answer = $null
        while ([string]::IsNullOrWhiteSpace($answer)) {
            $answer = Read-Host $label
        }
        return $answer
    }

    $apiKey     = if ($script:ApiKey)     { $script:ApiKey }     else { Ask "API key"     $null }
    $baseUrl    = if ($script:BaseUrl)    { $script:BaseUrl }    else { Ask "Base URL"    "https://dw.scanwithsam.de/api/" }
    $deviceCode = if ($script:DeviceCode) { $script:DeviceCode } else { Ask "Device code" $null }
    $watchPath  = if ($script:WatchPath)  { $script:WatchPath }  else { Ask "Watch path"  "D:\FTPServer\Data\Arch" }

    return Build-ConfigObject -ApiKeyValue $apiKey -BaseUrlValue $baseUrl -DeviceCodeValue $deviceCode -WatchPathValue $watchPath
}

function Build-TemplateConfig {
    # Only api_key, base_url, and deviceCode are left blank — everything else
    # has a sensible default the installer pre-fills so the user only has to
    # edit three lines of config.json.
    $apiKey     = if ($script:ApiKey)     { $script:ApiKey }     else { "" }
    $baseUrl    = if ($script:BaseUrl)    { $script:BaseUrl }    else { "" }
    $deviceCode = if ($script:DeviceCode) { $script:DeviceCode } else { "" }
    $watchPath  = if ($script:WatchPath)  { $script:WatchPath }  else { "D:\FTPServer\Data\Arch" }
    return Build-ConfigObject -ApiKeyValue $apiKey -BaseUrlValue $baseUrl -DeviceCodeValue $deviceCode -WatchPathValue $watchPath
}

function Write-JsonUtf8 {
    param([string]$Path, [object]$Data)
    $json = $Data | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Merge-ConfigDefaults {
    # Adds any missing keys from $defaults into $existing without overwriting
    # existing values. Returns an [ordered] hashtable plus the list of added keys.
    param($existing, $defaults, [string]$prefix = "")

    $result = [ordered]@{}
    $added  = New-Object System.Collections.Generic.List[string]
    $existingKeys = @($existing.PSObject.Properties.Name)

    foreach ($key in $defaults.Keys) {
        $defaultVal = $defaults[$key]
        $keyPath = if ($prefix) { "$prefix.$key" } else { $key }

        if ($existingKeys -contains $key) {
            $existingVal = $existing.PSObject.Properties[$key].Value
            if ($defaultVal -is [System.Collections.IDictionary] -and $existingVal -is [PSCustomObject]) {
                $nested = Merge-ConfigDefaults -existing $existingVal -defaults $defaultVal -prefix $keyPath
                $result[$key] = $nested.Result
                foreach ($k in $nested.Added) { $added.Add($k) }
            } else {
                $result[$key] = $existingVal
            }
        } else {
            $result[$key] = $defaultVal
            $added.Add($keyPath)
        }
    }

    # Preserve any extra keys the user may have added that aren't in defaults
    foreach ($key in $existingKeys) {
        if (-not $result.Contains($key)) {
            $result[$key] = $existing.PSObject.Properties[$key].Value
        }
    }

    return [PSCustomObject]@{ Result = $result; Added = $added }
}

function Update-ConfigIfNeeded {
    param([string]$CfgPath)
    if (-not (Test-Path $CfgPath)) { return }

    try {
        $existing = Get-Content -Raw -Path $CfgPath -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "Could not parse $CfgPath as JSON ($_). Skipping config migration."
        return
    }

    $defaults = Build-TemplateConfig
    $merge = Merge-ConfigDefaults -existing $existing -defaults $defaults

    if ($merge.Added.Count -eq 0) {
        Write-Host "Config schema already up-to-date."
        return
    }

    Write-Host "Migrating config.json — adding $($merge.Added.Count) new default key(s):"
    foreach ($k in $merge.Added) { Write-Host "  + $k" }
    Write-JsonUtf8 -Path $CfgPath -Data $merge.Result
}

function Register-NssmService {
    param([string]$Nssm, [string]$ExePath)

    Write-Host "Registering service '$ServiceName' with NSSM..."
    & $Nssm install $ServiceName $ExePath | Out-Null
    & $Nssm set $ServiceName AppDirectory     $InstallDir | Out-Null
    & $Nssm set $ServiceName DisplayName      "NTA Scan Uploader" | Out-Null
    & $Nssm set $ServiceName Description      "Uploads scanner results to the NTA backend" | Out-Null
    & $Nssm set $ServiceName Start            SERVICE_AUTO_START | Out-Null
    & $Nssm set $ServiceName ObjectName       LocalSystem | Out-Null

    # Restart on any non-graceful exit
    & $Nssm set $ServiceName AppExit Default  Restart | Out-Null
    & $Nssm set $ServiceName AppRestartDelay  5000 | Out-Null
    & $Nssm set $ServiceName AppThrottle      10000 | Out-Null

    # Capture stdout/stderr with rotation so crashes leave a trail
    & $Nssm set $ServiceName AppStdout        (Join-Path $InstallDir "service_stdout.log") | Out-Null
    & $Nssm set $ServiceName AppStderr        (Join-Path $InstallDir "service_stderr.log") | Out-Null
    & $Nssm set $ServiceName AppRotateFiles   1 | Out-Null
    & $Nssm set $ServiceName AppRotateOnline  1 | Out-Null
    & $Nssm set $ServiceName AppRotateBytes   10485760 | Out-Null
}

function Do-Install {
    Require-Admin
    if (Service-Exists) {
        Write-Host "Service '$ServiceName' already exists — switching to upgrade."
        Do-Upgrade
        return
    }

    Ensure-InstallDir
    Ensure-LocalScript
    $nssm = Ensure-Nssm

    $release = Get-LatestReleaseAsset
    $exe = Join-Path $InstallDir "upload_script.exe"
    Download-File -Url $release.Url -Dest $exe

    $cfgPath = Join-Path $InstallDir "config.json"
    $configFilledIn = $true
    if (-not (Test-Path $cfgPath)) {
        if ($SkipConfig) {
            $config = Build-TemplateConfig
            Write-JsonUtf8 -Path $cfgPath -Data $config
            Write-Host "Wrote template $cfgPath with placeholders."
            $configFilledIn = $false
        } else {
            $config = Prompt-ConfigInteractive
            Write-JsonUtf8 -Path $cfgPath -Data $config
            Write-Host "Wrote $cfgPath"
        }
    } else {
        Write-Host "Keeping existing $cfgPath"
    }

    Register-NssmService -Nssm $nssm -ExePath $exe

    if ($configFilledIn) {
        Write-Host "Starting service..."
        & $nssm start $ServiceName | Out-Null
    } else {
        Write-Host ""
        Write-Host "Service registered but NOT started because config.json still has placeholders."
        Write-Host "Next steps:"
        Write-Host "  1. Open $cfgPath and fill in:"
        Write-Host "       - api_key      (scanner API key)"
        Write-Host "       - base_url     (e.g. https://dw.scanwithsam.de/api/)"
        Write-Host "       - deviceCode   (scanner device ID)"
        Write-Host "     Everything else (watch_path, workers, retries, logging) is pre-filled."
        Write-Host "  2. Start the service: .\install.ps1 -Action start"
    }

    Write-Host ""
    Write-Host "Install complete. Release: $($release.Tag)"
    Write-Host "Install dir:  $InstallDir"
    Write-Host "Service name: $ServiceName"
    Write-Host ""
    Write-Host "Manage the service:"
    Write-Host "  .\install.ps1 -Action stop      (or: nssm stop $ServiceName)"
    Write-Host "  .\install.ps1 -Action start     (or: nssm start $ServiceName)"
    Write-Host "  .\install.ps1 -Action restart   (or: nssm restart $ServiceName)  # run after editing config.json"
    Write-Host "  .\install.ps1 -Action status"
    Write-Host "  .\install.ps1 -Action logs"
    Write-Host "  services.msc  ->  '$ServiceName'"
}

function Do-Upgrade {
    Require-Admin
    if (-not (Service-Exists)) {
        Write-Host "Service '$ServiceName' does not exist — switching to install."
        Do-Install
        return
    }

    Ensure-InstallDir
    Ensure-LocalScript
    $nssm = Ensure-Nssm

    Write-Host "Stopping service..."
    & $nssm stop $ServiceName | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Service -Name $ServiceName).Status -ne "Stopped") {
        if ((Get-Date) -gt $deadline) { throw "Service '$ServiceName' did not stop within 30s." }
        Start-Sleep -Milliseconds 500
    }

    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path $InstallDir "backup_$ts"
    Write-Host "Backing up to $backupDir ..."
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    foreach ($name in "upload_script.exe", "config.json") {
        $src = Join-Path $InstallDir $name
        if (Test-Path $src) { Copy-Item $src -Destination $backupDir -Force }
    }

    Write-Host "Clearing queue databases (format may have changed between releases)..."
    Get-ChildItem -Path $InstallDir -Filter "*.db" -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $release = Get-LatestReleaseAsset
    $exe = Join-Path $InstallDir "upload_script.exe"
    Download-File -Url $release.Url -Dest $exe

    $cfgPath = Join-Path $InstallDir "config.json"
    Update-ConfigIfNeeded -CfgPath $cfgPath

    Write-Host "Starting service..."
    & $nssm start $ServiceName | Out-Null
    Write-Host "Upgrade complete. Now running release: $($release.Tag)"
}

function Do-Uninstall {
    Require-Admin
    if (Service-Exists) {
        $nssm = Join-Path $InstallDir "nssm.exe"
        if (-not (Test-Path $nssm)) { $nssm = Ensure-Nssm }
        Write-Host "Stopping service..."
        & $nssm stop $ServiceName | Out-Null
        Write-Host "Removing service..."
        & $nssm remove $ServiceName confirm | Out-Null
    } else {
        Write-Host "Service '$ServiceName' not registered."
    }
    Write-Host "Install directory left untouched at $InstallDir (delete manually if desired)."
}

function Do-ServiceAction {
    param([string]$Verb)
    Require-Admin
    $nssm = Join-Path $InstallDir "nssm.exe"
    if (-not (Test-Path $nssm)) { throw "NSSM not found at $nssm. Run -Action install first." }
    & $nssm $Verb $ServiceName
}

function Do-Status {
    if (Service-Exists) {
        Get-Service -Name $ServiceName | Format-Table Name, Status, StartType -AutoSize
    } else {
        Write-Host "Service '$ServiceName' not registered."
    }
    $log = Join-Path $InstallDir "uploader_log.log"
    if (Test-Path $log) {
        Write-Host ""
        Write-Host "Last 10 lines of $log :"
        Get-Content -Path $log -Tail 10
    }
}

function Do-Logs {
    $log = Join-Path $InstallDir "uploader_log.log"
    if (-not (Test-Path $log)) { throw "Log file not found: $log" }
    Write-Host "Tailing $log  (Ctrl+C to stop)"
    Get-Content -Path $log -Wait -Tail 50
}

switch ($Action) {
    "auto" {
        if (Service-Exists) { Do-Upgrade } else { Do-Install }
    }
    "install"   { Do-Install }
    "upgrade"   { Do-Upgrade }
    "uninstall" { Do-Uninstall }
    "start"     { Do-ServiceAction -Verb "start" }
    "stop"      { Do-ServiceAction -Verb "stop" }
    "restart"   { Do-ServiceAction -Verb "restart" }
    "status"    { Do-Status }
    "logs"      { Do-Logs }
}
