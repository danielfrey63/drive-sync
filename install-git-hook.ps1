# Adds the text check (githooks/check-text.sh) to this clone's pre-commit hook.
# Idempotent; run once per machine. .git/ is excluded from the sync, so the
# P16 does not get the hook through Drive.
#
# The hook file belongs to ai-toolbox (one managed "toolbox-bump" line); this
# adds a second, marked line next to it instead of redirecting core.hooksPath,
# which would switch the toolbox hook off.
#
#   pwsh -File install-git-hook.ps1

$ErrorActionPreference = "Stop"
$marker = "# drive-sync:check-text"
$line = 'sh "$(git rev-parse --show-toplevel)/githooks/check-text.sh" || exit 1   ' + $marker

$hooksDir = (& git -C $PSScriptRoot rev-parse --git-path hooks)
if (-not [IO.Path]::IsPathRooted($hooksDir)) { $hooksDir = Join-Path $PSScriptRoot $hooksDir }
New-Item -ItemType Directory -Force $hooksDir | Out-Null
$hook = Join-Path $hooksDir "pre-commit"

$lines = if (Test-Path $hook) { @(Get-Content $hook) } else { @("#!/bin/sh") }
if ($lines -match [regex]::Escape($marker)) {
    Write-Host "pre-commit: check-text already installed ($hook)"
    exit 0
}
# the check runs first: a commit it rejects needs no version bump
$out = @($lines[0], $line) + @($lines | Select-Object -Skip 1)
# hooks run in sh: LF only
[IO.File]::WriteAllText($hook, (($out -join "`n") + "`n"))
Write-Host "pre-commit: check-text installed ($hook)"
