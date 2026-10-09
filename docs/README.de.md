<p align="center"><img src="images/icon.png" width="128" height="128" alt="DiskRings-Icon"></p>

<h1 align="center">DiskRings</h1>

<p align="center"><b>Kostenloser Open-Source-Festplatten-Analysator für macOS mit interaktivem Sunburst-Diagramm.</b><br>
Auf einen Blick sehen, was den Mac füllt, Scans über die Zeit vergleichen und sicher Platz schaffen.</p>

<p align="center">
  <a href="https://github.com/brokoskokoli/diskrings/releases/latest"><b>Download</b></a> ·
  <a href="https://brokoskokoli.github.io/diskrings/">Website</a> ·
  <a href="#häufige-fragen">Häufige Fragen</a> ·
  <a href="../README.md">English</a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/hero-dark.png">
  <img src="images/hero-light.png" alt="DiskRings mit Sunburst-Diagramm und Ordnerliste (Beispieldaten)">
</picture>

DiskRings scannt ein Volume oder einen Ordner und zeigt die Belegung als Sunburst-Diagramm: Jeder Ring ist eine Ordnerebene, jedes Segment so breit wie sein Anteil am Speicher. Ein Klick zoomt in den Ordner, eine Wischgeste geht zurück, und aufgeräumt wird direkt im Diagramm. DiskRings ist eine native SwiftUI-App für Apple Silicon und Intel, vergleichbar mit WinDirStat, TreeSize, SpaceSniffer oder Scanner unter Windows.

> **Sprachen:** Englisch, Deutsch, Französisch, Spanisch, Italienisch, Portugiesisch (Brasilien), Niederländisch, Polnisch, Russisch, Japanisch, Chinesisch (vereinfacht), Koreanisch, Türkisch und Schwedisch. DiskRings folgt automatisch der Systemsprache; die Sprache lässt sich auch in den Einstellungen wählen oder pro App unter Systemeinstellungen → Allgemein → Sprache & Region → Apps. Übersetzungen verbessern: siehe [Übersetzungen](#übersetzungen).

## Funktionen

- **Schneller, genauer Scan** ganzer Volumes oder einzelner Ordner, parallel über `getattrlistbulk`. Gezählt wird der tatsächlich belegte Platz: Hardlinks nur einmal, Sparse- und komprimierte Dateien mit ihrer echten Belegung, Firmlinks des Data-Volumes ohne Doppelzählung, iCloud-Dateien ohne Download.
- **Interaktives Sunburst-Diagramm** mit Drill-down per Klick, animiertem Zoom, Zurück/Vor (auch per Wischgeste) und Breadcrumb. Kleine Elemente landen in einem Sammelsegment.
- **Detailliste** neben dem Diagramm mit Prozentbalken, Mehrfachauswahl und Suche, synchron mit dem Diagramm.
- **„Nicht zugeordnet“ sichtbar:** An der Volume-Wurzel zeigt ein schraffiertes Segment, was kein Ordner erklärt: lokale APFS- und Time-Machine-Snapshots, bereinigbarer Speicher, Systemdaten und nicht lesbare Ordner.
- **Snapshots und Vergleich („Wo ist mein Speicher hin?“):** einen Scan sichern, später neu scannen und genau sehen, was gewachsen, geschrumpft, neu oder entfernt ist.
- **Sicher aufräumen:** Kontextmenü mit Im Finder zeigen, Öffnen, Übersicht (Quick Look), Pfad kopieren, Ordner neu scannen und In den Papierkorb legen. Gelöscht wird nur über den Papierkorb, mit Rückfrage und Widerrufen per ⌘Z. Systembereiche sind geschützt.
- **Färbung** nach Ast oder nach Dateityp, hell und dunkel.
- **Kommandozeilen-Werkzeug** `diskrings-cli` für Scan, Top-Ordner, Snapshots und Vergleich.
- **Datenschutz:** keine Netzwerkzugriffe, keine Telemetrie, kein Konto.
- **Lokalisiert** in 14 Sprachen, Größen, Zahlen und Datum im Format der Region.

### Sunburst-Diagramm

<img src="images/sunburst.png" alt="Sunburst-Diagramm von /usr/share mit Ordnerliste" width="900">

### Vergleich: Wachstum

Im Wachstumsmodus ist die Segmentgröße der Zuwachs seit dem Snapshot; die Liste zeigt die größten Veränderungen.

<img src="images/compare-growth.png" alt="Wachstumsansicht: Vergleich eines Snapshots mit dem aktuellen Scan" width="900">

### Vergleich: Delta-Färbung

Die Delta-Färbung behält das normale Layout und färbt Wachstum rot, Rückgang grün. Neue Elemente tragen einen Punkt, entfernte erscheinen gestrichelt.

<img src="images/compare-delta.png" alt="Delta-Färbung im Dunkelmodus" width="900">

### Kontextmenü

<img src="images/context-menu.png" alt="Kontextmenüs für Datei, geschützten Ordner und Mehrfachauswahl" width="900">

### Startbildschirm

<img src="images/start.png" alt="Startbildschirm mit Volume-Liste" width="700">

## Warum DiskRings?

| | DiskRings | DaisyDisk | GrandPerspective | OmniDiskSweeper |
|---|---|---|---|---|
| Darstellung | Sunburst + Liste | Sunburst | Treemap | Sortierte Liste |
| Scans über die Zeit vergleichen | Ja (Snapshots) | Nein | Nein | Nein |
| Nicht zugeordneter Platz (Snapshots, bereinigbar) | Ja | Ja (als „hidden space“) | Nein | Nein |
| Löschen | Nur Papierkorb, mit Undo | Ja | Ja | Ja |
| Preis | Kostenlos, Open Source (MIT) | Kostenpflichtig | Kostenlos, Open Source | Kostenlos |

- **Snapshot-Vergleich:** „Wo ist seit letzter Woche mein Speicher hin?“ beantworten, statt die ganze Platte neu zu durchsuchen.
- **Ehrliche Summen:** Scan-Summe plus „Nicht zugeordnet“ ergibt die Belegung laut Volume.
- **Sicher:** Kein endgültiges Löschen, alles geht in den Papierkorb, mit Bestätigung und ⌘Z.
- **Schnell:** Auf einem M3 Pro dauert der Scan eines Home-Ordners mit 2,9 Mio. Dateien und Ordnern rund 10 s (`du -sk`: 65 s). Der Vergleich zweier Snapshots mit je 2 Mio. Einträgen dauert etwa 0,3 s. Details in [PERFORMANCE.md](PERFORMANCE.md).
- **Kostenlos und Open Source**, ohne In-App-Käufe, Werbung oder Datensammlung.

## Installation

1. Die aktuelle Version unter [Releases](https://github.com/brokoskokoli/diskrings/releases/latest) als **DMG** laden.
2. DMG öffnen und **DiskRings** in den Ordner **Programme** ziehen.
3. Starten. Die App ist mit Developer ID signiert und von Apple notarisiert.

Voraussetzung: macOS 14 (Sonoma) oder neuer, Apple Silicon oder Intel. Homebrew ist geplant.

### Festplattenvollzugriff einrichten

Ohne Festplattenvollzugriff funktioniert DiskRings, kann aber Ordner wie `~/Library/Mail`, `~/Library/Messages`, Safari-Daten und die Container anderer Apps nicht lesen. Sie erscheinen als „nicht lesbar“, ihr Platz landet unter „Nicht zugeordnet“.

1. **Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff** öffnen (oder in DiskRings auf „Systemeinstellungen öffnen …“ klicken).
2. Mit **+** die App `DiskRings` aus dem Ordner Programme hinzufügen und den Schalter einschalten.
3. DiskRings neu starten (oder im Startbildschirm „Erneut prüfen“).

### Bauen aus dem Quellcode

Ein Swift Package ohne Xcode-Projekt. Es genügen die **Command Line Tools** (`xcode-select --install`) mit Swift 6; Xcode ist optional.

```sh
scripts/check.sh                       # Build, alle Tests, Performance-Tests im Release-Build
scripts/make-app.sh                    # build/DiskRings.app (Release, universal, signiert)
DISKRINGS_ADHOC=1 scripts/make-app.sh  # ohne Developer ID: ad-hoc-Signatur
open build/DiskRings.app
```

`make-app.sh` signiert mit der Developer ID aus dem Schlüsselbund, wenn sie vorhanden ist, sonst ad hoc. Hängt codesign länger als 60 s (unsichtbarer Schlüsselbund-Dialog), bricht das Skript mit einem Hinweis ab.

Kommandozeile und Vorschaubilder:

```sh
swift run -c release diskrings-cli scan ~ --top 10 --depth 2
swift run -c release diskrings-cli volumes
swift run DiskRings --render-snapshots build/snapshots --scan /usr/share   # PNGs, hell/dunkel
swift run DiskRings --render-snapshots build/snapshots --compare-demo      # Vergleichsansichten
swift scripts/make-icon.swift            # App-Icon (Resources/DiskRings.icns)
swift scripts/make-social-preview.swift  # docs/images/social-preview.png
```

### Release-Ablauf

Signieren und Notarisieren laufen lokal, nicht in der CI. Die CI (GitHub Actions) baut nur und führt die Tests aus. Einmalig das Notarisierungs-Profil anlegen (mit einem app-spezifischen Passwort der Apple-ID):

```sh
xcrun notarytool store-credentials diskrings --apple-id <apple-id> --team-id AGRWTKQZ8C
```

1. `VERSION` erhöhen und committen.
2. `scripts/release.sh`: führt `check.sh` und `make-app.sh` aus, notarisiert App und DMG, heftet die Tickets an, erzeugt `dist/DiskRings-<version>.zip`, `.dmg` und `SHA256SUMS` und prüft mit `spctl`.
3. `scripts/release.sh --publish` legt zusätzlich das GitHub-Release `v<version>` an (sauberes Arbeitsverzeichnis, Tag noch nicht vorhanden).

## Häufige Fragen

**Warum zeigt DiskRings eine andere Größe als der Finder?** Der Finder zeigt meist die logische Dateigröße, DiskRings den tatsächlich belegten Platz wie `du`. Unterschiede entstehen bei komprimierten und Sparse-Dateien, vielen kleinen Dateien (Blockgröße) und Hardlinks, die DiskRings nur einmal zählt. APFS-Klone teilen sich Blöcke; das ist über keine öffentliche API erkennbar, daher kann die Summe dort über der echten Belegung liegen.

**Was bedeutet „Nicht zugeordnet“?** Die Differenz zwischen der Belegung laut Volume und der Summe aller gefundenen Dateien: lokale Time-Machine- und APFS-Snapshots, bereinigbarer Speicher, Systemdaten und nicht lesbare Ordner. Das Segment erscheint nur beim Scan eines ganzen Volumes.

**Ist Löschen sicher?** Es gibt kein endgültiges Löschen. „In den Papierkorb legen“ fragt mit Name, Größe und Dateianzahl nach und lässt sich mit ⌘Z widerrufen. Volume-Wurzel, das Home-Verzeichnis und `~/Library` als Ganzes, Systembereiche wie `/System` und `/usr` sowie die App selbst sind geschützt.

## Datenschutz

Keine Netzwerkverbindungen, keine Telemetrie, keine Analyse- oder Absturzberichte. Scans und Snapshots bleiben auf dem Mac (`~/Library/Application Support/DiskRings`).

## Mitmachen

Issues und Pull Requests sind willkommen. Vor dem Einreichen muss `scripts/check.sh` ohne Warnungen durchlaufen. Weitere Dokumente: [SPEC.md](../SPEC.md) (Spezifikation), [DECISIONS.md](DECISIONS.md) (Entscheidungen), [PERFORMANCE.md](PERFORMANCE.md) (Messwerte).

## Übersetzungen

Die Übersetzungen sind maschinell erstellt und auf Apples macOS-Begriffe geprüft, aber noch nicht von Muttersprachlern aller Sprachen durchgesehen. Verbesserungen sind willkommen.

- Alle Texte liegen in `Sources/DiskRingsCore/Resources/<sprache>.lproj/`: `Localizable.strings` (Oberfläche), `Localizable.stringsdict` (Pluralformen) und `InfoPlist.strings` (Datenschutz-Texte von macOS). Quelle ist Englisch (`en.lproj`).
- **Sprache verbessern:** Werte im jeweiligen Ordner ändern und einen Pull Request öffnen. Schlüssel und Platzhalter (`%@`, `%1$@`, …) bleiben gleich; positionierte Platzhalter dürfen umgestellt werden.
- **Sprache hinzufügen:** `en.lproj` nach `<code>.lproj` kopieren, übersetzen, die Pluralkategorien der Sprache in der `.stringsdict` angeben und den Code samt Eigennamen in `L10n.supportedLanguages` und `L10n.nativeName(of:)` eintragen.
- `scripts/check.sh` prüft fehlende oder zusätzliche Schlüssel, Platzhalter und Pluralformen.
- Vorschaubilder in einer Sprache: `swift run DiskRings --render-snapshots build/snapshots/fr --language fr`.

## Lizenz

[MIT-Lizenz](../LICENSE). Copyright © 2026 Stefan Richter.
