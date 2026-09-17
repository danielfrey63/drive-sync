# Shared record of LOCAL intent the upload watcher has not carried to the cloud
# yet: the old path of a rename and the path of a delete, written the moment the
# file system event is drained - not when the flush finally runs.
#
# Why this exists: on 2026-09-17 a file uploaded from another device was
# downloaded at 14:43:32 and renamed locally at 14:43:58. The upload watcher had
# the rename queued within a second, but it was busy with a stream of editor
# saves and only ran the server-side moveto at 14:46:01. For those two minutes
# the cloud still carried the OLD name. Drive then delivered a second change
# event for the freshly uploaded file, the cloud watcher resolved it to the old
# name, found no such file locally and downloaded it again at 14:44:38 - the
# user ended up with the file twice.
#
# The upload ledger could not prevent it: it records a rename only AFTER the
# moveto, and only the new name. What the cloud watcher was missing is "this path
# is gone locally on purpose, the cloud just has not heard yet". That is written
# here, and a download is skipped when its path (or an ancestor directory) is
# listed AND the file is really absent locally - a file that exists again is
# none of this record's business, --update handles it as before.
#
# One writer (watch-drive.ps1), one reader (watch-cloud.ps1). Once the cloud has
# caught up (moveto or delete succeeded, or the path turned out not to exist
# there), an entry is COMPLETED: it stays for a short grace period and then
# expires. Not removed at once, because the cloud watcher may have queued the
# old name in a poll just before the moveto and flush it a poll interval later.
# Not kept for the full hour either, because a GENUINE new cloud file under the
# old name - a scanner app uploading the next "Scan.pdf" - would be held back
# with it. Entries whose propagation failed age out after the full hour.
#
# Paths use "\" separators - the form both watchers' queues use. Dot-source:
#   . (Join-Path $PSScriptRoot "local-intent.ps1")
#   Add-LocalIntent $stateDir @($oldRel)
#   Complete-LocalIntent $stateDir @($oldRel)
#   $kept = Select-DownloadsWithoutLocalIntent $stateDir $root $batch ([ref]$skipped)

# Long enough to cover the slowest flush seen (an upload watcher busy with a
# large batch), short enough that a stranded entry cannot hold a genuine new
# cloud file back for long - the nightly bisync is the backstop either way.
$script:LocalIntentMaxAgeSec = 3600
# Grace after completion: three cloud poll intervals (PollSeconds = 60).
$script:LocalIntentGraceSec = 180

function Get-LocalIntentPath([string]$stateDir) {
    Join-Path $stateDir "local-intent.txt"
}

# rel -> unix seconds, expired entries dropped
function Read-LocalIntentMap([string]$stateDir) {
    $map = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $file = Get-LocalIntentPath $stateDir
    if (-not (Test-Path $file)) { return $map }
    $cut = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:LocalIntentMaxAgeSec
    foreach ($line in Get-Content $file -ErrorAction SilentlyContinue) {
        if ($line -notmatch '^(\d+)\t(.+)$') { continue }
        $t = [long]$Matches[1]
        if ($t -le $cut) { continue }
        $map[$Matches[2]] = $t
    }
    return $map
}

# The reader must never see a half-written file (it would read "no intent" and
# resurrect exactly what this guards against), so write aside and swap.
function Write-LocalIntentMap([string]$stateDir, $map) {
    $file = Get-LocalIntentPath $stateDir
    $lines = @($map.Keys | ForEach-Object { "$($map[$_])`t$_" })
    if ($lines.Count -eq 0) {
        if (Test-Path $file) { Remove-Item -LiteralPath $file -Force -Confirm:$false -ErrorAction SilentlyContinue }
        return
    }
    $tmp = "$file.tmp"
    Set-Content -LiteralPath $tmp -Value $lines -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $file -Force
}

function Add-LocalIntent([string]$stateDir, [string[]]$rels) {
    # never let this kill the watcher: a missing entry costs the old behaviour
    # for one file, an exception costs the watcher
    try {
        if (-not $rels -or $rels.Count -eq 0) { return }
        $map = Read-LocalIntentMap $stateDir
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        foreach ($r in $rels) { if ($r) { $map[($r -replace '/', '\')] = $now } }
        Write-LocalIntentMap $stateDir $map
    }
    catch { }
}

# Backdates the entries so they expire after the grace period. Never extends an
# entry that is already closer to expiry than that.
function Complete-LocalIntent([string]$stateDir, [string[]]$rels) {
    try {
        if (-not $rels -or $rels.Count -eq 0) { return }
        $map = Read-LocalIntentMap $stateDir
        $expiresAs = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:LocalIntentMaxAgeSec + $script:LocalIntentGraceSec
        $changed = $false
        foreach ($r in $rels) {
            if (-not $r) { continue }
            $k = $r -replace '/', '\'
            if ($map.ContainsKey($k) -and $map[$k] -gt $expiresAs) { $map[$k] = $expiresAs; $changed = $true }
        }
        if ($changed) { Write-LocalIntentMap $stateDir $map }
    }
    catch { }
}

# Exact path or any ancestor directory: a renamed or deleted folder takes its
# whole subtree with it.
function Test-LocalIntent($map, [string]$rel) {
    $p = $rel -replace '/', '\'
    while ($p) {
        if ($map.ContainsKey($p)) { return $true }
        $cut = $p.LastIndexOf('\')
        if ($cut -lt 0) { break }
        $p = $p.Substring(0, $cut)
    }
    return $false
}

# Returns the downloads that may proceed; the held-back ones go to $Skipped.
# Fails open: if the record cannot be read, everything proceeds as before.
function Select-DownloadsWithoutLocalIntent([string]$stateDir, [string]$root, [string[]]$rels, [ref]$Skipped) {
    $Skipped.Value = @()
    if (-not $rels -or $rels.Count -eq 0) { return @() }
    try { $map = Read-LocalIntentMap $stateDir }
    catch { return @($rels) }
    if ($map.Count -eq 0) { return @($rels) }
    $kept = [System.Collections.Generic.List[string]]::new()
    $held = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rels) {
        if ((Test-LocalIntent $map $r) -and -not (Test-Path -LiteralPath (Join-Path $root $r))) { $held.Add($r) }
        else { $kept.Add($r) }
    }
    $Skipped.Value = @($held)
    return @($kept)
}
