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

param(
    [Parameter(Mandatory)][string]$LogFile,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
$root = $DriveSyncConfig.LocalRoot
$stateDir = $DriveSyncConfig.StateDir
$sweepLog = Join-Path $stateDir "conflicts.log"

if (-not (Test-Path -LiteralPath $LogFile)) { Write-Host "sweep: log not found: $LogFile"; exit 0 }

# collect the loser paths this run created (both sides can lose)
$rels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($line in Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue) {
    if ($line -notmatch 'Renaming Path[12] copy\s+-\s+(.+\.conflict\d+)\s*$') { continue }
    $p = $Matches[1].Trim()
    if ($p -match '^[^:]+:(.*)$') { $p = $Matches[1] }                    # remote form gdrive{...}:/rel
    $p = $p -replace '/', '\'
    if ($p.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { $p = $p.Substring($root.Length) }
    $p = $p.TrimStart('\')
    if ($p) { [void]$rels.Add($p) }
}
if ($rels.Count -eq 0) { exit 0 }
Write-Host "sweep: $($rels.Count) conflict cop(ies) named in $([IO.Path]::GetFileName($LogFile))"

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

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$destRoot = Join-Path $stateDir "conflicts\$stamp"
$moved = 0
foreach ($rel in @($rels | Sort-Object)) {
    $abs = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $abs)) { continue }   # never downloaded or already swept
    $marker = Test-InGitHistory $abs $rel
    if ($WhatIf) { Write-Host "sweep would move [$marker]: $rel"; continue }
    $dest = Join-Path $destRoot $rel
    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
    Move-Item -LiteralPath $abs -Destination $dest
    Add-Content $sweepLog "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$marker] $rel -> $dest"
    Write-Host "sweep [$marker]: $rel"
    $moved++
}
if (-not $WhatIf) { Write-Host "sweep: $moved file(s) moved to $destRoot (log: $sweepLog)" }
