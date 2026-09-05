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
#    capped at $maxDeletes per flush and go to the Drive TRASH (30 days) -
#    never hard-deleted. A storm above the cap is NOT simply dropped: its
#    paths are journalled (delete-journal.ps1), because bisync alone cannot
#    always read them as deletions - see there.
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
$statusFile = Join-Path $stateDir "watcher-status.json"
$lockFile = Join-Path $stateDir "watcher.lock"
$bisyncLock = Join-Path $stateDir "sync.lock"
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
        Add-Content $eventLogFile @($lines | ForEach-Object { "$ts $_" }) -ErrorAction SilentlyContinue
    }
    catch {}
}

# --- single instance --------------------------------------------------------
if (Test-Path $lockFile) {
    $other = Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($other -and (Get-Process -Id $other -ErrorAction SilentlyContinue)) {
        Write-Log "another watcher (PID $other) is active - exiting"
        exit 0
    }
}
Set-Content $lockFile $PID

# --- journal for deletes the cap drops --------------------------------------
. (Join-Path $PSScriptRoot "delete-journal.ps1")

# --- derive exclude sets from filters.txt -----------------------------------
. (Join-Path $PSScriptRoot "filter-rules.ps1")
$rules = Get-ExcludeRules $filters
Write-Log "started (PID $PID): $($rules.Dirs.Count) dir rules, $($rules.Exts.Count) ext rules, $($rules.Names.Count) name rules"

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
    } | ConvertTo-Json | Set-Content $statusFile
}

# Every path we upload/rename is recorded here so the cloud watcher can tell
# our own change events apart from genuine cloud-side changes (echo control).
$ledgerFile = Join-Path $stateDir "upload-ledger.txt"
function Add-LedgerEntries([string[]]$rels) {
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        # retention must cover the Drive changes-API latency (a 486 MB upload
        # surfaced its change event 23 min late on 2026-08-28); keep in sync
        # with the reader window in watch-cloud.ps1
        $cut = $now - 3600
        $keep = @()
        if (Test-Path $ledgerFile) {
            $keep = @(Get-Content $ledgerFile -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^(\d+)\t' -and [long]$Matches[1] -gt $cut })
        }
        $keep += @($rels | ForEach-Object { "$now`t$_" })
        Set-Content $ledgerFile $keep
    }
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
    $bisyncPid = Get-Content $bisyncLock -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bisyncPid -and (Get-Process -Id $bisyncPid -ErrorAction SilentlyContinue)) {
        # stamp untouched: the bisync reconciles the gap, the heartbeat takes over
        Write-Log "catch-up skipped: bisync (PID $bisyncPid) is running and reconciles the gap"
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
function Update-LastSeen {
    if (($pending.Count + $renames.Count + $deletes.Count) -eq 0) {
        try { Set-Content $lastSeenFile ((Get-Date).ToString("o")) } catch {}
    }
}

# --- main loop: debounce and flush ------------------------------------------
$lastHeartbeat = Get-Date
try {
    while ($true) {
        $null = Wait-Event -Timeout 3
        if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 10) {
            Write-Log "heartbeat: $($pending.Count) up / $($renames.Count) ren / $($deletes.Count) del pending"
            $lastHeartbeat = Get-Date
            Update-LastSeen
        }
        $drained = 0
        $evtTrace = [System.Collections.Generic.List[string]]::new()
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
                if (-not (Test-Excluded $rules $rel)) { [void]$deletes.Add($rel) }
            }
            elseif ($src -eq "fswRenamed") {
                $oldRel = $ea.OldFullPath.Substring($root.Length + 1)
                $oldOk = -not (Test-Excluded $rules $oldRel)
                $newOk = -not (Test-Excluded $rules $rel)
                if ($oldOk -and $oldRel -like "*.partial") { $oldOk = $false }   # rclone download temp -> plain create
                if ($oldOk -and $newOk) { $renames.Add([pscustomobject]@{ Old = $oldRel; New = $rel }) }
                elseif ($oldOk) { [void]$deletes.Add($oldRel) }   # renamed INTO an excluded name
                elseif ($newOk) { Add-PendingPath $path $rel }    # renamed OUT of an excluded/temp name
            }
            elseif ($src -eq "fswChanged") {
                # files only: a timestamp touch on a directory (e.g. by a sync
                # download into it) must not enqueue its entire subtree
                if (-not (Test-Excluded $rules $rel) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                    [void]$pending.Add($rel)
                }
            }
            else {
                if (-not (Test-Excluded $rules $rel)) { Add-PendingPath $path $rel }
            }
            if ($null -eq $oldestPending) { $oldestPending = Get-Date }
        }
        if ($evtTrace.Count -gt 0) { Write-EventLog $evtTrace }
        if ($drained -gt 0) { Write-Log "events: $drained drained, $($pending.Count) up / $($renames.Count) ren / $($deletes.Count) del pending" }

        if (($pending.Count + $renames.Count + $deletes.Count) -eq 0) { $oldestPending = $null; continue }
        $quiet = $lastEvent -and ((Get-Date) - $lastEvent).TotalSeconds -ge 15
        $overdue = $oldestPending -and ((Get-Date) - $oldestPending).TotalSeconds -ge 60
        if (-not ($quiet -or $overdue)) { continue }

        # defer while the nightly bisync holds its lock
        if (Test-Path $bisyncLock) {
            $lockPid = Get-Content $bisyncLock -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) { continue }
        }
        $oldestPending = $null

        # the flush cycle must never kill the watcher - log and carry on
        try {
            # 1) renames: server-side moves, in event order (rename chains)
            foreach ($rn in @($renames)) {
                $newAbs = Join-Path $root $rn.New
                if (-not (Test-Path -LiteralPath $newAbs)) { continue }   # gone again; delete/bisync covers it
                $oldR = $rn.Old -replace '\\', '/'
                $newR = $rn.New -replace '\\', '/'
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
                            continue
                        }
                        # step 2 failed: move back so no .casemv-tmp orphan is
                        # left for bisync to download as a new file
                        & $rcloneExe moveto "$remote$tmpR" "$remote$oldR" @pacer --log-level ERROR --log-file $logFile 2>$null
                    }
                    Write-Log "WARN case-only 2-step moveto failed for $newR - falling back"
                }
                & $rcloneExe moveto "$remote$oldR" "$remote$newR" @pacer --log-level ERROR --log-file $logFile 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $renamedTotal++
                    Write-Log "rename: $oldR -> $newR"
                    Add-LedgerEntries @($rn.New)
                }
                else {
                    # old path unknown in the cloud (e.g. editor tmp-file save): upload instead
                    Write-Log "rename fallback to upload: $newR"
                    Add-PendingPath $newAbs $rn.New
                }
            }
            $renames.Clear()

            # 2) uploads - files still being written stay queued: uploading a
            #    file mid-write ends in "corrupted on transfer" and rclone's
            #    cleanup trashes the cloud copy, which started the 2026-08-29
            #    delete chain. 10s of write silence is required before upload.
            $settleCut = (Get-Date).AddSeconds(-10)
            $hot = 0
            $batch = @(foreach ($r in @($pending)) {
                    $fi = Get-Item -LiteralPath (Join-Path $root $r) -Force -ErrorAction SilentlyContinue
                    if (-not $fi -or $fi.PSIsContainer) { [void]$pending.Remove($r); continue }
                    if ($fi.LastWriteTime -gt $settleCut) { $hot++; continue }
                    [void]$pending.Remove($r)
                    $r
                })
            if ($hot -gt 0) { Write-Log "settle: $hot hot file(s) deferred to the next flush" }
            if ($batch.Count -gt 0) {
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
                & $rcloneExe copy $root $remote --files-from-raw $batchFile --no-traverse @strictFlag `
                    --modify-window 1s @pacer --transfers 4 --log-level INFO --log-file $logFile 2>$null
                $exit = $LASTEXITCODE
                Write-Log "flush: $($batch.Count) file(s), exit=$exit"
                if ($exit -eq 0) {
                    $uploadedTotal += $batch.Count
                }
                else {
                    # strict mode fails the whole batch if one file vanished mid-flight:
                    # re-queue; entries gone from disk drop out via the Test-Path filter
                    foreach ($r in $batch) { [void]$pending.Add($r) }
                    $lastEvent = Get-Date   # restart the quiet timer to pace retries
                    Write-Log "re-queued $($batch.Count) file(s) after failed flush"
                }
            }

            # 3) deletes: verify, cap, then move to the Drive trash
            if ($deletes.Count -gt $maxDeletes) {
                # The cap is right - a runaway delete must not propagate at
                # once. But handing the storm to bisync without a record does
                # not defer the delete, it can invert it: bisync compares
                # against the previous baseline, and a path created after that
                # baseline is not in it, so bisync reads "new on path2" and
                # copies the file back. Journal what we drop.
                if ($journalDrops) { Add-DroppedDeletes $stateDir "path1" @($deletes) }
                Write-Log "WARN $($deletes.Count) deletes exceed cap $maxDeletes - journalled for the nightly bisync"
                $deletes.Clear()
            }
            elseif ($deletes.Count -gt 0) {
                $delList = @($deletes | Sort-Object)
                $deletes.Clear()
                foreach ($d in $delList) {
                    if (Test-Path -LiteralPath (Join-Path $root $d)) { continue }   # recreated meanwhile
                    if (@($delList | Where-Object { $_ -ne $d -and $d.StartsWith("$_\") }).Count -gt 0) { continue }   # ancestor dir covers it
                    $dR = $d -replace '\\', '/'
                    $stat = & $rcloneExe lsjson "$remote$dR" --stat @pacer 2>$null | ConvertFrom-Json
                    if (-not $stat) { continue }   # not in the cloud (already gone)
                    if ($stat.IsDir) { & $rcloneExe purge "$remote$dR" @pacer --log-level ERROR --log-file $logFile 2>$null }
                    else { & $rcloneExe deletefile "$remote$dR" @pacer --log-level ERROR --log-file $logFile 2>$null }
                    if ($LASTEXITCODE -eq 0) { $deletedTotal++; Write-Log "delete -> Drive trash: $dR" }
                    else { Write-Log "WARN delete failed: $dR" }
                }
            }

            Write-Status
            # a fully drained flush is the freshest safe point for the stamp
            Update-LastSeen
        }
        catch {
            Write-Log "ERROR flush cycle: $($_.Exception.Message)"
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
