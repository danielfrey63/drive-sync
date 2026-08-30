# Daily restic backup of C: (user data, no OS/program files) and
# "D:\Meine Ablage" to the Hetzner Storage Box, over SSH port 23.
#
# Why port 23 and a pinned ssh binary: port 22 is ProFTPD mod_sftp without
# any post-quantum key exchange, port 23 is OpenSSH offering
# sntrup761x25519 (verified 2026-08-30). The "storagebox" host alias in
# ~/.ssh/config enforces that KEX. The ssh in PATH is the MSYS build from
# git-with-openssh, which cannot talk to the Windows ssh-agent; the
# Microsoft build in scoop/apps/openssh can, so restic is told to use it.
#
# Pipeline: backup (VSS snapshot when elevated) -> forget (retention) ->
# prune (Sundays) -> check (Sundays, 2 % of the data read back).
# Idempotent: every step is safe to repeat; an interrupted upload keeps its
# packs and the next run continues from the repository index.

param(
    [switch]$NoVss,          # skip the VSS snapshot (implicit when not elevated)
    [switch]$DryRun,         # scan only, upload nothing
    [switch]$SkipMaintenance # backup only, no forget/prune/check
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\config.ps1")
. (Join-Path $PSScriptRoot "backup-config.ps1")

$cfg = $BackupConfig
$logDir = Join-Path $DriveSyncConfig.StateDir "logs"
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("backup-{0}.log" -f (Get-Date -Format "yyyyMMdd"))
$lock = Join-Path $DriveSyncConfig.StateDir "backup.lock"

function Log($msg) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $log -Value $line
}

# single instance: a stale lock (owner PID gone) is taken over
if (Test-Path $lock) {
    $ownerPid = Get-Content $lock -ErrorAction SilentlyContinue
    if ($ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
        Log "another backup is running (PID $ownerPid), exiting"
        exit 0
    }
    Log "stale lock from PID $ownerPid, taking over"
}
Set-Content -Path $lock -Value $PID
try {
    $env:RESTIC_REPOSITORY    = $cfg.Repository
    $env:RESTIC_PASSWORD_FILE = $cfg.PasswordFile
    $env:RESTIC_CACHE_DIR     = $cfg.CacheDir
    New-Item -ItemType Directory -Force $cfg.CacheDir | Out-Null

    $common = @("-o", "sftp.command=$($cfg.SshCommand)", "--cleanup-cache")

    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $useVss = -not $NoVss -and $elevated
    if (-not $NoVss -and -not $elevated) { Log "not elevated: VSS disabled, locked files will be skipped" }

    $args = @("backup") + $cfg.Sources + @(
        "--exclude-file", $cfg.ExcludeFile
        "--exclude-caches"
        "--tag", "daily"
        "--compression", "auto"
    )
    if ($useVss) { $args += "--use-fs-snapshot" }
    if ($DryRun) { $args += "--dry-run"; $args += "--verbose" }

    Log "backup start (vss=$useVss dryrun=$DryRun) -> $($cfg.Repository)"
    & $cfg.Restic @args @common 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
    $rc = $LASTEXITCODE
    # 3 = some source files could not be read; the snapshot is still complete for the rest
    if ($rc -eq 3) { Log "backup finished with unreadable files (rc=3), see log" }
    elseif ($rc -ne 0) { Log "backup FAILED rc=$rc"; exit $rc }
    else { Log "backup done" }

    if ($DryRun -or $SkipMaintenance) { exit 0 }

    Log "forget: keep $($cfg.KeepDaily)d/$($cfg.KeepWeekly)w/$($cfg.KeepMonthly)m"
    & $cfg.Restic forget --keep-daily $cfg.KeepDaily --keep-weekly $cfg.KeepWeekly `
        --keep-monthly $cfg.KeepMonthly --group-by host @common 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
    if ($LASTEXITCODE -ne 0) { Log "forget FAILED rc=$LASTEXITCODE"; exit $LASTEXITCODE }

    if ((Get-Date).DayOfWeek -eq $cfg.MaintenanceDay) {
        Log "prune"
        & $cfg.Restic prune --max-unused 5% @common 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
        if ($LASTEXITCODE -ne 0) { Log "prune FAILED rc=$LASTEXITCODE"; exit $LASTEXITCODE }

        Log "check --read-data-subset=$($cfg.CheckSubset)"
        & $cfg.Restic check --read-data-subset=$cfg.CheckSubset @common 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
        if ($LASTEXITCODE -ne 0) { Log "check FAILED rc=$LASTEXITCODE"; exit $LASTEXITCODE }
    }
    Log "all done"
}
finally {
    Remove-Item $lock -ErrorAction SilentlyContinue
}
