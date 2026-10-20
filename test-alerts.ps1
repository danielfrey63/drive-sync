# Exercises the alert module (notify.ps1) and the watchdog's crash-cause
# detection against a scratch state directory. Shows no toast unless -Live is
# given; touches neither the real state directory nor the cloud.
#
#   pwsh -File test-alerts.ps1          # logic only
#   pwsh -File test-alerts.ps1 -Live    # plus one real test toast

param([switch]$Live)
$ErrorActionPreference = "Stop"

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("alerts-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $scratch | Out-Null
$DriveSyncConfig = @{ StateDir = $scratch; AlertRepeatHours = 12 }
. (Join-Path $PSScriptRoot "notify.ps1")
$realToast = $script:toastScript

$script:failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:failures++ }
    Write-Host ("{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($detail) { "  ($detail)" } else { "" }))
}
function AlertLog { @(Get-Content (Join-Path $scratch "alerts.log") -ErrorAction SilentlyContinue) }

try {
    # a stand-in helper script that records its calls instead of showing a toast
    $fake = Join-Path $scratch "toast.ps1"
    $calls = Join-Path $scratch "calls.txt"
    Set-Content $fake "param([string]`$Title, [string]`$Body, [switch]`$Reminder, [string]`$AppId, [string]`$AppName) Add-Content '$calls' `"`$AppId|`$Reminder|`$Title`""
    $script:toastScript = $fake
    function Calls { @(Get-Content $calls -ErrorAction SilentlyContinue) }

    Check "erster Alarm wird gezeigt" ((Send-DriveSyncAlert -Key "k1" -Title "T1" -Body "B") -and (Calls).Count -eq 1)
    Check "Toast bleibt im Action Center (Reminder) unter eigener App-Id" (@(Calls)[0] -eq "DriveSync.Alerts|True|T1") (@(Calls)[0])
    Check "Wiederholung innert 12 h wird unterdrueckt" (-not (Send-DriveSyncAlert -Key "k1" -Title "T1") -and (Calls).Count -eq 1)
    Check "anderer Schluessel kommt durch" ((Send-DriveSyncAlert -Key "k2" -Title "T2") -and (Calls).Count -eq 2)
    Check "-Force ignoriert die Sperrfrist" ((Send-DriveSyncAlert -Key "k1" -Title "T1" -Force) -and (Calls).Count -eq 3)

    Clear-DriveSyncAlert "k1"
    Check "nach Clear meldet derselbe Schluessel sofort wieder" ((Send-DriveSyncAlert -Key "k1" -Title "T1") -and (Calls).Count -eq 4)

    # an entry older than the repeat window fires again
    $st = Get-Content (Join-Path $scratch "alerts.json") -Raw | ConvertFrom-Json
    $st.k2 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 13 * 3600
    Set-Content (Join-Path $scratch "alerts.json") ($st | ConvertTo-Json -Compress)
    Check "nach Ablauf der Sperrfrist wird wiederholt" ((Send-DriveSyncAlert -Key "k2" -Title "T2") -and (Calls).Count -eq 5)

    Check "jeder Alarm steht in alerts.log" (@(AlertLog | Where-Object { $_ -match 'ALERT \[' }).Count -eq 5)

    # helper missing: logged, no error for the caller
    $script:toastScript = Join-Path $scratch "nope.ps1"
    $r = Send-DriveSyncAlert -Key "k3" -Title "T3"
    Check "fehlender Toast-Helfer: kein Fehler, nur Log" ((-not $r) -and (AlertLog | Where-Object { $_ -match 'toast helper missing' }))

    # broken helper: must not throw either
    Set-Content $fake "throw 'boom'"
    $script:toastScript = $fake
    $r = Send-DriveSyncAlert -Key "k4" -Title "T4"
    Check "kaputter Toast-Helfer wirft nicht" ((-not $r) -and (AlertLog | Where-Object { $_ -match 'WARN alert \[k4\].*boom' }))

    # corrupt state file: fail-open, alert still goes out
    Set-Content (Join-Path $scratch "alerts.json") "{kaputt"
    Set-Content $fake "param([string]`$Title, [string]`$Body, [switch]`$Reminder, [string]`$AppId, [string]`$AppName) Add-Content '$calls' `"`$AppId|`$Reminder|`$Title`""
    Check "kaputte alerts.json blockiert keinen Alarm" (Send-DriveSyncAlert -Key "k5" -Title "T5")

    Check "Toast-Helfer der ai-toolbox ist auffindbar" (Test-Path $realToast) $realToast

    if ($Live) {
        $script:toastScript = $realToast
        Clear-DriveSyncAlert "test-live"
        Check "Live-Toast an Windows uebergeben" (Send-DriveSyncAlert -Key "test-live" -Title "Drive-Sync: Testalarm" -Body "Wenn du das siehst, funktionieren die Warnungen. Einfach wegklicken.")
    }
}
finally {
    [IO.Directory]::Delete($scratch, $true)
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) FAILED"; exit 1 }
Write-Host "`nall passed"
