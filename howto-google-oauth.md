
 Lass uns die Google Client-ID erstellen und leite mich an, wie das geht

Gern. Es sind vier kurze Etappen in der Google Cloud Console — mit dem Google-Konto einloggen, das zur «Meine Ablage» gehört:

1. Projekt anlegen
   Öffne https://console.cloud.google.com/projectcreate — Projektname z.B. rclone-sync, Organisation leer lassen, «Erstellen». Kein Billing nötig.
2. Drive API aktivieren
   Öffne https://console.cloud.google.com/apis/library/drive.googleapis.com — oben sicherstellen, dass das neue Projekt rclone-sync ausgewählt ist → «Aktivieren».
3. OAuth-Zustimmungsbildschirm einrichten
   Öffne https://console.cloud.google.com/auth/overview — «Jetzt starten»:
4. App-Name: rclone, Support-E-Mail: deine.
5. Zielgruppe (Audience): Extern.
6. Kontaktdaten: deine E-Mail. → Fertigstellen/Erstellen.
7. Wichtig: Danach unter «Zielgruppe» (Audience) den Status von Testing auf «In Produktion» publizieren. Sonst läuft der Refresh-Token alle 7 Tage ab und der Sync bricht wöchentlich mit Re-Login ab. Die Warnung «App nicht verifiziert» ist für den Eigengebrauch egal.
8. Client-ID erstellen
   Öffne https://console.cloud.google.com/apis/credentials — «Anmeldedaten erstellen» → «OAuth-Client-ID» → Anwendungstyp «Desktop-App», Name z.B. rclone-desktop → «Erstellen». Google zeigt dir dann Client-ID (endet auf .apps.googleusercontent.com) und Client-Secret.
