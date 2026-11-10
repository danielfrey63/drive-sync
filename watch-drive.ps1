# Stage-B watcher: near-realtime UPLOAD of local changes in "D:\Meine Ablage"
# to gdrive:, complementing the nightly bisync (which reconciles cloud-side
# renames, conflicts and anything the watchers missed).
#
# Design:
#  - FileSystemWatcher (recursive) queues Created/Changed/Renamed/Deleted
#    events; batches are debounced (15s quiet / 60s max age).
#  - Uploads run via "rclone copy --files-from-raw --no-traverse" - no tree
#    listing at all.
#  - Renames become server-side "rclone moveto" (no re-upload); if the old
#    path does not exist in the cloud, the new path is uploaded instead.
#  - Deletes are verified at flush time (path must really be gone locally),
#    folded (a removed folder counts once), capped at $maxDeletes per flush
#    and go to the Drive TRASH (30 days) - never hard-deleted. A storm above
#    the cap is NOT simply dropped: its paths are journalled
#    (delete-journal.ps1) and carried out before the next bisync
#    (journal-replay.ps1), because bisync alone cannot always read them as
#    deletions - see there.
#  - Exclude rules are DERIVED FROM filters.txt (shared filter-rules.ps1).
#  - While the bisync wrapper's lock is active, flushing is deferred.
#  - Watcher buffer overflows are only logged: the nightly bisync catches up.
#  - Start-up catch-up: a liveness stamp (watcher-lastseen.txt, refreshed with
#    every heartbeat) marks the last covered moment; on start, files modified
#    since then are uploaded via "rclone copy --max-age" so a watcher outage
#    no longer parks new files until the nightly bisync. Deletes/renames from
#    the gap remain bisync territory.
#
# Meant to run permanently via the "DriveSync watcher" logon task
# (install-watcher-task.ps1). Single instance enforced by a PID lock.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
$root = $DriveSyncConfig.LocalRoot
$remote = $DriveSyncConfig.Remote
$filters = Join-Path $PSScriptRoot "filters.txt"
$stateDir = $DriveSyncConfig.StateDir
$logFile = Join-Path $stateDir "watcher.log"
# A crash outside the loop's own error handling (a missing module, a parse
# error in a dot-sourced file) used to leave no trace: the watchdog saw only a
# dead PID and restarted the task every 15 min for hours (2026-10-20). The
# FATAL line is what the watchdog quotes in its alert.
trap { try { Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') FATAL: $($_.Exception.Message)" } catch {}; break }
$statusFile = Join-Path $stateDir "watcher-status.json"
$lockFile = Join-Path $stateDir "watcher.lock"
$bisyncLock = Join-Path $stateDir "sync.lock"

# --- single instance, before the slow start-up (single-instance.ps1) ---------
. (Join-Path $PSScriptRoot "single-instance.ps1")
$script:instance = Enter-SingleInstance "watch-drive" $lockFile
if (-not $script:instance) {
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') another watcher (PID $(Get-Content $lockFile -TotalCount 1 -ErrorAction SilentlyContinue)) is active - exiting" -ErrorAction SilentlyContinue
    exit 0
}
# sign of life for the watchdog, touched from the main loop (liveness.ps1)
. (Join-Path $PSScriptRoot "liveness.ps1")
$aliveFile = Join-Path $stateDir "watcher.alive"
$lastSeenFile = Join-Path $stateDir "watcher-lastseen.txt"
$maxDeletes = $DriveSyncConfig.MaxDeletes
$journalDrops = [bool]$DriveSyncConfig.JournalDroppedDeletes
$pacer = $DriveSyncConfig.Pacer
# custom build (release + --files-from-strict backport) if deployed, else PATH rclone
$rcloneExe = Join-Path $stateDir "bin\rclone.exe"
if (-not (Test-Path $rcloneExe)) { $rcloneExe = "rclone" }
elseif (-not $env:RCLONE_CONFIG) {
    # the custom build defaults to %APPDATA%, but scoop keeps the config in its
    # persist dir - resolve it via the PATH rclone once and pin it
    $cfg = @(& rclone config file 2>$null)[-1]
    if ($cfg -and (Test-Path $cfg)) { $env:RCLONE_CONFIG = $cfg }
}
New-Item -ItemType Directory -Force $stateDir | Out-Null
# --files-from-strict is a pending upstream contribution (rclone PR #9598):
# with it, a stale path mapping fails the batch loudly instead of being
# skipped silently. Detected at runtime so a stock rclone release works too.
$strictFlag = @()
if (& $rcloneExe help flags files-from-strict 2>$null | Select-String -Quiet "files-from-strict") {
    $strictFlag = @("--files-from-strict")
}

function Write-Log([string]$msg) {
    # logging must never kill the watcher
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 10MB) {
            Move-Item $logFile "$logFile.1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ErrorAction SilentlyContinue
    }
    catch {}
}

# Diagnostic event trace: every raw FSW event with source and path, BEFORE
# any filtering. Added to explain why dir renames/deletes during the
# 2026-08-28 restructuring never reached the queues ("0 ren / 0 del pending"
# all night). Cheap (one Add-Content per drain cycle), capped at 2x10MB.
$eventLogFile = Join-Path $stateDir "watcher-events.log"
function Write-EventLog([string[]]$lines) {
    try {
        if ((Test-Path $eventLogFile) -and (Get-Item $eventLogFile).Length -gt 10MB) {
            Move-Item $eventLogFile "$eventLogFile.1" -Force -ErrorAction SilentlyContinue
        }
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        # the drain number tells which events were read together - needed to
        # see whether a change and a rename shared a drain (test-pending-rename.ps1)
        $script:drainSeq++
        Add-Content $eventLogFile @($lines | ForEach-Object { "$ts $_`t#d$script:drainSeq" }) -ErrorAction SilentlyContinue
    }
    catch {}
}

# --- journal for deletes the cap drops --------------------------------------
. (Join-Path $PSScriptRoot "delete-journal.ps1")

# --- local intent: tells the cloud watcher what is gone here on purpose -----
. (Join-Path $PSScriptRoot "local-intent.ps1")

# --- recycle bin: for copies a resync brought back under an old name --------
. (Join-Path $PSScriptRoot "recycle-bin.ps1")

# --- derive exclude sets from filters.txt -----------------------------------
. (Join-Path $PSScriptRoot "filter-rules.ps1")
$rules = Get-ExcludeRules $filters
Write-Log "started (PID $PID): $($rules.Dirs.Count) dir rules, $($rules.Exts.Count) ext rules, $($rules.Names.Count) name rules, $($rules.Suffixes.Count) suffix rules"

# --- watcher + event queue --------------------------------------------------
# Events are drained from the session event queue via Wait-Event/Get-Event:
# -Action blocks would not run reliably while the main loop sleeps.
$fsw = [System.IO.FileSystemWatcher]::new($root)
$fsw.IncludeSubdirectories = $true
# 1 MB (~5000 events): the kernel buffer sees ALL events below the root,
# also excluded ones - dev-tool bursts (npm install, branch switches) would
# overflow the 64 KB default long before our filters even run
$fsw.InternalBufferSize = 1MB
$fsw.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::DirectoryName -bor [IO.NotifyFilters]::LastWrite

Register-ObjectEvent $fsw Created -SourceIdentifier fswCreated | Out-Null
Register-ObjectEvent $fsw Changed -SourceIdentifier fswChanged | Out-Null
Register-ObjectEvent $fsw Renamed -SourceIdentifier fswRenamed | Out-Null
Register-ObjectEvent $fsw Deleted -SourceIdentifier fswDeleted | Out-Null
Register-ObjectEvent $fsw Error -SourceIdentifier fswError | Out-Null
$fsw.EnableRaisingEvents = $true

# --- queues ------------------------------------------------------------------
$pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$renames = [System.Collections.Generic.List[object]]::new()   # ordered: chains must replay in order
$deletes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$lastEvent = $null
$oldestPending = $null
$uploadedTotal = 0
$renamedTotal = 0
$deletedTotal = 0

# A pending upload follows its file through a rename. Otherwise the flush finds
# the old path gone, drops it, and the server-side move carries the cloud's
# STALE content to the new name: on 2026-10-21 a mail draft was saved at
# 10:15:38 and renamed at 10:15:39 - the cloud kept the 10:11 version until the
# nightly bisync parked it as .conflict1. Covers folder renames by prefix.
function Move-PendingPaths([string]$oldRel, [string]$newRel) {
    $prefix = "$oldRel\"
    foreach ($p in @($pending)) {
        if ($p -ieq $oldRel) { $moved = $newRel }
        elseif ($p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $moved = $newRel + $p.Substring($oldRel.Length) }
        else { continue }
        [void]$pending.Remove($p)
        [void]$pending.Add($moved)
    }
}

# A change event queues its file. Files only: a timestamp touch on a directory
# (e.g. by a sync download into it) must not enqueue its entire subtree. A path
# that is gone by now is queued too: it may have been renamed in the same
# drain, and the rename event that follows carries it to the new name
# (Move-PendingPaths). Dropping it lost the upload on 2026-11-02 - written and
# renamed within 16:59:12, the cloud kept the 29.10. content under the new
# name. The upload stage drops whatever is missing or a directory.
function Add-ChangedPath([string]$abs, [string]$rel) {
    if (-not (Test-Path -LiteralPath $abs -PathType Container)) { [void]$pending.Add($rel) }
}

function Test-BisyncRunning {
    if (-not (Test-Path $bisyncLock)) { return $false }
    $lockPid = Get-Content $bisyncLock -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue))
}

# A rename that waited out a bisync is checked after its server-side move: a
# --resync merges both sides without deleting, sees the old name in the cloud
# and the new one on disk, and copies the old name back down. The m4a moved
# into protokolle\2026-10-20 during the 66-min resync of 2026-10-20 came back
# that way. An old path on disk again with the size and modtime of the new
# one is that copy: recycle it and drop the upload its download queued. A
# file that differs is somebody's work and stays.
function Remove-RevivedRenameSource([string]$oldRel, [string]$newRel) {
    $oldAbs = Join-Path $root $oldRel
    $newAbs = Join-Path $root $newRel
    if (Test-Path -LiteralPath $oldAbs -PathType Leaf) { $files = @(Get-Item -LiteralPath $oldAbs -Force) }
    elseif (Test-Path -LiteralPath $oldAbs -PathType Container) { $files = @(Get-ChildItem -LiteralPath $oldAbs -Recurse -File -Force) }
    else { return }
    $recycled = 0; $kept = 0
    foreach ($o in $files) {
        $suffix = $o.FullName.Substring($oldAbs.Length)
        $n = Get-Item -LiteralPath ($newAbs + $suffix) -Force -ErrorAction SilentlyContinue
        $same = $n -and -not $n.PSIsContainer -and $n.Length -eq $o.Length -and
            [math]::Abs(($n.LastWriteTimeUtc - $o.LastWriteTimeUtc).TotalSeconds) -le 1
        if ($same -and (Move-ToRecycleBin $o.FullName) -eq 0) {
            [void]$pending.Remove($oldRel + $suffix)
            $recycled++
        }
        else { $kept++ }
    }
    if (Test-Path -LiteralPath $oldAbs -PathType Container) {
        # folders the recycled files left empty, deepest first
        $dirs = @(Get-ChildItem -LiteralPath $oldAbs -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending) + @(Get-Item -LiteralPath $oldAbs -Force)
        foreach ($d in $dirs) {
            if (-not (Get-ChildItem -LiteralPath $d.FullName -Force | Select-Object -First 1)) { [IO.Directory]::Delete($d.FullName) }
        }
    }
    Write-Log "revived by bisync under the old name $($oldRel -replace '\\', '/'): $recycled recycled, $kept kept (differ)"
}

function Add-PendingPath([string]$abs, [string]$rel) {
    if ([string]::IsNullOrWhiteSpace($rel)) {
        # phantom event for the watch root itself (seen twice on 2026-08-12,
        # rel = ""): enumerating it would enqueue the entire corpus (1.23M
        # files) and poison the flush - the nightly bisync owns full passes
        Write-Log "WARN ignoring event for watch root (would enqueue the whole corpus)"
        return
    }
    if (Test-Path -LiteralPath $abs -PathType Container) {
        # new/renamed directory: enqueue its files (move-in raises only one event)
        $added = 0
        Get-ChildItem -LiteralPath $abs -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $r = $_.FullName.Substring($root.Length + 1)
            if (-not (Test-Excluded $rules $r)) { if ($pending.Add($r)) { $added++ } }
        }
        # always name the trigger dir for big fan-outs: a phantom event on a
        # top-level dir once enqueued 1.2M files with no trace of the culprit
        if ($added -gt 1000) { Write-Log "WARN dir event fanned out to $added file(s): $rel" }
    }
    elseif (Test-Path -LiteralPath $abs -PathType Leaf) { [void]$pending.Add($rel) }
}

function Write-Status {
    [ordered]@{
        pid = $PID; lastFlush = (Get-Date).ToString("s")
        uploadedTotal = $uploadedTotal; renamedTotal = $renamedTotal; deletedTotal = $deletedTotal
        parkedUploads = $parked.Count
    } | ConvertTo-Json | Set-Content $statusFile
}

# Uploads that keep failing (upload-retry.ps1): a file that fails on its own
# is parked with a growing delay, a batch that fails as a whole pauses all
# uploads. Either one raises a toast once it has lasted AlertUploadStuckMinutes
# and clears it when it is over.
. (Join-Path $PSScriptRoot "upload-retry.ps1")
. (Join-Path $PSScriptRoot "notify.ps1")
$parked = New-UploadParking
$flushLog = Join-Path $stateDir "watcher-flush.log"
$uploadFailures = 0
$uploadFailSince = $null
$uploadHoldUntil = [datetime]::MinValue
$stuckMinutes = if ($DriveSyncConfig.AlertUploadStuckMinutes) { [double]$DriveSyncConfig.AlertUploadStuckMinutes } else { 60 }
# true at start: the first good flush clears an alert a previous instance left
$script:uploadAlerted = $true
function Update-UploadAlert {
    $now = Get-Date
    $stuck = @(Get-StuckUploads $parked $now $stuckMinutes)
    if ($stuck.Count -gt 0) {
        $script:uploadAlerted = $true
        Send-DriveSyncAlert -Key "upload-stuck" -Title "Drive-Sync: Upload hängt" `
            -Body "$($stuck.Count) Datei(en) lassen sich seit über $stuckMinutes min nicht hochladen, z.B. $($stuck[0].Rel): $($stuck[0].Reason)" | Out-Null
    }
    elseif ($uploadFailSince -and ($now - $uploadFailSince).TotalMinutes -ge $stuckMinutes) {
        $script:uploadAlerted = $true
        Send-DriveSyncAlert -Key "upload-stuck" -Title "Drive-Sync: Uploads scheitern" `
            -Body "Seit $([int]($now - $uploadFailSince).TotalMinutes) min kommt kein Upload durch (Netz, Anmeldung oder Kontingent?). Details in watcher.log." | Out-Null
    }
    elseif ($script:uploadAlerted) {
        $script:uploadAlerted = $false
        Clear-DriveSyncAlert "upload-stuck"
    }
}

# Every path we upload/rename is recorded here so the cloud watcher can tell
# our own change events apart from genuine cloud-side changes (echo control).
# Each entry carries the modtime and size of what was uploaded, so a later
# change of the same path by another machine is not mistaken for an echo
# (upload-ledger.ps1 has the 2026-10-03 incident).
. (Join-Path $PSScriptRoot "upload-ledger.ps1")
. (Join-Path $PSScriptRoot "conflict-names.ps1")
function Add-LedgerEntries([string[]]$rels) {
    try { Add-UploadLedger $stateDir $root $rels }
    catch { Write-Log "WARN ledger update failed: $($_.Exception.Message)" }
}

# --- start-up catch-up ------------------------------------------------------
# The FSW is already live at this point, so there is no coverage gap: files
# changed while no watcher was running are copied up; unchanged candidates
# are skipped by the size+modtime compare, --update never overwrites newer
# cloud versions. The full local listing takes a few minutes; FSW events
# raised meanwhile simply queue up for the main loop.
#
# The liveness stamp means "everything modified up to this moment is uploaded
# or captured by the live FSW". It therefore only advances on a SUCCESSFUL
# catch-up (to the catch-up START time, so changes made during the run stay
# covered) and later only while no work is pending (see Update-LastSeen).
try {
    $lastSeen = $null
    if (Test-Path $lastSeenFile) {
        try { $lastSeen = [datetime]::Parse((Get-Content $lastSeenFile -TotalCount 1), $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
    }
    if (Test-BisyncRunning) {
        # stamp untouched: the bisync reconciles the gap, the heartbeat takes over
        Write-Log "catch-up skipped: bisync (PID $(Get-Content $bisyncLock -TotalCount 1)) is running and reconciles the gap"
    }
    elseif ($null -eq $lastSeen) {
        Write-Log "catch-up skipped: no liveness stamp yet (first run)"
        Set-Content $lastSeenFile ((Get-Date).ToString("o"))
    }
    else {
        $cuStart = Get-Date
        # 5 min margin on top of the gap for clock skew and rounding
        $maxAge = [math]::Ceiling(($cuStart - $lastSeen).TotalSeconds) + 300
        $cuLog = Join-Path $stateDir "watcher-catchup.log"
        Remove-Item $cuLog -Force -Confirm:$false -ErrorAction SilentlyContinue
        # below-normal priority (rclone inherits the class) and halved listing
        # concurrency: the full corpus listing must never starve foreground
        # work, only the catch-up may take longer
        $self = Get-Process -Id $PID
        $prevPriority = $self.PriorityClass
        $self.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
        try {
            & $rcloneExe copy $root $remote --max-age "${maxAge}s" --filter-from $filters `
                --no-traverse --update --modify-window 1s @pacer --transfers 4 --checkers 4 `
                --log-level INFO --log-file $cuLog 2>$null
            $cuExit = $LASTEXITCODE
        }
        finally { $self.PriorityClass = $prevPriority }
        $copied = @()
        if (Test-Path $cuLog) {
            $copied = @(Select-String -Path $cuLog -Pattern 'INFO\s+: (.+): Copied \(' |
                ForEach-Object { $_.Matches[0].Groups[1].Value -replace '/', '\' })
        }
        if ($copied.Count -gt 0) { Add-LedgerEntries $copied }
        Write-Log "catch-up: gap since $($lastSeen.ToString('s')), $($copied.Count) file(s) uploaded, exit=$cuExit"
        if ($cuExit -eq 0) { Set-Content $lastSeenFile ($cuStart.ToString("o")) }
    }
}
catch { Write-Log "WARN catch-up failed: $($_.Exception.Message)" }

# Advance the liveness stamp only when every queue is empty: pending work
# lies BEFORE now, and stamping over it would hide it from the next catch-up.
# A parked upload is pending work too.
function Update-LastSeen {
    if (($pending.Count + $renames.Count + $deletes.Count + $parked.Count) -eq 0) {
        try { Set-Content $lastSeenFile ((Get-Date).ToString("o")) } catch {}
    }
}

# --- main loop: debounce and flush ------------------------------------------
$lastHeartbeat = Get-Date
try {
    while ($true) {
        $null = Wait-Event -Timeout 3
        Update-AliveStamp $aliveFile
        if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 10) {
            Write-Log "heartbeat: $($pending.Count) up / $($renames.Count) ren / $($deletes.Count) del pending$(if ($parked.Count) { ", $($parked.Count) upload(s) parked" })"
            $lastHeartbeat = Get-Date
            Update-LastSeen
        }
        # parked uploads whose delay has run out go back into the queue, and
        # are flushed without waiting for an event
        foreach ($r in @(Get-DueUploads $parked (Get-Date))) {
            if ($pending.Add($r) -and $null -eq $oldestPending) { $oldestPending = (Get-Date).AddSeconds(-60) }
        }
        $drained = 0
        $evtTrace = [System.Collections.Generic.List[string]]::new()
        # old paths of renames and deleted paths, published to the cloud watcher
        # right after this drain - NOT at flush time, which can be minutes later
        # (local-intent.ps1 has the 2026-09-17 incident)
        $intent = [System.Collections.Generic.List[string]]::new()
        foreach ($evt in @(Get-Event)) {
            $drained++
            $src = $evt.SourceIdentifier
            $ea = $evt.SourceEventArgs
            Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
            $lastEvent = Get-Date
            if ($src -eq "fswError") { Write-Log "WARN event buffer overflow - nightly bisync will reconcile"; $evtTrace.Add("fswError OVERFLOW"); continue }
            $path = $ea.FullPath
            if (-not $path.StartsWith($root)) { continue }
            $rel = $path.Substring($root.Length + 1)
            if ($src -eq "fswRenamed") { $evtTrace.Add("$src $($ea.OldFullPath.Substring($root.Length + 1)) -> $rel") }
            else { $evtTrace.Add("$src $rel") }

            if ($src -eq "fswDeleted") {
                if (-not (Test-Excluded $rules $rel)) { [void]$deletes.Add($rel); $intent.Add($rel) }
            }
            elseif ($src -eq "fswRenamed") {
                $oldRel = $ea.OldFullPath.Substring($root.Length + 1)
                # bisync parking a conflict loser (X -> X.conflictN): it has
                # already settled both sides. Replaying the rename in the
                # cloud would move the WINNER onto the conflict name and seed
                # a conflict on the conflict file (conflict-names.ps1).
                if (Test-ConflictLoserRename $oldRel $rel) { continue }
                $oldOk = -not (Test-Excluded $rules $oldRel)
                $newOk = -not (Test-Excluded $rules $rel)
                if ($oldOk -and $oldRel -like "*.partial") { $oldOk = $false }   # rclone download temp -> plain create
                if ($oldOk) { $intent.Add($oldRel) }
                if ($newOk) { Move-PendingPaths $oldRel $rel }
                if ($oldOk -and $newOk) { $renames.Add([pscustomobject]@{ Old = $oldRel; New = $rel; DuringBisync = $false }) }
                elseif ($oldOk) { [void]$deletes.Add($oldRel) }   # renamed INTO an excluded name
                elseif ($newOk) { Add-PendingPath $path $rel }    # renamed OUT of an excluded/temp name
            }
            elseif ($src -eq "fswChanged") {
                if (-not (Test-Excluded $rules $rel)) { Add-ChangedPath $path $rel }
            }
            else {
                if (-not (Test-Excluded $rules $rel)) { Add-PendingPath $path $rel }
            }
            if ($null -eq $oldestPending) { $oldestPending = Get-Date }
        }
        if ($intent.Count -gt 0) { Add-LocalIntent $stateDir @($intent) }
        if ($evtTrace.Count -gt 0) { Write-EventLog $evtTrace }
        if ($drained -gt 0) { Write-Log "events: $drained drained, $($pending.Count) up / $($renames.Count) ren / $($deletes.Count) del pending" }

        if (($pending.Count + $renames.Count + $deletes.Count) -eq 0) { $oldestPending = $null; continue }
        # checked on every pass, not only when a flush is due: a rename made in
        # the last seconds of a resync must be marked too
        $bisyncRunning = Test-BisyncRunning
        if ($bisyncRunning) { foreach ($rn in $renames) { $rn.DuringBisync = $true } }
        $quiet = $lastEvent -and ((Get-Date) - $lastEvent).TotalSeconds -ge 15
        $overdue = $oldestPending -and ((Get-Date) - $oldestPending).TotalSeconds -ge 60
        if (-not ($quiet -or $overdue)) { continue }

        # defer while the nightly bisync holds its lock
        if ($bisyncRunning) { continue }
        # nothing but uploads queued, and those are paused after a failed batch
        if (($renames.Count + $deletes.Count) -eq 0 -and (Get-Date) -lt $uploadHoldUntil) { continue }
        $oldestPending = $null

        # the flush cycle must never kill the watcher - log and carry on
        $inFlight = @()
        try {
            # paths whose local rename/delete the cloud now reflects; their
            # intent entries are completed at the end of the flush
            $intentDone = [System.Collections.Generic.List[string]]::new()

            # 1) renames: server-side moves, in event order (rename chains)
            $renList = @($renames)
            for ($i = 0; $i -lt $renList.Count; $i++) {
                $rn = $renList[$i]
                $newAbs = Join-Path $root $rn.New
                if (-not (Test-Path -LiteralPath $newAbs)) {
                    # The file already left its new name - a rename followed by
                    # a move or a second rename inside one debounce window, or
                    # queued behind a long flush. The cloud still holds it under
                    # the OLD name, and that copy has to follow the file: skipping
                    # it left the old name in the cloud and the nightly bisync
                    # brought it back as a new file (2026-09-17: renamed, then
                    # moved into a subfolder -> old name back at 04:26).
                    $next = $null
                    for ($j = $i + 1; $j -lt $renList.Count; $j++) {
                        if ($renList[$j].Old -ieq $rn.New) { $next = $renList[$j]; break }
                    }
                    if ($next) { $next.Old = $rn.Old; $intentDone.Add($rn.New) }   # A->B, B->C replays as A->C; B never reached the cloud
                    elseif (-not (Test-Path -LiteralPath (Join-Path $root $rn.Old))) {
                        # moved elsewhere (Deleted + Created, uploaded as new) or
                        # deleted: the old cloud copy goes to the trash
                        [void]$deletes.Add($rn.Old)
                    }
                    continue
                }
                $oldR = $rn.Old -replace '\\', '/'
                $newR = $rn.New -replace '\\', '/'
                if ($oldR -ceq $newR) { $intentDone.Add($rn.Old); continue }   # chain came back to its start
                if ($oldR -ne $newR -and $oldR -ieq $newR) {
                    # case-only rename: Drive's case-insensitive path lookup
                    # resolves source and destination to the same object, the
                    # direct moveto fails and the fallback would re-upload the
                    # whole tree (340 MB on 2026-08-28) - go via a temp name
                    $tmpR = "$newR.casemv-tmp"
                    & $rcloneExe moveto "$remote$oldR" "$remote$tmpR" @pacer --log-level ERROR --log-file $logFile 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        & $rcloneExe moveto "$remote$tmpR" "$remote$newR" @pacer --log-level ERROR --log-file $logFile 2>$null
                        if ($LASTEXITCODE -eq 0) {
                            $renamedTotal++
                            Write-Log "rename (case-only, 2-step): $oldR -> $newR"
                            Add-LedgerEntries @($rn.New, "$($rn.New).casemv-tmp")
                            $intentDone.Add($rn.Old)
                            continue
                        }
                        # step 2 failed: move back so no .casemv-tmp orphan is
                        # left for bisync to download as a new file
                        & $rcloneExe moveto "$remote$tmpR" "$remote$oldR" @pacer --log-level ERROR --log-file $logFile 2>$null
                    }
                    Write-Log "WARN case-only 2-step moveto failed for $newR - falling back"
                }
                # --retries 1: an old path the cloud never had (every temp-file
                # save) fails the same way three times over - 1308 such moves
                # left 3924 error lines in one log. The upload below is the retry.
                & $rcloneExe moveto "$remote$oldR" "$remote$newR" @pacer --retries 1 --log-level ERROR --log-file $logFile 2>$null
                $moveExit = $LASTEXITCODE
                if ($moveExit -eq 0) {
                    $renamedTotal++
                    Write-Log "rename: $oldR -> $newR"
                    Add-LedgerEntries @($rn.New)
                    $intentDone.Add($rn.Old)
                    if ($rn.DuringBisync) { Remove-RevivedRenameSource $rn.Old $rn.New }
                }
                else {
                    # old path unknown in the cloud (e.g. editor tmp-file save): upload instead
                    Write-Log "rename fallback to upload: $newR"
                    Add-PendingPath $newAbs $rn.New
                    # exit 3/4 = the old path never existed in the cloud, so there
                    # is nothing to resurrect: complete the intent now. These are
                    # the bulk - 258 temp-file saves against 15 real renames in one
                    # hour on 2026-09-17 - and would otherwise sit in the record
                    # for the full hour. Any other failure may have left the old
                    # path in the cloud; that entry stays and ages out.
                    if ($moveExit -in 3, 4) { $intentDone.Add($rn.Old) }
                }
            }
            $renames.Clear()

            # 2) uploads - files still being written stay queued: uploading a
            #    file mid-write ends in "corrupted on transfer" and rclone's
            #    cleanup trashes the cloud copy, which started the 2026-08-29
            #    delete chain. 10s of write silence is required before upload.
            $now = Get-Date
            $settleCut = $now.AddSeconds(-10)
            $hot = 0
            $batch = @()
            # after a batch that failed as a whole, uploads wait out a growing
            # pause; the queue keeps collecting meanwhile
            if ($now -ge $uploadHoldUntil) {
                $batch = @(foreach ($r in @($pending)) {
                        $fi = Get-Item -LiteralPath (Join-Path $root $r) -Force -ErrorAction SilentlyContinue
                        if (-not $fi -or $fi.PSIsContainer) { [void]$pending.Remove($r); [void]$parked.Remove($r); continue }
                        # a file that failed on its own waits out its delay in
                        # $parked - a new change event does not shorten it
                        if ($parked.ContainsKey($r) -and $parked[$r].Next -gt $now) { [void]$pending.Remove($r); continue }
                        if ($fi.LastWriteTime -gt $settleCut) { $hot++; continue }
                        [void]$pending.Remove($r)
                        $r
                    })
            }
            if ($hot -gt 0) { Write-Log "settle: $hot hot file(s) deferred to the next flush" }
            if ($batch.Count -gt 0) {
                # out of the queue but not uploaded yet: the catch below puts
                # the batch back if anything throws before it is accounted for
                $inFlight = $batch
                $batchFile = Join-Path $stateDir "watcher-batch.txt"
                # rclone expects "/" separators for the gdrive: destination side too
                Set-Content -Path $batchFile -Value @($batch | ForEach-Object { $_ -replace '\\', '/' }) -Encoding UTF8
                # ledger BEFORE the copy: on a long flush the change events of
                # the first files arrive while the batch is still uploading, and
                # a post-flush ledger write would let them through as echoes. A
                # failed batch stays ledgered on purpose - its cloud debris
                # events (partial copy + "Removing failed copy" trash) are our
                # own doing and must not be applied locally.
                Add-LedgerEntries $batch
                # rclone logs this one run into its own file first: it is the
                # only record of WHICH paths failed. --retries 1, because
                # rclone would repeat the whole batch three times for a single
                # failed file - the retrying is done here, per path.
                Remove-Item -LiteralPath $flushLog -Force -Confirm:$false -ErrorAction SilentlyContinue
                & $rcloneExe copy $root $remote --files-from-raw $batchFile --no-traverse @strictFlag `
                    --modify-window 1s @pacer --transfers 4 --retries 1 --log-level INFO --log-file $flushLog 2>$null
                $exit = $LASTEXITCODE
                $flushLines = @(Get-Content -LiteralPath $flushLog -ErrorAction SilentlyContinue)
                if ($flushLines.Count -gt 0) { Add-Content $logFile $flushLines -ErrorAction SilentlyContinue }
                Write-Log "flush: $($batch.Count) file(s), exit=$exit"
                if ($exit -eq 0) {
                    $uploadedTotal += $batch.Count
                    foreach ($r in $batch) { [void]$parked.Remove($r) }
                    $uploadFailures = 0
                    $uploadFailSince = $null
                }
                else {
                    $outcome = Get-FlushOutcome $flushLines
                    $done = @($batch | Where-Object { $outcome.Copied.Contains($_) })
                    $bad = @($batch | Where-Object { $outcome.Failed.ContainsKey($_) })
                    $uploadedTotal += $done.Count
                    foreach ($r in $done) { [void]$parked.Remove($r) }
                    # Named paths alone do not tell a locked file from a dead
                    # line: without DNS every path of the batch is "failed"
                    # (4248 at once on 2026-10-30). One cheap call decides -
                    # if the remote answers, the failures belong to the files.
                    $reachable = $false
                    if ($bad.Count -gt 0) {
                        & $rcloneExe about $remote --json --retries 1 --low-level-retries 1 --contimeout 10s --timeout 20s 2>$null | Out-Null
                        $reachable = $LASTEXITCODE -eq 0
                    }
                    if ($reachable) {
                        foreach ($r in $bad) {
                            $e = Add-UploadStrike $parked $r $outcome.Failed[$r] (Get-Date)
                            Write-Log "WARN upload failed ($($e.Strikes)x, next try in $(Get-UploadRetryMinutes $e.Strikes) min): $($r.Replace('\', '/')) - $($e.Reason)"
                        }
                        # neither copied nor failed: unchanged, or never
                        # reached - trying again costs one compare
                        $again = @($batch | Where-Object { -not $outcome.Copied.Contains($_) -and -not $outcome.Failed.ContainsKey($_) })
                        $uploadFailures = 0
                        $uploadFailSince = $null
                    }
                    else {
                        # the line is dead, or rclone gave up without naming a
                        # path (strict mode: a file vanished mid-flight)
                        $again = @($batch | Where-Object { -not $outcome.Copied.Contains($_) })
                        $uploadFailures++
                        if (-not $uploadFailSince) { $uploadFailSince = Get-Date }
                        $hold = Get-UploadHoldSeconds $uploadFailures
                        $uploadHoldUntil = (Get-Date).AddSeconds($hold)
                        Write-Log "WARN flush failed as a whole ($($uploadFailures)x in a row) - uploads paused for $hold s"
                    }
                    # entries gone from disk drop out via the Get-Item filter
                    foreach ($r in $again) { [void]$pending.Add($r) }
                    if ($again.Count -gt 0) {
                        $lastEvent = Get-Date   # restart the quiet timer to pace retries
                        Write-Log "re-queued $($again.Count) file(s) after failed flush"
                    }
                }
                $inFlight = @()
                Update-UploadAlert
            }

            # 3) deletes: verify, fold, cap, then move to the Drive trash
            if ($deletes.Count -gt 0) {
                $delList = @($deletes)
                $deletes.Clear()
                # Verify and fold BEFORE counting. The cap is there to stop a
                # runaway delete from propagating at once, so it has to count
                # what would actually be deleted: a path that is back on disk
                # is no delete, and a removed folder is ONE delete however
                # many events its content raised (2026-11-09: one removed
                # worktree, 457 events, hit the cap although a single purge
                # would have done).
                $gone = [System.Collections.Generic.List[string]]::new()
                foreach ($d in $delList) {
                    if (Test-Path -LiteralPath (Join-Path $root $d)) { $intentDone.Add($d) }   # recreated meanwhile
                    else { $gone.Add($d) }
                }
                $todo = [System.Collections.Generic.List[string]]::new()
                foreach ($d in @(Select-TopmostPaths @($gone) '\' | Sort-Object)) { $todo.Add($d) }
                if ($todo.Count -gt $maxDeletes) {
                    # Handing the storm to bisync without a record would not
                    # defer the delete, it could invert it: bisync compares
                    # against the previous baseline, and a path created after
                    # that baseline is not in it, so bisync reads "new on
                    # path2" and copies the file back. Journal what we drop -
                    # journal-replay.ps1 carries it out before the next bisync.
                    # The local intent stays open so the cloud watcher does
                    # not fetch the paths back in the meantime.
                    if ($journalDrops) { Add-DroppedDeletes $stateDir "path1" @($todo) }
                    Write-Log "WARN $($todo.Count) deletes exceed cap $maxDeletes - journalled, carried out before the next bisync"
                    $todo.Clear()
                }
                else {
                    $top = [System.Collections.Generic.HashSet[string]]::new([string[]]@($todo), [System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($d in $gone) { if (-not $top.Contains($d)) { $intentDone.Add($d) } }   # ancestor dir covers it
                }
                # One listing and one delete for all plain files: a stat plus a
                # deletefile per path cost ~11 s each, 76 deletes took 18 min
                # on 2026-11-02. What the listing does not return - a folder,
                # or a path already gone - and a failed batch take the
                # per-path route below.
                $rest = @($todo)
                if ($todo.Count -gt 1) {
                    $delFile = Join-Path $stateDir "watcher-deletes.txt"
                    Set-Content -Path $delFile -Value @($todo | ForEach-Object { $_ -replace '\\', '/' }) -Encoding UTF8
                    $lsRaw = & $rcloneExe lsjson $remote -R --files-only --files-from-raw $delFile --no-traverse @pacer 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $live = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        if ($lsRaw) { foreach ($o in (($lsRaw -join "`n") | ConvertFrom-Json)) { [void]$live.Add(($o.Path -replace '/', '\')) } }
                        $files = @($todo | Where-Object { $live.Contains($_) })
                        $rest = @($todo | Where-Object { -not $live.Contains($_) })
                        if ($files.Count -gt 0) {
                            Set-Content -Path $delFile -Value @($files | ForEach-Object { $_ -replace '\\', '/' }) -Encoding UTF8
                            & $rcloneExe delete $remote --files-from-raw $delFile --no-traverse @pacer --log-level ERROR --log-file $logFile 2>$null
                            if ($LASTEXITCODE -eq 0) {
                                foreach ($d in $files) { $deletedTotal++; $intentDone.Add($d); Write-Log "delete -> Drive trash: $($d -replace '\\', '/')" }
                            }
                            else { Write-Log "WARN batch delete failed (exit $LASTEXITCODE) - one by one"; $rest += $files }
                        }
                    }
                }
                foreach ($d in $rest) {
                    $dR = $d -replace '\\', '/'
                    $stat = & $rcloneExe lsjson "$remote$dR" --stat @pacer 2>$null | ConvertFrom-Json
                    if (-not $stat) { $intentDone.Add($d); continue }   # not in the cloud (already gone)
                    if ($stat.IsDir) { & $rcloneExe purge "$remote$dR" @pacer --log-level ERROR --log-file $logFile 2>$null }
                    else { & $rcloneExe deletefile "$remote$dR" @pacer --log-level ERROR --log-file $logFile 2>$null }
                    if ($LASTEXITCODE -eq 0) { $deletedTotal++; $intentDone.Add($d); Write-Log "delete -> Drive trash: $dR" }
                    else { Write-Log "WARN delete failed: $dR" }
                }
            }
            if ($intentDone.Count -gt 0) { Complete-LocalIntent $stateDir @($intentDone) }

            Write-Status
            # a fully drained flush is the freshest safe point for the stamp
            Update-LastSeen
        }
        catch {
            Write-Log "ERROR flush cycle: $($_.Exception.Message)"
            # a batch taken out of the queue and not accounted for is not lost
            foreach ($r in $inFlight) { [void]$pending.Add($r) }
        }
    }
}
finally {
    $fsw.EnableRaisingEvents = $false
    "fswCreated", "fswChanged", "fswRenamed", "fswDeleted", "fswError" | ForEach-Object { Unregister-Event -SourceIdentifier $_ -ErrorAction SilentlyContinue }
    $fsw.Dispose()
    Remove-Item $lockFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "stopped (PID $PID)"
}
