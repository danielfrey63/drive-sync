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
#   -ReadyTimeoutSec 0                       do not wait for the catch-up

param(
    [switch]$Up,
    [switch]$Down,
    # the upload watcher lists the whole corpus before its main loop runs
    # (start-up catch-up, ~2-3 min); 0 returns as soon as the PID is up
    [int]$ReadyTimeoutSec = 300
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")

$stateDir = $DriveSyncConfig.StateDir
$all = @(
    # Ready: the log line that ends start-up. The cloud watcher polls right
    # away, so its PID is the whole story.
    @{ Name = "DriveSync watcher"; Lock = "watcher.lock"; Log = "watcher.log"; Pick = $Up; Ready = '^\S+ \S+ (catch-up|WARN catch-up failed)' }
    @{ Name = "DriveSync cloud watcher"; Lock = "cloud-watcher.lock"; Log = "cloud-watcher.log"; Pick = $Down; Ready = $null }
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
    $w.OldPid = $old
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
# proof that the restart took - a task result of 0 is not (see the header).
# Poll instead of a fixed pause: start-up takes 4-7 s before the lock is written
# (rclone capability probes, config resolution), and until then the lock still
# names the process just killed - a fixed 3 s reported "NOT RUNNING" for two
# watchers that were fine (2026-09-17).
$deadline = (Get-Date).AddSeconds(30)
foreach ($w in $watchers) {
    $lock = Join-Path $stateDir $w.Lock
    $new = $null; $proc = $null
    while ($true) {
        $new = Get-Content $lock -ErrorAction SilentlyContinue | Select-Object -First 1
        $proc = if ($new -and $new -ne $w.OldPid) { Get-Process -Id $new -ErrorAction SilentlyContinue }
        if ($proc -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    }
    $w.NewPid = if ($proc) { $new }
    if ($proc) { Write-Host "$($w.Name): running as PID $new (since $($proc.StartTime.ToString('HH:mm:ss')))" }
    else { Write-Host "$($w.Name): NOT RUNNING after 30 s - check $(Join-Path $stateDir $w.Log)" }
}

# A live PID is not a working watcher yet: on 2026-10-22 the upload watcher
# spent 3 minutes in its catch-up listing after the restart, and a test file
# written meanwhile seemed to be ignored. FSW events queue up during that time
# and nothing is lost - but whoever restarts should know when the main loop
# runs. Only lines after this PID's own "started" line count.
foreach ($w in @($watchers | Where-Object { $_.NewPid -and $_.Ready -and $ReadyTimeoutSec -gt 0 })) {
    $log = Join-Path $stateDir $w.Log
    $since = Get-Date
    $deadline = $since.AddSeconds($ReadyTimeoutSec)
    $hit = $null
    while (-not $hit -and (Get-Date) -lt $deadline) {
        $tail = @(Get-Content $log -Tail 400 -ErrorAction SilentlyContinue)
        $start = -1
        for ($i = $tail.Count - 1; $i -ge 0; $i--) { if ($tail[$i] -match "started \(PID $($w.NewPid)\)") { $start = $i; break } }
        if ($start -ge 0) { $hit = $tail[($start + 1)..($tail.Count)] | Where-Object { $_ -match $w.Ready } | Select-Object -First 1 }
        if (-not $hit) { Start-Sleep -Seconds 2 }
    }
    $secs = [int]((Get-Date) - $since).TotalSeconds
    if ($hit) { Write-Host "$($w.Name): ready after $secs s - $(($hit -split ' ', 3)[2])" }
    else { Write-Host "$($w.Name): still in start-up after $secs s - events queue meanwhile, nothing is lost; see $log" }
}
