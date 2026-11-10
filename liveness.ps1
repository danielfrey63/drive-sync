# Dead man's switch: the pure checks behind the watchdog's liveness tests.
# Dot-source after config.ps1.
#
# Every alarm of this chain is raised by the component that fails - which
# takes a component that still runs. A watcher whose process lives while its
# loop stands still, or a nightly task that is gone, disabled or dies before
# its first line of log, raises nothing. The watchdog is the one piece that
# looks at the others from outside, so the checks live there:
#
# - each watcher touches a stamp file from its main loop (Update-AliveStamp);
#   the watchdog reads its age (Get-WatcherVerdict)
# - the nightly bisync is judged by its scheduled task and status.json
#   (Get-NightlyProblem)

# Called from a watcher's main loop; writes at most once a minute.
function Update-AliveStamp([string]$path) {
    $now = Get-Date
    if ($script:aliveStampedAt -and ($now - $script:aliveStampedAt).TotalSeconds -lt 60) { return }
    $script:aliveStampedAt = $now
    try { [IO.File]::WriteAllText($path, $now.ToString("o")) } catch {}
}

# Last sign of life of a watcher: its stamp, or the process start as long as
# the start-up (the catch-up listing) has not reached the loop yet.
function Get-LastSignOfLife([string]$alivePath, [datetime]$processStart) {
    $t = $processStart
    try {
        $m = (Get-Item -LiteralPath $alivePath -ErrorAction Stop).LastWriteTime
        if ($m -gt $t) { $t = $m }
    }
    catch {}
    return $t
}

# ok     - the loop turned within the limit
# busy   - silent, but waiting for a child rclone: a large transfer blocks the
#          loop for as long as it takes, and that is no fault
# stuck  - silent behind a child rclone for longer than any sane transfer
# silent - silent with nothing to wait for
function Get-WatcherVerdict([datetime]$now, [datetime]$lastSign, [bool]$hasChild, [double]$hungMinutes, [double]$busyHours = 6) {
    $idle = ($now - $lastSign).TotalMinutes
    if ($idle -lt $hungMinutes) { return 'ok' }
    if (-not $hasChild) { return 'silent' }
    if ($idle -ge $busyHours * 60) { return 'stuck' }
    return 'busy'
}

# Why the nightly bisync is not doing its job, as a sentence for the toast -
# or $null. Covers only what sync-drive.ps1 cannot report itself: a run that
# starts and fails writes status.json and raises its own alerts, and so do
# its refusals (exit 2: root not writable, exit 3: baseline too old).
#   $taskLastRun    last start the scheduler recorded ($null = never)
#   $lastStatusRun  start of the last real run in status.json ($null = none)
#   $running        a run holds the bisync lock right now
function Get-NightlyProblem {
    param(
        [bool]$taskExists, [string]$taskState, [Nullable[datetime]]$taskLastRun, [long]$taskLastResult,
        [Nullable[datetime]]$lastStatusRun, [bool]$running, [datetime]$now, [double]$staleHours
    )
    if (-not $taskExists) { return "Die geplante Aufgabe fehlt." }
    if ($taskState -eq 'Disabled') { return "Die geplante Aufgabe ist deaktiviert." }
    if ($running) { return $null }
    $cut = $now.AddHours(-$staleHours)
    $started = $taskLastRun
    if ($null -ne $lastStatusRun -and ($null -eq $started -or $lastStatusRun -gt $started)) { $started = $lastStatusRun }
    if ($null -eq $started) { return "Die geplante Aufgabe ist noch nie gelaufen." }
    if ($started -lt $cut) { return "Seit $($started.ToString('dd.MM. HH:mm')) nicht mehr gestartet." }
    # 267009 = 0x41301, the task is running
    if (($null -eq $lastStatusRun -or $lastStatusRun -lt $cut) -and $taskLastResult -notin 0, 2, 3, 267009) {
        return "Die Aufgabe startet, bricht aber vor dem ersten Schritt ab (Ergebnis $taskLastResult)."
    }
    return $null
}
