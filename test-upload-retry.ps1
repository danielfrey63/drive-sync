# Tests for the upload watcher's retry bookkeeping (upload-retry.ps1).
#
# Part 1 - the pure functions against log lines as rclone wrote them on
#          2026-11-06 (a locked file) and 2026-10-30 (no DNS).
# Part 2 - a REAL rclone copy between two scratch folders under TEMP with one
#          file held open exclusively: the log must name exactly that file as
#          failed and the others as copied. No cloud access.
#
#   pwsh -File test-upload-retry.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "upload-retry.ps1")

$rclone = Join-Path $DriveSyncConfig.StateDir "bin\rclone.exe"
if (-not (Test-Path $rclone)) { $rclone = "rclone" }

$script:failed = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    Write-Host ("{0} - {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { " [$detail]" } else { "" }))
    if (-not $ok) { $script:failed++ }
}

# ============================================================================
Write-Host "--- part 1: log parsing and delays ---"
$log = @(
    '2026/11/06 09:14:02 INFO  : Akros/Angebote/SECO/notes.md: Copied (replaced existing)'
    '2026/11/06 09:14:02 INFO  : Akros/Angebote/SECO/new.md: Copied (new)'
    '2026/11/06 09:14:03 ERROR : Akros/Angebote/SECO/20261106-0830 - AKROS - SECO.workflow.lock.guard: Failed to copy: Post "https://www.googleapis.com/upload/drive/v3/files?alt=json&uploadType=multipart": googleapi: Copy failed: read \\?\D:\Meine Ablage\Akros\Angebote\SECO\20261106-0830 - AKROS - SECO.workflow.lock.guard: Der Prozess kann nicht auf die Datei zugreifen, da sie von einem anderen Prozess verwendet wird.'
    '2026/11/06 09:14:03 ERROR : Attempt 1/1 failed with 1 errors and: Post "https://www.googleapis.com/upload/drive/v3/files": googleapi: Copy failed'
    '2026/11/06 09:14:03 INFO  : Akros/touched.md: Updated modification time in destination'
    '2026/11/06 09:14:03 ERROR : flaky.bin: Failed to copy: unexpected EOF'
    '2026/11/06 09:14:09 INFO  : flaky.bin: Copied (new)'
)
$o = Get-FlushOutcome $log
Check "copied: three paths with a line that says so, plus the one a retry got through" `
    ($o.Copied.Count -eq 4 -and $o.Copied.Contains('Akros\Angebote\SECO\notes.md') -and $o.Copied.Contains('Akros\touched.md') -and $o.Copied.Contains('flaky.bin')) "$($o.Copied.Count)"
$guard = 'Akros\Angebote\SECO\20261106-0830 - AKROS - SECO.workflow.lock.guard'
Check "failed: only the locked file, the summary line is no path" `
    ($o.Failed.Count -eq 1 -and $o.Failed.ContainsKey($guard)) "$(@($o.Failed.Keys) -join ' | ')"
Check "reason: the cause, without URL and path" `
    ($o.Failed[$guard] -eq 'Der Prozess kann nicht auf die Datei zugreifen, da sie von einem anderen Prozess verwendet wird.') $o.Failed[$guard]

$dns = @('2026/10/30 07:01:10 ERROR : Develop/sem/a.md: Failed to copy: couldn''t list directory: Get "https://www.googleapis.com/drive/v3/files?alt=json": dial tcp: lookup www.googleapis.com: no such host')
$o = Get-FlushOutcome $dns
Check "no DNS: the path is named as failed (the caller's probe tells network from file)" `
    ($o.Failed.Count -eq 1 -and $o.Failed['Develop\sem\a.md'] -eq 'no such host') "$(@($o.Failed.Values) -join ' | ')"
$o = Get-FlushOutcome @()
Check "empty log: nothing copied, nothing failed" ($o.Copied.Count -eq 0 -and $o.Failed.Count -eq 0)

$mins = @(1..8 | ForEach-Object { Get-UploadRetryMinutes $_ }) -join ','
Check "file delays: 1, 2, 4, 8, 16, then 30 min" ($mins -eq '1,2,4,8,16,30,30,30') $mins
$secs = @(1..7 | ForEach-Object { Get-UploadHoldSeconds $_ }) -join ','
Check "global holds: 15 s doubling, capped at 300 s" ($secs -eq '15,30,60,120,240,300,300') $secs

$parked = New-UploadParking
$t0 = [datetime]'2026-11-06T09:00:00'
$e = Add-UploadStrike $parked 'a\x.lock' 'locked' $t0
Check "first strike: due after 1 min, not before" `
    ($e.Strikes -eq 1 -and @(Get-DueUploads $parked $t0.AddSeconds(59)).Count -eq 0 -and @(Get-DueUploads $parked $t0.AddSeconds(60)) -contains 'a\x.lock')
$e = Add-UploadStrike $parked 'A\X.LOCK' 'still locked' $t0.AddMinutes(1)
Check "second strike on the same path (other case): one entry, 2 min, first failure kept" `
    ($parked.Count -eq 1 -and $e.Strikes -eq 2 -and $e.First -eq $t0 -and $e.Next -eq $t0.AddMinutes(3) -and $e.Reason -eq 'still locked')
[void](Add-UploadStrike $parked 'b\y.db' 'locked' $t0.AddMinutes(50))
$stuck = @(Get-StuckUploads $parked $t0.AddMinutes(61) 60)
Check "stuck after 60 min: the old one only" ($stuck.Count -eq 1 -and $stuck[0].Rel -eq 'a\x.lock') "$(@($stuck.Rel) -join ', ')"
[void]$parked.Remove('a\x.lock')
Check "uploaded in the end: entry gone, nothing stuck" (@(Get-StuckUploads $parked $t0.AddMinutes(61) 60).Count -eq 0 -and $parked.Count -eq 1)

# ============================================================================
Write-Host "--- part 2: real rclone copy with a locked file ---"
$root = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-upload-retry-test"
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
$src = Join-Path $root "src"; $dst = Join-Path $root "dst"
New-Item -ItemType Directory -Force (Join-Path $src "sub dir"), $dst | Out-Null
$rels = @('plain.txt', 'sub dir\Aufträge → Übersicht.md', 'sub dir\meeting.workflow.lock.guard')
foreach ($r in $rels) { [IO.File]::WriteAllText((Join-Path $src $r), "content of $r") }
$batchFile = Join-Path $root "batch.txt"
Set-Content -Path $batchFile -Value @($rels | ForEach-Object { $_.Replace('\', '/') }) -Encoding UTF8
$flushLog = Join-Path $root "flush.log"
$lock = [IO.File]::Open((Join-Path $src $rels[2]), 'Open', 'ReadWrite', 'None')
try {
    & $rclone copy $src $dst --files-from-raw $batchFile --no-traverse --retries 1 --log-level INFO --log-file $flushLog 2>$null
    $exit = $LASTEXITCODE
}
finally { $lock.Dispose() }
$o = Get-FlushOutcome @(Get-Content $flushLog)
Check "locked file: rclone exits non-zero" ($exit -ne 0) "exit=$exit"
Check "the two free files are reported as copied (umlauts and arrow intact)" `
    ($o.Copied.Count -eq 2 -and $o.Copied.Contains($rels[0]) -and $o.Copied.Contains($rels[1])) "$(@($o.Copied) -join ' | ')"
Check "the locked file is the only failure, with a reason" `
    ($o.Failed.Count -eq 1 -and $o.Failed.ContainsKey($rels[2]) -and $o.Failed[$rels[2]].Length -gt 5) "$(@($o.Failed.Values) -join ' | ')"
Check "the free files really arrived" ((Test-Path -LiteralPath (Join-Path $dst $rels[0])) -and (Test-Path -LiteralPath (Join-Path $dst $rels[1])))

& $rclone copy $src $dst --files-from-raw $batchFile --no-traverse --retries 1 --log-level INFO --log-file $flushLog 2>$null
$o = Get-FlushOutcome @(Get-Content $flushLog)
Check "lock released: the next run gets it through" ($LASTEXITCODE -eq 0 -and $o.Copied.Contains($rels[2]))

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($script:failed -eq 0) { Write-Host "`nALL PASS"; exit 0 }
Write-Host "`nFAILED: $($script:failed)"
exit 1
