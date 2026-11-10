# Tests for the watchdog's dead man's switch (liveness.ps1). Offline: pure
# functions, plus the stamp file in a scratch folder under TEMP.
#
#   pwsh -File test-liveness.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "liveness.ps1")

$script:failed = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    Write-Host ("{0} - {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { " [$detail]" } else { "" }))
    if (-not $ok) { $script:failed++ }
}

# ============================================================================
Write-Host "--- part 1: watcher verdict ---"
$now = [datetime]'2026-11-10T12:00:00'
Check "loop turned a minute ago: ok" ((Get-WatcherVerdict $now $now.AddMinutes(-1) $false 30) -eq 'ok')
Check "29 min of silence: still ok" ((Get-WatcherVerdict $now $now.AddMinutes(-29) $false 30) -eq 'ok')
Check "30 min of silence, nothing to wait for: silent" ((Get-WatcherVerdict $now $now.AddMinutes(-30) $false 30) -eq 'silent')
Check "2 h of silence behind a running rclone: busy" ((Get-WatcherVerdict $now $now.AddHours(-2) $true 30) -eq 'busy')
Check "6 h of silence behind a running rclone: stuck" ((Get-WatcherVerdict $now $now.AddHours(-6) $true 30) -eq 'stuck')
Check "6 h of silence without a child: silent, not stuck" ((Get-WatcherVerdict $now $now.AddHours(-6) $false 30) -eq 'silent')

$dir = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-liveness-test"
New-Item -ItemType Directory -Force $dir | Out-Null
$stamp = Join-Path $dir "w.alive"
if (Test-Path $stamp) { [IO.File]::Delete($stamp) }
$start = (Get-Date).AddMinutes(-5)
Check "no stamp yet: the process start is the last sign of life" ((Get-LastSignOfLife $stamp $start) -eq $start)
$script:aliveStampedAt = $null
Update-AliveStamp $stamp
$first = (Get-Item $stamp).LastWriteTime
Check "first call writes the stamp, and it counts" ((Test-Path $stamp) -and (Get-LastSignOfLife $stamp $start) -eq $first)
[IO.File]::SetLastWriteTime($stamp, (Get-Date).AddHours(-1))
Update-AliveStamp $stamp
Check "second call within a minute writes nothing" ((Get-Item $stamp).LastWriteTime -lt (Get-Date).AddMinutes(-50))
$script:aliveStampedAt = (Get-Date).AddSeconds(-61)
Update-AliveStamp $stamp
Check "a minute later it writes again" ((Get-Item $stamp).LastWriteTime -gt (Get-Date).AddMinutes(-1))
$restart = Get-Date
[IO.File]::SetLastWriteTime($stamp, $restart.AddHours(-3))
Check "stamp of the previous instance, process just started: the start counts" ((Get-LastSignOfLife $stamp $restart) -eq $restart)
Update-AliveStamp (Join-Path $dir "no-such-dir" "w.alive")
Check "an unwritable stamp path never throws" $true
[IO.Directory]::Delete($dir, $true)

# ============================================================================
Write-Host "--- part 2: nightly bisync ---"
function Night([hashtable]$over) {
    $p = @{
        taskExists = $true; taskState = 'Ready'; taskLastRun = $now.AddHours(-9); taskLastResult = 0
        lastStatusRun = $now.AddHours(-9); running = $false; now = $now; staleHours = 36
    }
    foreach ($k in $over.Keys) { $p[$k] = $over[$k] }
    Get-NightlyProblem @p
}
Check "ran last night: no problem" ($null -eq (Night @{}))
Check "task gone" ((Night @{ taskExists = $false }) -like '*fehlt*')
Check "task disabled" ((Night @{ taskState = 'Disabled' }) -like '*deaktiviert*')
Check "never ran, no status" ((Night @{ taskLastRun = $null; lastStatusRun = $null }) -like '*noch nie*')
$m = Night @{ taskLastRun = $now.AddHours(-60); lastStatusRun = $now.AddHours(-60) }
Check "last start 60 h ago: names the date" ($m -like 'Seit 08.11. 00:00*') $m
Check "last start 60 h ago, but a run is active now: no problem" ($null -eq (Night @{ taskLastRun = $now.AddHours(-60); lastStatusRun = $now.AddHours(-60); running = $true }))
Check "scheduler says 60 h, a manual run 2 h ago: no problem" ($null -eq (Night @{ taskLastRun = $now.AddHours(-60); lastStatusRun = $now.AddHours(-2) }))
Check "starts nightly, dies before the status (exit 1)" ((Night @{ taskLastResult = 1; lastStatusRun = $now.AddHours(-60) }) -like '*bricht*Ergebnis 1*')
Check "starts nightly, refuses with exit 3: its own alert, not ours" ($null -eq (Night @{ taskLastResult = 3; lastStatusRun = $now.AddHours(-60) }))
Check "started a moment ago and still running (0x41301): no problem" ($null -eq (Night @{ taskLastRun = $now; taskLastResult = 267009; lastStatusRun = $now.AddHours(-60) }))
Check "failed last night with exit 7, status written: its own alert" ($null -eq (Night @{ taskLastResult = 7 }))

if ($script:failed -eq 0) { Write-Host "`nALL PASS"; exit 0 }
Write-Host "`nFAILED: $($script:failed)"
exit 1
