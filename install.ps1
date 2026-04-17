<#
.SYNOPSIS
  Install, upgrade, or manage the NTAScanUploader Windows service (WinSW-based).

.DESCRIPTION
  Run from an elevated PowerShell:

    # Install or upgrade (auto-detects existing service)
    irm https://raw.githubusercontent.com/GetSamAI/NTAScanUploader-dist/main/install.ps1 | iex

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
    [string]$InstallDir  = "D:\ScanUploader",
    [string]$ServiceName = "NTAScanUploader",
    [string]$ApiKey,
    [string]$BaseUrl,
    [string]$DeviceCode,
    [string]$WatchPath,
    [switch]$SkipConfig,
    [string]$GitHubRepo  = "GetSamAI/NTAScanUploader-dist",
    [string]$WinSWUrl    = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
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

function Get-WinSWPath {
    # WinSW convention: the wrapper executable and its XML config must share the
    # same base name. We name them after the service so the XML is self-describing.
    return Join-Path $InstallDir "$ServiceName.exe"
}

function Get-WinSWConfigPath {
    return Join-Path $InstallDir "$ServiceName.xml"
}

function Ensure-WinSW {
    $winsw = Get-WinSWPath
    if (Test-Path $winsw) { return $winsw }

    Write-Host "Downloading WinSW from $WinSWUrl ..."
    Invoke-WebRequest -Uri $WinSWUrl -OutFile $winsw -UseBasicParsing
    return $winsw
}

function Write-WinSWConfig {
    # Produces D:\ScanUploader\NTAScanUploader.xml — the WinSW service config
    # that wraps upload_script.exe with auto-restart on any non-graceful exit.
    $cfg = Get-WinSWConfigPath
    $xml = @"
<service>
  <id>$ServiceName</id>
  <name>NTA Scan Uploader</name>
  <description>Uploads scanner results to the NTA backend</description>
  <executable>%BASE%\upload_script.exe</executable>
  <workingdirectory>%BASE%</workingdirectory>
  <priority>Normal</priority>
  <stoptimeout>30 sec</stoptimeout>
  <stopparentprocessfirst>true</stopparentprocessfirst>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <resetfailure>1 hour</resetfailure>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
</service>
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cfg, $xml, $utf8NoBom)
    return $cfg
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

function Wait-ServiceStopped {
    param([int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -eq $svc -or $svc.Status -eq "Stopped") { return }
        if ((Get-Date) -gt $deadline) {
            throw "Service '$ServiceName' did not stop within $TimeoutSeconds seconds."
        }
        Start-Sleep -Milliseconds 500
    }
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
    $winsw = Ensure-WinSW
    Write-WinSWConfig | Out-Null

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

    Write-Host "Registering service '$ServiceName' with WinSW..."
    & $winsw install | Out-Null

    if ($configFilledIn) {
        Write-Host "Starting service..."
        & $winsw start | Out-Null
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
    Write-Host "  .\install.ps1 -Action stop      (or: Stop-Service $ServiceName)"
    Write-Host "  .\install.ps1 -Action start     (or: Start-Service $ServiceName)"
    Write-Host "  .\install.ps1 -Action restart   (run after editing config.json)"
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
    $winsw = Ensure-WinSW

    Write-Host "Stopping service..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Wait-ServiceStopped -TimeoutSeconds 30

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

    # Refresh the WinSW config in case the installer shipped new service settings
    Write-WinSWConfig | Out-Null

    $cfgPath = Join-Path $InstallDir "config.json"
    Update-ConfigIfNeeded -CfgPath $cfgPath

    Write-Host "Starting service..."
    Start-Service -Name $ServiceName
    Write-Host "Upgrade complete. Now running release: $($release.Tag)"
}

function Do-Uninstall {
    Require-Admin
    if (Service-Exists) {
        $winsw = Get-WinSWPath
        if (-not (Test-Path $winsw)) { $winsw = Ensure-WinSW }
        Write-Host "Stopping service..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Wait-ServiceStopped -TimeoutSeconds 30
        Write-Host "Removing service..."
        & $winsw uninstall | Out-Null
    } else {
        Write-Host "Service '$ServiceName' not registered."
    }
    Write-Host "Install directory left untouched at $InstallDir (delete manually if desired)."
}

function Do-ServiceAction {
    param([string]$Verb)
    Require-Admin
    if (-not (Service-Exists)) {
        throw "Service '$ServiceName' is not registered. Run the installer first."
    }
    switch ($Verb) {
        "start"   { Start-Service   -Name $ServiceName }
        "stop"    { Stop-Service    -Name $ServiceName -Force }
        "restart" { Restart-Service -Name $ServiceName -Force }
    }
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
