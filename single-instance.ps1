# Single-instance guard for the watchers. Dot-source after config.ps1, as early
# as possible:
#   . (Join-Path $PSScriptRoot "single-instance.ps1")
#   $script:instance = Enter-SingleInstance "watch-drive" $lockFile
#   if (-not $script:instance) { exit 0 }
#
# Why a mutex and not just the lock file: the lock file was written only after
# ~18 s of start-up (rclone config resolution, capability probes). On
# 2026-11-05 the logon task started both watchers at 20:19:27, the watchdog
# read the lock files at 20:19:34 - still holding the PIDs from before the
# reboot - and started a second pair. Two upload watchers then copied every
# batch twice, each creating the new folders itself, and Drive kept both:
# duplicate folders and files under one path, until a bisync rename hit one
# and aborted ("object not found", resync required) on 06. and 07.11.
#
# A named mutex is granted atomically to exactly one process and released by
# Windows when that process ends, however it ends. The lock file stays: the
# watchdog and restart-watchers.ps1 read the PID from it, and it is now written
# the moment the mutex is held.

function Enter-SingleInstance([string]$name, [string]$lockFile) {
    # Local\ = this logon session; the logon task, the watchdog and a manual
    # restart all start the watchers there
    $mutex = [System.Threading.Mutex]::new($false, "Local\DriveSync-$name")
    $owned = $false
    # an owner that died without releasing leaves the mutex abandoned - the
    # wait then succeeds with this exception, and we own it
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { $mutex.Dispose(); return $null }
    Set-Content $lockFile $PID
    return $mutex
}
