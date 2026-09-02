# Operational wrapper for the "D:\Meine Ablage" <-> gdrive: bisync.
# Replaces Google DriveFS (decommissioned 2026-08; see HANDOVER doc).
#
# - Lock file prevents overlapping runs (stale locks from dead processes are
#   cleared automatically).
# - Logs go to %LOCALAPPDATA%\drive-sync\logs, one file per run, last 30 kept.
# - status.json records the last run and the last SUCCESSFUL run for the
#   status check / monitoring.
# - Flag set battle-tested during the 2026-08-04 baseline: dangling shortcuts
#   skipped, gdocs stay cloud-only, 1s modtime window (Drive ms vs NTFS 100ns),
#   tuned pacer for the own client id.
# - Every EmptyDirCleanupDays a successful run also prunes empty folder
#   skeletons on the remote (rclone rmdirs) - bisync itself only tracks files
#   and never sees directories without any.
#
# Usage:
#   pwsh -File sync-drive.ps1              # normal bisync run
#   pwsh -File sync-drive.ps1 -Resync      # re-baseline (after filter changes!)
#   pwsh -File sync-drive.ps1 -DryRun      # show what would happen

param(
    [switch]$Resync,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
$localPath = $DriveSyncConfig.LocalRoot
$remote = $DriveSyncConfig.Remote
$filters = Join-Path $PSScriptRoot "filters.txt"
$stateDir = $DriveSyncConfig.StateDir
$logDir = Join-Path $stateDir "logs"
$lockFile = Join-Path $stateDir "sync.lock"
$statusFile = Join-Path $stateDir "status.json"
New-Item -ItemType Directory -Force $logDir | Out-Null

# --- lock handling ----------------------------------------------------------
if (Test-Path $lockFile) {
    $lockPid = Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
        Write-Host "Another sync run (PID $lockPid) is active - exiting."
        exit 0
    }
    Write-Host "Removing stale lock (PID $lockPid no longer running)."
    Remove-Item $lockFile -Force -Confirm:$false
}
Set-Content -Path $lockFile -Value $PID

try {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logFile = Join-Path $logDir "bisync-$stamp.log"
    $rcArgs = @(
        "bisync", $localPath, $remote
        "--filters-file", $filters
        "--drive-skip-gdocs"
        "--drive-skip-dangling-shortcuts"
        "--modify-window", "1s"
        "--fast-list"
        # keep the newer version under the ORIGINAL name on a two-sided change;
        # only the loser gets a .conflictN suffix. The default (none) renamed
        # BOTH copies, so the original path vanished from every consumer (git
        # status noise, broken references) - seen 2026-08-26 after a missed
        # nightly plus an unflushed watcher backlog diverged 8 files.
        "--conflict-resolve", "newer"
    ) + $DriveSyncConfig.Pacer + @(
        "--checkers", "16"
        "--transfers", "8"
        "--drive-chunk-size", "64M"
        "--log-level", "INFO"
        "--log-file", $logFile
        "--stats", "60s", "--stats-one-line"
    )
    # --max-lock on every run: without it a killed bisync leaves a lock file
    # that never expires and blocks all future runs until removed by hand
    $rcArgs += @("--max-lock", "2h")
    if ($Resync) { $rcArgs += "--resync" }
    else { $rcArgs += @("--resilient", "--recover") }
    if ($DryRun) { $rcArgs += "--dry-run" }

    $start = Get-Date
    & rclone @rcArgs
    $exit = $LASTEXITCODE
    $end = Get-Date

    $status = if (Test-Path $statusFile) { Get-Content $statusFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $run = [ordered]@{
        start = $start.ToString("s"); end = $end.ToString("s")
        minutes = [math]::Round(($end - $start).TotalMinutes, 1)
        exitCode = $exit; resync = [bool]$Resync; dryRun = [bool]$DryRun; log = $logFile
    }
    $newStatus = [ordered]@{ lastRun = $run }
    if ($exit -eq 0 -and -not $DryRun) { $newStatus.lastSuccess = $run }
    elseif ($status.lastSuccess) { $newStatus.lastSuccess = $status.lastSuccess }
    # retry: a concurrent reader (status check while the run ends) makes
    # Set-Content throw and the whole run would end without a status record
    $json = ConvertTo-Json $newStatus -Depth 4
    foreach ($attempt in 1..5) {
        try { Set-Content $statusFile $json -ErrorAction Stop; break }
        catch { if ($attempt -eq 5) { Write-Warning "status.json not written: $_" } else { Start-Sleep -Milliseconds 200 } }
    }

    # --- conflict-loser sweep ----------------------------------------------
    # a .conflictN loser copy inside a git worktree is a trap, not a backup:
    # auto-staging swept 54 of them into the pmo index on 2026-09-02 and
    # blocked every merge there. Move them out of the corpus, keep them
    # findable (see sweep-conflicts.ps1). Never let the sweep fail the run.
    if (-not $DryRun) {
        try { & pwsh -NoProfile -File (Join-Path $PSScriptRoot "sweep-conflicts.ps1") -LogFile $logFile }
        catch { Write-Warning "conflict sweep failed: $_" }
    }

    # --- periodic empty-dir cleanup on the remote --------------------------
    # rmdirs only ever deletes empty directories; a folder holding just an
    # unexportable google doc looks empty in listings but the Drive API
    # refuses to remove it, so a non-zero exit here is expected and non-fatal.
    $cleanupDays = $DriveSyncConfig.EmptyDirCleanupDays
    if ($exit -eq 0 -and -not $DryRun -and -not $Resync -and $cleanupDays -gt 0) {
        $stampFile = Join-Path $stateDir "rmdirs-last.txt"
        $lastCleanup = [datetime]::MinValue
        if (Test-Path $stampFile) {
            try { $lastCleanup = [datetime](Get-Content $stampFile -TotalCount 1) } catch {}
        }
        if (((Get-Date) - $lastCleanup).TotalDays -ge $cleanupDays) {
            Write-Host "Empty-dir cleanup due - running rclone rmdirs (log: $logFile)"
            $rmArgs = @("rmdirs", $remote, "--leave-root", "--fast-list") +
                $DriveSyncConfig.Pacer +
                @("--log-level", "INFO", "--log-file", $logFile)
            foreach ($ex in $DriveSyncConfig.EmptyDirCleanupExcludes) { $rmArgs += @("--exclude", $ex) }
            & rclone @rmArgs
            if ($LASTEXITCODE -ne 0) { Write-Warning "rmdirs exit $LASTEXITCODE (expected when a folder holds only unexportable gdocs) - see $logFile" }
            # stamp regardless of the exit code: the leftovers above would
            # otherwise retrigger the full-tree listing every night
            Set-Content $stampFile (Get-Date -Format "s")
        }
    }

    # log rotation: keep the newest 30
    Get-ChildItem $logDir -Filter "bisync-*.log" | Sort-Object Name -Descending |
        Select-Object -Skip 30 | Remove-Item -Force -Confirm:$false

    if ($exit -ne 0) { Write-Warning "bisync failed with exit code $exit - see $logFile" }
    else { Write-Host "bisync ok ($($run.minutes) min) - log: $logFile" }
    exit $exit
}
finally {
    Remove-Item $lockFile -Force -Confirm:$false -ErrorAction SilentlyContinue
}
