# Direct Drive v3 API access with the rclone remote's own OAuth credentials,
# for what rclone cannot do cheaply. Dot-source, then:
#   . (Join-Path $PSScriptRoot "drive-api.ps1")
#   $rootId = Initialize-DriveApi $rcloneExe $remoteName
#   Invoke-Drive "changes/startPageToken?fields=startPageToken"
#   Resolve-RelPath $file        # "dir\name" below My Drive, $null outside
#   Get-DriveTrashedFiles        # every trashed file: .Rel ("/") and .ModTime
#
# Used by watch-cloud.ps1 (Changes API) and resync-guard.ps1 (trash listing).
# State lives in the caller's script scope: $rootId, $dirCache and the token.

function Initialize-DriveApi([string]$rcloneExe, [string]$remoteName) {
    $conf = (& $rcloneExe config dump | ConvertFrom-Json).$remoteName
    if (-not $conf) { throw "rclone remote '$remoteName' not found" }
    $script:driveApiConf = $conf
    $script:driveApiRefreshToken = ($conf.token | ConvertFrom-Json).refresh_token
    $script:accessToken = $null
    $script:accessTokenExpiry = [datetime]::MinValue
    $script:dirCache = @{}   # folder id -> @{ Name; Parent }
    $script:rootId = (Invoke-Drive "files/root?fields=id").id
    return $script:rootId
}

function Get-AccessToken {
    if ($script:accessToken -and (Get-Date) -lt $script:accessTokenExpiry) { return $script:accessToken }
    # -TimeoutSec is essential: the default is infinite, and a hung TLS
    # connection would freeze the whole watcher silently
    $resp = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -TimeoutSec 30 -Body @{
        client_id = $script:driveApiConf.client_id; client_secret = $script:driveApiConf.client_secret
        refresh_token = $script:driveApiRefreshToken; grant_type = "refresh_token"
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

# --- path resolution via parent-chain walk with cache -----------------------
# A Drive name may contain "/", a path segment may not: rclone shows it as
# U+FF0F, and that is also the name the local mirror carries. Applied to every
# segment, folders included - otherwise "A/B" as one folder name would read as
# two levels.
function ConvertTo-RcloneName([string]$name) { $name.Replace('/', [string][char]0xFF0F) }

# the dirCache entry for a folder object from any API response
function New-FolderInfo($f) { @{ Name = ConvertTo-RcloneName $f.name; Parent = @($f.parents)[0] } }

function Get-FolderInfo([string]$id) {
    if ($script:dirCache.ContainsKey($id)) { return $script:dirCache[$id] }
    $f = Invoke-Drive "files/$([uri]::EscapeDataString($id))?fields=id,name,parents"
    $info = New-FolderInfo $f
    $script:dirCache[$id] = $info
    return $info
}

function Resolve-RelDir([string]$parentId) {
    # returns the relative directory path ("" for My Drive root),
    # or $null if the chain does not reach the root (shared/orphaned)
    $segs = @()
    $id = $parentId
    for ($depth = 0; $depth -lt 100; $depth++) {
        if ($id -eq $script:rootId) { return ($segs -join '\') }
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
    $name = ConvertTo-RcloneName $file.name
    if ($dir) { return "$dir\$name" } else { return $name }
}

# --- the trash ---------------------------------------------------------------
# Every trashed file below My Drive, as rclone would name it: "/" separators,
# a "/" inside a name as U+FF0F (ConvertTo-RcloneName), modtime in local time truncated to seconds
# (the "t" column of rclone lsf). Google-native documents are left out, like
# --drive-skip-gdocs in the bisync - they have no local twin.
#
# Why not rclone lsf --drive-trashed-only: that walks every folder of the
# corpus to find the trashed ones, ~90 min on 2026-10-20 before a resync could
# start. trashed=true is one flat, paged query; it also returns the contents
# of a trashed folder (their "trashed" is inherited). Trashed folders seed the
# path cache, so mostly only the live parents of trashed files cost a call.
function Get-DriveTrashedFiles {
    $fields = "nextPageToken,files(id,name,mimeType,parents,modifiedTime)"
    $q = [uri]::EscapeDataString("trashed=true")
    $items = [System.Collections.Generic.List[object]]::new()
    $token = $null
    do {
        $url = "files?q=$q&spaces=drive&pageSize=1000&fields=$([uri]::EscapeDataString($fields))"
        if ($token) { $url += "&pageToken=$([uri]::EscapeDataString($token))" }
        $resp = Invoke-Drive $url
        foreach ($f in @($resp.files)) {
            if ($f.mimeType -eq "application/vnd.google-apps.folder") {
                $script:dirCache[$f.id] = New-FolderInfo $f
            }
            elseif ($f.mimeType -notlike "application/vnd.google-apps.*") { $items.Add($f) }
        }
        $token = $resp.nextPageToken
    } while ($token)

    foreach ($f in $items) {
        $rel = Resolve-RelPath $f
        if ($null -eq $rel) { continue }
        $rel = $rel -replace '\\', '/'
        $t = ([datetime]$f.modifiedTime).ToLocalTime()
        [pscustomobject]@{
            Rel     = $rel
            ModTime = [datetime]::new($t.Year, $t.Month, $t.Day, $t.Hour, $t.Minute, $t.Second)
        }
    }
}
