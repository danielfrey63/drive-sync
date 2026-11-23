# Recycle-bin delete shared by the cloud watcher and the resync guard.
# Prefers rclone --local-use-trash (custom build, rclone PR 9741) and falls
# back to a Win32 SHFileOperation shim (no UI, FOF_ALLOWUNDO). Dot-source
# after config.ps1; call Move-ToRecycleBin <absolute path>, 0 = success.

$script:recycleRclone = Join-Path $DriveSyncConfig.StateDir "bin\rclone.exe"
if (-not (Test-Path $script:recycleRclone)) { $script:recycleRclone = "rclone" }
$script:recycleViaRclone = [bool](& $script:recycleRclone help flags local-use-trash 2>$null | Select-String "local-use-trash")

if (-not ('RecycleBin' -as [type])) {
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
}

# Return codes besides the ones of rclone / SHFileOperation:
$script:RecycleRefusedCase = 90    # the path exists only in another letter case
$script:RecycleRefusedSize = 91    # a folder too large to take on a cloud signal

# True if every segment of $path exists on disk in exactly this spelling.
# NTFS answers Test-Path case-insensitively; Drive does not. On 2026-11-22 a
# folder "archiv" was trashed in the cloud, its local twin looked present,
# and the recycle took "Archiv" - 570'000 files, too large for the recycle
# bin, gone for good; the next bisync then deleted them in the cloud too.
function Test-ExactPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $parts = $full.Split('\')
    $current = $parts[0] + '\'
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $hit = @([IO.Directory]::GetFileSystemEntries($current, $parts[$i]) | ForEach-Object { [IO.Path]::GetFileName($_) })
        if ($hit -cnotcontains $parts[$i]) { return $false }
        $current = Join-Path $current $parts[$i]
    }
    return $true
}

# Number of files below a folder, counted up to $limit + 1 (enough to decide).
function Get-FileCountUpTo([string]$dir, [int]$limit) {
    $n = 0
    foreach ($f in [IO.Directory]::EnumerateFiles($dir, '*', [IO.SearchOption]::AllDirectories)) {
        $n++
        if ($n -gt $limit) { break }
    }
    return $n
}

function Move-ToRecycleBin([string]$path) {
    if (-not (Test-ExactPath $path)) { return $script:RecycleRefusedCase }
    # a whole folder on one cloud event: anything large goes through bisync
    # and its --max-delete check instead, never through a single recycle
    $maxFiles = if ($DriveSyncConfig.RecycleFolderMaxFiles) { [int]$DriveSyncConfig.RecycleFolderMaxFiles } else { 1000 }
    if ((Test-Path -LiteralPath $path -PathType Container) -and (Get-FileCountUpTo $path $maxFiles) -gt $maxFiles) {
        return $script:RecycleRefusedSize
    }
    if ($script:recycleViaRclone) {
        if (Test-Path -LiteralPath $path -PathType Container) { & $script:recycleRclone purge $path --local-use-trash -q 2>$null }
        else { & $script:recycleRclone deletefile $path --local-use-trash -q 2>$null }
        return $LASTEXITCODE
    }
    return [RecycleBin]::Delete($path)
}
