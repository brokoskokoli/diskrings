# Releases erstellen

DiskRings wird mit der Developer ID signiert, von Apple notarisiert und als ZIP
und DMG über GitHub Releases verteilt. Das geht auf zwei Wegen, die dieselben
Skripte nutzen:

| Weg | Auslöser | Signatur | Notarisierung |
|---|---|---|---|
| **GitHub Actions** (`.github/workflows/release.yml`) | Push eines Tags `v*`, oder Trockenlauf von Hand | Zertifikat aus Secrets in einer temporären Keychain | App Store Connect API Key |
| **Lokal** (`scripts/release.sh`) | von Hand | Zertifikat im Anmelde-Schlüsselbund | Schlüsselbund-Profil (`notarytool store-credentials`) oder API Key |

Beteiligte Skripte:

- `scripts/make-app.sh`: baut `build/DiskRings.app` (universal) und signiert sie. `DISKRINGS_IDENTITY` wählt die Identität, `DISKRINGS_KEYCHAIN` beschränkt die Suche auf eine Keychain (dann ohne Rückfall auf ad hoc).
- `scripts/notarize.sh`: `check` prüft die Zugangsdaten, `submit <datei>` reicht ein und wartet. Nutzt den API Key, wenn `NOTARY_API_KEY_ID` gesetzt ist, sonst das Profil `diskrings`.
- `scripts/release.sh`: Tests, `make-app.sh`, Notarisierung von App und DMG, `stapler`, `spctl`, `SHA256SUMS`.
- `scripts/ci-release.sh`: Schritte nur für den Workflow (Vorprüfung, temporäre Keychain).
- `scripts/setup-release-secrets.sh`: richtet die Secrets einmalig ein.

## Einmalige Einrichtung (GitHub Actions)

**Wohin die Secrets gehören:** in das **Environment `release`**, nicht in die allgemeinen Repository-Secrets. Environment-Secrets bekommt nur ein Job, der dieses Environment nutzt (der Build-Job des Release-Workflows), und erst nach deiner Freigabe. Repository-Secrets würden auch funktionieren, umgehen aber die Freigabe.

### Schon erledigt (Stand 10.10.2026)

Auf GitHub ist bereits eingerichtet:

| Was | Wo | Wirkung |
|---|---|---|
| Environment `release` | Settings → Environments → `release` | Pflicht-Freigabe durch dich (Required reviewers: brokoskokoli, „Prevent self-review“ aus); nutzbar nur von Tags `v*` und Branch `main` |
| Ruleset „Release-Tags schützen“ | Settings → Rules → Rulesets | Tags `v*` anlegen, verschieben, löschen nur durch Repository-Admins (du) |
| Ruleset „main schützen“ | Settings → Rules → Rulesets | kein Force-Push und kein Löschen von `main` (Admins dürfen umgehen) |

Noch von dir zu tun: **Zwei-Faktor-Anmeldung** bei GitHub (github.com → Settings → Password and authentication) und bei deiner Apple-ID prüfen bzw. einschalten. Ohne sie ist dein Konto die schwächste Stelle.

### Schritt 1: API Key in App Store Connect anlegen (ca. 3 Minuten)

1. [App Store Connect](https://appstoreconnect.apple.com) öffnen → **Users and Access** → Reiter **Integrations** → links **App Store Connect API** → **Team Keys**.
   Beim allerersten Mal muss der Account Holder (du) den API-Zugang einmal per „Request Access“ anfordern.
2. **+** (Generate API Key): Name „DiskRings Notarisierung (GitHub)“, Rolle **Developer** → **Generate**.
   Developer ist die kleinste Rolle, mit der `notarytool` nach Erfahrungsberichten funktioniert (keine Zusage von Apple). Scheitert der Trockenlauf in Schritt 4 mit „Apple lehnt den API-Key ab“, einen zweiten Key mit Rolle **App Manager** anlegen und Schritt 2 wiederholen.
   Achtung: Ein Team Key ist **nicht** auf die Notarisierung beschränkt, er hat im Rahmen seiner Rolle API-Zugriff auf das ganze Team. Wie das Zertifikat behandeln.
3. **Download API Key** → Datei `AuthKey_XXXXXXXXXX.p8`. Sie lässt sich **nur einmal** herunterladen.
4. Notieren:
   - **Key ID**: 10 Zeichen, Spalte „Key ID“ in der Liste (steht auch im Dateinamen),
   - **Issuer ID**: UUID oben über der Key-Liste (z. B. `69a6de7e-…`).

### Schritt 2: Secrets setzen – mit dem Hilfsskript (empfohlen, ca. 3 Minuten)

Das Skript ist interaktiv und braucht ein echtes Terminal (Terminal.app oder iTerm, nicht den `!`-Befehl in Claude Code). Im Projektordner:

```sh
scripts/setup-release-secrets.sh
```

Was das Skript fragt und was du antwortest:

| Frage | Antwort |
|---|---|
| Repository | Enter (`brokoskokoli/diskrings`) |
| Secrets im Environment „release“ ablegen? | **j** |
| Beides jetzt einrichten? (Freigabe, Tag-Regeln) | **j** |
| Vorhandene Schutzregeln überschreiben? | **n** (sind schon korrekt eingerichtet) |
| Passwort für das .p12 (zweimal) | ein **neues** zufälliges Passwort, mind. 12 Zeichen, z. B. aus dem Passwortmanager. Du brauchst es später nicht mehr, GitHub speichert es als `MACOS_CERTIFICATE_PASSWORD`. |
| Weg (a/b) | **a** (automatischer Export). macOS fragt dann nach deinem **Anmeldepasswort** des Macs, um den privaten Schlüssel freizugeben → **Erlauben** (nicht „Immer erlauben“). |
| Pfad zur .p8-Datei | z. B. `~/Downloads/AuthKey_XXXXXXXXXX.p8` |
| Key-ID | Enter, wenn der Vorschlag aus dem Dateinamen stimmt |
| Issuer-ID | die UUID aus Schritt 1 |
| API-Key jetzt bei Apple prüfen? | **j** (muss „API-Key funktioniert“ melden) |
| Jetzt setzen (vorhandene werden überschrieben)? | **j** |

Am Ende meldet das Skript jedes gesetzte Secret („… gesetzt“) und löscht alle temporären Dateien (auch bei Abbruch mit Ctrl-C). Dein Schlüsselbund wird nicht verändert.

Falls Weg **a** scheitert (z. B. weil macOS den Export verweigert), das Skript erneut starten und Weg **b** wählen: Schlüsselbundverwaltung → links „Anmeldung“ → oben „Meine Zertifikate“ → „Developer ID Application: Stefan Richter (AGRWTKQZ8C)“ (das Dreieck davor zeigt den privaten Schlüssel) → Rechtsklick → „… exportieren“ → Format „Persönlicher Informationsaustausch (.p12)“ → beliebiges Passwort → Pfad und Passwort im Skript angeben → die exportierte Datei danach löschen.

### Schritt 2 (Alternative): Secrets von Hand im Browser setzen

Nur nötig, wenn du das Skript nicht nutzen willst.

1. `.p12` exportieren wie bei Weg **b** oben, mit einem neuen Passwort.
2. Base64 erzeugen und in die Zwischenablage kopieren (ohne Zeilenumbrüche):
   ```sh
   base64 -i ~/Desktop/developer-id.p12 | tr -d '\n' | pbcopy   # für MACOS_CERTIFICATE_P12_BASE64
   base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy   # für NOTARY_API_KEY_P8_BASE64
   ```
3. GitHub → Repo **diskrings** → **Settings** → **Environments** → **release** → Abschnitt **Environment secrets** → **Add environment secret**, fünfmal:

| Name (exakt so) | Wert |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 der `.p12` (Zwischenablage aus Schritt 2, erste Zeile) |
| `MACOS_CERTIFICATE_PASSWORD` | das Passwort, mit dem du die `.p12` exportiert hast |
| `NOTARY_API_KEY_P8_BASE64` | Base64 der `.p8` (zweite Zeile) |
| `NOTARY_API_KEY_ID` | Key ID, 10 Zeichen, z. B. `ABC123DEF4` |
| `NOTARY_API_ISSUER_ID` | Issuer ID (UUID) |

4. Die exportierte `.p12` löschen und den Papierkorb leeren. **Nicht** unter „Repository secrets“ (Settings → Secrets and variables → Actions) eintragen, sondern unter dem Environment.

### Schritt 3: Aufräumen

- Die `.p8` sicher aufbewahren (Passwortmanager) oder löschen. Bei Verlust einfach einen neuen Key anlegen und Schritt 2 wiederholen.
- Kontrolle: Settings → Environments → release zeigt **5 Environment secrets**; unter Settings → Secrets and variables → Actions sollten **keine** dieser fünf als Repository-Secret stehen.

### Schritt 4: Trockenlauf

```sh
gh workflow run release.yml -f dry_run=true
```

GitHub → **Actions** → Lauf „Release“ öffnen → gelbes Banner **Review deployments** → `release` anhaken → **Approve and deploy**. Nach 15–25 Minuten liegen ZIP und DMG als Artefakt am Lauf, notarisiert, aber nicht veröffentlicht. Schlägt etwas fehl, steht die Ursache samt Anleitung in der Zusammenfassung des Laufs (siehe auch „Fehlersuche“ unten).

### Schritt 5: Erstes Release

```sh
git tag v0.1.0 && git push origin v0.1.0
```

Wieder unter Actions freigeben. Danach steht das Release mit DMG, ZIP und Prüfsummen unter github.com/brokoskokoli/diskrings/releases.

## Release erstellen

```sh
# 1. Version erhöhen
echo 0.2.0 > VERSION
git commit -am "Version 0.2.0"
git push origin main

# 2. Tag setzen und pushen (muss zu VERSION passen)
git tag v0.2.0 && git push origin v0.2.0
```

Der Workflow „Release“ startet, wartet ggf. auf deine Freigabe (Actions → Lauf → **Review deployments**) und

1. prüft, dass der Tag zu `VERSION` passt und alle Secrets gesetzt sind,
2. baut und testet (ohne Performance-Tests, wie die CI),
3. importiert das Zertifikat in eine temporäre Keychain mit Zufallspasswort (`set-key-partition-list`, damit `codesign` ohne Dialog läuft),
4. ruft `scripts/release.sh --skip-checks` auf: `make-app.sh` mit dieser Keychain, Notarisierung von App und DMG per API Key, `stapler`, `spctl`, ZIP, DMG, `SHA256SUMS`,
5. löscht die Keychain (immer, auch bei Fehlern) und lädt die Dateien als Artefakt hoch,
6. legt im getrennten Job `publish` (nur dieser darf schreiben, er sieht keine Signier-Secrets) das Release `v<version>` mit generierten Release-Notes an.

Dauer: meist 15–25 Minuten, den größten Teil davon wartet `notarytool` auf Apple.

## Trockenlauf

GitHub → **Actions** → **Release** → **Run workflow**, Branch `main`, `dry_run` angehakt. Oder:

```sh
gh workflow run release.yml -f dry_run=true
gh run watch
```

Alles läuft wie beim Release, nur ohne Veröffentlichung. ZIP, DMG und `SHA256SUMS` liegen als Artefakt am Lauf (14 Tage). Ein Trockenlauf notarisiert wirklich; das ist harmlos (Apple speichert nur das Ticket).

Mit `dry_run = false` veröffentlicht der Workflow nur, wenn er auf einem Tag gestartet wird („Use workflow from“ → Tags → `v0.2.0`), z. B. um einen fehlgeschlagenen Release-Lauf zu wiederholen.

## Lokal releasen

```sh
scripts/release.sh             # prüfen, bauen, signieren, notarisieren
scripts/release.sh --publish   # zusätzlich GitHub-Release v<VERSION> anlegen
```

Notarisierung lokal, wahlweise:

```sh
# Schlüsselbund-Profil (app-spezifisches Passwort der Apple-ID), einmalig:
xcrun notarytool store-credentials diskrings --apple-id <apple-id> --team-id AGRWTKQZ8C

# oder API Key (wie in der CI):
export NOTARY_API_KEY_ID=XXXXXXXXXX NOTARY_API_ISSUER_ID=<uuid> NOTARY_API_KEY_PATH=~/keys/AuthKey_XXXXXXXXXX.p8
scripts/release.sh
```

Nicht beide Wege für dieselbe Version mischen: Wenn der Tag-Workflow schon ein Release angelegt hat, nicht zusätzlich `release.sh --publish` aufrufen.

## Fehlersuche

| Meldung | Ursache und Abhilfe |
|---|---|
| „Release nicht möglich: Es fehlen Secrets“ | Secrets fehlen im Environment `release` (oder der Lauf nutzt ein anderes Environment). `scripts/setup-release-secrets.sh` ausführen. |
| „Tag 'vX' passt nicht zu VERSION“ | `VERSION` erhöhen und committen, falschen Tag löschen (`git push origin :refs/tags/vX && git tag -d vX`), richtigen Tag pushen. |
| „Import des .p12 fehlgeschlagen“ | Falsches `MACOS_CERTIFICATE_PASSWORD` oder unvollständiges base64. Skript erneut ausführen. |
| „Das .p12 enthält nicht die Identität …“ | Falsches Zertifikat exportiert (z. B. „Apple Development“) oder ohne privaten Schlüssel. Die Liste der gefundenen Identitäten steht im Log. |
| „Identität … ist nicht gültig“ | Zertifikat abgelaufen oder widerrufen. Neues Developer-ID-Zertifikat anlegen, Skript erneut ausführen. |
| „Apple lehnt den API-Key ab“ | Key ID, Issuer ID oder `.p8` passen nicht zusammen, Key widerrufen oder ein Individual Key statt eines Team Keys. Die letzten Zeilen von `notarytool` stehen darüber. |
| „Notarisierung … nicht akzeptiert“ | Das Protokoll von Apple steht direkt darunter im Log (`notarytool log`). Meist fehlende Hardened Runtime oder eine unsignierte Datei im Bündel. |
| „Release vX existiert schon“ | Altes Release löschen (`gh release delete vX`) und den Lauf wiederholen, oder `VERSION` erhöhen. |
| Lauf wartet und tut nichts | Pflicht-Freigabe: Actions → Lauf → **Review deployments** → `release` → Approve. |
| `hdiutil: create failed - Resource busy` | Bekanntes Runner-Problem; `release.sh` versucht es dreimal. Sonst Lauf wiederholen. |

Lokal nachstellen (ohne echte Secrets):

```sh
# Vorprüfung wie bei einem Tag-Push
GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v0.1.0 scripts/ci-release.sh preflight

# temporäre Keychain mit einem eigenen .p12 (z. B. einem selbst signierten Testzertifikat)
export MACOS_CERTIFICATE_P12_BASE64=$(base64 -i test.p12) MACOS_CERTIFICATE_PASSWORD=… \
       DISKRINGS_IDENTITY="Name des Testzertifikats" DISKRINGS_CI_STATE=$TMPDIR/diskrings-ci
scripts/ci-release.sh keychain-setup          # gibt DISKRINGS_KEYCHAIN=… aus
DISKRINGS_KEYCHAIN=… scripts/make-app.sh
scripts/ci-release.sh keychain-cleanup        # Keychain weg, Suchliste wie vorher
```

## Sicherheitsabwägungen

Mit dem Workflow verlässt der private Schlüssel der Developer ID den Rechner: Er liegt verschlüsselt als GitHub-Secret (libsodium Sealed Box, nur im Lauf entschlüsselt) und zur Laufzeit auf einem von GitHub gehosteten, nach dem Job verworfenen Runner. Wer den Schlüssel erbeutet, kann Software im Namen „Stefan Richter (AGRWTKQZ8C)“ signieren, mit dem API Key zusätzlich notarisieren lassen; Gatekeeper würde sie durchlassen, bis das Zertifikat widerrufen ist.

**Risiken**

- Jemand mit Schreibrechten am Repo ändert den Workflow so, dass er die Secrets ausgibt oder fremden Code signiert.
- Eine eingebundene Action wird kompromittiert (Supply Chain).
- Ein GitHub-Konto mit Zugriff (deins) wird übernommen.
- Logs könnten Secrets enthalten.

**Gegenmaßnahmen im Workflow**

- Secrets nur im Environment `release`, nur in den drei Schritten, die sie brauchen; der Job mit Schreibrecht (`publish`) sieht sie nicht, der Job mit den Secrets hat nur Leserecht.
- Standard-Token ohne Rechte (`permissions: {}`), `persist-credentials: false` beim Checkout.
- Actions auf Commit-SHAs gepinnt; nur Actions von GitHub (`actions/*`) und `maxim-lobanov/setup-xcode` (wie in der CI). Updates bewusst einspielen (SHA und Versionskommentar ändern).
- Auslöser nur Tag-Push `v*` und manueller Start; keine Pull-Request-Auslöser, also kommt fremder Code aus Forks nie an die Secrets.
- Kein `set -x`; GitHub maskiert Secret-Werte im Log zusätzlich, das zufällige Keychain-Passwort wird per `::add-mask::` maskiert. Die `.p8` liegt nur für die Dauer eines `notarytool`-Aufrufs in einer Datei (0600) unter `$RUNNER_TEMP`, das `.p12` nur bis zum Import. Die Keychain wird im `always()`-Schritt gelöscht.
- Bekannte Restlücke: Das zufällige Keychain-Passwort und das `.p12`-Passwort stehen für die Dauer von `security create-keychain`/`unlock-keychain`/`import`/`set-key-partition-list` als Prozessargumente in der Prozessliste (das `security`-Werkzeug nimmt sie nicht anders ohne Dialog an). Auf dem gehosteten, nur für diesen Job gestarteten Runner kann sie nur der eigene Job sehen; das Risiko ist gering. Lokal gilt dasselbe für `scripts/setup-release-secrets.sh` (temporäres Export-Passwort).
- Das Zwischenzertifikat von Apple wird, falls es auf dem Runner fehlt, nur mit geprüfter SHA-256-Summe nachgeladen.

**Was du einrichten solltest**

- **Pflicht-Freigabe** am Environment `release`: Kein Lauf kommt ohne deinen Klick an die Secrets, auch nicht nach einem manipulierten Push.
- **Deployment-Regeln** am Environment: nur Tags `v*` und `main`.
- **Tag- und Branch-Rulesets** (siehe oben), damit nur du Release-Tags setzen und `main` nicht umgeschrieben werden kann.
- **Zwei-Faktor-Anmeldung** bei GitHub und Apple.
- Der API Key bekommt die kleinste Rolle, mit der `notarytool` funktioniert (**Developer**). Er ist trotzdem nicht auf die Notarisierung beschränkt, sondern hat im Rahmen dieser Rolle API-Zugriff auf das ganze Team (z. B. App-Metadaten und Builds). Bei Verdacht deshalb immer auch den Key widerrufen.

**Bei Verdacht auf Missbrauch**

1. Zertifikat widerrufen: [developer.apple.com](https://developer.apple.com/account/resources/certificates/list) → Certificates → Developer ID Application → Revoke, oder über den Apple Developer Support (dort lässt sich auch der Zeitpunkt der Kompromittierung angeben). Signaturen mit sicherem Zeitstempel vor dem Widerrufsdatum bleiben gültig, spätere nicht; neue Builds brauchen ein neues Zertifikat.
2. API Key in App Store Connect widerrufen (Team Keys → Revoke).
3. Secrets in GitHub löschen (`gh secret delete … --env release`), Environment-Protokoll und Action-Läufe prüfen.
4. Neues Zertifikat und neuen Key anlegen, `scripts/setup-release-secrets.sh` erneut ausführen.

Wer das Risiko nicht tragen will, löscht die Secrets und nutzt nur den lokalen Weg (`scripts/release.sh`); der Workflow bricht dann mit einer Anleitung ab.
