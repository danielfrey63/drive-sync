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

    # Ransomware tripwire (see backup-metrics.ps1 for the reasoning). All
    # thresholds are shares of the chain's own size, because C: and D: differ
    # by a factor of ~500 in file count.
    #
    # Changed and new are judged SEPARATELY, and that separation is the whole
    # point: ransomware REPLACES existing files, a bulk import ADDS files.
    # Lumping them into one rate throws that distinction away and turns a
    # 60'000-photo import into a false alarm (measured, 08.09.2026).
    #
    # Changed rate = changed / files in the snapshot. Measured maxima over the
    # first 36 snapshots: 0.47 % on C:, 0.003 % on D: - the limits leave 6x
    # resp. 300x headroom.
    AnomalyChangedRate = @{
        'C:\'             = 0.03
        'D:\Meine Ablage' = 0.01
        '*'               = 0.03
    }
    # New rate = new / files. Deliberately loose: adding files is what a
    # backup is for. It exists to catch rename-encryption
    # (foo.docx -> foo.docx.locked), which the shrink check sees as well.
    # Measured maxima: 1.33 % on C:, 0.25 % on D:.
    AnomalyNewRate = @{
        'C:\'             = 0.15
        'D:\Meine Ablage' = 0.10
        '*'               = 0.15
    }
    # Slow burn: malware encrypting a little per slot stays under every
    # per-snapshot limit. The changed share summed over a window catches it.
    # This does NOT reintroduce a poisonable baseline - the limit stays
    # static, only the measurement window widens. Measured worst day:
    # 2.5 % on C:, 0.26 % on D:.
    AnomalyWindowHours       = 24
    AnomalyWindowChangedRate = @{
        'C:\'             = 0.08
        'D:\Meine Ablage' = 0.03
        '*'               = 0.08
    }
    # Shrink = share of files the chain lost against its previous snapshot.
    # C: needs a wider limit than D:, and that is not laziness: Windows churns
    # temp and cache trees, one measured slot legitimately lost 3.53 % of the
    # file count. D: is an archive - it grows, it does not shed (max 0.26 %).
    AnomalyShrinkRate = @{
        'C:\'             = 0.10
        'D:\Meine Ablage' = 0.02
        '*'               = 0.05
    }
    AnomalyMinFiles      = 2000   # floor: fewer touched files never trips, whatever the rate
    # corroborating hints in the message, never triggers on their own
    AnomalyVolumeFactor  = 10     # upload vs. median of the chain's last 20 runs
    AnomalyVolumeFloorGB = 5      # below this upload both hints are noise
    AnomalyRatioFloor    = 1.05   # data_added / data_added_packed

    # optional: estimated final repository size in GB; when set, backup-status
    # shows an ETA while the repository is still below it. Used during the
    # initial upload (completed 04.09.2026 at 1.318 TiB stored, 1.10x
    # compression); set again for the next bulk ingestion.
    ExpectedRepoGB = 0

    FirstRunAt   = "05:00"                 # after the 04:00 bisync
    IntervalHours = 6                      # 05:00, 11:00, 17:00, 23:00
}

$__localBackupConfig = Join-Path $PSScriptRoot "backup-config.local.ps1"
if (Test-Path $__localBackupConfig) { . $__localBackupConfig }
