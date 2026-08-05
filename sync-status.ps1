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
if ($s.lastRun.log -and (Test-Path $s.lastRun.log)) {
    ""
    "--- log tail ---"
    Get-Content $s.lastRun.log -Tail 5
}
