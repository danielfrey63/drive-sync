# Keeps a --resync from reviving files that were deleted elsewhere.
#
# bisync --resync merges both sides and never deletes, so every file that
# exists only locally gets uploaded again - including everything that was
# deliberately deleted on another machine since this copy was made (676
# revived files on the first resync of a second laptop, 2026-09-25). A resync
# has no prior listing to tell "only local" from "deleted elsewhere"; the
# Drive trash has: every deletion our chain performs lands there for 30 days.
#
# Rule: a local file whose path matches a trashed cloud file, whose modtime is
# not newer than that tombstone (1s window, like --modify-window), and whose
# path is not live in the cloud, is a stale copy of a deleted file - it goes
# to the recycle bin before the resync can upload it. Equal modtime is the
# plain case (this copy IS the deleted file); an older modtime means the file
# was edited elsewhere and then deleted while this copy never saw the edit
# (pmo/tools/transcribe_watch.py, 2026-09-28: local 09-17, tombstone 09-22 -
# the equal-only rule let it through). Only a local file that is newer than
# every trashed twin was rewritten since and stays. Reach is the trash
# retention (30 days); older stale copies still need a manual
# "rclone check <local> gdrive: --one-way --missing-on-dst".
#
# Before that, step 0 carries out the local deletes the upload watcher only
# journalled (beyond its MaxDeletes cap): they are in no trash, so the rule
# above cannot see them. Same code as before every nightly run
# (journal-replay.ps1).
#
# Usage:
#   pwsh -File resync-guard.ps1            # act
#   pwsh -File resync-guard.ps1 -DryRun    # report only
#   pwsh -File resync-guard.ps1 -Scope "Develop/foo" -DryRun
#                                          # one subtree only (the trash is
#                                          # still listed in full, ~75 s)
# Called by sync-drive.ps1 -Resync; exit 0 = ok (also when nothing to do),
# exit 2 = trash listing or live check failed (the caller refuses to resync
# blind).

param(
    [switch]$DryRun,
    [string]$Scope = "",
    [string]$LogFile = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "journal-replay.ps1")   # also brings recycle-bin.ps1 and filter-rules.ps1
. (Join-Path $PSScriptRoot "notify.ps1")
$root = $DriveSyncConfig.LocalRoot
$remote = $DriveSyncConfig.Remote
if ($Scope) {
    $Scope = $Scope.Trim('/')
    $remote = "$remote$Scope"
    $root = Join-Path $root ($Scope -replace '/', '\')
}
$filters = Join-Path $PSScriptRoot "filters.txt"
$rcloneExe = Join-Path $DriveSyncConfig.StateDir "bin\rclone.exe"
if (-not (Test-Path $rcloneExe)) { $rcloneExe = "rclone" }
elseif (-not $env:RCLONE_CONFIG) {
    $cfg = @(& rclone config file 2>$null)[-1]
    if ($cfg -and (Test-Path $cfg)) { $env:RCLONE_CONFIG = $cfg }
}
if (-not $LogFile) {
    $logDir = Join-Path $DriveSyncConfig.StateDir "logs"
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $LogFile = Join-Path $logDir "resync-guard-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

function Write-Log([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') GUARD : $msg"
    Write-Host $line
    Add-Content $LogFile $line -ErrorAction SilentlyContinue
}

# --- 0. local deletes the upload watcher deferred (delete journal, path1) ----
# Deletes beyond the watcher's MaxDeletes cap are journalled instead of
# executed. They are in no trash - the tombstone rule below cannot see them,
# and a resync downloads every one of them again (84 files on 2026-10-20,
# journalled 09.-11.10. while the nightly run needed a resync). Carry them out
# first; the rules live in journal-replay.ps1, shared with the nightly run.
# Only path1: what the cloud deleted (path2) is exactly what the tombstone
# rule below covers, with the trashed file's own modtime as the stricter bound.
$rules = Get-ExcludeRules $filters
$replay = Invoke-JournalledDeletes -Side "path1" -LocalRoot $DriveSyncConfig.LocalRoot -Remote $DriveSyncConfig.Remote `
    -StateDir $DriveSyncConfig.StateDir -RcloneExe $rcloneExe -Rules $rules -Scope $Scope -DryRun:$DryRun `
    -Log { param($m) Write-Log $m }
if (-not $replay.Ok) { exit 2 }

# --- 1. trashed cloud files: path|modtime -----------------------------------
# One flat Drive API query (drive-api.ps1, ~75 s on 2026-10-22) instead of
# rclone's walk through every folder (~90 min before the 2026-10-20 resync).
# Measured against that walk on three subtrees: identical, except files
# trashed one by one inside a folder that was trashed afterwards - the walk
# misses those tombstones, the query has them. rclone stays as the fallback
# when the API is unreachable.
$trash = @{}   # rel path (/) -> list of modtimes (seconds precision)
function Add-Tombstone([string]$p, [datetime]$t) {
    if (-not $trash.ContainsKey($p)) { $trash[$p] = [System.Collections.Generic.List[datetime]]::new() }
    $trash[$p].Add($t)
}
$trashSource = "drive api"
try {
    . (Join-Path $PSScriptRoot "drive-api.ps1")
    $null = Initialize-DriveApi $rcloneExe $DriveSyncConfig.RemoteName
    $prefix = if ($Scope) { "$Scope/" } else { "" }
    foreach ($f in Get-DriveTrashedFiles) {
        if ($prefix -and -not $f.Rel.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
        if (Test-Excluded $rules ($f.Rel -replace '/', '\')) { continue }
        Add-Tombstone $f.Rel.Substring($prefix.Length) $f.ModTime
    }
    Clear-DriveSyncAlert -Key "resync-guard-fallback"
}
catch {
    Write-Log "drive api trash listing failed: $($_.Exception.Message) - falling back to rclone (slow)"
    # the resync still runs, but ~90 min later than it should - and a broken
    # API path would stay unnoticed in a log nobody reads
    Send-DriveSyncAlert -Key "resync-guard-fallback" -Title "Drive-Sync: Resync-Guard langsam" `
        -Body "Drive-API nicht erreichbar ($($_.Exception.Message)), der Papierkorb wird per rclone gelesen (~90 min). Log: $LogFile" | Out-Null
    $trash.Clear()
    $trashSource = "rclone"
    # --fast-list: one flat query instead of walking every folder of the corpus
    $trashRaw = & $rcloneExe lsf $remote --drive-trashed-only -R --files-only --fast-list `
        --format "pt" --separator "|" --filter-from $filters @($DriveSyncConfig.Pacer) 2>&1
    $trashExit = $LASTEXITCODE
    foreach ($line in $trashRaw) {
        if ($line -match '^(.+)\|(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)') {
            Add-Tombstone $Matches[1] ([datetime]::ParseExact($Matches[2], 'yyyy-MM-dd HH:mm:ss', $null))
        }
    }
    if ($trashExit -ne 0 -and $trash.Count -eq 0) {
        Write-Log "trash listing failed (exit $trashExit): $(($trashRaw | Select-Object -Last 1))"
        exit 2
    }
}
Write-Log "trash listing ($trashSource): $($trash.Count) path(s)"

# --- 2. local twins of trashed files ------------------------------------------
$candidates = [System.Collections.Generic.List[string]]::new()
foreach ($p in $trash.Keys) {
    $abs = Join-Path $root ($p -replace '/', '\')
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
    $localMod = (Get-Item -LiteralPath $abs).LastWriteTime
    $localSec = [datetime]::new($localMod.Year, $localMod.Month, $localMod.Day, $localMod.Hour, $localMod.Minute, $localMod.Second)
    # not newer than the newest tombstone: equal = the deleted copy itself,
    # older = never saw the last edit before the deletion; both are stale
    $newestTomb = ($trash[$p] | Measure-Object -Maximum).Maximum
    if (($localSec - $newestTomb).TotalSeconds -le 1) { $candidates.Add($p) }
}
Write-Log "local twins of trashed files: $($candidates.Count)"
if ($candidates.Count -eq 0) { exit 0 }

# --- 3. drop candidates that are live in the cloud ----------------------------
# The trash is full of identical twins of LIVE files: every dedupe run leaves
# the deleted duplicate there with the same path and modtime as the survivor,
# and rclone's "Removing failed copy" cleanup does the same. Only a path that
# is gone from the live tree is a real tombstone. -R is required: without it
# lsjson lists the root only and every nested candidate looks dead (the first
# dry run reported 277 live files for recycling, 2026-09-25). A failed live
# check must abort - the guard must never recycle on missing information.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "resync-guard-candidates.txt"
Set-Content $tmp $candidates -Encoding utf8NoBOM
$live = @{}
$liveJson = & $rcloneExe lsjson $remote -R --files-only --files-from-raw $tmp --no-traverse @($DriveSyncConfig.Pacer) 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "live check failed (exit $LASTEXITCODE): $(($liveJson | Select-Object -Last 1))"
    exit 2
}
foreach ($o in (($liveJson -join "`n") | ConvertFrom-Json)) { $live[$o.Path] = $true }
$revive = @($candidates | Where-Object { -not $live.ContainsKey($_) })

# Plausibility before anything irreversible. A returned path that matches no
# candidate means both sides spell names differently - on 2026-11-07 rclone's
# UTF-8 was read as ibm850 and the 5 candidates with a or an arrow in their
# names looked dead although live; their local files were recycled. And every
# path about to be recycled is confirmed dead on its own: few by nature, and
# the one step that cannot be undone from here.
$candSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$candidates, [System.StringComparer]::OrdinalIgnoreCase)
$stray = @($live.Keys | Where-Object { -not $candSet.Contains($_) })
if ($stray.Count -gt 0) {
    Write-Log "live check unreliable: $($stray.Count) returned path(s) match no candidate, e.g. '$($stray[0])' - aborting"
    exit 2
}
$sep = if ($remote.EndsWith(":")) { "" } else { "/" }
foreach ($r in $revive) {
    $one = & $rcloneExe lsjson "$remote$sep$r" --stat @($DriveSyncConfig.Pacer) 2>$null
    if ($LASTEXITCODE -eq 0 -and $one) {
        Write-Log "live check unreliable: '$r' is live on a single lookup - aborting"
        exit 2
    }
}
Write-Log "live in cloud again (kept): $($candidates.Count - $revive.Count); would be revived by resync: $($revive.Count)"

# --- 4. recycle -----------------------------------------------------------------
$ok = 0; $failed = 0
foreach ($p in $revive) {
    $abs = Join-Path $root ($p -replace '/', '\')
    if ($DryRun) { Write-Log "DRYRUN would recycle: $p"; continue }
    $rc = Move-ToRecycleBin $abs
    if ($rc -eq 0) { $ok++; Write-Log "recycled: $p" }
    else { $failed++; Write-Log "WARN recycle failed (rc=$rc): $p" }
}
if ($DryRun) { Write-Log "dry run: $($revive.Count) file(s) would be recycled" }
else { Write-Log "recycled $ok file(s), $failed failed" }
exit 0
