# Exercises the three links of the 2026-10-02..05 conflict cascade against a
# scratch state directory and a scratch tree: the upload ledger's echo check
# (upload-ledger.ps1), the conflict-loser rename filter and the sweep's log
# parser (conflict-names.ps1). Touches neither the real watchers, the real
# state directory nor the cloud; safe to run any time.
#
#   pwsh -File test-conflict-chain.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "upload-ledger.ps1")
. (Join-Path $PSScriptRoot "conflict-names.ps1")

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("conflict-chain-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$stateDir = Join-Path $scratch "state"
$root = Join-Path $scratch "root"
New-Item -ItemType Directory -Force $stateDir, (Join-Path $root "setup") | Out-Null

$script:failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:failures++ }
    Write-Host ("{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($detail) { "  ($detail)" } else { "" }))
}
function Unix([datetime]$utc) { [DateTimeOffset]::new([datetime]::SpecifyKind($utc, [DateTimeKind]::Utc)).ToUnixTimeSeconds() }

try {
    # --- upload ledger -------------------------------------------------------
    # the 2026-10-03 case: we upload install.ps1 (15:20 stand), the other
    # machine changes it 42 minutes later
    $rel = "setup\install.ps1"
    $abs = Join-Path $root $rel
    Set-Content $abs ("a" * 100) -NoNewline
    $t1520 = [datetime]::new(2026, 10, 3, 13, 20, 4, [DateTimeKind]::Utc)
    (Get-Item $abs).LastWriteTimeUtc = $t1520
    $size = (Get-Item $abs).Length

    Check "leeres Ledger: nichts ist ein Echo" (-not (Test-UploadEcho (Get-UploadLedger $stateDir) $rel (Unix $t1520) $size))

    Add-UploadLedger $stateDir $root @($rel)
    $ledger = Get-UploadLedger $stateDir
    $line = Get-Content (Get-UploadLedgerPath $stateDir) | Select-Object -Last 1
    Check "Eintrag traegt Modtime und Groesse" ($line -match "^\d+`t$([regex]::Escape($rel))`t$(Unix $t1520)`t$size$") $line

    Check "eigener Upload (gleiche Modtime, gleiche Groesse) ist ein Echo" (Test-UploadEcho $ledger $rel (Unix $t1520) $size)
    Check "Modtime 1 s daneben ist noch ein Echo (modify-window)" (Test-UploadEcho $ledger $rel ((Unix $t1520) + 1) $size)
    $t1602 = [datetime]::new(2026, 10, 3, 14, 2, 21, [DateTimeKind]::Utc)
    Check "fremde Aenderung 42 min spaeter ist KEIN Echo" (-not (Test-UploadEcho $ledger $rel (Unix $t1602) ($size + 412)))
    Check "gleiche Modtime, andere Groesse ist KEIN Echo" (-not (Test-UploadEcho $ledger $rel (Unix $t1520) ($size + 1)))
    Check "Pfadvergleich ignoriert Gross-/Kleinschreibung" (Test-UploadEcho $ledger $rel.ToUpperInvariant() (Unix $t1520) $size)
    Check "unbekannter Pfad ist kein Echo" (-not (Test-UploadEcho $ledger "setup\other.ps1" (Unix $t1520) $size))
    Check "Event ohne Metadaten faellt auf Pfadvergleich zurueck" (Test-UploadEcho $ledger $rel $null $null)

    # two uploads of the same path inside the window: both stands are echoes
    Set-Content $abs ("b" * 150) -NoNewline
    (Get-Item $abs).LastWriteTimeUtc = $t1602
    Add-UploadLedger $stateDir $root @($rel)
    $ledger = Get-UploadLedger $stateDir
    Check "zwei Uploads: erster Stand bleibt Echo" (Test-UploadEcho $ledger $rel (Unix $t1520) $size)
    Check "zwei Uploads: zweiter Stand ist Echo" (Test-UploadEcho $ledger $rel (Unix $t1602) 150)

    # path without a local file (renamed away before the ledger write) and
    # lines written by the previous watcher version: path-only, as before
    Add-UploadLedger $stateDir $root @("setup\gone.txt")
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Add-Content (Get-UploadLedgerPath $stateDir) "$now`tsetup\legacy.txt"
    $ledger = Get-UploadLedger $stateDir
    Check "Eintrag ohne lokale Datei: jeder Stand ist Echo" (Test-UploadEcho $ledger "setup\gone.txt" 1 1)
    Check "Altformat-Zeile: jeder Stand ist Echo" (Test-UploadEcho $ledger "setup\legacy.txt" 1 1)

    # expiry
    $old = $now - 3700
    Set-Content (Get-UploadLedgerPath $stateDir) @("$old`tsetup\expired.txt`t1`t1", "$now`tsetup\fresh.txt`t1`t1")
    $ledger = Get-UploadLedger $stateDir
    Check "abgelaufener Eintrag wird nicht gelesen" (-not $ledger.ContainsKey("setup\expired.txt") -and $ledger.ContainsKey("setup\fresh.txt"))
    Add-UploadLedger $stateDir $root @($rel)
    Check "abgelaufener Eintrag wird beim Schreiben entfernt" (-not ((Get-Content (Get-UploadLedgerPath $stateDir)) -match 'expired'))
    Check "kein .tmp-Rest nach dem Schreiben" (-not (Test-Path "$(Get-UploadLedgerPath $stateDir).tmp"))

    # modifiedTime conversion (PS7 hands over [datetime], 5.1 the raw string)
    Check "Zeit aus RFC-3339-String" ((ConvertTo-UploadLedgerTime "2026-10-03T14:02:21.978Z") -eq (Unix $t1602))
    Check "Zeit aus UTC-DateTime" ((ConvertTo-UploadLedgerTime $t1602) -eq (Unix $t1602))
    Check "Zeit aus lokalem DateTime" ((ConvertTo-UploadLedgerTime $t1602.ToLocalTime()) -eq (Unix $t1602))
    Check "Zeit aus DateTime ohne Kind gilt als UTC" ((ConvertTo-UploadLedgerTime ([datetime]::SpecifyKind($t1602, [DateTimeKind]::Unspecified))) -eq (Unix $t1602))
    Check "leere/kaputte Zeit ergibt null" (($null -eq (ConvertTo-UploadLedgerTime $null)) -and ($null -eq (ConvertTo-UploadLedgerTime "kaputt")))

    # --- conflict-loser rename filter ----------------------------------------
    Check "X -> X.conflict1 ist ein bisync-Verlierer" (Test-ConflictLoserRename "setup\install.ps1" "setup\install.ps1.conflict1")
    Check "X.conflict1 -> X.conflict1.conflict1 ebenso" (Test-ConflictLoserRename "a\b.md.conflict1" "a\b.md.conflict1.conflict1")
    Check "mehrstellige Nummer" (Test-ConflictLoserRename "a\b.md" "a\b.md.conflict12")
    Check "Gross-/Kleinschreibung im Pfad egal" (Test-ConflictLoserRename "A\B.md" "a\b.md.conflict1")
    Check "normale Umbenennung bleibt eine Umbenennung" (-not (Test-ConflictLoserRename "a\b.md" "a\c.md"))
    Check "Editor-Temp-Save bleibt eine Umbenennung" (-not (Test-ConflictLoserRename "a\b.md.tmp.123" "a\b.md"))
    Check "Rueckbenennung X.conflict1 -> X ist kein Verlierer" (-not (Test-ConflictLoserRename "a\b.md.conflict1" "a\b.md"))
    Check "anderer Zusatz als .conflictN zaehlt nicht" (-not (Test-ConflictLoserRename "a\b.md" "a\b.md.conflict1.bak"))
    Check "Verschieben in anderen Ordner zaehlt nicht" (-not (Test-ConflictLoserRename "a\b.md" "c\b.md.conflict1"))

    # --- sweep log parser ----------------------------------------------------
    $r = "D:\Meine Ablage"
    $p1 = '2026/10/04 04:15:55 NOTICE: - Path1             Renaming Path1 copy                         - D:\Meine Ablage\Develop/danielfrey63/laptop-setup/setup/install.ps1.conflict1'
    $p2 = '2026/09/02 04:22:02 NOTICE: - Path2             Renaming Path2 copy                         - gdrive{sl-MZ}:/Develop/danielfrey63/pmo/tools/agent.py.conflict1'
    $win = '2026/10/05 04:19:41 NOTICE: - Path2             Not renaming Path2 copy, as it was determined the winner - gdrive{sl-MZ}:/Develop/danielfrey63/laptop-setup/setup/install.ps1.conflict1.conflict1'
    $queue = '2026/10/04 04:15:55 NOTICE: - Path1             Queue copy to Path2                         - gdrive{sl-MZ}:/Develop/danielfrey63/laptop-setup/setup/install.ps1.conflict1'
    Check "Path1-Zeile mit Laufwerksbuchstabe (der Fehler vom 04.10.)" ((Get-ConflictLoserRel $p1 $r) -eq 'Develop\danielfrey63\laptop-setup\setup\install.ps1.conflict1') (Get-ConflictLoserRel $p1 $r)
    Check "Path1-Zeile, Root mit abschliessendem Backslash" ((Get-ConflictLoserRel $p1 "$r\") -eq 'Develop\danielfrey63\laptop-setup\setup\install.ps1.conflict1')
    Check "Path2-Zeile mit Remote-Praefix" ((Get-ConflictLoserRel $p2 $r) -eq 'Develop\danielfrey63\pmo\tools\agent.py.conflict1') (Get-ConflictLoserRel $p2 $r)
    Check "Gewinner-Zeile (Not renaming) ist kein Verlierer" ($null -eq (Get-ConflictLoserRel $win $r))
    Check "Queue-Zeile ist kein Verlierer" ($null -eq (Get-ConflictLoserRel $queue $r))
    Check "lokaler Pfad ausserhalb des Roots wird verworfen" ($null -eq (Get-ConflictLoserRel ($p1 -replace 'Meine Ablage', 'Andere Ablage') $r))
}
finally {
    [IO.Directory]::Delete($scratch, $true)
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) FAILED"; exit 1 }
Write-Host "`nall passed"
