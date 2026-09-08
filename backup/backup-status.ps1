# Status of the restic backup: task state, running process, log summary and
# repository size on the box. restic prints no progress lines when stdout is
# not a terminal, so during the multi-day initial run the log is silent
# between the VSS lines and the final summary - this script measures instead:
# it sums the pack files on the box over SFTP and derives the upload rate
# from the previous invocation (cursor in the state dir).
#
# -Sample <n>  list only n of the 256 data subdirectories and extrapolate
#              (default 32, ~5 s; -Sample 256 is exact, ~1 min)
# -Audit       replay the ransomware tripwire over the whole snapshot history
#              and exit. Use this after changing a threshold: a calibrated
#              detector is silent on every snapshot that has already happened.

param(
    [int]$Sample = 32,
    [switch]$Audit
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\config.ps1")
. (Join-Path $PSScriptRoot "backup-config.ps1")
. (Join-Path $PSScriptRoot "backup-metrics.ps1")

if ($Audit) {
    $all = Get-BackupSnapshotStats -Config $BackupConfig
    if ($all.Count -eq 0) { Write-Host "no snapshots with a summary found"; exit 1 }
    Write-Host ("{0,-14} {1,-16} {2,9} {3,9} {4,9} {5,7} {6,7}  {7}" -f "TIME", "CHAIN", "CHANGED", "NEW", "SHRINK", "RATIO", "UP GB", "VERDICT")
    $tripped = 0
    foreach ($s in $all) {
        $verdict = Test-BackupAnomaly -Config $BackupConfig -Stat $s -History @($all | Where-Object { $_.Time -lt $s.Time })
        $shrink = "n/a"
        if ($null -ne $s.ShrinkRate) { $shrink = "{0:P2}" -f $s.ShrinkRate }
        $mark = $verdict.Level
        if ($s.IsInitial) { $mark = "exempt (initial)" }
        if ($verdict.Level -eq "alarm") { $tripped++ }
        Write-Host ("{0,-14} {1,-16} {2,9:P2} {3,9:P2} {4,9} {5,7:N2} {6,7:N1}  {7}" -f `
            $s.Time.ToString("dd.MM. HH:mm"), $s.Path, $s.ChangedRate, $s.NewRate, $shrink, $s.Ratio, ($s.Packed / 1GB), $mark)
        foreach ($r in $verdict.Reasons) { Write-Host "                 -> $r" }
        foreach ($n in $verdict.Notes)   { Write-Host "                 -> note: $n" }
    }
    Write-Host ""
    Write-Host ("Audit: {0} of {1} snapshots would raise an alarm with the current thresholds." -f $tripped, $all.Count)
    $limitMaps = [ordered]@{
        "changed" = $BackupConfig.AnomalyChangedRate
        "new"     = $BackupConfig.AnomalyNewRate
        "shrink"  = $BackupConfig.AnomalyShrinkRate
        ("{0}h changed" -f $BackupConfig.AnomalyWindowHours) = $BackupConfig.AnomalyWindowChangedRate
    }
    foreach ($name in $limitMaps.Keys) {
        foreach ($k in $limitMaps[$name].Keys) {
            Write-Host ("  {0,-12} limit {1,-18} {2:P0}" -f $name, $k, $limitMaps[$name][$k])
        }
    }
    exit 0
}

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

# tripwire latch: while it is set, forget/prune/check are disabled
$latch = Get-BackupAnomalyLatch (Join-Path $DriveSyncConfig.StateDir "backup-anomaly.json")
if ($latch) {
    Write-Host "Tripwire: LATCHED since $($latch.time) - maintenance is halted"
    foreach ($r in @($latch.reasons)) { Write-Host "Tripwire:   $r" }
    Write-Host "Tripwire: release with .\backup\run-backup.ps1 -ClearAnomaly"
} else {
    Write-Host "Tripwire: armed, no anomaly latched"
}

# per-snapshot deltas: restic stores the run summary in the snapshot itself;
# data_added_packed is what actually went over the wire (dedup + compression)
try {
    foreach ($s in (Get-BackupSnapshotStats -Config $BackupConfig | Sort-Object Time | Select-Object -Last 8)) {
        Write-Host ("Snap:     {0}  {1}  {2}  up {3:N2} GB  new {4}  chg {5}  {6} min" -f `
            $s.ShortId, $s.Time.ToString("dd.MM. HH:mm"), $s.Chain, ($s.Packed / 1GB), $s.New, $s.Changed, $s.Minutes)
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
