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

# A real entry from the baseline that still exists on disk. Picked from the file
# instead of hard-coded: a fixed path drops out of the baseline as soon as the
# nightly run rebuilds it, and the test then fails for the wrong reason.
$baselineRel = $null
$n = 0
foreach ($line in [System.IO.File]::ReadLines($listings.Path1)) {
    if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }
    if (++$n -gt 20000) { break }
    $q1 = $line.IndexOf('"'); $q2 = $line.LastIndexOf('"')
    if ($q2 -le $q1) { continue }
    $rel = $line.Substring($q1 + 1, $q2 - $q1 - 1)
    if (-not (Test-SpliceSafeName $rel)) { continue }
    if (Test-Path -LiteralPath (Join-Path $localPath ($rel -replace '/', '\'))) { $baselineRel = $rel; break }
}
if (-not $baselineRel) { throw "no usable baseline entry found in the first $n lines" }

$cases = [ordered]@{
    "waere zu spleissen (nirgends)" = "Agile Lean Teal/SAFe/__does-not-exist-anywhere__.zip"
    "wieder da (existiert lokal)"   = $baselineRel
    "unsicherer Name (U+00A0)"      = "Agile Lean Teal/SAFe/__nbsp$([char]0x00A0)test__.pdf"
    "unsicherer Name (U+00AD)"      = "Agile Lean Teal/SAFe/__shy$([char]0x00AD)test__.pdf"
}

Write-Host "`nName-Sicherheitspruefung:"
foreach ($k in $cases.Keys) {
    Write-Host ("   {0,-34} {1}" -f $k, (Test-SpliceSafeName $cases[$k]))
}

$m = Measure-SpliceCandidates $localPath $listings "path1" @($cases.Values)
Write-Host "`nEinstufung (Seite path1 - lokal geloescht):"
Write-Host "   journalisiert:      $($m.Total)"
Write-Host "   zu spleissen:       $($m.Ready.Count)   $($m.Ready -join ', ')"
Write-Host "   schon in Baseline:  $($m.InBaseline)"
Write-Host "   wieder auf Platte:  $($m.Recreated)"
Write-Host "   unsicherer Name:    $($m.UnsafeName.Count)"

$ok = $m.Ready.Count -eq 1 -and $m.InBaseline -eq 0 -and $m.Recreated -eq 1 -and $m.UnsafeName.Count -eq 2
Write-Host "`n$(if ($ok) { 'PASS' } else { 'FAIL' }) - erwartet 1 / 0 / 1 / 2"

# The same path from the other side: the cloud deleted it, the mirror still has
# it, and it IS in the baseline - so bisync reads the deletion correctly and
# there is nothing to splice. This is the branch that proves the listings are
# really being consulted.
$m2 = Measure-SpliceCandidates $localPath $listings "path2" @($baselineRel)
Write-Host "`nEinstufung (Seite path2 - in der Cloud geloescht):"
Write-Host "   Kandidat:           $baselineRel"
Write-Host "   schon in Baseline:  $($m2.InBaseline)"
$okB = $m2.InBaseline -eq 1 -and $m2.Ready.Count -eq 0
Write-Host "$(if ($okB) { 'PASS' } else { 'FAIL' }) - erwartet in der Baseline gefunden, nichts zu spleissen"

# and the journal round-trip, in a scratch dir so the real one is untouched
$tmp = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-journal-test"
New-Item -ItemType Directory -Force $tmp | Out-Null
Clear-DroppedDeletes $tmp "path1" -All
Add-DroppedDeletes $tmp "path1" @("a\b\c.txt", "d/e.txt", "a\b\c.txt")
$rt = @(Read-DroppedDeletes $tmp "path1" -Claim)
Write-Host "`nJournal-Roundtrip: $($rt.Count) Eintraege - $($rt -join ', ')"
Clear-DroppedDeletes $tmp "path1"
$after = @(Read-DroppedDeletes $tmp "path1").Count
$ok2 = $rt.Count -eq 2 -and $rt -contains 'a/b/c.txt' -and $after -eq 0
Write-Host "$(if ($ok2) { 'PASS' } else { 'FAIL' }) - erwartet 2 Eintraege, Backslashes normalisiert, danach leer"

# the race the claim exists for: a watcher appends while a batch is being
# consumed. Claim, then append, then clear - the late entry must survive.
Clear-DroppedDeletes $tmp "path1" -All
Add-DroppedDeletes $tmp "path1" @("early.txt")
$claimed = @(Read-DroppedDeletes $tmp "path1" -Claim)
Add-DroppedDeletes $tmp "path1" @("late.txt")           # the watcher, mid-flush
Clear-DroppedDeletes $tmp "path1"
$survived = @(Read-DroppedDeletes $tmp "path1")
$ok4 = $claimed.Count -eq 1 -and $claimed[0] -eq 'early.txt' `
    -and $survived.Count -eq 1 -and $survived[0] -eq 'late.txt'
Write-Host "`nNebenlaeufiger Anhang: geclaimt=$($claimed -join ',') ueberlebt=$($survived -join ',')"
Write-Host "$(if ($ok4) { 'PASS' } else { 'FAIL' }) - erwartet early.txt geclaimt, late.txt ueberlebt"

# consumer died between claim and clear: the batch must not be lost, and the
# next claim must fold the newer entries into it
Clear-DroppedDeletes $tmp "path1" -All
Add-DroppedDeletes $tmp "path1" @("orphan.txt")
[void](Read-DroppedDeletes $tmp "path1" -Claim)         # ... and then the process dies
Add-DroppedDeletes $tmp "path1" @("next.txt")
$recovered = @(Read-DroppedDeletes $tmp "path1" -Claim | Sort-Object)
Clear-DroppedDeletes $tmp "path1" -All
$ok5 = $recovered.Count -eq 2 -and $recovered[0] -eq 'next.txt' -and $recovered[1] -eq 'orphan.txt'
Write-Host "`nAbgestuerzter Konsument: $($recovered -join ', ')"
Write-Host "$(if ($ok5) { 'PASS' } else { 'FAIL' }) - erwartet next.txt + orphan.txt"

# the report exactly as sync-drive.ps1 runs it, against a scratch journal
Clear-DroppedDeletes $tmp "path1" -All
Add-DroppedDeletes $tmp "path1" @($cases.Values)
Write-Host "`nBericht (derselbe Aufruf wie im Wrapper):"
$sw = [Diagnostics.Stopwatch]::StartNew()
$rep = @(Write-SpliceReport $localPath $DriveSyncConfig.Remote $tmp)
$sw.Stop()
$leftover = @(Read-DroppedDeletes $tmp "path1").Count
# the nightly task runs hidden: the file is the only place the numbers survive
$logged = @(Get-Content (Join-Path $tmp "splice-report.log") -ErrorAction SilentlyContinue)
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
$ok3 = $rep.Count -eq 1 -and $rep[0].Ready.Count -eq 1 -and $leftover -eq 0
Write-Host "$(if ($ok3) { 'PASS' } else { 'FAIL' }) - ein Seitenbericht, 1 zu spleissen, Journal danach geleert"
$ok6 = $logged.Count -ge 1 -and ($logged[0] -match 'splice report path1: 4 journalled')
Write-Host "Bericht-Log: $($logged.Count) Zeile(n)"
Write-Host "$(if ($ok6) { 'PASS' } else { 'FAIL' }) - Bericht steht in splice-report.log"
Write-Host ("Laufzeit des Berichts ueber beide Listings: {0:n1} s" -f $sw.Elapsed.TotalSeconds)
