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
    [string]$DailyAt = "04:00"
)

$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "sync-drive.ps1"
$pwshExe = (Get-Command pwsh).Source

$action = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "Bidirectional Google Drive sync via rclone bisync (drive-sync)" -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered (daily at $DailyAt, missed runs start when available)."
