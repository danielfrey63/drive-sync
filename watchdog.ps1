# Watchdog for the two drive-sync watchers: restarts their scheduled tasks
# if the recorded PID is no longer alive (both watchers died silently at the
# same minute on 2026-08-05; root cause found 2026-08-06: the scheduler's
# StopIfGoingOnBatteries default killed them when the power cord was pulled -
# fixed in install-watcher-task.ps1, watchdog stays as second line of
# defence). Runs every 15 min via the "DriveSync watchdog" task. Idempotent.
#
# Touch %LOCALAPPDATA%\drive-sync\watchdog-pause to suppress restarts during
# maintenance (ignored and removed when older than 6 h). For maintenance that
# may run longer, write "pid:<n>" as the first line: the pause then holds as
# long as that process is alive, regardless of age (lesson from 2026-08-06,
# when a >6 h dedupe run lost its pause and a watcher restarted mid-cleanup).

. (Join-Path $PSScriptRoot "config.ps1")
$stateDir = $DriveSyncConfig.StateDir
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
    $ownerAlive = $false
    $firstLine = Get-Content $pauseFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($firstLine -match '^pid:(\d+)$') {
        $ownerAlive = [bool](Get-Process -Id $Matches[1] -ErrorAction SilentlyContinue)
    }
    if ($ownerAlive -or (Get-Item $pauseFile).LastWriteTime -gt (Get-Date).AddHours(-6)) {
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
