# ============================================================================
# dev_connect.ps1 — restore the phone -> laptop Supabase tunnel.
# Run after ANY phone replug, reboot, adb restart, or transport switch
# (USB <-> wireless). Usage:  .\tools\dev_connect.ps1   (or dev_connect.bat)
# ============================================================================
$ErrorActionPreference = 'Continue'

# --- 1. Locate adb (PATH first, then the default Android SDK location) ------
$adbCmd = Get-Command adb -ErrorAction SilentlyContinue
if ($adbCmd) {
    $adb = $adbCmd.Source
} else {
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $candidate) {
        $adb = $candidate
    } else {
        Write-Host 'ERROR: adb not found on PATH or in %LOCALAPPDATA%\Android\Sdk\platform-tools.' -ForegroundColor Red
        Write-Host 'Find it with:  Get-ChildItem -Path $env:LOCALAPPDATA -Recurse -Filter adb.exe -ErrorAction SilentlyContinue'
        exit 1
    }
}
Write-Host "Using adb: $adb"

# --- 2. Devices; drop stale wireless entries if they cause ambiguity --------
$devices = (& $adb devices) | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' }
Write-Host "Connected devices: $($devices.Count)"
$devices | ForEach-Object { Write-Host "  $_" }

if ($devices.Count -eq 0) {
    Write-Host 'ERROR: no device. Plug in the phone (check USB-debugging prompt) and rerun.' -ForegroundColor Red
    exit 1
}
if ($devices.Count -gt 1) {
    Write-Host 'Multiple devices - disconnecting stale wireless entries...' -ForegroundColor Yellow
    & $adb disconnect | Out-Null
    Start-Sleep -Seconds 1
    $devices = (& $adb devices) | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' }
    if ($devices.Count -ne 1) {
        Write-Host 'Still ambiguous. Unplug/replug USB or disable wireless debugging, then rerun.' -ForegroundColor Red
        exit 1
    }
}

# --- 3. The tunnel: phone's 127.0.0.1:54321 -> laptop's 127.0.0.1:54321 ------
& $adb reverse tcp:54321 tcp:54321
Write-Host 'Active reverse tunnels:'
& $adb reverse --list

# --- 4. Laptop side: is the Supabase API actually listening? -----------------
$api = Test-NetConnection -ComputerName 127.0.0.1 -Port 54321 -InformationLevel Quiet -WarningAction SilentlyContinue
if ($api) {
    Write-Host 'OK: Supabase API reachable on laptop port 54321.' -ForegroundColor Green
    Write-Host 'Phone -> laptop path is ready. Retry the app now.'
} else {
    Write-Host 'WARNING: nothing listening on 54321. Is Docker running and `supabase start` done?' -ForegroundColor Yellow
}
