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
