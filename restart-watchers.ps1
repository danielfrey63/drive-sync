# Restarts the two watcher processes so they pick up changed code.
#
# Why this is not just Stop-ScheduledTask/Start-ScheduledTask: the tasks launch
# through run-hidden.vbs, which uses WScript.Shell.Run(cmd, 0, False) - fire and
# forget. wscript exits after milliseconds, so the scheduler considers the task
# finished and never shows it as Running. The watcher itself lives on as a loose
# process the scheduler does not own.
#
# Stop-ScheduledTask therefore finds nothing to stop and the old process keeps
# running; Start-ScheduledTask then starts a second one that hits the PID lock
# and exits again ("another watcher (PID ...) is active - exiting"). The code on
# disk changes, the running watcher does not - silently, with rc=0 on both tasks.
#
#   pwsh -File restart-watchers.ps1          both watchers
#   pwsh -File restart-watchers.ps1 -Up      upload watcher only
#   pwsh -File restart-watchers.ps1 -Down    cloud watcher only

param(
    [switch]$Up,
    [switch]$Down
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")

$stateDir = $DriveSyncConfig.StateDir
$all = @(
    @{ Name = "DriveSync watcher"; Lock = "watcher.lock"; Pick = $Up }
    @{ Name = "DriveSync cloud watcher"; Lock = "cloud-watcher.lock"; Pick = $Down }
)
# no switch given means both
$watchers = if ($Up -or $Down) { @($all | Where-Object { $_.Pick }) } else { $all }

if (Test-Path (Join-Path $stateDir "watchdog-pause")) {
    Write-Host "watchdog-pause present - maintenance in progress, not restarting."
    exit 1
}

foreach ($w in $watchers) {
    $lock = Join-Path $stateDir $w.Lock
    $old = Get-Content $lock -ErrorAction SilentlyContinue | Select-Object -First 1
    $proc = if ($old) { Get-Process -Id $old -ErrorAction SilentlyContinue }
    if ($proc) {
        Stop-Process -Id $old -Force
        # the new instance reads the lock: give the process a moment to be gone,
        # otherwise it sees a live PID and exits like every other duplicate
        for ($i = 0; $i -lt 20 -and (Get-Process -Id $old -ErrorAction SilentlyContinue); $i++) {
            Start-Sleep -Milliseconds 100
        }
        Write-Host "$($w.Name): stopped PID $old"
    }
    else {
        Write-Host "$($w.Name): no live process (lock PID: $(if ($old) { "$old, gone" } else { 'none' }))"
    }
    Start-ScheduledTask -TaskName $w.Name
}

# the watcher writes its own PID to the lock at startup, so a changed PID is the
# proof that the restart took - a task result of 0 is not (see the header)
Start-Sleep -Seconds 3
foreach ($w in $watchers) {
    $lock = Join-Path $stateDir $w.Lock
    $new = Get-Content $lock -ErrorAction SilentlyContinue | Select-Object -First 1
    $proc = if ($new) { Get-Process -Id $new -ErrorAction SilentlyContinue }
    if ($proc) { Write-Host "$($w.Name): running as PID $new (since $($proc.StartTime.ToString('HH:mm:ss')))" }
    else { Write-Host "$($w.Name): NOT RUNNING - check $(Join-Path $stateDir $w.Lock.Replace('.lock', '.log'))" }
}
