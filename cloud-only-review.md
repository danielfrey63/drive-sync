# Cloud-only Inhalte — Review vor der Baseline

Stand: 2026-08-04. Diese Verzeichnisse existieren NUR in der Cloud (lokal seit 27.07. gelöscht, verschoben oder umbenannt). Beim Resync würden sie wieder heruntergeladen. Befund automatisch ermittelt: Dateinamen der Cloud-Kopie im lokalen Bestand gesucht — RENAME/MOVE = Inhalt existiert lokal unter anderem Pfad (Prozentzahl = Anteil wiedergefundener Dateinamen), DELETE = lokal nirgends gefunden.

Spalte «Entscheid» pro Zeile ausfüllen: `purgen` oder `runterladen`. Leer = Empfehlung gilt; bei Zeilen ohne Empfehlung (`?`) ist dein Entscheid nötig: Wenn du die lokale Löschung diese Woche bewusst gemacht hast → `purgen`, sonst → `runterladen`.

## Rename/Move — Inhalt lokal vorhanden, Empfehlung: purgen

| Dateien | MB | Cloud-Verzeichnis | Lokal gefunden unter | Entscheid |
| --- | --- | --- | --- | --- |
| 114 | 2818 | Bilder/20200622 Fotoshooting KEGON All | Kegon\Bilder\Photo Shooting 2020 | |
| 182 | 341 | Champagner/Services/Verkauf | Champagner\Services\Verkauf\… (lokal restrukturiert) | |
| 37 | 293 | Audio/To Sort/iTunes Music | Audio\To Sort\iTunes Music (1)\… — NB: lokalen Ordner ggf. vor der Baseline zu «iTunes Music» zurückbenennen | |
| 1872 | 272 | Akros/Kunden/SBB/Develop/ai-at-dz-repository | nirgends — aber: alter Klon von codessh.sbb.ch/ai-tools-exploration/cc-plugins.git (Remote existiert, cc-plugins per Daniel-Entscheid veraltet) | |
| 9 | 250 | Develop (Einzeldateien im Root) | Develop\Alt\Develop-Root-Altbestand | |
| 2 | 35 | Agile Lean Teal/KEGON Agil/Agiles Handwerkszeug | Agile Lean Teal\KEGON Agil\Agiles Handwerkszeug\… (restrukturiert) | |
| 17 | 2 | Flashcards Deluxe/Fotoliste CAS SAPM FS19/Teilnehmende SAPM FS 2019 Media | BFH\CAS SAPM\2019_FS_CAS_SAPM\Fotoliste CAS SAPM FS19\… | |
| 18 | 1 | Flashcards Deluxe/Fotoliste BEKB-DXC/Leute BEKB\|DXC Media | Flashcards Deluxe\Fotoliste BEKB-DXC\Leute BEKB DXC Media (Pipe-Zeichen lokal entfernt) | |
| 2 | 0 | Akros/Spesen/protokoll | Akros\Spesen\tampermonkey | |

## Vermutlich Move — Mehrheit der Dateien lokal gefunden, Empfehlung: purgen (bei Zweifel «anschauen» eintragen)

| Dateien | MB | Cloud-Verzeichnis | Lokal gefunden unter (Trefferquote) | Entscheid |
| --- | --- | --- | --- | --- |
| 271 | 67 | Kegon/Kunden/SBB | Kegon\KEGON-SharePoint-lokal\50-Kunden\S\SBB\… (48%) | |
| 13 | 62 | Agile Lean Teal/PSM/2021-07-08 PSM Allianz CH | Kegon\Kunden\Allianz Suisse\2021-07-08 PSM Allianz CH (Kopie)\… (69%) | |
| 16 | 46 | Agile Lean Teal/PSM/2021-07-15 PSM Allianz CH | Kegon\Kunden\Allianz Suisse\… (56%) | |
| 73 | 112 | Agile Lean Teal/OKR/OKR Consortium | Kegon\OneDrive\12 - Akademie\15 OKR Consortium\… (42%) | |
| 14 | 192 | Agile Lean Teal/Teal/Intro Presentations [shared w／ providers] | Agile Lean Teal\Teal\Intro Presentations\Archive (50%) | |
| 13 | 1 | Akros/Spesen | Akros\Spesen\Alt (69%) | |
| 5 | 2 | Privat/Steuern/2025 | Archiv\2026 (40%) | |
| 3 | 10 | Agile Lean Teal/Social Selling/Modul 1 | Agile Lean Teal\Social Selling\Modul 1\… (33%) | |

## Delete — lokal nirgends gefunden, dein Entscheid (bewusst gelöscht → purgen, sonst → runterladen)

| Dateien | MB | Cloud-Verzeichnis | Entscheid |
| --- | --- | --- | --- |
| 56 | 40 | ALE/ALE 2018 Zürich Organisation/Branding | |
| 88 | 18 | ALE/ALE 2018 Zürich Organisation/Administration | |
| 12 | 57 | ALE/ALE 2018 Zürich Organisation/ALE18 Feedback Wall | |
| 1 | 24 | ALE/ALE 2018 Zürich Organisation/Sponsoring | |
| 9 | 19 | ALE/ALE 2018 Zürich Organisation/booklet-flyer | |
| 18 | 9 | ALE/ALE 2018 Zürich Organisation/Community & Communication | |
| 3 | 3 | ALE/ALE 2018 Zürich Organisation/Verein Agile Lean Europe | |
| 3 | 3 | ALE/ALE 2018 Zürich Organisation/Gustav | |
| 5 | 2 | ALE/ALE 2018 Zürich Organisation/OpenSpace | |
| 5 | 1 | ALE/ALE 2018 Zürich Organisation/Venue and Catering | |
| 2 | 0 | ALE/ALE 2018 Zürich Organisation/Website-WordPress | |
| 1 | 0 | ALE/ALE 2024 Budapest | |
| 34 | 24 | Archiv/2026 | |
| 3 | 17 | Privat/Gesundheit/Athreya Ayurvedic Center | |
| 5 | 13 | Aus Chrome gespeichert | |
| 5 | 12 | Agile Lean Teal/BetaCodex | |
| 1 | 0 | Agile Lean Teal/Social Selling | |
| 3 | 11 | Books/Cleaned | |
| 1 | 0 | Books/To Clean | |
| 2 | 5 | Privat/Covid | |
| 5 | 0 | Privat/Hochzeit/Grosse Party | |
| 5 | 2 | Privat/Steuern/2025 → siehe oben (Move) | |
| 1 | 1 | simple_ml_for_sheets | |
| 1 | 0 | Archiv/Backup 2004/Download | |
