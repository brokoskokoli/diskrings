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

### 1. API Key in App Store Connect anlegen

1. [App Store Connect](https://appstoreconnect.apple.com) → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys**.
   Beim ersten Mal muss der Account Holder den API-Zugang einmal anfordern.
2. **+** (Generate API Key), Name z. B. „DiskRings Notarisierung (GitHub)“, Rolle **Developer**.
   Das ist die kleinste Rolle, mit der `notarytool` nach unserem Kenntnisstand funktioniert
   (Erfahrungsberichte, keine Zusage von Apple); der erste Trockenlauf beweist es. Scheitert er
   mit „Apple lehnt den API-Key ab“, einen Key mit Rolle **App Manager** anlegen.
   Achtung: Ein Team Key ist **nicht** auf die Notarisierung beschränkt. Er hat API-Zugriff auf
   das ganze Team im Rahmen seiner Rolle (z. B. App-Metadaten, Builds, TestFlight) und ist deshalb
   genauso sorgfältig zu behandeln wie das Zertifikat.
3. **Download API Key**: Die Datei `AuthKey_<KeyID>.p8` lässt sich nur **einmal** herunterladen.
4. Die **Key ID** (Spalte in der Liste) und die **Issuer ID** (UUID über der Liste) notieren.

### 2. Hilfsskript ausführen

Voraussetzungen: [GitHub CLI](https://cli.github.com) angemeldet (`gh auth login`, mit Admin-Rechten am Repo) und das Zertifikat „Developer ID Application: Stefan Richter (AGRWTKQZ8C)“ mit privatem Schlüssel im Anmelde-Schlüsselbund.

```sh
scripts/setup-release-secrets.sh
```

Das Skript

1. legt bei Bedarf das Environment `release` an und richtet auf Wunsch eine **Pflicht-Freigabe** (du selbst als Reviewer) und die Regel „nur Tags `v*` und Branch `main`“ ein,
2. exportiert die Developer ID samt privatem Schlüssel als `.p12` mit einem neuen Passwort: automatisch per `security export` (macOS fragt pro privatem Schlüssel im Schlüsselbund einmal nach dem Anmeldepasswort; „Erlauben“ genügt) oder aus einer selbst exportierten Datei (Schlüsselbundverwaltung → Anmeldung → Meine Zertifikate → Rechtsklick auf das Zertifikat → exportieren als `.p12`). In beiden Fällen bleibt nur diese eine Identität samt Zwischenzertifikat im `.p12`,
3. fragt nach `.p8`, Key ID und Issuer ID und prüft den Key auf Wunsch bei Apple,
4. setzt die Secrets per `gh secret set --env release`,
5. löscht die temporären Dateien (auch bei Abbruch).

Danach die `.p8` offline aufbewahren oder löschen; bei Verlust einfach einen neuen Key anlegen und das Skript erneut ausführen.

Secrets (alle im Environment `release`; Repository-Secrets funktionieren auch, dann entfällt aber die Freigabe):

| Secret | Inhalt |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | `.p12` mit Zertifikat und privatem Schlüssel, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | Passwort des `.p12` |
| `NOTARY_API_KEY_P8_BASE64` | `AuthKey_<KeyID>.p8`, base64 |
| `NOTARY_API_KEY_ID` | Key ID (10 Zeichen) |
| `NOTARY_API_ISSUER_ID` | Issuer ID (UUID) |

### 3. Environment prüfen (oder von Hand anlegen)

GitHub → **Settings** → **Environments** → `release`:

- **Required reviewers**: dich selbst eintragen, „Prevent self-review“ **aus** (sonst kann ein Einzel-Maintainer nie freigeben). Jeder Lauf wartet dann auf deine Freigabe unter Actions, bevor er die Secrets sieht.
- **Deployment branches and tags** → „Selected branches and tags“: Tag-Regel `v*` und Branch-Regel `main` (für Trockenläufe). Andere Branches kommen nicht an die Secrets.
- **Environment secrets**: die fünf Secrets oben.

Existiert das Environment nicht, legt GitHub es beim ersten Lauf ohne Schutz an.

### 4. Tags schützen (empfohlen)

**Settings** → **Rules** → **Rulesets** → **New tag ruleset**: Ziel `v*`, Regeln „Restrict creations“, „Restrict updates“, „Restrict deletions“, Bypass nur für dich (Repository admin). Damit kann niemand sonst einen Release-Tag setzen oder verschieben. Für `main` entsprechend ein Branch-Ruleset (kein Force-Push, keine Löschung).

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
