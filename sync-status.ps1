# Shows the drive-sync status: last run, last success, tail of the last log.
. (Join-Path $PSScriptRoot "config.ps1")
$statusFile = Join-Path $DriveSyncConfig.StateDir "status.json"
if (-not (Test-Path $statusFile)) { Write-Host "No sync run recorded yet."; exit 1 }
$s = Get-Content $statusFile -Raw | ConvertFrom-Json
"Last run:     $($s.lastRun.start)  exit=$($s.lastRun.exitCode)  $($s.lastRun.minutes) min $(if ($s.lastRun.dryRun) { '(dry-run)' })"
if ($s.lastSuccess) {
    $age = [math]::Round(((Get-Date) - [datetime]$s.lastSuccess.end).TotalHours, 1)
    "Last success: $($s.lastSuccess.end)  ($age h ago)"
}
else { "Last success: NEVER" }
# liveness comes from the PID lock (the status json only updates on flushes)
function Get-WatcherLine([string]$label, [string]$lockName, [string]$statusName, [scriptblock]$counters) {
    $pid_ = Get-Content (Join-Path $DriveSyncConfig.StateDir $lockName) -ErrorAction SilentlyContinue | Select-Object -First 1
    $alive = $pid_ -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)
    $sf = Join-Path $DriveSyncConfig.StateDir $statusName
    $s = if (Test-Path $sf) { Get-Content $sf -Raw | ConvertFrom-Json }
    $stats = if ($s) { "lastFlush=$($s.lastFlush)  $(& $counters $s)" } else { "no flush recorded yet" }
    "{0} $(if ($alive) { "running (PID $pid_)" } else { 'NOT RUNNING' })  $stats" -f $label
}
Get-WatcherLine "Watcher up:  " "watcher.lock" "watcher-status.json" { param($s) "up=$($s.uploadedTotal) ren=$($s.renamedTotal) del=$($s.deletedTotal)" }
Get-WatcherLine "Watcher down:" "cloud-watcher.lock" "cloud-watcher-status.json" { param($s) "down=$($s.downloadedTotal) recycled=$($s.recycledTotal)" }
if ($s.lastRun.log -and (Test-Path $s.lastRun.log)) {
    ""
    "--- log tail ---"
    Get-Content $s.lastRun.log -Tail 5
}
