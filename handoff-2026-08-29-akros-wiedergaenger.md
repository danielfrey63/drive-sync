# Hand-off: Wiedergänger-Ordner nach Aufräumaktion in `Develop/Akros` (28./29.08.2026)

Zusammengestellt aus der Session «Aufräumen@WORK» (Claude Code, Projekt `D:\Meine Ablage\Develop\Akros`). Zweck: der drive-sync-Session die Umstände liefern, unter denen lokal gelöschte bzw. verschobene Ordner wieder aufgetaucht sind, obwohl Löschungen laut Design in die Cloud gespiegelt werden. Alle Zeiten Lokalzeit (CEST). Logs: `%LOCALAPPDATA%\drive-sync\watcher.log`, `cloud-watcher.log`, `logs\bisync-20260829-040002.log`.

## Kurzfassung

Nicht Google Drive hat die Ordner wiederhergestellt, sondern die eigene Sync-Kette in zwei Schritten: (1) Der **Cloud-Watcher** hat um 23:24 und 23:30 Dateien, die der Upload-Watcher kurz zuvor selbst hochgeladen hatte, an die **alten lokalen Pfade** zurückgeladen, während diese Ordner gerade verschoben wurden. (2) Der **Nacht-bisync** hat um 04:22 die restlichen Dateien nachgeladen, weil er die per `moveto` umbenannten Cloud-Dateien als «Path2 File is new» einstufte und lokal nie eine Löschung dieser (neuen) Namen gesehen hatte. Verzeichnis-Renames und -Löschungen wurden vom Upload-Watcher in der ganzen Nacht nicht propagiert (nur `events: N drained, 0 ren / 0 del pending`).

## Ablauf mit Belegen

### 23:05 bis 23:10, Vorbereitung durch Daniel (vor der Aufräumsession)

Neue Aufzeichnung `2026-08-28-14-00-16 - CC AI Kerteam.{docx,vtt,mp4}` (mp4 486 MB) nach `Develop/Akros/CCAI/CCAI/protokolle/` gelegt, danach 10 bestehende Protokoll-Dateien umbenannt (`20260619-104500 - …` zu `2026-06-19-10-45-00 - …`).

```
watcher.log
2026-08-28 23:05:33 events: 7 drained, 3 up / 0 ren / 0 del pending
2026-08-28 23:07:16 flush: 3 file(s), exit=0
2026-08-28 23:08:09 rename: Develop/Akros/CCAI/CCAI/protokolle/20260619-104500 - CC AI Workshops.m4a -> Develop/Akros/CCAI/CCAI/protokolle/2026-06-19-10-45-00 - CC AI Workshops.m4a
… (10 rename-Zeilen bis 23:09:51, alle server-seitig)
```

### 23:13 bis 23:30, Aufräumsession verschiebt Ordner

Aktionen der Session (Reihenfolge): `git pull` in `Marvin-Admin/maven-maintenance` (53 Commits, viele neue Dateien in `admin_notes/`, `english/`, `plist/`, `start-scripts/`); Rename `Hackathon-Multiverse-2026` zu `hackathon-multiverse-2026` (nur Gross-/Kleinschreibung); Move `BäRN Requirements Night` nach `%TEMP%\git-backup\…`; Rename `CCAI` zu `CCAI-old`, neuer Ordner `ccai`, Move `CCAI-old\CCAI\protokolle` nach `ccai\protokolle`; Move `Marvin-Admin\maven-maintenance` nach `maven-maintenance`.

Beobachtet in der Session: `Rename-Item CCAI` und `mv Marvin-Admin/maven-maintenance` scheiterten mehrfach mit «Access denied» / «Permission denied». Bash `mv` fiel still auf Kopieren zurück und verschob nur die Dateien, nicht die Unterordner (`admin_notes`, `english`, `plist`, `start-scripts` blieben unter `Marvin-Admin/maven-maintenance`; `.git` wurde in Meta-Dateien oben und `objects/refs` unten zerrissen). Dasselbe Muster (zerrissenes `.git`, Dateien eine Ebene höher als die Ordner) zeigte der Altbestand `BäRN Requirements Night/2026` bereits vor der Session, also ein wiederkehrender Effekt.

Der Upload-Watcher hat von diesen Verzeichnis-Operationen nichts propagiert. Einzige Zeilen mit Pfad in dieser Phase:

```
watcher.log
2026-08-28 23:18:54 rename fallback to upload: Develop/Akros/hackathon-multiverse-2026
2026-08-28 23:41:31 rename fallback to upload: Develop/Akros/sommerevent-2025/.gitmodules
```

Alle übrigen Einträge 23:11 bis 23:59 sind `events: N drained, 0 up / 0 ren / 0 del pending`, das heisst die Verzeichnis-Events wurden entgegengenommen, aber weder als Rename noch als Delete umgesetzt.

Gleichzeitig hat der Cloud-Watcher in dichter Folge **heruntergeladen** (Flushes von 30 bis 104 Dateien pro Minute):

```
cloud-watcher.log
2026-08-28 23:19:19 flush: 4 file(s), exit=0
2026-08-28 23:20:28 flush: 30 file(s), exit=0
2026-08-28 23:21:35 flush: 32 file(s), exit=0
2026-08-28 23:22:45 flush: 32 file(s), exit=0
2026-08-28 23:24:05 flush: 57 file(s), exit=0
2026-08-28 23:25:25 flush: 100 file(s), exit=0
2026-08-28 23:26:53 flush: 97 file(s), exit=0
2026-08-28 23:28:22 flush: 104 file(s), exit=0
2026-08-28 23:30:08 flush: 93 file(s), exit=0
2026/08/28 23:24:02 INFO  : Develop/Akros/Marvin-Admin/maven-maintenance/start-scripts/create-mapping.sh: Copied (new)
2026/08/28 23:24:03 INFO  : Develop/Akros/Marvin-Admin/maven-maintenance/plist/com.nexa.serve.plist: Copied (new)
2026/08/28 23:24:04 INFO  : Develop/Akros/Marvin-Admin/maven-maintenance/admin_notes/glm-4.6-multi-user-analysis.md: Copied (new)
… (insgesamt 20 Dateien aus admin_notes/, english/, plist/, start-scripts/)
2026/08/28 23:30:08 INFO  : Develop/Akros/CCAI/CCAI/protokolle/2026-08-28-14-00-16 - CC AI Kerteam.mp4: Multi-thread Copied (new)
```

Das sind exakt die Dateien, die der Upload-Watcher 10 bis 25 Minuten vorher selbst hochgeladen hatte (git-pull-Ergebnis um ca. 23:13, mp4 ab 23:07). Sie kamen an den **alten** Pfad zurück, während diese Ordner verschoben wurden. Das erklärt sowohl die Locks («Access denied»: rclone schreibt gerade in den Ordner) als auch die halb verschobenen Ordner (die Unterordner, in die der Cloud-Watcher gerade schrieb, liessen sich nicht umbenennen). Weil `ccai` zu diesem Zeitpunkt schon existierte und NTFS case-insensitiv ist, landete `CCAI/CCAI/protokolle/…mp4` lokal unter `ccai/CCAI/protokolle/`.

Hypothese zur Ursache (nicht verifiziert): Die Echo-Kontrolle des Cloud-Watchers (`upload-ledger.txt`, «eigene Uploads <15 min überspringen») greift hier nicht, entweder weil die Changes-Events erst nach Ablauf des 15-min-Fensters eintrafen (grosse Uploads, Pacer) oder weil per `moveto` umbenannte Dateien und Uploads aus dem Start-Catch-up nicht im Ledger stehen. Der `Marvin-Admin/maven-maintenance/.gitignore`-Eintrag im bisync (`Path2 File changed: size (larger), time (newer)`) zeigt, dass die Cloud-Version aus dem Upload nach dem git pull stammt.

### 04:00 bis 05:00, Nacht-bisync vervollständigt die Wiedergänger

```
logs/bisync-20260829-040002.log
2026/08/29 04:21:37 - Path1  File was deleted  - Develop/Akros/CCAI/CCAI/protokolle/20260619-… (alte Namen, 10×)
2026/08/29 04:21:37 - Path1  File is new       - Develop/Akros/ccai/CCAI/protokolle/2026-08-28-14-00-16 - CC AI Kerteam.mp4
2026/08/29 04:21:37 - Path1  File is new       - Develop/Akros/ccai/protokolle/2026-06-19-… (13×, neuer Ort)
2026/08/29 04:21:37 - Path1  File is new       - Develop/Akros/Marvin-Admin/maven-maintenance/admin_notes/… (20×)
2026/08/29 04:21:45 - Path2  File was deleted  - Develop/Akros/CCAI/CCAI/protokolle/20260619-… (alte Namen, 10×)
2026/08/29 04:21:46 - Path2  File is new       - Develop/Akros/CCAI/CCAI/protokolle/2026-06-19-… und 2026-08-28-… (13×)
2026/08/29 04:21:46 - Path2  File is new       - Develop/Akros/Marvin-Admin/maven-maintenance/… (admin_notes, english, plist, start-scripts)
2026/08/29 04:22:07 … : Develop/Akros/CCAI/CCAI/protokolle/2026-06-19-15-58-32 - Besprechungsaufzeichnung.md: Copied (new)
2026/08/29 04:22:16 … : Develop/Akros/CCAI/CCAI/protokolle/2026-08-28-14-00-16 - CC AI Kerteam.mp4: Multi-thread Copied (new)
2026/08/29 04:23:01 … : Develop/Akros/Marvin-Admin/maven-maintenance/257168925-model-summary.md: Deleted
2026/08/29 05:00:52 INFO  : Bisync successful   (exit 0, 779 «File was deleted», 18 «Copied (new)»)
```

Lesart: Für bisync existierten die umbenannten Protokoll-Namen in keinem Vor-Listing. Cloud-seitig lagen sie unter `CCAI/CCAI/protokolle/` (dort hatte der Upload-Watcher sie per `moveto` umbenannt), lokal lagen sie unter `ccai/protokolle/`. Beides «neu», keine Seite «gelöscht», also wurden beide Richtungen kopiert. Ergebnis lokal: `ccai/protokolle/` (gewollt) plus `ccai/CCAI/protokolle/` (Wiedergänger, 13 Dateien, byte-identisch, 897 MB). Analog `Marvin-Admin/maven-maintenance/` mit den vier Unterordnern. Die nachfolgenden `DirSetModTime`-Zeilen des Cloud-Watchers um 05:21:37 erklären die beobachtete Ordner-mtime 05:21.

Offen: Warum bisync die lokal seit 23:5x fehlenden `Marvin-Admin/…`-Dateien um 04:21 als «Path1 File is new» listet. Entweder hat der Cloud-Watcher sie zwischen 23:30 und 04:00 nochmals lokal angelegt (im Log nicht gefunden) oder der Move nach `%TEMP%` hat wie die anderen `mv` nur teilweise gegriffen.

## Zustand jetzt (29.08., 10:30)

Lokal bereinigt: `ccai/CCAI` und `Marvin-Admin` nach `cmp`-Verifikation gegen die Zielkopien gelöscht. Cloud-seitig existieren die alten Pfade `Develop/Akros/CCAI/CCAI/protokolle/` (13 Dateien) und `Develop/Akros/Marvin-Admin/maven-maintenance/` vermutlich noch; der Upload-Watcher hat auch diese Verzeichnis-Löschung nicht propagiert (`0 del pending`). Erwartung: der bisync am 30.08. 04:00 sieht «Path1 File was deleted» und räumt die Cloud auf. Risiko: taucht vorher ein Changes-Event für diese Pfade auf, lädt der Cloud-Watcher sie ein drittes Mal herunter.

## Fragen an die drive-sync-Session

1. Propagiert der Upload-Watcher Verzeichnis-Renames und -Löschungen überhaupt (Log zeigt nur `drained`)? Falls nein: ist das bewusst («Dir-Changed-Events werden nicht enumeriert») und wäre ein Dir-Rename als `moveto` bzw. Dir-Delete als `purge` in den Papierkorb ergänzbar?
2. Warum greift die Echo-Kontrolle des Cloud-Watchers bei den Uploads von 23:07 und 23:13 nicht (Ledger-Fenster 15 min, `moveto`-Ergebnisse, Catch-up-Uploads)?
3. Sollte der Cloud-Watcher Downloads unterlassen, wenn der lokale Zielordner nicht mehr existiert (Indiz für eine laufende lokale Umstrukturierung), statt ihn neu anzulegen?
4. Case-Insensitivity: Lokal `ccai`, Cloud `CCAI`. Wie behandelt die Kette einen reinen Case-Rename eines Verzeichnisses (`Hackathon-Multiverse-2026` → `hackathon-multiverse-2026` wurde zu «rename fallback to upload», also 340 MB Re-Upload)?

## Lehre für Aufräumaktionen im Sync-Baum

Vor grösseren Verschiebungen im Sync-Baum beide Watcher pausieren (`watchdog-pause`-Marker mit `pid:`), Ordner mit `cp -a` plus Verifikation statt `mv` bewegen, danach einmal `sync-drive.ps1` laufen lassen und erst dann die Watcher wieder starten. Ein Audit-Skript für den Repo-Bestand liegt neu in `ai-toolbox/tools/workspace-audit`.
