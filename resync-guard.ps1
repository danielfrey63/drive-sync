# Keeps a --resync from reviving files that were deleted elsewhere.
#
# bisync --resync merges both sides and never deletes, so every file that
# exists only locally gets uploaded again - including everything that was
# deliberately deleted on another machine since this copy was made (676
# revived files on the first resync of a second laptop, 2026-09-25). A resync
# has no prior listing to tell "only local" from "deleted elsewhere"; the
# Drive trash has: every deletion our chain performs lands there for 30 days.
#
# Rule: a local file whose path AND modtime (1s window, like --modify-window)
# match a trashed cloud file, and whose path is not live in the cloud, is the
# deleted copy - it goes to the recycle bin before the resync can upload it.
# A local file that is newer than its trashed twin was rewritten since and
# stays. Reach is the trash retention (30 days); older stale copies still
# need a manual "rclone check <local> gdrive: --one-way --missing-on-dst".
#
# Usage:
#   pwsh -File resync-guard.ps1            # act
#   pwsh -File resync-guard.ps1 -DryRun    # report only
#   pwsh -File resync-guard.ps1 -Scope "Develop/foo" -DryRun
#                                          # one subtree only (seconds instead
#                                          # of the ~90 min full trash listing)
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

# --- 1. trashed cloud files: path|modtime -----------------------------------
# --fast-list: one flat query instead of walking every folder of the corpus
$trashRaw = & $rcloneExe lsf $remote --drive-trashed-only -R --files-only --fast-list `
    --format "pt" --separator "|" --filter-from $filters @($DriveSyncConfig.Pacer) 2>&1
$trashExit = $LASTEXITCODE
$trash = @{}   # rel path (/) -> list of modtimes (seconds precision)
foreach ($line in $trashRaw) {
    if ($line -match '^(.+)\|(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)') {
        $p = $Matches[1]
        if (-not $trash.ContainsKey($p)) { $trash[$p] = [System.Collections.Generic.List[datetime]]::new() }
        $trash[$p].Add([datetime]::ParseExact($Matches[2], 'yyyy-MM-dd HH:mm:ss', $null))
    }
}
if ($trashExit -ne 0 -and $trash.Count -eq 0) {
    Write-Log "trash listing failed (exit $trashExit): $(($trashRaw | Select-Object -Last 1))"
    exit 2
}
Write-Log "trash listing: $($trash.Count) path(s) (lsf exit $trashExit)"

# --- 2. local twins of trashed files ------------------------------------------
$candidates = [System.Collections.Generic.List[string]]::new()
foreach ($p in $trash.Keys) {
    $abs = Join-Path $root ($p -replace '/', '\')
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
    $localMod = (Get-Item -LiteralPath $abs).LastWriteTime
    $localSec = [datetime]::new($localMod.Year, $localMod.Month, $localMod.Day, $localMod.Hour, $localMod.Minute, $localMod.Second)
    foreach ($t in $trash[$p]) {
        if ([math]::Abs(($localSec - $t).TotalSeconds) -le 1) { $candidates.Add($p); break }
    }
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
