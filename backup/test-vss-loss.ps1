# Exercises the "shadow copy deleted mid-run" guard in run-backup.ps1 without
# touching restic, the repository or the real state: the two helpers and the
# retry loop are lifted out of the script and driven against canned restic
# output, including the real output of the 2026-11-05 incident when its log is
# still around.
#
#   pwsh -File test-vss-loss.ps1

$ErrorActionPreference = "Stop"
$runBackup = Join-Path $PSScriptRoot "run-backup.ps1"
$src = Get-Content $runBackup -Raw

$script:failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:failures++ }
    Write-Host ("{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($detail) { "  ($detail)" } else { "" }))
}

# --- the detector, taken from the script so the test cannot drift from it ----
$fn = [regex]::Match($src, '(?s)function Test-VssLost.*?\r?\n    \}\r?\n').Value
if (-not $fn) { Write-Host "FAIL  Test-VssLost nicht in run-backup.ps1 gefunden"; exit 1 }
Invoke-Expression $fn

$limit = 10
$vssError = 'error: C:\x\y: CreateFile \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\x\y: Das Geraet ist nicht bereit.'
$plainError = 'error: C:\z: open C:\z: Zugriff verweigert'

Check "sauberer Lauf schlaegt nicht an" ((Test-VssLost @("Files: 3 new", "snapshot abcd1234 saved") $limit) -eq 0)
Check "ein paar gesperrte Dateien schlagen nicht an" ((Test-VssLost @(1..5 | ForEach-Object { $plainError }) $limit) -eq 0)
Check "wenige Schattenkopie-Fehler bleiben unter der Schwelle" ((Test-VssLost @(1..9 | ForEach-Object { $vssError }) $limit) -eq 0)
Check "viele Schattenkopie-Fehler schlagen an" ((Test-VssLost @(1..20 | ForEach-Object { $vssError }) $limit) -eq 20)
Check "VSS_E_OBJECT_NOT_FOUND allein genuegt" ((Test-VssLost @('error: failed to delete VSS snapshot: VSS error: DeleteSnapshots() failed: VSS_E_OBJECT_NOT_FOUND') $limit) -ge 1)
Check "Treffer nur in error-Zeilen, nicht in beliebigem Text" ((Test-VssLost @(1..20 | ForEach-Object { "scanning HarddiskVolumeShadowCopy1" }) $limit) -eq 0)

# the real thing: the C: run of 2026-11-05 against the healthy D: run that followed
$realLog = Join-Path $env:LOCALAPPDATA "drive-sync\logs\backup-20261105.log"
if (Test-Path $realLog) {
    $all = Get-Content $realLog
    $i = ($all | Select-String "20:19:39 backup start \[C" | Select-Object -First 1).LineNumber
    $j = ($all | Select-String "20:24:55 backup start \[D" | Select-Object -First 1).LineNumber
    if ($i -and $j) {
        Check "echter abgebrochener C:-Lauf vom 05.11. schlaegt an" ((Test-VssLost $all[($i - 1)..($j - 2)] $limit) -gt 0)
        Check "echter gesunder D:-Lauf vom 05.11. schlaegt nicht an" ((Test-VssLost $all[($j - 1)..($all.Count - 1)] $limit) -eq 0)
    }
}
else { Write-Host "SKIP  Protokoll vom 05.11. nicht mehr vorhanden" }

# --- the retry loop ----------------------------------------------------------
# Replays the per-source loop with a stub for restic. $script:runs records what
# each attempt was asked to do, so the test can see how often it ran and with
# which verdict.
function Invoke-SourceLoop([object[]]$attemptResults, [int]$ladder = 5) {
    $script:runs = 0
    $script:forgotten = @()
    $vssAborted = @()
    $vssRetried = $false
    $rc = 0
    $attempts = $ladder + 1
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $script:runs++
        $r = $attemptResults[[Math]::Min($script:runs - 1, $attemptResults.Count - 1)]
        $srcOut = $r.Out; $rc = $r.Rc
        $vssLost = 0
        if ($rc -eq 3) { $vssLost = Test-VssLost @($srcOut) $limit }
        if ($vssLost -gt 0) {
            $script:forgotten += @($srcOut | ForEach-Object { if ("$_" -match '^snapshot ([0-9a-f]{8}) saved') { $Matches[1] } })
            if (-not $vssRetried) { $vssRetried = $true; $attempt--; continue }
            $vssAborted += "C:\"
            break
        }
        if ($rc -in 0, 3) { break }
        if ($attempt -eq $attempts) { break }
    }
    return [pscustomobject]@{ Rc = $rc; Aborted = @($vssAborted); Runs = $script:runs; Forgotten = @($script:forgotten) }
}

$lostOut = @(1..20 | ForEach-Object { $vssError }) + @("snapshot 38cba7bf saved")
$okOut = @("Files: 3 new", "snapshot aaaa1111 saved")
$lost = @{ Out = $lostOut; Rc = 3 }
$ok = @{ Out = $okOut; Rc = 0 }
$spotty = @{ Out = @($plainError, "snapshot bbbb2222 saved"); Rc = 3 }
$boxDown = @{ Out = @("ssh command exited: exit status 255"); Rc = 1 }

$r = Invoke-SourceLoop @($ok)
Check "gesunder Lauf: ein Versuch, kein Abbruch" ($r.Runs -eq 1 -and $r.Aborted.Count -eq 0 -and $r.Forgotten.Count -eq 0)

$r = Invoke-SourceLoop @($lost, $ok)
Check "Verlust, dann Erfolg: genau ein Wiederholversuch" ($r.Runs -eq 2 -and $r.Aborted.Count -eq 0) "Laeufe $($r.Runs)"
Check "Truemmer-Snapshot des Fehlversuchs wird entfernt" ($r.Forgotten -contains "38cba7bf" -and $r.Forgotten.Count -eq 1)

$r = Invoke-SourceLoop @($lost, $lost)
Check "zweimal verloren: Lauf gilt als abgebrochen" ($r.Runs -eq 2 -and $r.Aborted -contains "C:\") "Laeufe $($r.Runs)"
Check "beide Truemmer-Snapshots werden entfernt" ($r.Forgotten.Count -eq 2)

$r = Invoke-SourceLoop @($spotty)
Check "rc=3 ohne Schattenkopie-Verlust laeuft normal durch" ($r.Runs -eq 1 -and $r.Aborted.Count -eq 0 -and $r.Forgotten.Count -eq 0)

# the whole point of $attempt--: a shadow-copy retry must not use up the ladder
# that exists for a sleeping storage box
$r = Invoke-SourceLoop @($lost, $boxDown) 5
Check "Wiederholversuch verbraucht die Transport-Leiter nicht" ($r.Runs -eq 7 -and $r.Rc -eq 1) "Laeufe $($r.Runs), rc=$($r.Rc)"

# a loss on the very last ladder attempt must still conclude, not slip through
# as a bare rc=3 with no snapshot
$r = Invoke-SourceLoop @($boxDown, $boxDown, $boxDown, $boxDown, $boxDown, $lost, $lost) 5
Check "Verlust im letzten Leiter-Versuch endet als Abbruch" ($r.Aborted -contains "C:\") "Laeufe $($r.Runs), rc=$($r.Rc)"

Write-Host ""
if ($script:failures -eq 0) { Write-Host "ALLE TESTS BESTANDEN" } else { Write-Host "$($script:failures) TEST(S) FEHLGESCHLAGEN"; exit 1 }
