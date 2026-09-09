# End-to-end reproduction of the 2026-09-05 resurrection, and the proof that a
# splice is the right medicine. Runs a REAL rclone bisync - between two scratch
# directories under TEMP, with its own --workdir and its own state dir. It never
# touches the corpus, the cloud, the real baselines or a running watcher.
#
# The scenario, both times identical up to the splice:
#   1. a small corpus on both sides, --resync writes the baseline
#   2. a new file appears on BOTH sides without bisync knowing - this is the
#      watcher's realtime upload between two nightly runs, and the reason the
#      file is in neither baseline
#   3. it is deleted on path1 and the delete lands in the journal instead of
#      being executed - the MaxDeletes cap
#   4. bisync runs
#
# Without the splice, step 4 copies the file back: bisync sees it on one side
# only, and its baseline says it never existed, so "new on path2" is the only
# reading available. With the two spliced lines it reads "deleted on path1" and
# propagates the deletion. That difference is the whole point of stage 3.
# C changes the surviving copy after the delete: the lookup must refuse it,
# because a line built from the new values would erase that change silently.
#
#   pwsh -File test-splice-e2e.ps1          run all three scenarios
#   pwsh -File test-splice-e2e.ps1 -Keep    leave the scratch dirs for a look

param([switch]$Keep)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "bisync-index.ps1")

# same resolution as the watchers: custom build if deployed, else PATH
$rclone = Join-Path $DriveSyncConfig.StateDir "bin\rclone.exe"
if (-not (Test-Path $rclone)) { $rclone = "rclone" }

$root = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-e2e"
$testFile = "neu.txt"

# --- the listing line, exactly as rclone writes it ---------------------------
# "-<size right-aligned to 9> - - <RFC3339, 9 fractional digits> "<path>""
function New-ListingLine([long]$size, [datetime]$mtime, [string]$rel) {
    $ts = $mtime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffff") + "00+0000"
    "-{0,9} - - {1} `"{2}`"" -f $size, $ts, $rel
}

# Insert one entry and keep the file sorted the way rclone sorts it. Reading,
# adding and rewriting is what stage 3 will do - prototyped here so the test
# proves the format before any production code depends on it.
function Add-ListingEntry([string]$listing, [string]$rel, [long]$size, [datetime]$mtime) {
    # Hard stop before writing: the first version of this test resolved the
    # listings through Get-BisyncWorkDir, which answers with the REAL workdir
    # unless BisyncWorkDir is set - and rewrote the 212 MB production baseline
    # (2026-09-08). No scratch path, no write.
    if (-not $listing.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to touch a listing outside the scratch root: $listing"
    }
    $lines = @(Get-Content $listing)
    $header = @($lines | Where-Object { $_.StartsWith("#") })
    $entries = @($lines | Where-Object { -not $_.StartsWith("#") -and $_.Length -gt 0 })
    $entries += New-ListingLine $size $mtime $rel
    $key = { param($l) $l.Substring($l.IndexOf('"') + 1, $l.LastIndexOf('"') - $l.IndexOf('"') - 1) }
    $sorted = @($entries | Sort-Object -Property @{ Expression = { & $key $_ } } -CaseSensitive)
    # LF, and UTF-8 without BOM. rclone rejects any line ending in \r with
    # "Ignoring incorrect line" - every line at once, which leaves it with an
    # empty prior listing and a critical abort. Set-Content writes CRLF.
    $sw = [System.IO.StreamWriter]::new($listing, $false, [System.Text.UTF8Encoding]::new($false))
    $sw.NewLine = "`n"
    foreach ($l in (@($header) + $sorted)) { $sw.WriteLine($l) }
    $sw.Dispose()
}

function Invoke-Scenario([string]$label, [bool]$splice, [bool]$touchP2 = $false) {
    $p1 = Join-Path $root "path1"
    $p2 = Join-Path $root "path2"
    $work = Join-Path $root "work"
    $state = Join-Path $root "state"
    foreach ($d in @($p1, $p2, $work, $state)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
        New-Item -ItemType Directory -Force $d | Out-Null
    }
    $log = Join-Path $root "bisync.log"
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    # this is what keeps Get-BisyncListings inside the scratch: without it the
    # helpers answer with the machine's real bisync workdir
    $DriveSyncConfig.BisyncWorkDir = $work

    # 1) corpus + baseline
    1..5 | ForEach-Object { Set-Content (Join-Path $p1 "alt-$_.txt") "content $_" -NoNewline }
    & $rclone bisync $p1 $p2 --resync --workdir $work --log-level INFO --log-file $log | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "resync failed with $LASTEXITCODE - see $log" }

    # 2) the watcher's realtime upload: present on both sides, in no baseline
    $abs1 = Join-Path $p1 $testFile
    Set-Content $abs1 "created between two nightly runs" -NoNewline
    $info = Get-Item $abs1
    Copy-Item $abs1 (Join-Path $p2 $testFile)
    # rclone compares modtimes; the "upload" must not look newer than the source
    (Get-Item (Join-Path $p2 $testFile)).LastWriteTimeUtc = $info.LastWriteTimeUtc

    # 3) deleted locally, dropped at the cap, journalled
    Remove-Item $abs1
    Add-DroppedDeletes $state "path1" @($testFile)

    # 3b) another device changes the surviving copy AFTER our delete. The
    #     journal time is the only bound we have for that, and the lookup
    #     allows a second of slack for two unsynchronised clocks.
    if ($touchP2) {
        Start-Sleep -Milliseconds 2100
        Add-Content (Join-Path $p2 $testFile) " changed on another device" -NoNewline
    }

    # 4) the report - peeking, so the journal survives for the splice below
    $rep = @(Write-SpliceReport $p1 $p2 $state $rclone -Peek)
    $ready = if ($rep.Count -gt 0) { @($rep[0].Ready) } else { @() }
    $usable = if ($rep.Count -gt 0) { $rep[0].Splice } else { @{} }
    $conflict = if ($rep.Count -gt 0) { $rep[0].Conflict } else { 0 }

    # 5) the splice, or not
    if ($splice) {
        $listings = Get-BisyncListings $p1 $p2
        if (-not $listings) { throw "no listings in $work" }
        # size and modtime come from the report's lookup, not from $info: the
        # production splice will only ever have the surviving copy to ask
        $md = $usable[$testFile]
        if (-not $md) { throw "no usable metadata for $testFile" }
        foreach ($l in @($listings.Path1, $listings.Path2)) {
            Add-ListingEntry $l $testFile $md.Size $md.ModTime
        }
    }

    # 6) the nightly run
    # stdout must not leak into the return value: the caller would get an
    # array, and [bool]@(0) is $false - a green run then reads as FAIL
    & $rclone bisync $p1 $p2 --workdir $work --log-level INFO --log-file $log | Out-Null
    $exit = $LASTEXITCODE

    [pscustomobject]@{
        Label      = $label
        Exit       = $exit
        Ready      = $ready
        Usable     = $usable.Count
        Conflict   = $conflict
        BackOnP1   = Test-Path (Join-Path $p1 $testFile)
        StillOnP2  = Test-Path (Join-Path $p2 $testFile)
        Log        = $log
    }
}

Write-Host "rclone:  $rclone"
Write-Host "scratch: $root`n"

# --- A: today's behaviour, the bug ------------------------------------------
$a = Invoke-Scenario "ohne Splice" $false
Write-Host "A) ohne Splice"
Write-Host "   Bericht wuerde spleissen: $($a.Ready -join ', ')"
Write-Host "   nach dem bisync: auf path1 wieder da = $($a.BackOnP1), auf path2 noch da = $($a.StillOnP2)"
# @() at the point of use: a single-element collection read back from a
# property collapses to the scalar, and "neu.txt"[0] is the letter n
$readyA = @($a.Ready)
$okA = $a.Exit -eq 0 -and $readyA.Count -eq 1 -and $readyA[0] -eq $testFile -and $a.Usable -eq 1 -and $a.BackOnP1 -and $a.StillOnP2
Write-Host "$(if ($okA) { 'PASS' } else { 'FAIL' }) - der Vorfall vom 05.09. reproduziert: die Loeschung kippt zur Wiederherstellung`n"

# --- B: with the two spliced lines ------------------------------------------
$b = Invoke-Scenario "mit Splice" $true
Write-Host "B) mit Splice"
Write-Host "   nach dem bisync: auf path1 wieder da = $($b.BackOnP1), auf path2 noch da = $($b.StillOnP2)"
$okB = $b.Exit -eq 0 -and -not $b.BackOnP1 -and -not $b.StillOnP2
Write-Host "$(if ($okB) { 'PASS' } else { 'FAIL' }) - die Loeschung wird propagiert, nichts kommt zurueck`n"

# --- C: the surviving copy was changed elsewhere after our delete ------------
# The whole reason the line must describe the file AS UPLOADED. Built from the
# current values instead, it would tell bisync "unchanged on path2" and the
# foreign change would be deleted without a trace.
$c = Invoke-Scenario "Fremdaenderung" $false $true
Write-Host "C) Fremdaenderung an der ueberlebenden Kopie"
Write-Host "   brauchbar = $($c.Usable), als Konflikt erkannt = $($c.Conflict), auf path2 noch da = $($c.StillOnP2)"
$okC = $c.Usable -eq 0 -and $c.Conflict -eq 1 -and $c.StillOnP2
Write-Host "$(if ($okC) { 'PASS' } else { 'FAIL' }) - nichts zu spleissen, die fremde Aenderung bleibt`n"

if ($Keep) { Write-Host "scratch behalten: $root" }
else { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

if ($okA -and $okB -and $okC) { Write-Host "ALLES PASS"; exit 0 }
Write-Host "FEHLGESCHLAGEN"
exit 1
