# Recognises bisync's conflict-loser names (<name>.conflictN), shared by the
# upload watcher and the conflict sweep. Dot-source; no dependencies.
#
# Both helpers exist because of the cascade of 2026-10-02..05 (127 loser
# copies, nested six deep as install.ps1.conflict1.conflict1...):
#  - the upload watcher replayed bisync's own local rename "X -> X.conflict1"
#    as a server-side move once the nightly lock was gone. Bisync had already
#    settled both sides, so the replay moved the cloud's WINNER onto the
#    conflict name; local and cloud .conflict1 then differed and the next
#    night raised a conflict on the conflict file.
#  - the sweep that should have moved the losers out of the corpus read the
#    drive letter of "D:\root\rel" as a remote name and never found a file
#    (since --conflict-resolve newer only Path1 lines carry a loser).

# Is the rename $oldRel -> $newRel bisync parking a conflict loser, i.e. the
# new name is exactly the old one plus ".conflict<N>"?
function Test-ConflictLoserRename([string]$oldRel, [string]$newRel) {
    if (-not $oldRel -or $newRel.Length -le $oldRel.Length) { return $false }
    if (-not $newRel.StartsWith($oldRel, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $newRel.Substring($oldRel.Length) -match '^\.conflict\d+$'
}

# Extracts the loser's path relative to $root (backslashes) from a bisync log
# line, or $null if the line names no loser. Handles both sides:
#   "- Path1  Renaming Path1 copy  - D:\Meine Ablage\Develop/x.md.conflict1"
#   "- Path2  Renaming Path2 copy  - gdrive{sl-MZ}:/Develop/x.md.conflict1"
# "Not renaming Path2 copy, as it was determined the winner - ...conflict1"
# names a WINNER (of a nested conflict) and must not match.
function Get-ConflictLoserRel([string]$line, [string]$root) {
    if ($line -cnotmatch '(?<!Not )Renaming Path[12] copy\s+-\s+(.+\.conflict\d+)\s*$') { return $null }
    $p = $Matches[1].Trim() -replace '/', '\'
    if ($p -match '^[A-Za-z]:\\') {
        # local form: must live under the root, anything else is not ours
        $r = $root.TrimEnd('\')
        if (-not $p.StartsWith("$r\", [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        $p = $p.Substring($r.Length)
    }
    elseif ($p -match '^[^:\\]+:(.*)$') { $p = $Matches[1] }   # remote form name{id}:\rel
    $p = $p.TrimStart('\')
    if ($p) { return $p } else { return $null }
}
