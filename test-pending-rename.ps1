# Exercises two watcher fixes of 2026-10-22 around renames:
#  - a file saved and renamed inside one debounce window must reach the cloud
#    with its NEW content (af21764, Move-PendingPaths)
#  - a rename that waited out a bisync: the copy a resync brought back under
#    the old name is recycled, a differing file stays (Remove-RevivedRenameSource)
#
#   pwsh -File test-pending-rename.ps1          offline, scratch dir in %TEMP%
#   pwsh -File test-pending-rename.ps1 -Live    plus the live cases against the
#                                               running upload watcher and the
#                                               cloud, in Temp\ of the mirror
#
# -Live needs a watcher past its start-up catch-up (restart-watchers.ps1 waits
# for that). It cleans up after itself; the cloud copies go to the Drive trash.
# The resync case holds a fake bisync lock (sync.lock with the PID of a
# sleeping process) for about half a minute and refuses to run if a real one
# exists.

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
function Get-WatcherFunction([string]$name) {
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
}
$fn = Get-WatcherFunction "Move-PendingPaths"
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

# --- offline: copies revived under the old name -----------------------------
$fn = Get-WatcherFunction "Remove-RevivedRenameSource"
Check "Remove-RevivedRenameSource in watch-drive.ps1 gefunden" ($null -ne $fn)
if ($fn) {
    . (Join-Path $PSScriptRoot "recycle-bin.ps1")
    . ([scriptblock]::Create($fn.Extent.Text))
    $script:logLines = @()
    function Write-Log([string]$m) { $script:logLines += $m }
    $root = Join-Path ([IO.Path]::GetTempPath()) ("revived-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    function Put([string]$rel, [string]$text, [datetime]$time) {
        $abs = Join-Path $root $rel
        New-Item -ItemType Directory -Force (Split-Path $abs) | Out-Null
        Set-Content -LiteralPath $abs $text -NoNewline
        (Get-Item -LiteralPath $abs).LastWriteTimeUtc = $time
    }
    $t0 = [datetime]::new(2026, 10, 20, 17, 0, 0, [DateTimeKind]::Utc)
    try {
        # file: the resync copied the old name back, identical to the new one
        Put "protokolle\x.m4a" "audio" $t0
        Put "protokolle\2026-10-20\x.m4a" "audio" $t0
        $pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$pending.Add("protokolle\x.m4a")
        Remove-RevivedRenameSource "protokolle\x.m4a" "protokolle\2026-10-20\x.m4a"
        Check "Datei: identische Kopie unter altem Namen recycelt" (-not (Test-Path (Join-Path $root "protokolle\x.m4a")))
        Check "Datei: neuer Name bleibt" (Test-Path (Join-Path $root "protokolle\2026-10-20\x.m4a"))
        Check "Datei: Upload des alten Namens verworfen" ($pending.Count -eq 0)

        # file: something different under the old name is somebody's work
        Put "a.md" "jemand anderes" $t0.AddMinutes(5)
        Put "b.md" "original" $t0
        Remove-RevivedRenameSource "a.md" "b.md"
        Check "Datei: abweichende Datei unter altem Namen bleibt" (Test-Path (Join-Path $root "a.md"))

        # folder: two identical copies recycled, one differing file kept
        Put "Alt\a.txt" "1" $t0; Put "Neu\a.txt" "1" $t0
        Put "Alt\sub\b.txt" "2" $t0; Put "Neu\sub\b.txt" "2" $t0
        Put "Alt\c.txt" "anders" $t0; Put "Neu\c.txt" "3" $t0
        Remove-RevivedRenameSource "Alt" "Neu"
        Check "Ordner: identische Dateien recycelt" (-not (Test-Path (Join-Path $root "Alt\a.txt")) -and -not (Test-Path (Join-Path $root "Alt\sub\b.txt")))
        Check "Ordner: leerer Unterordner entfernt" (-not (Test-Path (Join-Path $root "Alt\sub")))
        Check "Ordner: abweichende Datei und ihr Ordner bleiben" (Test-Path (Join-Path $root "Alt\c.txt"))
        $last = $script:logLines | Select-Object -Last 1
        Check "Ordner: Log nennt 2 recycelt, 1 behalten" ($last -match '2 recycled, 1 kept') $last

        # nothing there under the old name: no-op
        $before = $script:logLines.Count
        Remove-RevivedRenameSource "gibts\nicht.md" "b.md"
        Check "Alter Name fehlt: nichts passiert" ($script:logLines.Count -eq $before)
    }
    finally { if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    Remove-Item Function:\Write-Log
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

    # a rename during a resync: hold a fake bisync lock, rename, let the
    # "resync" copy the old name back down from the cloud, release the lock
    $lock = Join-Path $DriveSyncConfig.StateDir "sync.lock"
    if (Test-Path $lock) { Check "Resync-Fall: kein echter Bisync-Lock vorhanden" $false (Get-Content $lock -TotalCount 1) }
    else {
        Set-Content (Join-Path $localDir "r.md") "resync" -NoNewline
        $got = Wait-CloudContent "r.md" "resync"
        Check "Resync-Fall, Vorbereitung: r.md in der Cloud" ($got -eq "resync") "Cloud: '$got'"
        $holder = Start-Process pwsh -ArgumentList "-NoProfile", "-Command", "Start-Sleep 600" -WindowStyle Hidden -PassThru
        try {
            Set-Content $lock $holder.Id
            Start-Sleep -Seconds 5
            Rename-Item (Join-Path $localDir "r.md") "s.md"
            Start-Sleep -Seconds 5
            & $rcloneExe copyto "$remoteDir/r.md" (Join-Path $localDir "r.md") 2>$null
            Check "Resync-Fall: alter Name lokal zurueckkopiert" (Test-Path (Join-Path $localDir "r.md"))
            Start-Sleep -Seconds 20
        }
        finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
            [IO.File]::Delete($lock)
        }
        $deadline = (Get-Date).AddSeconds(180)
        while ((Test-Path (Join-Path $localDir "r.md")) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
        Check "Resync-Fall: Wiedergaenger r.md lokal recycelt" (-not (Test-Path (Join-Path $localDir "r.md")))
        $got = Wait-CloudContent "s.md" "resync"
        Check "Resync-Fall: s.md in der Cloud" ($got -eq "resync") "Cloud: '$got'"
        Start-Sleep -Seconds 40
        $left = @(& $rcloneExe lsf --files-only $remoteDir 2>$null)
        Check "Resync-Fall: r.md nicht in der Cloud" (-not ($left -contains "r.md")) ($left -join ", ")
    }
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
