# Analyzes the sync corpus: counts dirs/files/bytes per top-level directory.
# Uses robocopy in list-only mode (/L) so nothing is copied or modified.
# Junctions/symlinks are excluded (/XJ) to avoid cycles and double counting.
# Idempotent: read-only apart from the output file, safe to re-run anytime.

param(
    [string]$SourceRoot = "D:\Meine Ablage",
    [string]$OutFile = "$env:TEMP\corpus-analysis.csv"
)

$ErrorActionPreference = "Stop"
$dummyDest = Join-Path $env:TEMP "rc-null-$PID"

function Get-RobocopyStats {
    param([string]$Path, [switch]$TopLevelOnly)
    $rcArgs = @($Path, $dummyDest, "/L", "/XJ", "/NFL", "/NDL", "/NJH", "/BYTES", "/R:0", "/W:0")
    $rcArgs += if ($TopLevelOnly) { "/LEV:1" } else { "/E" }
    $out = & robocopy @rcArgs 2>$null
    $stats = [ordered]@{ Dirs = 0; Files = 0; Bytes = 0 }
    foreach ($line in $out) {
        # Summary lines look like (localized): "Verzeich.:  1 ..." / "  Dateien:  1234 ..." / "  Files :  1234 ..."
        if ($line -match '^\s*(Verzeich\S*|Dirs)\s*:\s*(\d+)') { $stats.Dirs = [long]$Matches[2] }
        elseif ($line -match '^\s*(Dateien|Files)\s*:\s*(\d+)') { $stats.Files = [long]$Matches[2] }
        elseif ($line -match '^\s*Bytes\s*:\s*(\d+)') { $stats.Bytes = [long]$Matches[1] }
    }
    [pscustomobject]$stats
}

$results = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Root-level files (not inside any top-level dir)
$rootStats = Get-RobocopyStats -Path $SourceRoot -TopLevelOnly
$results += [pscustomobject]@{ TopLevel = "<root files>"; Dirs = 0; Files = $rootStats.Files; Bytes = $rootStats.Bytes; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }

foreach ($dir in Get-ChildItem -LiteralPath $SourceRoot -Directory -Force) {
    if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $results += [pscustomobject]@{ TopLevel = "$($dir.Name) <reparse point, skipped>"; Dirs = 0; Files = 0; Bytes = 0; Seconds = 0 }
        continue
    }
    $t0 = $sw.Elapsed.TotalSeconds
    $stats = Get-RobocopyStats -Path $dir.FullName
    $results += [pscustomobject]@{
        TopLevel = $dir.Name
        Dirs     = $stats.Dirs
        Files    = $stats.Files
        Bytes    = $stats.Bytes
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds - $t0, 1)
    }
    # Write incrementally so partial progress is visible while running
    $results | Sort-Object Files -Descending | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
}

$results | Sort-Object Files -Descending | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
if (Test-Path $dummyDest) { Remove-Item -LiteralPath $dummyDest -Recurse -Force -Confirm:$false }

$total = [pscustomobject]@{
    TopLevels = $results.Count
    Files     = ($results | Measure-Object Files -Sum).Sum
    GB        = [math]::Round((($results | Measure-Object Bytes -Sum).Sum) / 1GB, 2)
    Minutes   = [math]::Round($sw.Elapsed.TotalMinutes, 1)
}
"DONE $($total | ConvertTo-Json -Compress)"
$results | Sort-Object Files -Descending | Format-Table TopLevel, Dirs, Files, @{n='GB';e={[math]::Round($_.Bytes/1GB,2)}} -AutoSize
