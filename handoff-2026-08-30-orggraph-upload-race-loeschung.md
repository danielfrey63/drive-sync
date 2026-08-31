# Hand-off: Datei-Löschung durch Upload-Race in `Develop/danielfrey63/orggraph` (29./30.08.2026)

Zusammengestellt aus der Component-Audit-Session (Claude Code, Projekt `D:\Meine Ablage\Develop\danielfrey63\orggraph`). Zweck: der drive-sync-Session den Fall liefern, in dem die Sync-Kette eine aktiv bearbeitete Datei (`COMPONENT_INVENTORY.md`) beidseitig gelöscht hat, ohne dass irgendjemand sie gelöscht hätte. Spiegel-Fall zu `handoff-2026-08-29-akros-wiedergaenger.md`: dort erweckte die Kette Gelöschtes wieder zum Leben, hier löschte sie Existierendes. Alle Zeiten Lokalzeit (CEST). Logs: `%LOCALAPPDATA%\drive-sync\watcher.log`, `cloud-watcher.log`, `logs\bisync-20260830-*.log`, `upload-ledger.txt`.

## Kurzfassung

Eine Session schrieb `COMPONENT_INVENTORY.md` mehrfach kurz nacheinander. Der Upload lief los, während die Datei lokal erneut geschrieben wurde, und scheiterte mit «corrupted on transfer» (md5 mismatch). rclone räumte daraufhin selbst die defekte Cloud-Kopie weg («Removing failed copy») — das erzeugte in Google Drive ein **Trash-Event, das in keinem Ledger steht**. Der Retry lud die Datei 7 Sekunden später korrekt hoch. Der **Cloud-Watcher** wendete das inzwischen veraltete Trash-Event trotzdem lokal an (Datei in den Papierkorb), der **Upload-Watcher** echote diese lokale Löschung zurück in die Drive-Trash, der **Nacht-bisync** besiegelte den beidseitigen Löschzustand. Wiederhergestellt per `git restore` am 30.08. (Datei war committet, Hash-identisch — kein Datenverlust, aber nur dank git).

## Ablauf mit Belegen

### 29.08., 17:06 bis 17:08 — Session schreibt die Datei mehrfach, Upload-Race

Die Audit-Session schrieb das Inventar in mehreren Edits kurz nacheinander (atomare Replace-Writes, für den Watcher Renames). Das server-seitige `moveto` scheiterte zweimal, der Fallback-Upload traf eine Datei mitten im nächsten Write:

```
watcher.log
2026/08/29 17:07:45 CRITICAL: Source doesn't exist or is a directory and destination is a file
2026-08-29 17:07:45 rename fallback to upload: Develop/danielfrey63/orggraph/COMPONENT_INVENTORY.md
2026/08/29 17:07:53 CRITICAL: Source doesn't exist or is a directory and destination is a file
2026-08-29 17:07:53 rename fallback to upload: Develop/danielfrey63/orggraph/COMPONENT_INVENTORY.md
2026/08/29 17:07:57 ERROR : …COMPONENT_INVENTORY.md: corrupted on transfer: md5 hashes differ src(…) "1b16159a…" vs dst(…) "9776da17…"
2026/08/29 17:07:57 INFO  : …COMPONENT_INVENTORY.md: Removing failed copy
2026/08/29 17:08:01 ERROR : Attempt 1/3 failed with 1 errors and: corrupted on transfer: …
2026/08/29 17:08:04 INFO  : …COMPONENT_INVENTORY.md: Copied (new)
2026/08/29 17:08:08 ERROR : Attempt 2/3 succeeded
2026-08-29 17:08:08 flush: 2 file(s), exit=0
```

Aus Sicht des Watchers endete alles gut: Retry erfolgreich, exit=0, Datei liegt korrekt in der Cloud. Aber das `Removing failed copy` von 17:07:57 hatte in Drive bereits ein Trash-Event hinterlassen.

### 29.08., 17:08:25 — Cloud-Watcher wendet das veraltete Trash-Event an

```
cloud-watcher.log
2026-08-29 17:08:25 skipped 2 own-upload echo(es)
2026-08-29 17:08:25 cloud trash -> recycle bin: Develop\danielfrey63\orggraph\COMPONENT_INVENTORY.md
```

Die Echo-Kontrolle griff für zwei andere Events (Uploads stehen im Ledger), nicht aber für dieses: `Removing failed copy` ist eine rclone-interne Aufräumaktion, die nirgends als eigene Aktion registriert wird. Der Cloud-Watcher prüfte auch nicht, dass die Datei in der Cloud seit 17:08:04 wieder existiert (das Trash-Event war zum Anwendungszeitpunkt 21 Sekunden alt und überholt) — er löschte die lokale, aktuelle Datei in den Papierkorb.

### 29.08., 17:09:04 — Upload-Watcher echot die Löschung zurück

```
watcher.log
2026-08-29 17:09:04 delete -> Drive trash: Develop/danielfrey63/orggraph/COMPONENT_INVENTORY.md
```

Der Upload-Watcher sah die lokale Löschung (die der Cloud-Watcher verursacht hatte) und spiegelte sie designgemäss in die Drive-Trash. Ab jetzt war die Datei auf beiden Seiten weg — der klassische Echo-Loop, nur diesmal in Richtung Löschung.

### 30.08., 04:17 — Nacht-bisync besiegelt den Zustand

```
logs/bisync-20260830-…
2026/08/30 04:17:55 INFO  : - Path1  File was deleted - Develop/danielfrey63/orggraph/COMPONENT_INVENTORY.md
2026/08/30 04:18:02 INFO  : - Path2  File was deleted - Develop/danielfrey63/orggraph/COMPONENT_INVENTORY.md
```

### 30.08., 21:13 — Entdeckung und Wiederherstellung

Die nächste Audit-Runde bemerkte die fehlende Datei. Recycle-Bin-Forensik ($I-Datei) bestätigte Originalpfad und Löschzeitpunkt 29.08. 17:08:25. `git restore` stellte die committete Version her (Hash-identisch mit dem letzten Stand), der Watcher lud sie um 21:13:43 wieder hoch (Ledger-Eintrag 1788117223).

## Zustand jetzt (30.08., 21:30)

Datei lokal und in der Cloud wiederhergestellt und identisch mit dem git-Stand. Kein Datenverlust. Der Fall ist reproduzierbar bei jeder Datei, die während eines laufenden Upload-Flushs erneut geschrieben wird — Refactoring-Sessions mit mehreren schnellen Writes in dieselbe Datei sind der typische Auslöser. Uncommittete Dateien hätten denselben Weg genommen, ohne git-Netz.

## Verbesserungsvorschläge an die drive-sync-Session

1. **Destruktive Selbst-Aktionen ins Ledger.** rclones `Removing failed copy` (und `moveto`-Quellseiten) erzeugen Cloud-Trash-Events, die die Echo-Kontrolle nicht kennt. Das flush-Log liesse sich nach diesen Zeilen parsen und die Pfade mit Zeitstempel ins Ledger (oder ein eigenes «self-trash»-Ledger) schreiben, damit der Cloud-Watcher sie als eigene Aktionen verwirft.
2. **Trash-Events gegen den aktuellen Cloud-Zustand prüfen.** Bevor der Cloud-Watcher ein Trash-Event lokal anwendet: `rclone lsjson` auf den Pfad. Existiert die Datei in der Cloud wieder (jüngerer mtime als das Event), ist das Event überholt und wird verworfen. Das hätte diesen Fall allein verhindert — um 17:08:25 lag die Datei seit 21 Sekunden wieder korrekt in der Cloud.
3. **Heisse Dateien nicht mitten im Write hochladen.** Settle-Delay pro Datei (Upload erst, wenn n Sekunden kein weiteres Event kam) oder `--local-no-check-updated` als bewusste Entscheidung; mehrere Events auf dieselbe Datei innerhalb eines Flush-Fensters koaleszieren. Das «corrupted on transfer» war der Startpunkt der ganzen Kette.

## Lehre

Die Kette hat keinen einzelnen Bug, sondern drei fehlende Sicherungen, die erst zusammen zur Löschung führen: unregistrierte Selbst-Aktion → ungeprüfte Anwendung eines veralteten Events → designgemässes Lösch-Echo. Jede der drei Massnahmen oben unterbricht die Kette einzeln. Bis dahin gilt für Arbeits-Sessions: Dateien im Sync-Baum, an denen schnell iteriert wird, früh und oft committen — git war hier die einzige funktionierende Rückfallebene.
