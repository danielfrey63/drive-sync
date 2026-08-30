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
$info = if ($task) { $task | Get-ScheduledTaskInfo }
$proc = Get-Process restic -ErrorAction SilentlyContinue
Write-Host ("Task:     {0}   last result 0x{1:X}   next run {2}" -f `
    ($task ? $task.State : "NOT REGISTERED"), ($info ? $info.LastTaskResult : 0), ($info ? $info.NextRunTime : "-"))
Write-Host ("Process:  {0}" -f ($proc ? "running (PID $($proc.Id), since $($proc.StartTime.ToString('HH:mm')), $([int]($proc.WorkingSet64/1MB)) MB)" : "not running"))

# log
$log = Join-Path $DriveSyncConfig.StateDir ("logs\backup-{0}.log" -f (Get-Date -Format "yyyyMMdd"))
if (Test-Path $log) {
    Get-Content $log | Select-String -Pattern "^\d{4}-\d{2}-\d{2}" | Select-Object -Last 4 | ForEach-Object { Write-Host "Log:      $($_.Line)" }
} else {
    Write-Host "Log:      no log for today"
}

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
Write-Host ("Repo:     ~{0:N1} GB in ~{1:N0} packs{2}" -f ($bytes / 1GB), ($packs.Count * $step), ($step -gt 1 ? " (extrapolated from $Sample of 256 dirs)" : ""))

# rate since the previous invocation
$cursor = Join-Path $DriveSyncConfig.StateDir "backup-status-cursor.txt"
if (Test-Path $cursor) {
    $prev = Get-Content $cursor -Raw | ConvertFrom-Json
    $dt = ((Get-Date) - [datetime]$prev.time).TotalSeconds
    if ($dt -gt 60) {
        $rate = ($bytes - $prev.bytes) / $dt
        Write-Host ("Rate:     {0:N1} MB/s since {1} ({2:N1} GB/day)" -f ($rate / 1MB), ([datetime]$prev.time).ToString("HH:mm"), ($rate * 86400 / 1GB))
    }
}
@{ time = (Get-Date).ToString("o"); bytes = $bytes } | ConvertTo-Json -Compress | Set-Content $cursor
