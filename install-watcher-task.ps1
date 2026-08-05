# Registers (or updates) the logon task that keeps watch-drive.ps1 running
# and starts it right away. Idempotent.

param([string]$TaskName = "DriveSync watcher")

$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "watch-drive.ps1"
$pwshExe = (Get-Command pwsh).Source

$action = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "Near-realtime upload watcher for D:\Meine Ablage (ai-toolbox/drive-sync)" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Watcher task '$TaskName' registered (at logon) and started."
