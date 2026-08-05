# Registers (or updates) the scheduled task that runs sync-drive.ps1 every
# 3 hours. Idempotent: re-running replaces the existing definition.
# Runs as the current user, only when a network is available; a missed
# schedule is started as soon as possible.

param(
    [string]$TaskName = "DriveSync rclone bisync",
    [int]$IntervalHours = 3
)

$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "sync-drive.ps1"
$pwshExe = (Get-Command pwsh).Source

$action = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)
$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "Bidirectional Google Drive sync via rclone bisync (ai-toolbox/drive-sync)" -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered (every $IntervalHours h, next start in ~5 min)."
