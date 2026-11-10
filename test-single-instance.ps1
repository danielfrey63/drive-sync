# Tests for the single-instance lock (single-instance.ps1): one holder per
# name across processes, and the lock is gone with the process that held it.
# Offline. It uses a lock name of its own, never those of the watchers or the
# bisync, and starts two short-lived hidden pwsh processes as contenders.
#
#   pwsh -File test-single-instance.ps1

$ErrorActionPreference = "Stop"
$lib = Join-Path $PSScriptRoot "single-instance.ps1"
. $lib

$script:failed = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    Write-Host ("{0} - {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { " [$detail]" } else { "" }))
    if (-not $ok) { $script:failed++ }
}

$name = "selftest-$PID"
$root = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-single-instance-test"
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Force $root | Out-Null
$lock = Join-Path $root "instance.lock"

# A second pwsh that tries to take the lock, writes what it got, and stays.
# Encoded: Start-Process joins its arguments unquoted, and the paths have spaces.
function Start-Contender([string]$answerFile) {
    $cmd = ". '$lib'; `$m = Enter-SingleInstance '$name' '$lock'; [IO.File]::WriteAllText('$answerFile', `$(if (`$m) { 'held' } else { 'refused' })); Start-Sleep 600"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process pwsh -ArgumentList "-NoProfile", "-EncodedCommand", $enc -WindowStyle Hidden -PassThru
}
function Wait-Answer([string]$answerFile) {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $a = if (Test-Path $answerFile) { try { [IO.File]::ReadAllText($answerFile) } catch { "" } }
        if ($a) { return $a }
        Start-Sleep -Milliseconds 200
    }
    "no answer"
}
function Wait-Released {
    $deadline = (Get-Date).AddSeconds(15)
    while ((Test-InstanceRunning $name) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    -not (Test-InstanceRunning $name)
}

$other = $null
try {
    # ========================================================================
    Write-Host "--- part 1: this process holds the lock ---"
    Check "nobody holds it: not running" (-not (Test-InstanceRunning $name))
    $mine = Enter-SingleInstance $name $lock
    Check "enter: granted, the lock file names this process" `
        ($null -ne $mine -and (Get-Content $lock -TotalCount 1) -eq "$PID") "$(Get-Content $lock -TotalCount 1 -ErrorAction SilentlyContinue)"
    Check "held: running - and asking did not take it away" ((Test-InstanceRunning $name) -and (Test-InstanceRunning $name))
    $answer = Join-Path $root "answer-1.txt"
    $other = Start-Contender $answer
    $got = Wait-Answer $answer
    Check "a second process is refused" ($got -eq 'refused') $got
    Check "the refused one left the lock file alone" ((Get-Content $lock -TotalCount 1) -eq "$PID")
    Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue
    $other = $null
    Exit-SingleInstance $mine $lock
    Check "exit: not running any more, lock file gone" ((Wait-Released) -and -not (Test-Path $lock))
    Exit-SingleInstance $null $lock
    Check "exit without a lock: no error" $true

    # ========================================================================
    Write-Host "--- part 2: another process holds it, and dies ---"
    $answer = Join-Path $root "answer-2.txt"
    $other = Start-Contender $answer
    $got = Wait-Answer $answer
    Check "the other process gets the free lock" ($got -eq 'held') $got
    Check "seen from here: running, lock file names the other process" `
        ((Test-InstanceRunning $name) -and (Get-Content $lock -TotalCount 1) -eq "$($other.Id)")
    $mine = Enter-SingleInstance $name $lock
    Check "enter from here is refused" ($null -eq $mine)
    if ($mine) { Exit-SingleInstance $mine $lock }
    Stop-Process -Id $other.Id -Force
    $stalePid = "$($other.Id)"
    $other = $null
    Check "holder killed: not running, although its lock file is still there" `
        ((Wait-Released) -and (Get-Content $lock -TotalCount 1 -ErrorAction SilentlyContinue) -eq $stalePid)
    $mine = Enter-SingleInstance $name $lock
    Check "the stale lock file does not block the next start" ($null -ne $mine -and (Get-Content $lock -TotalCount 1) -eq "$PID")
    Exit-SingleInstance $mine $lock
}
finally {
    if ($other) { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed -eq 0) { Write-Host "`nALL PASS"; exit 0 }
Write-Host "`nFAILED: $($script:failed)"
exit 1
