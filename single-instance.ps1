# Single-instance guard for the watchers and the nightly bisync. Dot-source
# after config.ps1, as early as possible:
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
#
# The nightly bisync takes the same kind of lock ("bisync"), and the watchers
# ask Test-BisyncRunning before every flush. Its lock used to be a PID file
# alone: a run that was killed left the file behind, and "is that PID alive"
# is answered with yes for whichever process Windows gave the number to next
# - the watchers would then have stood still until the next reboot.

# Local\ = this logon session; the scheduled tasks (all "interactive"), the
# watchdog and a manual start from a terminal all run there
function Get-InstanceMutexName([string]$name) { "Local\DriveSync-$name" }

function Enter-SingleInstance([string]$name, [string]$lockFile) {
    $mutex = [System.Threading.Mutex]::new($false, (Get-InstanceMutexName $name))
    $owned = $false
    # an owner that died without releasing leaves the mutex abandoned - the
    # wait then succeeds with this exception, and we own it
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { $mutex.Dispose(); return $null }
    Set-Content $lockFile $PID
    return $mutex
}

# Leave the lock before the process ends - for a script that may be run from
# an interactive session, which lives on after it. Closing the handle is what
# counts: Windows destroys a mutex with its last handle.
function Exit-SingleInstance($mutex, [string]$lockFile) {
    if (-not $mutex) { return }
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
    Remove-Item -LiteralPath $lockFile -Force -Confirm:$false -ErrorAction SilentlyContinue
}

# True while some process holds the instance lock of that name. The mutex
# exists exactly as long as a process has it open, and only its owner keeps it
# open - so existence is the answer, and asking never competes for the lock.
function Test-InstanceRunning([string]$name) {
    $mutex = $null
    try { return [System.Threading.Mutex]::TryOpenExisting((Get-InstanceMutexName $name), [ref]$mutex) }
    catch [System.UnauthorizedAccessException] { return $true }   # there, but not ours to open
    catch { return $false }
    finally { if ($mutex) { $mutex.Dispose() } }
}

function Test-BisyncRunning { Test-InstanceRunning "bisync" }
