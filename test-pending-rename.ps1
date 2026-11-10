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
# The resync case lets a sleeping process hold the bisync lock
# (single-instance.ps1) for about half a minute and refuses to run while a
# real bisync holds it.

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
Check "Move-PendingPaths found in watch-drive.ps1" ($null -ne $fn)
if ($fn) {
    . ([scriptblock]::Create($fn.Extent.Text))
    $pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in "Z\0851 - Mail.md", "Dir\a.txt", "Dir\sub\b.txt", "Dirx\c.txt", "other.md") { [void]$pending.Add($p) }

    Move-PendingPaths "Z\0851 - Mail.md" "Z\1013 - Mail.md"
    Check "file: the upload follows the new name" ($pending.Contains("Z\1013 - Mail.md") -and -not $pending.Contains("Z\0851 - Mail.md"))

    Move-PendingPaths "dir" "Neu"
    Check "folder: its content follows by prefix, recursively too" ($pending.Contains("Neu\a.txt") -and $pending.Contains("Neu\sub\b.txt"))
    Check "folder: case does not matter" (-not $pending.Contains("Dir\a.txt"))
    Check "folder: a namesake with the same prefix stays (Dirx)" ($pending.Contains("Dirx\c.txt"))
    Check "an unrelated file stays" ($pending.Contains("other.md"))

    Move-PendingPaths "nicht\da.md" "egal.md"
    Check "a rename without a pending entry changes nothing" ($pending.Count -eq 5) "$($pending.Count) Eintraege"
}

# --- offline: a change event drained after its file was already renamed -----
# The 2026-11-02 case. Live timing cannot force it, so replay the drain order:
# Changed(old) when old is already gone, then Renamed(old -> new).
$fn = Get-WatcherFunction "Add-ChangedPath"
Check "Add-ChangedPath found in watch-drive.ps1" ($null -ne $fn)
if ($fn) {
    . ([scriptblock]::Create($fn.Extent.Text))
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("changed-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force (Join-Path $scratch "dir") | Out-Null
    Set-Content (Join-Path $scratch "da.md") "x"
    try {
        $pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Add-ChangedPath (Join-Path $scratch "da.md") "da.md"
        Check "change: an existing file is queued" ($pending.Contains("da.md"))
        Add-ChangedPath (Join-Path $scratch "dir") "dir"
        Check "change: a folder is not queued" (-not $pending.Contains("dir"))
        Add-ChangedPath (Join-Path $scratch "2030-v0.2.md") "2030-v0.2.md"
        Check "change: a file already moved away is queued all the same" ($pending.Contains("2030-v0.2.md"))
        $fnMove = Get-WatcherFunction "Move-PendingPaths"
        . ([scriptblock]::Create($fnMove.Extent.Text))
        Move-PendingPaths "2030-v0.2.md" "2027-v0.2.md"
        Check "change + rename in one round: upload under the new name" ($pending.Contains("2027-v0.2.md") -and -not $pending.Contains("2030-v0.2.md"))
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

# --- offline: copies revived under the old name -----------------------------
$fn = Get-WatcherFunction "Remove-RevivedRenameSource"
Check "Remove-RevivedRenameSource found in watch-drive.ps1" ($null -ne $fn)
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
        Check "file: identical copy under the old name recycled" (-not (Test-Path (Join-Path $root "protokolle\x.m4a")))
        Check "file: the new name stays" (Test-Path (Join-Path $root "protokolle\2026-10-20\x.m4a"))
        Check "file: upload of the old name dropped" ($pending.Count -eq 0)

        # file: something different under the old name is somebody's work
        Put "a.md" "jemand anderes" $t0.AddMinutes(5)
        Put "b.md" "original" $t0
        Remove-RevivedRenameSource "a.md" "b.md"
        Check "file: a differing file under the old name stays" (Test-Path (Join-Path $root "a.md"))

        # folder: two identical copies recycled, one differing file kept
        Put "Alt\a.txt" "1" $t0; Put "Neu\a.txt" "1" $t0
        Put "Alt\sub\b.txt" "2" $t0; Put "Neu\sub\b.txt" "2" $t0
        Put "Alt\c.txt" "anders" $t0; Put "Neu\c.txt" "3" $t0
        Remove-RevivedRenameSource "Alt" "Neu"
        Check "folder: identical files recycled" (-not (Test-Path (Join-Path $root "Alt\a.txt")) -and -not (Test-Path (Join-Path $root "Alt\sub\b.txt")))
        Check "folder: empty subfolder removed" (-not (Test-Path (Join-Path $root "Alt\sub")))
        Check "folder: a differing file and its folder stay" (Test-Path (Join-Path $root "Alt\c.txt"))
        $last = $script:logLines | Select-Object -Last 1
        Check "folder: the log names 2 recycled, 1 kept" ($last -match '2 recycled, 1 kept') $last

        # nothing there under the old name: no-op
        $before = $script:logLines.Count
        Remove-RevivedRenameSource "gibts\nicht.md" "b.md"
        Check "old name missing: nothing happens" ($script:logLines.Count -eq $before)
    }
    finally { if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    Remove-Item Function:\Write-Log
}

if (-not $Live) {
    Write-Host $(if ($script:failures) { "$($script:failures) FAIL" } else { "all passed" })
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
    Check "setup: a.md in the cloud" ($got -eq "v1") "Cloud: '$got'"
    $got = Wait-CloudContent "F/x.md" "v1"
    Check "setup: F/x.md in the cloud" ($got -eq "v1") "Cloud: '$got'"

    # the 2026-10-21 case: save, rename one second later
    Set-Content (Join-Path $localDir "a.md") "v2" -NoNewline
    Start-Sleep -Seconds 1
    Rename-Item (Join-Path $localDir "a.md") "b.md"
    $got = Wait-CloudContent "b.md" "v2"
    Check "file: save + rename -> the cloud has the new content" ($got -eq "v2") "Cloud: '$got'"

    # same within a folder: edit a file, rename its folder
    Set-Content (Join-Path $localDir "F\x.md") "v2" -NoNewline
    Start-Sleep -Seconds 1
    Rename-Item (Join-Path $localDir "F") "G"
    $got = Wait-CloudContent "G/x.md" "v2"
    Check "folder: save + rename the folder -> the cloud has the new content" ($got -eq "v2") "Cloud: '$got'"

    $left = @(& $rcloneExe lsf -R --files-only $remoteDir 2>$null)
    Check "cloud: no old names left" (-not ($left -contains "a.md" -or $left -contains "F/x.md")) ($left -join ", ")

    # The 2026-11-02 drain order: change and rename read in ONE drain, after
    # the old path is gone. That happens when both events queue up while the
    # watcher is busy, so write and rename during an upload - a dummy file
    # keeps the flush running for a few seconds. The event log numbers each
    # drain; retry until change and rename carry the same number.
    $evLog = Join-Path $DriveSyncConfig.StateDir "watcher-events.log"
    $rel = "Temp\$name"
    $src = "b.md"; $hit = 0; $contentOk = $true
    for ($k = 1; $k -le 6 -and -not $hit; $k++) {
        [IO.File]::WriteAllBytes((Join-Path $localDir "dummy$k.bin"), [byte[]]::new(15MB))
        # flush starts after 15 s of quiet; act a little later, varied per try
        Start-Sleep -Seconds (16 + ($k % 3))
        $dst = "c$k.md"
        [IO.File]::WriteAllText((Join-Path $localDir $src), "v3-$k")
        [IO.File]::Move((Join-Path $localDir $src), (Join-Path $localDir $dst))
        $got = Wait-CloudContent $dst "v3-$k"
        if ($got -ne "v3-$k") { $contentOk = $false; Write-Host "  attempt ${k}: the cloud has '$got' instead of 'v3-$k'" }
        $lines = @(Get-Content $evLog -Tail 3000)
        $chg = $lines | Where-Object { $_ -like "* fswChanged $rel\$src`t#d*" } | Select-Object -Last 1
        $ren = $lines | Where-Object { $_ -like "* fswRenamed $rel\$src -> $rel\$dst`t#d*" } | Select-Object -Last 1
        if ($chg -and $ren -and ($chg -split '#d')[-1] -eq ($ren -split '#d')[-1]) { $hit = $k }
        $src = $dst
    }
    Check "file: write + rename at once -> the cloud has the new content every time" $contentOk
    if ($hit) { Check "change and rename met in the same collection round (attempt $hit)" $true }
    else { Write-Host "SKIP  change and rename never in the same collection round - the case of 2026-11-02 is covered offline only" }

    # a rename during a resync: a second process holds the bisync lock, rename,
    # let the "resync" copy the old name back down from the cloud, release it
    $lockLib = Join-Path $PSScriptRoot "single-instance.ps1"
    . $lockLib
    $lock = Join-Path $DriveSyncConfig.StateDir "sync.lock"
    if (Test-BisyncRunning) { Check "resync case: no real bisync is running" $false (Get-Content $lock -TotalCount 1) }
    else {
        Set-Content (Join-Path $localDir "r.md") "resync" -NoNewline
        $got = Wait-CloudContent "r.md" "resync"
        Check "resync case, setup: r.md in the cloud" ($got -eq "resync") "Cloud: '$got'"
        # encoded: Start-Process joins its arguments unquoted, the paths have spaces
        $hold = ". '$lockLib'; [void](Enter-SingleInstance 'bisync' '$lock'); Start-Sleep 600"
        $holder = Start-Process pwsh -ArgumentList "-NoProfile", "-EncodedCommand", ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hold))) -WindowStyle Hidden -PassThru
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Test-BisyncRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            Check "resync case: the stand-in holds the bisync lock" (Test-BisyncRunning)
            Start-Sleep -Seconds 5
            Rename-Item (Join-Path $localDir "r.md") "s.md"
            Start-Sleep -Seconds 5
            & $rcloneExe copyto "$remoteDir/r.md" (Join-Path $localDir "r.md") 2>$null
            Check "resync case: old name copied back locally" (Test-Path (Join-Path $localDir "r.md"))
            Start-Sleep -Seconds 20
        }
        finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
            [IO.File]::Delete($lock)
        }
        $deadline = (Get-Date).AddSeconds(180)
        while ((Test-Path (Join-Path $localDir "r.md")) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
        Check "resync case: revived r.md recycled locally" (-not (Test-Path (Join-Path $localDir "r.md")))
        $got = Wait-CloudContent "s.md" "resync"
        Check "resync case: s.md in the cloud" ($got -eq "resync") "Cloud: '$got'"
        Start-Sleep -Seconds 40
        $left = @(& $rcloneExe lsf --files-only $remoteDir 2>$null)
        Check "resync case: r.md not in the cloud" (-not ($left -contains "r.md")) ($left -join ", ")
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

Write-Host $(if ($script:failures) { "$($script:failures) FAIL" } else { "all passed" })
exit [int]($script:failures -gt 0)
