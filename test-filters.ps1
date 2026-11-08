# Checks that the watchers' exclude logic (filter-rules.ps1) agrees with
# rclone's reading of filters.txt - rclone is the oracle, bisync uses it.
#
# Until 2026-11-07 the two disagreed on every anchored rule ("/a/b/**"): the
# watchers matched rules against single path segments only and synced 66
# subtrees that bisync excluded. Nobody noticed, because no test compared them.
#
# For every "- pattern" line one sample file is built that the rule should
# exclude, plus a near miss for folder rules ("x/namex/f.txt" next to
# "x/name/f.txt"). rclone lists the scratch tree through filters.txt; whatever
# it leaves out is excluded. Each sample must get the same answer from
# Test-Excluded. Patterns that cannot be turned into a sample (inner wildcards)
# are reported as skipped. Local only, no cloud access.
#
#   pwsh -File test-filters.ps1
#   pwsh -File test-filters.ps1 -RulesScript <older filter-rules.ps1>   # regression check

param([string]$RulesScript = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
if (-not $RulesScript) { $RulesScript = Join-Path $PSScriptRoot "filter-rules.ps1" }
. $RulesScript
$filters = Join-Path $PSScriptRoot "filters.txt"
$rules = Get-ExcludeRules $filters
$rcloneExe = Join-Path $DriveSyncConfig.StateDir "bin\rclone.exe"
if (-not (Test-Path $rcloneExe)) { $rcloneExe = "rclone" }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("filters-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$samples = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
$ruleCount = 0
function Add-Sample([string]$rule, [string]$rel) { $samples.Add([pscustomobject]@{ Rule = $rule; Rel = $rel }) }

foreach ($line in Get-Content $filters) {
    if ($line -notmatch '^\s*-\s+(.+)$') { continue }
    $pat = $Matches[1].Trim()
    $ruleCount++
    $plain = $pat -replace '\\([\[\]])', '$1'   # rclone escapes [ and ]
    if ($pat -match '^/(.+)/\*\*$') {
        $p = ($Matches[1] -replace '\\([\[\]])', '$1') -replace '/', '\'
        Add-Sample $pat "$p\sample.txt"
        Add-Sample $pat "$p-near\sample.txt"
    }
    elseif ($pat -match '^([^/*?\[]+)/\*\*$') {
        Add-Sample $pat "x\$($Matches[1])\sample.txt"
        Add-Sample $pat "x\$($Matches[1])near\sample.txt"
    }
    elseif ($pat -match '^\*(\.[A-Za-z0-9]+)$') { Add-Sample $pat "x\sample$($Matches[1])" }
    elseif ($pat -match '^([^/*?\[]+)\*$') { Add-Sample $pat "x\$($Matches[1])sample" }
    elseif ($plain -notmatch '[\*\?\[\]/]') { Add-Sample $pat "x\$plain" }
    else { $skipped.Add($pat) }
}
# controls nothing should exclude
Add-Sample "(control)" "x\plain-file.txt"
Add-Sample "(control)" "Develop\project\src\app.js"

$failures = 0
try {
    foreach ($s in $samples) {
        $abs = Join-Path $scratch $s.Rel
        New-Item -ItemType Directory -Force (Split-Path $abs -Parent) | Out-Null
        [IO.File]::WriteAllText($abs, "x")
    }
    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in (& $rcloneExe lsf -R --files-only --filter-from $filters $scratch 2>$null)) { [void]$listed.Add(($p -replace '/', '\')) }
    if ($LASTEXITCODE -ne 0) { throw "rclone lsf failed (exit $LASTEXITCODE)" }
    foreach ($s in $samples) {
        $rclone = -not $listed.Contains($s.Rel)
        $ours = Test-Excluded $rules $s.Rel
        if ($rclone -ne $ours) {
            $failures++
            Write-Host ("FAIL  {0,-60} rclone={1,-5} watchers={2,-5} ({3})" -f $s.Rel, $rclone, $ours, $s.Rule)
        }
    }
}
finally { if (Test-Path $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }

Write-Host "$($samples.Count) sample(s) from $ruleCount rule(s), $($skipped.Count) skipped (inner wildcards)$(if ($skipped.Count) { ': ' + ($skipped -join ', ') })"
if ($failures -gt 0) { Write-Host "$failures disagreement(s)"; exit 1 }
Write-Host "all agree"
