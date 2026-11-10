# Retry bookkeeping for the upload watcher's batches (watch-drive.ps1).
#
# One "rclone copy" carries a whole batch. Until 2026-11-10 a non-zero exit put
# the complete batch back and tried again 15 s later, for as long as it took:
# a file another program held open (298 attempts on one .workflow.lock.guard
# on 2026-11-06) kept that loop spinning all day, three rclone-internal
# attempts per round, and nothing ever said so. A DNS outage did the same with
# 4248 files at once.
#
# rclone's own log says which paths failed. Those are parked with a growing
# delay and reported once they stay stuck; everything else in the batch is
# done or goes back into the queue. Pure functions, no rclone and no file
# system in here - test-upload-retry.ps1 runs them against a real rclone log.
#
#   $parked = New-UploadParking
#   $out = Get-FlushOutcome (Get-Content $flushLog)      # .Copied / .Failed
#   $e = Add-UploadStrike $parked $rel $reason (Get-Date)
#   Get-DueUploads $parked (Get-Date)
#   Get-StuckUploads $parked (Get-Date) 60

# rel path ("\" separators) -> entry with Rel, Strikes, First, Next, Reason
function New-UploadParking {
    # the comma keeps PowerShell from unrolling the empty dictionary into $null
    , [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
}

# Reads the log of ONE rclone copy. A path counts as copied only with a line
# that says so; a path without any line was either unchanged or never reached
# (a fatal error ends the run early), and the caller must not guess which.
# A colon cannot occur in a Windows file name, so the first ": Failed to copy"
# ends the path.
function Get-FlushOutcome([string[]]$logLines) {
    $copied = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $failed = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $logLines) {
        if ($line -match ' INFO +: (.+?): (?:Copied \(|Updated modification time in destination)') {
            [void]$copied.Add(($Matches[1] -replace '/', '\'))
        }
        elseif ($line -match ' ERROR +: (.+?): Failed to copy: (.+)$') {
            $rel = $Matches[1] -replace '/', '\'
            # the last clause is the cause ("... read <path>: <cause>"); the
            # text before it repeats the request URL and the path
            $reason = ($Matches[2] -split ': ')[-1].Trim()
            if ($reason.Length -gt 160) { $reason = $reason.Substring(0, 160) }
            $failed[$rel] = $reason
        }
    }
    foreach ($rel in @($failed.Keys)) { if ($copied.Contains($rel)) { [void]$failed.Remove($rel) } }   # a retry inside the run got it through
    [pscustomobject]@{ Copied = $copied; Failed = $failed }
}

# minutes until the next attempt after the n-th failure in a row: 1, 2, 4, 8,
# 16, then every 30. A file that is locked for a meeting's length costs a
# handful of attempts instead of several hundred, and is picked up within
# half an hour of being released.
function Get-UploadRetryMinutes([int]$strikes) {
    if ($strikes -ge 6) { return 30 }
    [int][math]::Pow(2, [math]::Max(0, $strikes - 1))
}

# seconds to hold ALL uploads after the n-th batch in a row that failed as a
# whole (network, sign-in): 15, 30, 60, 120, 240, then 300
function Get-UploadHoldSeconds([int]$failures) {
    if ($failures -ge 6) { return 300 }
    [int](15 * [math]::Pow(2, [math]::Max(0, $failures - 1)))
}

function Add-UploadStrike($parked, [string]$rel, [string]$reason, [datetime]$now) {
    if ($parked.ContainsKey($rel)) { $e = $parked[$rel] }
    else {
        $e = [pscustomobject]@{ Rel = $rel; Strikes = 0; First = $now; Next = $now; Reason = "" }
        $parked[$rel] = $e
    }
    $e.Strikes++
    $e.Reason = $reason
    $e.Next = $now.AddMinutes((Get-UploadRetryMinutes $e.Strikes))
    $e
}

# parked paths whose delay has run out
function Get-DueUploads($parked, [datetime]$now) {
    foreach ($e in @($parked.Values)) { if ($e.Next -le $now) { $e.Rel } }
}

# entries that have been failing for at least $minutes, longest first
function Get-StuckUploads($parked, [datetime]$now, [double]$minutes) {
    @($parked.Values | Where-Object { ($now - $_.First).TotalMinutes -ge $minutes } | Sort-Object First)
}
