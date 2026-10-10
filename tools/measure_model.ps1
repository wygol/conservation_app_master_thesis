<#
.SYNOPSIS
  On-device measurement round of the thesis' offline model (ADR 009; objectives O3a-O3c).

.DESCRIPTION
  One command, no taps. In order:
    1. finds adb + flutter, checks exactly one phone is connected;
    2. records device facts via adb (model, Android, SoC, CPU topology, battery, thermal);
    3. flutter pub get, flutter analyze (stops on errors), unit tests test/ml (stops on failure);
    4. builds the RELEASE APK (as shipped) with --dart-define=MODEL_LAB_AUTORUN=true;
    5. O3a: reads the model entry from inside the APK (size, stored size, SHA-256);
    6. installs, keeps the screen on, starts the app in a fresh process: it opens the model lab
       and runs the protocol by itself (correctness -> O3b -> O3c -> 12 MP image);
    7. while the app classifies, samples `dumpsys meminfo` (never during latency runs);
    8. reassembles the app's report from logcat and verifies its SHA-256;
    9. attributes the XNNPACK log line to an interpreter (was XNNPACK applied by default?);
   10. if it was (or with -ForceBenchmarkTool): runs Google's TFLite Benchmark Tool with
       --use_xnnpack=false under taskset on the same cores, as an independent cross-check;
   11. writes everything to docs/measurements/<date>_arm2_phone/raw/<timestamp>/.

  Supabase/Docker are NOT needed. Connect the phone by USB cable, unlock it, leave it alone.

.PARAMETER SkipBuild           Reuse the last APK in build/app/outputs/flutter-apk.
.PARAMETER ForceBenchmarkTool  Run the Benchmark Tool cross-check even if not needed.
.PARAMETER SkipBenchmarkTool   Never run it.
.PARAMETER TimeoutMinutes      Give up waiting for the app after this long (default 15).
.PARAMETER NoPrompt            Do not wait for Enter after "unlock the phone" (for runs started by an
                               agent or another script). The phone must ALREADY be unlocked: the app
                               starts the protocol only after its first frame is visible.
#>
param(
    [switch]$SkipBuild,
    [switch]$ForceBenchmarkTool,
    [switch]$SkipBenchmarkTool,
    [switch]$NoPrompt,
    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Continue'   # native tools write normal output to stderr
$ScriptVersion = '1.2 (2026-10-10)'
$Package = 'com.example.conservation_app'
$Activity = "$Package/.MainActivity"
$ExpectedModelSha = 'e0e182a8fbbc75fc632840bdc59bbf004d7179350f5d630691a28522748eb12d'
$ModelEntry = 'assets/flutter_assets/assets/model/large075_plain_int8_weight_only.tflite'
$BenchUrl = 'https://storage.googleapis.com/tensorflow-nightly-public/prod/tensorflow/release/lite/tools/nightly/latest/android_aarch64_benchmark_model'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$Day = Get-Date -Format 'yyyy-MM-dd'
$OutDir = Join-Path $RepoRoot "docs\measurements\${Day}_arm2_phone\raw\$Stamp"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Say([string]$Message, [string]$Color = 'Gray') { Write-Host $Message -ForegroundColor $Color }
function Step([string]$Message) { Write-Host ''; Write-Host "== $Message" -ForegroundColor Cyan }
function Fail([string]$Message) {
    Write-Host "STOPPED: $Message" -ForegroundColor Red
    Write-Host "Logs of this run: $OutDir" -ForegroundColor Yellow
    exit 1
}
# In Windows PowerShell 5.1, a native tool's stderr lines arrive as ErrorRecords when
# redirected with 2>&1; an empty one would print as "System.Management.Automation.RemoteException".
function LineOf($Item) {
    if ($Item -is [System.Management.Automation.ErrorRecord]) { return $Item.Exception.Message }
    return "$Item"
}
function Lines($Output) { return @($Output | ForEach-Object { LineOf $_ }) }
# Runs a native command, shows its output LIVE, saves it as UTF-8 (Tee-Object in 5.1 would
# write UTF-16), and returns the exit code.
function Invoke-Logged([string]$LogName, [scriptblock]$Command) {
    & $Command 2>&1 | ForEach-Object { $l = LineOf $_; Write-Host $l; $l } |
        Set-Content -Path (Join-Path $OutDir $LogName) -Encoding UTF8
    return $LASTEXITCODE
}
function Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Sha256OfFile([string]$Path) { return Sha256Hex ([System.IO.File]::ReadAllBytes($Path)) }
function Save-Json($Object, [string]$Name) {
    $json = $Object | ConvertTo-Json -Depth 14
    [System.IO.File]::WriteAllText((Join-Path $OutDir $Name), $json, (New-Object System.Text.UTF8Encoding($false)))
}

Say "Logs of this run: $OutDir" 'DarkGray'

# ----------------------------------------------------------------- 1. tools
Step 'Locating adb and flutter'
$adbCmd = Get-Command adb -ErrorAction SilentlyContinue
if ($adbCmd) { $Adb = $adbCmd.Source }
else {
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $candidate) { $Adb = $candidate } else { Fail 'adb not found (PATH or %LOCALAPPDATA%\Android\Sdk\platform-tools).' }
}
Say "adb: $Adb"
if (-not $SkipBuild) {
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { Fail 'flutter is not on PATH.' }
}

function AdbShell([string]$Command) {
    return ((Lines (& $Adb shell $Command 2>&1)) -join "`n")
}

# ---------------------------------------------------------------- 2. device
Step 'Checking the device'
$devices = @(Lines (& $Adb devices 2>&1) | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' })
if ($devices.Count -eq 0) { Fail 'No device. Connect the S22 by USB cable, unlock it and accept the USB-debugging prompt.' }
if ($devices.Count -gt 1) { Fail "More than one device ($($devices -join '; ')). Run 'adb disconnect' or unplug extras." }
$Serial = ($devices[0] -split "`t")[0]
Say "device: $Serial"
if ($Serial -match ':') { Say 'Wireless adb detected - a USB cable gives steadier timing. Continuing.' 'Yellow' }

Step 'Recording device facts'
$props = [ordered]@{}
foreach ($p in @('ro.product.manufacturer', 'ro.product.model', 'ro.product.device', 'ro.product.name',
        'ro.build.version.release', 'ro.build.version.sdk', 'ro.build.display.id',
        'ro.build.version.security_patch', 'ro.soc.manufacturer', 'ro.soc.model',
        'ro.board.platform', 'ro.hardware', 'ro.product.cpu.abi')) {
    $props[$p] = (AdbShell "getprop $p").Trim()
}
$cpuMax = [ordered]@{}
for ($i = 0; $i -lt 16; $i++) {
    $v = (AdbShell "cat /sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq 2>/dev/null").Trim()
    if ($v -match '^\d+$') { $cpuMax["cpu$i"] = [int64]$v }
}
$device = [ordered]@{
    serial            = $Serial
    getprop           = $props
    cpu_max_freq_khz  = $cpuMax
    proc_cpuinfo      = AdbShell 'cat /proc/cpuinfo'
    battery_at_start  = AdbShell 'dumpsys battery'
    thermal_at_start  = ((AdbShell 'dumpsys thermalservice') -split "`n" | Select-Object -First 40) -join "`n"
    uptime_at_start   = AdbShell 'uptime'
    recorded_local    = (Get-Date).ToString('o')
}
Say ("{0} {1}, Android {2} (SDK {3}), SoC {4} {5}" -f $props['ro.product.manufacturer'], $props['ro.product.model'],
    $props['ro.build.version.release'], $props['ro.build.version.sdk'], $props['ro.soc.manufacturer'], $props['ro.soc.model'])

# ------------------------------------------------------------ 3./4. build
$toolchain = [ordered]@{}
if (-not $SkipBuild) {
    Push-Location $RepoRoot
    try {
        Step 'flutter pub get'
        if ((Invoke-Logged 'flutter_pub_get.txt' { flutter pub get }) -ne 0) { Fail 'flutter pub get failed (output above, also in flutter_pub_get.txt).' }

        Step 'flutter analyze'
        # The exit code is not used: flutter analyze also exits non-zero for infos.
        $null = Invoke-Logged 'flutter_analyze.txt' { flutter analyze }
        $analyze = @(Get-Content -Path (Join-Path $OutDir 'flutter_analyze.txt') -Encoding UTF8)
        $errors = @($analyze | Where-Object { $_ -match '^\s*error\s' })
        $warnings = @($analyze | Where-Object { $_ -match '^\s*warning\s' })
        $infos = @($analyze | Where-Object { $_ -match '^\s*info\s' })
        $toolchain.analyze = [ordered]@{ errors = $errors.Count; warnings = $warnings.Count; infos = $infos.Count }
        Say "analyze: $($errors.Count) errors, $($warnings.Count) warnings, $($infos.Count) infos (saved)"
        if ($errors.Count -gt 0) { $errors | Out-Host; Fail 'flutter analyze reports errors - paste them to the agent.' }

        Step 'Unit tests: test/ml'
        if ((Invoke-Logged 'flutter_test_ml.txt' { flutter test test/ml }) -ne 0) { Fail 'Unit tests failed - see flutter_test_ml.txt in the logs folder.' }
        $toolchain.unit_tests = 'passed'

        # Universal APK on purpose: --split-per-abi would raise the versionCode
        # (arm64 -> 2001), and the next normal `flutter run` would then be refused
        # as a downgrade and uninstall the app (losing its local login).
        Step 'Building the release APK (as shipped) with MODEL_LAB_AUTORUN=true'
        if ((Invoke-Logged 'flutter_build.txt' { flutter build apk --release --dart-define=MODEL_LAB_AUTORUN=true }) -ne 0) {
            Fail 'Build failed - the full output is in flutter_build.txt in the logs folder.'
        }
        $toolchain.flutter_version = ((Lines (& flutter --version 2>&1)) -join "`n")
    }
    finally { Pop-Location }
}

# ------------------------------------------------------------------ 5. O3a
Step 'O3a - the model as shipped inside the APK'
$Apk = Join-Path $RepoRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $Apk)) { Fail "APK not found: $Apk" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$entries = New-Object System.Collections.ArrayList
$zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    foreach ($e in $zip.Entries) {
        $n = $e.FullName
        if (-not ($n -like 'assets/flutter_assets/assets/model*' -or $n -like 'lib/arm64-v8a/*.so')) { continue }
        $row = [ordered]@{ name = $n; uncompressed_bytes = $e.Length; stored_bytes = $e.CompressedLength;
            stored_without_compression = ($e.Length -eq $e.CompressedLength) }
        if ($n -eq $ModelEntry) {
            $stream = $e.Open()
            try { $ms = New-Object System.IO.MemoryStream; $stream.CopyTo($ms); $row.sha256 = Sha256Hex ($ms.ToArray()) }
            finally { $stream.Close() }
        }
        [void]$entries.Add($row)
    }
}
finally { $zip.Dispose() }
$modelRow = $entries | Where-Object { $_.name -eq $ModelEntry } | Select-Object -First 1
if (-not $modelRow) { Fail "The model is not inside the APK ($ModelEntry)." }
$apkInfo = [ordered]@{
    apk                       = 'build/app/outputs/flutter-apk/app-release.apk (universal: all ABIs; the phone uses lib/arm64-v8a)'
    apk_bytes                 = (Get-Item $Apk).Length
    apk_sha256                = Sha256OfFile $Apk
    model_entry               = $modelRow
    model_sha256_matches      = ($modelRow.sha256 -eq $ExpectedModelSha)
    model_file_in_repo_bytes  = (Get-Item (Join-Path $RepoRoot 'assets\model\large075_plain_int8_weight_only.tflite')).Length
    entries                   = $entries
    note                      = 'stored_without_compression is inferred from equal stored and uncompressed sizes'
}
Say ("model in APK: {0:N0} bytes ({1:N2} MB), stored {2:N0} bytes, SHA-256 {3}" -f $modelRow.uncompressed_bytes,
    ($modelRow.uncompressed_bytes / 1e6), $modelRow.stored_bytes, $(if ($apkInfo.model_sha256_matches) { 'matches the thesis file' } else { 'DOES NOT MATCH' }))

# -------------------------------------------------------- 6. install + run
Step 'Installing the measurement build'
$install = Lines (& $Adb install -r $Apk 2>&1)
$install | Out-Host
if (($install -join ' ') -notmatch 'Success') {
    Fail 'Install failed. If it says INSTALL_FAILED_UPDATE_INCOMPATIBLE, uninstall the app on the phone first (only its local login is lost) and rerun.'
}

$stayOnBefore = (AdbShell 'settings get global stay_on_while_plugged_in').Trim()
& $Adb shell svc power stayon true | Out-Null
& $Adb shell input keyevent KEYCODE_WAKEUP | Out-Null
Say ''
Say 'Unlock the phone now and leave it untouched on the desk until this script prints DONE.' 'Yellow'
if ($NoPrompt) { Say '-NoPrompt: assuming the phone is already unlocked.' 'Yellow'; Start-Sleep -Seconds 3 }
else { Read-Host 'Press Enter when the phone is unlocked' }

# The full device log contains other apps' messages, so it stays in the git-ignored
# cache; only the app's own lines are copied into the results folder.
$CacheDir = Join-Path $RepoRoot 'tools\.cache'
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$LogFile = Join-Path $CacheDir "logcat_full_$Stamp.txt"
& $Adb logcat -c 2>&1 | Out-Null
$logProc = Start-Process -FilePath $Adb -ArgumentList @('logcat', '-v', 'epoch') -RedirectStandardOutput $LogFile `
    -RedirectStandardError (Join-Path $CacheDir "logcat_stderr_$Stamp.txt") -NoNewWindow -PassThru
Start-Sleep -Milliseconds 1000

# logcat -v epoch: "<seconds.millis>  <pid>  <tid> <level> <tag>: <message>"
function PidOf([string]$l) {
    if ($l -match '^\s*\d+\.\d+\s+(\d+)\s+\d+\s+[VDIWEFA]\s') { return $Matches[1] }
    return $null
}

function Get-MemInfo {
    $t = (Get-Date).ToString('o')
    $text = (Lines (& $Adb shell dumpsys meminfo $Package 2>&1)) -join "`n"
    $info = [ordered]@{ t = $t; total_pss_kb = $null; total_rss_kb = $null; graphics_kb = $null; native_heap_kb = $null; java_heap_kb = $null }
    if ($text -match 'TOTAL PSS:\s*([\d,]+)') { $info.total_pss_kb = [int]($Matches[1] -replace ',', '') }
    elseif ($text -match '(?m)^\s*TOTAL\s+([\d,]+)') { $info.total_pss_kb = [int]($Matches[1] -replace ',', '') }
    if ($text -match 'TOTAL RSS:\s*([\d,]+)') { $info.total_rss_kb = [int]($Matches[1] -replace ',', '') }
    if ($text -match '(?m)^\s*Graphics:\s*([\d,]+)') { $info.graphics_kb = [int]($Matches[1] -replace ',', '') }
    if ($text -match '(?m)^\s*Native Heap:\s*([\d,]+)') { $info.native_heap_kb = [int]($Matches[1] -replace ',', '') }
    if ($text -match '(?m)^\s*Java Heap:\s*([\d,]+)') { $info.java_heap_kb = [int]($Matches[1] -replace ',', '') }
    $info.raw = $text
    return $info
}

$snapshots = New-Object System.Collections.ArrayList
$samples = New-Object System.Collections.ArrayList
# The runtime's own error lines (logcat tag "tflite", level E/F, the app's process only).
# The app itself only sees e.g. "Bad state: failed precondition"; the reason is logged here.
$runtimeErrors = New-Object System.Collections.ArrayList
$chunks = @{}
$header = $null
$done = $false
$crashed = $false
$sampling = $null
$script:pending = ''

try {
    Step 'Starting the app (fresh process) - the protocol runs by itself'
    & $Adb shell am force-stop $Package | Out-Null
    Lines (& $Adb shell am start -W -n $Activity 2>&1) | Out-Host
    $AppPid = $null
    for ($k = 0; $k -lt 10 -and -not $AppPid; $k++) {
        $p = (AdbShell "pidof $Package").Trim()
        if ($p -match '^\d+') { $AppPid = ($p -split '\s+')[0] } else { Start-Sleep -Milliseconds 500 }
    }
    Say "app process id: $AppPid"

    $fs = New-Object System.IO.FileStream($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while (-not $done -and (Get-Date) -lt $deadline) {
        $chunk = $reader.ReadToEnd()
        $newLines = @()
        if ($chunk) {
            $script:pending += $chunk
            $parts = $script:pending -split "`n"
            $script:pending = $parts[-1]
            if ($parts.Count -gt 1) { $newLines = $parts[0..($parts.Count - 2)] }
        }
        foreach ($raw in $newLines) {
            $line = $raw.TrimEnd("`r")
            # Only the app's own crashes count (Java or native), plus the system's
            # "process has died" line about it; other processes' crashes are ignored.
            $linePid = PidOf $line
            $ownCrash = ($AppPid -and $linePid -eq $AppPid -and $line -match 'FATAL EXCEPTION|Fatal signal')
            $died = ($line -match ('Process ' + [regex]::Escape($Package) + ' \(pid \d+\) has died'))
            if ($ownCrash -or $died) {
                $crashed = $true; $done = $true; Say "APP CRASHED: $line" 'Red'
            }
            if ($AppPid -and $linePid -eq $AppPid -and $line -match '^\s*\d+\.\d+\s+\d+\s+\d+\s+[EF]\s+tflite\s*:\s?(.*)$') {
                $runtimeMessage = $Matches[1]
                [void]$runtimeErrors.Add($runtimeMessage)
                Say ('  RUNTIME ERROR (tflite): ' + $runtimeMessage) 'Red'
            }
            if ($line -notmatch 'MODEL_LAB\|(.*)$') { continue }
            $payload = $Matches[1]
            $f = $payload -split '\|'
            switch ($f[0]) {
                'PROGRESS' { Say ('  ' + $payload.Substring(9)) }
                'SNAPSHOT' {
                    $m = Get-MemInfo; $m.name = $f[1]; [void]$snapshots.Add($m)
                    Say ("  snapshot {0}: TOTAL PSS {1} kB" -f $f[1], $m.total_pss_kb)
                }
                'PHASE' {
                    if ($f[2] -eq 'START' -and ($f[1] -eq 'O3B_CLASSIFY' -or $f[1] -eq 'BIGIMG_CLASSIFY')) { $sampling = $f[1] }
                    elseif ($f[2] -eq 'END' -and $sampling -eq $f[1]) { $sampling = $null }
                }
                'DONE' { Say '  app reports DONE - collecting the report' 'Green' }
                'ERROR' { Say ('  APP ERROR (a partial report follows): ' + $payload.Substring(6)) 'Red' }
                'REPORT' {
                    if ($f[1] -eq 'BEGIN') { $header = @{ count = [int]$f[2]; sha = $f[3]; bytes = [int]$f[4] } }
                    elseif ($f[1] -eq 'END') { $done = $true }
                    else { $chunks[[int]$f[1]] = $f[2] }
                }
            }
        }
        if ($sampling) {
            $m = Get-MemInfo; $m.phase = $sampling; $m.Remove('raw'); [void]$samples.Add($m)
        }
        else { Start-Sleep -Milliseconds 250 }
    }
    $reader.Close()
}
finally {
    if ($logProc -and -not $logProc.HasExited) { Stop-Process -Id $logProc.Id -Force -ErrorAction SilentlyContinue }
    if ($stayOnBefore -match '^\d+$') { & $Adb shell settings put global stay_on_while_plugged_in $stayOnBefore | Out-Null }
}
$device.battery_at_end = AdbShell 'dumpsys battery'
$device.thermal_at_end = ((AdbShell 'dumpsys thermalservice') -split "`n" | Select-Object -First 40) -join "`n"

if ($crashed) { Fail "The app crashed - the device log is saved at $LogFile; tell the agent." }
if (-not $done) { Fail "Timed out after $TimeoutMinutes min without a complete report (device log: $LogFile)." }

# -------------------------------------------------------- 8. reassemble
Step 'Reassembling the app report'
$b64 = New-Object System.Text.StringBuilder
for ($i = 1; $i -le $header.count; $i++) {
    if (-not $chunks.ContainsKey($i)) { Fail "Report chunk $i of $($header.count) missing from logcat - rerun." }
    [void]$b64.Append($chunks[$i])
}
$reportBytes = [Convert]::FromBase64String($b64.ToString())
$reportSha = Sha256Hex $reportBytes
$reportOk = ($reportSha -eq $header.sha -and $reportBytes.Length -eq $header.bytes)
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'report_app.json'), $reportBytes)
if (-not $reportOk) { Fail 'Report checksum mismatch - chunks were lost; rerun.' }
$report = [System.Text.Encoding]::UTF8.GetString($reportBytes) | ConvertFrom-Json
Say "report: $($reportBytes.Length) bytes, SHA-256 verified" 'Green'

# ------------------------------------------- 9. XNNPACK attribution (logcat)
Step 'Attributing the XNNPACK log line'
$allLines = Get-Content -Path $LogFile -Encoding UTF8
function EpochOf([string]$l) {
    if ($l -match '^\s*(\d+\.\d+)\s') { return [double]$Matches[1] }
    return $null
}
$marks = @{}
$xnnLines = New-Object System.Collections.ArrayList
$relevant = New-Object System.Collections.ArrayList
foreach ($l in $allLines) {
    $fromApp = ($AppPid -and (PidOf $l) -eq $AppPid)
    if ($l -match 'MODEL_LAB\|IFACE_CREATE\|(C\d)\|(START|END)') { $marks["$($Matches[1])_$($Matches[2])"] = EpochOf $l }
    # Any TFLite user on the phone logs this line once per process: only the app's own count.
    # [string]: a line from Get-Content carries PowerShell 5.1 file metadata (PSPath, PSDrive,
    # PSProvider ...), which ConvertTo-Json -Depth 14 would serialize as a huge object graph -
    # run 2026-10-10_120250 hung there at 5 GB of RAM before measurement.json was written.
    if ($fromApp -and $l -match '(?i)xnnpack') { [void]$xnnLines.Add([ordered]@{ epoch = (EpochOf $l); line = [string]$l }) }
    if (($fromApp -and $l -notmatch 'MODEL_LAB\|REPORT\|\d') -or $l -match [regex]::Escape($Package)) {
        [void]$relevant.Add($l)
    }
}
# The app's own log lines only (no other apps' messages) - safe to keep with the results.
$relevant | Set-Content -Path (Join-Path $OutDir 'logcat_app.txt') -Encoding UTF8
$verdict = 'undetermined'
$createdLine = $xnnLines | Where-Object { $_.line -match 'Created TensorFlow Lite XNNPACK delegate' } | Select-Object -First 1
# C2 is the only interpreter that adds XNNPACK explicitly, and C1 is the only one that
# exists before C2 is created. So the once-per-process creation line, if it appears
# after C1 started but before C2 started (at creation OR lazily at C1's first invoke),
# can only come from C1.
if ($marks.ContainsKey('C1_START')) {
    $c2Start = [double]::MaxValue
    if ($marks.ContainsKey('C2_START')) { $c2Start = $marks['C2_START'] }
    if (-not $createdLine) { $verdict = 'no_xnnpack_line_seen' }
    elseif ($createdLine.epoch -ge $marks['C1_START'] -and $createdLine.epoch -lt $c2Start) { $verdict = 'default' }
    elseif ($createdLine.epoch -ge $c2Start) { $verdict = 'not_default' }
}
$c1Valid = $true
if ($report.runtime.c1_created_in_this_run -ne $true) { $c1Valid = $false }
$attribution = [ordered]@{
    verdict = $verdict
    meaning = @{ default = 'LiteRT applied XNNPACK by default to the interpreter that added no delegate (C1): C1 is NOT a no-delegate configuration';
        not_default = 'C1 created no XNNPACK delegate; the first XNNPACK instantiation was the explicit C2: C1 IS the no-delegate configuration';
        no_xnnpack_line_seen = 'no XNNPACK creation line in logcat at all (log level or message changed?) - rely on the latency comparison';
        undetermined = 'markers missing' }[$verdict]
    c1_created_fresh_in_this_process = $c1Valid
    app_pid = $AppPid
    marker_epochs = $marks
    xnnpack_lines = $xnnLines
    latency_based_in_app = $report.o3c_latency.xnnpack_attribution_in_app
}
Say "verdict: $verdict - $($attribution.meaning)"

# ---------------------------------------- 10. Benchmark Tool cross-check
$bench = [ordered]@{ ran = $false }
$runBench = $ForceBenchmarkTool -or ($verdict -eq 'default')
if ($SkipBenchmarkTool) { $runBench = $false }
if ($runBench) {
    Step 'Official TFLite Benchmark Tool: --use_xnnpack=false, 1 thread, taskset to one core'
    $cache = Join-Path $RepoRoot 'tools\.cache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $bin = Join-Path $cache 'android_aarch64_benchmark_model'
    if (-not (Test-Path $bin)) {
        Say "downloading $BenchUrl"
        try { Invoke-WebRequest -Uri $BenchUrl -OutFile $bin -UseBasicParsing } catch { Say "download failed: $_" 'Yellow' }
    }
    if (Test-Path $bin) {
        $bench.ran = $true
        $bench.binary = [ordered]@{ source = $BenchUrl; sha256 = (Sha256OfFile $bin); bytes = (Get-Item $bin).Length;
            downloaded = (Get-Item $bin).LastWriteTime.ToString('o') }
        & $Adb push $bin /data/local/tmp/benchmark_model 2>&1 | Out-Null
        & $Adb shell chmod 755 /data/local/tmp/benchmark_model | Out-Null
        & $Adb push (Join-Path $RepoRoot 'assets\model\large075_plain_int8_weight_only.tflite') /data/local/tmp/arm2_int8_wo.tflite 2>&1 | Out-Null
        $runs = New-Object System.Collections.ArrayList
        foreach ($t in @(@{ label = 'prime'; cpu = $report.device_in_app.prime_cpu }, @{ label = 'big'; cpu = $report.device_in_app.big_cpu })) {
            if ($null -eq $t.cpu) { continue }
            $mask = '{0:x}' -f (1 -shl [int]$t.cpu)
            $cmd = "taskset $mask /data/local/tmp/benchmark_model --graph=/data/local/tmp/arm2_int8_wo.tflite --num_threads=1 --use_xnnpack=false --warmup_runs=20 --num_runs=100"
            Say "  $($t.label) core cpu$($t.cpu): $cmd"
            $out = AdbShell $cmd
            $r = [ordered]@{ core = $t.label; cpu = $t.cpu; command = $cmd; output = $out }
            # The tool prints a statistics line for the warm-up first and for the
            # timed runs second: take the LAST one.
            $stats = [regex]::Matches($out, 'count=(\d+) first=(\d+) curr=(\d+) min=(\d+) max=(\d+) avg=([\d.e+]+) std=(\d+)')
            if ($stats.Count -gt 0) {
                $g = $stats[$stats.Count - 1].Groups
                $r.count = [int]$g[1].Value; $r.min_us = [int]$g[4].Value; $r.max_us = [int]$g[5].Value
                $r.avg_us = [double]$g[6].Value; $r.std_us = [int]$g[7].Value
                $r.stat_lines_found = $stats.Count
            }
            [void]$runs.Add($r)
            Say ("    avg {0} us, min {1}, max {2}" -f $r.avg_us, $r.min_us, $r.max_us)
        }
        $bench.runs = $runs
        $bench.note = 'The tool prints mean/std/min/max, not median/p90; it serves as cross-check of the in-app no-delegate path.'
        & $Adb shell rm -f /data/local/tmp/benchmark_model /data/local/tmp/arm2_int8_wo.tflite | Out-Null
    }
}

# ------------------------------------------------------------ 11. outputs
$snapshotsLite = @($snapshots | ForEach-Object { $c = [ordered]@{}; foreach ($k in $_.Keys) { if ($k -ne 'raw') { $c[$k] = $_[$k] } }; $c })
$snapshots | ForEach-Object { "==== $($_.name) $($_.t)`n$($_.raw)`n" } | Set-Content -Path (Join-Path $OutDir 'dumpsys_snapshots.txt') -Encoding UTF8
function PeakOf($phase) {
    $vals = @($samples | Where-Object { $_.phase -eq $phase -and $null -ne $_.total_pss_kb } | ForEach-Object { $_.total_pss_kb })
    if ($vals.Count -eq 0) { return $null }
    return [ordered]@{ samples = $vals.Count; max_total_pss_kb = ($vals | Measure-Object -Maximum).Maximum }
}
$meminfo = [ordered]@{
    method      = "adb shell dumpsys meminfo $Package (App Summary TOTAL PSS / TOTAL RSS); sampled back-to-back while the app classifies, plus one reading per snapshot marker. Never sampled during latency runs."
    snapshots   = $snapshotsLite
    samples     = $samples
    peak_o3b    = PeakOf 'O3B_CLASSIFY'
    peak_bigimg = PeakOf 'BIGIMG_CLASSIFY'
}
$measurement = [ordered]@{
    what               = 'On-device measurement round of the Arm 2 offline model (ADR 009); raw record for the report'
    script             = [ordered]@{ path = 'tools/measure_model.ps1'; version = $ScriptVersion; sha256 = (Sha256OfFile $PSCommandPath) }
    output_dir         = $OutDir.Substring($RepoRoot.Length + 1)
    device             = $device
    toolchain          = $toolchain
    o3a_apk            = $apkInfo
    dumpsys_meminfo    = $meminfo
    xnnpack_attribution = $attribution
    benchmark_tool     = $bench
    runtime_errors_logcat = $runtimeErrors
    app_report_file    = 'report_app.json'
    app_report_sha256  = $reportSha
}
Save-Json $measurement 'measurement.json'

# -------------------------------------------------------------- summary
Step 'Summary'
if ($report.error) {
    Say ('  APP ERROR: ' + $report.error) 'Red'
    foreach ($r in $runtimeErrors) { Say ('    runtime said: ' + $r) 'Red' }
}
$cases = @($report.correctness.cases)
foreach ($c in $cases) {
    $col = 'Green'; if (-not $c.pass) { $col = 'Red' }
    Say ("  {0,-4} {1,-44} dMean {2}  top-5 {3}/5  dLogit {4}" -f $(if ($c.pass) { 'PASS' } else { 'FAIL' }), $c.image, $c.max_abs_mean_diff, $c.top5_overlap, $c.max_abs_logit_diff) $col
}
Say ("  correctness overall: {0}" -f $(if ($report.correctness.all_pass) { 'ALL PASS' } else { 'NOT ALL PASS' }))
Say ("  O3a model as shipped: {0:N2} MB (target <= 25 MB)" -f ($modelRow.uncompressed_bytes / 1e6))
if ($meminfo.peak_o3b) { Say ("  O3b peak TOTAL PSS while classifying (dumpsys): {0:N1} MiB (target <= 300 MB)" -f ($meminfo.peak_o3b.max_total_pss_kb / 1024)) }
Say ("  O3b VmHWM (peak RSS since start, upper bound): {0:N1} MiB" -f ($report.o3b_memory.vm_hwm_kb_after_loop / 1024))
foreach ($cfg in @($report.o3c_latency.configs)) {
    if ($cfg.stats) {
        $col = 'Gray'; if ($cfg.all_runs_on_pinned_cpu -ne $true) { $col = 'Red' }
        Say ("  O3c {0,-9} median {1,7:N1} ms   p90 {2,7:N1} ms   all runs on cpu{3}: {4} (pin held after {5} ms)" -f $cfg.id,
            ($cfg.stats.median_us / 1000), ($cfg.stats.p90_us / 1000), $cfg.pinned_cpu, $cfg.all_runs_on_pinned_cpu, $cfg.pin_wait_ms) $col
    }
    elseif ($cfg.error) { Say ("  O3c {0,-9} NOT MEASURED: {1}" -f $cfg.id, $cfg.error) 'Red' }
}
Say "  XNNPACK by default for C1: $verdict"
Write-Host ''
Write-Host "DONE. Results: $OutDir" -ForegroundColor Green
Write-Host 'Tell the agent the run finished - it reads the files itself and writes the report.' -ForegroundColor Green
Write-Host 'Note: the phone now has the measurement build (it opens straight into the model lab).' -ForegroundColor Gray
Write-Host 'A normal "flutter run" puts the usual app back (same signing key and versionCode, login kept).' -ForegroundColor Gray
