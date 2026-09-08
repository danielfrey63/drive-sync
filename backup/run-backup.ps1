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
# Pipeline: backup (VSS snapshot when elevated) -> tripwire -> forget
# (retention) -> prune (Sundays) -> check (Sundays, 2 % of the data read back).
# Idempotent: every step is safe to repeat; an interrupted upload keeps its
# packs and the next run continues from the repository index.
#
# The tripwire judges each fresh snapshot against its own chain and latches on
# an alarm: backups keep running (a snapshot too many costs nothing), but
# forget/prune/check stay disabled until "-ClearAnomaly" is run by hand, so no
# automation ages out the last clean snapshots while nobody is watching.

param(
    [switch]$NoVss,          # skip the VSS snapshot (implicit when not elevated)
    [switch]$DryRun,         # scan only, upload nothing
    [switch]$SkipMaintenance,# backup only, no forget/prune/check
    [switch]$ClearAnomaly    # release the tripwire latch and exit
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\config.ps1")
. (Join-Path $PSScriptRoot "backup-config.ps1")
. (Join-Path $PSScriptRoot "backup-metrics.ps1")

$cfg = $BackupConfig
$runStart = Get-Date
$logDir = Join-Path $DriveSyncConfig.StateDir "logs"
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("backup-{0}.log" -f (Get-Date -Format "yyyyMMdd"))
$lock = Join-Path $DriveSyncConfig.StateDir "backup.lock"
$latchFile = Join-Path $DriveSyncConfig.StateDir "backup-anomaly.json"

function Log($msg) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $log -Value $line
}

# The scheduled run has no window; outcome and failures go to the Action Center
# as toasts (ai-toolbox/tools/notify, sibling checkout). A missing toolbox only
# silences the toasts, the backup does not depend on it.
$toastHelper = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "ai-toolbox\tools\notify\toast.ps1"
if (Test-Path $toastHelper) { . $toastHelper }
function Notify([string]$title, [string]$body) {
    if (-not (Get-Command Show-Toast -ErrorAction SilentlyContinue)) { return }
    try { Show-Toast -Title $title -Body $body -AppId "DriveSync.Backup" -AppName "DriveSync Backup" }
    catch { Log "notification failed: $($_.Exception.Message)" }
}
function Fail([string]$msg, [int]$code, [string]$title = "Backup FAILED") {
    Log $msg
    Notify $title "$msg`nLog: $log"
    exit $code
}

# releasing the latch is deliberately a separate, explicit invocation: it is
# the one place where a human confirms the anomaly was understood
if ($ClearAnomaly) {
    $held = Get-BackupAnomalyLatch $latchFile
    if ($held) {
        Remove-Item $latchFile -ErrorAction SilentlyContinue
        Log "anomaly latch released (was set $($held.time))"
    } else {
        Log "no anomaly latch set"
    }
    exit 0
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

    # crashes of earlier runs leave stale locks behind; plain unlock removes
    # only those, never the lock of a live process
    & $cfg.Restic unlock @common 2>&1 | Tee-Object -FilePath $log -Append | Out-Null

    # one restic invocation PER source: each tree gets its own snapshot chain
    # and thus its own parent. Until a tree's first snapshot exists, every
    # restart re-reads the whole tree (index dedup prevents re-upload, but the
    # chunking takes hours) - completing the small tree first ends that phase
    # for it, instead of one giant snapshot that never completes.
    $out = @(); $rc = 0
    foreach ($source in $cfg.Sources) {
        $args = @("backup", $source
            "--exclude-file", $cfg.ExcludeFile
            "--exclude-caches"
            "--tag", "auto"
            "--compression", "auto"
            "--read-concurrency", $cfg.ReadConcurrency
        )
        if ($useVss) { $args += "--use-fs-snapshot" }
        if ($DryRun) { $args += "--dry-run"; $args += "--verbose" }

        Log "backup start [$source] (vss=$useVss dryrun=$DryRun) -> $($cfg.Repository)"
        for ($attempt = 1; $attempt -le $cfg.BackupRetries; $attempt++) {
            $srcOut = & $cfg.Restic @args @common 2>&1 | Tee-Object -FilePath $log -Append
            $rc = $LASTEXITCODE
            if ($rc -in 0, 3) { break }
            Log "backup [$source] attempt $attempt/$($cfg.BackupRetries) failed rc=$rc, retrying in $($cfg.RetryWaitSec)s"
            Start-Sleep -Seconds $cfg.RetryWaitSec
            & $cfg.Restic unlock @common 2>&1 | Out-Null
        }
        $out += $srcOut
        if ($rc -notin 0, 3) { break }   # skip remaining sources, keep rc for the exit path
    }
    $out | Select-Object -Last 8 | Out-Host

    # per-file errors flood the log (34k iCloud placeholders on the first
    # dry-run); summarise them by cause so the tail of the log is readable
    $errors = @($out | Where-Object { "$_" -match '^(error|scan):' } | ForEach-Object {
        switch -Regex ("$_") {
            'Clouddateianbieter|cloud file provider' { 'cloud placeholder (dehydrated file)' }
            'Zugriff verweigert|Access is denied'     { 'access denied (run elevated)' }
            'anderen Prozess|being used by another'   { 'locked file (VSS missing or skipped)' }
            'Virus|nicht erfolgreich abgeschlossen'   { 'blocked by Defender' }
            default                                   { 'other' }
        }
    })
    if ($errors.Count -gt 0) {
        Log "backup error summary ($($errors.Count) files):"
        $errors | Group-Object | Sort-Object Count -Descending | ForEach-Object { Log ("  {0,6}  {1}" -f $_.Count, $_.Name) }
    }
    # 3 = some source files could not be read; the snapshot is still complete for the rest
    if ($rc -eq 3) { Log "backup finished with unreadable files (rc=3)" }
    elseif ($rc -ne 0) { Fail "backup FAILED rc=$rc" $rc }
    else { Log "backup done" }

    # restic's own summary lines (one "Added"/"processed" pair per source) make the toast body
    $summary = @($out | Where-Object { "$_" -match '^(Added to the repository|processed \d)' } | ForEach-Object { "$_".Trim() })
    if ($errors.Count -gt 0) { $summary += "$($errors.Count) unreadable file(s), see log" }

    # tripwire: every snapshot this run created is judged against its own chain.
    # A failure here must never fail the backup - the data is already on the
    # box; only the verdict would be missing.
    $latch = Get-BackupAnomalyLatch $latchFile
    $notes = @()
    if (-not $DryRun) {
        $reasons = @()
        try {
            $all = Get-BackupSnapshotStats -Config $cfg
            foreach ($source in $cfg.Sources) {
                $fresh = @($all | Where-Object { $_.Path -eq $source -and $_.Time -ge $runStart } | Sort-Object Time)
                foreach ($snap in $fresh) {
                    $history = @($all | Where-Object { $_.Time -lt $snap.Time })
                    $verdict = Test-BackupAnomaly -Config $cfg -Stat $snap -History $history
                    $shrinkText = "n/a"
                    if ($null -ne $snap.ShrinkRate) { $shrinkText = "{0:P3}" -f $snap.ShrinkRate }
                    Log ("tripwire [{0}] {1}: changed {2:P3}, new {3:P3}, shrink {4}, ratio {5:N2} ({6:N0} files)" -f
                        $source, $verdict.Level, $snap.ChangedRate, $snap.NewRate, $shrinkText, $snap.Ratio, $snap.Total)
                    $reasons += $verdict.Reasons
                    $notes   += $verdict.Notes
                }
            }
        } catch { Log "tripwire skipped: $($_.Exception.Message)" }

        foreach ($n in $notes) { Log "tripwire note: $n" }
        if ($reasons.Count -gt 0) {
            foreach ($r in $reasons) { Log "TRIPWIRE ALARM: $r" }
            Set-BackupAnomalyLatch -Path $latchFile -Reasons $reasons
            $latch = Get-BackupAnomalyLatch $latchFile
        }
    }

    if (-not $DryRun) {
        $title = "Backup done"
        if ($rc -eq 3) { $title = "Backup done (unreadable files skipped)" }
        $summary += $notes
        if ($latch) {
            $title = "!! BACKUP ANOMALY - maintenance halted"
            $summary = @($latch.reasons) + @(
                "Latched $($latch.time)."
                "forget/prune/check stay off until reviewed."
                "Release: run-backup.ps1 -ClearAnomaly"
                "Log: $log"
            )
        }
        Notify $title ($summary -join "`n")
    }

    if ($DryRun -or $SkipMaintenance) { exit 0 }
    if ($latch) {
        Log "maintenance skipped: anomaly latch set $($latch.time) - release with: run-backup.ps1 -ClearAnomaly"
        exit 0
    }

    # group-by host,paths: the C: chain and the D: chain age independently -
    # grouped by host alone, C and D snapshots of the same day would compete
    # for the single keep-daily slot
    Log "forget: keep all within $($cfg.KeepWithin), then $($cfg.KeepDaily) daily / $($cfg.KeepMonthly) monthly"
    & $cfg.Restic forget --keep-within $cfg.KeepWithin --keep-daily $cfg.KeepDaily `
        --keep-monthly $cfg.KeepMonthly --group-by host,paths @common 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail "forget FAILED rc=$LASTEXITCODE" $LASTEXITCODE }

    # maintenance once per maintenance day, not on every slot of it: a stamp
    # file carries the date of the last run, so the other three Sunday slots
    # skip prune and check instead of repeating them
    $stamp = Join-Path $DriveSyncConfig.StateDir "backup-maintenance.txt"
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $lastMaintenance = if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { "" }
    if ((Get-Date).DayOfWeek -eq $cfg.MaintenanceDay -and $lastMaintenance -ne $today) {
        Set-Content -Path $stamp -Value $today
        Log "prune"
        & $cfg.Restic prune --max-unused 5% @common 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail "prune FAILED rc=$LASTEXITCODE" $LASTEXITCODE "Maintenance FAILED" }

        # $($...) is required: "--flag=$cfg.CheckSubset" would expand $cfg alone
        # and append the literal ".CheckSubset" (silently broke check until 06.09.2026)
        Log "check --read-data-subset=$($cfg.CheckSubset)"
        & $cfg.Restic check "--read-data-subset=$($cfg.CheckSubset)" @common 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail "check FAILED rc=$LASTEXITCODE" $LASTEXITCODE "Maintenance FAILED" }
    }
    Log "all done"
}
finally {
    Remove-Item $lock -ErrorAction SilentlyContinue
}
