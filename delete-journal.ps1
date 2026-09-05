# Shared journal for deletes that the watchers dropped at the MaxDeletes cap.
#
# Why this exists: when a delete storm exceeds the cap, the watcher logs "leaving
# them to the nightly bisync" and drops the list. But bisync computes its deltas
# against the baseline listings of the previous run, and a file that was created
# AFTER that baseline is absent from it - so bisync does not see "deleted on the
# side that deleted it", it sees "new on the other side" and copies it back. On
# 2026-09-05 that resurrected eight files (bisync log 04:25:42, "Copied (new)").
#
# The information bisync is missing is exactly what the cap throws away. This
# records it instead, so a later step can tell bisync about it.
#
# Sides are named after bisync's own vocabulary:
#   path1 - the local mirror; the watcher deleted here, the cloud still has it
#   path2 - the cloud;        the cloud deleted here, the local mirror still has it
#
# Paths are stored with "/" separators - the form the bisync listings use, which
# is the only consumer. Dot-source this file, then:
#   . (Join-Path $PSScriptRoot "delete-journal.ps1")
#   Add-DroppedDeletes $stateDir "path1" $paths
#   $paths = Read-DroppedDeletes $stateDir "path1"
#   Clear-DroppedDeletes $stateDir "path1"

# Entries older than this are ignored on read and dropped on the next write: if
# the consumer never runs, a stale path must not accumulate forever. Generous
# against a bisync that failed for a few nights in a row.
$script:JournalMaxAgeDays = 7

function Get-DeleteJournalPath([string]$stateDir, [string]$side) {
    Join-Path $stateDir "dropped-deletes-$side.txt"
}

function Add-DroppedDeletes([string]$stateDir, [string]$side, [string[]]$rels) {
    # never let journalling kill a watcher: a missing journal costs us the
    # splice for one night, an exception costs us the watcher
    try {
        if (-not $rels -or $rels.Count -eq 0) { return }
        $file = Get-DeleteJournalPath $stateDir $side
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $lines = @($rels | ForEach-Object { "$now`t$($_ -replace '\\', '/')" })
        Add-Content -Path $file -Value $lines -Encoding UTF8
    }
    catch { }
}

function Read-DroppedDeletes([string]$stateDir, [string]$side) {
    try {
        $file = Get-DeleteJournalPath $stateDir $side
        if (-not (Test-Path $file)) { return @() }
        $cut = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - ($script:JournalMaxAgeDays * 86400)
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($line in Get-Content $file -ErrorAction SilentlyContinue) {
            if ($line -notmatch '^(\d+)\t(.+)$') { continue }
            if ([long]$Matches[1] -le $cut) { continue }
            [void]$seen.Add($Matches[2])
        }
        return @($seen)
    }
    catch { return @() }
}

function Clear-DroppedDeletes([string]$stateDir, [string]$side) {
    try {
        $file = Get-DeleteJournalPath $stateDir $side
        if (Test-Path $file) { Remove-Item $file -Force -Confirm:$false -ErrorAction SilentlyContinue }
    }
    catch { }
}
