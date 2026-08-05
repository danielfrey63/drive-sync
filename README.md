# Drive-Sync: `D:\Meine Ablage` ↔ Google Drive via rclone

Ersetzt Google DriveFS (stillgelegt 08/2026, Hintergrund im [Handover](HANDOVER-2026-07-30-drivefs-rclone.md)) durch einen dreistufigen Sync:

1. **Nacht-bisync** (täglich 04:00): `sync-drive.ps1` fährt einen vollen `rclone bisync` als Auffangnetz für alles, was die Watcher nicht abdecken (Konflikte, Verzeichnis-Renames in der Cloud, verpasste Events). Ein Volllauf listet ~1.6 Mio. Dateien und braucht ~25 Minuten.
2. **Upload-Watcher** (`watch-drive.ps1`, permanent): FileSystemWatcher auf `D:\Meine Ablage`, lädt neue/geänderte Dateien nach ~20–40 s hoch, propagiert Renames server-seitig (`moveto`) und verifizierte Deletes in den **Drive-Papierkorb** (Cap: 50 pro Flush).
3. **Cloud-Watcher** (`watch-cloud.ps1`, permanent): pollt die Google-Drive-Changes-API im 60-s-Takt, lädt neue/geänderte Cloud-Dateien nach ~1–2 min herunter und verschiebt cloud-seitig Gelöschtes in den **Windows-Papierkorb** (Cap: 50). Eigene Uploads werden über ein Ledger erkannt und übersprungen (Echo-Kontrolle).

Grundprinzip: **Nichts wird hart gelöscht** — Löschungen landen immer im jeweiligen Papierkorb (Drive-Trash 30 Tage bzw. Windows-Papierkorb).

## Komponenten

| Datei | Zweck |
| --- | --- |
| `sync-drive.ps1` | bisync-Wrapper (Lock, Logs, `status.json`); `-Resync` für Re-Baseline, `-DryRun` zum Testen |
| `watch-drive.ps1` | Upload-Watcher lokal → Cloud (New/Update/Rename/Delete) |
| `watch-cloud.ps1` | Download-Watcher Cloud → lokal (New/Update/Trash); `-Once` für einen Testzyklus |
| `watchdog.ps1` | startet alle 15 min still gestorbene Watcher neu |
| `filter-rules.ps1` | gemeinsame Exclude-Logik der Watcher, abgeleitet aus `filters.txt` |
| `filters.txt` | Include-/Exclude-Regeln für bisync und Watcher (nach Änderung: `-Resync` nötig!) |
| `run-hidden.vbs` | fensterloser Task-Launcher (verhindert das Aufblitzen von Konsolenfenstern) |
| `install-sync-task.ps1` | registriert den Nacht-bisync-Task |
| `install-watcher-task.ps1` | registriert Watcher- und Watchdog-Tasks |
| `uninstall.ps1` | stoppt Watcher und entfernt alle vier Tasks (`-RemoveState` löscht zusätzlich das State-Verzeichnis) |
| `sync-status.ps1` | Status-Übersicht (letzter bisync, Watcher-Zähler) |
| `howto-google-oauth.md` | Anleitung: eigene Google-OAuth-Client-ID erstellen |

## Voraussetzungen

- PowerShell 7 (`scoop install pwsh`) und rclone (`scoop install rclone`).
- Eigene Google-OAuth-Client-ID (siehe `howto-google-oauth.md`); das heruntergeladene `client_secret_*.json` liegt in diesem Ordner und ist per `.gitignore` vom Commit ausgeschlossen — **niemals committen**.
- Ein konfiguriertes rclone-Remote namens `gdrive` (Typ `drive`, scope `drive`, client_id/client_secret aus dem JSON): `rclone config` starten und dem Assistenten folgen; die Autorisierung öffnet den Browser.

## Installation

1. Voraussetzungen oben herstellen (`rclone lsd gdrive:` muss funktionieren).
2. `filters.txt` prüfen bzw. an den eigenen Korpus anpassen.
3. Baseline erstellen: `pwsh -File sync-drive.ps1 -Resync` — der Erstlauf gleicht lokal und Cloud vollständig ab und kann mehrere Stunden dauern.
4. `pwsh -File install-sync-task.ps1` — registriert den täglichen bisync (Standard 04:00, änderbar via `-DailyAt "HH:mm"`).
5. `pwsh -File install-watcher-task.ps1` — registriert und startet beide Watcher plus den Watchdog.
6. Kontrolle: `pwsh -File sync-status.ps1`.

Alle Installer sind idempotent: erneutes Ausführen aktualisiert die Task-Definitionen, ohne laufende Watcher zu stören (bereits laufende Instanzen werden über ihre PID-Locks erkannt).

### Manuelle Einrichtung (ohne Installer-Skripte)

Die vier Tasks lassen sich auch von Hand in der Aufgabenplanung (`taskschd.msc`) anlegen — als angemeldeter Benutzer, «Nur ausführen, wenn der Benutzer angemeldet ist»:

| Task | Trigger | Aktion | Einstellungen |
| --- | --- | --- | --- |
| `DriveSync watcher` | Bei Anmeldung | `wscript.exe` mit Argumenten `//B //Nologo "<repo>\drive-sync\run-hidden.vbs" "<pfad>\pwsh.exe" -NoProfile -File "<repo>\drive-sync\watch-drive.ps1"` | keine Zeitbeschränkung; neue Instanz nicht starten, wenn bereits aktiv |
| `DriveSync cloud watcher` | Bei Anmeldung | wie oben, mit `watch-cloud.ps1` | wie oben |
| `DriveSync watchdog` | Einmalig, danach alle 15 min wiederholen | wie oben, mit `watchdog.ps1` | Zeitbeschränkung 5 min; «So schnell wie möglich nach einem verpassten Start ausführen» |
| `DriveSync rclone bisync` | Täglich 04:00 | `pwsh.exe` mit Argumenten `-NoProfile -WindowStyle Hidden -File "<repo>\drive-sync\sync-drive.ps1"` | Zeitbeschränkung 6 h; nur bei Netzwerkverbindung; verpasste Starts nachholen |

Der Umweg über `wscript.exe` + `run-hidden.vbs` ist nötig, weil `pwsh -WindowStyle Hidden` beim Start trotzdem kurz ein Konsolenfenster aufblitzen lässt. Der bisync-Task läuft bewusst **ohne** Wrapper: Nur so kann seine 6-h-Zeitbeschränkung einen hängenden Lauf abbrechen — dafür blitzt bei einem nachgeholten Tageslauf einmal kurz ein Fenster auf (der reguläre 04:00-Lauf stört niemanden).

## Betrieb und Monitoring

Sämtlicher Laufzeit-State liegt unter `%LOCALAPPDATA%\drive-sync\`:

| Pfad | Inhalt |
| --- | --- |
| `status.json` | letzter und letzter erfolgreicher bisync-Lauf |
| `logs\bisync-*.log` | ein Log pro bisync-Lauf, die neuesten 30 werden behalten |
| `watcher.log`, `cloud-watcher.log` | Watcher-Logs (Rotation bei 1 MB), inkl. 10-min-Heartbeats |
| `watcher.lock`, `cloud-watcher.lock`, `sync.lock` | PID-Locks (Single-Instance bzw. bisync-Vorrang) |
| `watcher-status.json`, `cloud-watcher-status.json` | Zähler für `sync-status.ps1` |
| `cloud-watcher-pagetoken.txt` | persistenter Changes-API-Cursor; löschen = Neustart ab «jetzt» (Lücke schliesst der nächste bisync) |
| `upload-ledger.txt` | Echo-Kontrolle: eigene Uploads der letzten 30 min |
| `watchdog.log`, `watchdog-pause` | Watchdog-Log; die Marker-Datei `watchdog-pause` unterdrückt Neustarts für Wartungsfenster (wird nach 6 h automatisch verworfen) |
| `bin\rclone.exe` | optionaler Custom-Build (aktuell: v1.75.0 + `--files-from-strict`- und `--local-use-trash`-Backports); die Watcher bevorzugen ihn, Löschen fällt auf das PATH-rclone zurück |

Nützliche Handgriffe: `pwsh -File sync-status.ps1` für den Gesamtstatus; `pwsh -File sync-drive.ps1` für einen manuellen bisync; für Wartung `Set-Content "$env:LOCALAPPDATA\drive-sync\watchdog-pause" "grund"` setzen und danach wieder löschen.

## Deinstallation

Skriptiert: `pwsh -File uninstall.ps1` stoppt beide Watcher-Prozesse und entfernt alle vier Tasks; mit `-RemoveState` wird zusätzlich `%LOCALAPPDATA%\drive-sync` (Logs, Cursor, Custom-Build) gelöscht.

Manuell entspricht das diesen Schritten:

1. Watcher-Prozesse beenden: PIDs stehen in `%LOCALAPPDATA%\drive-sync\watcher.lock` und `cloud-watcher.lock` (`Stop-Process -Id <pid>`). Läuft gerade ein bisync (PID in `sync.lock` lebt), diesen zuerst ausrichten lassen.
2. Die vier Tasks löschen: `schtasks /Delete /F /TN "DriveSync watcher"`, `... "DriveSync cloud watcher"`, `... "DriveSync watchdog"`, `... "DriveSync rclone bisync"` (oder in `taskschd.msc`).
3. Optional den State löschen: `Remove-Item -Recurse -Force "$env:LOCALAPPDATA\drive-sync"`.
4. Optional das rclone-Remote entfernen (`rclone config delete gdrive`) und den OAuth-Zugriff im Google-Konto widerrufen (Sicherheit → Verbindungen zu Drittanbieter-Apps).

Die Deinstallation fasst **keine Nutzdaten** an: `D:\Meine Ablage` und der Cloud-Bestand bleiben unverändert, es endet lediglich die Synchronisation.
