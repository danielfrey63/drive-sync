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

function Move-ToRecycleBin([string]$path) {
    if ($script:recycleViaRclone) {
        if (Test-Path -LiteralPath $path -PathType Container) { & $script:recycleRclone purge $path --local-use-trash -q 2>$null }
        else { & $script:recycleRclone deletefile $path --local-use-trash -q 2>$null }
        return $LASTEXITCODE
    }
    return [RecycleBin]::Delete($path)
}
