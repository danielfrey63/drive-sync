# Stage-B watcher: near-realtime UPLOAD of local changes in "D:\Meine Ablage"
# to gdrive:, complementing the hourly bisync (which reconciles deletions,
# renames leftovers and cloud-side changes).
#
# Design:
#  - FileSystemWatcher (recursive) queues Created/Changed/Renamed events;
#    Deleted events are deliberately ignored (never destructive).
#  - Exclude rules are DERIVED FROM filters.txt at startup (dir names,
#    extensions, literal names, ~$ prefix) - single source of truth.
#  - Batches are debounced (15s quiet / 60s max age) and uploaded via
#    "rclone copy --files-from-raw --no-traverse" - no tree listing at all.
#  - While the bisync wrapper's lock is active, flushing is deferred.
#  - Watcher buffer overflows are only logged: the hourly bisync catches up.
#
# Meant to run permanently via the "DriveSync watcher" logon task
# (install-watcher-task.ps1). Single instance enforced by a PID lock.

$ErrorActionPreference = "Stop"
$root = "D:\Meine Ablage"
$remote = "gdrive:"
$filters = Join-Path $PSScriptRoot "filters.txt"
$stateDir = Join-Path $env:LOCALAPPDATA "drive-sync"
$logFile = Join-Path $stateDir "watcher.log"
$statusFile = Join-Path $stateDir "watcher-status.json"
$lockFile = Join-Path $stateDir "watcher.lock"
$bisyncLock = Join-Path $stateDir "sync.lock"
New-Item -ItemType Directory -Force $stateDir | Out-Null

function Write-Log([string]$msg) {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 10MB) {
        Move-Item $logFile "$logFile.1" -Force
    }
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
}

# --- single instance --------------------------------------------------------
if (Test-Path $lockFile) {
    $other = Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($other -and (Get-Process -Id $other -ErrorAction SilentlyContinue)) {
        Write-Log "another watcher (PID $other) is active - exiting"
        exit 0
    }
}
Set-Content $lockFile $PID

# --- derive exclude sets from filters.txt -----------------------------------
$exDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$exExts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$exNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$exPrefixes = @()
foreach ($line in Get-Content $filters) {
    if ($line -notmatch '^\s*-\s+(.+)$') { continue }
    $pat = $Matches[1].Trim()
    if ($pat -match '^(.+)/\*\*$') { [void]$exDirs.Add($Matches[1]) }
    elseif ($pat -match '^\*(\.[A-Za-z0-9]+)$') { [void]$exExts.Add($Matches[1]) }
    elseif ($pat.EndsWith('*')) { $exPrefixes += $pat.TrimEnd('*') }
    elseif ($pat -notmatch '[\*\[\]]') { [void]$exNames.Add($pat) }
}
Write-Log "started (PID $PID): $($exDirs.Count) dir rules, $($exExts.Count) ext rules, $($exNames.Count) name rules"

function Test-Excluded([string]$relPath) {
    $segs = $relPath -split '\\'
    for ($i = 0; $i -lt $segs.Count - 1; $i++) { if ($exDirs.Contains($segs[$i])) { return $true } }
    $base = $segs[-1]
    if ($exNames.Contains($base)) { return $true }
    $ext = [System.IO.Path]::GetExtension($base)
    if ($ext -and $exExts.Contains($ext)) { return $true }
    foreach ($p in $exPrefixes) { if ($base.StartsWith($p)) { return $true } }
    return $false
}

# --- watcher + event queue --------------------------------------------------
# Events are drained from the session event queue via Wait-Event/Get-Event:
# -Action blocks would not run reliably while the main loop sleeps.
$fsw = [System.IO.FileSystemWatcher]::new($root)
$fsw.IncludeSubdirectories = $true
$fsw.InternalBufferSize = 65536
$fsw.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::DirectoryName -bor [IO.NotifyFilters]::LastWrite

Register-ObjectEvent $fsw Created -SourceIdentifier fswCreated | Out-Null
Register-ObjectEvent $fsw Changed -SourceIdentifier fswChanged | Out-Null
Register-ObjectEvent $fsw Renamed -SourceIdentifier fswRenamed | Out-Null
Register-ObjectEvent $fsw Error -SourceIdentifier fswError | Out-Null
$fsw.EnableRaisingEvents = $true

# --- main loop: debounce and flush ------------------------------------------
$pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$lastEvent = $null
$oldestPending = $null
$uploadedTotal = 0

try {
    while ($true) {
        $null = Wait-Event -Timeout 3
        $drained = 0
        foreach ($evt in @(Get-Event)) {
            $drained++
            $path = if ($evt.SourceIdentifier -eq "fswError") { "<OVERFLOW>" } else { $evt.SourceEventArgs.FullPath }
            Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
            $lastEvent = Get-Date
            if ($path -eq "<OVERFLOW>") { Write-Log "WARN event buffer overflow - hourly bisync will reconcile"; continue }
            if (-not $path.StartsWith($root)) { continue }
            $rel = $path.Substring($root.Length + 1)
            if (Test-Excluded $rel) { continue }
            if (Test-Path -LiteralPath $path -PathType Container) {
                # new/renamed directory: enqueue its files (move-in raises only one event)
                Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    $r = $_.FullName.Substring($root.Length + 1)
                    if (-not (Test-Excluded $r)) { [void]$pending.Add($r) }
                }
            }
            elseif (Test-Path -LiteralPath $path -PathType Leaf) { [void]$pending.Add($rel) }
            if ($null -eq $oldestPending) { $oldestPending = Get-Date }
        }
        if ($drained -gt 0) { Write-Log "events: $drained drained, $($pending.Count) pending" }

        if ($pending.Count -eq 0) { $oldestPending = $null; continue }
        $quiet = $lastEvent -and ((Get-Date) - $lastEvent).TotalSeconds -ge 15
        $overdue = $oldestPending -and ((Get-Date) - $oldestPending).TotalSeconds -ge 60
        if (-not ($quiet -or $overdue)) { continue }

        # defer while the hourly bisync holds its lock
        if (Test-Path $bisyncLock) {
            $lockPid = Get-Content $bisyncLock -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) { continue }
        }

        $batch = @($pending | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf })
        $pending.Clear()
        $oldestPending = $null
        if ($batch.Count -eq 0) { continue }

        $batchFile = Join-Path $stateDir "watcher-batch.txt"
        Set-Content -Path $batchFile -Value $batch -Encoding UTF8
        & rclone copy $root $remote --files-from-raw $batchFile --no-traverse `
            --modify-window 1s --drive-pacer-min-sleep 10ms --drive-pacer-burst 200 `
            --transfers 4 --log-level INFO --log-file $logFile 2>$null
        $exit = $LASTEXITCODE
        $uploadedTotal += $batch.Count
        Write-Log "flush: $($batch.Count) file(s), exit=$exit"
        [ordered]@{
            pid = $PID; lastFlush = (Get-Date).ToString("s"); lastExit = $exit
            lastBatch = $batch.Count; uploadedTotal = $uploadedTotal
        } | ConvertTo-Json | Set-Content $statusFile
    }
}
finally {
    $fsw.EnableRaisingEvents = $false
    "fswCreated", "fswChanged", "fswRenamed", "fswError" | ForEach-Object { Unregister-Event -SourceIdentifier $_ -ErrorAction SilentlyContinue }
    $fsw.Dispose()
    Remove-Item $lockFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "stopped (PID $PID)"
}
