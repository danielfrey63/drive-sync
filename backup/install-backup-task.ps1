# Registers (or updates) the scheduled task that runs run-backup.ps1 once a
# day. Idempotent: re-running replaces the existing definition.
# Runs elevated (RunLevel Highest) because VSS snapshots require it; the
# Windows ssh-agent service is per user, so the elevated task still sees
# the storage box key loaded in the interactive session.
# Missed runs (machine asleep at night) start as soon as possible after
# wake-up. The 20 h limit only ends a run that is stuck; an interrupted
# upload resumes from the repository index on the next run.

param(
    [string]$TaskName = "DriveSync restic backup",
    [string]$DailyAt = ""   # empty = DailyAt from backup-config.ps1
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\config.ps1")
. (Join-Path $PSScriptRoot "backup-config.ps1")
if (-not $DailyAt) { $DailyAt = $BackupConfig.DailyAt }
$script = Join-Path $PSScriptRoot "run-backup.ps1"
$pwshExe = (Get-Command pwsh).Source

$action = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 20) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description "restic backup of C: and D:\Meine Ablage to the Hetzner Storage Box (drive-sync)" -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered (daily at $DailyAt, elevated, missed runs start when available)."
