# Status of the restic backup: task state, running process, log summary and
# repository size on the box. restic prints no progress lines when stdout is
# not a terminal, so during the multi-day initial run the log is silent
# between the VSS lines and the final summary - this script measures instead:
# it sums the pack files on the box over SFTP and derives the upload rate
# from the previous invocation (cursor in the state dir).
#
# -Sample <n>  list only n of the 256 data subdirectories and extrapolate
#              (default 32, ~5 s; -Sample 256 is exact, ~1 min)

param(
    [int]$Sample = 32
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\config.ps1")
. (Join-Path $PSScriptRoot "backup-config.ps1")

# task + process
$task = Get-ScheduledTask -TaskName "DriveSync restic backup" -ErrorAction SilentlyContinue
if ($task) {
    $info = $task | Get-ScheduledTaskInfo
    Write-Host ("Task:     {0}   last result 0x{1:X}   next run {2}" -f $task.State, $info.LastTaskResult, $info.NextRunTime)
} else {
    Write-Host "Task:     NOT REGISTERED"
}
$proc = Get-Process restic -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host ("Process:  running (PID {0}, since {1}, {2} MB)" -f $proc.Id, $proc.StartTime.ToString('HH:mm'), [int]($proc.WorkingSet64 / 1MB))
} else {
    Write-Host "Process:  not running"
}

# log: the file name is fixed when a run starts, so a run crossing midnight
# keeps writing to yesterday's file - show the newest one, not today's
$log = Get-ChildItem (Join-Path $DriveSyncConfig.StateDir "logs\backup-*.log") -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
if ($log) {
    Write-Host "Log:      $($log.Name), last write $($log.LastWriteTime.ToString('dd.MM. HH:mm'))"
    Get-Content $log.FullName | Select-String -Pattern "^\d{4}-\d{2}-\d{2}" | Select-Object -Last 4 | ForEach-Object { Write-Host "Log:      $($_.Line)" }
} else {
    Write-Host "Log:      no backup log found"
}

# per-snapshot deltas: restic stores the run summary in the snapshot itself;
# data_added_packed is what actually went over the wire (dedup + compression)
try {
    $env:RESTIC_REPOSITORY = $BackupConfig.Repository
    $env:RESTIC_PASSWORD_FILE = $BackupConfig.PasswordFile
    $snaps = & $BackupConfig.Restic snapshots --json -o "sftp.command=$($BackupConfig.SshCommand)" 2>$null | ConvertFrom-Json
    foreach ($s in ($snaps | Select-Object -Last 8)) {
        $line = "Snap:     {0}  {1}  {2}" -f $s.short_id, ([datetime]$s.time).ToString("dd.MM. HH:mm"), ($s.paths -join ",")
        if ($s.summary) {
            $mins = [math]::Round((([datetime]$s.summary.backup_end) - ([datetime]$s.summary.backup_start)).TotalMinutes, 1)
            $line += "  up {0:N2} GB  new {1}  chg {2}  {3} min" -f ($s.summary.data_added_packed / 1GB), $s.summary.files_new, $s.summary.files_changed, $mins
        }
        Write-Host $line
    }
} catch { Write-Host "Snap:     Liste nicht abrufbar ($($_.Exception.Message))" }

# repository size: sample every (256/n)-th data subdir, extrapolate
$Sample = [Math]::Min([Math]::Max($Sample, 1), 256)
$step = [int](256 / $Sample)
$batch = Join-Path $env:TEMP "backup-status-sftp.txt"
$dirs = 0..255 | Where-Object { $_ % $step -eq 0 } | ForEach-Object { "ls -la /home/restic/data/{0:x2}" -f $_ }
($dirs + "quit") | Set-Content $batch -Encoding ascii
$sftp = ($BackupConfig.SshCommand -split ' ')[0] -replace 'ssh\.exe$', 'sftp.exe'
$listing = & $sftp -o BatchMode=yes -b $batch storagebox 2>&1
$packs = @($listing | Where-Object { $_ -match '^-r' })
$bytes = ($packs | ForEach-Object { [double]($_ -split '\s+')[4] } | Measure-Object -Sum).Sum * $step
$note = ""
if ($step -gt 1) { $note = " (extrapolated from $Sample of 256 dirs)" }
Write-Host ("Repo:     ~{0:N1} GB in ~{1:N0} packs{2}" -f ($bytes / 1GB), ($packs.Count * $step), $note)

# rate since the previous invocation - only comparable when both
# measurements used the same sampling step (extrapolation noise otherwise)
$rate = $null
$cursor = Join-Path $DriveSyncConfig.StateDir "backup-status-cursor.txt"
if (Test-Path $cursor) {
    $prev = Get-Content $cursor -Raw | ConvertFrom-Json
    $dt = ((Get-Date) - [datetime]$prev.time).TotalSeconds
    if ($dt -gt 60 -and $prev.step -eq $step) {
        $rate = ($bytes - $prev.bytes) / $dt
        if ($rate * $dt -lt -1GB) {
            Write-Host "Rate:     n/a (sampling noise, repo did not shrink)"
        } else {
            Write-Host ("Rate:     {0:N1} MB/s since {1} ({2:N1} GB/day)" -f ($rate / 1MB), ([datetime]$prev.time).ToString("HH:mm"), ($rate * 86400 / 1GB))
        }
    } elseif ($dt -gt 60) {
        Write-Host "Rate:     n/a (previous measurement used a different -Sample; comparable again on the next call)"
    }
}
@{ time = (Get-Date).ToString("o"); bytes = $bytes; step = $step } | ConvertTo-Json -Compress | Set-Content $cursor

# ETA against the estimated final size (initial upload only; once the repo
# passes the estimate the line disappears - then rely on the snapshot list)
if ($BackupConfig.ExpectedRepoGB) {
    $remainGB = $BackupConfig.ExpectedRepoGB - ($bytes / 1GB)
    if ($remainGB -gt 0) {
        $eta = ""
        if ($rate -and $rate -gt 100KB) {
            $h = [math]::Round($remainGB * 1GB / $rate / 3600, 1)
            $eta = ", ~{0} h at current rate (about {1})" -f $h, (Get-Date).AddHours($h).ToString("dd.MM. HH:mm")
        }
        Write-Host ("ETA:      ~{0:N0} GB of estimated ~{1:N0} GB total remaining{2}" -f $remainGB, $BackupConfig.ExpectedRepoGB, $eta)
    }
}
