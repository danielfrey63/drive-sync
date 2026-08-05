# Shows the drive-sync status: last run, last success, tail of the last log.
$statusFile = Join-Path $env:LOCALAPPDATA "drive-sync\status.json"
if (-not (Test-Path $statusFile)) { Write-Host "No sync run recorded yet."; exit 1 }
$s = Get-Content $statusFile -Raw | ConvertFrom-Json
"Last run:     $($s.lastRun.start)  exit=$($s.lastRun.exitCode)  $($s.lastRun.minutes) min $(if ($s.lastRun.dryRun) { '(dry-run)' })"
if ($s.lastSuccess) {
    $age = [math]::Round(((Get-Date) - [datetime]$s.lastSuccess.end).TotalHours, 1)
    "Last success: $($s.lastSuccess.end)  ($age h ago)"
}
else { "Last success: NEVER" }
$w = Join-Path $env:LOCALAPPDATA "drive-sync\watcher-status.json"
if (Test-Path $w) {
    $ws = Get-Content $w -Raw | ConvertFrom-Json
    $alive = [bool](Get-Process -Id $ws.pid -ErrorAction SilentlyContinue)
    "Watcher up:   $(if ($alive) { "running (PID $($ws.pid))" } else { 'NOT RUNNING' })  lastFlush=$($ws.lastFlush)  up=$($ws.uploadedTotal) ren=$($ws.renamedTotal) del=$($ws.deletedTotal)"
}
else { "Watcher up:   no flush recorded yet" }
$c = Join-Path $env:LOCALAPPDATA "drive-sync\cloud-watcher-status.json"
if (Test-Path $c) {
    $cs = Get-Content $c -Raw | ConvertFrom-Json
    $calive = [bool](Get-Process -Id $cs.pid -ErrorAction SilentlyContinue)
    "Watcher down: $(if ($calive) { "running (PID $($cs.pid))" } else { 'NOT RUNNING' })  lastFlush=$($cs.lastFlush)  down=$($cs.downloadedTotal) recycled=$($cs.recycledTotal)"
}
else { "Watcher down: no flush recorded yet" }
if ($s.lastRun.log -and (Test-Path $s.lastRun.log)) {
    ""
    "--- log tail ---"
    Get-Content $s.lastRun.log -Tail 5
}
