# Exercises the local-intent guard (local-intent.ps1) against a scratch state
# directory and a scratch tree. Touches neither the real watchers, the real
# state directory nor the cloud; safe to run any time.
#
#   pwsh -File test-local-intent.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "local-intent.ps1")

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("local-intent-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$stateDir = Join-Path $scratch "state"
$root = Join-Path $scratch "root"
New-Item -ItemType Directory -Force $stateDir, (Join-Path $root "Develop\sem"), (Join-Path $root "Scans") | Out-Null

$script:failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:failures++ }
    Write-Host ("{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($detail) { "  ($detail)" } else { "" }))
}
function Select-Now([string[]]$rels) {
    $held = @()
    $kept = @(Select-DownloadsWithoutLocalIntent $stateDir $root $rels ([ref]$held))
    return [pscustomobject]@{ Kept = $kept; Held = @($held) }
}
function Set-EntryAge([string]$rel, [int]$ageSec) {
    $file = Get-LocalIntentPath $stateDir
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ageSec
    $lines = @(Get-Content $file | ForEach-Object { if ($_ -match "^\d+`t$([regex]::Escape($rel))$") { "$t`t$rel" } else { $_ } })
    Set-Content $file $lines
}

try {
    # the 2026-09-17 case: downloaded, renamed locally, cloud still has the old name
    $old = "Develop\sem\20260917-1100 SEM - Weekly.m4a"
    $new = "Develop\sem\20260917-1100 - SEM - Weekly.m4a"
    Set-Content (Join-Path $root $new) "x"

    $r = Select-Now @($old)
    Check "ohne Eintrag wird heruntergeladen (bisheriges Verhalten)" ($r.Kept.Count -eq 1 -and $r.Held.Count -eq 0)

    Add-LocalIntent $stateDir @($old)
    $r = Select-Now @($old)
    Check "alter Name nach Umbenennung wird zurueckgehalten" ($r.Held.Count -eq 1 -and $r.Kept.Count -eq 0)

    $r = Select-Now @(($old -replace '\\', '/').ToUpperInvariant())
    Check "Schreibweise und Trenner spielen keine Rolle" ($r.Held.Count -eq 1)

    $r = Select-Now @($new, "Develop\sem\anderes.pdf")
    Check "andere Pfade laufen normal durch" ($r.Kept.Count -eq 2 -and $r.Held.Count -eq 0)

    # the name is used again locally: the record must not interfere
    Set-Content (Join-Path $root $old) "y"
    $r = Select-Now @($old)
    Check "existiert die Datei lokal wieder, wird nicht blockiert" ($r.Kept.Count -eq 1)
    Remove-Item -LiteralPath (Join-Path $root $old)

    # directory rename takes the subtree along - but only real ancestors
    Add-LocalIntent $stateDir @("Scans\2026")
    $r = Select-Now @("Scans\2026\a.pdf", "Scans\2026-alt\b.pdf", "Scans\2026x.pdf")
    Check "Ordner-Eintrag haelt den Unterbaum zurueck" ($r.Held -contains "Scans\2026\a.pdf")
    Check "aehnlicher Name ist kein Vorfahre" (($r.Kept -contains "Scans\2026-alt\b.pdf") -and ($r.Kept -contains "Scans\2026x.pdf")) "gehalten: $($r.Held -join ', ')"

    # completion: still held inside the grace period, released after it
    Complete-LocalIntent $stateDir @($old)
    $r = Select-Now @($old)
    Check "nach Vollzug waehrend der Gnadenfrist weiter zurueckgehalten" ($r.Held.Count -eq 1)
    Set-EntryAge $old ($script:LocalIntentMaxAgeSec + 1)
    $r = Select-Now @($old)
    Check "nach der Gnadenfrist kommt ein neuer Cloud-Upload gleichen Namens durch" ($r.Kept.Count -eq 1)

    # completion must never EXTEND an entry that is closer to expiry
    Add-LocalIntent $stateDir @("Scans\alt.pdf")
    Set-EntryAge "Scans\alt.pdf" ($script:LocalIntentMaxAgeSec - 10)
    Complete-LocalIntent $stateDir @("Scans\alt.pdf")
    $map = Read-LocalIntentMap $stateDir
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $map["Scans\alt.pdf"]
    Check "Vollzug verlaengert keinen fast abgelaufenen Eintrag" ($age -ge ($script:LocalIntentMaxAgeSec - 10)) "Alter $age s"

    # a stranded entry (propagation failed) ages out after the full window
    Add-LocalIntent $stateDir @("Scans\haengen.pdf")
    Set-EntryAge "Scans\haengen.pdf" ($script:LocalIntentMaxAgeSec + 5)
    $r = Select-Now @("Scans\haengen.pdf")
    Check "nicht vollzogener Eintrag laeuft nach einer Stunde aus" ($r.Kept.Count -eq 1)

    # damaged record: bad lines are ignored, good ones still count
    Add-LocalIntent $stateDir @("Scans\gut.pdf")
    Add-Content (Get-LocalIntentPath $stateDir) @("kaputt", "`t", "abc`tScans\x.pdf")
    $r = Select-Now @("Scans\gut.pdf", "Scans\x.pdf")
    Check "defekte Zeilen werden ignoriert, gueltige gelten weiter" (($r.Held -contains "Scans\gut.pdf") -and ($r.Kept -contains "Scans\x.pdf"))

    # empty record removes the file instead of leaving an empty one around
    $map = Read-LocalIntentMap $stateDir
    foreach ($k in @($map.Keys)) { $map.Remove($k) | Out-Null }
    Write-LocalIntentMap $stateDir $map
    Check "leerer Stand hinterlaesst keine Datei" (-not (Test-Path (Get-LocalIntentPath $stateDir)))

    # no temp file left behind by the atomic swap
    Add-LocalIntent $stateDir @("Scans\swap.pdf")
    Check "atomarer Tausch hinterlaesst keine .tmp-Datei" (-not (Test-Path "$(Get-LocalIntentPath $stateDir).tmp"))
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:failures -eq 0) { Write-Host "ALLE TESTS BESTANDEN" } else { Write-Host "$($script:failures) TEST(S) FEHLGESCHLAGEN"; exit 1 }
