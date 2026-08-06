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
    ) + $DriveSyncConfig.Pacer + @(
        "--checkers", "16"
        "--transfers", "8"
        "--drive-chunk-size", "64M"
        "--log-level", "INFO"
        "--log-file", $logFile
        "--stats", "60s", "--stats-one-line"
    )
    if ($Resync) { $rcArgs += "--resync" }
    else { $rcArgs += @("--resilient", "--recover", "--max-lock", "2h") }
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
    ConvertTo-Json $newStatus -Depth 4 | Set-Content $statusFile

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
