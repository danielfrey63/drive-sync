# Shared snapshot metrics for the restic backup, and the ransomware tripwire
# built on them. Dot-sourced by run-backup.ps1 (verdict on the run that just
# finished) and by backup-status.ps1 (snapshot list and the -Audit replay).
#
# restic stores the summary of a run inside the snapshot itself, so the whole
# history is available from one cheap "snapshots --json" call - no extra state
# file to keep in sync.
#
# Everything is a RATE, never an absolute number: the C: and D: chains differ
# by a factor of ~500 in file count and by three orders of magnitude in upload
# volume, so a shared absolute threshold would be meaningless for one of them.
#
# Changed files and new files are judged separately, and that is the central
# design decision. A bulk import (a photo drop, an archive) is large,
# incompressible and entirely legitimate - it ADDS files. Ransomware REPLACES
# existing ones. A single combined rate throws that distinction away: measured
# on 08.09.2026, a 60'000-file photo import and an in-place encryption of
# 300'000 files land on the same side of any one threshold.
#
# Four legs, each of which alone raises the alarm:
#   changed rate  - in-place encryption
#   new rate      - rename encryption (foo.docx -> foo.docx.locked), loose
#   shrink rate   - mass deletion, and the other half of rename encryption
#   window rate   - slow burn that stays under the per-run limits
#
# Upload volume and compression ratio are corroborating hints in the message,
# never triggers on their own: the legitimate first D: snapshot had ratio
# 1.05, exactly the value a naive "incompressible means encrypted" rule would
# have fired on.
#
# Thresholds are static (backup-config.ps1) rather than a rolling baseline.
# A rolling baseline can be poisoned: malware that ramps up slowly over twenty
# snapshots trains its own normal.

function Get-BackupMedian {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return 0 }
    $sorted = @($Values | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return $sorted[$mid] }
    return ($sorted[$mid - 1] + $sorted[$mid]) / 2
}

# One record per snapshot that carries a summary, sorted by chain and time.
function Get-BackupSnapshotStats {
    param([Parameter(Mandatory)] $Config)

    $env:RESTIC_REPOSITORY    = $Config.Repository
    $env:RESTIC_PASSWORD_FILE = $Config.PasswordFile
    if ($Config.CacheDir) { $env:RESTIC_CACHE_DIR = $Config.CacheDir }

    $raw = & $Config.Restic snapshots --json -o "sftp.command=$($Config.SshCommand)" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    $snaps = ($raw -join "`n") | ConvertFrom-Json

    $stats = foreach ($s in $snaps) {
        if (-not $s.summary -or -not $s.paths) { continue }
        $new   = [double]$s.summary.files_new
        $chg   = [double]$s.summary.files_changed
        $unmod = [double]$s.summary.files_unmodified
        $total = $new + $chg + $unmod
        if ($total -le 0) { continue }

        $packed = [double]$s.summary.data_added_packed
        $added  = [double]$s.summary.data_added
        $ratio  = 0
        if ($packed -gt 0) { $ratio = $added / $packed }

        $minutes = 0
        if ($s.summary.backup_start -and $s.summary.backup_end) {
            $minutes = [math]::Round((([datetime]$s.summary.backup_end) - ([datetime]$s.summary.backup_start)).TotalMinutes, 1)
        }

        [pscustomobject]@{
            ShortId     = $s.short_id
            Time        = [datetime]$s.time
            Chain       = ($s.paths -join ",")
            Path        = $s.paths[0]
            New         = [int]$new
            Changed     = [int]$chg
            Unmodified  = [int]$unmod
            Touched     = [int]($new + $chg)
            Total       = [int]$total
            Added       = $added
            Packed      = $packed
            Ratio       = $ratio
            Minutes     = $minutes
            ChangedRate = $chg / $total
            NewRate     = $new / $total
            # a chain's first snapshot has nothing unmodified: every file is
            # new, every rate is 100 % by definition, so it is exempt
            IsInitial   = ($unmod -le 0)
            ShrinkRate  = $null
            PrevTotal   = $null
        }
    }

    # Shrink is measured against the previous snapshot of the SAME chain.
    # It is the second leg of the detector: ransomware that renames instead of
    # overwriting (foo.docx -> foo.docx.locked) leaves files_changed at zero,
    # but the corpus visibly loses its old members.
    $ordered = @($stats | Sort-Object Chain, Time)
    $prevTotal = @{}
    foreach ($st in $ordered) {
        if ($prevTotal.ContainsKey($st.Chain)) {
            $p = $prevTotal[$st.Chain]
            $st.PrevTotal = $p
            if ($p -gt 0) { $st.ShrinkRate = 1 - ($st.Total / $p) }
        }
        $prevTotal[$st.Chain] = $st.Total
    }
    return $ordered
}

# per-chain limit with a "*" fallback; used for both rate thresholds
function Get-BackupChainLimit {
    param($Map, [string]$Path, [double]$Default = 0.05)
    if ($Map) {
        if ($Map.ContainsKey($Path)) { return [double]$Map[$Path] }
        if ($Map.ContainsKey("*"))   { return [double]$Map["*"] }
    }
    return $Default
}

# Verdict for a single snapshot. $History are the snapshots that existed
# before it (used only for the corroborating volume hint).
function Test-BackupAnomaly {
    param($Config, $Stat, $History)

    $verdict = [pscustomobject]@{ Level = "ok"; Reasons = @(); Notes = @() }
    if ($Stat.IsInitial) { return $verdict }

    $enough = ($Stat.Touched -ge $Config.AnomalyMinFiles)

    $changedLimit = Get-BackupChainLimit -Map $Config.AnomalyChangedRate -Path $Stat.Path -Default 0.03
    if ($enough -and $Stat.ChangedRate -gt $changedLimit) {
        $verdict.Reasons += ("[{0}] {1:N0} of {2:N0} existing files rewritten in one run ({3:P2}, limit {4:P0})" -f `
            $Stat.Path, $Stat.Changed, $Stat.Total, $Stat.ChangedRate, $changedLimit)
    }
    $newLimit = Get-BackupChainLimit -Map $Config.AnomalyNewRate -Path $Stat.Path -Default 0.15
    if ($enough -and $Stat.NewRate -gt $newLimit) {
        $verdict.Reasons += ("[{0}] {1:N0} new files in one run ({2:P2} of {3:N0}, limit {4:P0})" -f `
            $Stat.Path, $Stat.New, $Stat.NewRate, $Stat.Total, $newLimit)
    }
    $shrinkLimit = Get-BackupChainLimit -Map $Config.AnomalyShrinkRate -Path $Stat.Path
    if ($null -ne $Stat.ShrinkRate -and $Stat.ShrinkRate -gt $shrinkLimit) {
        $verdict.Reasons += ("[{0}] corpus shrank {1:P2} (limit {2:P0}): {3:N0} -> {4:N0} files" -f `
            $Stat.Path, $Stat.ShrinkRate, $shrinkLimit, $Stat.PrevTotal, $Stat.Total)
    }

    # slow burn: sum the changed share over a window. Files touched in more
    # than one slot are counted more than once - the sum is an upper bound,
    # which errs toward noticing rather than toward missing.
    $windowLimit = Get-BackupChainLimit -Map $Config.AnomalyWindowChangedRate -Path $Stat.Path -Default 0.08
    $since = $Stat.Time.AddHours(-1 * $Config.AnomalyWindowHours)
    $window = @($History | Where-Object { $_.Chain -eq $Stat.Chain -and -not $_.IsInitial -and $_.Time -ge $since })
    if ($window.Count -ge 2) {
        $windowRate = $Stat.ChangedRate + (($window | ForEach-Object { $_.ChangedRate }) | Measure-Object -Sum).Sum
        if ($windowRate -gt $windowLimit) {
            $verdict.Reasons += ("[{0}] {1:P2} of the files rewritten over the last {2} h across {3} runs (limit {4:P0})" -f `
                $Stat.Path, $windowRate, $Config.AnomalyWindowHours, ($window.Count + 1), $windowLimit)
        }
    }

    # hints only above a volume floor - below it both numbers are rounding
    # noise (a 0.3 MB snapshot legitimately shows a ratio of 5.9)
    if ($Stat.Packed -gt ($Config.AnomalyVolumeFloorGB * 1GB)) {
        $peers = @($History | Where-Object { $_.Chain -eq $Stat.Chain -and -not $_.IsInitial } |
            Sort-Object Time | Select-Object -Last 20 | ForEach-Object { $_.Packed })
        $median = Get-BackupMedian -Values $peers
        if ($median -gt 0 -and $Stat.Packed -gt ($median * $Config.AnomalyVolumeFactor)) {
            $verdict.Notes += ("[{0}] upload {1:N1} GB is {2:N0}x the chain median" -f `
                $Stat.Path, ($Stat.Packed / 1GB), ($Stat.Packed / $median))
        }
        if ($Stat.Ratio -gt 0 -and $Stat.Ratio -lt $Config.AnomalyRatioFloor) {
            $verdict.Notes += ("[{0}] new data is incompressible (ratio {1:N2})" -f $Stat.Path, $Stat.Ratio)
        }
    }

    if ($verdict.Reasons.Count -gt 0) { $verdict.Level = "alarm" }
    elseif ($verdict.Notes.Count -gt 0) { $verdict.Level = "note" }
    return $verdict
}

# The latch. Without it the next run six hours later sees a perfectly normal
# rewrite rate - the files are encrypted by then, so they count as unmodified -
# and would happily resume forget/prune while the only clean snapshots age out.
function Get-BackupAnomalyLatch {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Set-BackupAnomalyLatch {
    param([string]$Path, [string[]]$Reasons)
    [pscustomobject]@{
        time    = (Get-Date).ToString("o")
        reasons = $Reasons
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding utf8
}
