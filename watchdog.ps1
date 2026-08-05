# Watchdog for the two drive-sync watchers: restarts their scheduled tasks
# if the recorded PID is no longer alive (both watchers died silently at the
# same minute on 2026-08-05, most likely killed by a system-level event -
# scheduler-side restart-on-failure did not trigger). Runs every 15 min via
# the "DriveSync watchdog" task (install-watcher-task.ps1). Idempotent.
#
# Touch %LOCALAPPDATA%\drive-sync\watchdog-pause to suppress restarts during
# maintenance (ignored and removed when older than 6 h).

$stateDir = Join-Path $env:LOCALAPPDATA "drive-sync"
$logFile = Join-Path $stateDir "watchdog.log"
$pauseFile = Join-Path $stateDir "watchdog-pause"

function Write-Log([string]$msg) {
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
            Move-Item $logFile "$logFile.1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ErrorAction SilentlyContinue
    }
    catch {}
}

if (Test-Path $pauseFile) {
    if ((Get-Item $pauseFile).LastWriteTime -gt (Get-Date).AddHours(-6)) {
        Write-Log "paused (watchdog-pause present) - skipping"
        exit 0
    }
    Remove-Item $pauseFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "stale watchdog-pause removed"
}

$watchers = @(
    @{ Task = "DriveSync watcher"; Lock = Join-Path $stateDir "watcher.lock" }
    @{ Task = "DriveSync cloud watcher"; Lock = Join-Path $stateDir "cloud-watcher.lock" }
)

foreach ($w in $watchers) {
    $pid_ = Get-Content $w.Lock -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pid_ -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) { continue }
    Write-Log "'$($w.Task)' not running (lock PID: $($pid_ ?? 'none')) - restarting"
    Remove-Item $w.Lock -Force -Confirm:$false -ErrorAction SilentlyContinue
    try { Start-ScheduledTask -TaskName $w.Task -ErrorAction Stop }
    catch { Write-Log "ERROR starting '$($w.Task)': $($_.Exception.Message)" }
}
