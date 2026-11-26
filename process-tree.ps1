# Stopping a watcher together with everything it started. Dot-source, then:
#   Stop-ProcessTree $watcherPid
#   Stop-ChildRclone $PID              # from inside: only the rclone below us
#
# Why: Stop-Process ends the watcher alone. A rclone it was waiting for (the
# start-up catch-up, a large upload batch) lives on as an orphan and keeps
# writing to the cloud. On 2026-11-27 restart-watchers.ps1 left the P16's
# catch-up running - scoop shim plus the real rclone below it - while the
# P15's bisync held its lease, and it had to be found and killed by hand.

# Every descendant of $rootId, children first in breadth order.
#
# ParentProcessId alone is not proof: Windows keeps it after the parent died
# and hands that PID out again. A watcher is started through wscript, which
# exits at once - so every watcher carries the PID of a dead process, and the
# next process to get that PID looked like its parent. On 2026-11-27 a test
# stand-in got it, and stopping the stand-in's tree took the P16's upload
# watcher along. A real child is created after its parent: anything older
# than the process it points to is an orphan of an earlier holder of the PID.
# $all: a process snapshot to search instead of the live one (for the tests)
function Get-ProcessTreeIds([int]$rootId, $all = $null) {
    if ($null -eq $all) { $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate -ErrorAction SilentlyContinue) }
    $byId = @{}; foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    if (-not $byId.ContainsKey($rootId)) { return @() }
    $found = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    [void]$seen.Add($rootId)
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($rootId)
    while ($queue.Count) {
        $p = $byId[$queue.Dequeue()]
        foreach ($c in $all | Where-Object { $_.ParentProcessId -eq $p.ProcessId -and $_.CreationDate -ge $p.CreationDate }) {
            if ($seen.Add([int]$c.ProcessId)) { $found.Add($c); $queue.Enqueue([int]$c.ProcessId) }
        }
    }
    @($found)
}

# Root first, so it cannot start anything new, then what it had started.
function Stop-ProcessTree([int]$rootId) {
    $below = Get-ProcessTreeIds $rootId
    Stop-Process -Id $rootId -Force -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($c in $below) { Stop-Process -Id $c.ProcessId -Force -Confirm:$false -ErrorAction SilentlyContinue }
    @($below).Count
}

# The rclone processes below $rootId (a scoop shim and the real binary under
# it), and whatever they started; the root itself stays.
function Stop-ChildRclone([int]$rootId) {
    $n = 0
    foreach ($c in @(Get-ProcessTreeIds $rootId | Where-Object Name -eq 'rclone.exe')) {
        Stop-Process -Id $c.ProcessId -Force -Confirm:$false -ErrorAction SilentlyContinue
        $n++
    }
    $n
}
