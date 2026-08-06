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

    # Drive Changes API poll interval of the cloud watcher (seconds)
    PollSeconds   = 60

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
