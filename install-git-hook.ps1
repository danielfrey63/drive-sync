# Adds the drive-sync checks to this clone's pre-commit hook: the text check
# (githooks/check-text.sh) and the offline tests (run-tests.ps1 -IfStaged,
# which runs them only when a script or filters.txt is part of the commit).
# Idempotent; run once per machine, and again after this file changed. .git/
# is excluded from the sync, so the P16 does not get the hook through Drive.
#
# The hook file belongs to ai-toolbox (one managed "toolbox-bump" line); this
# keeps its own marked lines next to it instead of redirecting
# core.hooksPath, which would switch the toolbox hook off.
#
#   pwsh -File install-git-hook.ps1

$ErrorActionPreference = "Stop"
# in this order, ahead of everything else: a commit they reject needs no
# version bump, and the cheap check runs before the tests
$managed = @(
    @{ Marker = "# drive-sync:check-text"; Line = 'sh "$(git rev-parse --show-toplevel)/githooks/check-text.sh" || exit 1' }
    @{ Marker = "# drive-sync:run-tests"; Line = 'pwsh -NoProfile -File "$(git rev-parse --show-toplevel)/run-tests.ps1" -IfStaged || exit 1' }
)

$hooksDir = (& git -C $PSScriptRoot rev-parse --git-path hooks)
if (-not [IO.Path]::IsPathRooted($hooksDir)) { $hooksDir = Join-Path $PSScriptRoot $hooksDir }
New-Item -ItemType Directory -Force $hooksDir | Out-Null
$hook = Join-Path $hooksDir "pre-commit"

$lines = if (Test-Path $hook) { @(Get-Content $hook) } else { @("#!/bin/sh") }
$foreign = @($lines | Select-Object -Skip 1 | Where-Object { $l = $_; -not ($managed | Where-Object { $l.Contains($_.Marker) }) })
$out = @($lines[0]) + @($managed | ForEach-Object { "$($_.Line)   $($_.Marker)" }) + $foreign

if (($out -join "`n") -ceq ($lines -join "`n")) {
    Write-Host "pre-commit: drive-sync checks already installed ($hook)"
    exit 0
}
# hooks run in sh: LF only
[IO.File]::WriteAllText($hook, (($out -join "`n") + "`n"))
Write-Host "pre-commit: drive-sync checks installed ($hook)"
