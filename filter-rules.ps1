# Shared exclude logic for the drive-sync watchers, DERIVED FROM filters.txt
# (single source of truth). Dot-source this file, then:
#   $rules = Get-ExcludeRules (Join-Path $PSScriptRoot "filters.txt")
#   if (Test-Excluded $rules "some\relative\path.txt") { ... }

function Get-ExcludeRules([string]$filtersFile) {
    $rules = @{
        Dirs     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Exts     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Names    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Prefixes = @()
        # "*.workflow.lock": a literal name ending with more than one dot,
        # which the extension rule below does not take. Until 2026-11-10 such
        # a line matched no branch and was dropped without a word.
        Suffixes = @()
        # "/a/b/**": one subtree, anchored at the root. Until 2026-11-07 these
        # landed in Dirs as "/a/b", matched no single segment, and the
        # watchers synced what bisync excluded.
        Anchored = @()
    }
    foreach ($line in Get-Content $filtersFile) {
        if ($line -notmatch '^\s*-\s+(.+)$') { continue }
        $pat = $Matches[1].Trim()
        if ($pat -match '^/(.+)/\*\*$') {
            # rclone escapes [ and ] in patterns; the path itself has none
            $rules.Anchored += (($Matches[1] -replace '\\([\[\]])', '$1') -replace '/', '\')
        }
        elseif ($pat -match '^(.+)/\*\*$') { [void]$rules.Dirs.Add($Matches[1]) }
        elseif ($pat -match '^\*(\.[A-Za-z0-9]+)$') { [void]$rules.Exts.Add($Matches[1]) }
        elseif ($pat -match '^\*([^/*?\[\]{}]+)$') { $rules.Suffixes += $Matches[1] }
        elseif ($pat.EndsWith('*')) { $rules.Prefixes += $pat.TrimEnd('*') }
        elseif ($pat -notmatch '[\*\[\]]') { [void]$rules.Names.Add($pat) }
    }
    return $rules
}

function Test-Excluded($rules, [string]$relPath) {
    foreach ($a in $rules.Anchored) {
        if ($relPath.StartsWith("$a\", [System.StringComparison]::OrdinalIgnoreCase) -or $relPath -ieq $a) { return $true }
    }
    $segs = $relPath -split '\\'
    for ($i = 0; $i -lt $segs.Count - 1; $i++) { if ($rules.Dirs.Contains($segs[$i])) { return $true } }
    $base = $segs[-1]
    if ($rules.Names.Contains($base)) { return $true }
    $ext = [System.IO.Path]::GetExtension($base)
    if ($ext -and $rules.Exts.Contains($ext)) { return $true }
    foreach ($p in $rules.Prefixes) { if ($base.StartsWith($p)) { return $true } }
    # ordinal and case-sensitive, as rclone reads the pattern
    foreach ($s in $rules.Suffixes) { if ($base.EndsWith($s, [System.StringComparison]::Ordinal)) { return $true } }
    return $false
}
