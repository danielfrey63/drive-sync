# Stage-C watcher: near-realtime DOWNLOAD of cloud-side changes from gdrive:
# to "D:\Meine Ablage", complementing the nightly bisync and the stage-B
# upload watcher (watch-drive.ps1).
#
# Design:
#  - Polls the Drive Changes API (changes.list with a persisted pageToken)
#    every $PollSeconds - one cheap delta call, no tree listing. This is the
#    same mechanism the official Drive clients use; true push (changes.watch)
#    would need a public HTTPS endpoint.
#  - OAuth reuses the rclone remote's client id + refresh token (read via
#    "rclone config dump"); access tokens are refreshed in-process and never
#    written back, so rclone's own token handling is untouched.
#  - FILE changes are downloaded via "rclone copy --files-from-raw
#    --no-traverse --update" (--update never overwrites a newer local file).
#  - Cloud-side TRASHING moves the local copy to the Windows recycle bin
#    (never a hard delete), capped at $maxDeletes per cycle - larger delete
#    storms are left to the nightly bisync.
#  - Cloud-side folder RENAMES and permanent deletions are left to the
#    nightly bisync (resolving the old local path would need a full
#    fileId->path index).
#  - Exclude rules are derived from filters.txt (shared filter-rules.ps1).
#  - Paths are resolved by walking the parent chain with a directory cache;
#    folder change events keep the cache fresh.
#  - While the bisync wrapper's lock is active, flushing is deferred (pending
#    work accumulates; the token FILE only advances after a flush, so nothing
#    is lost across restarts).
#  - On an invalid/expired page token the watcher restarts from a fresh
#    startPageToken - the gap is reconciled by the next bisync run.
#
# Meant to run permanently via the "DriveSync cloud watcher" logon task
# (install-watcher-task.ps1). Single instance enforced by a PID lock.
# -Once runs a single poll+flush cycle (for testing).

param(
    [int]$PollSeconds = 60,
    [switch]$Once
)

$ErrorActionPreference = "Stop"
$root = "D:\Meine Ablage"
$remoteName = "gdrive"
$stateDir = Join-Path $env:LOCALAPPDATA "drive-sync"
$logFile = Join-Path $stateDir "cloud-watcher.log"
$statusFile = Join-Path $stateDir "cloud-watcher-status.json"
$lockFile = Join-Path $stateDir "cloud-watcher.lock"
$tokenFile = Join-Path $stateDir "cloud-watcher-pagetoken.txt"
$bisyncLock = Join-Path $stateDir "sync.lock"
$maxDeletes = 50
New-Item -ItemType Directory -Force $stateDir | Out-Null
# custom build (release + --files-from-strict backport) if deployed, else PATH
# rclone. Downloads deliberately do NOT use --files-from-strict: a file may
# legitimately vanish in the cloud between change event and flush.
$rcloneExe = Join-Path $env:LOCALAPPDATA "drive-sync\bin\rclone.exe"
if (-not (Test-Path $rcloneExe)) { $rcloneExe = "rclone" }
elseif (-not $env:RCLONE_CONFIG) {
    # the custom build defaults to %APPDATA%, but scoop keeps the config in its
    # persist dir - resolve it via the PATH rclone once and pin it
    $cfg = @(& rclone config file 2>$null)[-1]
    if ($cfg -and (Test-Path $cfg)) { $env:RCLONE_CONFIG = $cfg }
}
# recycle via rclone if the build supports --local-use-trash (rclone PR 9741),
# otherwise fall back to the SHFileOperation shim below
$rcloneHasLocalTrash = [bool](& $rcloneExe help flags local-use-trash 2>$null | Select-String "local-use-trash")

function Write-Log([string]$msg) {
    # logging must never kill the watcher
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 10MB) {
            Move-Item $logFile "$logFile.1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ErrorAction SilentlyContinue
    }
    catch {}
}

# Paths the upload watcher recently sent to the cloud (echo control): change
# events for them are our own doing and must not be downloaded back.
$ledgerFile = Join-Path $stateDir "upload-ledger.txt"
function Get-RecentUploads {
    $recent = @{}
    try {
        if (Test-Path $ledgerFile) {
            $cut = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 900
            foreach ($line in Get-Content $ledgerFile -ErrorAction SilentlyContinue) {
                if ($line -match '^(\d+)\t(.+)$' -and [long]$Matches[1] -gt $cut) { $recent[$Matches[2]] = $true }
            }
        }
    }
    catch {}
    return $recent
}

# --- recycle-bin delete via SHFileOperation (no UI, FOF_ALLOWUNDO) ----------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RecycleBin {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
    // FO_DELETE with FOF_ALLOWUNDO|FOF_NOCONFIRMATION|FOF_SILENT|FOF_NOERRORUI
    public static int Delete(string path) {
        var op = new SHFILEOPSTRUCT { wFunc = 3, pFrom = path + "\0", fFlags = 0x0454 };
        return SHFileOperation(ref op);
    }
}
"@

# --- single instance --------------------------------------------------------
if (Test-Path $lockFile) {
    $other = Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($other -and (Get-Process -Id $other -ErrorAction SilentlyContinue)) {
        Write-Log "another cloud watcher (PID $other) is active - exiting"
        exit 0
    }
}
Set-Content $lockFile $PID

# --- exclude rules from filters.txt -----------------------------------------
. (Join-Path $PSScriptRoot "filter-rules.ps1")
$rules = Get-ExcludeRules (Join-Path $PSScriptRoot "filters.txt")

# --- OAuth: reuse the rclone remote's credentials ---------------------------
$remoteConf = (& $rcloneExe config dump | ConvertFrom-Json).$remoteName
if (-not $remoteConf) { Write-Log "FATAL: rclone remote '$remoteName' not found"; exit 1 }
$refreshToken = ($remoteConf.token | ConvertFrom-Json).refresh_token
$script:accessToken = $null
$script:accessTokenExpiry = [datetime]::MinValue

function Get-AccessToken {
    if ($script:accessToken -and (Get-Date) -lt $script:accessTokenExpiry) { return $script:accessToken }
    # -TimeoutSec is essential: the default is infinite, and a hung TLS
    # connection would freeze the whole watcher silently
    $resp = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -TimeoutSec 30 -Body @{
        client_id = $remoteConf.client_id; client_secret = $remoteConf.client_secret
        refresh_token = $refreshToken; grant_type = "refresh_token"
    }
    $script:accessToken = $resp.access_token
    $script:accessTokenExpiry = (Get-Date).AddSeconds($resp.expires_in - 60)
    return $script:accessToken
}

function Invoke-Drive([string]$pathAndQuery) {
    # one retry with a forced token refresh on 401
    foreach ($attempt in 1, 2) {
        try {
            return Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/$pathAndQuery" -TimeoutSec 60 `
                -Headers @{ Authorization = "Bearer $(Get-AccessToken)" }
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($attempt -eq 1 -and $status -eq 401) { $script:accessTokenExpiry = [datetime]::MinValue; continue }
            throw
        }
    }
}

$rootId = (Invoke-Drive "files/root?fields=id").id
Write-Log "started (PID $PID): $($rules.Dirs.Count) dir rules, root=$rootId, poll=${PollSeconds}s"

# --- path resolution via parent-chain walk with cache -----------------------
$dirCache = @{}  # folder id -> @{ Name; Parent }

function Get-FolderInfo([string]$id) {
    if ($dirCache.ContainsKey($id)) { return $dirCache[$id] }
    $f = Invoke-Drive "files/$([uri]::EscapeDataString($id))?fields=id,name,parents"
    $info = @{ Name = $f.name; Parent = @($f.parents)[0] }
    $dirCache[$id] = $info
    return $info
}

function Resolve-RelDir([string]$parentId) {
    # returns the relative directory path ("" for My Drive root),
    # or $null if the chain does not reach the root (shared/orphaned)
    $segs = @()
    $id = $parentId
    for ($depth = 0; $depth -lt 100; $depth++) {
        if ($id -eq $rootId) { return ($segs -join '\') }
        if (-not $id) { return $null }
        $info = Get-FolderInfo $id
        $segs = @($info.Name) + $segs
        $id = $info.Parent
    }
    return $null
}

function Resolve-RelPath($file) {
    $parent = @($file.parents)[0]
    if (-not $parent) { return $null }
    $dir = Resolve-RelDir $parent
    if ($null -eq $dir) { return $null }
    if ($dir) { return "$dir\$($file.name)" } else { return $file.name }
}

# --- page token: persisted across restarts ----------------------------------
$pageToken = if (Test-Path $tokenFile) { (Get-Content $tokenFile -Raw).Trim() } else { $null }
if (-not $pageToken) {
    $pageToken = (Invoke-Drive "changes/startPageToken?fields=startPageToken").startPageToken
    Write-Log "fresh startPageToken (changes before now are left to bisync)"
}

# --- main loop: poll, resolve, flush ----------------------------------------
$pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$trash = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$downloadedTotal = 0
$recycledTotal = 0
$lastSavedToken = $pageToken
$fields = "changes(removed,fileId,file(id,name,mimeType,parents,trashed)),nextPageToken,newStartPageToken"

$lastHeartbeat = Get-Date
try {
    while ($true) {
        if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 10) {
            Write-Log "heartbeat: $($pending.Count) down / $($trash.Count) trash pending"
            $lastHeartbeat = Get-Date
        }
        try {
            $token = $pageToken
            while ($token) {
                $resp = Invoke-Drive ("changes?pageToken=$([uri]::EscapeDataString($token))" +
                    "&restrictToMyDrive=true&pageSize=1000&fields=$([uri]::EscapeDataString($fields))")
                foreach ($chg in @($resp.changes)) {
                    if ($chg.removed) { $dirCache.Remove($chg.fileId); continue }   # permanent delete: bisync's job
                    $f = $chg.file
                    if (-not $f) { continue }
                    $isFolder = $f.mimeType -eq "application/vnd.google-apps.folder"
                    if ($f.trashed) {
                        # move the local copy to the recycle bin (files AND folders)
                        if (-not $isFolder -and $f.mimeType -like "application/vnd.google-apps.*") { continue }
                        $rel = Resolve-RelPath $f
                        $dirCache.Remove($chg.fileId)
                        if ($rel -and -not (Test-Excluded $rules $rel)) { [void]$trash.Add($rel) }
                        continue
                    }
                    if ($isFolder) {
                        # keep the cache fresh; renamed dirs themselves are bisync's job
                        $dirCache[$f.id] = @{ Name = $f.name; Parent = @($f.parents)[0] }
                        continue
                    }
                    if ($f.mimeType -like "application/vnd.google-apps.*") { continue }  # gdocs, shortcuts, ...
                    $rel = Resolve-RelPath $f
                    if ($rel -and -not (Test-Excluded $rules $rel)) { [void]$pending.Add($rel) }
                }
                if ($resp.newStartPageToken) {
                    # advance in memory only; the token FILE is written after a
                    # flush so deferred/unflushed changes survive a restart
                    $pageToken = $resp.newStartPageToken
                    $token = $null
                }
                else { $token = $resp.nextPageToken }
            }
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 410 -or $status -eq 400) {
                Write-Log "WARN page token invalid ($status) - restarting from a fresh token, bisync covers the gap"
                $pageToken = (Invoke-Drive "changes/startPageToken?fields=startPageToken").startPageToken
                Set-Content $tokenFile $pageToken
                $lastSavedToken = $pageToken
            }
            else { Write-Log "WARN poll failed: $($_.Exception.Message)" }
        }

        # defer while the nightly bisync holds its lock
        $bisyncActive = $false
        if (Test-Path $bisyncLock) {
            $lockPid = Get-Content $bisyncLock -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) { $bisyncActive = $true }
        }

        if (-not $bisyncActive) {
            # the flush cycle must never kill the watcher - log and carry on
            try {
                $didWork = ($pending.Count + $trash.Count) -gt 0
                # 1) downloads (skipping echoes of our own recent uploads)
                if ($pending.Count -gt 0) {
                    $recent = Get-RecentUploads
                    $batch = @($pending | Where-Object { -not $recent.ContainsKey($_) })
                    $skipped = $pending.Count - $batch.Count
                    $pending.Clear()
                    if ($skipped -gt 0) { Write-Log "skipped $skipped own-upload echo(es)" }
                    if ($batch.Count -gt 0) {
                        $batchFile = Join-Path $stateDir "cloud-batch.txt"
                        # rclone expects "/" separators for remote paths in --files-from
                        Set-Content -Path $batchFile -Value @($batch | ForEach-Object { $_ -replace '\\', '/' }) -Encoding UTF8
                        & $rcloneExe copy "${remoteName}:" $root --files-from-raw $batchFile --no-traverse --update `
                            --modify-window 1s --drive-pacer-min-sleep 10ms --drive-pacer-burst 200 `
                            --transfers 4 --log-level INFO --log-file $logFile 2>$null
                        $exit = $LASTEXITCODE
                        $downloadedTotal += $batch.Count
                        Write-Log "flush: $($batch.Count) file(s), exit=$exit"
                    }
                }

                # 2) cloud trash -> local recycle bin (verified, capped)
                if ($trash.Count -gt $maxDeletes) {
                    Write-Log "WARN $($trash.Count) trashed paths exceed cap $maxDeletes - leaving them to the nightly bisync"
                    $trash.Clear()
                }
                elseif ($trash.Count -gt 0) {
                    foreach ($t in @($trash | Sort-Object)) {
                        $abs = Join-Path $root $t
                        if (-not (Test-Path -LiteralPath $abs)) { continue }   # already gone locally
                        if ($rcloneHasLocalTrash) {
                            $isDir = Test-Path -LiteralPath $abs -PathType Container
                            if ($isDir) { & $rcloneExe purge $abs --local-use-trash -q 2>$null }
                            else { & $rcloneExe deletefile $abs --local-use-trash -q 2>$null }
                            $rc = $LASTEXITCODE
                        }
                        else { $rc = [RecycleBin]::Delete($abs) }
                        if ($rc -eq 0) { $recycledTotal++; Write-Log "cloud trash -> recycle bin: $t" }
                        else { Write-Log "WARN recycle failed (rc=$rc): $t" }
                    }
                    $trash.Clear()
                }

                if ($didWork) {
                    [ordered]@{
                        pid = $PID; lastFlush = (Get-Date).ToString("s")
                        downloadedTotal = $downloadedTotal; recycledTotal = $recycledTotal
                    } | ConvertTo-Json | Set-Content $statusFile
                }
            }
            catch {
                Write-Log "ERROR flush cycle: $($_.Exception.Message)"
            }
        }

        if ($pending.Count -eq 0 -and $trash.Count -eq 0 -and $pageToken -ne $lastSavedToken) {
            Set-Content $tokenFile $pageToken
            $lastSavedToken = $pageToken
        }

        if ($Once) { break }
        Start-Sleep $PollSeconds
    }
}
finally {
    Remove-Item $lockFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "stopped (PID $PID)"
}
