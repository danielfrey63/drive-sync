# Registers (or updates) the scheduled task that runs run-backup.ps1 every
# IntervalHours (default 6 h). Idempotent: re-running replaces the existing
# definition. A run that is still going when the next slot fires is left
# alone (IgnoreNew); the run-backup lock covers manual starts.
# Runs elevated (RunLevel Highest) because VSS snapshots require it; the
# Windows ssh-agent service is per user, so the elevated task still sees
# the storage box key loaded in the interactive session.
# Missed runs (machine asleep at night) start as soon as possible after
# wake-up. The 20 h limit only ends a run that is stuck; an interrupted
# upload resumes from the repository index on the next run.

param(
    [string]$TaskName = "DriveSync restic backup",
    [string]$FirstRunAt = "",   # empty = FirstRunAt from backup-config.ps1
    [int]$IntervalHours = 0,    # 0 = IntervalHours from backup-config.ps1
    [string]$ToolboxPath = ""   # empty = sibling checkout ..\ai-toolbox (windowless launcher)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\config.ps1")
. (Join-Path $PSScriptRoot "backup-config.ps1")
if (-not $FirstRunAt) { $FirstRunAt = $BackupConfig.FirstRunAt }
if (-not $IntervalHours) { $IntervalHours = $BackupConfig.IntervalHours }
if (-not $ToolboxPath) { $ToolboxPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "ai-toolbox" }
$script = Join-Path $PSScriptRoot "run-backup.ps1"
$pwshExe = (Get-Command pwsh).Source

# Windowless start through wscript + run-hidden.vbs from ai-toolbox: "-WindowStyle
# Hidden" alone flashes a console window every 6 h. The toolbox launcher waits for
# pwsh and returns its exit code, so the 20 h limit and the task result still work.
$hiddenTask = Join-Path $ToolboxPath "tools\run-hidden\HiddenTask.ps1"
if (-not (Test-Path $hiddenTask)) { throw "ai-toolbox checkout missing: $hiddenTask" }
. $hiddenTask
$action = New-HiddenTaskAction -FilePath $pwshExe -ArgumentList @("-NoProfile", "-File", $script)
# -Once with a repetition interval and no duration repeats indefinitely
$trigger = New-ScheduledTaskTrigger -Once -At $FirstRunAt -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)
$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 20) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description "restic backup of C: and D:\Meine Ablage to the Hetzner Storage Box (drive-sync)" -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered (every $IntervalHours h from $FirstRunAt, elevated, missed runs start when available)."
