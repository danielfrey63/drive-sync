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

    KeepDaily    = 7
    KeepWeekly   = 4
    KeepMonthly  = 12
    MaintenanceDay = [DayOfWeek]::Sunday   # prune + check run on this weekday
    CheckSubset  = "2%"                    # share of pack data read back per check

    DailyAt      = "05:00"                 # after the 04:00 bisync
}

$__localBackupConfig = Join-Path $PSScriptRoot "backup-config.local.ps1"
if (Test-Path $__localBackupConfig) { . $__localBackupConfig }
