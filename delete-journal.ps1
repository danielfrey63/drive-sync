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
#   $paths = Read-DroppedDeletes $stateDir "path1" -Claim
#   Clear-DroppedDeletes $stateDir "path1"
#
# One writer per file (the local watcher owns path1, the cloud watcher path2), so
# writers never meet. Reader against writer is serialised by the existing PID lock
# "sync.lock": both watchers skip their whole flush cycle while a live process
# holds it, and the consumer runs under it. That leaves one window - the wrapper
# takes the lock without waiting for a watcher that is ALREADY mid-flush, and an
# upload batch runs for minutes. -Claim closes it.

# Entries older than this are ignored on read and dropped on the next write: if
# the consumer never runs, a stale path must not accumulate forever. Generous
# against a bisync that failed for a few nights in a row.
$script:JournalMaxAgeDays = 7

function Get-DeleteJournalPath([string]$stateDir, [string]$side) {
    Join-Path $stateDir "dropped-deletes-$side.txt"
}

# the batch a consumer has taken aside; never written to by a watcher
function Get-DeleteClaimPath([string]$stateDir, [string]$side) {
    (Get-DeleteJournalPath $stateDir $side) + ".consuming"
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

# -Claim renames the journal aside and reads the renamed copy. The rename is
# atomic on NTFS, so a watcher appending at that very moment writes into a fresh
# journal and its entries survive; plain read-then-clear would drop them.
# Without -Claim nothing is moved and both files are read - a peek at everything
# still pending, including a batch a dead consumer left behind.
function Read-DroppedDeletes([string]$stateDir, [string]$side, [switch]$Claim) {
    try {
        $file = Get-DeleteJournalPath $stateDir $side
        # NOT $claim: PowerShell variables are case-insensitive, so that name
        # would overwrite the [switch]$Claim parameter - and the type constraint
        # then throws on the string, straight into the catch below
        $claimFile = Get-DeleteClaimPath $stateDir $side
        if ($Claim -and (Test-Path $file)) {
            if (Test-Path $claimFile) {
                # a previous consumer died between claim and clear: fold the new
                # lines into its batch instead of overwriting it. Not atomic, but
                # reaching here already requires a dead consumer
                Add-Content -Path $claimFile -Value (Get-Content $file) -Encoding UTF8
                Remove-Item $file -Force -Confirm:$false -ErrorAction SilentlyContinue
            }
            else { Move-Item -LiteralPath $file -Destination $claimFile -Force }
        }
        $sources = if ($Claim) { @($claimFile) } else { @($file, $claimFile) }
        $cut = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - ($script:JournalMaxAgeDays * 86400)
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($src in $sources) {
            if (-not (Test-Path $src)) { continue }
            foreach ($line in Get-Content $src -ErrorAction SilentlyContinue) {
                if ($line -notmatch '^(\d+)\t(.+)$') { continue }
                if ([long]$Matches[1] -le $cut) { continue }
                [void]$seen.Add($Matches[2])
            }
        }
        return @($seen)
    }
    # must not abort the caller (the watcher would die, the bisync would skip its
    # run), but must not be invisible either: a silent catch here hid a variable
    # collision that made every read return nothing
    catch { Write-Host "delete journal read failed ($side): $($_.Exception.Message)"; return @() }
}

# Drops the claimed batch only - what a watcher appended in the meantime lives in
# the fresh journal and stays. -All drops that too (reset, tests).
function Clear-DroppedDeletes([string]$stateDir, [string]$side, [switch]$All) {
    try {
        $files = @(Get-DeleteClaimPath $stateDir $side)
        if ($All) { $files += Get-DeleteJournalPath $stateDir $side }
        foreach ($f in $files) {
            if (Test-Path $f) { Remove-Item $f -Force -Confirm:$false -ErrorAction SilentlyContinue }
        }
    }
    catch { Write-Host "delete journal clear failed ($side): $($_.Exception.Message)" }
}
