# Shared read-side helpers for rclone's bisync baseline listings.
#
# A listing is one header line plus one line per entry:
#   # bisync listing v1 from 2026-09-05T03:31:55.775751300+0000
#   -   106997 - - 2022-04-26T07:04:29.124000000+0000 "Agile Lean Teal/.../x.pdf"
#
# Measured on the 1'311'691-entry corpus (2026-09-05):
#  - both sides carry the SAME paths and sizes; only the modtime differs, path2
#    being path1 truncated to milliseconds (115'139 of 115'139 cases, no rounding)
#  - 996 entries (0.076 %) contain a \uXXXX escape. rclone escapes invisible and
#    ambiguous characters - U+00A0, U+2006, U+00AD - and writes accented letters
#    raw. It SORTS by the unescaped path but WRITES the escaped one, which is why
#    a hand-built line can land in the wrong place or be read as a different path.
#    Reason enough never to write into a listing: the deletes bisync cannot see
#    on its own are carried out directly instead (journal-replay.ps1).

# rclone's default bisync workdir on Windows; override via config if it moves
function Get-BisyncWorkDir {
    if ($DriveSyncConfig.BisyncWorkDir) { return $DriveSyncConfig.BisyncWorkDir }
    Join-Path $env:LOCALAPPDATA "rclone\bisync"
}

function Get-BisyncListings([string]$localPath, [string]$remote) {
    $dir = Get-BisyncWorkDir
    if (-not (Test-Path $dir)) { return $null }
    # rclone mangles both endpoints into the file name; derive it, and fall back
    # to a glob when the derivation and the actual naming disagree
    $mangle = { param($s) ($s -replace '[^A-Za-z0-9]', '_') }
    $stem = "$(& $mangle $localPath)..$(& $mangle $remote)"
    $p1 = Join-Path $dir "$stem.path1.lst"
    $p2 = Join-Path $dir "$stem.path2.lst"
    if (-not (Test-Path $p1) -or -not (Test-Path $p2)) {
        $cand = @(Get-ChildItem -Path $dir -Filter "*.path1.lst" -File -ErrorAction SilentlyContinue)
        if ($cand.Count -ne 1) { return $null }
        $p1 = $cand[0].FullName
        $p2 = $p1 -replace '\.path1\.lst$', '.path2.lst'
        if (-not (Test-Path $p2)) { return $null }
    }
    [pscustomobject]@{ Path1 = $p1; Path2 = $p2 }
}
