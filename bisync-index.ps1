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
function Get-ListedPaths([string]$listing, [System.Collections.Generic.HashSet[string]]$wanted) {
    $hit = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($wanted.Count -eq 0) { return $hit }
    foreach ($line in [System.IO.File]::ReadLines($listing)) {
        if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }
        $a = $line.IndexOf('"')
        if ($a -lt 0) { continue }
        $b = $line.LastIndexOf('"')
        if ($b -le $a) { continue }
        $p = $line.Substring($a + 1, $b - $a - 1)
        if ($wanted.Contains($p)) { [void]$hit.Add($p) }
    }
    return $hit
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

# Report what a splice would have covered, and consume the journals. Reads only;
# the baselines are not touched. Returns the measurements, one per side that had
# entries, so a caller can assert on them.
function Write-SpliceReport([string]$localRoot, [string]$remote, [string]$stateDir) {
    $out = @()
    $listings = Get-BisyncListings $localRoot $remote
    if (-not $listings) {
        Write-Host "splice report: no baseline listings found - skipped"
        return $out
    }
    foreach ($side in @("path1", "path2")) {
        $journal = @(Read-DroppedDeletes $stateDir $side)
        if ($journal.Count -eq 0) { continue }
        $m = Measure-SpliceCandidates $localRoot $listings $side $journal
        # the concatenation needs its own parentheses: -f binds tighter than +,
        # so without them only the second literal would be formatted
        Write-Host ((
                "splice report {0}: {1} journalled - {2} would be spliced, " +
                "{3} already in the baseline, {4} back on disk, {5} unsafe name"
            ) -f $side, $m.Total, $m.Ready.Count, $m.InBaseline, $m.Recreated, $m.UnsafeName.Count)
        foreach ($p in @($m.Ready | Select-Object -First 5)) { Write-Host "    would splice: $p" }
        foreach ($p in @($m.UnsafeName | Select-Object -First 3)) { Write-Host "    unsafe name: $p" }
        # consumed: the entries describe the baseline of THIS run, not the next one
        Clear-DroppedDeletes $stateDir $side
        $out += $m
    }
    return $out
}
