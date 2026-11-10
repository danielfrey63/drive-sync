# Carries out the deletes a watcher only journalled instead of executing.
#
# A delete storm beyond MaxDeletes is not executed by the watchers but written
# to the delete journal (delete-journal.ps1) "for the nightly bisync". bisync
# alone cannot honour that: a file created after its last baseline is absent
# from the listings, so its deletion reads as "new on the other side" and the
# file comes back (2026-09-05: 8 files, 2026-11-06/07: 603 files after an
# aborted run). Rewriting the baseline to tell bisync (the "splice" idea) was
# only ever reported, never armed - the listing format is too easy to get
# wrong. This replays the journal directly, before every bisync and before a
# resync, so bisync finds both sides already in agreement:
#
#   path1 - deleted locally, the cloud still has it: trash the cloud copy,
#           unless the path is back on disk or the cloud copy changed after
#           the local delete (somebody's newer work stays)
#   path2 - deleted in the cloud, the mirror still has it: recycle the local
#           copy, unless the path is live in the cloud again or the local copy
#           changed after the cloud delete
#
# Nothing here is final: cloud deletes go to the Drive trash, local ones to the
# recycle bin. Every entry is re-checked against both file systems, so a stale
# or replayed journal does no harm, and a run that fails half-way keeps the
# claimed batch for the next one.
#
# Dot-source after config.ps1, then:
#   $r = Invoke-JournalledDeletes -Side path1 -LocalRoot $root -Remote "gdrive:" `
#            -StateDir $stateDir -Rules $rules -DryRun:$DryRun -Log { param($m) ... }
#   if (-not $r.Ok) { <do not run the bisync> }

. (Join-Path $PSScriptRoot "delete-journal.ps1")
. (Join-Path $PSScriptRoot "upload-ledger.ps1")   # ConvertTo-UploadLedgerTime
. (Join-Path $PSScriptRoot "recycle-bin.ps1")
. (Join-Path $PSScriptRoot "filter-rules.ps1")

# "gdrive:" takes the path as is, a directory (the end-to-end test syncs two
# of them) needs a separator
function Join-RemotePath([string]$remote, [string]$rel) {
    if (-not $rel) { return $remote }
    if ($remote -match '[:/\\]$') { "$remote$rel" } else { "$remote/$rel" }
}

# rclone lsjson with stdout and stderr kept apart: a NOTICE line mixed into the
# JSON makes the parser throw, and the exit code is what tells "not there" (3,
# 4) from "could not look" (anything else).
function Get-RcloneListing([string]$rcloneExe, [string[]]$lsArgs) {
    $raw = @(& $rcloneExe lsjson @lsArgs @($DriveSyncConfig.Pacer) 2>&1)
    $code = $LASTEXITCODE
    $text = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $err = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Select-Object -Last 1
    $items = @()
    if ($code -eq 0 -and $text.Trim()) { $items = @($text | ConvertFrom-Json) }
    [pscustomobject]@{ Exit = $code; Items = $items; Error = "$err" }
}

# the delete time that applies to a path: its own entry, or the nearest
# journalled folder above it
function Get-CoveringDeleteTime($times, [string]$rel) {
    $p = $rel
    while ($true) {
        if ($times.ContainsKey($p)) { return $times[$p] }
        $i = $p.LastIndexOf('/')
        if ($i -le 0) { return $null }
        $p = $p.Substring(0, $i)
    }
}

function Invoke-JournalledDeletes {
    param(
        [Parameter(Mandatory)][ValidateSet("path1", "path2")][string]$Side,
        # both unscoped; -Scope only narrows which entries are looked at
        [Parameter(Mandatory)][string]$LocalRoot,
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$StateDir,
        [string]$RcloneExe = "rclone",
        # from Get-ExcludeRules: paths the sync excludes today are left alone
        # (rclone refuses --files-from together with filters)
        $Rules = $null,
        [string]$Scope = "",
        [switch]$DryRun,
        # every entry is re-checked against both sides, so the read cut-off can
        # be generous: a blocked chain easily outlives the journal's own 7 days
        [int]$MaxAgeDays = 30,
        [scriptblock]$Log = { param($m) Write-Host $m },
        # 0 = success; replaced by the tests, which must not fill the real bin
        [scriptblock]$Recycle = { param($p) Move-ToRecycleBin $p }
    )

    $res = [ordered]@{ Side = $Side; Ok = $true; Journalled = 0; Pending = 0; Done = 0; Kept = 0; Failed = 0; Error = "" }
    $say = { param($m) & $Log "delete journal ${Side}: $m" }
    $fail = { param($m) $res.Ok = $false; $res.Error = $m; & $say "FAILED - $m" }

    # a scoped run only peeks: claiming would take the entries of every other
    # subtree with it, and the clear at the end would drop them
    $consume = -not $DryRun -and -not $Scope
    $journal = @(Read-DroppedDeletes $StateDir $Side -Claim:$consume -MaxAgeDays $MaxAgeDays)
    $res.Journalled = $journal.Count
    if ($journal.Count -eq 0) { & $say "nothing deferred"; return [pscustomobject]$res }

    # --- which entries still ask for anything -------------------------------
    $prefix = if ($Scope) { $Scope.Trim('/') + '/' } else { "" }
    $times = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $settled = 0; $excluded = 0; $outOfScope = 0
    foreach ($e in $journal) {
        if ($prefix -and -not $e.Rel.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $outOfScope++; continue }
        $win = $e.Rel -replace '/', '\'
        if ($Rules -and (Test-Excluded $Rules $win)) { $excluded++; continue }
        $here = Test-Path -LiteralPath (Join-Path $LocalRoot $win)
        # path1: back on disk = recreated since, the entry is stale.
        # path2: gone from the mirror too = settled, or the echo of our own delete
        if (($Side -eq "path1") -eq $here) { $settled++; continue }
        $times[$e.Rel] = $e.Time
    }
    $top = @(Select-TopmostPaths @($times.Keys))
    $res.Pending = $top.Count
    $settledText = if ($Side -eq "path1") { "back on disk" } else { "gone locally as well" }
    & $say ("{0} journalled - {1} to check ({2} after folding into deleted folders), {3} {4}, {5} excluded by the filters{6}" -f `
            $journal.Count, $times.Count, $top.Count, $settled, $settledText, $excluded,
        $(if ($prefix) { ", $outOfScope outside the scope" } else { "" }))

    if ($top.Count -gt 0) {
        # A journal entry is a file or the root of a deleted tree, and the
        # side that lost it can no longer tell which. One listing per parent
        # folder answers it for all siblings at once.
        $cloudItems = @{}   # entry -> lsjson item; absent = not in the cloud
        $parentGone = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $byParent = $top | Group-Object { $i = $_.LastIndexOf('/'); if ($i -lt 0) { "" } else { $_.Substring(0, $i) } }
        foreach ($grp in $byParent) {
            $parent = $grp.Name
            $ls = Get-RcloneListing $RcloneExe @((Join-RemotePath $Remote $parent))
            if ($ls.Exit -eq 3) { foreach ($entry in $grp.Group) { [void]$parentGone.Add($entry) }; continue }
            if ($ls.Exit -ne 0) { & $fail "listing '$parent' failed (exit $($ls.Exit)): $($ls.Error)"; return [pscustomobject]$res }
            $byName = @{}
            foreach ($o in $ls.Items) { if ($o) { $byName[$o.Name] = $o } }
            foreach ($entry in $grp.Group) {
                $leaf = if ($parent) { $entry.Substring($parent.Length + 1) } else { $entry }
                if ($byName.ContainsKey($leaf)) { $cloudItems[$entry] = $byName[$leaf] }
            }
        }

        if ($Side -eq "path1") {
            # --- trash the cloud copies ----------------------------------
            $cloud = [System.Collections.Generic.List[object]]::new()   # @{ Rel; M }
            foreach ($entry in $top) {
                if (-not $cloudItems.ContainsKey($entry)) { continue }   # gone in the cloud already
                $it = $cloudItems[$entry]
                if (-not $it.IsDir) { $cloud.Add(@{ Rel = $entry; M = (ConvertTo-UploadLedgerTime $it.ModTime) }); continue }
                $tree = Get-RcloneListing $RcloneExe @((Join-RemotePath $Remote $entry), "-R", "--files-only")
                if ($tree.Exit -ne 0) { & $fail "listing folder '$entry' failed (exit $($tree.Exit)): $($tree.Error)"; return [pscustomobject]$res }
                foreach ($o in $tree.Items) {
                    if ($o) { $cloud.Add(@{ Rel = "$entry/$($o.Path)"; M = (ConvertTo-UploadLedgerTime $o.ModTime) }) }
                }
            }
            $toDelete = [System.Collections.Generic.List[string]]::new()
            foreach ($c in $cloud) {
                $win = $c.Rel -replace '/', '\'
                if ($Rules -and (Test-Excluded $Rules $win)) { continue }
                if (Test-Path -LiteralPath (Join-Path $LocalRoot $win)) { continue }
                $t = Get-CoveringDeleteTime $times $c.Rel
                # same file only: not touched in the cloud after our delete (1s
                # slack for two clocks, like --modify-window)
                if ($null -ne $c.M -and $null -ne $t -and $c.M -le $t + 1) { $toDelete.Add($c.Rel) }
                else { $res.Kept++; & $say "kept, changed in the cloud after the local delete: $($c.Rel)" }
            }
            & $say "$($toDelete.Count) file(s) still in the cloud and unchanged, $($res.Kept) changed since"
            if ($toDelete.Count -gt 0) {
                if ($DryRun) { foreach ($p in $toDelete) { & $say "DRYRUN would trash in the cloud: $p" } }
                else {
                    $tmp = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-journal-$Side-$PID.txt"
                    Set-Content -LiteralPath $tmp -Value $toDelete -Encoding utf8NoBOM
                    $delRaw = @(& $RcloneExe delete $Remote --files-from-raw $tmp --no-traverse @($DriveSyncConfig.Pacer) 2>&1)
                    $delExit = $LASTEXITCODE
                    [IO.File]::Delete($tmp)
                    if ($delExit -ne 0) { & $fail "cloud deletes failed (exit $delExit): $($delRaw | Select-Object -Last 1)"; return [pscustomobject]$res }
                    foreach ($p in $toDelete) { & $say "trashed in the cloud: $p" }
                    $res.Done = $toDelete.Count
                }
            }
        }
        else {
            # --- recycle the local copies ----------------------------------
            # Everything is decided before the first file moves. A path the
            # parent listing does not show is confirmed dead by a lookup of
            # its own: on 2026-11-07 rclone's UTF-8 output was read as ibm850,
            # names with umlauts matched nothing, and live files were recycled.
            # The lookup passes the name as an argument and answers by exit
            # code, so it does not depend on how the output is decoded.
            $dead = [System.Collections.Generic.List[string]]::new()
            $live = 0
            foreach ($entry in $top) {
                if ($cloudItems.ContainsKey($entry)) { $live++; continue }
                if (-not $parentGone.Contains($entry)) {
                    $st = Get-RcloneListing $RcloneExe @((Join-RemotePath $Remote $entry), "--stat")
                    if ($st.Exit -eq 0) { & $fail "cloud listing unreliable: '$entry' is missing from its folder listing but live on a single lookup"; return [pscustomobject]$res }
                    if ($st.Exit -notin 3, 4) { & $fail "lookup of '$entry' failed (exit $($st.Exit)): $($st.Error)"; return [pscustomobject]$res }
                }
                $dead.Add($entry)
            }
            $stale = {
                param($fi, [string]$rel)
                $t = Get-CoveringDeleteTime $times $rel
                if ($null -eq $t) { return $false }
                $bound = [DateTimeOffset]::FromUnixTimeSeconds($t + 1).UtcDateTime
                # written AND created before the cloud delete: a copy dropped
                # into the folder afterwards keeps an old modtime but not an
                # old creation time
                $fi.LastWriteTimeUtc -le $bound -and $fi.CreationTimeUtc -le $bound
            }
            $whole = [System.Collections.Generic.List[string]]::new()    # folders to recycle as one
            $single = [System.Collections.Generic.List[string]]::new()   # files
            foreach ($entry in $dead) {
                $abs = Join-Path $LocalRoot ($entry -replace '/', '\')
                $item = Get-Item -LiteralPath $abs -Force -ErrorAction SilentlyContinue
                if (-not $item) { continue }
                if (-not $item.PSIsContainer) {
                    if (& $stale $item $entry) { $single.Add($entry) }
                    else { $res.Kept++; & $say "kept, changed locally after the cloud delete: $entry" }
                    continue
                }
                $mine = [System.Collections.Generic.List[string]]::new()
                $blocked = 0
                # a link inside the tree: never hand the shell a folder whose
                # removal might follow it
                $links = @(Get-ChildItem -LiteralPath $abs -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue).Count
                foreach ($fi in Get-ChildItem -LiteralPath $abs -Recurse -File -Force -ErrorAction SilentlyContinue) {
                    $rel = "$entry/" + ($fi.FullName.Substring($abs.Length).TrimStart('\') -replace '\\', '/')
                    if ($Rules -and (Test-Excluded $Rules ($rel -replace '/', '\'))) { $blocked++; continue }
                    if (& $stale $fi $rel) { $mine.Add($rel) }
                    else { $blocked++; $res.Kept++; & $say "kept, changed locally after the cloud delete: $rel" }
                }
                if ($blocked -eq 0 -and $links -eq 0) { $whole.Add($entry) }
                else { $single.AddRange($mine) }
            }
            & $say "$live live in the cloud again (kept), $($whole.Count) folder(s) and $($single.Count) file(s) to recycle, $($res.Kept) changed since"
            foreach ($p in @($whole) + @($single)) {
                if ($DryRun) { & $say "DRYRUN would recycle: $p"; continue }
                $rc = & $Recycle (Join-Path $LocalRoot ($p -replace '/', '\'))
                if ($rc -eq 0) { $res.Done++; & $say "recycled: $p" }
                # not fatal: at worst the file is uploaded again by the bisync
                else { $res.Failed++; & $say "WARN recycle failed (rc=$rc): $p" }
            }
        }
    }

    # the claimed batch is settled (never claimed under -DryRun or -Scope)
    if ($consume) { Clear-DroppedDeletes $StateDir $Side }
    return [pscustomobject]$res
}
