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
    }
    foreach ($line in Get-Content $filtersFile) {
        if ($line -notmatch '^\s*-\s+(.+)$') { continue }
        $pat = $Matches[1].Trim()
        if ($pat -match '^(.+)/\*\*$') { [void]$rules.Dirs.Add($Matches[1]) }
        elseif ($pat -match '^\*(\.[A-Za-z0-9]+)$') { [void]$rules.Exts.Add($Matches[1]) }
        elseif ($pat.EndsWith('*')) { $rules.Prefixes += $pat.TrimEnd('*') }
        elseif ($pat -notmatch '[\*\[\]]') { [void]$rules.Names.Add($pat) }
    }
    return $rules
}

function Test-Excluded($rules, [string]$relPath) {
    $segs = $relPath -split '\\'
    for ($i = 0; $i -lt $segs.Count - 1; $i++) { if ($rules.Dirs.Contains($segs[$i])) { return $true } }
    $base = $segs[-1]
    if ($rules.Names.Contains($base)) { return $true }
    $ext = [System.IO.Path]::GetExtension($base)
    if ($ext -and $rules.Exts.Contains($ext)) { return $true }
    foreach ($p in $rules.Prefixes) { if ($base.StartsWith($p)) { return $true } }
    return $false
}
