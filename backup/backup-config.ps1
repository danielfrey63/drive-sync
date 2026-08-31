# restic backup configuration. Dot-sourced by run-backup.ps1 and
# install-backup-task.ps1; config.ps1 (StateDir) must be loaded first.
# Machine-specific overrides go into backup-config.local.ps1 (gitignored).

$BackupConfig = @{
    # "storagebox" is a host alias in ~/.ssh/config (port 23, dedicated
    # ed25519 key, KexAlgorithms pinned to sntrup761x25519)
    Repository   = "sftp:storagebox:/home/restic"
    PasswordFile = Join-Path $env:LOCALAPPDATA "restic\storagebox-password.txt"
    CacheDir     = Join-Path $env:LOCALAPPDATA "drive-sync\restic-cache"

    Restic       = Join-Path $env:USERPROFILE "scoop\apps\restic\current\restic.exe"
    # forward slashes: restic splits this string shell-style and eats backslashes
    SshCommand   = "C:/Users/Daniel/scoop/apps/openssh/current/ssh.exe storagebox -s sftp"

    Sources      = @("C:\", "D:\Meine Ablage")
    ExcludeFile  = Join-Path $PSScriptRoot "restic-excludes.txt"

    # Snapshots are cheap (a tree of pointers into deduplicated chunks, only
    # changed data is uploaded), so run often and thin out later: every
    # intermediate state for a week, one per day for a month, then monthly.
    KeepWithin   = "7d"
    KeepDaily    = 30
    KeepMonthly  = 12
    # The sftp backend runs a single ssh; when the connection dies, the whole
    # run aborts (seen twice on 31.08.2026: Intel Wi-Fi driver resets after
    # hours of sustained upload). A retry resumes from the repository index,
    # so re-uploaded work is near zero.
    BackupRetries = 5
    RetryWaitSec  = 60

    # until the first snapshot of a tree exists, every restart re-reads and
    # re-chunks the whole tree; higher read concurrency shortens that phase
    ReadConcurrency = 8

    MaintenanceDay = [DayOfWeek]::Sunday   # prune + check run on this weekday
    CheckSubset  = "2%"                    # share of pack data read back per check

    FirstRunAt   = "05:00"                 # after the 04:00 bisync
    IntervalHours = 6                      # 05:00, 11:00, 17:00, 23:00
}

$__localBackupConfig = Join-Path $PSScriptRoot "backup-config.local.ps1"
if (Test-Path $__localBackupConfig) { . $__localBackupConfig }
