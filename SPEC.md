# DiskRings – Spezifikation

Ein nativer macOS-Festplatten-Analysator nach dem Vorbild von *Scanner* (Windows): Er durchsucht ein Volume oder einen Ordner, zeigt die Belegung als Sunburst-Diagramm (konzentrische Ringe, die nach außen immer feiner werden) und lässt große Dateien und Ordner direkt per Rechtsklick im Finder anzeigen oder in den Papierkorb legen. Außerdem lassen sich Scan-Snapshots speichern und später vergleichen: „Was ist seit letzter Woche gewachsen?“

---

## 1. Ziele und Nicht-Ziele

**Ziele**
- In wenigen Sekunden sehen, wo der Platz hingeht: Volume-Übersicht, dann Drill-down bis zur einzelnen Datei.
- Schnell scannen: eine typische SSD mit 1–2 Mio. Dateien in unter 60 s, und das Diagramm baut sich schon während des Scans auf.
- Echte Plattenbelegung zeigen (allokierte Größe), nicht nur die logische Dateigröße.
- Sicher löschen: nur in den Papierkorb, mit Bestätigung, und Systembereiche sind geschützt.

**Nicht-Ziele (v1)**
- Duplikatsuche, Bereinigungs-Assistent, Cache-Reiniger.
- Netzlaufwerke optimieren (sie funktionieren, aber langsam).
- Mac App Store (siehe Abschnitt 9: die Sandbox würde den Vollscan stark einschränken).

---

## 2. Plattform und Technik

| Thema | Entscheidung | Begründung |
|---|---|---|
| Sprache/UI | Swift 6, SwiftUI, AppKit wo nötig (Kontextmenü, Drag, Trash) | nativ, schnell, kein Electron-Overhead |
| Mindest-OS | macOS 14 Sonoma | `Canvas`, `@Observable`, moderne Concurrency |
| Build | Swift Package (`executableTarget`) und `scripts/make-app.sh`, das ein `.app`-Bundle baut, mit Developer ID signiert und per `notarytool` notarisiert | funktioniert ohne Xcode; alle nötigen Werkzeuge (`swift`, `codesign`, `notarytool`, `iconutil`) sind in den Command Line Tools enthalten |
| Diagramm | eigenes Rendering in SwiftUI `Canvas` (keine Chart-Library) | Swift Charts kann keinen mehrstufigen Sunburst; beim Hover und bei Animationen ist volle Kontrolle nötig |
| Scan | POSIX `fts_open`/`fts_read` oder `getattrlistbulk`, parallelisiert über Unterverzeichnisse | `FileManager.enumerator` ist bei Millionen Dateien 3–5× langsamer |

---

## 3. Funktionsumfang

### 3.1 Startbildschirm
- Liste der eingehängten Volumes (Name, Icon, Gesamt/Belegt/Frei als Balken).
- Daten über `URLResourceValues`: `volumeTotalCapacity`, `volumeAvailableCapacityForImportantUsage` (enthält den bereinigbaren Speicher) und `volumeAvailableCapacity` (wirklich frei).
- Button „Ordner wählen…“ (NSOpenPanel), außerdem Drag & Drop eines Ordners aufs Fenster.
- Hinweis-Banner, wenn kein Festplattenvollzugriff erteilt ist, mit Button, der die Systemeinstellung öffnet:
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

### 3.2 Scan
- Fortschrittsanzeige: Anzahl Dateien, gescannte Bytes, aktueller Pfad, abgelaufene Zeit; Abbrechen-Button.
- Das Sunburst-Diagramm aktualisiert sich während des Scans alle ~250 ms mit den bisher gesammelten Daten.
- Am Ende eine Zusammenfassung: Anzahl Dateien/Ordner, nicht lesbare Ordner (Liste aufklappbar), Dauer.

### 3.3 Hauptansicht (Layout)

```
┌──────────────────────────────────────────────────────────────────┐
│ ◀ ▶  Macintosh HD › Users › stefan › Library        [Rescan] [⌕] │  Toolbar + Breadcrumb
├───────────────────────────────────────────┬──────────────────────┤
│                                           │ Library              │
│              ╭───────────╮                │ 182,4 GB · 41 %      │
│          ╭───┤  Sunburst ├───╮            │ 312 841 Dateien      │
│          │   │  (Mitte = │   │            │──────────────────────│
│          │   │  aktueller│   │            │ ▸ Containers  61 GB  │
│          ╰───┤   Ordner) ├───╯            │ ▸ Caches      38 GB  │
│              ╰───────────╯                │ ▸ Developer   29 GB  │
│                                           │   …                  │
├───────────────────────────────────────────┴──────────────────────┤
│ Volume: 994 GB · belegt 812 GB · frei 182 GB (davon 14 GB bereinigbar) │
└──────────────────────────────────────────────────────────────────┘
```

- **Links:** Sunburst. **Rechts:** Detailliste (Outline) des aktuell fokussierten Ordners, nach Größe sortiert, mit Prozentbalken. Diagramm und Liste sind synchronisiert (Hover und Auswahl wirken in beiden).
- **Unten:** Statusleiste mit der Volume-Belegung.
- **Optionaler Tab „Größte Dateien“:** Top 100 Dateien im gesamten Scan, filterbar nach Typ.

### 3.4 Sunburst-Diagramm
- **Mitte:** der aktuell fokussierte Ordner (Name und Gesamtgröße). Klick auf die Mitte geht eine Ebene nach oben.
- **Ringe:** Ring *n* zeigt die Kinder der Ebene *n*. Der Winkel jedes Segments entspricht seinem Anteil am Elternordner. Standard sind 6 Ringe, einstellbar von 3 bis 10.
- **Ringbreite:** Die inneren Ringe sind etwas breiter, die äußeren schmaler, damit die tiefen Ebenen nicht dominieren.
- **Kleine Segmente:** Elemente unter 0,5° werden pro Elternordner zu einem grauen Sammelsegment „N kleinere Elemente“ zusammengefasst. Das hält das Rendern schnell und das Bild lesbar.
- **Farbe:**
  - Standard: Jeder Top-Level-Ast bekommt einen Farbton, und nach außen wird er heller beziehungsweise weniger gesättigt (wie bei Scanner).
  - Alternativ: nach Dateityp färben (Video, Bilder, Audio, Archive, Apps, Code, Dokumente, Sonstiges), mit Legende.
  - Dateien werden etwas gedämpfter dargestellt als Ordner, damit man sie unterscheiden kann.
- **Interaktion:**
  - Hover: Das Segment wird hervorgehoben, der Tooltip zeigt Pfad, Größe, Anteil und Anzahl der Elemente, und die Breadcrumb zeigt den Hover-Pfad.
  - Klick auf einen Ordner zoomt hinein: Der Ordner wird zur neuen Mitte, mit einer animierten Übergangsanimation von ca. 300 ms.
  - Klick auf eine Datei wählt sie aus und scrollt die Liste dorthin.
  - Doppelklick auf eine Datei öffnet die Quick-Look-Vorschau.
  - Zurück/Vor: Toolbar, ⌘[ / ⌘], und Wischgesten auf dem Trackpad.
  - Rechtsklick öffnet das Kontextmenü (siehe 3.5).
- **Beschriftung:** Namen nur in Segmenten, die groß genug sind (Bogenlänge über Textbreite); der Text folgt tangential bzw. radial der Segmentrichtung.

### 3.5 Kontextmenü (Diagramm und Liste gleich)
| Eintrag | Umsetzung |
|---|---|
| Im Finder zeigen (⌘R) | `NSWorkspace.shared.activateFileViewerSelecting([url])` |
| Öffnen | `NSWorkspace.shared.open(url)` |
| Quick Look (Leertaste) | `QLPreviewPanel` |
| Hier hineinzoomen | Fokus auf diesen Ordner setzen |
| Pfad kopieren (⌥⌘C) | `NSPasteboard` |
| Informationen (⌘I) | Finder-Info-Fenster per AppleScript/`NSAppleScript` oder eigenes Info-Popover |
| Diesen Ordner neu scannen | siehe 3.8 |
| In den Papierkorb legen (⌘⌫) | siehe 3.6 |

### 3.6 Löschen
- Gelöscht wird ausschließlich über `FileManager.trashItem(at:resultingItemURL:)`. Es gibt kein endgültiges Löschen.
- Vorher erscheint ein Bestätigungsdialog mit Name, Größe und Anzahl der enthaltenen Dateien. „Nicht mehr fragen“ gilt nur für Elemente unter 1 GB.
- Mehrfachauswahl in der Liste ist möglich; der Dialog zeigt dann die Gesamtsumme.
- Nach dem Löschen wird der Knoten aus dem Baum entfernt, die Größen der Elternordner werden neu berechnet und das Diagramm animiert die Änderung. Ein erneuter Scan ist nicht nötig.
- **Schutzliste:** Löschen ist deaktiviert (Menüeintrag ausgegraut, mit Begründung im Tooltip) für:
  - `/System`, `/usr` (außer `/usr/local`), `/bin`, `/sbin`, `/private/var/db`, `/Library/Apple`
  - das Volume-Root, das eigene Home-Verzeichnis als Ganzes, `~/Library` als Ganzes
  - die laufende App selbst
- Undo (⌘Z) über den von `trashItem` gelieferten `resultingItemURL`: Das Element wird zurückverschoben und der Baum aktualisiert.

### 3.7 Einstellungen
- Ringanzahl, Farbschema (Ast/Dateityp), Schwelle für das Sammelsegment.
- Größenmodus: **belegt auf Platte** (Standard) oder **logische Größe**.
- Versteckte Dateien zählen: ja/nein (Standard: ja, denn genau dort steckt oft der Platz).
- Ausschlussliste von Pfaden.
- Andere Volumes beim Scan überqueren: nein (Standard).
- Snapshots: automatisch nach jedem vollständigen Scan speichern (Standard: ja), maximale Anzahl pro Scan-Wurzel (Standard: 20, die ältesten werden gelöscht).

### 3.8 Teilbereich neu scannen
- Erreichbar per Rechtsklick → „Diesen Ordner neu scannen“ (⌘⇧R) in Diagramm und Liste sowie über den Rescan-Button in der Toolbar für den aktuell fokussierten Ordner.
- Nur dieser Teilbaum wird neu eingelesen; der Rest des Baums bleibt unverändert. Während des Teilscans zeigt das Segment einen Fortschrittsring, und die App bleibt bedienbar.
- Danach wird der alte Teilbaum durch den neuen ersetzt, und die Größendifferenz wird bis zur Wurzel propagiert. Das Diagramm animiert die Änderung.
- Ein kurzer Hinweis zeigt das Ergebnis: „Library: 182,4 GB → 176,1 GB (−6,3 GB)“.
- Technisch hängt der neue Teilbaum als frische Knoten am Ende des `nodes`-Arrays; die alten Knoten werden als tot markiert. Eine Kompaktierung läuft im Hintergrund, sobald mehr als 25 % der Knoten tot sind.

### 3.9 Snapshots und Vergleich („Wo ist mein Speicher hin?“)
**Snapshot speichern**
- Nach jedem vollständigen Scan (automatisch, abschaltbar) oder manuell per Menü „Ablage → Snapshot sichern“ (⌘S), mit optionalem Namen („vor Xcode-Update“).
- Gespeichert wird ein kompaktes Abbild des Baums: Pfadstruktur, allokierte Größe und Dateianzahl pro Knoten, dazu Zeitpunkt, Scan-Wurzel, Volume-UUID und die Volume-Kennzahlen (belegt, frei, nicht zugeordnet).
- Um Platz zu sparen, werden standardmäßig nur **Ordner und Dateien ab 1 MB** gespeichert; kleinere Dateien fließen nur in die Ordnersumme ein. Ein Snapshot von 2 Mio. Dateien wird so etwa 5–15 MB groß.
- Format: eigenes Binärformat (Knoten-Array wie in 4.2 plus Namenspuffer), mit LZFSE komprimiert (`Compression`-Framework). Ablage unter `~/Library/Application Support/DiskRings/Snapshots/<volume-uuid>/<zeitstempel>.drsnap`.
- Verwaltung im Fenster „Snapshots“: Liste mit Datum, Name, Scan-Wurzel und Gesamtgröße; umbenennen, löschen, im Finder zeigen.

**Vergleichen**
- Nach einem Scan: Toolbar-Button „Vergleichen mit…“ und ein Popup mit den passenden Snapshots (gleiche Volume-UUID und Scan-Wurzel). Vorausgewählt ist der jüngste.
- Zwei gespeicherte Snapshots lassen sich auch ohne neuen Scan miteinander vergleichen.
- Der Abgleich geschieht über den Pfad: Beide Bäume werden parallel ab der Wurzel durchlaufen und Kinder per Name zugeordnet (Sortierung nach Name, dann Merge). Das ist O(n) und braucht für 2 Mio. Knoten unter 2 Sekunden.
- Ergebnis pro Knoten: `alt`, `neu`, `delta = neu − alt` und ein Status: *neu*, *entfernt*, *gewachsen*, *geschrumpft* oder *unverändert*.

**Darstellung im Vergleichsmodus**
- Kopfzeile: „Seit 02.10., 09:14: belegt +38,2 GB · frei −38,2 GB · davon nicht zugeordnet +4,1 GB“.
- **Sunburst-Variante „Wachstum“:** Die Segmentgröße entspricht dem *Zuwachs* (nur positive Deltas), sodass das Diagramm direkt zeigt, wohin der neue Speicher gegangen ist. Drill-down funktioniert wie gewohnt.
- Umschaltbar auf die normale Ansicht mit **Delta-Färbung**: Rot bedeutet gewachsen, Grün geschrumpft, die Intensität richtet sich nach der Größe des Deltas, neue Elemente erhalten eine Markierung und entfernte Elemente erscheinen grau gestrichelt.
- Die Detailliste bekommt zusätzliche Spalten (*Vorher*, *Jetzt*, *Δ*) und lässt sich nach Δ sortieren.
- Tab „Größte Veränderungen“: eine flache Top-50-Liste der Ordner und Dateien mit dem größten absoluten Zuwachs, wobei nur der tiefste aussagekräftige Ordner auftaucht. Wenn `~/Library/Caches/foo` um 20 GB wächst, steht dort `foo` und nicht zusätzlich `Library` und `Caches`.
- Das Kontextmenü funktioniert auch im Vergleichsmodus, sodass man gewachsene Dateien direkt in den Papierkorb legen kann.

**Grenzen**
- Umbenannte oder verschobene Ordner erscheinen als *entfernt* plus *neu*. Eine Erkennung über die Inode-Nummer ist für Phase 2 vorgesehen.
- Wurde der Snapshot mit einer anderen Einstellung erstellt (z. B. ohne versteckte Dateien), zeigt die App eine Warnung.

---

## 4. Scan-Engine (Kern)

### 4.1 Was „Größe“ bedeutet – die macOS-Fallstricke
1. **Allokierte Größe statt logischer Größe:** Gezählt wird `st_blocks * 512` beziehungsweise `totalFileAllocatedSize`. Sparse-Dateien und Dateien mit APFS-Kompression sind sonst völlig falsch.
2. **Hardlinks:** Bei `st_nlink > 1` wird `(st_dev, st_ino)` in einem Set gemerkt und die Datei nur beim ersten Auftreten gezählt. Das betrifft vor allem Time-Machine-Restbestände und Xcode.
3. **APFS-Klone:** Geklonte Dateien teilen sich Blöcke, das ist über die öffentliche API aber nicht erkennbar. Die Summe kann deshalb über der tatsächlichen Belegung liegen. Das ist ein bekannte Grenze, die in der Statusleiste erklärt wird („Klone/Snapshots können Abweichungen verursachen“).
4. **Snapshots und bereinigbarer Speicher:** Lokale Time-Machine-Snapshots belegen Platz, der in keinem Ordner auftaucht. Die Differenz *Volume belegt − Scan-Summe* wird deshalb als eigenes Segment **„Nicht zugeordnet (System, Snapshots, Purgeable)“** im äußersten Bereich der Wurzel gezeigt. Genau das macht Scanner unter Windows auch, und es ist der wichtigste Aha-Effekt.
5. **Firmlinks / Data-Volume:** `/` (System, schreibgeschützt) und `/System/Volumes/Data` sind auf APFS zwei Volumes, die über Firmlinks verbunden sind. Beim Scan von „Macintosh HD“ wird `/` gescannt. Mount-Grenzen werden über `st_dev` erkannt; `/System/Volumes/Data` wird **nicht** doppelt gescannt, wohl aber die Firmlink-Ziele wie `/Users` und `/Applications`, die unter `/` erscheinen.
6. **Symlinks** werden nicht verfolgt (`FTS_PHYSICAL`); sie zählen mit ihrer eigenen, winzigen Größe.
7. **Pakete** (`.app`, `.photoslibrary`, `.bundle`) sind Ordner und werden normal durchlaufen, damit man in die Photos-Mediathek hineinzoomen kann. In der Anzeige bekommen sie das Finder-Icon und das Kennzeichen „Paket“.
8. **iCloud-Dateien, die nur in der Cloud liegen** (Dataless-Dateien, `SF_DATALESS`): Sie belegen 0 Byte, werden mit 0 gezählt und in der Liste mit Wolken-Icon markiert. Beim Scan dürfen sie keinen Download auslösen. `fts`/`stat` lösen keinen aus, Lesezugriffe auf den Inhalt aber schon.
9. **Keine Berechtigung (`EACCES`/`EPERM`):** Der Ordner wird als „nicht lesbar“ markiert (Schloss-Icon) und gezählt, aber der Scan läuft weiter.

### 4.2 Datenmodell
Bei 2 Mio. Knoten zählt der Speicher, deshalb gibt es keine Klasse pro Datei mit `String`-Pfad.

```swift
struct Node {                 // ~40 Byte
    var parent: Int32         // Index in nodes, -1 = Root
    var firstChild: Int32     // erst nach dem Scan sortiert befüllt
    var childCount: Int32
    var nameOffset: UInt32    // in einen gemeinsamen UTF-8-Namenspuffer
    var nameLength: UInt16
    var flags: UInt16         // isDir, isPackage, isSymlink, unreadable, dataless, hardlinkDup
    var allocatedSize: UInt64 // für Ordner: Summe der Kinder
    var logicalSize: UInt64
    var fileCount: UInt32     // Anzahl Dateien im Teilbaum
}
final class ScanTree { var nodes: [Node]; var names: [UInt8] }
```
- Pfade werden bei Bedarf über die `parent`-Kette rekonstruiert.
- Nach dem Scan sind die Kinder jedes Ordners zusammenhängend und absteigend nach Größe sortiert gespeichert. Das Diagramm und die Liste brauchen so keine weitere Sortierung.
- Zielwert: unter 150 MB RAM bei 2 Mio. Dateien.

### 4.3 Ablauf und Parallelität
1. Der Wurzelordner wird gelesen, seine direkten Unterordner werden als Jobs in eine Work-Queue gelegt.
2. *N* Worker (Anzahl Performance-Kerne, maximal 8) arbeiten die Queue ab. Jeder Worker scannt seinen Teilbaum mit `fts` in einen **eigenen lokalen Puffer**, ohne Locks. Sehr große Teilbäume (über 50 000 Einträge) werden während des Scans weiter in Jobs aufgeteilt (Work-Stealing).
3. Ein Merger hängt die fertigen Teilbäume in den globalen Baum ein und propagiert die Größen nach oben.
4. Alle ~250 ms erzeugt der Merger einen leichten **Snapshot** (nur die ersten *k* Ebenen, Größen sind vorläufig) für die UI. Die UI liest nie direkt am wachsenden Baum.
5. Abbruch über `Task.isCancelled` beziehungsweise ein atomares Flag, das die Worker pro Verzeichnis prüfen.

Alternative für maximale Geschwindigkeit (Phase 2): `getattrlistbulk` liefert Name, Typ, allokierte Größe und Inode in einem einzigen Syscall pro Verzeichnisblock und ist erfahrungsgemäß noch einmal 1,5–2× schneller als `fts` + `stat`.

### 4.4 Inkrementelle Aktualisierung (Phase 2)
- Ein `FSEventStream` beobachtet die gescannte Wurzel. Bei Änderungen werden nur die betroffenen Ordner neu gescannt und die Größen nach oben aktualisiert. Dadurch bleibt die Ansicht aktuell, wenn man parallel im Finder aufräumt.

---

## 5. Sunburst-Rendering

- Das Layout wird **aus dem Modell berechnet und gecacht**: eine Liste von `Arc { nodeIndex, depth, startAngle, endAngle }`, die nur bei Fokuswechsel, Scan-Snapshot oder Löschen neu entsteht.
- Rekursion ab dem Fokusknoten: Der Winkel des Kindes ist Winkel des Elternknotens × (Kindgröße / Elterngröße). Die Rekursion stoppt bei der maximalen Ringzahl oder wenn der Winkel unter der Schwelle liegt; dann entsteht stattdessen ein Sammelsegment.
- Gezeichnet wird in `Canvas` mit einem `Path` pro Arc (`addArc` innen und außen) und einer dünnen Trennlinie in Hintergrundfarbe. Bei realistisch maximal ~5 000 Arcs läuft das flüssig mit 60 fps.
- **Hit-Testing:** Aus der Mausposition werden Polarkoordinaten (r, θ) berechnet. r ergibt den Ring, und per binärer Suche über die nach Winkel sortierten Arcs dieses Rings findet man das Segment. Das ist O(log n) und braucht keinen Path-Hit-Test.
- **Zoom-Animation:** Zwischen dem alten und dem neuen Layout werden Start- und Endwinkel sowie die Tiefe interpoliert (`TimelineView` bzw. `withAnimation` auf einem `animatableData`-Fortschritt).
- **Barrierefreiheit:** Die Liste rechts ist die zugängliche Hauptdarstellung. Das Diagramm bekommt ein `accessibilityElement` pro Ring-1-Segment mit Label „Name, Größe, Prozent“.
- Hell- und Dunkelmodus: Die Farbpaletten sind für beide Modi definiert.

---

## 6. Architektur

```
DiskRings/
├─ Package.swift
├─ Sources/DiskRings/
│  ├─ App/            DiskRingsApp.swift, AppState (@Observable), Commands (Menüs, Shortcuts)
│  ├─ Scanner/        ScanEngine (fts/getattrlistbulk), WorkQueue, ScanTree, HardlinkSet, VolumeInfo
│  ├─ Model/          NodeRef (leichter Zugriff: name, path, size, children), Snapshot
│  ├─ History/        SnapshotStore (Speichern/Laden, LZFSE), SnapshotDiff, DiffView-Modelle
│  ├─ Sunburst/       SunburstLayout (Arc-Berechnung), SunburstView (Canvas), HitTester, Palette
│  ├─ Browser/        DetailListView (Outline), BreadcrumbView, LargestFilesView
│  ├─ Actions/        FileActions (Finder, Trash, QuickLook, Undo), ProtectedPaths
│  └─ Settings/       SettingsView, Preferences
├─ Tests/DiskRingsTests/   ScanEngine gegen Fixture-Bäume (Hardlinks, Sparse, Symlink-Zyklen,
│                          unlesbare Ordner), Layout-Mathematik, Hit-Test, ProtectedPaths,
│                          Teil-Rescan, Snapshot-Roundtrip, Diff
├─ scripts/make-app.sh     Bundle bauen, Info.plist, Icon (iconutil), codesign (Developer ID, Hardened Runtime)
├─ scripts/release.sh      notarytool submit --wait, stapler staple, DMG/ZIP für GitHub Releases
└─ .github/workflows/      CI: swift build + swift test auf macos-latest
```

- **Zustandsfluss:** `ScanEngine` (Actor) → Snapshots → `AppState` (MainActor, `@Observable`) → Views. Aktionen wie Trash gehen über `FileActions` und verändern danach `ScanTree` über den Actor.

---

## 7. Berechtigungen und Distribution

- **Nicht sandboxed**, mit Developer ID signiert (`Developer ID Application: Stefan Richter (AGRWTKQZ8C)`, im Schlüsselbund vorhanden), mit Hardened Runtime, notarisiert und gestapelt (`stapler`).
- Bundle-ID: `de.stefanrichter.DiskRings`.
- Notarisierung über `xcrun notarytool` mit einem im Schlüsselbund gespeicherten Profil (`notarytool store-credentials`). Es werden keine Zugangsdaten im Repo abgelegt.
- Verteilung als ZIP oder DMG über **GitHub Releases** (Repo `brokoskokoli/diskrings`). Ein Auto-Update mit Sparkle ist für später vorgesehen.
- Signieren und Notarisieren laufen lokal, nicht in der CI, damit das Zertifikat den Rechner nicht verlässt.
- **Festplattenvollzugriff (Full Disk Access)** ist nötig für `~/Library/Mail`, `Messages`, `Safari`, Container anderer Apps usw. Ohne diesen Zugriff funktioniert die App trotzdem, zeigt aber mehr „nicht lesbar“-Ordner und einen größeren Anteil „Nicht zugeordnet“.
  - Erkennung: einen Lesetest auf `~/Library/Safari` oder `/Library/Application Support/com.apple.TCC/TCC.db` versuchen.
- Keine Netzwerkzugriffe und keine Telemetrie.
- Bei der Variante für den App Store wären nur vom Nutzer gewählte Ordner per Security-Scoped Bookmark erlaubt. Das ist bewusst nicht Teil von v1.

---

## 8. Meilensteine

| # | Inhalt | Ergebnis |
|---|---|---|
| M1 | Scan-Engine (`fts`, parallel, allokierte Größe, Hardlinks, Mount-Grenzen) und CLI-Ausgabe der Top-Ordner, mit Tests | Korrekte Zahlen; Abgleich mit `du -sk`, Abweichung unter 1 % |
| M2 | SwiftUI-Fenster: Volume-Liste, Ordnerwahl, Fortschritt, Detailliste | Benutzbar ohne Diagramm |
| M3 | Sunburst: Layout, Canvas, Hover, Tooltip, Klick-Zoom, Breadcrumb, Zurück/Vor | Kernerlebnis wie bei Scanner |
| M4 | Kontextmenü, Finder, Quick Look, Papierkorb mit Undo, Schutzliste | Aufräumen direkt aus der App |
| M5 | Segment „Nicht zugeordnet“, Volume-Statusleiste, Hinweis auf Festplattenvollzugriff, Live-Update während des Scans | macOS-spezifischer Feinschliff |
| M6 | Teil-Rescan per Rechtsklick, Snapshots speichern/verwalten, Vergleichsmodus (Wachstums-Sunburst, Delta-Spalten, Größte Veränderungen) | „Wo ist mein Speicher hin?“ |
| M7 | Signieren, Notarisieren, Release-Skript, erstes GitHub Release | Weitergabe möglich |
| M8 (opt.) | `getattrlistbulk`, FSEvents-Live-Update, Tab „Größte Dateien“, Farbschema nach Dateityp, Einstellungen | Tempo und Komfort |

---

## 9. Akzeptanzkriterien (Auszug)

- Ein Scan von `~` liefert eine Gesamtgröße, die maximal 1 % von `du -sk ~` abweicht (bei identischem Hardlink-Verhalten).
- Ein Scan von „Macintosh HD“ ergibt *Scan-Summe + Nicht zugeordnet = Volume belegt*.
- Das Diagramm bleibt bei 2 Mio. Dateien flüssig (Hover unter 16 ms pro Frame) und der Speicherbedarf unter 300 MB.
- „In den Papierkorb“ verschiebt das Element nachweislich in `~/.Trash`, ⌘Z stellt es wieder her, und das Diagramm aktualisiert sich ohne Rescan.
- Auf geschützte Pfade ist kein Löschen möglich, auch nicht per Tastenkürzel.
- Ein Symlink-Zyklus und unlesbare Ordner führen weder zu einem Hänger noch zu einem Absturz.
- Der Abbruch eines Scans reagiert in unter 0,5 s.
- Ein Teil-Rescan eines Ordners, in dem eine 1-GB-Datei angelegt wurde, erhöht die Größe dieses Ordners und aller Elternordner bis zur Wurzel um genau diesen Betrag.
- Snapshot speichern und laden ergibt einen identischen Baum (Roundtrip-Test).
- Testfall Vergleich: Snapshot erstellen, 5 GB in `~/Downloads/x` anlegen, neu scannen und vergleichen. „Größte Veränderungen“ zeigt `x` mit +5 GB an erster Stelle, und im Wachstums-Sunburst ist `Downloads` das dominierende Segment.
- Die gestartete `.app` besteht `spctl --assess --type execute` (notarisiert).

---

## 10. Entscheidungen

| Thema | Entscheidung |
|---|---|
| Name | **DiskRings**: kein Mac-Programm und kein GitHub-Repo dieses Namens gefunden (Stand 09.10.2026). „DiskSpace“ ist zu generisch und kollidiert mit Nektonys „Disk Space Analyzer“. |
| Weitergabe | Ja, signiert mit Developer ID, notarisiert, über GitHub Releases |
| Build | Swift Package ohne Xcode-Projekt; Xcode ist optional (siehe unten) |
| Farbschema | Nach Ast (wie Scanner); Färbung nach Dateityp als Option |

**Braucht es Xcode?** Nein. Bauen, Testen, Signieren und Notarisieren funktionieren mit den installierten Command Line Tools. Xcode wäre nur aus diesen Gründen nützlich:
- **Instruments** für das Profiling des Scans und des Renderings. Für das Performance-Ziel in M1/M3 ist das hilfreich, aber man kann auch mit `os_signpost` und Zeitmessungen arbeiten.
- **SwiftUI-Previews** und der Debugger in der IDE.
- **Asset-Kataloge** (`actool`). Diese sind nicht nötig, weil das Icon als `.icns` mit `iconutil` erstellt wird.

Zu prüfen in M1: ob `swift test` mit den Command Line Tools ohne Xcode läuft (Swift Testing beziehungsweise XCTest).
