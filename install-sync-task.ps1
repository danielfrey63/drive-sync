# Registers (or updates) the scheduled task that runs sync-drive.ps1 on an
# interval. Idempotent: re-running replaces the existing definition.
# Runs as the current user, only when a network is available; a missed
# schedule is started as soon as possible.
#
# NOTE: a full run needs ~25 min (listing 1.6M files); with intervals below
# that, the wrapper's lock serializes runs, so the effective cadence is
# max(interval, run duration) - i.e. continuous syncing.

param(
    [string]$TaskName = "DriveSync rclone bisync",
    [int]$IntervalMinutes = 10
)

$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "sync-drive.ps1"
$pwshExe = (Get-Command pwsh).Source

$action = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "Bidirectional Google Drive sync via rclone bisync (ai-toolbox/drive-sync)" -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered (every $IntervalMinutes min, next start in ~2 min)."
