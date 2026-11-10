# Shows the drive-sync status and checks the installation against the
# configuration: last run, watchers, pending work, open alerts, and whether
# the scheduled tasks still are what config.ps1 says they should be.
#
# Why the second half: a task keeps the values it was registered with, the
# config moves on, and nothing compared the two. On 2026-11-10 the nightly run
# started at 03:00 while config.ps1 said 04:00 and a config.local.ps1 that had
# come in through the sync said 02:00.
#
# Read-only: it changes nothing and names the script that would.
#
#   pwsh -File sync-status.ps1
#
# Exit code: 0 = every check ok, 1 = at least one WARN.

. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "single-instance.ps1")
. (Join-Path $PSScriptRoot "notify.ps1")
. (Join-Path $PSScriptRoot "delete-journal.ps1")
. (Join-Path $PSScriptRoot "filter-rules.ps1")
$stateDir = $DriveSyncConfig.StateDir
$now = Get-Date

$script:warnings = 0
$script:checks = [System.Collections.Generic.List[string]]::new()
# $state: 'ok', 'WARN' or 'info' (a fact worth seeing that is neither)
function Report([string]$state, [string]$text) {
    if ($state -eq 'WARN') { $script:warnings++ }
    $script:checks.Add(("  {0,-4}  {1}" -f $state, $text))
}
function Read-StateJson([string]$name) {
    $f = Join-Path $stateDir $name
    if (Test-Path $f) { try { Get-Content $f -Raw | ConvertFrom-Json } catch {} }
}
function Format-Time($t) { if ($t) { ([datetime]$t).ToString('yyyy-MM-dd HH:mm') } }
function Get-LockPid([string]$lockName) {
    Get-Content (Join-Path $stateDir $lockName) -TotalCount 1 -ErrorAction SilentlyContinue
}

# --- the nightly bisync ------------------------------------------------------
$s = Read-StateJson "status.json"
if ($s) {
    $flags = "$(if ($s.lastRun.dryRun) { '  (dry-run)' })$(if ($s.lastRun.resync) { '  (resync)' })"
    "Last run:     $(Format-Time $s.lastRun.start)  exit=$($s.lastRun.exitCode)  $($s.lastRun.minutes) min$flags"
}
else { "Last run:     none recorded yet" }
$staleH = [double]$DriveSyncConfig.AlertStaleSyncHours
if ($s -and $s.lastSuccess) {
    $age = [math]::Round(($now - [datetime]$s.lastSuccess.end).TotalHours, 1)
    "Last success: $(Format-Time $s.lastSuccess.end)  ($age h ago)"
    if ($age -lt $staleH) { Report 'ok' "last successful bisync $age h ago" }
    else { Report 'WARN' "last successful bisync $age h ago (limit: $staleH h)" }
}
else {
    "Last success: NEVER"
    Report 'WARN' "no successful bisync recorded"
}
if (Test-BisyncRunning) { "Bisync:       running now (PID $(Get-LockPid 'sync.lock'))" }

# --- the watchers ------------------------------------------------------------
# running = the instance lock is held (the status json only updates on flushes,
# and a PID alone may belong to another process by now)
$paused = Test-Path (Join-Path $stateDir "watchdog-pause")
$hungMin = [double]$DriveSyncConfig.WatcherHungMinutes
$watchers = @(
    @{ Label = "Watcher up:  "; Name = "upload watcher"; Instance = "watch-drive"; Lock = "watcher.lock"
       Alive = "watcher.alive"; Status = "watcher-status.json"
       Counters = { param($w) "up=$($w.uploadedTotal) ren=$($w.renamedTotal) del=$($w.deletedTotal) parked=$([int]$w.parkedUploads)" } }
    @{ Label = "Watcher down:"; Name = "cloud watcher"; Instance = "watch-cloud"; Lock = "cloud-watcher.lock"
       Alive = "cloud-watcher.alive"; Status = "cloud-watcher-status.json"
       Counters = { param($w) "down=$($w.downloadedTotal) recycled=$($w.recycledTotal)" } }
)
foreach ($w in $watchers) {
    $ws = Read-StateJson $w.Status
    $stats = if ($ws) { "lastFlush=$(Format-Time $ws.lastFlush)  $(& $w.Counters $ws)" } else { "no flush recorded yet" }
    if (-not (Test-InstanceRunning $w.Instance)) {
        "$($w.Label) NOT RUNNING  $stats"
        Report 'WARN' "$($w.Name) is not running - $(if ($paused) { 'and watchdog-pause keeps the watchdog from restarting it' } else { 'the watchdog restarts it within 15 min, or: restart-watchers.ps1' })"
        continue
    }
    $stamp = Join-Path $stateDir $w.Alive
    $loop = "no sign-of-life stamp"
    if (Test-Path $stamp) {
        $silent = [math]::Round(($now - (Get-Item $stamp).LastWriteTime).TotalMinutes)
        $loop = "loop alive $silent min ago"
        if ($silent -ge $hungMin) { Report 'WARN' "$($w.Name): main loop silent for $silent min - the watchdog tells a long transfer from a hang and restarts a hung one" }
        else { Report 'ok' "$($w.Name) running, main loop alive" }
    }
    else { Report 'WARN' "$($w.Name) runs code from before the dead man's switch (no stamp) - restart-watchers.ps1" }
    "$($w.Label) running (PID $(Get-LockPid $w.Lock)), $loop  $stats"
}
if ($paused) {
    Report 'WARN' "watchdog-pause is set since $(Format-Time (Get-Item (Join-Path $stateDir 'watchdog-pause')).LastWriteTime) - died or hung watchers are not restarted"
}

# --- pending work and open alerts --------------------------------------------
$j1 = @(Read-DroppedDeletes $stateDir "path1").Count
$j2 = @(Read-DroppedDeletes $stateDir "path2").Count
if ($j1 + $j2) { Report 'info' "delete journal: $j1 local and $j2 cloud delete(s) wait for the next bisync" }
$open = @(Get-DriveSyncOpenAlerts)
if ($open.Count -eq 0) { Report 'ok' "no open alerts" }
foreach ($a in $open) { Report 'WARN' "alert '$($a.Key)' is open since $(Format-Time $a.Raised) - see alerts.log" }

# --- installation against configuration --------------------------------------
$expected = @(
    @{ Name = "DriveSync rclone bisync"; Script = "sync-drive.ps1"; Fix = "install-sync-task.ps1" }
    @{ Name = "DriveSync watcher"; Script = "watch-drive.ps1"; Fix = "install-watcher-task.ps1"; Logon = $true }
    @{ Name = "DriveSync cloud watcher"; Script = "watch-cloud.ps1"; Fix = "install-watcher-task.ps1"; Logon = $true }
    @{ Name = "DriveSync watchdog"; Script = "watchdog.ps1"; Fix = "install-watcher-task.ps1" }
)
$tasksOk = 0
$nightTask = $null
foreach ($e in $expected) {
    $task = Get-ScheduledTask -TaskName $e.Name -ErrorAction SilentlyContinue
    if (-not $task) { Report 'WARN' "task '$($e.Name)' is not registered - $($e.Fix)"; continue }
    if ($e.Script -eq "sync-drive.ps1") { $nightTask = $task }
    $bad = $false
    if ($task.State -eq 'Disabled') { Report 'WARN' "task '$($e.Name)' is disabled"; $bad = $true }
    $want = Join-Path $PSScriptRoot $e.Script
    $runs = "$($task.Actions[0].Arguments)"
    if ($runs.IndexOf($want, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Report 'WARN' "task '$($e.Name)' does not run this copy ($want) but: $runs - $($e.Fix)"; $bad = $true
    }
    if ($e.Logon -and "$($task.Triggers[0].Delay)" -ne "$($DriveSyncConfig.WatcherLogonDelay)") {
        Report 'WARN' "task '$($e.Name)' starts $($task.Triggers[0].Delay) after logon, the config says $($DriveSyncConfig.WatcherLogonDelay) - $($e.Fix)"; $bad = $true
    }
    if (-not $bad) { $tasksOk++ }
}
if ($tasksOk -eq $expected.Count) { Report 'ok' "scheduled tasks: all $tasksOk registered, enabled and running this copy" }

if ($nightTask) {
    $wantAt = "$($DriveSyncConfig.BisyncDailyAt)"
    $source = if ("$($DriveSyncConfigDefaults.BisyncDailyAt)" -ne $wantAt) { " (config.local.ps1; config.ps1 says $($DriveSyncConfigDefaults.BisyncDailyAt))" } else { "" }
    $next = ($nightTask | Get-ScheduledTaskInfo).NextRunTime
    $isAt = if ($next) { $next.ToString('HH:mm') }
    # a start with "Z" or a UTC offset is an instant: the scheduler keeps it
    # through the daylight-saving change, and the wall-clock hour moves
    $pinned = "$($nightTask.Triggers[0].StartBoundary)" -match '(Z|[+-]\d\d:\d\d)$'
    if ($isAt -and $isAt -ne $wantAt) {
        Report 'WARN' "nightly bisync starts at $isAt, the config says $wantAt$source - install-sync-task.ps1 registers the configured time"
    }
    elseif ($isAt) { Report 'ok' "nightly bisync starts at $isAt, as configured" }
    if ($pinned) {
        Report 'WARN' "nightly bisync: the start is stored as an instant and moves by an hour with daylight saving - install-sync-task.ps1 registers it as wall-clock time"
    }
}

$localConfig = Join-Path $PSScriptRoot "config.local.ps1"
if (Test-Path $localConfig) {
    $diff = @($DriveSyncConfigDefaults.Keys | Sort-Object | Where-Object { "$($DriveSyncConfig[$_])" -ne "$($DriveSyncConfigDefaults[$_])" } |
        ForEach-Object { "$_ = $($DriveSyncConfig[$_]) (default $($DriveSyncConfigDefaults[$_]))" })
    Report 'info' "config.local.ps1 $(if ($diff) { "sets: $($diff -join '; ')" } else { 'is present and changes nothing' })"
    # "machine-specific" only holds if the file stays on this machine
    $root = "$($DriveSyncConfig.LocalRoot)".TrimEnd('\') + '\'
    if ($localConfig.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $localConfig.Substring($root.Length)
        $rules = Get-ExcludeRules (Join-Path $PSScriptRoot "filters.txt")
        if (-not (Test-Excluded $rules $rel)) {
            Report 'WARN' "config.local.ps1 lies in the synced tree and is not filtered: every machine gets the same 'machine-specific' file"
        }
    }
}

# --- the things the chain leans on -------------------------------------------
if (-not (Test-Path -LiteralPath $DriveSyncConfig.LocalRoot)) { Report 'WARN' "local root $($DriveSyncConfig.LocalRoot) is not there" }
# the PATH rclone runs the bisync and tells the custom build (watchers) where
# the config is - without it neither works
$custom = if (Test-Path (Join-Path $stateDir "bin\rclone.exe")) { ", custom build for the watchers" } else { "" }
if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) { Report 'WARN' "rclone is not on the PATH" }
elseif (@(& rclone listremotes 2>$null) -notcontains $DriveSyncConfig.Remote) { Report 'WARN' "rclone knows no remote '$($DriveSyncConfig.Remote)' (rclone listremotes)" }
else { Report 'ok' "rclone remote $($DriveSyncConfig.Remote) is configured$custom" }

# bisync remembers the hash of the filters file and refuses to run on another
$filters = Join-Path $PSScriptRoot "filters.txt"
$known = Get-Content "$filters.md5" -TotalCount 1 -ErrorAction SilentlyContinue
if ($known -and $known.Trim() -ne (Get-FileHash $filters -Algorithm MD5).Hash) {
    Report 'WARN' "filters.txt changed since the last resync: the next bisync stops and asks for one (sync-drive.ps1 -Resync -ResyncMode newer)"
}
if (-not (Test-Path -LiteralPath $script:toastScript)) { Report 'WARN' "toast helper missing ($script:toastScript): alerts are only written to alerts.log" }
$hooksDir = & git -C $PSScriptRoot rev-parse --git-path hooks 2>$null
if ($hooksDir) {
    if (-not [IO.Path]::IsPathRooted($hooksDir)) { $hooksDir = Join-Path $PSScriptRoot $hooksDir }
    $hook = Join-Path $hooksDir "pre-commit"
    if (-not ((Test-Path $hook) -and (Select-String -Path $hook -Pattern 'drive-sync:check-text' -SimpleMatch -Quiet))) {
        Report 'WARN' "pre-commit hook of this clone lacks the text check - install-git-hook.ps1"
    }
}

""
"Checks"
$script:checks
if ($s -and $s.lastRun.log -and (Test-Path $s.lastRun.log)) {
    ""
    "--- log tail ---"
    Get-Content $s.lastRun.log -Tail 5
}
exit $(if ($script:warnings) { 1 } else { 0 })
