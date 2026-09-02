# Postmortem: `task.py sync` verwarf einen lokalen Commit per Rebase

**Datum des Vorfalls:** 01.09.2026, ~23:00 (Europe/Zurich) · **Verfasst:** 02.09.2026 · **Status:** Wiederhergestellt; strukturelle Ursache offen · **Verwandt:** [[POSTMORTEM-drive-sync]], CLAUDE.md-Regel «Push abgelehnt heisst: Reflog vor Force» (31.08.2026)

## Zusammenfassung

Ein `task.py sync` hat den Commit `ae9a7ec` (das neue SAP-Stunden-Skript, sechs Dateien, 272 Zeilen) aus `main` entfernt. Der Commit war vorher nach GitHub gepusht, aber nicht nach Forgejo. Beim nächsten `sync` lief der Push-Wiederherstellungspfad `_push_with_recovery` in `tools/task.py`: Der Push wurde von Forgejo abgelehnt, das darauf folgende `git pull --rebase` setzte `main` auf Forgejos Stand `2e11c99` und liess den lokalen Commit fallen. Weil GitHub und Forgejo über zwei Push-URLs desselben `origin` laufen, hielt GitHub `ae9a7ec` weiter — dadurch war die Wiederherstellung ohne Datenverlust möglich (`git merge ae9a7ec` → Merge-Commit `077dd9e`, dann normaler Push auf beide).

## Auswirkung

Kein Datenverlust: Der Commit lag durchgehend auf GitHub und im lokalen Reflog. Die Remotes waren für einige Minuten divergent (Forgejo `2e11c99`, GitHub `ae9a7ec`). Die Korrektur kostete wenige Minuten Untersuchung und einen Merge. Der Vorfall ist trotzdem ernst, weil er sich ohne die zufällige Rettung durch das zweite Remote als stiller Verlust dargestellt hätte und weil dasselbe Muster laut CLAUDE.md schon am 31.08.2026 zwei Commits getroffen hat.

## Zeitleiste (01.09.2026, Ortszeit)

| Zeit | Ereignis |
|---|---|
| 23:00:02 | Devbox-Session zieht per `pull --no-rebase` den Container-Commit `04bab4a` (Task 0204) fast-forward herein. |
| 23:00:25 | Devbox committet `ae9a7ec` auf Basis `04bab4a` (SAP-Skript, Kanal `sbb-sap`, Doku). |
| ~23:00:2x | Push: GitHub nimmt `ae9a7ec` an (Fast-forward von `04bab4a`). Forgejo lehnt ab — dort hatte der Container zeitgleich `982bbd9→47f5b3d→2e11c99` (ebenfalls auf `04bab4a`) gepusht. Die Ablehnung scrollte im `tail -4` der Push-Ausgabe weg. |
| ~23:00:5x | Nächster `task.py sync`: `_push_with_recovery` pusht, Forgejo lehnt ab, `pull --rebase` holt Forgejos `2e11c99` und setzt `main` dorthin. `ae9a7ec` ist aus dem Branch verschwunden (Reflog: «pull --rebase (finish): returning to refs/heads/main» bei `2e11c99`). |
| 23:01:20 | Erkannt an der Remote-Prüfung (Forgejo `2e11c99a`, GitHub `ae9a7ec3`). Wiederherstellung per `git merge ae9a7ec` → `077dd9e`, Push auf beide, beide Remotes gleich. |

Der Zwei-Stunden-Versatz in den Rohdaten (Container-Commits datieren auf 21:00 UTC) ist die bekannte Container-UTC-Eigenheit aus der CLAUDE.md und erschwerte anfangs das Lesen der Reihenfolge.

## Ursache

Drei Schreiber committen gleichzeitig auf denselben `main`: die Devbox-Session, der `pmo-web`-Container und eine parallele Session. Alle drei setzten hier auf derselben Basis `04bab4a` auf. Die Devbox-Commit `ae9a7ec` und die Container-Kette `2e11c99` sind damit Geschwister, kein Fast-forward voneinander.

Der eigentliche Verlust kam aus `_push_with_recovery`: Bei abgelehntem Push führt die Funktion `git -c rebase.autoStash=true pull --rebase` aus und pusht erneut. Diese Strategie ist für den Normalfall gedacht — lokale Auto-Commits auf den Remote-Stand nachziehen. Sie ist aber blind gegenüber der Frage, ob der lokale Commit den Rebase überlebt. Im Reflog endete der Rebase exakt auf Forgejos `2e11c99`, ohne `ae9a7ec` zu replayen; der Commit fiel aus dem Branch. Ob der Rebase ihn hätte replayen müssen, ist zweitrangig: Der Wiederherstellungspfad prüft nach dem `pull --rebase` nicht, dass die vorherige lokale Spitze noch erreichbar ist, und meldet den Verlust darum nicht.

Dass nichts verloren ging, war Glück der Architektur, nicht des Codes: GitHub und Forgejo hängen als zwei Push-URLs an einem `origin`. Der abgelehnte Forgejo-Push liess `ae9a7ec` allein auf GitHub liegen, wo der Rebase ihn nicht erreichte.

## Belege

- `ae9a7ec` Parent `04bab4a`; `2e11c99` Parent `47f5b3d`, Kette zurück auf `04bab4a`. `git merge-base --is-ancestor ae9a7ec 2e11c99` → NO. Die beiden sind Geschwister.
- Reflog: `ae9a7ec commit` → `pull --rebase (start): checkout 2e11c99` → `pull --rebase (finish): returning to refs/heads/main` bei `2e11c99`. Der Rebase replayte null Commits.
- Remote-Prüfung im Moment des Fehlers: Forgejo `2e11c99a`, GitHub `ae9a7ec3` — belegt, dass der Push nur GitHub erreichte und die Remotes divergierten.
- `origin` Fetch-URL = Forgejo; Push-URLs = Forgejo + GitHub. Der Rebase orientiert sich an Forgejo, wohin der Commit nie kam.
- Wiederherstellung: `077dd9e` «Merge commit 'ae9a7ec'», danach beide Remotes auf `077dd9e`.
- Der Code: `tools/task.py` `_push_with_recovery` (Push → `pull --rebase` → Push → bei Fehler `rebase --abort`), keine Prüfung der alten Spitze; `autopull()` ist `pull --ff-only` und damit unschuldig.

## Sofortmassnahmen (erledigt)

1. Verlust an der Remote-Divergenz erkannt, nicht am Zufall.
2. `git merge ae9a7ec` statt Force-Push — die Seite mit dem Commit (GitHub) blieb unangetastet, exakt nach der CLAUDE.md-Regel «Reflog vor Force».
3. Beide Remotes wieder gleichgezogen und verifiziert.

## Offen

**1. `_push_with_recovery` muss den lokalen Stand vor dem Rebase sichern und danach prüfen.** Konkret: vor `pull --rebase` `HEAD` merken; danach `git merge-base --is-ancestor <alt> HEAD` prüfen. Ist die alte Spitze nicht mehr erreichbar, automatisch `git merge <alt>` (kein Rebase, kein Force) und den Vorgang melden. Das ist genau das Rezept, das die CLAUDE.md heute dem Menschen aufträgt — es gehört ins Skript, weil der Container und die Auto-Commits ohne Menschen laufen.

**2. `pull --rebase` bei divergenten Geschwister-Commits durch Merge ersetzen.** Der Wiederherstellungspfad sollte gar nicht rebasen, wenn lokale Commits nicht im Remote sind. Ein Merge bewahrt beide Seiten und macht die Zusammenführung im Graphen sichtbar; der Rebase riskiert bei jedem Lauf denselben stillen Verlust.

**3. Die Grundursache ist der geteilte `main`-Checkout mit drei Schreibern.** Die Worktree-Regel (ein Worktree pro Session) adressiert die Arbeitskopie, nicht die konkurrierenden Commits von Devbox und Container auf denselben Branch. Solange beide gleichzeitig auf `main` committen und pushen, bleibt das Push-Rennen bestehen; robuster Wiederherstellungscode (Punkt 1/2) ist die realistische Absicherung.

## Was gut lief

Die Zwei-Remote-Architektur hat den Commit gerettet, obwohl der Code ihn fallen liess. Die Remote-Prüfung nach jedem Push (`git ls-remote` auf beide) hat die Divergenz sofort sichtbar gemacht. Und die CLAUDE.md-Regel «Reflog vor Force» hat den reflexhaften Force-Push verhindert, der die einzige verbliebene Kopie auf GitHub überschrieben hätte.
