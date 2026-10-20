# App Store Connect: Texte und Angaben

Alle Einträge für die Store-Seite von DiskRings, zum Kopieren. Grenzen von Apple in Klammern; die Längen sind geprüft. Englisch ist die Primärsprache, Deutsch eine zusätzliche Lokalisierung (in App Store Connect oben rechts auf der Versionsseite die Sprache umschalten bzw. hinzufügen).

Screenshots erzeugt `swift run DiskRings --store-screenshots <ordner> --language en|de --appearance light|dark` (2880 × 1800, nur Testdaten).

## App-Informationen (linke Spalte → Allgemein → App-Informationen)

| Feld | Eintrag |
|---|---|
| Name (30) | `DiskRings` (falls vergeben: `DiskRings: Disk Space Rings`) |
| Untertitel EN (30) | `See where your disk space goes` |
| Untertitel DE (30) | `Sieh, wo dein Speicher bleibt` |
| Primäre Kategorie | Dienstprogramme (Utilities) |
| Sekundäre Kategorie | Produktivität (Productivity) |
| Altersfreigabe | Fragebogen: überall „Keine“ bzw. „Nein“ → 4+ |
| Datenschutzrichtlinie (URL) | `https://brokoskokoli.github.io/diskrings/privacy.html` |
| Lizenzvereinbarung | Standard-EULA von Apple |

## App-Datenschutz

„Daten werden nicht erfasst“ (Data Not Collected). Die Store-Variante stellt keine Netzwerkverbindungen her: Sparkle (Update-Prüfung) steckt nur in der Download-Version von GitHub; `make-app.sh --appstore` baut ohne den Package Trait `Updates` und bricht ab, wenn Sparkle im Bündel auftaucht (siehe `dev/DECISIONS.md`).

„Mit KI analysieren“ ändert daran nichts: Die App öffnet auf ausdrücklichen Klick nur den Standardbrowser mit einem Link (bzw. kopiert den Prompt in die Zwischenablage). Die Daten gehen vom Nutzer über seinen Browser an einen Dienst seiner Wahl; weder der Entwickler noch ein in die App eingebundener Dritter erhält sie („collect“ im Sinne von Apple = Übertragung vom Gerät an den Entwickler oder seine Partner). Keine Netzwerk-Berechtigung, kein SDK. Die interaktiven CLI-Sitzungen gibt es in der Store-Variante nicht (Package Trait `AISessions` aus, `make-app.sh --appstore` prüft das Binary).

## Preise und Verfügbarkeit

Gratis, alle Länder und Regionen.

## Versionsseite (macOS App → Version)

| Feld | Eintrag |
|---|---|
| Version | `0.2.1` (muss zur Datei `VERSION` des hochgeladenen Builds passen) |
| Copyright | `2026 Stefan Richter` |
| Support-URL | `https://github.com/brokoskokoli/diskrings/issues` |
| Marketing-URL | `https://brokoskokoli.github.io/diskrings/` |
| Build | nach dem Upload auswählen |
| Veröffentlichung | „Diese Version manuell veröffentlichen“ (beim ersten Mal empfohlen) |

### Werbetext (170, jederzeit ohne neue Prüfung änderbar)

**EN**
```
Find out what fills your Mac in seconds: an interactive sunburst of every folder, system data and free space at a glance, and snapshots that show what grew.
```

**DE**
```
Finde in Sekunden heraus, was deinen Mac füllt: ein interaktives Ringdiagramm aller Ordner, Systemdaten und freier Platz auf einen Blick, dazu Snapshots mit Vergleich.
```

### Schlüsselwörter (100 Bytes, durch Kommas getrennt, keine Namen anderer Apps)

**EN**
```
disk,space,storage,analyzer,ai,sunburst,cleanup,folder,size,free,purgeable,system data,snapshot
```

**DE**
```
festplatte,speicherplatz,analyse,belegung,ordner,größe,aufräumen,sunburst,systemdaten,frei,ki
```

### Beschreibung (4000)

**EN**
```
DiskRings shows you where your disk space goes.

Choose a volume or folder and DiskRings draws its contents as an interactive sunburst: every ring is one folder level, every segment is as wide as its share of the space. Click a folder to zoom in, swipe back, and clean up right from the chart.

THE WHOLE DISK AT A GLANCE
• Your folders, System Data (other volumes such as Preboot, VM and Recovery, each named), Purgeable space and Free space in one picture
• A stacked bar for every volume on the start screen and in the status bar
• Accurate sizes: space actually allocated on disk, hard links counted once, iCloud files without downloading them

WHERE DID MY SPACE GO?
• Save a snapshot of a scan
• Scan again later and see exactly what grew, what shrank, what is new and what was removed
• Growth view and delta coloring with the largest changes listed

SAFE CLEANUP
• Show in Finder, Open, Quick Look, Copy Path and Rescan This Folder from the chart, the list or the menu bar
• Move to Trash asks first and can be undone with ⌘Z; nothing is ever deleted permanently
• System locations are protected

MADE FOR THE MAC
• Native SwiftUI app for Apple Silicon and Intel
• Fast parallel scanning of millions of files
• Full keyboard navigation and VoiceOver support, color-blind friendly comparison colors
• Light and dark mode, 14 languages

ASK AN AI ASSISTANT
• Not sure what a folder is? Right-click it and choose Analyze with AI
• DiskRings prepares a prompt with the path, sizes, largest items and file types and opens the AI assistant of your choice in your browser, or copies the prompt for you to paste anywhere
• Your user name and computer name are replaced by placeholders; nothing is sent before you click

PRIVATE BY DESIGN
DiskRings makes no network connections and collects no data. It only reads the folders and volumes you choose, and remembers your choice.

DiskRings is open source (MIT license): github.com/brokoskokoli/diskrings
```

**DE**
```
DiskRings zeigt dir, wo dein Speicherplatz bleibt.

Wähle ein Volume oder einen Ordner, und DiskRings zeichnet den Inhalt als interaktives Ringdiagramm: Jeder Ring ist eine Ordnerebene, jedes Segment ist so breit wie sein Anteil am Speicher. Klick in einen Ordner, um hineinzuzoomen, wisch zurück und räum direkt im Diagramm auf.

DIE GANZE PLATTE AUF EINEN BLICK
• Deine Ordner, Systemdaten (weitere Volumes wie Preboot, VM und Recovery, jeweils benannt), löschbarer und freier Speicher in einem Bild
• Ein gestapelter Balken für jedes Volume auf dem Startbildschirm und in der Statusleiste
• Genaue Größen: tatsächlich belegter Platz, Hardlinks nur einmal gezählt, iCloud-Dateien ohne Herunterladen

WO IST MEIN SPEICHER HIN?
• Speichere einen Snapshot eines Scans
• Scanne später erneut und sieh genau, was gewachsen, geschrumpft, neu oder verschwunden ist
• Wachstumsansicht und Delta-Färbung mit Liste der größten Veränderungen

SICHER AUFRÄUMEN
• Im Finder zeigen, Öffnen, Quick Look, Pfad kopieren und Ordner neu scannen – im Diagramm, in der Liste und in der Menüleiste
• „In den Papierkorb“ fragt vorher nach und lässt sich mit ⌘Z rückgängig machen; endgültig gelöscht wird nie etwas
• Systembereiche sind geschützt

FÜR DEN MAC GEMACHT
• Native SwiftUI-App für Apple Silicon und Intel
• Schneller paralleler Scan von Millionen Dateien
• Vollständig per Tastatur und mit VoiceOver bedienbar, farbenblind-taugliche Vergleichsfarben
• Hell- und Dunkelmodus, 14 Sprachen

EINEN KI-ASSISTENTEN FRAGEN
• Unklar, was ein Ordner ist? Rechtsklick und „Mit KI analysieren“
• DiskRings stellt einen Prompt mit Pfad, Größen, größten Elementen und Dateitypen zusammen und öffnet den KI-Assistenten deiner Wahl im Browser oder kopiert den Prompt zum Einfügen
• Benutzername und Rechnername werden durch Platzhalter ersetzt; vor deinem Klick wird nichts übertragen

DATENSCHUTZ VON ANFANG AN
DiskRings baut keine Netzwerkverbindungen auf und erfasst keine Daten. Die App liest nur die Ordner und Volumes, die du auswählst, und merkt sich deine Auswahl.

DiskRings ist Open Source (MIT-Lizenz): github.com/brokoskokoli/diskrings
```

### Informationen für die App-Prüfung

| Feld | Eintrag |
|---|---|
| Anmeldung erforderlich | aus |
| Kontakt | eigener Name, Telefon, E-Mail (sieht nur Apple) |

Notizen (zugleich Antwort auf Apples Rückfrage vom 11.10.2026 an neue Entwicklerkonten; in App Store Connect unter „App-Prüfung → Antworten“ und im Feld „Notizen“ eintragen, < 4000 Zeichen):
```
1. Screen recording
Attached: recorded on a MacBook running the latest macOS. It starts with launching DiskRings from the Applications folder and shows the typical flow: choose a volume, grant folder access, scan, explore the sunburst, move a file to the Trash and undo, save a snapshot and compare. The app has no accounts, no user-generated content and no paid content.

2. Purpose and target audience
DiskRings is a disk space analyzer for Mac users who run low on storage and want to know what fills their disk. It scans a volume or folder the user selects and shows the result as an interactive sunburst chart: each ring is one folder level, each segment is as wide as its share of the space. It also breaks the volume down into System Data (other APFS volumes such as Preboot or VM), Purgeable and Free space. Snapshots let users compare two scans to see what grew. Value: users find large and growing folders in seconds and can clean up safely (Move to Trash only, with confirmation and Undo).

3. How to use the main features
No login, no account, no sample files needed.
- Launch DiskRings. The start screen lists all volumes.
- Click "Macintosh HD". Because the app is sandboxed, an Open dialog asks for access; click "Grant Access". The scan starts (a few seconds to a minute). Alternatively use "Scan Home Folder", File > Choose Folder... or drag a folder onto the window.
- Click a segment to zoom in, use Go > Back to return. Right-click a segment or list row for Show in Finder, Quick Look, Copy Path, Rescan This Folder and Move to Trash.
- Move to Trash asks for confirmation and can be undone with Edit > Undo (Cmd+Z). Nothing is ever deleted permanently; system locations are protected.
- File > Save Snapshot..., later rescan and choose Snapshots... to compare two scans.
- Settings > Folder Access lists granted folders and lets the user remove access.
- Right-click a segment > Analyze with AI: after a one-time explanation, opens the user's default browser with a prompt about the item for an AI assistant chosen in Settings > AI (or copies the prompt to the clipboard). The app itself sends nothing.
Optional: without Full Disk Access some protected folders (e.g. ~/Library/Mail) are unreadable and shown as "Unreadable System Data"; the app explains this on the start screen.

4. External services
None. DiskRings makes no network connections (no network entitlement), uses no third-party SDKs, analytics, authentication, payment or AI services. It only uses macOS system APIs to read file metadata. Snapshots and settings are stored locally in the app container. The optional "Analyze with AI" menu only opens a web link in the user's default browser (NSWorkspace) or copies text to the clipboard, on explicit click; the app does not call any AI API itself.

5. Regional differences
None. The app works identically in all regions; it is localized into 14 languages.

6. Regulated industry / third-party material
Not applicable. DiskRings is not in a regulated industry and contains no protected third-party material. It is open source under the MIT license: https://github.com/brokoskokoli/diskrings
```
## Exportkontrolle

Entfällt beim Upload: Der Store-Build setzt `ITSAppUsesNonExemptEncryption = false`.
