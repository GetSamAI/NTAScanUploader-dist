# NTAScanUploader — Distribution

Public distribution channel for the **NTAScanUploader** Windows service. The source code lives in a private repository; this repo exists so the installer and release binaries can be fetched without authentication.

## Install on Windows (one-liner)

Open PowerShell **as administrator** and run:

```powershell
irm https://raw.githubusercontent.com/GetSamAI/NTAScanUploader-dist/main/install.ps1 | iex
```

On first run, the installer downloads NSSM + the latest `upload_script.exe`, creates the `NTAScanUploader` Windows service (auto-restart on crash), and prompts for the four config values it needs. Re-running the same command on an existing install performs an in-place upgrade and migrates any new config keys.

### Install without entering config values yet

```powershell
irm https://raw.githubusercontent.com/GetSamAI/NTAScanUploader-dist/main/install.ps1 -OutFile install.ps1
.\install.ps1 -SkipConfig
# Then edit D:\NTAScanUploader\config.json and fill in:
#   - api_key
#   - base_url
#   - deviceCode
# Everything else is pre-filled with sensible defaults.
.\install.ps1 -Action start
```

### Manage the service

```powershell
.\install.ps1 -Action stop
.\install.ps1 -Action start
.\install.ps1 -Action restart
.\install.ps1 -Action status
.\install.ps1 -Action logs
.\install.ps1 -Action uninstall
```

Or use native tools: `nssm stop NTAScanUploader`, `services.msc`, etc.

## What this repo contains

- `install.ps1` — the installer / upgrader script
- Releases — each release contains `upload_script.exe` built by CI from the private source repo
