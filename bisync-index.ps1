# Shared read-side helpers for rclone's bisync baseline listings.
#
# A listing is one header line plus one line per entry:
#   # bisync listing v1 from 2026-09-05T03:31:55.775751300+0000
#   -   106997 - - 2022-04-26T07:04:29.124000000+0000 "Agile Lean Teal/.../x.pdf"
#
# Measured on the 1'311'691-entry corpus (2026-09-05):
#  - both sides carry the SAME paths and sizes; only the modtime differs, path2
#    being path1 truncated to milliseconds (115'139 of 115'139 cases, no rounding)
#  - 996 entries (0.076 %) contain a \uXXXX escape. rclone escapes invisible and
#    ambiguous characters - U+00A0, U+2006, U+00AD - and writes accented letters
#    raw. It SORTS by the unescaped path but WRITES the escaped one, which is why
#    a hand-built line can land in the wrong place or be read as a different path.
#    Anything that would be escaped is therefore refused, not guessed at.

. (Join-Path $PSScriptRoot "delete-journal.ps1")

# rclone's default bisync workdir on Windows; override via config if it moves
function Get-BisyncWorkDir {
    if ($DriveSyncConfig.BisyncWorkDir) { return $DriveSyncConfig.BisyncWorkDir }
    Join-Path $env:LOCALAPPDATA "rclone\bisync"
}

function Get-BisyncListings([string]$localPath, [string]$remote) {
    $dir = Get-BisyncWorkDir
    if (-not (Test-Path $dir)) { return $null }
    # rclone mangles both endpoints into the file name; derive it, and fall back
    # to a glob when the derivation and the actual naming disagree
    $mangle = { param($s) ($s -replace '[^A-Za-z0-9]', '_') }
    $stem = "$(& $mangle $localPath)..$(& $mangle $remote)"
    $p1 = Join-Path $dir "$stem.path1.lst"
    $p2 = Join-Path $dir "$stem.path2.lst"
    if (-not (Test-Path $p1) -or -not (Test-Path $p2)) {
        $cand = @(Get-ChildItem -Path $dir -Filter "*.path1.lst" -File -ErrorAction SilentlyContinue)
        if ($cand.Count -ne 1) { return $null }
        $p1 = $cand[0].FullName
        $p2 = $p1 -replace '\.path1\.lst$', '.path2.lst'
        if (-not (Test-Path $p2)) { return $null }
    }
    [pscustomobject]@{ Path1 = $p1; Path2 = $p2 }
}

# A path is safe to write into a listing only if rclone would write it verbatim.
function Test-SpliceSafeName([string]$rel) {
    if ([string]::IsNullOrEmpty($rel)) { return $false }
    if ($rel -match '[\p{C}\p{Zl}\p{Zp}"\\]') { return $false }   # control, format, quote, escape
    foreach ($ch in $rel.ToCharArray()) {
        # U+00A0 and U+2006 are whitespace but not a plain space - rclone escapes them
        if ([char]::IsWhiteSpace($ch) -and $ch -ne ' ') { return $false }
    }
    return $true
}

# Which of $candidates does a listing already know about? Streams the file once;
# Get-Content would take minutes on a 212 MB listing.
# The leading comma on both returns is load-bearing: PowerShell unrolls a
# collection on return, which turns no matches into $null (and the caller's
# .Contains() into a null-reference error) and a single match into a String,
# whose .Contains() compares substrings instead of paths.
function Get-ListedPaths([string]$listing, [System.Collections.Generic.HashSet[string]]$wanted) {
    $hit = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($wanted.Count -eq 0) { return , $hit }
    foreach ($line in [System.IO.File]::ReadLines($listing)) {
        if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }
        $a = $line.IndexOf('"')
        if ($a -lt 0) { continue }
        $b = $line.LastIndexOf('"')
        if ($b -le $a) { continue }
        $p = $line.Substring($a + 1, $b - $a - 1)
        if ($wanted.Contains($p)) { [void]$hit.Add($p) }
    }
    return , $hit
}

# Classify journalled paths against the baselines and the two file systems.
# $side is the side the delete happened on: "path1" = locally deleted (the cloud
# still has it), "path2" = deleted in the cloud (the local mirror still has it).
function Measure-SpliceCandidates([string]$localRoot, $listings, [string]$side, [string[]]$candidates) {
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($c in $candidates) { [void]$wanted.Add($c) }

    $in1 = Get-ListedPaths $listings.Path1 $wanted
    $in2 = Get-ListedPaths $listings.Path2 $wanted

    $ready = [System.Collections.Generic.List[string]]::new()
    $inBaseline = 0
    $recreated = 0
    $unsafeName = [System.Collections.Generic.List[string]]::new()

    foreach ($c in $candidates) {
        $abs = Join-Path $localRoot ($c -replace '/', '\')
        $localHere = Test-Path -LiteralPath $abs
        # the side that deleted must really be missing it now; if it is back,
        # the journal entry is stale and splicing it would order a live delete
        if ($side -eq "path1" -and $localHere) { $recreated++; continue }
        if ($side -eq "path2" -and -not $localHere) { $recreated++; continue }
        # present in a baseline means bisync already sees the deletion correctly
        if ($in1.Contains($c) -or $in2.Contains($c)) { $inBaseline++; continue }
        if (-not (Test-SpliceSafeName $c)) { $unsafeName.Add($c); continue }
        $ready.Add($c)
    }

    [pscustomobject]@{
        Side       = $side
        Total      = $candidates.Count
        Ready      = $ready
        InBaseline = $inBaseline
        Recreated  = $recreated
        UnsafeName = $unsafeName
    }
}

# Size and modtime for a spliced line, taken from the side that still has the
# file. The upload ledger cannot serve: it carries only timestamp and path, and
# only for an hour.
#
# Why not simply the current metadata of the surviving copy: if another device
# changed it after our upload, a line built from today's values would tell bisync
# "unchanged on the other side" and the change would be deleted without a trace.
# The line has to describe the file AS UPLOADED, so a foreign change surfaces as
# a conflict. The journal time is the bound we have for that - a surviving copy
# modified after we deleted ours is not ours any more.
#
# $side is the side the delete happened on, so the surviving copy is the other:
#   path1 - deleted locally, the cloud still has it -> ask the remote
#   path2 - deleted in the cloud, the mirror still has it -> ask the disk
# States: ok (splice it) | gone (nothing to do) | conflict (leave it to bisync)
function Get-SpliceMetadata([string]$rcloneExe, [string]$localRoot, [string]$remote,
    [string]$side, [string]$rel, [long]$journalTime) {
    $none = { param($s) [pscustomobject]@{ State = $s; Size = 0; ModTime = [datetime]::MinValue } }
    $size = $null
    $mtime = $null
    if ($side -eq "path1") {
        # "gdrive:" needs no separator, a local path (the end-to-end test syncs
        # two directories) does - without it the two names simply run together
        $sep = if ($remote -match '[:/\\]$') { "" } else { "/" }
        $stat = & $rcloneExe lsjson "$remote$sep$rel" --stat @($DriveSyncConfig.Pacer) 2>$null | ConvertFrom-Json
        if (-not $stat -or $stat.IsDir) { return & $none "gone" }
        $size = [long]$stat.Size
        $mtime = ([datetime]$stat.ModTime).ToUniversalTime()
    }
    else {
        $fi = Get-Item -LiteralPath (Join-Path $localRoot ($rel -replace '/', '\')) -Force -ErrorAction SilentlyContinue
        if (-not $fi -or $fi.PSIsContainer) { return & $none "gone" }
        $size = $fi.Length
        $mtime = $fi.LastWriteTimeUtc
    }
    # a second of slack: the delete is journalled after the file is gone, and
    # two clocks (local, Drive) are never exactly aligned
    $cut = [DateTimeOffset]::FromUnixTimeSeconds($journalTime + 1).UtcDateTime
    if ($mtime -gt $cut) { return & $none "conflict" }
    [pscustomobject]@{ State = "ok"; Size = $size; ModTime = $mtime }
}

# Report what a splice would have covered, and consume the journals. Reads only;
# the baselines are not touched. Returns the measurements, one per side that had
# entries, so a caller can assert on them.
# -Peek reports without consuming: a dry run must not eat the entries the next
# real run needs. It is the caller's -DryRun, passed through.
function Write-SpliceReport([string]$localRoot, [string]$remote, [string]$stateDir,
    [string]$rcloneExe = "rclone", [switch]$Peek) {
    $out = @()
    # The nightly task runs sync-drive.ps1 with -WindowStyle Hidden and no
    # redirection, so Write-Host alone leaves no trace of the very nights this
    # report exists to observe. Keep a file next to the state, and echo for the
    # manual run and the test.
    $reportLog = Join-Path $stateDir "splice-report.log"
    $say = {
        param($msg)
        Write-Host $msg
        try { Add-Content $reportLog "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ErrorAction SilentlyContinue } catch { }
    }
    $listings = Get-BisyncListings $localRoot $remote
    if (-not $listings) {
        & $say "splice report: no baseline listings found - skipped"
        return $out
    }
    foreach ($side in @("path1", "path2")) {
        # peeking reads the journal AND a claim a dead consumer left behind,
        # and moves neither
        $entries = @(Read-DroppedDeletes $stateDir $side -Claim:(-not $Peek))
        # consumed right away: the batch is in memory and the report changes
        # nothing, so a retry could not salvage anything. The splice will move
        # this to after a successful write, where a crash IS worth retrying.
        if (-not $Peek) { Clear-DroppedDeletes $stateDir $side }
        if ($entries.Count -eq 0) { continue }
        $m = Measure-SpliceCandidates $localRoot $listings $side @($entries.Rel)

        # Only now, and only for the candidates that survived the classification:
        # every lookup is a metadata call, and the cap is the ceiling on both the
        # cost and the size of a splice gone wrong.
        $maxSplice = if ($DriveSyncConfig.MaxSpliceEntries) { [int]$DriveSyncConfig.MaxSpliceEntries } else { 200 }
        $times = @{}
        foreach ($e in $entries) { $times[$e.Rel] = $e.Time }
        $ready = @($m.Ready)
        $capped = $ready.Count -gt $maxSplice
        if ($capped) { $ready = @($ready | Select-Object -First $maxSplice) }
        $meta = @{}
        $gone = 0
        $conflict = 0
        foreach ($rel in $ready) {
            $md = Get-SpliceMetadata $rcloneExe $localRoot $remote $side $rel $times[$rel]
            switch ($md.State) {
                "ok" { $meta[$rel] = $md }
                "gone" { $gone++ }
                default { $conflict++ }
            }
        }
        $m | Add-Member -NotePropertyName Splice -NotePropertyValue $meta
        $m | Add-Member -NotePropertyName Gone -NotePropertyValue $gone
        $m | Add-Member -NotePropertyName Conflict -NotePropertyValue $conflict
        $m | Add-Member -NotePropertyName Capped -NotePropertyValue $capped
        # the concatenation needs its own parentheses: -f binds tighter than +,
        # so without them only the second literal would be formatted
        & $say ((
                "splice report {0}{6}: {1} journalled - {2} would be spliced, " +
                "{3} already in the baseline, {4} back on disk, {5} unsafe name"
            ) -f $side, $m.Total, $m.Ready.Count, $m.InBaseline, $m.Recreated, $m.UnsafeName.Count,
            $(if ($Peek) { " (dry run, journal kept)" } else { "" }))
        & $say ("    metadata: {0} usable, {1} gone from both sides, {2} changed since the delete{3}" `
                -f $meta.Count, $gone, $conflict, $(if ($capped) { " (capped at $maxSplice)" } else { "" }))
        foreach ($p in @($meta.Keys | Select-Object -First 5)) { & $say "    would splice: $p" }
        foreach ($p in @($m.UnsafeName | Select-Object -First 3)) { & $say "    unsafe name: $p" }
        $out += $m
    }
    return $out
}
