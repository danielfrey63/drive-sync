# Upload ledger: echo control between the two watchers.
#
# The upload watcher records every path it sends to the cloud; the cloud
# watcher skips change events that are merely the echo of such an upload.
# Until 2026-10-05 the ledger carried only "timestamp<TAB>path" and the reader
# suppressed EVERY change of that path for an hour. With a second machine on
# the same remote that swallowed real edits: on 2026-10-03 this machine
# ledgered laptop-setup/setup/install.ps1 at 15:20, the other machine edited
# it at 16:02, the event was dropped as an "own-upload echo", and the nightly
# bisync found two diverged sides (start of a .conflictN cascade).
#
# Now each entry also carries what was uploaded - modtime (unix seconds, UTC)
# and size - and an event is an echo only if the cloud state it reports is
# exactly that upload. Lines without the two fields (written by an older
# watcher, or for a path that had no local file at ledger time) keep the old
# path-only meaning, as does an event without usable metadata: when in doubt,
# the event counts as an echo, because downloading our own upload back over a
# file that is being edited is the worse failure (2026-08-28, 2026-08-29).
#
# Line format: <unix ts>\t<rel path, backslashes>[\t<mtime unix>\t<size>]
# Dot-source; no dependencies. Retention must cover the Drive changes-API
# latency (a 486 MB upload surfaced its event 23 min late on 2026-08-28).

$script:UploadLedgerRetentionSec = 3600

function Get-UploadLedgerPath([string]$stateDir) { Join-Path $stateDir "upload-ledger.txt" }

# Appends entries for the given relative paths and prunes expired lines.
# Throws on I/O errors - the caller decides how loud to be.
function Add-UploadLedger([string]$stateDir, [string]$root, [string[]]$rels) {
    if (-not $rels -or $rels.Count -eq 0) { return }
    $file = Get-UploadLedgerPath $stateDir
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cut = $now - $script:UploadLedgerRetentionSec
    $keep = @()
    if (Test-Path -LiteralPath $file) {
        $keep = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^(\d+)\t' -and [long]$Matches[1] -gt $cut })
    }
    $keep += @(foreach ($rel in $rels) {
            $fi = Get-Item -LiteralPath (Join-Path $root $rel) -Force -ErrorAction SilentlyContinue
            if ($fi -and -not $fi.PSIsContainer) {
                $m = [DateTimeOffset]::new($fi.LastWriteTimeUtc).ToUnixTimeSeconds()
                "$now`t$rel`t$m`t$($fi.Length)"
            }
            else { "$now`t$rel" }
        })
    $tmp = "$file.tmp"
    Set-Content -LiteralPath $tmp -Value $keep
    Move-Item -LiteralPath $tmp -Destination $file -Force
}

# Returns rel path (case-insensitive) -> list of entries; an entry is either
# @{ M = <mtime unix>; S = <size> } or $null for a path-only (legacy) line.
# Fail-open on read errors: an empty ledger means "nothing is an echo".
function Get-UploadLedger([string]$stateDir) {
    $ledger = [System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        $file = Get-UploadLedgerPath $stateDir
        if (-not (Test-Path -LiteralPath $file)) { return $ledger }
        $cut = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:UploadLedgerRetentionSec
        foreach ($line in Get-Content -LiteralPath $file -ErrorAction SilentlyContinue) {
            $parts = $line -split "`t"
            if ($parts.Count -lt 2 -or $parts[0] -notmatch '^\d+$' -or [long]$parts[0] -le $cut) { continue }
            $rel = $parts[1]
            if (-not $ledger.ContainsKey($rel)) { $ledger[$rel] = [System.Collections.ArrayList]::new() }
            if ($parts.Count -ge 4 -and $parts[2] -match '^\d+$' -and $parts[3] -match '^\d+$') {
                [void]$ledger[$rel].Add(@{ M = [long]$parts[2]; S = [long]$parts[3] })
            }
            else { [void]$ledger[$rel].Add($null) }
        }
    }
    catch {}
    return $ledger
}

# Drive's modifiedTime as unix seconds, or $null if unusable. The JSON layer
# hands it over as [datetime] (PowerShell 7 parses ISO strings) or as the raw
# RFC 3339 string (Windows PowerShell 5.1); a [datetime] of unspecified kind
# is taken as UTC, which is what Drive sends.
function ConvertTo-UploadLedgerTime($value) {
    try {
        if ($null -eq $value -or $value -eq '') { return $null }
        if ($value -is [datetime]) {
            $utc = if ($value.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($value, [DateTimeKind]::Utc) } else { $value.ToUniversalTime() }
            return [DateTimeOffset]::new($utc).ToUnixTimeSeconds()
        }
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        return [DateTimeOffset]::Parse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, $styles).ToUnixTimeSeconds()
    }
    catch { return $null }
}

# Is a cloud change event for $rel, reporting modtime $cloudMtime (unix
# seconds) and size $cloudSize, the echo of one of our own recent uploads?
# Pass $null for unknown metadata (falls back to path-only).
function Test-UploadEcho($ledger, [string]$rel, $cloudMtime, $cloudSize) {
    if (-not $ledger.ContainsKey($rel)) { return $false }
    if ($null -eq $cloudMtime -or $null -eq $cloudSize) { return $true }
    foreach ($e in $ledger[$rel]) {
        if ($null -eq $e) { return $true }   # path-only entry
        # 1s window like --modify-window: Drive keeps ms, NTFS 100ns
        if ($e.S -eq [long]$cloudSize -and [math]::Abs($e.M - [long]$cloudMtime) -le 1) { return $true }
    }
    return $false
}
