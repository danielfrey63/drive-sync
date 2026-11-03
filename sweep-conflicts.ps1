# Sweeps bisync conflict-loser copies (<name>.conflictN) out of the sync
# corpus. A loser copy inside a git worktree is a trap, not a backup: on
# 2026-09-02 the nightly run left 68 of them in the pmo repo, auto-staging
# swept 54 into the index and blocked every merge.
#
# Parses a bisync log for "Renaming Path1/Path2 copy" lines, moves the local
# copies to %LOCALAPPDATA%\drive-sync\conflicts\<runstamp>\<relative-path>
# and appends one line per file to conflicts.log, marking whether the content
# already exists in the surrounding git history (then the copy is redundant).
# The cloud-side copies are cleaned up by the normal deletion propagation
# (upload watcher, or the next nightly run beyond the 50-delete cap).
#
# Called by sync-drive.ps1 after every real run; can be run standalone
# against any bisync log. -WhatIf reports without moving. Idempotent:
# already-moved files are skipped silently.
#
# -Scan instead looks at every .conflictN file in the current baseline
# listing, whoever made it. The log-based sweep only knows this machine's
# losers; on 2026-10-31 the closed P16 pushed 70 of its own, the cloud
# watcher downloaded them and they sat in the corpus for two days. A scan
# moves only copies that are provably redundant - byte-identical to the
# original, a prefix of it (append-only logs), or a blob in its git history -
# and raises an alert for the rest, which need a human.

param(
    [Parameter(Mandatory, ParameterSetName = "Log")][string]$LogFile,
    [Parameter(Mandatory, ParameterSetName = "Scan")][switch]$Scan,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "conflict-names.ps1")
$root = $DriveSyncConfig.LocalRoot
$stateDir = $DriveSyncConfig.StateDir
$sweepLog = Join-Path $stateDir "conflicts.log"

# is the loser's content already a blob of the original path in git history?
function Test-InGitHistory([string]$absConflict, [string]$rel) {
    try {
        # find the enclosing worktree (a .git dir or file), never above the root
        $dir = Split-Path $absConflict -Parent
        $wt = $null
        while ($dir -and $dir.Length -ge $root.Length) {
            if (Test-Path -LiteralPath (Join-Path $dir ".git")) { $wt = $dir; break }
            $dir = Split-Path $dir -Parent
        }
        if (-not $wt) { return "no-git" }
        $origAbs = $absConflict -replace '\.conflict\d+$', ''
        $origRel = ($origAbs.Substring($wt.Length).TrimStart('\')) -replace '\\', '/'
        $blob = (& git -C $wt hash-object -- $absConflict 2>$null | Select-Object -First 1)
        if (-not $blob) { return "unknown" }
        foreach ($c in @(& git -C $wt log -n 50 --format=%H -- $origRel 2>$null)) {
            $h = (& git -C $wt rev-parse "${c}:${origRel}" 2>$null | Select-Object -First 1)
            if ($h -eq $blob) { return "in-git" }
        }
        return "not-in-git"
    }
    catch { return "unknown" }
}

# Is the copy redundant next to its original? Returns the marker, or $null if
# it holds content found nowhere else.
function Get-RedundancyMarker([string]$abs, [string]$rel) {
    $origAbs = $abs -replace '\.conflict\d+$', ''
    if (-not (Test-Path -LiteralPath $origAbs -PathType Leaf)) { return $null }
    $c = Get-Item -LiteralPath $abs
    $o = Get-Item -LiteralPath $origAbs
    if ($c.Length -le $o.Length) {
        # equal bytes, or the original continues the copy (an append-only log
        # that grew on the other machine after the split)
        $cb = [IO.File]::ReadAllBytes($abs)
        $ob = [byte[]]::new($cb.Length)
        $fs = [IO.File]::OpenRead($origAbs)
        try { [void]$fs.Read($ob, 0, $cb.Length) } finally { $fs.Close() }
        if ([Linq.Enumerable]::SequenceEqual($cb, $ob)) {
            if ($c.Length -eq $o.Length) { return "SAME-AS-ORIGINAL" } else { return "PREFIX-OF-ORIG" }
        }
    }
    if ((Test-InGitHistory $abs $rel) -eq "in-git") { return "in-git" }
    return $null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$destRoot = Join-Path $stateDir "conflicts\$stamp"
function Move-ToConflictArchive([string]$rel, [string]$marker) {
    $abs = Join-Path $root $rel
    if ($WhatIf) { Write-Host "sweep would move [$marker]: $rel"; return }
    $dest = Join-Path $destRoot $rel
    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
    Move-Item -LiteralPath $abs -Destination $dest
    Add-Content $sweepLog "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$marker] $rel -> $dest"
    Write-Host "sweep [$marker]: $rel"
}

if ($Scan) {
    # the listing, not the disk: a walk over 1.2M files takes minutes, the
    # baseline the run just wrote lists every file in seconds
    . (Join-Path $PSScriptRoot "bisync-index.ps1")
    $listings = Get-BisyncListings $root $DriveSyncConfig.Remote
    if (-not $listings) { Write-Host "sweep scan: no baseline listing - skipped"; exit 0 }
    $found = foreach ($line in [IO.File]::ReadLines($listings.Path1)) {
        if ($line -notmatch '\.conflict\d+"\s*$') { continue }
        $q1 = $line.IndexOf('"'); $q2 = $line.LastIndexOf('"')
        if ($q2 -gt $q1) { $line.Substring($q1 + 1, $q2 - $q1 - 1) -replace '/', '\' }
    }
    $kept = [System.Collections.Generic.List[string]]::new()
    $moved = 0
    foreach ($rel in @($found | Sort-Object -Unique)) {
        $abs = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
        $marker = Get-RedundancyMarker $abs $rel
        if ($marker) { Move-ToConflictArchive $rel "SCAN $marker"; $moved++ }
        else { $kept.Add($rel) }
    }
    Write-Host "sweep scan: $(@($found).Count) listed, $moved redundant moved, $($kept.Count) need review"
    if ($kept.Count -gt 0 -and -not $WhatIf) {
        foreach ($k in $kept) { Write-Host "  review: $k" }
        . (Join-Path $PSScriptRoot "notify.ps1")
        Send-DriveSyncAlert -Key "conflict-review" -Title "Drive-Sync: Konfliktkopien prüfen" `
            -Body "$($kept.Count) Konfliktkopie(n) mit eigenem Inhalt, z.B. $($kept[0]). Liste: sweep-conflicts.ps1 -Scan -WhatIf" | Out-Null
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $LogFile)) { Write-Host "sweep: log not found: $LogFile"; exit 0 }

# collect the loser paths this run created (both sides can lose)
$rels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($line in Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue) {
    $p = Get-ConflictLoserRel $line $root
    if ($p) { [void]$rels.Add($p) }
}
if ($rels.Count -eq 0) { exit 0 }
Write-Host "sweep: $($rels.Count) conflict cop(ies) named in $([IO.Path]::GetFileName($LogFile))"

$moved = 0
foreach ($rel in @($rels | Sort-Object)) {
    $abs = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $abs)) { continue }   # never downloaded or already swept
    Move-ToConflictArchive $rel (Test-InGitHistory $abs $rel)
    $moved++
}
if (-not $WhatIf) { Write-Host "sweep: $moved file(s) moved to $destRoot (log: $sweepLog)" }
