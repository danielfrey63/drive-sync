# Registers (or updates) the logon tasks that keep the two watchers running
# (watch-drive.ps1 = local->cloud uploads, watch-cloud.ps1 = cloud->local
# downloads) plus the watchdog task, and starts watchers that are not
# already running. Idempotent.
#
# All three tasks launch through run-hidden.vbs (wscript) so no console
# window flashes. Duplicate starts are harmless: the watchers enforce a
# single instance via their PID lock files.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
$pwshExe = (Get-Command pwsh).Source
$wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
$wrapper = Join-Path $PSScriptRoot "run-hidden.vbs"
$stateDir = $DriveSyncConfig.StateDir

function New-HiddenAction([string]$script) {
    New-ScheduledTaskAction -Execute $wscript `
        -Argument "//B //Nologo `"$wrapper`" `"$pwshExe`" -NoProfile -File `"$script`""
}

$tasks = @(
    @{ Name = "DriveSync watcher"; Script = Join-Path $PSScriptRoot "watch-drive.ps1"
       Lock = Join-Path $stateDir "watcher.lock"
       Description = "Near-realtime upload watcher for $($DriveSyncConfig.LocalRoot) (drive-sync)" }
    @{ Name = "DriveSync cloud watcher"; Script = Join-Path $PSScriptRoot "watch-cloud.ps1"
       Lock = Join-Path $stateDir "cloud-watcher.lock"
       Description = "Near-realtime download watcher for $($DriveSyncConfig.Remote) changes (drive-sync)" }
)

# during maintenance (watchdog-pause marker) only register, never start
$paused = Test-Path (Join-Path $stateDir "watchdog-pause")

foreach ($t in $tasks) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    # no time limit: if the scheduler's job object tracks the detached pwsh,
    # a limit would kill the long-running watcher. Battery flags matter: the
    # cmdlet defaults silently refuse to start and even STOP tasks on battery
    # (this killed both watchers when the power cord was pulled, 2026-08-05).
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $t.Name -Action (New-HiddenAction $t.Script) `
        -Trigger $trigger -Settings $settings -Description $t.Description -Force | Out-Null

    $pid_ = Get-Content $t.Lock -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pid_ -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) {
        Write-Host "Task '$($t.Name)' registered; watcher already running (PID $pid_)."
    }
    elseif ($paused) {
        Write-Host "Task '$($t.Name)' registered; NOT started (watchdog-pause present)."
    }
    else {
        Start-ScheduledTask -TaskName $t.Name
        Write-Host "Task '$($t.Name)' registered (at logon) and started."
    }
}

# watchdog: restarts silently died watchers (see watchdog.ps1)
$wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 15)
$wdSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "DriveSync watchdog" -Action (New-HiddenAction (Join-Path $PSScriptRoot "watchdog.ps1")) `
    -Trigger $wdTrigger -Settings $wdSettings -Description "Restarts died DriveSync watchers (drive-sync)" -Force | Out-Null
Write-Host "Task 'DriveSync watchdog' registered (every 15 min)."
