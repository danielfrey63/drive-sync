# Tests for the delete journal and its replay (delete-journal.ps1,
# journal-replay.ps1).
#
# Part 1 - the journal itself: round trip, the claim against a watcher that
#          appends meanwhile, a consumer that died, folding into folders.
# Part 2 - end to end with a REAL rclone bisync between two scratch
#          directories under TEMP, with its own --workdir and state dir. It
#          never touches the corpus, the cloud, the real baselines, the real
#          journals or the recycle bin.
#
# The core scenario (2026-09-05, again 2026-11-07): a file appears on both
# sides between two nightly runs (the watcher's realtime upload), so it is in
# neither baseline. It is deleted on one side and the delete is only
# journalled (MaxDeletes cap). bisync alone then reads "new on the other side"
# and copies it back; with the replay it stays gone.
#
#   pwsh -File test-journal-replay.ps1          run everything
#   pwsh -File test-journal-replay.ps1 -Keep    leave the scratch dirs for a look

param([switch]$Keep)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "journal-replay.ps1")

# same resolution as the watchers: custom build if deployed, else PATH
$rclone = Join-Path $DriveSyncConfig.StateDir "bin\rclone.exe"
if (-not (Test-Path $rclone)) { $rclone = "rclone" }

$root = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-replay-test"
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Force $root | Out-Null
$script:failed = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    Write-Host ("{0} - {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { " [$detail]" } else { "" }))
    if (-not $ok) { $script:failed++ }
}

# ============================================================================
Write-Host "--- Teil 1: Journal ---"
$tmp = Join-Path $root "journal"
New-Item -ItemType Directory -Force $tmp | Out-Null

Add-DroppedDeletes $tmp "path1" @("a\b\c.txt", "d/e.txt", "a\b\c.txt")
$rt = @(Read-DroppedDeletes $tmp "path1" -Claim)
Clear-DroppedDeletes $tmp "path1"
$after = @(Read-DroppedDeletes $tmp "path1").Count
Check "Roundtrip: 2 Einträge, Backslashes normalisiert, danach leer" `
    ($rt.Count -eq 2 -and @($rt.Rel) -contains 'a/b/c.txt' -and $after -eq 0) "$(@($rt.Rel) -join ', ')"

# the race the claim exists for: a watcher appends while a batch is being
# consumed. Claim, then append, then clear - the late entry must survive.
Clear-DroppedDeletes $tmp "path1" -All
Add-DroppedDeletes $tmp "path1" @("early.txt")
$claimed = @(Read-DroppedDeletes $tmp "path1" -Claim)
Add-DroppedDeletes $tmp "path1" @("late.txt")           # the watcher, mid-flush
Clear-DroppedDeletes $tmp "path1"
$survived = @(Read-DroppedDeletes $tmp "path1")
Check "Nebenläufiger Anhang: early.txt geclaimt, late.txt überlebt" `
    ($claimed.Count -eq 1 -and @($claimed.Rel)[0] -eq 'early.txt' -and $survived.Count -eq 1 -and @($survived.Rel)[0] -eq 'late.txt')

# consumer died between claim and clear: the batch must not be lost, and the
# next claim must fold the newer entries into it
Clear-DroppedDeletes $tmp "path1" -All
Add-DroppedDeletes $tmp "path1" @("orphan.txt")
[void](Read-DroppedDeletes $tmp "path1" -Claim)         # ... and then the process dies
Add-DroppedDeletes $tmp "path1" @("next.txt")
$recovered = @(Read-DroppedDeletes $tmp "path1" -Claim | ForEach-Object { $_.Rel } | Sort-Object)
Clear-DroppedDeletes $tmp "path1" -All
Check "Abgestürzter Konsument: next.txt + orphan.txt" `
    ($recovered.Count -eq 2 -and $recovered[0] -eq 'next.txt' -and $recovered[1] -eq 'orphan.txt') ($recovered -join ', ')

$topmost = @(Select-TopmostPaths @("a/b", "a/b/c.txt", "a/b/sub/d.txt", "a/bc.txt", "d", "A/B/x.txt") | Sort-Object)
Check "Zusammenfassen auf gelöschte Ordner" (($topmost -join '|') -eq 'a/b|a/bc.txt|d') ($topmost -join '|')
$topWin = @(Select-TopmostPaths @("a\b", "a\b\c.txt", "e.txt") '\' | Sort-Object)
Check "Zusammenfassen mit Backslash-Pfaden" (($topWin -join '|') -eq 'a\b|e.txt') ($topWin -join '|')

# ============================================================================
Write-Host "`n--- Teil 2: Replay gegen echtes rclone bisync ---"
Write-Host "rclone:  $rclone"
Write-Host "scratch: $root"

function New-Scratch {
    $s = [pscustomobject]@{
        P1 = Join-Path $root "path1"; P2 = Join-Path $root "path2"
        Work = Join-Path $root "work"; State = Join-Path $root "state"
        Log = Join-Path $root "bisync.log"; Lines = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($d in @($s.P1, $s.P2, $s.Work, $s.State)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
        New-Item -ItemType Directory -Force $d | Out-Null
    }
    1..3 | ForEach-Object { Set-Content (Join-Path $s.P1 "alt-$_.txt") "content $_" -NoNewline }
    & $rclone bisync $s.P1 $s.P2 --resync --workdir $s.Work --log-level INFO --log-file $s.Log | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "resync failed with $LASTEXITCODE - see $($s.Log)" }
    $s
}

# the watcher's realtime upload: present on both sides, in no baseline
function Add-Both($s, [string]$rel, [string]$text = "created between two nightly runs") {
    $a = Join-Path $s.P1 $rel
    $b = Join-Path $s.P2 $rel
    New-Item -ItemType Directory -Force (Split-Path $a -Parent), (Split-Path $b -Parent) | Out-Null
    Set-Content -LiteralPath $a $text -NoNewline
    Copy-Item -LiteralPath $a $b
    # rclone compares modtimes; the "upload" must not look newer than the source
    (Get-Item -LiteralPath $b).LastWriteTimeUtc = (Get-Item -LiteralPath $a).LastWriteTimeUtc
}

function Invoke-Bisync($s) {
    # stdout must not leak into the return value
    & $rclone bisync $s.P1 $s.P2 --workdir $s.Work --log-level INFO --log-file $s.Log | Out-Null
    $LASTEXITCODE
}

function Invoke-Replay($s, [string]$side, [switch]$DryRun, $Rules = $null, [string]$Scope = "", [string]$Remote = "") {
    $captured = $s.Lines
    Invoke-JournalledDeletes -Side $side -LocalRoot $s.P1 -Remote $(if ($Remote) { $Remote } else { $s.P2 }) `
        -StateDir $s.State -RcloneExe $rclone -Rules $Rules -Scope $Scope -DryRun:$DryRun `
        -Log { param($m) $captured.Add($m) } `
        -Recycle { param($p) Remove-Item -LiteralPath $p -Recurse -Force; 0 }
}
function On1($s, $rel) { Test-Path -LiteralPath (Join-Path $s.P1 $rel) }
function On2($s, $rel) { Test-Path -LiteralPath (Join-Path $s.P2 $rel) }
function Pending($s, $side) { @(Read-DroppedDeletes $s.State $side).Count }

# --- A: no replay - the bug ----------------------------------------------------
$s = New-Scratch
Add-Both $s "neu.txt"
Remove-Item (Join-Path $s.P1 "neu.txt")
$exit = Invoke-Bisync $s
Check "A) ohne Replay kippt die Löschung zur Wiederherstellung (Vorfall 05.09.)" ($exit -eq 0 -and (On1 $s "neu.txt") -and (On2 $s "neu.txt"))

# --- B: path1, a file and a whole tree -----------------------------------------
$s = New-Scratch
Add-Both $s "neu.txt"; Add-Both $s "tree\a.txt"; Add-Both $s "tree\sub\b.txt"
Remove-Item (Join-Path $s.P1 "neu.txt"); Remove-Item (Join-Path $s.P1 "tree") -Recurse
Add-DroppedDeletes $s.State "path1" @("neu.txt", "tree", "tree\a.txt")
$r = Invoke-Replay $s "path1"
$gone2 = -not (On2 $s "neu.txt") -and -not (On2 $s "tree\a.txt") -and -not (On2 $s "tree\sub\b.txt")
Check "B) path1: Datei und Ordner auf der Gegenseite gelöscht, Journal geleert" `
    ($r.Ok -and $r.Done -eq 3 -and $r.Pending -eq 2 -and $gone2 -and (Pending $s "path1") -eq 0) "done=$($r.Done) pending=$($r.Pending)"
$exit = Invoke-Bisync $s
Check "B) danach bringt bisync nichts zurück, Altbestand bleibt" `
    ($exit -eq 0 -and -not (On1 $s "neu.txt") -and -not (On1 $s "tree\a.txt") -and (On1 $s "alt-1.txt") -and (On2 $s "alt-1.txt"))

# --- C: path1, the surviving copy changed after our delete -----------------------
$s = New-Scratch
Add-Both $s "neu.txt"
Remove-Item (Join-Path $s.P1 "neu.txt")
Add-DroppedDeletes $s.State "path1" @("neu.txt")
Start-Sleep -Milliseconds 2100   # the bound has a second of slack
Add-Content (Join-Path $s.P2 "neu.txt") " changed on another device" -NoNewline
$r = Invoke-Replay $s "path1"
$exit = Invoke-Bisync $s
Check "C) path1: Fremdänderung nach der Löschung bleibt und kommt zurück" `
    ($r.Ok -and $r.Done -eq 0 -and $r.Kept -eq 1 -and $exit -eq 0 -and (On2 $s "neu.txt") -and (On1 $s "neu.txt")) "kept=$($r.Kept)"

# --- D: path1, recreated locally --------------------------------------------------
$s = New-Scratch
Add-Both $s "neu.txt"
Add-DroppedDeletes $s.State "path1" @("neu.txt")
$r = Invoke-Replay $s "path1"
Check "D) path1: lokal wieder vorhanden - Eintrag verfällt, nichts gelöscht" `
    ($r.Ok -and $r.Pending -eq 0 -and $r.Done -eq 0 -and (On2 $s "neu.txt") -and (Pending $s "path1") -eq 0)

# --- E: dry run -----------------------------------------------------------------------
$s = New-Scratch
Add-Both $s "neu.txt"
Remove-Item (Join-Path $s.P1 "neu.txt")
Add-DroppedDeletes $s.State "path1" @("neu.txt")
$r1 = Invoke-Replay $s "path1" -DryRun
$r2 = Invoke-Replay $s "path1" -DryRun
$claimLeft = Test-Path (Get-DeleteClaimPath $s.State "path1")
$said = @($s.Lines | Where-Object { $_ -match 'DRYRUN would trash in the cloud: neu\.txt' }).Count
Check "E) Trockenlauf, zweimal: nichts gelöscht, Journal unberührt, Bericht da" `
    ($r1.Ok -and $r2.Ok -and $r1.Done -eq 0 -and (On2 $s "neu.txt") -and (Pending $s "path1") -eq 1 -and -not $claimLeft -and $said -eq 2) "gemeldet=$said"

# --- F: path2, a file and a whole tree -------------------------------------------
$s = New-Scratch
Add-Both $s "neu.txt"; Add-Both $s "tree\a.txt"; Add-Both $s "tree\sub\b.txt"
Remove-Item (Join-Path $s.P2 "neu.txt"); Remove-Item (Join-Path $s.P2 "tree") -Recurse
Add-DroppedDeletes $s.State "path2" @("neu.txt", "tree")
$r = Invoke-Replay $s "path2"
Check "F) path2: lokale Datei und lokaler Ordner entfernt, Journal geleert" `
    ($r.Ok -and $r.Done -eq 2 -and -not (On1 $s "neu.txt") -and -not (On1 $s "tree") -and (Pending $s "path2") -eq 0) "done=$($r.Done)"
$exit = Invoke-Bisync $s
Check "F) danach lädt bisync nichts wieder hoch" ($exit -eq 0 -and -not (On2 $s "neu.txt") -and -not (On2 $s "tree\a.txt") -and (On2 $s "alt-1.txt"))

# --- G: path2, local copy changed after the cloud delete; one file of a tree ----
$s = New-Scratch
Add-Both $s "neu.txt"; Add-Both $s "tree\a.txt"; Add-Both $s "tree\b.txt"
Remove-Item (Join-Path $s.P2 "neu.txt"); Remove-Item (Join-Path $s.P2 "tree") -Recurse
Add-DroppedDeletes $s.State "path2" @("neu.txt", "tree")
Start-Sleep -Milliseconds 2100
Add-Content (Join-Path $s.P1 "neu.txt") " edited here" -NoNewline
Add-Content (Join-Path $s.P1 "tree\b.txt") " edited here" -NoNewline
$r = Invoke-Replay $s "path2"
Check "G) path2: lokal Geändertes bleibt, der Rest des Ordners geht einzeln" `
    ($r.Ok -and $r.Kept -eq 2 -and $r.Done -eq 1 -and (On1 $s "neu.txt") -and (On1 $s "tree\b.txt") -and -not (On1 $s "tree\a.txt")) "kept=$($r.Kept) done=$($r.Done)"

# --- H: path2, live in the cloud again ------------------------------------------------
$s = New-Scratch
Add-Both $s "neu.txt"
Add-DroppedDeletes $s.State "path2" @("neu.txt")
$r = Invoke-Replay $s "path2"
Check "H) path2: in der Cloud wieder vorhanden - lokale Kopie bleibt" ($r.Ok -and $r.Done -eq 0 -and (On1 $s "neu.txt"))

# --- I: the other side cannot be reached ---------------------------------------------
$s = New-Scratch
Add-Both $s "neu.txt"
Remove-Item (Join-Path $s.P1 "neu.txt")
Add-DroppedDeletes $s.State "path1" @("neu.txt")
$r = Invoke-Replay $s "path1" -Remote "drive-sync-test-no-such-remote:"
Check "I) Gegenseite nicht erreichbar: Fehler gemeldet, Stapel bleibt erhalten" `
    (-not $r.Ok -and $r.Error -and (On2 $s "neu.txt") -and (Pending $s "path1") -eq 1) $r.Error
Add-DroppedDeletes $s.State "path1" @("alt-9.txt")   # the watcher keeps journalling meanwhile
$r = Invoke-Replay $s "path1"
Check "I) der nächste Lauf holt den Stapel nach" ($r.Ok -and $r.Journalled -eq 2 -and $r.Done -eq 1 -and -not (On2 $s "neu.txt") -and (Pending $s "path1") -eq 0)

# --- J: filters and scope ------------------------------------------------------------
$s = New-Scratch
$filterFile = Join-Path $root "filters-test.txt"
Set-Content $filterFile @("- *.tmp", "- cache/**")
$rules = Get-ExcludeRules $filterFile
Add-Both $s "one\a.txt"; Add-Both $s "one\x.tmp"; Add-Both $s "two\b.txt"; Add-Both $s "two\cache\c.txt"
Remove-Item (Join-Path $s.P1 "one") -Recurse; Remove-Item (Join-Path $s.P1 "two") -Recurse
Add-DroppedDeletes $s.State "path1" @("one\a.txt", "one\x.tmp", "two")
$r = Invoke-Replay $s "path1" -Rules $rules -Scope "one"
Check "J) Scope: nur der Teilbaum, Ausgeschlossenes bleibt, Journal unberührt" `
    ($r.Ok -and $r.Done -eq 1 -and -not (On2 $s "one\a.txt") -and (On2 $s "one\x.tmp") -and (On2 $s "two\b.txt") -and (Pending $s "path1") -eq 3) "done=$($r.Done)"
$r = Invoke-Replay $s "path1" -Rules $rules
Check "J) ohne Scope: Ordner gelöscht bis auf Ausgeschlossenes" `
    ($r.Ok -and $r.Done -eq 1 -and -not (On2 $s "two\b.txt") -and (On2 $s "two\cache\c.txt") -and (On2 $s "one\x.tmp") -and (Pending $s "path1") -eq 0) "done=$($r.Done)"

if ($Keep) { Write-Host "`nscratch behalten: $root" }
else { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:failed -eq 0) { Write-Host "`nALLES PASS"; exit 0 }
Write-Host "`nFEHLGESCHLAGEN: $($script:failed)"
exit 1
