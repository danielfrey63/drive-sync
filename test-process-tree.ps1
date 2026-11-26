# Tests for stopping a watcher with what it started (process-tree.ps1): the
# rclone below a process is found through the scoop shim, Stop-ChildRclone
# leaves the parent alive, Stop-ProcessTree takes the parent and the rclone,
# and an orphan whose dead parent's PID was handed out again is no child.
# Offline: a hidden pwsh stands in for the watcher and starts
# "rclone serve http" on 127.0.0.1 for an empty scratch folder.
#
#   pwsh -File test-process-tree.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "process-tree.ps1")

$script:failed = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    Write-Host ("{0} - {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { " [$detail]" } else { "" }))
    if (-not $ok) { $script:failed++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-process-tree-test"
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $root "served") | Out-Null

# A stand-in watcher: starts rclone the way the watcher does (& rclone, so
# through the shim when rclone is a scoop shim), blocks on it and lives on
# for a minute after it.
# Encoded: Start-Process joins its arguments unquoted, and the paths have spaces.
function Start-StandIn {
    $cmd = "& rclone serve http '$(Join-Path $root 'served')' --addr 127.0.0.1:0 2>`$null; Start-Sleep 60"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process pwsh -ArgumentList "-NoProfile", "-EncodedCommand", $enc -WindowStyle Hidden -PassThru
}
function Wait-Rclone([int]$parentId) {
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $r = @(Get-ProcessTreeIds $parentId | Where-Object Name -eq 'rclone.exe')
        # the scoop shim starts the real rclone a moment after itself: wait
        # until the set stops growing, or the test counts the shim alone
        if ($r) {
            Start-Sleep -Milliseconds 1000
            $again = @(Get-ProcessTreeIds $parentId | Where-Object Name -eq 'rclone.exe')
            if ($again.Count -eq $r.Count) { return $r }
            continue
        }
        Start-Sleep -Milliseconds 200
    }
    @()
}
function Test-Alive([int]$id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }

$standIns = @()
try {
    Write-Host "--- part 1: only the rclone below ---"
    $p = Start-StandIn; $standIns += $p
    $rc = Wait-Rclone $p.Id
    Check "the rclone below the stand-in is found" ($rc.Count -ge 1) "$(@($rc.ProcessId) -join ', ')"
    $n = Stop-ChildRclone $p.Id
    Start-Sleep -Milliseconds 500
    Check "Stop-ChildRclone stops every rclone below" ($n -eq $rc.Count -and -not @($rc | Where-Object { Test-Alive $_.ProcessId })) "stopped $n"
    Check "... and leaves the parent alive" (Test-Alive $p.Id)

    Write-Host "--- part 2: the whole tree ---"
    $q = Start-StandIn; $standIns += $q
    $rc = Wait-Rclone $q.Id
    Check "second stand-in has its rclone" ($rc.Count -ge 1)
    $n = Stop-ProcessTree $q.Id
    Start-Sleep -Milliseconds 500
    Check "Stop-ProcessTree stops the parent" (-not (Test-Alive $q.Id))
    Check "... and every process it had started" ($n -ge $rc.Count -and -not @($rc | Where-Object { Test-Alive $_.ProcessId })) "stopped $n below"

    Write-Host "--- part 3: a reused PID (2026-11-27) ---"
    # The watcher's parent (wscript) is long dead; a newer process got its PID.
    # Only what was created after that newer process is its child.
    $t0 = Get-Date
    $snap = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 4; Name = "pwsh.exe"; CreationDate = $t0 }
        [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = "rclone.exe"; CreationDate = $t0.AddSeconds(5) }
        [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; Name = "rclone.exe"; CreationDate = $t0.AddSeconds(6) }
        [pscustomobject]@{ ProcessId = 50; ParentProcessId = 100; Name = "pwsh.exe"; CreationDate = $t0.AddHours(-2) }
        [pscustomobject]@{ ProcessId = 51; ParentProcessId = 50; Name = "rclone.exe"; CreationDate = $t0.AddHours(-1) }
    )
    $ids = @(Get-ProcessTreeIds 100 $snap | ForEach-Object ProcessId | Sort-Object)
    Check "real children and grandchildren are found" (($ids -join ",") -eq "101,102") ($ids -join ",")
    Check "an orphan older than the PID's new holder is not" ($ids -notcontains 50 -and $ids -notcontains 51)
    Check "a root not in the snapshot has no tree" (@(Get-ProcessTreeIds 999 $snap).Count -eq 0)

    Write-Host "--- part 4: nothing below ---"
    $lone = Start-Process pwsh -ArgumentList "-NoProfile", "-Command", "Start-Sleep 60" -WindowStyle Hidden -PassThru; $standIns += $lone
    Start-Sleep -Milliseconds 500
    Check "no rclone below: Stop-ChildRclone stops nothing" ((Stop-ChildRclone $lone.Id) -eq 0 -and (Test-Alive $lone.Id))
    # a hidden pwsh still has its conhost.exe below it: exactly those go along
    $below = @(Get-ProcessTreeIds $lone.Id)
    $n = Stop-ProcessTree $lone.Id
    Check "no rclone below: Stop-ProcessTree takes exactly what was below" ($n -eq $below.Count -and -not @($below | Where-Object Name -eq 'rclone.exe')) "$(@($below.Name) -join ', ')"
    Start-Sleep -Milliseconds 300
    Check "... and it is gone" (-not (Test-Alive $lone.Id))
    Check "a PID that does not exist: no error" ((Stop-ProcessTree 999999) -eq 0)
}
finally {
    foreach ($s in $standIns) { if ($s -and -not $s.HasExited) { [void](Stop-ProcessTree $s.Id) } }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:failed) { Write-Host "$($script:failed) check(s) FAILED"; exit 1 }
Write-Host "all checks passed"
exit 0
