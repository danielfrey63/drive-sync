# Exercises the watcher fix of 2026-10-22 (af21764): a file saved and renamed
# inside one debounce window must reach the cloud with its NEW content. Before
# the fix the flush dropped the pending upload of the vanished old path and the
# server-side move carried the cloud's stale content to the new name.
#
#   pwsh -File test-pending-rename.ps1          Move-PendingPaths only, offline
#   pwsh -File test-pending-rename.ps1 -Live    plus file and folder case against
#                                               the running upload watcher and
#                                               the cloud, in Temp\ of the mirror
#
# -Live needs a watcher past its start-up catch-up (restart-watchers.ps1 waits
# for that). It cleans up after itself; the cloud copies go to the Drive trash.

param([switch]$Live)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")

$script:failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:failures++ }
    Write-Host ("{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($detail) { "  ($detail)" } else { "" }))
}

# --- offline: the function itself, lifted from watch-drive.ps1 ---------------
# The watcher is a script with a main loop, not a module; parse it and define
# just this function instead of copying it here.
$src = Join-Path $PSScriptRoot "watch-drive.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Move-PendingPaths" }, $true) | Select-Object -First 1
Check "Move-PendingPaths in watch-drive.ps1 gefunden" ($null -ne $fn)
if ($fn) {
    . ([scriptblock]::Create($fn.Extent.Text))
    $pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in "Z\0851 - Mail.md", "Dir\a.txt", "Dir\sub\b.txt", "Dirx\c.txt", "other.md") { [void]$pending.Add($p) }

    Move-PendingPaths "Z\0851 - Mail.md" "Z\1013 - Mail.md"
    Check "Datei: Upload folgt dem neuen Namen" ($pending.Contains("Z\1013 - Mail.md") -and -not $pending.Contains("Z\0851 - Mail.md"))

    Move-PendingPaths "dir" "Neu"
    Check "Ordner: Inhalt folgt per Praefix, auch rekursiv" ($pending.Contains("Neu\a.txt") -and $pending.Contains("Neu\sub\b.txt"))
    Check "Ordner: Gross-/Kleinschreibung egal" (-not $pending.Contains("Dir\a.txt"))
    Check "Ordner: Namensvetter mit gleichem Praefix bleibt (Dirx)" ($pending.Contains("Dirx\c.txt"))
    Check "Unbeteiligte Datei bleibt" ($pending.Contains("other.md"))

    Move-PendingPaths "nicht\da.md" "egal.md"
    Check "Rename ohne pending Eintrag aendert nichts" ($pending.Count -eq 5) "$($pending.Count) Eintraege"
}

if (-not $Live) {
    Write-Host $(if ($script:failures) { "$($script:failures) FAIL" } else { "alle PASS" })
    exit [int]($script:failures -gt 0)
}

# --- live: against the running watcher and the cloud ------------------------
$rcloneExe = Join-Path $DriveSyncConfig.StateDir "bin\rclone.exe"
if (-not (Test-Path $rcloneExe)) { $rcloneExe = "rclone" }
elseif (-not $env:RCLONE_CONFIG) { $env:RCLONE_CONFIG = @(& rclone config file 2>$null)[-1] }

$name = "pending-rename-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$localDir = Join-Path $DriveSyncConfig.LocalRoot "Temp\$name"
$remoteDir = "$($DriveSyncConfig.Remote)Temp/$name"

# polls the cloud until the file has the expected content; the watcher needs
# 15 s of quiet plus 10 s of write silence plus the upload itself
function Wait-CloudContent([string]$rel, [string]$expected, [int]$timeoutSec = 180) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $got = $null
    while ((Get-Date) -lt $deadline) {
        $got = (& $rcloneExe cat "$remoteDir/$rel" 2>$null) -join "`n"
        if ($got -eq $expected) { return $got }
        Start-Sleep -Seconds 5
    }
    return $got
}

try {
    New-Item -ItemType Directory -Force (Join-Path $localDir "F") | Out-Null
    Set-Content (Join-Path $localDir "a.md") "v1" -NoNewline
    Set-Content (Join-Path $localDir "F\x.md") "v1" -NoNewline
    $got = Wait-CloudContent "a.md" "v1"
    Check "Vorbereitung: a.md in der Cloud" ($got -eq "v1") "Cloud: '$got'"
    $got = Wait-CloudContent "F/x.md" "v1"
    Check "Vorbereitung: F/x.md in der Cloud" ($got -eq "v1") "Cloud: '$got'"

    # the 2026-10-21 case: save, rename one second later
    Set-Content (Join-Path $localDir "a.md") "v2" -NoNewline
    Start-Sleep -Seconds 1
    Rename-Item (Join-Path $localDir "a.md") "b.md"
    $got = Wait-CloudContent "b.md" "v2"
    Check "Datei: speichern + umbenennen -> Cloud hat neuen Inhalt" ($got -eq "v2") "Cloud: '$got'"

    # same within a folder: edit a file, rename its folder
    Set-Content (Join-Path $localDir "F\x.md") "v2" -NoNewline
    Start-Sleep -Seconds 1
    Rename-Item (Join-Path $localDir "F") "G"
    $got = Wait-CloudContent "G/x.md" "v2"
    Check "Ordner: speichern + Ordner umbenennen -> Cloud hat neuen Inhalt" ($got -eq "v2") "Cloud: '$got'"

    $left = @(& $rcloneExe lsf -R --files-only $remoteDir 2>$null)
    Check "Cloud: keine alten Namen uebrig" (-not ($left -contains "a.md" -or $left -contains "F/x.md")) ($left -join ", ")
}
finally {
    # local first, the watcher carries the delete into the Drive trash; purge
    # whatever it has not reached yet, which also goes to the trash
    if (Test-Path -LiteralPath $localDir) {
        Get-ChildItem -LiteralPath $localDir -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) }
        Get-ChildItem -LiteralPath $localDir -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        [IO.Directory]::Delete($localDir)
    }
    Start-Sleep -Seconds 40
    & $rcloneExe purge $remoteDir 2>$null
}

Write-Host $(if ($script:failures) { "$($script:failures) FAIL" } else { "alle PASS" })
exit [int]($script:failures -gt 0)
