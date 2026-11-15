# Registers (or updates) the scheduled task that runs sync-drive.ps1 once a
# day. Idempotent: re-running replaces the existing definition.
# Runs as the current user, only when a network is available; a missed
# schedule (machine off/asleep at night) is started as soon as possible
# after wake-up (-StartWhenAvailable).
#
# The bisync is the daily reconciliation net (deletions, renames, conflicts,
# anything the watchers missed); near-realtime transfers are handled by the
# two watchers (watch-drive.ps1 up, watch-cloud.ps1 down). A full run needs
# ~25 min (listing 1.6M files), hence the quiet nightly slot.

param(
    [string]$TaskName = "DriveSync rclone bisync",
    [string]$DailyAt = ""   # empty = BisyncDailyAt from this machine's entry in config.ps1
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
# Two machines on the default start time run their bisyncs against the same
# remote at once, and the final listing check fails on the other's writes.
# A machine without its own entry would silently take the default.
if (-not $DailyAt) {
    if (-not ($DriveSyncMachine -and $DriveSyncMachine.ContainsKey('BisyncDailyAt'))) {
        Write-Warning "This machine ($env:COMPUTERNAME) has no BisyncDailyAt in `$DriveSyncMachines (config.ps1). Add it there - each machine its own time - or pass -DailyAt explicitly. Nothing registered."
        exit 1
    }
    $DailyAt = $DriveSyncConfig.BisyncDailyAt
}
$script = Join-Path $PSScriptRoot "sync-drive.ps1"
$pwshExe = (Get-Command pwsh).Source

$action = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
# The cmdlet writes the start as an instant ("2026-08-08T02:00:00Z"), and the
# scheduler keeps the instant, not the hour: registered in summer for 04:00,
# the task ran at 03:00 from the end of October 2026 on. Without an offset the
# start is wall-clock time and follows daylight saving.
$trigger.StartBoundary = ([datetime]$trigger.StartBoundary).ToString("yyyy-MM-dd'T'HH:mm:ss")
$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "Bidirectional Google Drive sync via rclone bisync (drive-sync)" -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered (daily at $DailyAt, missed runs start when available)."
