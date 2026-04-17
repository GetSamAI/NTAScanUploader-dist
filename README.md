# NTAScanUploader — Distribution

Public distribution channel for the **NTAScanUploader** Windows service. The source code lives in a private repository; this repo exists so the installer and release binaries can be fetched without authentication.

## Install on Windows (one-liner)

Open PowerShell **as administrator** and run:

```powershell
irm https://raw.githubusercontent.com/GetSamAI/NTAScanUploader-dist/main/install.ps1 | iex
```

On first run, the installer downloads [WinSW](https://github.com/winsw/winsw) (a maintained Windows service wrapper — also used by Jenkins) + the latest `upload_script.exe`, creates the `NTAScanUploader` Windows service with auto-restart on crash, and prompts for the four config values it needs. Re-running the same command on an existing install performs an in-place upgrade and migrates any new config keys — your existing values are preserved.

### Migrating from a FireDaemon-managed install

If the PC currently runs the uploader under FireDaemon (`SamScanUploadService`), stop + disable it first, then run the one-liner. The default install folder (`D:\ScanUploader`) matches FireDaemon's, so the existing `config.json` is reused in place.

```powershell
Stop-Service -Name "SamScanUploadService"
Set-Service  -Name "SamScanUploadService" -StartupType Disabled
irm https://raw.githubusercontent.com/GetSamAI/NTAScanUploader-dist/main/install.ps1 | iex
```

FireDaemon's service stays registered but disabled — a dormant rollback. To roll back:

```powershell
Stop-Service NTAScanUploader
Set-Service  SamScanUploadService -StartupType Automatic
Start-Service SamScanUploadService
```

### Install without entering config values yet

```powershell
irm https://raw.githubusercontent.com/GetSamAI/NTAScanUploader-dist/main/install.ps1 -OutFile install.ps1
.\install.ps1 -SkipConfig
# Edit D:\ScanUploader\config.json:
#   - api_key
#   - base_url
#   - deviceCode
# Everything else is pre-filled with sensible defaults.
.\install.ps1 -Action start
```

### After editing `config.json`, restart the service

```powershell
.\install.ps1 -Action restart
# or: Restart-Service NTAScanUploader
# or: services.msc → right-click "NTAScanUploader" → Restart
```

### Manage the service

```powershell
.\install.ps1 -Action stop
.\install.ps1 -Action start
.\install.ps1 -Action restart
.\install.ps1 -Action status
.\install.ps1 -Action logs        # tails uploader_log.log
.\install.ps1 -Action uninstall   # removes the service (keeps the folder)
```

Or use Windows' native tools — WinSW registers a standard Windows service, so `Start-Service NTAScanUploader`, `services.msc`, etc. all work.

### Default paths

| Thing          | Path                                                 |
|----------------|------------------------------------------------------|
| Install folder | `D:\ScanUploader`                                    |
| Service name   | `NTAScanUploader`                                    |
| Config file    | `D:\ScanUploader\config.json`                        |
| App log        | `D:\ScanUploader\uploader_log.log` (UTF-8, rotated)  |
| WinSW wrapper  | `D:\ScanUploader\NTAScanUploader.exe` + `.xml`       |
| WinSW logs     | `D:\ScanUploader\NTAScanUploader.out.log` / `.err.log` / `.wrapper.log` |

Override with `-InstallDir` or `-ServiceName` on any command.

### Verify the install

From any folder (doesn't need to `cd` into the install dir):

```powershell
# Is the service registered and running?
Get-Service NTAScanUploader

# Will it auto-start on reboot? (Expect: StartType = Automatic)
Get-Service NTAScanUploader | Select-Object Name, Status, StartType

# Tail the app log to see it processing files
Get-Content D:\ScanUploader\uploader_log.log -Wait -Tail 20
```

Or, from inside `D:\ScanUploader`: `.\install.ps1 -Action status` (shows service state + last 10 log lines) and `.\install.ps1 -Action logs` (live tail).

## What this repo contains

- `install.ps1` — the installer / upgrader script (mirrored from the private source repo on every build)
- Releases — each release contains `upload_script.exe` built by CI
