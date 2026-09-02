# Hand-off: Konfliktwelle im Git-Arbeitsbaum `Develop/danielfrey63/pmo` (02.09.2026)

Zusammengestellt aus der PMO-UI-Session (Claude Code, Projekt `D:\Meine Ablage\Develop\danielfrey63\pmo`). Zweck: der drive-sync-Session den Fall liefern, in dem die nächtliche bisync 68 Verliererkopien in einen aktiv bearbeiteten Git-Arbeitsbaum gelegt hat, wo sie in den Index gerieten und jeden Merge blockierten. Dritter Fall der Reihe nach `handoff-2026-08-29-akros-wiedergaenger.md` (Kette erweckt Gelöschtes) und `handoff-2026-08-30-orggraph-upload-race-loeschung.md` (Kette löscht Existierendes); hier legt die Kette Dateien an, die niemand geschrieben hat. Alle Zeiten Lokalzeit (CEST). Logs: `logs\bisync-20260902-040002.log`, `%LOCALAPPDATA%\drive-sync\watcher.log`, `cloud-watcher.log`.

## Kurzfassung

Die bisync vom 02.09. um 04:25 fand im Repo `pmo` 68 beidseitig geänderte Dateien. `--conflict-resolve newer` behielt die lokale, neuere Fassung unter dem Originalnamen und benannte die Cloud-Kopie server-seitig in `<name>.conflict1` um — und lud sie anschliessend nach Path1 herunter. Damit lagen 68 Dateien im Arbeitsbaum, die dort nie jemand angelegt hatte. Das ist an sich das dokumentierte Verhalten und kein Bug. Der Schaden entstand daraus, **wo** die Kopien landeten: `task.py sync` und die Auto-Commits des PMO stagen alles, was unter `tasks/` dirty ist, also wanderten 54 davon in den Git-Index und blockierten am Vormittag jeden Merge mit «Your local changes to the following files would be overwritten by merge». Inhaltlich waren die Verlierer wertlos: 66 der 68 sind byte-identisch mit einer früheren Git-Version derselben Datei. Kein Datenverlust.

## Ablauf mit Belegen

### 01.09., tagsüber und abends — intensive Schreiblast im Repo

Im `pmo` lief eine lange Session: Kanal-Umbenennungen, die 26 Task-Dateien mehrfach umschrieben, dazu rund 40 Commits und die Auto-Commits des `pmo-web`-Containers. Jede Mutation schreibt die Datei neu, der Upload-Watcher lädt sie hoch. Am 02.09. zählt `watcher.log` 2304 Zeilen mit `danielfrey63/pmo` — das Repo ist mit Abstand der schreibintensivste Baum im Korpus.

### 02.09., 04:21 bis 04:27 — die bisync klassifiziert und benennt um

```
logs/bisync-20260902-040002.log
2026/09/02 04:21:39 INFO  : Checking potential conflicts...
2026/09/02 04:25:36 INFO  : Finished checking the potential conflicts. %!s(<nil>)
2026/09/02 04:25:36 NOTICE: - Path2  Renaming Path2 copy  - gdrive{RaLC1}:/Develop/danielfrey63/pmo/.events/pmo-events.jsonl.conflict1
2026/09/02 04:25:37 INFO  : Develop/danielfrey63/pmo/.events/pmo-events.jsonl: Moved (server-side) to: …jsonl.conflict1
2026/09/02 04:25:37 NOTICE: - Path2  Queue copy to Path1  - D:\Meine Ablage\Develop/danielfrey63/pmo/.events/pmo-events.jsonl.conflict1
```

68 solcher Umbenennungen betrafen `Develop/danielfrey63/pmo`, zwei weitere `Develop/sbb/intake` — sonst nichts im ganzen Korpus. Der Lauf selbst war sauber und meldete «Bisync successful»; die 238 MiB Transfervolumen dieser Nacht stammen aus neuen SBB-Quelldateien, nicht aus dem Vorfall.

### 02.09., vormittags — die Kopien blockieren die Arbeit am Repo

54 der 68 liegen unter `tasks/`. Ein `task.py`-Lauf hatte sie mit `git add` eingesammelt, der Commit kam nicht mehr zustande (er hinterliess um 10:49:45 zusätzlich ein verwaistes `.git/index.lock`, unabhängige Ursache). Ab da scheiterte jeder Merge nach `main`, weil git die gestagten Dateien beim Checkout überschreiben müsste. Aufgelöst um 11:06 durch `git restore --staged tasks/` — die Dateien blieben unangetastet auf der Platte.

### Vorgeschichte: 26.08. — derselbe Mechanismus, damals mit Commit

Die Nacht auf den 26.08. hatte 94 Konfliktzeilen; das ist der Lauf, der zur Umstellung auf `--conflict-resolve newer` führte (Kommentar in `sync-drive.ps1`: «missed nightly plus an unflushed watcher backlog diverged 8 files»). Im `pmo` sind damals zwei Verliererkopien tatsächlich **committet** worden: `fd75555` vom 26.08. 08:57 fügte `tasks/0130-…md.conflict1` und `.conflict2` hinzu, ein späterer Auto-Commit entfernte sie um 09:37 wieder (`a81df6b`). Sie stehen bis heute in der History. Die Umstellung auf `newer` hat also das Symptom «beide Kopien verlieren ihren Namen» geheilt, nicht das Grundproblem «Verliererkopie landet in einem Arbeitsbaum, den Werkzeuge automatisch einsammeln».

## Warum ausgerechnet dieses Repo

Der Watcher lädt laufend hoch, die bisync gleicht einmal pro Nacht ab. Eine Datei, die der Watcher seit dem letzten nächtlichen Lauf hochgeladen hat **und** die lokal danach nochmals geschrieben wurde, ist für die bisync eine beidseitige Änderung — obwohl beide Änderungen von derselben Maschine stammen und dieselbe Linie fortschreiben. Bei normalen Dokumenten trifft das selten zu, bei einem Git-Arbeitsbaum mit einer CLI, die bei jeder Mutation schreibt und committet, ist es der Normalfall. Deshalb 68 Treffer in `pmo` und praktisch keine anderswo.

Die Filter greifen dabei korrekt: `.git/**` und `.claude/**` sind ausgeschlossen, die Repository-Metadaten waren nie in Gefahr. Betroffen war nur der Arbeitsbaum.

## Zustand jetzt (02.09., 11:30)

Alle 68 Kopien liegen unangetastet im Arbeitsbaum, aus dem Git-Index genommen. Inhaltsprüfung aller 68: 66 sind byte-identisch mit einer früheren Git-Version derselben Datei (Beispiel `tasks/0003`: identisch mit Commit `9957e63` vom 01.09. 16:00, während die getrackte Fassung vier weitere Journal-Zeilen trägt), die beiden übrigen sind `tasks.md` (generiert) und `.events/pmo-events.jsonl` (per `.gitignore` nie getrackt). Auf PMO-Seite ist `*.conflict[0-9]*` in `.gitignore` aufgenommen und die Analyse als `POSTMORTEM-drive-sync.md` abgelegt. Gelöscht wurde nichts; die Kopien warten auf Daniels Freigabe.

## Verbesserungsvorschläge an die drive-sync-Session

1. **Verliererkopien nicht im Arbeitsbaum ablegen, sondern in Quarantäne.** Das ist die wirksamste Änderung. Eine `.conflictN`-Datei neben dem Original ist in einem Git-Baum kein Backup, sondern eine Falle: `git add`, `git status`, Build-Skripte und Linter sehen sie. Vorschlag: Verlierer nach `%LOCALAPPDATA%\drive-sync\conflicts\<relativer-pfad>` verschieben, mit Zeitstempel und einer Logzeile, die Original und Ablageort nennt. Der Nutzen für Daniel bleibt (die Kopie existiert und ist auffindbar), die Nebenwirkung verschwindet. Nachbearbeitung des bisync-Laufs genügt, das Log nennt jeden Pfad explizit.
2. **Verliererkopie unterdrücken, wenn ihr Inhalt schon in git steht.** Liegt der Pfad in einem Git-Arbeitsbaum, lässt sich der Verlierer vor dem Ablegen prüfen: `git hash-object` auf die Kopie, dann die Blob-Hashes dieses Pfades aus `git log` vergleichen. Trifft es zu, ist die Kopie überflüssig — git hält den Stand bereits. In diesem Fall hätte die Prüfung 66 der 68 Dateien gar nicht erst entstehen lassen. Billig, weil nur bei Konflikten und nur für Pfade unterhalb eines `.git` nötig.
3. **Die Uploads des Watchers für die bisync sichtbar machen.** Gleiche Wurzel wie Punkt 1 im orggraph-Hand-off: Watcher und bisync teilen keinen Zustand. Wenn eine Path2-Änderung, die nachweislich aus einem eigenen Upload stammt (`upload-ledger.txt`), bei der Konfliktklassifikation nicht als fremde Änderung zählt, verschwindet die ganze Klasse der falschen Konflikte statt nur ihrer Symptome. Das ist die grössere Änderung, aber die einzige, die auch verhindert, dass eine echte zweite Maschine irgendwann in dieselbe Falle läuft.
4. **Aktive Repos aus dem Sync nehmen.** `git-repos-in-ablage.md` plant den Umzug nach `D:\Develop` bereits, die Zielspalten sind grösstenteils noch leer. `pmo` wäre ein guter erster Umzug: es hat zwei Remotes (Forgejo und GitHub), braucht Drive also nicht zur Replikation, und es ist der schreibintensivste Baum im Korpus. Wenn ein Repo ohnehin bleibt, wäre wenigstens ein `- **/.conflict*`-Filter sinnvoll, damit Kopien nicht wieder in die Cloud hochwandern.

## Lehre

Die drei Hand-offs zeigen dasselbe Muster aus drei Richtungen: Die Kette tut jeweils genau das, was konfiguriert ist, und der Schaden entsteht an der Schnittstelle zu einem Werkzeug, das mitliest. Beim orggraph war es git als einzige Rückfallebene, hier ist git das Werkzeug, das die Kopien einsammelt und daran erstickt. Verallgemeinert: Sobald die Sync-Kette Dateien **anlegt** statt nur zu übertragen, muss sie wissen, in welche Art von Verzeichnis sie schreibt. Ein Arbeitsbaum mit Versionskontrolle verträgt keine Fremddateien neben den Originalen — und braucht sie auch nicht, weil er die Historie schon hat.
