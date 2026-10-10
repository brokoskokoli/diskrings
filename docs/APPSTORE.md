# Mac App Store: Einrichtung und Ablauf

Die Store-Variante entsteht aus demselben Code wie die Download-Version. Sie läuft in der **App Sandbox**: DiskRings liest dort nur Ordner, die über den Öffnen-Dialog freigegeben wurden, und merkt sich die Freigaben. Gebaut wird sie mit `scripts/make-app.sh --appstore` (Spezifikation: SPEC 11; Befehle auch in [RELEASING.md](RELEASING.md), Abschnitt „Mac App Store“).

**Stand:** Code, Build-Skript, CI-Schritt und Datenschutzseite sind fertig. Ohne die Zertifikate unten baut das Skript eine ad hoc signierte Sandbox-App und ein **unsigniertes** `.pkg` (zum lokalen Testen, nicht hochladbar). Was noch von dir kommt: Schritte 1–5.

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
| Screenshots | mindestens einer, 16:10: 1280×800, 1440×900, 2560×1600 oder 2880×1800 (liefere ich aus dem Snapshot-Renderer) |
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
  Der Key braucht in App Store Connect mindestens die Rolle **App Manager**; der Notarisierungs-Key (Rolle Developer) reicht dafür vermutlich nicht. Mit installiertem Xcode geht alternativ `xcrun altool --upload-app -f build/DiskRings-<version>.pkg -t macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>`. Ein Workflow „App Store Upload“ (von Hand gestartet, Environment mit Freigabe) kann folgen, sobald der manuelle Weg einmal geklappt hat.

## Je Version

1. `VERSION` erhöhen (die Build-Nummer ergibt sich aus der Zahl der Commits und steigt damit automatisch; der Store verlangt eine höhere als beim letzten Upload).
2. Bauen (Tests vorher mit `scripts/check.sh`):
   ```sh
   DISKRINGS_PROVISIONING_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/DiskRings_App_Store.provisionprofile" \
     scripts/make-app.sh --appstore
   ```
   Erwartet in der Ausgabe: `codesign (Apple Distribution: …)`, die Entitlements (drei Sandbox-Schlüssel plus `application-identifier`/`team-identifier`) und `productbuild (3rd Party Mac Developer Installer: …)`. Prüfen:
   ```sh
   codesign -d --entitlements - build/appstore/DiskRings.app
   pkgutil --check-signature build/DiskRings-<version>.pkg
   ```
   Steht dort `adhoc-sandbox` oder „unsigniert“, fehlt ein Zertifikat (Schritt 1). Andere Identitäten: `DISKRINGS_APPSTORE_IDENTITY=…`, `DISKRINGS_INSTALLER_IDENTITY=…`.
3. Hochladen (Transporter oder `altool`), nach ca. 10–30 Minuten erscheint der Build in App Store Connect.
4. Optional **TestFlight** (Mac): Build an dich selbst verteilen und testen.
5. In der Version den Build auswählen → **Zur Prüfung einreichen**.
6. Nach der Freigabe automatisch oder von Hand veröffentlichen.

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
- Screenshots aus dem Snapshot-Renderer (`swift run DiskRings --render-snapshots build/snapshots`; Sandbox-Ansichten: `start-sandbox-*`, `settings-sandbox-*`).
