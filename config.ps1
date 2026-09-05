# Central drive-sync configuration. Every script dot-sources this file.
#
# Do NOT edit the defaults for a machine-specific setup: create a
# config.local.ps1 next to this file (gitignored, see config.local.ps1.example)
# and override individual entries there.

$DriveSyncConfig = @{
    # local mirror root and the rclone remote it syncs with
    LocalRoot     = "D:\Meine Ablage"
    RemoteName    = "gdrive"        # must exist in the rclone config ("rclone listremotes")

    # runtime state: logs, locks, cursors, ledger, optional custom rclone build
    StateDir      = Join-Path $env:LOCALAPPDATA "drive-sync"

    # reactive delete cap per flush cycle; larger delete storms are left to
    # the nightly bisync (safety against sync-amplified mass deletions)
    MaxDeletes    = 50

    # record the paths a MaxDeletes storm dropped, so the nightly bisync can be
    # told about them. Without this the cap does not defer a delete, it can
    # invert it: a file created after the last baseline and deleted before the
    # next one is invisible to bisync as a deletion and comes back as "new on
    # the other side" (2026-09-05, eight files). Off = the old behaviour.
    JournalDroppedDeletes = $true

    # Drive Changes API poll interval of the cloud watcher (seconds)
    PollSeconds   = 60

    # daily start time of the reconciliation bisync ("HH:mm"); a full run
    # lists both sides completely, so pick a quiet slot
    BisyncDailyAt = "04:00"

    # days between remote empty-dir cleanups (rclone rmdirs after a successful
    # nightly bisync). bisync only tracks files, so trees whose files were
    # deleted or filtered out leave folder skeletons behind on the cloud
    # (15'634 removed on the first cleanup, 2026-08-16). 0 disables.
    EmptyDirCleanupDays = 30

    # paths the cleanup must not touch: folders whose only content is an
    # unexportable google-native file (e.g. Earth projects, Forms) are
    # invisible in listings and would look empty. The Drive API refuses to
    # delete them anyway, but excluding known cases avoids noisy errors.
    EmptyDirCleanupExcludes = @("/Google Earth/**")

    # logon start delay of both watcher tasks (ISO 8601 duration). The start-up
    # catch-up lists the full corpus (~2 min of metadata I/O); run concurrently
    # with logon it starved App Readiness' packaged COM servers past their 120 s
    # DCOM timeout and the shell waited ~3 min on that group (seen 2026-08-15).
    # The catch-up covers the delayed window, so nothing is lost.
    WatcherLogonDelay = "PT3M"

    # Google Drive pacer tuning - safe with an OWN OAuth client id, too
    # aggressive for the shared default rclone client id
    PacerMinSleep = "10ms"
    PacerBurst    = 200
}

$__localConfig = Join-Path $PSScriptRoot "config.local.ps1"
if (Test-Path $__localConfig) { . $__localConfig }

# derived values used by all scripts
$DriveSyncConfig.Remote = "$($DriveSyncConfig.RemoteName):"
$DriveSyncConfig.Pacer = @(
    "--drive-pacer-min-sleep", $DriveSyncConfig.PacerMinSleep
    "--drive-pacer-burst", "$($DriveSyncConfig.PacerBurst)"
)
