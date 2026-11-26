# Tests for the cross-machine bisync lease (remote-lease.ps1): taking,
# seeing and releasing a lease, expiry, the start-at-the-same-moment race and
# a remote that cannot be reached. Offline: the "remote" is a scratch folder
# under TEMP (rclone's local backend), the machines are COMPUTERNAME values.
#
#   pwsh -File test-remote-lease.ps1

$ErrorActionPreference = "Stop"
$lib = Join-Path $PSScriptRoot "remote-lease.ps1"

$script:failed = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    Write-Host ("{0} - {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { " [$detail]" } else { "" }))
    if (-not $ok) { $script:failed++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-remote-lease-test"
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Force $root | Out-Null
$remote = "$root\remote\"
$DriveSyncConfig = @{ Remote = $remote; RemoteLeaseDir = ".cache/drive-sync"; RemoteLeaseMinutes = 30; RemoteLeaseCheckSeconds = 0 }
. $lib
$leaseDir = Join-Path $remote ".cache\drive-sync"
$realHost = $env:COMPUTERNAME
function As([string]$machine) { $env:COMPUTERNAME = $machine }

try {
    Write-Host "--- part 1: one machine ---"
    As "HOST-A"
    Check "no lease folder yet: nothing foreign" ($null -eq (Get-ForeignLease "rclone"))
    $a = Enter-RemoteLease "rclone"
    Check "A takes the lease" ($a -and $a.Written) "$($a | ConvertTo-Json -Compress)"
    Check "A's file is lease-HOST-A.json" (Test-Path (Join-Path $leaseDir "lease-HOST-A.json"))
    Check "A sees no foreign lease (its own does not count)" ($null -eq (Get-ForeignLease "rclone"))

    Write-Host "--- part 2: the other machine ---"
    As "HOST-B"
    $seen = Get-ForeignLease "rclone"
    Check "B sees A's lease" ($seen -and $seen.host -eq "HOST-A" -and $seen.token -eq $a.token) "$($seen.host)"
    Check "B's watcher defers (Test-ForeignBisyncRunning)" ([bool](Test-ForeignBisyncRunning "rclone"))
    Check "B cannot take a lease while A's is live" ($null -eq (Enter-RemoteLease "rclone"))
    Check "B left no file behind" (-not (Test-Path (Join-Path $leaseDir "lease-HOST-B.json")))

    Write-Host "--- part 3: renewal and release ---"
    As "HOST-A"
    # an almost lapsed lease on disk, as if renewals had stopped
    $short = (Get-UnixNow) + 5
    $nearly = $a.PSObject.Copy(); $nearly.expires = $short; $nearly.PSObject.Properties.Remove('Written')
    Set-Content (Join-Path $leaseDir "lease-HOST-A.json") ($nearly | ConvertTo-Json -Compress)
    Update-RemoteLease "rclone" $a
    $renewed = [long](Get-Content (Join-Path $leaseDir "lease-HOST-A.json") -Raw | ConvertFrom-Json).expires
    Check "renewal pushes the expiry out again" ($renewed -gt $short + 60) "$short -> $renewed"
    Exit-RemoteLease "rclone" $a
    Check "release removes A's file" (-not (Test-Path (Join-Path $leaseDir "lease-HOST-A.json")))
    As "HOST-B"
    Check "after the release B sees nothing" ($null -eq (Get-ForeignLease "rclone"))

    Write-Host "--- part 4: expiry ---"
    $stale = [pscustomobject]@{ host = "HOST-A"; pid = 1; kind = "bisync"; token = "stale"; started = (Get-UnixNow) - 7200; expires = (Get-UnixNow) - 60 }
    New-Item -ItemType Directory -Force $leaseDir | Out-Null
    Set-Content (Join-Path $leaseDir "lease-HOST-A.json") ($stale | ConvertTo-Json -Compress)
    Check "an expired lease does not count" ($null -eq (Get-ForeignLease "rclone"))
    $b = Enter-RemoteLease "rclone"
    Check "B takes the lease over an expired one" ($b -and $b.Written)
    Exit-RemoteLease "rclone" $b
    Remove-Item (Join-Path $leaseDir "lease-HOST-A.json")

    Write-Host "--- part 5: both start at the same moment ---"
    # B enters in a process of its own; A's lease appears while B settles,
    # with an earlier start: B must withdraw. Encoded: the paths have spaces.
    $answer = Join-Path $root "b-answer.txt"
    $cmd = "`$env:COMPUTERNAME = 'HOST-B'; `$DriveSyncConfig = @{ Remote = '$remote'; RemoteLeaseDir = '.cache/drive-sync'; RemoteLeaseMinutes = 30; RemoteLeaseCheckSeconds = 0 }; " +
        ". '$lib'; `$l = Enter-RemoteLease 'rclone'; [IO.File]::WriteAllText('$answer', `$(if (`$l) { 'held' } else { 'withdrew' }))"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $p = Start-Process pwsh -ArgumentList "-NoProfile", "-EncodedCommand", $enc -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path (Join-Path $leaseDir "lease-HOST-B.json")) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Check "B wrote its lease first" (Test-Path (Join-Path $leaseDir "lease-HOST-B.json"))
    $early = [pscustomobject]@{ host = "HOST-A"; pid = 2; kind = "bisync"; token = "early"; started = (Get-UnixNow) - 10; expires = (Get-UnixNow) + 600 }
    Set-Content (Join-Path $leaseDir "lease-HOST-A.json") ($early | ConvertTo-Json -Compress)
    $p | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
    $got = if (Test-Path $answer) { [IO.File]::ReadAllText($answer) } else { "no answer" }
    Check "B withdraws in favour of the earlier start" ($got -eq "withdrew") $got
    Check "B's file is gone" (-not (Test-Path (Join-Path $leaseDir "lease-HOST-B.json")))
    Remove-Item (Join-Path $leaseDir "lease-HOST-A.json")

    Write-Host "--- part 6: remote not reachable ---"
    $DriveSyncConfig.Remote = "no-such-remote-$PID`:"
    Check "unreadable: nothing foreign, the sync is not blocked" ($null -eq (Get-ForeignLease "rclone"))
    $u = Enter-RemoteLease "rclone"
    Check "unwritable: a lease object marked not written" ($u -and -not $u.Written)
    Exit-RemoteLease "rclone" $u
    Check "releasing an unwritten lease does not throw" $true
}
finally {
    $env:COMPUTERNAME = $realHost
    if ($p -and -not $p.HasExited) { $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:failed) { Write-Host "$($script:failed) check(s) FAILED"; exit 1 }
Write-Host "all checks passed"
exit 0
