# Entscheidungen und Abweichungen von der Spec

## M1 – Grundgerüst und Scan-Engine

### Testframework: Swift Testing (nicht XCTest)
- Umgebung: macOS 27, Swift 6.4, nur Command Line Tools (kein Xcode).
- `import XCTest` schlägt fehl (`unable to resolve module dependency: 'XCTest'`): Die CLT enthalten kein XCTest.
- `import Testing` ist vorhanden (`/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework`), aber das Makro-Plugin wird beim Bauen nicht gefunden (`plugin for module 'TestingMacros' not found`). Das Plugin liegt unter `/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`; der Compiler-Job, der das Modul erzeugt, bekommt den Pfad aber nicht mit.
- Lösung: `Package.swift` setzt für das Test-Target `-plugin-path <…>/plugins/testing`, und zwar nur, wenn der Pfad existiert. Mit Xcode ist der Zusatz wirkungslos. `swift test` läuft damit ohne weitere Parameter.
- `--build-system native` hilft nicht (dort fehlt sogar das Modul `Testing`).
- Der Linker meldet bei jedem Build `ld: warning: search path '/Library/Developer/CommandLineTools/Developer/…' not found`. Das kommt aus der Toolchain, nicht aus eigenem Code, und wird ignoriert.

### Scan über `getattrlistbulk` statt `fts`
- Die Spec erlaubt beides (2, 4.3) und nennt `getattrlistbulk` als schnellere Variante für Phase 2. Es wird schon in M1 verwendet: Ein Syscall pro Verzeichnisblock liefert Name, Typ, Gerät, Inode, BSD-Flags, Linkanzahl, belegte Größe (`ATTR_FILE_ALLOCSIZE`) und logische Größe (`ATTR_FILE_DATALENGTH`). Das spart das `lstat` pro Datei.
- Eigener Verzeichnis-Walker mit explizitem Stapel statt Rekursion (500 Ebenen und mehr sind unkritisch). Pfade über `PATH_MAX` werden stückweise mit `openat` geöffnet.
- Belegte Größe: `ATTR_FILE_ALLOCSIZE` entspricht `st_blocks * 512` (Abgleich mit `du -sk` auf `/usr/share` bytegenau; Tests vergleichen außerdem gegen `lstat`).
- Ordner selbst zählen mit 0 Byte (auf APFS ist `st_blocks` für Ordner 0; `du` zählt sie mit, dort ergibt das ebenfalls 0).

### Parallelität
- Worker sind eigene `Thread`s (nicht der kooperative Swift-Concurrency-Pool), weil sie in blockierenden Syscalls stecken.
- **Abweichung:** Standard sind alle Kerne, höchstens 8, statt „Anzahl Performance-Kerne“. Der Scan verbringt fast die ganze Zeit im Kernel (`getattrlistbulk`), nicht in eigener Rechenarbeit. Gemessen auf dem Entwicklungsrechner (5 Performance-, 6 Effizienzkerne), Scan von `~` mit 2,9 Mio. Einträgen: 5 Worker 12,8–13,6 s, 8 Worker 9,8–10,3 s, 11 Worker 11,5 s. Beim Scan von `/`: 18,5 s gegenüber 14,1 s. Details in docs/PERFORMANCE.md.
- Statt fester Teilbaum-Jobs mit `fts` arbeitet jeder Worker einen lokalen Stapel offener Ordner ab. Er gibt die Hälfte davon an die gemeinsame Queue ab, sobald ein anderer Worker untätig ist oder er seit der letzten Abgabe mehr als `splitThreshold` (Standard 50 000) Einträge gelesen hat. Das ist das „Aufteilen großer Teilbäume“ aus 4.3.
- Es gibt keinen laufenden Merger; die lokalen Puffer werden am Ende in einem Schritt zusammengeführt. Die Live-Ansicht kommt stattdessen aus einem kleinen gemeinsamen „Skelett“ (Ordner bis Tiefe k), in das die Worker pro Ordner unter einem Lock ihre Summen eintragen. Daraus entsteht alle `progressInterval` Sekunden ein vorläufiger `ScanTree`. In diesen Snapshots erscheinen nur Ordner; Dateien stecken in der Größe ihres Ordners. Hardlinks sind darin noch nicht bereinigt, die vorläufigen Bytes können also etwas zu hoch sein.

### Determinismus und Hardlinks
- Die Spec beschreibt ein Set, das das „erste Auftreten“ merkt. Bei parallelem Scan hängt „erstes“ vom Zufall ab. Deshalb sammeln die Worker Hardlink-Kandidaten (`nlink > 1`) lokal, und am Ende zählt pro `(st_dev, st_ino)` genau das Vorkommen mit dem bytewise kleinsten Pfad. Weitere Vorkommen bleiben als Knoten im Baum, zählen mit 0 Byte und tragen das Flag `hardlinkDuplicate`. In `fileCount` zählen sie als Einträge mit.
- Sortierung der Kinder: belegte Größe absteigend, dann logische Größe absteigend, dann Name aufsteigend (UTF-8-Bytes). Dadurch ergeben sequenzieller und paralleler Scan identische Bäume (getestet).

### Firmlinks / Data-Volume
- Auf macOS 27 melden `/` und `/System/Volumes/Data` **dasselbe** `st_dev` (APFS-Volume-Gruppe). Eine reine `st_dev`-Prüfung reicht also nicht, um die Doppelzählung zu verhindern.
- Lösung: Einhängepunkte werden zusätzlich über `ATTR_DIR_MOUNTSTATUS` (`DIR_MNTSTATUS_MNTPOINT`) erkannt, und `/System/Volumes/Data` steht immer auf der Liste „nie betreten“, wenn es ein Einhängepunkt ist (`statfs`). Ältere Systeme mit getrennten Geräte-IDs werden über die Erlaubt-Liste der Geräte abgedeckt (System-Volume plus Data-Volume).
- Nicht betretene Einhängepunkte bleiben als Ordnerknoten mit Flag `mountPoint` (0 Byte) im Baum.

### Speicher: mmap-Puffer für Zwischenstände
- Die Worker-Puffer, der zusammengeführte Rohbaum und die Hilfsarrays des Baum-Aufbaus liegen in `MappedBuffer` (eigene `mmap`-Blöcke) statt in Swift-Arrays. Grund: Der macOS-Allocator behält freigegebene große Blöcke im „Large Cache“. Mit Arrays blieb der Prozess nach einem Scan mit 1,5 Mio. Knoten bei 314 MB, obwohl der Baum nur ~90 MB braucht (mit `MallocLargeCache=0` waren es 92 MB). `munmap` gibt den Speicher sofort zurück.
- Der fertige `ScanTree` nutzt weiterhin normale Arrays, jeweils in genau passender Größe angelegt.

### Datenmodell
- `ScanTree` ist wie in der Spec eine `final class`, aber unveränderlich (`let`) und damit `Sendable`. Änderungen für Löschen und Teil-Rescan (M4/M6) kommen später.
- `Node` hat genau 40 Byte (Felder so angeordnet, dass kein Padding entsteht). Zusätzliche Flags: `mountPoint`, `hidden`.
- Die Kinder liegen in Breitensuche-Reihenfolge zusammenhängend; Eltern stehen immer vor ihren Kindern.
- Die Wurzel heißt wie die letzte Pfadkomponente (bei `/` „/“). Der Wurzelpfad wird mit `realpath` aufgelöst, ein Symlink als Wurzel wird also verfolgt (anders als `du` ohne `-H`).

### Weitere Details
- **Versteckt** heißt: Name beginnt mit „.“ oder das BSD-Flag `UF_HIDDEN` ist gesetzt.
- **Pakete** werden über eine feste Liste von Endungen erkannt (`PackageDetector`), nicht über LaunchServices/UTType. Das ist schnell, deterministisch und ohne AppKit testbar. Die Liste ist nicht vollständig.
- **Dataless-Dateien**: zählen mit 0 belegten Byte, die logische Größe bleibt erhalten. Dataless-Ordner werden nicht betreten. Jeder Worker setzt `IOPOL_MATERIALIZE_DATALESS_FILES_OFF`, damit kein Zugriff einen iCloud-Download auslöst.
- **Ausschlussliste**: exakte absolute Pfade (der Teilbaum fällt mit weg); Pfade werden zusätzlich mit `realpath` aufgelöst.
- **Formatierung**: dezimal (1 KB = 1000 Byte), deutsch, unabhängig vom System-Locale. KB ohne, ab MB eine Nachkommastelle („61,0 GB“ statt „61 GB“ wie in der Skizze). Tausendertrenner ist ein schmales geschütztes Leerzeichen („312 841“).
- **Nicht zugeordnet** = `totalCapacity − availableCapacity − Scan-Summe`, nie negativ. Bereinigbarer Speicher zählt damit als belegt und landet in „Nicht zugeordnet“, wie im Segmentnamen der Spec vorgesehen.

## M2/M3 – Oberfläche und Sunburst

### Build ohne Xcode: `@State` als Makro
- Im SDK von macOS 27 ist `@State` zusätzlich ein Makro (`SwiftUIMacros.StateMacro`). Dessen Plugin liefern nur Xcode, nicht die Command Line Tools; `@State` bricht den Build daher mit „plugin for module 'SwiftUIMacros' not found“ ab.
- Lösung: `typealias ViewState<Value> = SwiftUI.State<Value>` (in `Sources/DiskRings/Support/Support.swift`) und überall `@ViewState` statt `@State`. Als Typalias greift der Property Wrapper, nicht das Makro. Mit Xcode funktioniert das genauso.

### Layout (`SunburstLayout`)
- Winkel im Bogenmaß, 0 = oben, im Uhrzeigersinn. Die Arcs werden ringweise in Breitensuche erzeugt; so ist jeder Ring nach Winkel sortiert (Voraussetzung für die binäre Suche im Hit-Test), und eine Obergrenze für die Arcs schneidet außen ab statt einseitig.
- **Obergrenze** (Standard 12 000 Arcs): Ein Ring, der sie sprengen würde, entfällt ganz. Nur der erste Ring wird gekürzt (Rest ins Sammelsegment).
- **Sammelsegment** je Elternknoten für alle Kinder unter der Schwelle; die Schwelle gilt in absoluten Grad (0,5°), wie in der Spec. Ein einzelnes zu kleines Element landet ebenfalls im Sammelsegment („1 kleineres Element“).
- **Restsegment** (zusätzlich zur Spec): Live-Snapshots enthalten nur Ordner, deren Größe schon die Dateien enthält. Die Differenz Ordnergröße − Summe der Kinder erscheint als graues Segment „Dateien in diesem Ordner“, damit die Winkel stimmen.
- Im Modus „belegt“ läuft die Berechnung nur bis zum ersten zu kleinen Kind (die Kinder sind sortiert). Für die Größe des Sammelsegments werden die übrigen Kinder allerdings aufsummiert (bis zum ersten mit 0 Byte); bei sehr großen Ordnern im Fokusbereich ist das O(Kinder). Im Modus „logisch“ werden die Kinder jedes sichtbaren Ordners einmal durchlaufen und die großen nach logischer Größe sortiert.
- **„Nicht zugeordnet“** ist ein Arc im ersten Ring (Ende des Kreises), nur wenn der Fokus die Wurzel ist und der Größenmodus „belegt“ (beim logischen Modus ergibt die Differenz keinen Sinn). Gezeichnet wird es von Ring 1 bis zum Außenrand, schraffiert; der Hit-Test trifft es in allen Ringen („im äußersten Bereich der Wurzel“, SPEC 4.1). Angezeigt wird es nur, wenn die Scan-Wurzel genau der Einhängepunkt des Volumes ist.
- Ringbreiten: Mittelscheibe 22 % des Radius, jeder Ring 84 % so breit wie der vorige.

### Farben
- Schema „Ast“: feste Folge von 12 gut unterscheidbaren Farbtönen in der Reihenfolge der Äste (größter zuerst), mit ±9° Verschiebung je nach Lage im Ast. Die Töne werden relativ zum Fokus vergeben; nach dem Hineinzoomen ändern sich also die Farben (wie bei Scanner und DaisyDisk).
- Schema „Dateityp“: Dateien nach Endung (feste Liste), Ordner neutral grau. Pakete mit bekannter Endung (z. B. `.app`, `.photoslibrary`) bekommen die Kategorie und vererben sie an ihren Inhalt. Eine Einfärbung von Ordnern nach dem überwiegenden Dateityp gibt es nicht (bräuchte eine Auswertung des ganzen Teilbaums).
- Beschriftungen sind schwarz oder weiß, je nachdem, was mehr Kontrast hat (immer mindestens 4,58 : 1, getestet).

### Zoom-Animation
- `ZoomTransition` bildet beide Layouts mit derselben „Kamera“ ab: Winkel' = a·Winkel + b, Ring' = Ring + c. Interpoliert werden die Bilder von 0 und 2π und die Tiefe, linear, mit Ease-in-out (300 ms). Das alte Layout blendet dabei aus. Ohne Vorfahrenbeziehung (z. B. Zurück zu einem Geschwister) wird überblendet. Bei „Bewegung reduzieren“ gibt es keine Animation.

### Navigation
- `FocusHistory` speichert Knotenindizes. Bei jedem neuen Baum (Live-Snapshot → Endergebnis, Rescan) wird die Historie über die Pfade übertragen; ein verschwundener Fokus fällt auf den nächsten vorhandenen Vorfahren zurück. Man kann also schon während des Scans hineinzoomen.
- Klick auf ein Sammelsegment zoomt in dessen Elternordner (falls nicht schon Fokus). Klick auf eine Datei wählt sie aus und klappt die Liste bis dorthin auf.
- „Rescan“ in der Toolbar ist vorerst ein kompletter neuer Scan der Wurzel; der Fokus wird danach über den Pfad wiederhergestellt.

### Oberfläche
- Die Toolbar (Zurück/Vor, Breadcrumb, Rescan) liegt im Fensterinhalt statt in der `NSToolbar` des Fensters. Grund: So lässt sie sich in den Vorschaubildern mitrendern, und die Breadcrumb hat die volle Breite.
- Diagramm und Liste stehen in einem `HStack` mit fester Listenbreite (400 pt), nicht in einem `HSplitView`; die Liste ist also nicht in der Breite verstellbar.
- Die Detailliste ist eine eigene Outline aus `ScrollView` + `LazyVStack` (keine `List`/`OutlineGroup`): Prozentbalken, Farbfeld aus dem Diagramm und Hover-Sync sind so einfacher. Je Ebene höchstens 400 Zeilen, der Rest als eine Zeile „N kleinere Elemente“. An der Volume-Wurzel steht „Nicht zugeordnet“ als eigene Zeile, nach Größe einsortiert. Der Prozentwert einer Zeile bezieht sich auf ihren Elternordner.
- Die Liste zeigt ein Farbfeld nur für Knoten, die im Diagramm bis Ring 3 sichtbar sind.
- Das Fenster ist ein einzelnes `Window` (keine `WindowGroup`), damit die Menübefehle (⌘[ / ⌘] / ⌘↑) ohne Fokus-Verwaltung auf den einen `AppState` wirken.
- Kontextmenü: Struktur, Reihenfolge und Tastenkürzel aller Einträge aus SPEC 3.5 stehen in `NodeAction`; in M3 ist nur „Hier hineinzoomen“ aktiv, die übrigen Einträge sind ausgegraut mit „(folgt)“. M4 implementiert `NodeActions.perform` und `isImplemented`.
- Einstellungen, die schon wirken: Ringanzahl, Farbschema (mit Legende), Schwelle für das Sammelsegment (0,1–3°), Beschriftung an/aus, Größenmodus, versteckte Dateien, andere Volumes überqueren, Ausschlussliste. Die Scan-Optionen wirken beim nächsten Scan. Snapshot-Einstellungen fehlen noch (M6).

### Vorschaubilder (visuelle Prüfung)
- `DiskRings --render-snapshots <ordner> [--scan <pfad>]` rendert die Szenen hell und dunkel als PNG und beendet sich. Es gibt kein Test-Target für die App: Ein Test-Target, das vom ausführbaren SwiftUI-Target abhängt, wäre mit den Command Line Tools ein weiterer Sonderweg.
- Das Diagramm allein wird mit `ImageRenderer` gerendert. Ganze Ansichten (Hauptansicht, Start, Scan, Einstellungen) dagegen über ein unsichtbares Fenster mit `NSHostingView` und `cacheDisplay`: `ImageRenderer` zeichnet AppKit-gestützte Bausteine (Buttons, ScrollView, Form) nicht, dort erschienen nur gelbe Platzhalter.
- `ImageRenderer` löst dynamische `NSColor`s nicht nach dem Hell-/Dunkelmodus auf; der Hintergrund ist dort deshalb fest gesetzt.

### Bündel
- `scripts/make-app.sh` baut `build/DiskRings.app` (Release, Info.plist mit `de.stefanrichter.DiskRings`, `LSMinimumSystemVersion` 14.0) und signiert ad hoc. Developer ID, Hardened Runtime, Icon und Notarisierung kommen in M7.
- `--scan <pfad>` als Startargument startet sofort einen Scan (zum Testen: `open build/DiskRings.app --args --scan /usr/share`).
