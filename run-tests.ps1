# Runs every offline test (each test-*.ps1 without switches) and prints one
# line per test; the output of a failing one is shown in full. None of them
# touches the cloud, the real state directory or the mirror - they work in
# scratch folders under TEMP. The live cases stay manual (test-alerts.ps1
# -Live, test-pending-rename.ps1 -Live).
#
#   pwsh -File run-tests.ps1              all of them
#   pwsh -File run-tests.ps1 liveness     those whose name contains the word
#   pwsh -File run-tests.ps1 -IfStaged    only if the commit in the making
#                                         touches a script or filters.txt
#                                         (the pre-commit hook, install-git-hook.ps1)
#
# Exit code: 0 = all passed (or nothing to do), 1 = at least one failed.

param(
    [string]$Filter = "",
    [switch]$IfStaged
)

$ErrorActionPreference = "Stop"

if ($IfStaged) {
    $staged = @(& git -C $PSScriptRoot diff --cached --name-only --diff-filter=ACMR)
    if (-not ($staged -match '(\.ps1|^filters\.txt)$')) { exit 0 }
}

$tests = @(Get-ChildItem (Join-Path $PSScriptRoot "test-*.ps1") | Where-Object { $_.Name -like "*$Filter*" })
if ($tests.Count -eq 0) { Write-Host "no test matches '$Filter'"; exit 1 }

# side by side: each test is a process of its own with a scratch folder of its
# own, and one of them (a real bisync between two folders) takes 15 s
$total = [Diagnostics.Stopwatch]::StartNew()
$results = @($tests | ForEach-Object -ThrottleLimit 4 -Parallel {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $out = @(& pwsh -NoProfile -File $_.FullName 2>&1)
        [pscustomobject]@{ Name = $_.BaseName; Ok = ($LASTEXITCODE -eq 0); Seconds = $watch.Elapsed.TotalSeconds; Output = $out }
    } | Sort-Object Name)
$failed = 0
foreach ($r in $results) {
    Write-Host ("{0}  {1,-28} {2,5:N1} s" -f $(if ($r.Ok) { 'PASS' } else { 'FAIL' }), $r.Name, $r.Seconds)
    if (-not $r.Ok) {
        $failed++
        $r.Output | ForEach-Object { Write-Host "      $_" }
    }
}
Write-Host ("{0} of {1} test scripts passed in {2:N0} s" -f ($tests.Count - $failed), $tests.Count, $total.Elapsed.TotalSeconds)
exit $(if ($failed) { 1 } else { 0 })
