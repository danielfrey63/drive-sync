# Cross-machine bisync lease in the cloud. Dot-source after config.ps1:
#   . (Join-Path $PSScriptRoot "remote-lease.ps1")
#   $lease = Enter-RemoteLease $rcloneExe          # $null = another machine holds one
#   ... Update-RemoteLease $rcloneExe $lease       # renew while the run lasts
#   Exit-RemoteLease $rcloneExe $lease
#   Get-ForeignLease $rcloneExe                    # the other machine's live lease, or $null
#
# Why: the bisync mutex (single-instance.ps1) is Local\ - it holds back the
# watchers of THIS machine only. On 2026-11-26 the P16 resynced for two hours
# while the P15's upload watcher pushed edits to markdown-review and
# sbb/brain; the final listing check found them changed and aborted the run
# ("path1 and path2 are out of sync, run --resync to recover").
#
# One file per machine, lease-<COMPUTERNAME>.json below RemoteLeaseDir. Drive
# allows two objects under one name; two machines writing ONE shared file at
# the same moment could create exactly that. A machine only ever writes its
# own file, and its local mutex keeps that serial. RemoteLeaseDir lies below
# ".cache/", which filters.txt already excludes: the lease never enters a
# listing, and adding a filter rule would have forced a resync.
#
# A lease carries its expiry: a run that is killed, or a laptop that sleeps
# mid-run, stops renewing, and the lease lapses after RemoteLeaseMinutes.
# Times are Unix seconds (UTC): plain numbers survive ConvertFrom-Json, which
# turns ISO strings into local DateTime values. The minutes of slack absorb
# clock skew between machines.
#
# Failure policy: a lease that cannot be read or written never blocks a sync.
# The lease only adds protection; without it the behaviour is the one before.

function Get-RemoteLeaseDir { "$($DriveSyncConfig.Remote)$($DriveSyncConfig.RemoteLeaseDir)" }
function Get-RemoteLeaseFile([string]$computer = $env:COMPUTERNAME) { "$(Get-RemoteLeaseDir)/lease-$computer.json" }

# Every lease file in the folder, parsed; unreadable lines are skipped.
# "rclone cat" on a folder prints all files in one call, one JSON line each.
function Read-RemoteLeases([string]$rcloneExe) {
    $out = @(& $rcloneExe cat (Get-RemoteLeaseDir) --include "lease-*.json" --retries 1 --low-level-retries 2 `
        --contimeout 15s --timeout 30s 2>$null)
    # exit 3 = folder not found: no machine has ever taken a lease
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) { return $null }
    @($out | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.host })
}

function Get-UnixNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Test-LeaseLive($lease, [long]$now = (Get-UnixNow)) {
    [bool]($lease -and [long]$lease.expires -gt $now)
}

# The live lease of another machine (the earliest, if several), else $null.
function Get-ForeignLease([string]$rcloneExe) {
    $all = Read-RemoteLeases $rcloneExe
    if ($null -eq $all) { return $null }
    @($all | Where-Object { $_.host -ne $env:COMPUTERNAME -and (Test-LeaseLive $_) } | Sort-Object { [long]$_.started }, host)[0]
}

function Write-RemoteLease([string]$rcloneExe, $lease) {
    $minutes = if ($DriveSyncConfig.RemoteLeaseMinutes) { [int]$DriveSyncConfig.RemoteLeaseMinutes } else { 30 }
    $lease.expires = (Get-UnixNow) + 60 * $minutes
    ($lease | Select-Object host, pid, kind, token, started, expires | ConvertTo-Json -Compress) | & $rcloneExe rcat (Get-RemoteLeaseFile) --retries 2 --low-level-retries 3 2>$null
    $LASTEXITCODE -eq 0
}

# Takes the lease, or returns $null while another machine holds a live one.
# A lease that could not be written still returns an object (.Written = $false):
# the run goes ahead unprotected, as before this file existed.
#
# Two machines starting at the same moment both see no foreign lease and both
# write. Hence write, settle, read again: of two live leases the earlier start
# wins (ties: the smaller host name), and the loser withdraws its own.
function Enter-RemoteLease([string]$rcloneExe, [string]$kind = "bisync") {
    if (Get-ForeignLease $rcloneExe) { return $null }
    $lease = [pscustomobject]@{
        host = $env:COMPUTERNAME; pid = $PID; kind = $kind
        token = [guid]::NewGuid().ToString("N")
        started = Get-UnixNow; expires = 0
    }
    $written = Write-RemoteLease $rcloneExe $lease
    $lease | Add-Member -NotePropertyName Written -NotePropertyValue $written
    if (-not $written) { return $lease }
    Start-Sleep -Seconds 5
    $rival = Get-ForeignLease $rcloneExe
    if ($rival -and (([long]$rival.started -lt $lease.started) -or ([long]$rival.started -eq $lease.started -and $rival.host -lt $lease.host))) {
        Exit-RemoteLease $rcloneExe $lease
        return $null
    }
    $lease
}

function Update-RemoteLease([string]$rcloneExe, $lease) {
    if ($lease -and $lease.Written) { [void](Write-RemoteLease $rcloneExe $lease) }
}

# Deleted outright, not into the Drive trash: the resync guard reads the
# trash, and a trashed lease per run would only add noise there.
function Exit-RemoteLease([string]$rcloneExe, $lease) {
    if (-not $lease -or -not $lease.Written) { return }
    & $rcloneExe deletefile (Get-RemoteLeaseFile) --drive-use-trash=false --retries 2 2>$null
}

# Renews the lease from a thread while the caller blocks in a long rclone
# call; Stop-LeaseRenewal ends it. The thread dies with the process, so a
# killed run stops renewing and its lease lapses.
function Start-LeaseRenewal([string]$rcloneExe, $lease) {
    if (-not $lease -or -not $lease.Written) { return $null }
    $every = [math]::Max(1, [int](([int]$DriveSyncConfig.RemoteLeaseMinutes) / 3))
    Start-ThreadJob -ArgumentList $PSScriptRoot, $rcloneExe, $lease, $every -ScriptBlock {
        param($root, $exe, $l, $every)
        . (Join-Path $root "config.ps1")
        . (Join-Path $root "remote-lease.ps1")
        while ($true) { Start-Sleep -Seconds ($every * 60); Update-RemoteLease $exe $l }
    }
}

function Stop-LeaseRenewal($job) {
    if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
}

# For the watchers: is another machine's bisync running? Asked before a flush,
# answered from a cache for RemoteLeaseCheckSeconds - a flush cycle runs every
# few seconds, the cloud is asked at most once a minute.
$script:foreignLeaseCache = @{ At = [datetime]::MinValue; Lease = $null }
function Test-ForeignBisyncRunning([string]$rcloneExe) {
    $ttl = if ($DriveSyncConfig.RemoteLeaseCheckSeconds) { [int]$DriveSyncConfig.RemoteLeaseCheckSeconds } else { 60 }
    if (((Get-Date) - $script:foreignLeaseCache.At).TotalSeconds -ge $ttl) {
        $script:foreignLeaseCache = @{ At = Get-Date; Lease = Get-ForeignLease $rcloneExe }
    }
    $l = $script:foreignLeaseCache.Lease
    if ($l -and -not (Test-LeaseLive $l)) { return $null }
    $l
}
