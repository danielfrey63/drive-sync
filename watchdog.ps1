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

. (Join-Path $PSScriptRoot "notify.ps1")

$watchers = @(
    @{ Task = "DriveSync watcher"; Key = "watcher-up"; Lock = Join-Path $stateDir "watcher.lock"
        Script = Join-Path $PSScriptRoot "watch-drive.ps1"; Log = Join-Path $stateDir "watcher.log" }
    @{ Task = "DriveSync cloud watcher"; Key = "watcher-down"; Lock = Join-Path $stateDir "cloud-watcher.lock"
        Script = Join-Path $PSScriptRoot "watch-cloud.ps1"; Log = Join-Path $stateDir "cloud-watcher.log" }
)

# Restart history per watcher (unix seconds of the last restarts). A watcher
# that dies right after every start - on 2026-10-20 two dot-sourced modules
# were missing - was restarted every 15 minutes for hours without anyone
# hearing of it. From AlertWatcherRestarts restarts within an hour on, the
# watchdog raises a toast naming the cause.
$historyFile = Join-Path $stateDir "watchdog-restarts.json"
$history = @{}
try {
    if (Test-Path $historyFile) {
        foreach ($p in (Get-Content $historyFile -Raw | ConvertFrom-Json).PSObject.Properties) { $history[$p.Name] = @($p.Value | ForEach-Object { [long]$_ }) }
    }
}
catch {}
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$threshold = if ($DriveSyncConfig.AlertWatcherRestarts) { [int]$DriveSyncConfig.AlertWatcherRestarts } else { 3 }

# Best guess at why a watcher will not stay up: dot-sourced files that are
# gone (the 2026-10-20 cause), else the last FATAL line of its log.
function Get-CrashCause($w) {
    $missing = @(Select-String -LiteralPath $w.Script -Pattern 'Join-Path \$PSScriptRoot "([^"]+\.ps1)"' -AllMatches -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
        Where-Object { -not (Test-Path (Join-Path $PSScriptRoot $_)) })
    if ($missing.Count -gt 0) { return "fehlende Datei(en): $($missing -join ', ')" }
    $fatal = Get-Content $w.Log -Tail 200 -ErrorAction SilentlyContinue | Where-Object { $_ -match ' FATAL: ' } | Select-Object -Last 1
    if ($fatal) { return ($fatal -replace '^.* FATAL: ', '') }
    return "keine Fehlermeldung im Log ($([IO.Path]::GetFileName($w.Log)))"
}

foreach ($w in $watchers) {
    $pid_ = Get-Content $w.Lock -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pid_ -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) {
        # up: forget the crash history only once it has stayed up past a cycle
        if ($history.ContainsKey($w.Key)) {
            $recent = @($history[$w.Key] | Where-Object { $now - $_ -lt 1200 })
            if ($recent.Count -eq 0) { $history.Remove($w.Key); Clear-DriveSyncAlert $w.Key }
        }
        continue
    }
    Write-Log "'$($w.Task)' not running (lock PID: $($pid_ ?? 'none')) - restarting"
    Remove-Item $w.Lock -Force -Confirm:$false -ErrorAction SilentlyContinue
    try { Start-ScheduledTask -TaskName $w.Task -ErrorAction Stop }
    catch { Write-Log "ERROR starting '$($w.Task)': $($_.Exception.Message)" }

    $history[$w.Key] = @(@($history[$w.Key]) + $now | Where-Object { $_ -and $now - $_ -lt 3600 })
    if ($history[$w.Key].Count -ge $threshold) {
        $cause = Get-CrashCause $w
        Write-Log "'$($w.Task)' restarted $($history[$w.Key].Count)x within an hour - alerting: $cause"
        Send-DriveSyncAlert -Key $w.Key -Title "Drive-Sync: $($w.Task) stürzt ab" `
            -Body "$($history[$w.Key].Count) Neustarts in einer Stunde, Sync in diese Richtung steht. Ursache: $cause" | Out-Null
    }
}

try { Set-Content $historyFile ($history | ConvertTo-Json -Compress) } catch {}
