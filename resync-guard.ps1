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
# journalled (beyond its MaxDeletes cap, for a nightly run that never came):
# they are in no trash, so the rule above cannot see them.
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
. (Join-Path $PSScriptRoot "recycle-bin.ps1")
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
# Deletes beyond the watcher's MaxDeletes cap are journalled for the nightly
# bisync instead of executed. If that bisync is blocked, they never reach the
# cloud and are in no trash - the tombstone rule below cannot see them, and a
# resync downloads every one of them again (84 files on 2026-10-20, journalled
# 09.-11.10. while the nightly run needed a resync). Carry them out first, but
# only where it is still the same file: local path gone (not recreated) and
# the cloud copy not newer than the delete (1s slack) - a copy changed in the
# cloud after our delete is somebody's newer work and stays.
. (Join-Path $PSScriptRoot "delete-journal.ps1")
. (Join-Path $PSScriptRoot "upload-ledger.ps1")   # ConvertTo-UploadLedgerTime
function Get-RemotePath([string]$rel) { if ($remote.EndsWith(':')) { "$remote$rel" } else { "$remote/$rel" } }

$stateDir = $DriveSyncConfig.StateDir
# a scoped run only peeks: claiming would take the entries of every other
# subtree with it, and the clear at the end would drop them
$consume = -not $DryRun -and -not $Scope
$journal = @(Read-DroppedDeletes $stateDir "path1" -Claim:$consume -MaxAgeDays 30)
$prefix = if ($Scope) { "$Scope/" } else { "" }
$pendingDel = @{}   # rel (within scope, "/") -> unix time of the local delete
foreach ($e in $journal) {
    if ($prefix -and -not $e.Rel.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    $r = $e.Rel.Substring($prefix.Length)
    if (-not $r -or (Test-Path -LiteralPath (Join-Path $root ($r -replace '/', '\')))) { continue }   # recreated locally
    $pendingDel[$r] = $e.Time
}
if ($pendingDel.Count -gt 0) {
    $cloud = [System.Collections.Generic.List[object]]::new()   # @{ Rel; M; Entry }
    # A journal entry is a file or the root of a deleted tree, and the local
    # side can no longer tell which. One listing per parent folder answers it
    # for all siblings at once (--files-from-raw aborts on a folder entry).
    $byParent = $pendingDel.Keys | Group-Object { $i = $_.LastIndexOf('/'); if ($i -lt 0) { "" } else { $_.Substring(0, $i) } }
    foreach ($grp in $byParent) {
        $parent = $grp.Name
        $lsRaw = & $rcloneExe lsjson $(if ($parent) { Get-RemotePath $parent } else { $remote }) @($DriveSyncConfig.Pacer) 2>&1
        if ($LASTEXITCODE -eq 3) { continue }   # parent gone in the cloud too: nothing left to delete there
        if ($LASTEXITCODE -ne 0) { Write-Log "journal check failed for $parent (exit $LASTEXITCODE): $(($lsRaw | Select-Object -Last 1))"; exit 2 }
        $items = @{}
        foreach ($o in @((($lsRaw -join "`n") | ConvertFrom-Json))) { if ($o) { $items[$o.Name] = $o } }
        foreach ($entry in $grp.Group) {
            $leaf = if ($parent) { $entry.Substring($parent.Length + 1) } else { $entry }
            if (-not $items.ContainsKey($leaf)) { continue }   # already gone in the cloud
            $it = $items[$leaf]
            if (-not $it.IsDir) { $cloud.Add(@{ Rel = $entry; M = (ConvertTo-UploadLedgerTime $it.ModTime); Entry = $entry }); continue }
            $treeRaw = & $rcloneExe lsjson (Get-RemotePath $entry) -R --files-only @($DriveSyncConfig.Pacer) 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log "journal check failed for folder $entry (exit $LASTEXITCODE)"; exit 2 }
            foreach ($o in @((($treeRaw -join "`n") | ConvertFrom-Json))) {
                if ($o) { $cloud.Add(@{ Rel = "$entry/$($o.Path)"; M = (ConvertTo-UploadLedgerTime $o.ModTime); Entry = $entry }) }
            }
        }
    }
    $tmpJ = Join-Path ([IO.Path]::GetTempPath()) "resync-guard-journal.txt"
    $toDelete = [System.Collections.Generic.List[string]]::new()
    $keptNewer = 0
    foreach ($c in $cloud) {
        if (Test-Path -LiteralPath (Join-Path $root ($c.Rel -replace '/', '\'))) { continue }
        if ($null -ne $c.M -and $c.M -le $pendingDel[$c.Entry] + 1) { $toDelete.Add($c.Rel) }
        else { $keptNewer++; Write-Log "journal: kept, changed in the cloud after the local delete: $($c.Rel)" }
    }
    Write-Log "delete journal: $($pendingDel.Count) deferred local delete(s), $($toDelete.Count) still in the cloud and unchanged, $keptNewer changed since"
    if ($toDelete.Count -gt 0) {
        if ($DryRun) { $toDelete | ForEach-Object { Write-Log "DRYRUN would trash in the cloud: $_" } }
        else {
            Set-Content $tmpJ $toDelete -Encoding utf8NoBOM
            $delRaw = & $rcloneExe delete $remote --files-from-raw $tmpJ --no-traverse @($DriveSyncConfig.Pacer) 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log "journal deletes failed (exit $LASTEXITCODE): $(($delRaw | Select-Object -Last 1))"; exit 2 }
            Write-Log "journal: trashed $($toDelete.Count) file(s) in the cloud"
        }
    }
}
else { Write-Log "delete journal: nothing deferred" }
# the claimed batch is settled (never claimed under -DryRun or -Scope)
if ($consume -and $journal.Count -gt 0) { Clear-DroppedDeletes $stateDir "path1" }

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
    . (Join-Path $PSScriptRoot "filter-rules.ps1")
    $rules = Get-ExcludeRules $filters
    $null = Initialize-DriveApi $rcloneExe $DriveSyncConfig.RemoteName
    $prefix = if ($Scope) { "$Scope/" } else { "" }
    foreach ($f in Get-DriveTrashedFiles) {
        if ($prefix -and -not $f.Rel.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
        if (Test-Excluded $rules ($f.Rel -replace '/', '\')) { continue }
        Add-Tombstone $f.Rel.Substring($prefix.Length) $f.ModTime
    }
}
catch {
    Write-Log "drive api trash listing failed: $($_.Exception.Message) - falling back to rclone (slow)"
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
