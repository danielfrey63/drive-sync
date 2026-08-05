# Registers (or updates) the logon tasks that keep the two watchers running
# (watch-drive.ps1 = local->cloud uploads, watch-cloud.ps1 = cloud->local
# downloads) and starts them right away. Idempotent.

$ErrorActionPreference = "Stop"
$pwshExe = (Get-Command pwsh).Source

$tasks = @(
    @{ Name = "DriveSync watcher"; Script = Join-Path $PSScriptRoot "watch-drive.ps1"
       Description = "Near-realtime upload watcher for D:\Meine Ablage (ai-toolbox/drive-sync)" }
    @{ Name = "DriveSync cloud watcher"; Script = Join-Path $PSScriptRoot "watch-cloud.ps1"
       Description = "Near-realtime download watcher for gdrive: changes (ai-toolbox/drive-sync)" }
)

foreach ($t in $tasks) {
    $action = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -WindowStyle Hidden -File `"$($t.Script)`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 5) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $trigger `
        -Settings $settings -Description $t.Description -Force | Out-Null
    Start-ScheduledTask -TaskName $t.Name
    Write-Host "Task '$($t.Name)' registered (at logon) and started."
}

# watchdog: restarts silently died watchers (see watchdog.ps1)
$wdScript = Join-Path $PSScriptRoot "watchdog.ps1"
$wdAction = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -WindowStyle Hidden -File `"$wdScript`""
$wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 15)
$wdSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName "DriveSync watchdog" -Action $wdAction -Trigger $wdTrigger `
    -Settings $wdSettings -Description "Restarts died DriveSync watchers (ai-toolbox/drive-sync)" -Force | Out-Null
Write-Host "Task 'DriveSync watchdog' registered (every 15 min)."
