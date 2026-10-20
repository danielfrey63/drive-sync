# Windows toast alerts for the drive-sync chain. Dot-source after config.ps1.
#
# Why: from 2026-10-09 to 2026-10-20 every nightly bisync aborted with exit 7
# ("Must run --resync") and the watchers crash-looped for the last hours of
# it - all written to logs nobody reads. A failure that needs a human now
# raises a toast that stays in the Action Center until dismissed.
#
#   Send-DriveSyncAlert -Key "bisync-resync" -Title "..." -Body "..."
#   Clear-DriveSyncAlert -Key "bisync-resync"     # condition is gone again
#
# Each key fires at most once per $DriveSyncConfig.AlertRepeatHours (default
# 12): a crash-looping watcher must not spam a toast every 15 minutes, but a
# condition that persists over night is raised again the next morning.
# Clearing a key re-arms it, so a NEW failure after a recovery alerts at once.
#
# The toast itself comes from ai-toolbox\tools\notify\toast.ps1 (sibling repo,
# handles the pwsh -> Windows PowerShell 5.1 hand-over for WinRT). Without it
# the alert is only logged to alerts.log - never an error for the caller.

$script:alertStateFile = Join-Path $DriveSyncConfig.StateDir "alerts.json"
$script:alertLogFile = Join-Path $DriveSyncConfig.StateDir "alerts.log"
$script:toastScript = Join-Path $PSScriptRoot "..\ai-toolbox\tools\notify\toast.ps1"

function Get-DriveSyncAlertState {
    try {
        if (Test-Path -LiteralPath $script:alertStateFile) {
            $o = Get-Content -LiteralPath $script:alertStateFile -Raw | ConvertFrom-Json
            $h = @{}
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = [long]$p.Value }
            return $h
        }
    }
    catch {}
    return @{}
}

function Save-DriveSyncAlertState([hashtable]$state) {
    try {
        $tmp = "$script:alertStateFile.tmp"
        Set-Content -LiteralPath $tmp -Value ($state | ConvertTo-Json -Compress) -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $script:alertStateFile -Force
    }
    catch {}
}

function Write-DriveSyncAlertLog([string]$msg) {
    try { Add-Content -LiteralPath $script:alertLogFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" } catch {}
}

# Returns $true if a toast was handed to Windows, $false if suppressed or
# unavailable. Never throws.
function Send-DriveSyncAlert {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Title,
        [string]$Body = '',
        [switch]$Force
    )
    try {
        $repeatH = if ($DriveSyncConfig.AlertRepeatHours) { [double]$DriveSyncConfig.AlertRepeatHours } else { 12 }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $state = Get-DriveSyncAlertState
        if (-not $Force -and $state.ContainsKey($Key) -and ($now - $state[$Key]) -lt ($repeatH * 3600)) {
            return $false
        }
        $state[$Key] = $now
        Save-DriveSyncAlertState $state
        Write-DriveSyncAlertLog "ALERT [$Key] $Title | $Body"
        if (-not (Test-Path -LiteralPath $script:toastScript)) {
            Write-DriveSyncAlertLog "toast helper missing ($script:toastScript) - logged only"
            return $false
        }
        # called as a script, not dot-sourced: its param block would rebind
        # $Title/$Body to empty in the dot-sourcing scope
        & $script:toastScript -Title $Title -Body $Body -Reminder -AppId 'DriveSync.Alerts' -AppName 'Drive-Sync'
        return $true
    }
    catch {
        Write-DriveSyncAlertLog "WARN alert [$Key] failed: $($_.Exception.Message)"
        return $false
    }
}

function Clear-DriveSyncAlert([string]$Key) {
    try {
        $state = Get-DriveSyncAlertState
        if (-not $state.ContainsKey($Key)) { return }
        $state.Remove($Key)
        Save-DriveSyncAlertState $state
        Write-DriveSyncAlertLog "clear [$Key]"
    }
    catch {}
}
