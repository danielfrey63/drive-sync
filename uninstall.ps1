# Removes the DriveSync scheduled tasks and stops the running watchers.
# Idempotent: safe to re-run, missing pieces are skipped silently.
#
#   pwsh -File uninstall.ps1               # stop watchers, remove the 4 tasks
#   pwsh -File uninstall.ps1 -RemoveState  # ... and delete %LOCALAPPDATA%\drive-sync
#                                          # (logs, page token, ledger, custom rclone build)
#
# Never touched: "D:\Meine Ablage" (your data), the rclone config/remote
# (remove with "rclone config delete gdrive") and rclone itself.

param(
    [switch]$RemoveState
)

$stateDir = Join-Path $env:LOCALAPPDATA "drive-sync"
$taskNames = @("DriveSync watcher", "DriveSync cloud watcher", "DriveSync watchdog", "DriveSync rclone bisync")

# refuse to pull the rug from under a running bisync
$bisyncPid = Get-Content (Join-Path $stateDir "sync.lock") -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bisyncPid -and (Get-Process -Id $bisyncPid -ErrorAction SilentlyContinue)) {
    Write-Warning "A bisync run (PID $bisyncPid) is active - let it finish or stop it first."
    exit 1
}

# stop the watcher processes via their PID locks
foreach ($lock in @("watcher.lock", "cloud-watcher.lock")) {
    $pid_ = Get-Content (Join-Path $stateDir $lock) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pid_ -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $pid_ -Force -Confirm:$false
        Write-Host "Stopped watcher process (PID $pid_, $lock)."
    }
    Remove-Item (Join-Path $stateDir $lock) -Force -Confirm:$false -ErrorAction SilentlyContinue
}

foreach ($name in $taskNames) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "Removed task '$name'."
    }
}

if ($RemoveState -and (Test-Path $stateDir)) {
    Remove-Item $stateDir -Recurse -Force -Confirm:$false
    Write-Host "Removed state directory $stateDir."
}
elseif (Test-Path $stateDir) {
    Write-Host "State directory kept: $stateDir (delete with -RemoveState)."
}

Write-Host "Done. Data in 'D:\Meine Ablage' and the rclone config were not touched."
