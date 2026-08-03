# Handover: DriveFS-Ablösung durch rclone-basierten Sync

**Nachtrag 15:20 Uhr — Develop-Restrukturierung bereits erfolgt**: Die Git-basierten Repos wurden aus dem Sync-Korpus herausgezogen: `D:\Meine Ablage\Develop\github\` → **`D:\Develop\github\`** (lokal, unsynct; Backup via Git-Remotes). Der Rest von `Develop` (nicht Git-basiert, braucht Drive als Backup) bleibt in `D:\Meine Ablage\Develop`. Damit liegt dieses ai-toolbox-Repo inkl. dieses Handovers neu unter `D:\Develop\github\danielfrey63\ai-toolbox\`. Bereits nachgezogene Referenzen: Symlink `~/.claude/CLAUDE.md` und Junctions `~/.claude/skills/{gdrive,transcribe}`. Cloud-seitig existiert `Meine Ablage/Develop/github` noch (Stand 27.07.) und muss vor der rclone-Baseline in Drive gelöscht werden, sonst lädt `--resync` alles wieder herunter (verschärft Punkt 2 der Schritte in Abschnitt 5). Rest-Pendenz: `server-landscape` wurde nach `D:\Develop` kopiert (117'840 Dateien, 4,05 GB, robocopy 0 Fehler); das durch einen unbekannten Prozess gesperrte Original unter `D:\Meine Ablage\Develop\github\danielfrey63\server-landscape` wird nach Verifikation gelöscht (Rename war blockiert, Copy ging).

**Nachtrag 2 (~16:00 Uhr)**: Weitere Checkouts ausquartiert: 9 SBB-Repos (`D:\Meine Ablage\Akros\Kunden\SBB\Develop\<repo>` → `D:\Develop\sbb\`; Plain-Verzeichnisse bleiben in der Ablage) und `SEM\Auftrag` → `D:\Develop\sem`. Abschluss via `ai-toolbox/scripts/finish-checkout-migration.ps1` (nach Schliessen von Claude/VS Code). **Backup-Lücke beachten**: Uncommittete/ungepushte Stände (v.a. `dokumentations-tools` mit bewusst git-ignorierten lokalen Daten wie `dfa-betrieb/conversations/`) haben nach dem Move weder Git-Remote- noch Drive-Backup — bei der rclone-Konzeption entscheiden, ob `D:\Develop` als zweite rclone-Quelle (nur ignored/uncommitted-Bereiche) aufgenommen wird oder solche lokalen Daten zurück in die Ablage wandern.

Stand: 2026-07-30, ~15:00 Uhr. Quelle: Session «DebugPWSH@WORK» im Repo `dokumentations-tools`. Ziel dieses Dokuments: Eine frische Session kann ohne Vorwissen den Umbau von Google DriveFS auf einen rclone-basierten Sync umsetzen.

## 1. Ausgangslage und Diagnose (abgeschlossen)

Symptom war: PowerShell-Start (pwsh 7.6.4 UND Windows PowerShell 5.1) dauerte Minuten, auch mit `-NoProfile`; `cmd.exe` und `dotnet` waren schnell; nach Reboot jeweils kurz gut, dann degradierend.

Ursachenkette, per `dotnet-stack report` (Managed-Stack-Dump) bewiesen: PowerShell enumeriert beim Start alle Laufwerke (`FileSystemProvider.InitializeDefaultDrives()` → `GetVolumeInformation`). Das virtuelle DriveFS-Laufwerk `G:` beantwortete diese Anfrage nicht mehr (60-s-Timeouts), weil der `GoogleDriveFS.exe`-Prozess degeneriert war (RAM bis 11,6 GB).

Dahinter liegt das eigentliche Problem: Daniel hat am **27.07.2026** den DriveFS-State (`%LOCALAPPDATA%\Google\DriveFS`) gelöscht; seither versucht DriveFS eine Re-Baseline des Mirrors und scheitert systematisch. Jede Instanz bläht sich in ~10 Minuten auf ~6 GB RAM auf, dann wird `G:` unresponsiv («Wedge»), persistiert wird fast nichts. Ein Watchdog-gestützter Rebuild (Auto-Restart bei Wedge, 4 Restarts über ~1 h) brachte messbar keinen Fortschritt.

Harte Belege aus den DriveFS-SQLite-DBs (live read-only auslesbar, WAL-Modus): Cloud-Katalog `mirror_metadata_sqlite.db` → `items` = **2'501'482** Items; tatsächlich abgeglichen `mirror_sqlite.db` → `mirror_item` = 5'913 (14:00) → 6'150 (14:26) = **~500 Items/h** → hochgerechnet 200+ Tage. Fazit: DriveFS-Mirror ist bei 2,5 Mio. Items praktisch nicht rebuildfähig; Client ist proprietär, nicht konfigurierbar (keine Excludes), Blackbox.

## 2. Aktueller Maschinenzustand (wichtig!)

- **DriveFS ist AUS** (Prozesse gekillt, bewusst nicht neu gestartet). Kein `G:` mehr → Shells starten normal (~300 ms). Autostart ist vermutlich noch aktiv → **nach einem Reboot startet DriveFS wieder** und das Problem kehrt zurück, bis Schritt «DriveFS deaktivieren/deinstallieren» erledigt ist.
- **Seit 27.07. wird NICHT mehr in die Cloud synchronisiert.** Alle lokalen Änderungen seither existieren nur auf `D:\Meine Ablage` (echtes lokales Volume, Mirror-Wurzel). Die lokale Seite ist damit die führende, aktuellste Kopie.
- DriveFS-Konfiguration: Account `102913154019465320149` = Mirror `G:` ↔ `D:\Meine Ablage`; zweiter Account `112988577544768575058` mit Mount-Point `H` konfiguriert (war zuletzt nicht aktiv gemountet). Registry: `HKCU\SOFTWARE\Google\DriveFS`.
- Installierte DriveFS-Versionen: `C:\Program Files\Google\Drive File Stream\{127.0.1.0, 128.0.0.0}`; State-Verzeichnis `%LOCALAPPDATA%\Google\DriveFS` (~3,9 GB, grösstenteils content_cache).

## 3. Artefakte aus der Debug-Session

- `%LOCALAPPDATA%\Temp\drivefs-watchdog.sh` — Bash-Watchdog (Start/Überwachung/Auto-Restart DriveFS; obsolet nach Umbau, aber als Referenz nützlich).
- `%LOCALAPPDATA%\Temp\drivefs-watchdog.log` und `%LOCALAPPDATA%\Temp\drivefs-memwatch.log` — Messreihen (RAM, G:-Antwortzeiten, Restarts).
- DriveFS-Logs: `%LOCALAPPDATA%\Google\DriveFS\Logs\drive_fs*.txt` — Zeitstempel in **UTC** (lokal −2 h im Sommer).
- Fortschritts-Query (live, gefahrlos): `sqlite3 "file:C:/Users/Daniel/AppData/Local/Google/DriveFS/102913154019465320149/mirror_sqlite.db?mode=ro" "SELECT COUNT(*) FROM mirror_item;"` (sqlite3 via miniconda im PATH).
- Diagnose-Tool: `dotnet-stack` als globales dotnet-Tool installiert (`~/.dotnet/tools`).
- Memory-Notiz der Session: `pwsh-slow-startup-drivefs.md` im Claude-Memory des Projekts `dokumentations-tools`.

## 4. Entscheid und Vorschlag

Grundsatzentscheid (Daniel, mündlich in der Session): DriveFS wird durch einen **rclone-basierten Sync** ersetzt; `D:\Meine Ablage` bleibt unverändert die lokale Arbeitskopie. rclone ist Open Source (MIT, Go, github.com/rclone/rclone).

Vorgeschlagene Stufen-Architektur (bewusst so, dass erst geforkt wird, wenn es wirklich nötig ist — keine Duplikation, Wartungslast minimieren):

- **Stufe A — rclone als Binary + eigenes Tooling-Repo (Start hier).** rclone via Scoop installieren. Eigenes Repo bzw. dieses Verzeichnis (`ai-toolbox/drive-sync/`) enthält: rclone-Filter-Datei (Excludes: `node_modules/`, `.venv/`, `__pycache__/`, Build-Outputs, …), Wrapper-Skript für `rclone bisync` (idempotent, Desired-State, Logging), geplanten Task (Scheduled Task) und einen kleinen Status-Check. Das «Intelligentere» gegenüber DriveFS sind hier: explizite Filter, beobachtbarer Zustand, deterministische Läufe.
- **Stufe B — eigene Logik via RC-API/librclone.** Falls Wrapper-Niveau nicht reicht (z.B. Watcher, der nur geänderte Teilbäume sofort synct; eigene Konflikt-Heuristiken): rclone als Daemon (`rclone rcd`) oder `librclone` einbetten und die Intelligenz als dünne Schicht obendrauf bauen. Immer noch kein Fork.
- **Stufe C — Fork nur bei Kernbedarf.** Erst wenn Verhalten im rclone-Kern geändert werden muss: Fork `danielfrey63/rclone` auf GitHub, Upstream als Remote behalten, eigene Änderungen als schmale, rebasebare Patches führen und wo sinnvoll als PR upstreamen. (Reines Lese-/Verständnis-Bedürfnis braucht keinen Fork — Clone reicht.)

## 5. Konkrete nächste Schritte (neue Session)

1. **DriveFS dauerhaft stilllegen**: Autostart deaktivieren (Run-Key/Startup prüfen), besser gleich deinstallieren; falls Deinstallation warten soll: sicherstellen, dass er nicht wieder anläuft. Erst NACH erfolgreichem rclone-Baseline-Lauf das State-Verzeichnis `%LOCALAPPDATA%\Google\DriveFS` (~3,9 GB) löschen.
2. **rclone installieren** (`scoop install rclone`) und Remote `gdrive:` konfigurieren (`rclone config`, OAuth im Browser durch Daniel; eigenes Google-API-Client-ID/Secret anlegen lohnt sich wegen Rate-Limits — Anleitung: rclone-Doku «Google drive → Making your own client_id»).
3. **Korpus-Analyse** auf `D:\Meine Ablage`: Dateien/Verzeichnisse pro Top-Level zählen (welche Bäume liefern die Millionen Kleindateien?). Daraus die Exclude-Filterliste ableiten und mit Daniel abstimmen. Offene Frage dabei: `.git`-Verzeichnisse syncen oder excluden (Repos haben Remotes als Backup)?
4. **Google-native Dateien klären**: Bestand an `.gsheet`/`.gdoc`/`.gslides`-Pointern erheben; Strategie wählen (rclone `--drive-export-formats url` als Link-Dateien o.ä.) und mit Daniel abstimmen — Verhaltensunterschied zu DriveFS!
5. **Baseline**: `rclone bisync "D:/Meine Ablage" gdrive: --resync` — vorher zwingend Dry-Run (`--dry-run`) und Review der geplanten Aktionen. Lokale Seite ist führend (Cloud hat den Stand vom 27.07.). Zweiter Account/`H:`-Mount separat behandeln (eigenes Remote), falls noch benötigt.
6. **Betrieb**: Scheduled Task für periodisches `bisync` (mit Lock gegen Überlappung), Log-Rotation, kleiner Status-Check (z.B. letzte erfolgreiche Sync-Zeit) — alles idempotent.
7. **Verifikation/Abschluss**: Stichproben-Vergleich lokal↔Cloud, danach DriveFS deinstallieren, State löschen, Memory-Notizen in `dokumentations-tools` aktualisieren (Problem gelöst, neue Architektur dokumentieren).

## 6. Risiken und Caveats

- **Kein Sync bis zur Baseline** — je länger der Umbau wartet, desto grösser das Backup-Loch seit 27.07. (Priorität!)
- `bisync --resync` bei 2,5 Mio. Cloud-Items: erster Listing-Lauf dauert Stunden und braucht API-Kontingent; mit eigener client_id und ausserhalb der Arbeitszeit fahren. Danach mit Filtern deutlich kleiner.
- Konflikte: bisync legt `.conflict`-Kopien an statt still zu überschreiben — gewollt, aber Aufräumbedarf einplanen.
- Google-Docs-Pointer und von DriveFS speziell behandelte Dateien (Shortcuts, Shared-Content) verhalten sich unter rclone anders — Schritt 4 nicht überspringen.
- SBB-Gäste-WLAN: Bandbreite/Captive-Portal können grosse Läufe bremsen.

## 7. Erfolgskriterien

PowerShell startet dauerhaft <1 s (kein `G:` mehr in `fsutil fsinfo drives`); `D:\Meine Ablage` wird wieder zuverlässig und nachvollziehbar mit Google Drive synchronisiert (Log zeigt letzte erfolgreiche Läufe); kein Prozess wächst unkontrolliert; alles reproduzierbar aus `ai-toolbox/drive-sync/` heraus.
