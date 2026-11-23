# Tests for the guards in recycle-bin.ps1 (Move-ToRecycleBin): a cloud signal
# must never take a local item that only matches in another letter case, nor
# a large folder in one go. Re-enacts 2026-11-22: "archiv" trashed in the
# cloud took the local "Archiv". Local only, scratch folder under TEMP; the
# two small items it does recycle end up in the Windows recycle bin.
#
#   pwsh -File test-recycle-guard.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
$DriveSyncConfig.RecycleFolderMaxFiles = 5
. (Join-Path $PSScriptRoot "recycle-bin.ps1")

$script:failed = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    Write-Host ("{0} - {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { " [$detail]" } else { "" }))
    if (-not $ok) { $script:failed++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "drive-sync-recycle-guard-test"
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
$archiv = Join-Path $root "Archiv"
New-Item -ItemType Directory -Force (Join-Path $archiv "Backup 2012") | Out-Null
1..3 | ForEach-Object { Set-Content (Join-Path $archiv "Backup 2012\f$_.txt") "x" }
try {
    Check "Test-ExactPath: exact spelling" (Test-ExactPath $archiv)
    Check "Test-ExactPath: another letter case is not the same path" (-not (Test-ExactPath (Join-Path $root "archiv")))
    Check "Test-ExactPath: missing path" (-not (Test-ExactPath (Join-Path $root "nope")))

    $rc = Move-ToRecycleBin (Join-Path $root "archiv")
    Check "the 2026-11-22 case: 'archiv' does not take 'Archiv'" ($rc -eq $script:RecycleRefusedCase -and (Test-Path (Join-Path $archiv "Backup 2012\f1.txt"))) "rc=$rc"
    $rc = Move-ToRecycleBin (Join-Path $root "Archiv\backup 2012\f1.txt")
    Check "a case mismatch deeper down is refused as well" ($rc -eq $script:RecycleRefusedCase -and (Test-Path (Join-Path $archiv "Backup 2012\f1.txt"))) "rc=$rc"

    4..9 | ForEach-Object { Set-Content (Join-Path $archiv "Backup 2012\f$_.txt") "x" }
    $rc = Move-ToRecycleBin $archiv
    Check "a folder over the limit (9 files, limit 5) is refused" ($rc -eq $script:RecycleRefusedSize -and (Test-Path $archiv)) "rc=$rc"

    $rc = Move-ToRecycleBin (Join-Path $archiv "Backup 2012\f1.txt")
    Check "a file in the exact spelling is recycled" ($rc -eq 0 -and -not (Test-Path (Join-Path $archiv "Backup 2012\f1.txt"))) "rc=$rc"
    $small = Join-Path $root "Klein"
    New-Item -ItemType Directory -Force $small | Out-Null
    1..2 | ForEach-Object { Set-Content (Join-Path $small "k$_.txt") "x" }
    $rc = Move-ToRecycleBin $small
    Check "a small folder in the exact spelling is recycled" ($rc -eq 0 -and -not (Test-Path $small)) "rc=$rc"
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:failed -eq 0) { Write-Host "`nALL PASS"; exit 0 }
Write-Host "`nFAILED: $($script:failed)"
exit 1
