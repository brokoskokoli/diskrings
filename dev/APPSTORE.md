# Mac App Store: Einrichtung und Ablauf

Die Store-Variante entsteht aus demselben Code wie die Download-Version. Sie läuft in der **App Sandbox**: DiskRings liest dort nur Ordner, die über den Öffnen-Dialog freigegeben wurden, und merkt sich die Freigaben. Gebaut wird sie mit `scripts/make-app.sh --appstore` (Spezifikation: SPEC 11; Befehle auch in [RELEASING.md](RELEASING.md), Abschnitt „Mac App Store“).

**Stand:** Code, Build-Skript, CI-Schritt, Upload-Workflow (optional mit Einreichung zur Prüfung per API) und Datenschutzseite sind fertig. Der erste Build (0.2.0, Build 118) wurde von Hand hochgeladen. Ohne die Zertifikate unten baut das Skript eine ad hoc signierte Sandbox-App und ein **unsigniertes** `.pkg` (zum lokalen Testen, nicht hochladbar). Für den Upload per Workflow fehlt noch Schritt 6.

Dieses Dokument beschreibt die **einmaligen Schritte von Hand** und den Ablauf je Version. Alles ist im Apple-Developer-Programm enthalten, es fallen keine Zusatzkosten an.

| | Download-Version (GitHub) | Store-Version |
|---|---|---|
| Signatur | Developer ID Application | Apple Distribution |
| Paket | DMG/ZIP, notarisiert | `.pkg`, signiert mit Mac Installer Distribution |
| Bündel | `build/DiskRings.app` | `build/appstore/DiskRings.app` und `build/DiskRings-<version>.pkg` |
| Zugriff | alles Lesbare, mit Festplattenvollzugriff fast alles | nur freigegebene Ordner (Sandbox) |
| Prüfung | automatische Notarisierung (Minuten) | App Review durch Apple (meist 1–3 Tage) |

Bundle-ID beider Varianten: `de.stefanrichter.DiskRings`.

## Einmalig (ca. 45–60 Minuten)

### 1. Zwei Zertifikate anlegen

1. **Zertifikatsanfrage (CSR) erzeugen:** Schlüsselbundverwaltung öffnen → Menü *Schlüsselbundverwaltung → Zertifikatsassistent → Zertifikat einer Zertifizierungsinstanz anfordern …* → E-Mail und Name eintragen, „Auf der Festplatte sichern“ → `CertificateSigningRequest.certSigningRequest`.
2. [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list) → **+** → **Apple Distribution** → CSR hochladen → `.cer` laden → doppelklicken (landet im Anmelde-Schlüsselbund).
3. Noch einmal **+** → **Mac Installer Distribution** → dieselbe CSR → `.cer` laden → doppelklicken.
4. Prüfen im Terminal:
   ```sh
   security find-identity -v | grep -E "Apple Distribution|3rd Party Mac Developer Installer|Mac Installer Distribution"
   ```
   Beide sollten mit „Stefan Richter (AGRWTKQZ8C)“ erscheinen.

### 2. App-ID registrieren

[Identifiers](https://developer.apple.com/account/resources/identifiers/list) → **+** → **App IDs** → **App** → Plattform **macOS**, Beschreibung „DiskRings“, Bundle ID **Explicit** `de.stefanrichter.DiskRings`. Keine Capabilities anhaken (die Sandbox braucht hier keine) → Register.

### 3. Provisioning Profile

[Profiles](https://developer.apple.com/account/resources/profiles/list) → **+** → unter *Distribution* **Mac App Store Connect** → App-ID `de.stefanrichter.DiskRings` → Zertifikat *Apple Distribution* → Name „DiskRings App Store“ → **Download**.

Die Datei `DiskRings_App_Store.provisionprofile` an einen festen Ort legen, z. B. `~/Library/MobileDevice/Provisioning Profiles/`, und den Pfad beim Bauen in `DISKRINGS_PROVISIONING_PROFILE` übergeben. Sie enthält keine Geheimnisse, gehört aber trotzdem nicht ins Repo. Das Skript bettet sie als `Contents/embedded.provisionprofile` ein und übernimmt `application-identifier` und `team-identifier` daraus in die Signatur (es bricht ab, wenn das Profil zu einer anderen Bundle-ID gehört).

### 4. App in App Store Connect anlegen

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps** → **+** → **Neue App**:

- Plattform **macOS**, Name **DiskRings** (muss im Store eindeutig sein; falls vergeben, z. B. „DiskRings – Disk Space Rings“), Primärsprache Englisch oder Deutsch, Bundle-ID aus der Liste, SKU `diskrings`, voller Zugriff.

Danach in der App:

| Bereich | Eintrag |
|---|---|
| App-Informationen | Kategorie **Dienstprogramme** (Utilities), optional zweite Kategorie Produktivität; Altersfreigabe-Fragebogen (alles „Nein“ → 4+) |
| Preise und Verfügbarkeit | Gratis (oder Preis; dafür braucht es den Vertrag „Paid Apps“ mit Steuer- und Bankdaten unter *Business*) |
| App-Datenschutz | „Daten werden nicht erfasst“; **URL zur Datenschutzrichtlinie**: `https://brokoskokoli.github.io/diskrings/privacy.html` (Quelle `docs/privacy.html`, erscheint nach dem Merge auf `main` über GitHub Pages) |
| Version 0.x | Beschreibung, Schlüsselwörter, Support-URL (`https://github.com/brokoskokoli/diskrings/issues`), Marketing-URL (die Pages-Seite), Copyright „2026 Stefan Richter“ |
| Screenshots | mindestens einer, 16:10: 1280×800, 1440×900, 2560×1600 oder 2880×1800; fertig gerendert mit `--store-screenshots`, siehe [Screenshots](#screenshots) |
| App Review | Kontaktdaten; Hinweis für die Prüfer, siehe unten |

**Exportkontrolle:** DiskRings verwendet keine eigene Verschlüsselung. Die Store-Variante setzt `ITSAppUsesNonExemptEncryption = false` im Info.plist, dann entfällt die Frage beim Hochladen.

### 5. Hochladen: Werkzeug wählen

`altool` gehört zu Xcode und fehlt bei den Command Line Tools (geprüft: `xcrun --find altool` schlägt fehl). Deshalb:

- **Transporter** (kostenlos im Mac App Store, empfohlen): `.pkg` hineinziehen, mit der Apple-ID anmelden, „Liefern“. Transporter prüft das Paket vor dem Hochladen.
- **Kommandozeile** über das in Transporter enthaltene `iTMSTransporter` mit einem API Key (die `.p8` muss unter `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` liegen):
  ```sh
  /Applications/Transporter.app/Contents/itms/bin/iTMSTransporter -m upload \
    -assetFile build/DiskRings-<version>.pkg -apiKey <KEY_ID> -apiIssuer <ISSUER_ID> -v informational
  ```
  Der Key braucht in App Store Connect mindestens die Rolle **App Manager**; der Notarisierungs-Key (Rolle Developer) reicht dafür vermutlich nicht. Mit installiertem Xcode geht alternativ `xcrun altool --upload-app -f build/DiskRings-<version>.pkg -t macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>`. Der übliche Weg ab Version 0.2.1 ist der Workflow „App Store Upload“ (unten).

### 6. Upload per Workflow einrichten (einmalig, ca. 15 Minuten)

Der Workflow [`.github/workflows/appstore.yml`](../.github/workflows/appstore.yml) („App Store Upload“) baut die Store-Variante auf einem macOS-Runner, signiert App und `.pkg`, lässt das Paket von App Store Connect prüfen (`altool --validate-app`) und lädt es hoch. Er startet nur von Hand und lädt nur auf einem Tag `v<VERSION>` hoch, der zu `VERSION` passt; sonst (oder mit `dry_run`) ist es ein Trockenlauf ohne Upload. Die Logik steht in `scripts/ci-appstore.sh`; das Sicherheitsmodell ist dasselbe wie beim Release-Workflow (siehe [RELEASING.md](RELEASING.md), „Sicherheitsabwägungen“): Token ohne Schreibrechte, gepinnte Actions, Secrets nur im Environment, temporäre Keychain mit Zufallspasswort, `.p8` nur während des `altool`-Aufrufs auf der Platte.

1. **Environment `appstore` anlegen:** GitHub → Settings → Environments → **New environment** `appstore` → *Required reviewers*: du; *Wait timer* nach Wunsch (z. B. 5 Minuten, Zeit zum Abbrechen); *Deployment branches and tags* → „Selected branches and tags“ → Tag-Regel `v*` und Branch `main`.
2. **API Key mit Rolle App Manager:** Der Workflow nutzt dieselben Secret-Namen wie die Notarisierung (`NOTARY_API_KEY_*`), aber im Environment `appstore`. Hat der vorhandene Key nur die Rolle **Developer**, in App Store Connect (Users and Access → Integrations → App Store Connect API → Team Keys) einen neuen Team Key mit Rolle **App Manager** anlegen und hier dessen `.p8`, Key-ID und Issuer-ID verwenden. Der Release-Workflow kann bei seinem Developer-Key bleiben.
3. **Secrets setzen** (im Terminal, interaktiv; braucht beide Zertifikate aus Schritt 1 im Anmelde-Schlüsselbund und das Profil aus Schritt 3):
   ```sh
   scripts/setup-release-secrets.sh --appstore
   ```
   Antworten wie in [RELEASING.md](RELEASING.md), Schritt 2; zusätzlich der Pfad zum Provisioning Profile. Das Skript schreibt „Apple Distribution“ und „3rd Party Mac Developer Installer“ in je ein eigenes `.p12` (gleiches Passwort) und setzt sieben Secrets im Environment `appstore`; ein altes `APPSTORE_CERTIFICATES_P12_BASE64` löscht es:

   | Secret | Inhalt |
   |---|---|
   | `APPSTORE_DISTRIBUTION_P12_BASE64` | `.p12` mit „Apple Distribution: …“ (Zertifikat + privater Schlüssel), base64 |
   | `APPSTORE_INSTALLER_P12_BASE64` | `.p12` mit „3rd Party Mac Developer Installer: …“ (Zertifikat + privater Schlüssel), base64 |
   | `APPSTORE_CERTIFICATES_PASSWORD` | Passwort beider `.p12` |
   | `APPSTORE_PROVISIONING_PROFILE_BASE64` | `DiskRings_App_Store.provisionprofile`, base64 |
   | `NOTARY_API_KEY_P8_BASE64` | `AuthKey_<KeyID>.p8` (Rolle App Manager), base64 |
   | `NOTARY_API_KEY_ID` | Key-ID (10 Zeichen) |
   | `NOTARY_API_ISSUER_ID` | Issuer-ID (UUID) |
   Warum zwei `.p12`: Beide Zertifikate entstehen meist aus derselben CSR und teilen sich einen privaten Schlüssel. Aus einem gemeinsamen `.p12` ordnet `security import` diesen Schlüssel nur einem der Zertifikate zu, dann fehlt in der CI die Identität „Apple Distribution“ („Gefundene Identitäten … (keine)“). Nacheinander in dieselbe Keychain importiert, sind beide Identitäten da. Ist noch das alte Secret `APPSTORE_CERTIFICATES_P12_BASE64` gesetzt, bricht der Workflow im ersten Schritt mit dem Hinweis ab, das Skript erneut auszuführen.
4. **Trockenlauf:** `gh workflow run appstore.yml -f dry_run=true`, unter Actions freigeben. Er baut, signiert und validiert bei Apple, lädt aber nichts hoch; das `.pkg` hängt einen Tag lang als Artefakt am Lauf.

Optional kann der Workflow nach dem Upload auch zur Prüfung einreichen (Eingabe `submit_for_review`, siehe „Einreichen per Workflow“ unten); das braucht keine weiteren Secrets.

Falls eine künftige Xcode-Version `altool --upload-app` nicht mehr kennt, weicht das Skript auf `altool --upload-package` aus; das braucht die numerische **Apple ID** der App (App Store Connect → App-Informationen) als Variable `APPSTORE_APP_ID` (Settings → Environments → appstore → Environment variables).

## Je Version

**Mit dem Workflow (empfohlen):**

1. `VERSION` erhöhen, committen, nach `main` pushen, Tag setzen und pushen (wie in [RELEASING.md](RELEASING.md), „Release erstellen“; der Tag startet auch den Release-Workflow für die Download-Version).
2. GitHub → **Actions** → **App Store Upload** → **Run workflow** → „Use workflow from“ → **Tags** → `v<version>`, **dry_run abhaken** → Run. Oder: `gh workflow run appstore.yml --ref v<version> -f dry_run=false`.
3. Lauf freigeben (**Review deployments** → `appstore` → Approve), Wartezeit abwarten. Nach etwa 10–15 Minuten ist das Paket validiert und hochgeladen; die Zusammenfassung des Laufs nennt Version und Build-Nummer.
4. Nach weiteren 10–30 Minuten erscheint der Build in App Store Connect (Apple schickt eine E-Mail, wenn er verarbeitet ist).
5. Optional **TestFlight** (Mac): Build an dich selbst verteilen und testen.
6. In App Store Connect die macOS-Version `<version>` anlegen bzw. öffnen, unter **Build** den Build auswählen → **Zur Prüfung einreichen**.
7. Nach der Freigabe automatisch oder von Hand veröffentlichen.

Schritte 4 und 6 übernimmt der Workflow, wenn zusätzlich **submit_for_review** angehakt ist (nächster Abschnitt). TestFlight entfällt dann.

### Einreichen per Workflow (submit_for_review)

Mit `submit_for_review` reicht der Workflow die Version nach dem Upload über die [App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi) zur Prüfung ein. Logik: `scripts/asc-submit.sh`, Token (JWT, ES256, 19 Minuten gültig, wird bei langem Warten erneuert): `scripts/asc-jwt.swift` mit CryptoKit. Derselbe API Key wie für den Upload (Rolle App Manager).

```sh
gh workflow run appstore.yml --ref v<version> -f dry_run=false -f submit_for_review=true
# nach der Freigabe automatisch veröffentlichen:  -f release_after_approval=true
```

| Eingabe | Standard | Wirkung |
|---|---|---|
| `dry_run` | an | Trockenlauf ohne Upload; muss für `submit_for_review` aus sein |
| `submit_for_review` | aus | nach dem Upload einreichen; nur auf einem Tag `v<VERSION>` |
| `release_after_approval` | aus | aus: Veröffentlichung von Hand („Diese Version manuell veröffentlichen“, `MANUAL`); an: automatisch nach der Freigabe (`AFTER_APPROVAL`) |

**Voraussetzung:** `dev/release-notes/<VERSION>.en.txt` und `.de.txt` im Tag (Konvention: [release-notes/README.md](release-notes/README.md)). Fehlen sie, sind sie leer, länger als 4000 Zeichen oder enthalten noch Platzhalter, bricht schon die Vorprüfung ab, vor dem Bauen. Prüfen vor dem Tag: `scripts/asc-submit.sh check-notes`.

**Automatisch:**

1. App-ID über die Bundle-ID suchen (oder Variable `APPSTORE_APP_ID`).
2. Warten, bis Apple den hochgeladenen Build verarbeitet hat (`processingState` `VALID`; Abfrage alle 60 s, höchstens 60 Minuten). `INVALID`/`FAILED` bricht ab.
3. macOS-Version `<VERSION>` suchen; sonst eine noch nicht eingereichte macOS-Version umbenennen (Apple erlaubt nur eine in Vorbereitung); sonst neu anlegen. Veröffentlichungsart nach `release_after_approval`.
4. „Neu in dieser Version“ für en-US und de-DE setzen (fehlende Lokalisierung wird angelegt). Bei der ersten Version einer App lässt Apple den Text nicht zu: Warnung, weiter.
5. Build an die Version hängen.
6. Einreichung anlegen (oder eine offene, noch nicht eingereichte wiederverwenden), Version hinzufügen, einreichen.

Ist die Version schon eingereicht, in Prüfung oder freigegeben, meldet der Schritt das und ändert nichts. Läuft für macOS schon eine andere Einreichung oder gibt es eine abgelehnte mit offenen Punkten, bricht er mit Hinweis ab; die Version ist dann vorbereitet, aber nicht eingereicht. Lehnt Apple die Einreichung ab (fehlende Angaben), stehen Apples Fehlermeldungen (`errors[].detail`, auch die zugeordneten Fehler je Feld) im Log und in der Zusammenfassung. Wiederholungen bei 429/5xx macht das Skript selbst.

**Bleibt beim Maintainer:**

- Inhalte der Versionsseite, die sich ändern: Beschreibung, Schlüsselwörter, Werbetext, **neue Screenshots** ([Screenshots](#screenshots)), Copyright-Jahr. Apple übernimmt sie aus der vorigen Version. Sollen sie sich ändern: vor dem Lauf in App Store Connect die macOS-Version `<VERSION>` von Hand anlegen und bearbeiten; der Workflow verwendet sie dann weiter.
- Neue Sprachen: Eine neu angelegte Lokalisierung hat nur „Neu in dieser Version“; Beschreibung und Screenshots fehlen dann und Apple lehnt die Einreichung ab.
- App-Informationen, Datenschutzangaben, Altersfreigabe, Preise.
- Rückfragen und Ablehnungen von App Review beantworten (Resolution Center in App Store Connect).
- Bei manueller Veröffentlichung nach der Freigabe: **Diese Version veröffentlichen**.

Lokal testen ohne Apple: `scripts/test-asc-submit.sh` spielt den Ablauf gegen einen Mock-Server durch (Build-Abfrage, Version anlegen/wiederverwenden, Lokalisierungen, schon eingereicht, Fehlerdetails, 429/5xx) und prüft das JWT mit openssl (ca. 10 s).

**Build-Nummer:** `CFBundleVersion` ist die Zahl der Commits bis zum Tag (`git rev-list --count v<version>`). Da Tags auf `main` gesetzt werden und `main` nicht umgeschrieben werden kann (Ruleset), steigt sie mit jedem neuen Tag. App Store Connect lehnt einen Build ab, dessen Build-Nummer nicht höher ist als die des letzten Uploads. Der erste Upload (von Hand) war Version 0.2.0 mit **Build 118**, gebaut vom damaligen Stand von `main`; der Tag `v0.2.0` selbst hat nur 114 Commits. Den Tag `v0.2.0` deshalb **nicht** über den Workflow hochladen, erst die nächste Version (ihr Tag liegt nach Commit 118). Ein Tag auf einem Seitenzweig hätte eine kleinere Commit-Zahl und würde ebenfalls abgelehnt.

**Von Hand (ohne Workflow):**

1. `VERSION` erhöhen (siehe Build-Nummer oben).
2. Bauen (Tests vorher mit `scripts/check.sh`):
   ```sh
   DISKRINGS_PROVISIONING_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/DiskRings_App_Store.provisionprofile" \
     scripts/make-app.sh --appstore
   ```
   Erwartet in der Ausgabe: `codesign (Apple Distribution: …)`, die Entitlements (drei Sandbox-Schlüssel plus `application-identifier`/`team-identifier`) und `productsign (3rd Party Mac Developer Installer: …)`. Prüfen:
   ```sh
   codesign -d --entitlements - build/appstore/DiskRings.app
   pkgutil --check-signature build/DiskRings-<version>.pkg
   ```
   Steht dort `adhoc-sandbox` oder „unsigniert“, fehlt ein Zertifikat (Schritt 1). Andere Identitäten: `DISKRINGS_APPSTORE_IDENTITY=…`, `DISKRINGS_INSTALLER_IDENTITY=…`.
3. Hochladen (Transporter oder `altool`, Schritt 5), weiter wie oben ab Schritt 4.

## Screenshots

Die App rendert die Store-Screenshots selbst, ausschließlich aus Demo-Daten (Home `/Users/demo`, erfundenes 994-GB-Volume „Macintosh HD“, zwei erfundene externe Volumes). Es wird nichts gescannt, und weder die echte Snapshot-Ablage noch die Volumes des Rechners erscheinen:

```sh
swift build
for lang in en de; do for app in light dark; do
  .build/debug/DiskRings --store-screenshots build/store/$lang/$app --language $lang --appearance $app
done; done
sips -g pixelWidth -g pixelHeight build/store/*/*/*.png   # alle 2880 × 1800
```

`--store-screenshots <ordner>` rendert den ganzen Fensterinhalt mit 1440 × 900 Punkten bei Skalierung 2, also genau **2880 × 1800 px** (16:10). `--language <code>` wählt die Sprache (alle 14 möglich), `--appearance light|dark` das Erscheinungsbild (Standard: hell). Szenen:

| Datei | Inhalt |
|---|---|
| `01-overview.png` | ganzes Volume mit Systemdaten, Löschbar und Frei im Ring, Liste, Belegungsbalken in der Statusleiste, Tooltip auf Library |
| `02-drilldown.png` | hineingezoomt in Library, Breadcrumb, Caches in der Liste aufgeklappt |
| `03-compare-growth.png` | Vergleich mit einem Snapshot: Wachstums-Sunburst und „Größte Veränderungen“ |
| `04-compare-delta.png` | Delta-Färbung (orange/blau), entfernte Filme gestrichelt |
| `05-context-menu.png` | Kontextmenü auf Downloads (nachgebildet wie im Snapshot-Renderer, ins Fenster gesetzt) |
| `06-start.png` | Startbildschirm mit Volumes und gestapelten Balken |

Code: `Sources/DiskRings/Snapshots/StoreScreenshotRenderer.swift`, Demo-Bäume in `DemoTree.home(scale:afterChanges:)`.

## Hinweis für die App-Prüfung (Vorschlag)

> DiskRings visualizes disk usage. In the sandboxed App Store version it only reads folders the user explicitly selects in the Open dialog (security-scoped bookmarks). "Move to Trash" uses FileManager.trashItem, always within user-selected folders, never deletes permanently, is undoable (⌘Z), and asks for confirmation. The app makes no network connections and collects no data.

## Häufige Ablehnungsgründe und wie DiskRings sie vermeidet

- **Verweise auf Festplattenvollzugriff oder Systemeinstellungen:** In der Sandbox blendet DiskRings diese Hinweise aus.
- **Fehlende Sandbox-Entitlements / zu breite Entitlements:** nur `app-sandbox`, `files.user-selected.read-write` und `files.bookmarks.app-scope`.
- **Fehlendes Icon in voller Größe:** Das Icon enthält 1024×1024 (512@2x).
- **Screenshots mit fremden Inhalten oder Nutzernamen:** Die Screenshots kommen aus Testdaten.

## Lokal testen ohne Zertifikate

```sh
scripts/make-app.sh --appstore          # ad hoc mit Sandbox-Entitlements, unsigniertes .pkg
open -n build/appstore/DiskRings.app    # läuft sandboxed: ~/Library/Containers/de.stefanrichter.DiskRings entsteht
```

Die Store-Variante hat einen eigenen Container mit eigenen Einstellungen, Freigaben und Snapshots (`~/Library/Containers/de.stefanrichter.DiskRings/Data/Library/Application Support/DiskRings/Snapshots`). Läuft gleichzeitig die Download-Version (gleiche Bundle-ID), mit `open -n` starten, sonst aktiviert macOS nur die laufende App. Die CI baut die Variante bei jedem Push auf diese Weise.

## Verhalten in der Sandbox (Kurzfassung von SPEC 11)

- Klick auf ein Volume, „Benutzerordner scannen“ oder ein Neuscan ohne Freigabe öffnet den Öffnen-Dialog direkt auf dem Ziel; „Zugriff erlauben“ genügt. Freigaben bleiben gespeichert (Einstellungen → „Ordnerzugriff“, dort auch entfernen).
- Drag & Drop eines Ordners gibt ihn frei.
- Keine Hinweise auf Festplattenvollzugriff; stattdessen „Zugriff auf weitere Ordner erlauben …“.
- Papierkorb nur in freigegebenen Ordnern; ⌘Z nur, wenn der Elternordner freigegeben ist, sonst Hinweis auf „Zurücklegen“ im Finder.
- Nicht eingehängte APFS-Volumes (z. B. Recovery) fehlen in den Systemdaten (kein `diskutil` in der Sandbox).

## Offene Punkte vor der ersten Einreichung

- Auf echtem Gerät mit Distributionssignatur einmal prüfen: Volume freigeben und scannen, App neu starten (Bookmark wird aufgelöst), Testordner in einem freigegebenen temporären Ordner in den Papierkorb legen und mit ⌘Z zurücklegen. Ob die Sandbox das Zurücklegen aus `~/.Trash` erlaubt, ist bisher nicht auf echten Daten geprüft.
- Screenshots: `--store-screenshots` (siehe [Screenshots](#screenshots)) hochladen; Sandbox-Ansichten bei Bedarf aus dem Snapshot-Renderer (`start-sandbox-*`, `settings-sandbox-*`).
