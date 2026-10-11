<#
.SYNOPSIS
  Reproduces the Windows PowerShell 5.1 defect that hung tools/measure_model.ps1 1.1 in run
  2026-10-10_120250 (fixed in 1.2), and checks the fix.

.DESCRIPTION
  A line read with Get-Content carries file metadata (PSPath, PSDrive, PSProvider, ...); ConvertTo-Json
  serializes it as an object graph that grows with -Depth. Prints the JSON size per depth, the size with
  the fix ([string] cast) at depth 14, and - if the run's device log is still in tools/.cache - the size of
  the XNNPACK attribution block rebuilt from that log exactly as script 1.2 builds it.

  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\model_check\ps51_json_probe.ps1
#>
param(
    [string]$LogFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.cache\logcat_full_2026-10-10_120250.txt'),
    [string]$AppPid = '16395'
)

$line = 'I tflite: Created TensorFlow Lite XNNPACK delegate for CPU.'
$tmp = Join-Path $env:TEMP 'ps51_json_probe.txt'
$line | Set-Content $tmp -Encoding UTF8
foreach ($l in (Get-Content -Path $tmp -Encoding UTF8)) { $fromGetContent = $l }
"PowerShell $($PSVersionTable.PSVersion); probe line: $($line.Length) characters"
"properties PowerShell attached to it: " + (($fromGetContent.PSObject.Properties |
    Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object Name) -join ', ')
foreach ($d in 1, 2, 3) {
    $j = ([ordered]@{ line = $fromGetContent }) | ConvertTo-Json -Depth $d
    "line from Get-Content, -Depth $d : $($j.Length) characters of JSON"
}
$fixed = ([ordered]@{ line = [string]$fromGetContent }) | ConvertTo-Json -Depth 14
"line cast to [string], -Depth 14: $($fixed.Length) characters of JSON"
Remove-Item $tmp

if (Test-Path $LogFile) {
    function PidOf([string]$l) { if ($l -match '^\s*\d+\.\d+\s+(\d+)\s+\d+\s+[VDIWEFA]\s') { return $Matches[1] }; return $null }
    function EpochOf([string]$l) { if ($l -match '^\s*(\d+\.\d+)\s') { return [double]$Matches[1] }; return $null }
    $xnnLines = New-Object System.Collections.ArrayList
    foreach ($l in (Get-Content -Path $LogFile -Encoding UTF8)) {
        if ((PidOf $l) -eq $AppPid -and $l -match '(?i)xnnpack') {
            [void]$xnnLines.Add([ordered]@{ epoch = (EpochOf $l); line = [string]$l })
        }
    }
    $json = ([ordered]@{ attribution = [ordered]@{ xnnpack_lines = $xnnLines } }) | ConvertTo-Json -Depth 14
    "run 2026-10-10_120250 log, app pid ${AppPid}: $($xnnLines.Count) XNNPACK lines -> $($json.Length) characters of JSON with the fix"
}
else { "device log $LogFile not present - part 2 skipped" }
