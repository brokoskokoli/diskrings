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

„Daten werden nicht erfasst“ (Data Not Collected). DiskRings stellt keine Netzwerkverbindungen her.

## Preise und Verfügbarkeit

Gratis, alle Länder und Regionen.

## Versionsseite (macOS App → Version)

| Feld | Eintrag |
|---|---|
| Version | `0.2.0` (muss zur Datei `VERSION` des hochgeladenen Builds passen) |
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
disk,space,storage,analyzer,usage,sunburst,cleanup,folder,size,free,purgeable,system data,snapshot
```

**DE**
```
festplatte,speicherplatz,analyse,belegung,ordner,größe,aufräumen,sunburst,systemdaten,frei,volume
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

DATENSCHUTZ VON ANFANG AN
DiskRings baut keine Netzwerkverbindungen auf und erfasst keine Daten. Die App liest nur die Ordner und Volumes, die du auswählst, und merkt sich deine Auswahl.

DiskRings ist Open Source (MIT-Lizenz): github.com/brokoskokoli/diskrings
```

### Informationen für die App-Prüfung

| Feld | Eintrag |
|---|---|
| Anmeldung erforderlich | aus |
| Kontakt | eigener Name, Telefon, E-Mail (sieht nur Apple) |

Notizen:
```
DiskRings visualizes disk usage as a sunburst chart. In this sandboxed App Store version it only reads folders and volumes the user explicitly selects in the Open dialog (stored as app-scoped security-scoped bookmarks; manageable in Settings → Folder Access). To test: click "Macintosh HD" on the start screen, click "Grant Access" in the Open dialog, and the scan starts.

"Move to Trash" uses FileManager.trashItem, only within user-selected folders. It never deletes permanently, asks for confirmation, and can be undone with Cmd+Z. System locations are protected.

The app makes no network connections and collects no data. Snapshots are stored locally in the app container.
```

## Exportkontrolle

Entfällt beim Upload: Der Store-Build setzt `ITSAppUsesNonExemptEncryption = false`.
