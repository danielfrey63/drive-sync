# Exercises the splice classification against the REAL baseline listings without
# touching them, the journals or the cloud. Read-only; safe to run any time.
#
#   pwsh -File test-splice-report.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "bisync-index.ps1")

$localPath = $DriveSyncConfig.LocalRoot
$listings = Get-BisyncListings $localPath $DriveSyncConfig.Remote
if (-not $listings) { throw "no baseline listings found" }
Write-Host "listings:"
Write-Host "   $($listings.Path1)"
Write-Host "   $($listings.Path2)"

# a file that really exists locally right now, to cover the "recreated" case
$live = Get-ChildItem -LiteralPath (Join-Path $localPath "Agile Lean Teal\SAFe") -File -Recurse |
    Select-Object -First 1
$liveRel = $live.FullName.Substring($localPath.Length + 1) -replace '\\', '/'

$cases = [ordered]@{
    "in der Baseline (heute geloescht)" = "Agile Lean Teal/SAFe/Assets/Sonstiges/SAFe_Buchstabenraetsel.pdf"
    "waere zu spleissen (nirgends)"     = "Agile Lean Teal/SAFe/__does-not-exist-anywhere__.zip"
    "wieder da (existiert lokal)"       = $liveRel
    "unsicherer Name (U+00A0)"          = "Agile Lean Teal/SAFe/__nbsp$([char]0x00A0)test__.pdf"
    "unsicherer Name (U+00AD)"          = "Agile Lean Teal/SAFe/__shy$([char]0x00AD)test__.pdf"
}

Write-Host "`nName-Sicherheitspruefung:"
foreach ($k in $cases.Keys) {
    Write-Host ("   {0,-34} {1}" -f $k, (Test-SpliceSafeName $cases[$k]))
}

$m = Measure-SpliceCandidates $localPath $listings "path1" @($cases.Values)
Write-Host "`nEinstufung (Seite path1):"
Write-Host "   journalisiert:      $($m.Total)"
Write-Host "   zu spleissen:       $($m.Ready.Count)   $($m.Ready -join ', ')"
Write-Host "   schon in Baseline:  $($m.InBaseline)"
Write-Host "   wieder auf Platte:  $($m.Recreated)"
Write-Host "   unsicherer Name:    $($m.UnsafeName.Count)"

$ok = $m.Ready.Count -eq 1 -and $m.InBaseline -eq 1 -and $m.Recreated -eq 1 -and $m.UnsafeName.Count -eq 2
Write-Host "`n$(if ($ok) { 'PASS' } else { 'FAIL' }) - erwartet 1 / 1 / 1 / 2"

# and the journal round-trip, in a scratch dir so the real one is untouched
$tmp = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-journal-test"
New-Item -ItemType Directory -Force $tmp | Out-Null
Clear-DroppedDeletes $tmp "path1"
Add-DroppedDeletes $tmp "path1" @("a\b\c.txt", "d/e.txt", "a\b\c.txt")
$rt = @(Read-DroppedDeletes $tmp "path1")
Write-Host "`nJournal-Roundtrip: $($rt.Count) Eintraege - $($rt -join ', ')"
Clear-DroppedDeletes $tmp "path1"
$after = @(Read-DroppedDeletes $tmp "path1").Count
$ok2 = $rt.Count -eq 2 -and $rt -contains 'a/b/c.txt' -and $after -eq 0
Write-Host "$(if ($ok2) { 'PASS' } else { 'FAIL' }) - erwartet 2 Eintraege, Backslashes normalisiert, danach leer"

# the report exactly as sync-drive.ps1 runs it, against a scratch journal
Add-DroppedDeletes $tmp "path1" @($cases.Values)
Write-Host "`nBericht (derselbe Aufruf wie im Wrapper):"
$sw = [Diagnostics.Stopwatch]::StartNew()
$rep = @(Write-SpliceReport $localPath $DriveSyncConfig.Remote $tmp)
$sw.Stop()
$leftover = @(Read-DroppedDeletes $tmp "path1").Count
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
$ok3 = $rep.Count -eq 1 -and $rep[0].Ready.Count -eq 1 -and $leftover -eq 0
Write-Host "$(if ($ok3) { 'PASS' } else { 'FAIL' }) - ein Seitenbericht, 1 zu spleissen, Journal danach geleert"
Write-Host ("Laufzeit des Berichts ueber beide Listings: {0:n1} s" -f $sw.Elapsed.TotalSeconds)
