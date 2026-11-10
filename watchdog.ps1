# Watchdog for the drive-sync chain. Runs every 15 min via the "DriveSync
# watchdog" task. Idempotent.
#
# 1. Restarts a watcher whose recorded PID is no longer alive (both watchers
#    died silently at the same minute on 2026-08-05; root cause found
#    2026-08-06: the scheduler's StopIfGoingOnBatteries default killed them
#    when the power cord was pulled - fixed in install-watcher-task.ps1, the
#    watchdog stays as second line of defence).
# 2. Dead man's switch (liveness.ps1): restarts a watcher whose process lives
#    while its main loop stands still, and raises a toast when the nightly
#    bisync does not happen at all - task gone, disabled, not started, or
#    dying before it writes a status. Neither can report itself.
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
. (Join-Path $PSScriptRoot "liveness.ps1")
. (Join-Path $PSScriptRoot "single-instance.ps1")

$watchers = @(
    @{ Task = "DriveSync watcher"; Key = "watcher-up"; Lock = Join-Path $stateDir "watcher.lock"; Alive = Join-Path $stateDir "watcher.alive"
        Script = Join-Path $PSScriptRoot "watch-drive.ps1"; Log = Join-Path $stateDir "watcher.log" }
    @{ Task = "DriveSync cloud watcher"; Key = "watcher-down"; Lock = Join-Path $stateDir "cloud-watcher.lock"; Alive = Join-Path $stateDir "cloud-watcher.alive"
        Script = Join-Path $PSScriptRoot "watch-cloud.ps1"; Log = Join-Path $stateDir "cloud-watcher.log" }
)

# Restart history per watcher (unix seconds of the last restarts). A watcher
# that dies right after every start - on 2026-10-20 two dot-sourced modules
# were missing - was restarted every 15 minutes for hours without anyone
# hearing of it. From AlertWatcherRestarts restarts within an hour on, the
# watchdog raises a toast naming the cause. The same file remembers since
# when the nightly bisync has looked missing (see the end of this script).
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
$hungMin = if ($DriveSyncConfig.WatcherHungMinutes) { [double]$DriveSyncConfig.WatcherHungMinutes } else { 30 }

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

# A watcher whose process lives is judged by the stamp its main loop touches.
# "silent" is confirmed before anything is stopped: right after a wake-up the
# stamp is as old as the sleep was long, and the loop needs a moment (the
# cloud watcher up to one poll interval) to touch it again. The wait below is
# spent awake together with the watcher, so a stamp that has still not moved
# means the loop does stand still.
function Get-WatcherState($w, $proc) {
    # no stamp at all: a watcher started from code that did not write one yet
    if (-not (Test-Path -LiteralPath $w.Alive)) { return @{ Verdict = 'ok'; IdleMinutes = 0 } }
    $hasChild = { [bool]@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id) AND Name='rclone.exe'" -ErrorAction SilentlyContinue).Count }
    $sign = Get-LastSignOfLife $w.Alive $proc.StartTime
    $verdict = Get-WatcherVerdict (Get-Date) $sign (& $hasChild) $hungMin
    if ($verdict -eq 'silent') {
        $rounds = [math]::Ceiling(([int]$DriveSyncConfig.PollSeconds + 60) / 5)
        for ($i = 0; $i -lt $rounds -and $verdict -eq 'silent'; $i++) {
            Start-Sleep -Seconds 5
            if ((Get-LastSignOfLife $w.Alive $proc.StartTime) -gt $sign) { $verdict = 'ok' }
        }
        if ($verdict -eq 'silent') { $verdict = Get-WatcherVerdict (Get-Date) $sign (& $hasChild) $hungMin }
    }
    return @{ Verdict = $verdict; IdleMinutes = [int]((Get-Date) - $sign).TotalMinutes }
}

foreach ($w in $watchers) {
    $pid_ = Get-Content $w.Lock -ErrorAction SilentlyContinue | Select-Object -First 1
    $proc = if ($pid_) { Get-Process -Id $pid_ -ErrorAction SilentlyContinue }
    $hung = $null
    if ($proc) {
        $state = Get-WatcherState $w $proc
        if ($state.Verdict -eq 'stuck') {
            # a transfer that long may be genuine - a human decides
            Write-Log "'$($w.Task)' (PID $pid_) silent for $($state.IdleMinutes) min behind a running rclone - alerting, not restarting"
            Send-DriveSyncAlert -Key "$($w.Key)-hung" -Title "Drive-Sync: $($w.Task) hängt" `
                -Body "Seit $([int]($state.IdleMinutes / 60)) h kein Lebenszeichen, ein rclone-Transfer läuft noch. Falls das kein sehr grosser Transfer ist: restart-watchers.ps1 ausführen." | Out-Null
            continue
        }
        if ($state.Verdict -ne 'silent') {
            if ($state.Verdict -eq 'busy') { Write-Log "'$($w.Task)' (PID $pid_) silent for $($state.IdleMinutes) min, waiting for a running rclone - leaving it" }
            Clear-DriveSyncAlert "$($w.Key)-hung"
            # up: forget the crash history only once it has stayed up past a cycle
            if ($history.ContainsKey($w.Key)) {
                $recent = @($history[$w.Key] | Where-Object { $now - $_ -lt 1200 })
                if ($recent.Count -eq 0) { $history.Remove($w.Key); Clear-DriveSyncAlert $w.Key }
            }
            continue
        }
        Write-Log "'$($w.Task)' (PID $pid_) gave no sign of life for $($state.IdleMinutes) min and waits for no transfer - stopping it"
        Stop-Process -Id $pid_ -Force -Confirm:$false -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 20 -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
        $hung = "Hauptschleife stand $($state.IdleMinutes) min still"
    }
    else {
        # The lock file alone is not proof: a watcher still in its start-up has
        # not written it yet. On 2026-11-05 the watchdog read pre-reboot PIDs 7 s
        # after the logon task had started both watchers and started a second
        # pair. Look for a live process of the script before starting another
        # (second line of defence; single-instance.ps1 is the first).
        $leaf = [IO.Path]::GetFileName($w.Script)
        $running = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($leaf) -and $_.ProcessId -ne $PID })
        if ($running.Count -gt 0) {
            Write-Log "'$($w.Task)' lock stale (PID: $($pid_ ?? 'none')) but $leaf runs as PID $($running[0].ProcessId) - not restarting"
            continue
        }
        Write-Log "'$($w.Task)' not running (lock PID: $($pid_ ?? 'none')) - restarting"
    }
    Remove-Item $w.Lock -Force -Confirm:$false -ErrorAction SilentlyContinue
    try { Start-ScheduledTask -TaskName $w.Task -ErrorAction Stop }
    catch { Write-Log "ERROR starting '$($w.Task)': $($_.Exception.Message)" }

    $history[$w.Key] = @(@($history[$w.Key]) + $now | Where-Object { $_ -and $now - $_ -lt 3600 })
    if ($history[$w.Key].Count -ge $threshold) {
        $cause = if ($hung) { $hung } else { Get-CrashCause $w }
        Write-Log "'$($w.Task)' restarted $($history[$w.Key].Count)x within an hour - alerting: $cause"
        Send-DriveSyncAlert -Key $w.Key -Title "Drive-Sync: $($w.Task) stürzt ab" `
            -Body "$($history[$w.Key].Count) Neustarts in einer Stunde, Sync in diese Richtung steht. Ursache: $cause" | Out-Null
    }
}

# --- the nightly bisync -------------------------------------------------------
# Judged from outside (Get-NightlyProblem): by its scheduled task and by the
# last real run in status.json. A problem must be seen twice, 10 min apart,
# before it alerts: after a wake-up the watchdog may run a moment before the
# scheduler has started the missed run.
$nightKey = "bisync-missing"
$nightTask = Get-ScheduledTask -TaskName "DriveSync rclone bisync" -ErrorAction SilentlyContinue
$nightInfo = if ($nightTask) { $nightTask | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue }
# the scheduler reports a task that never ran as 1999-11-30
$taskLast = if ($nightInfo -and $nightInfo.LastRunTime -and $nightInfo.LastRunTime.Year -gt 2000) { $nightInfo.LastRunTime }
$statusLast = $null
try {
    $st = Get-Content (Join-Path $stateDir "status.json") -Raw -ErrorAction Stop | ConvertFrom-Json
    # a dry run proves nothing about the nightly job
    $real = if ($st.lastRun -and -not $st.lastRun.dryRun) { $st.lastRun } else { $st.lastSuccess }
    if ($real) { $statusLast = [datetime]$real.start }
}
catch {}
$staleH = if ($DriveSyncConfig.AlertStaleSyncHours) { [double]$DriveSyncConfig.AlertStaleSyncHours } else { 36 }
$problem = Get-NightlyProblem -taskExists ([bool]$nightTask) -taskState "$($nightTask.State)" -taskLastRun $taskLast `
    -taskLastResult ([long]$nightInfo.LastTaskResult) -lastStatusRun $statusLast -running (Test-BisyncRunning) -now (Get-Date) -staleHours $staleH
if ($problem) {
    $first = @($history[$nightKey])[0]
    if (-not $first) {
        $history[$nightKey] = @($now)
        Write-Log "nightly bisync: $problem - watching"
    }
    elseif ($now - $first -ge 600) {
        $sent = Send-DriveSyncAlert -Key $nightKey -Title "Drive-Sync: Nachtlauf bleibt aus" `
            -Body "$problem Der tägliche Abgleich beider Seiten findet nicht statt. Prüfen: sync-status.ps1"
        if ($sent) { Write-Log "nightly bisync: $problem - alerted" }
    }
}
elseif ($history.ContainsKey($nightKey)) {
    $history.Remove($nightKey)
    Clear-DriveSyncAlert $nightKey
    Write-Log "nightly bisync: back to normal"
}

try { Set-Content $historyFile ($history | ConvertTo-Json -Compress) } catch {}
