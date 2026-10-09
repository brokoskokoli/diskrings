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
- Eigener Verzeichnis-Walker mit explizitem Stapel statt Rekursion (500 Ebenen und mehr sind unkritisch).
- **Öffnen relativ zum Elternordner (Befund K3):** Unterordner werden mit `openat(fd_eltern, name, O_NOFOLLOW | O_DIRECTORY)` geöffnet, nicht über den vollen Pfad. Wird ein Pfadbestandteil während des Scans gegen einen Symlink getauscht, liest der Scan trotzdem den echten Ordner. Der Deskriptor eines Ordners bleibt offen, solange Jobs seiner Unterordner ausstehen (`DirHandle`, Referenzzählung über ARC, auch bei Abbruch). Höchstens die Hälfte des weichen `RLIMIT_NOFILE` (maximal 1024) wird so offen gehalten; ist das Budget erschöpft oder meldet `openat` `EMFILE`, wird über den vollen Pfad geöffnet (Pfade über `PATH_MAX` stückweise mit `openat`).
- **Verschwundene Ordner (Befund K1):** Liefert das Öffnen `ENOENT`, `ENOTDIR` oder `ELOOP` (Ordner gelöscht oder ersetzt zwischen Auflisten und Öffnen), wird der Knoten still verworfen statt als „nicht lesbar“ markiert. Ausnahme: die Wurzel selbst.
- Belegte Größe: `ATTR_FILE_ALLOCSIZE` entspricht `st_blocks * 512` (Abgleich mit `du -sk` auf `/usr/share` bytegenau; Tests vergleichen außerdem gegen `lstat`).
- **Eigengröße von Ordnern (Befund S1):** Die belegte Größe eines Ordners ist seine eigene Größe (`ATTR_DIR_ALLOCSIZE` = `st_blocks * 512`, bei der Wurzel per `lstat`) plus die Summe seines Teilbaums, genau wie bei `du`. Auf APFS ist die Eigengröße 0, auf HFS+ ebenfalls; auf ExFAT/FAT belegt jeder Ordner mindestens einen Cluster (ohne diese Korrektur wich ein ExFAT-Image um 30 % von `du` ab). Nicht betretene Einhängepunkte zählen mit 0. Die **logische** Eigengröße von Ordnern zählt bewusst nicht (`ATTR_DIR_DATALENGTH` wird nicht abgefragt): Die logische Größe bleibt die Summe der Dateigrößen, wie im Finder. Folge für die Invarianten: Belegt ist ein Ordner *mindestens* so groß wie die Summe seiner Kinder, logische Größe und Dateianzahl sind exakt die Summe (`ScanTree.validate()`).

### Parallelität
- Worker sind eigene `Thread`s (nicht der kooperative Swift-Concurrency-Pool), weil sie in blockierenden Syscalls stecken.
- **Abweichung:** Standard sind alle Kerne, höchstens 8, statt „Anzahl Performance-Kerne“. Der Scan verbringt fast die ganze Zeit im Kernel (`getattrlistbulk`), nicht in eigener Rechenarbeit. Gemessen auf dem Entwicklungsrechner (5 Performance-, 6 Effizienzkerne), Scan von `~` mit 2,9 Mio. Einträgen: 5 Worker 12,8–13,6 s, 8 Worker 9,8–10,3 s, 11 Worker 11,5 s. Beim Scan von `/`: 18,5 s gegenüber 14,1 s. Details in docs/PERFORMANCE.md.
- Statt fester Teilbaum-Jobs mit `fts` arbeitet jeder Worker einen lokalen Stapel offener Ordner ab. Er gibt die Hälfte davon an die gemeinsame Queue ab, sobald ein anderer Worker untätig ist oder er seit der letzten Abgabe mehr als `splitThreshold` (Standard 50 000) Einträge gelesen hat. Das ist das „Aufteilen großer Teilbäume“ aus 4.3.
- Es gibt keinen laufenden Merger; die lokalen Puffer werden am Ende in einem Schritt zusammengeführt. Die Live-Ansicht kommt stattdessen aus einem kleinen gemeinsamen „Skelett“ (Ordner bis Tiefe k, Standard 6 wie die Standard-Ringzahl, Befund K7; Aufwand siehe PERFORMANCE.md), in das die Worker pro Ordner unter einem Lock ihre Summen eintragen. Daraus entsteht alle `progressInterval` Sekunden ein vorläufiger `ScanTree`. In diesen Snapshots erscheinen nur Ordner; Dateien stecken in der Größe ihres Ordners. Hardlinks sind darin noch nicht bereinigt, die vorläufigen Bytes können also etwas zu hoch sein.

### Determinismus und Hardlinks
- Die Spec beschreibt ein Set, das das „erste Auftreten“ merkt. Bei parallelem Scan hängt „erstes“ vom Zufall ab. Deshalb sammeln die Worker Hardlink-Kandidaten (`nlink > 1`) lokal, und am Ende zählt pro `(st_dev, st_ino)` genau das Vorkommen mit dem bytewise kleinsten Pfad. Weitere Vorkommen bleiben als Knoten im Baum, zählen mit 0 Byte und tragen das Flag `hardlinkDuplicate`. In `fileCount` zählen sie als Einträge mit.
- Sortierung der Kinder: belegte Größe absteigend, dann logische Größe absteigend, dann Name aufsteigend (UTF-8-Bytes). Dadurch ergeben sequenzieller und paralleler Scan identische Bäume (getestet).

### Firmlinks / Data-Volume
- Auf macOS 27 melden `/` und `/System/Volumes/Data` **dasselbe** `st_dev` (APFS-Volume-Gruppe). Eine reine `st_dev`-Prüfung reicht also nicht, um die Doppelzählung zu verhindern.
- Lösung: Einhängepunkte werden zusätzlich über `ATTR_DIR_MOUNTSTATUS` (`DIR_MNTSTATUS_MNTPOINT`) erkannt, und `/System/Volumes/Data` steht immer auf der Liste „nie betreten“, wenn es ein Einhängepunkt ist (`statfs`). Ältere Systeme mit getrennten Geräte-IDs werden über die Erlaubt-Liste der Geräte abgedeckt (System-Volume plus Data-Volume).
- Nicht betretene Einhängepunkte bleiben als Ordnerknoten mit Flag `mountPoint` (0 Byte) im Baum.

### Ereignis-Stream begrenzt (Befund S6)
- `ScanEngine.events(_:)` puffert höchstens `eventBufferLimit` (8) Ereignisse und verwirft bei einem langsamen Konsumenten die ältesten (`bufferingNewest`). `.finished` ist immer das letzte Ereignis und geht nie verloren. Die Fälle von `ScanEvent` sind unverändert.
- `ScanProgress` hat ein neues Feld `activeWorkers` (mit Standardwert, der memberwise-Initialisierer bleibt aufrufbar).

### Speicher: mmap-Puffer für Zwischenstände
- Die Worker-Puffer, der zusammengeführte Rohbaum und die Hilfsarrays des Baum-Aufbaus liegen in `MappedBuffer` (eigene `mmap`-Blöcke) statt in Swift-Arrays. Grund: Der macOS-Allocator behält freigegebene große Blöcke im „Large Cache“. Mit Arrays blieb der Prozess nach einem Scan mit 1,5 Mio. Knoten bei 314 MB, obwohl der Baum nur ~90 MB braucht (mit `MallocLargeCache=0` waren es 92 MB). `munmap` gibt den Speicher sofort zurück.
- Der fertige `ScanTree` nutzt weiterhin normale Arrays, jeweils in genau passender Größe angelegt.
- **Baumaufbau an Ort und Stelle (Befund K8):** Der Assembler schreibt die Worker-Puffer direkt in das endgültige `[Node]`-Array (in Puffer-Reihenfolge; `firstChild`/`childCount` dienen vorübergehend als Zähler und Cursor). Der `TreeBuilder` sortiert dieses Array dann per Zyklen-Permutation an Ort und Stelle in die Breitensuche-Reihenfolge. Es gibt keinen Rohbaum in Spaltenform und kein zweites Knoten-Array mehr; die Spitze sank beim Scan von `~` von 311 auf 239 MB (PERFORMANCE.md).

### Datenmodell
- `ScanTree` ist wie in der Spec eine `final class`, aber unveränderlich (`let`) und damit `Sendable`. Änderungen für Löschen und Teil-Rescan (M4/M6) kommen später.
- `Node` hat genau 40 Byte (Felder so angeordnet, dass kein Padding entsteht). Zusätzliche Flags: `mountPoint`, `hidden`, `dead` (siehe M6).
- `ScanTree.isComplete`: `true` bei fertigen Scans. Live-Snapshots und Snapshots mit Mindestgröße enthalten nicht jede Datei als Knoten; dort sind logische Größe und Dateianzahl eines Ordners nur *mindestens* die Summe der Kinder.
- `ScanTree.validate()` prüft alle Invarianten (Erreichbarkeit, Zusammenhang, Sortierung, Summen, Hardlink-Tabelle) und wird in den Tests für jeden erzeugten Baum aufgerufen.
- **Pfadsuche:** `index(ofPath:)` akzeptiert den Wurzelpfad nur an einer Komponentengrenze (Befund S2) und vergleicht Namen erst bytegenau, dann kanonisch äquivalent (NFC/NFD, Befund K6). Gespeichert werden die Namen weiterhin bytegenau wie im Dateisystem.
- **Anzahl der Einträge (`itemCount`):** Für die Gesamtzahl der Einträge pro Teilbaum ist im 40-Byte-Knoten kein Platz; ein eigenes Array kostete 4 Byte pro Knoten (+7 %). `NodeRef.itemCount` wird deshalb bei Bedarf durch Ablaufen des Teilbaums berechnet (O(Teilbaum)). Für Tooltips einmal pro Hover berechnen bzw. cachen.
- Die Kinder liegen in Breitensuche-Reihenfolge zusammenhängend; Eltern stehen immer vor ihren Kindern.
- Die Wurzel heißt wie die letzte Pfadkomponente (bei `/` „/“). Der Wurzelpfad wird mit `realpath` aufgelöst, ein Symlink als Wurzel wird also verfolgt (anders als `du` ohne `-H`).

### Weitere Details
- **Versteckt** heißt: Name beginnt mit „.“ oder das BSD-Flag `UF_HIDDEN` ist gesetzt.
- **Pakete** werden über eine feste Liste von Endungen erkannt (`PackageDetector`), nicht über LaunchServices/UTType. Das ist schnell, deterministisch und ohne AppKit testbar. Die Liste ist nicht vollständig.
- **Dataless-Dateien**: zählen mit 0 belegten Byte, die logische Größe bleibt erhalten. Dataless-Ordner werden nicht betreten. Jeder Worker setzt `IOPOL_MATERIALIZE_DATALESS_FILES_OFF`, damit kein Zugriff einen iCloud-Download auslöst.
- **Ausschlussliste**: exakte absolute Pfade (der Teilbaum fällt mit weg); Pfade werden zusätzlich mit `realpath` aufgelöst.
- **Formatierung**: dezimal (1 KB = 1000 Byte), deutsch, unabhängig vom System-Locale. KB ohne, ab MB eine Nachkommastelle („61,0 GB“ statt „61 GB“ wie in der Skizze). Tausendertrenner ist ein schmales geschütztes Leerzeichen („312 841“).
- **Nicht zugeordnet** = `totalCapacity − availableCapacity − Scan-Summe`, nie negativ. Bereinigbarer Speicher zählt damit als belegt und landet in „Nicht zugeordnet“, wie im Segmentnamen der Spec vorgesehen.

## M6 – Teil-Rescan, Snapshots und Vergleich (Kern)

### Veränderbarer Baum: neue unveränderliche Versionen (copy-on-write)
- **Entscheidung:** `ScanTree` bleibt unveränderlich und `Sendable`. `replacingSubtree(at:with:)`, `removingNode(at:)` und `compacted()` erzeugen eine **neue** Baum-Version (`TreeEdit.tree`); der alte Baum bleibt unverändert gültig.
- **Begründung:** Die Oberfläche hält den Baum, ein gecachtes Sunburst-Layout und `NodeRef`s; Rescans laufen im Hintergrund. Mit unveränderlichen Versionen gibt es keine Datenrennen und keine Sperren beim Lesen, und das Layout des alten Baums bleibt bis zum Austausch konsistent (die Diagramm-Animation kann alt gegen neu interpolieren). Kosten: eine Kopie von Knoten-Array und Namenspuffer pro Änderung, mit passender Kapazität in einem Schritt angelegt. Gemessen (Debug-Build): 3,8 ms für das Einhängen eines Ordners mit 300 Dateien in einen Baum mit 2 010 101 Knoten (Ziel: unter 100 ms ohne den Scan). Speicher: Während des Austauschs existieren kurz zwei Versionen.
- Ein in-place veränderbarer Baum hätte die Kopie gespart, aber Locks bzw. eine Actor-Isolation für jeden Lesezugriff des Layouts erfordert.

### Ablauf eines Teil-Rescans (Befund S7)
- `ScanEngine.rescanBlocking(subtree:in:)` bzw. `rescan(subtree:in:)` (async) scannt den Pfad des Knotens mit denselben Optionen und hängt das Ergebnis mit `replacingSubtree` ein. Existiert der Pfad nicht mehr, wird der Knoten entfernt (`RescanResult.removed`). Ein nicht betretener Einhängepunkt wird ohne `crossMountPoints` nicht neu eingelesen.
- Der Knoten behält Namen, Elternknoten und seinen Datensatz; seine alten Nachfahren werden als `.dead` markiert, die neuen hinten angehängt (zusammenhängend, sortiert, wie vom `TreeBuilder` geliefert).
- Die Differenz wird bis zur Wurzel propagiert; in jeder Ebene wird der geänderte Knoten innerhalb seiner Geschwister an die richtige Stelle geschoben. **Folge:** Dabei können der Knoten selbst und Geschwister entlang des Pfads ihren Index ändern (sonst wären die Kinder nicht mehr sortiert). `TreeEdit.index` liefert den neuen Index des bearbeiteten Knotens, `TreeEdit.translate(_:)` übersetzt beliebige alte Indizes (z. B. Fokus, Auswahl, Verlauf). Eltern stehen weiterhin vor ihren Kindern; die Breitensuche-Reihenfolge gilt nach einer Änderung aber nicht mehr global (erst wieder nach einer Kompaktierung).
- **Kompaktierung:** Sind mehr als 25 % der Knoten tot (`needsCompaction`), kompaktiert `replacingSubtree`/`removingNode` standardmäßig sofort (`compactIfNeeded: true`) und setzt `TreeEdit.compacted`; dann ändern sich alle Indizes (über `translate` abbildbar). Mit `compactIfNeeded: false` kann die Oberfläche das später im Hintergrund mit `compacted()` erledigen.
- **Tote Knoten** bleiben bis zur Kompaktierung in `ScanTree.nodes`. Sie sind von der Wurzel aus nicht erreichbar; wer `nodes` linear durchläuft, muss `.dead` überspringen. `count` zählt sie mit, `liveCount` nicht.
- **Undo** des Papierkorbs: `rescanBlocking(path:in:)` liest den nächsten im Baum vorhandenen Vorfahren des Pfads neu ein, also den Elternordner des zurückgelegten Elements.

### Hardlinks beim Teil-Rescan
- Der Baum behält eine schlanke Tabelle aller Dateien mit `nlink > 1`: Knotenindex, Gerät, Inode und echte Größe (32 Byte pro Eintrag, nur für Hardlinks). Beim Rescan fliegen die Einträge toter Knoten heraus, die neuen kommen hinzu, und jede betroffene Gruppe wird neu bereinigt: Weiterhin zählt das lebende Vorkommen mit dem bytewise kleinsten Pfad, die anderen mit 0 Byte und Flag `hardlinkDuplicate`. Größenwechsel (auch außerhalb des Teilbaums) werden wie oben propagiert.
- **Grenze:** Hatte eine Datei beim Scan `nlink == 1` und bekommt sie danach einen weiteren Link im neu eingelesenen Teilbaum, steht das alte Vorkommen nicht in der Tabelle; die Datei zählt dann doppelt, bis ein gemeinsamer Vorfahre neu eingelesen wird (Test „Bekannte Grenze“). Alle Inodes zu speichern kostete 12 Byte pro Knoten.

### Snapshots (`.drsnap`)
- Format wie in SPEC 3.9: Knoten-Array (40 Byte pro Knoten wie `Node`) plus Namenspuffer, LZFSE-komprimiert über `compression_encode_buffer` (Compression-Framework). Davor ein **unkomprimierter** JSON-Kopf (`SnapshotMetadata`), damit die Snapshot-Liste ohne Dekompression auskommt. Alle Zahlen little-endian, Formatversion 1; eine unbekannte Version ergibt `SnapshotError.unsupportedVersion`.
- Beim Laden werden Kennung, Version, Längen, eine FNV-1a-Prüfsumme der komprimierten Daten, die exakte Dekompressionslänge, die Struktur (Eltern vor Kindern, Bereiche, Namen) und schließlich `validate()` geprüft. Beschädigte oder abgeschnittene Dateien ergeben einen `SnapshotError`, nie einen Absturz.
- **Mindestgröße:** Dateien mit einer belegten Größe unter `minimumFileSize` (Standard 1 MB = 1 000 000 Byte) werden nicht gespeichert; ihre Größe und Anzahl stecken weiter in der Ordnersumme. Der geladene Baum hat dann `isComplete == false`. Ordner werden immer gespeichert. Mit `minimumFileSize = 0` ist der Roundtrip bytegenau identisch (`isIdentical`).
- Gespeichert werden auch die logische Größe und alle Flags (kostet nach Kompression wenig), nicht aber die Hardlink-Tabelle.
- Zeitpunkte werden auf ganze Millisekunden gespeichert. Dateiname `<zeitstempel>.drsnap` in UTC (`20261009T170632609Z.drsnap`), bei Kollision mit Zähler. Ohne Volume-UUID landet der Snapshot im Unterordner `unbekannt`.
- „Nicht zugeordnet“ wird in den Volume-Kennzahlen nur gespeichert, wenn die Scan-Wurzel die Volume-Wurzel ist (sonst ist der Wert nicht aussagekräftig).
- `delete` und `rename` arbeiten nur auf `.drsnap`-Dateien innerhalb des Basisverzeichnisses (`SnapshotError.outsideStore`). `rename` schreibt die Datei mit neuem Kopf atomar neu.
- `prune(maxCount:rootPath:volumeUUID:)` löscht die ältesten Snapshots einer Scan-Wurzel über der Höchstzahl (Standard 20, SPEC 3.7).

### Vergleich (`SnapshotDiff`)
- Beide Seiten sind ein `Snapshot` (Metadaten plus `ScanTree`); ein frischer Scan wird mit `Snapshot(metadata: .current(for: result), tree: result.tree)` zur Seite. Ergebnis ist ein Vereinigungsbaum (`entries`, Breitensuche, Kinder nach Name sortiert) mit Indizes in beide Bäume; Größen werden nicht kopiert, sondern aus den Bäumen gelesen (20 Byte pro Eintrag plus je 4 Byte pro Knoten für die Rückabbildung).
- **Kleine Dateien:** Verglichen wird mit der größeren der beiden Mindestgrößen. Dateien darunter bekommen auf keiner Seite einen eigenen Eintrag (sie stecken im Delta ihres Ordners); sonst erschienen alle kleinen Dateien eines frischen Scans gegenüber einem Snapshot als „neu“. Eine Datei, die über die Schwelle wächst, erscheint als „neu“.
- **Status** nach belegter Größe: neu, entfernt, gewachsen, geschrumpft, unverändert. Umbenannte oder verschobene Ordner erscheinen als „entfernt“ plus „neu“ (SPEC 3.9, Grenzen).
- **Wachstumsbaum:** Die Größe jedes Knotens ist sein Brutto-Zuwachs: Summe des Zuwachses seiner Kinder plus ein positiver, nicht aufgeschlüsselter Rest (kleine Dateien, Eigengröße). Schrumpfende Zweige zählen nicht dagegen, sonst würde ein gleichzeitig geleerter Ordner den Zuwachs woanders verdecken. Die Wurzel ist deshalb so groß wie der gesamte Brutto-Zuwachs, nicht wie das Netto-Delta. Der Baum ist ein normaler `ScanTree` (Wurzelpfad und Namen des neuen Baums); `entryForGrowth` bildet seine Indizes auf Vergleichseinträge ab.
- **„Größte Veränderungen“, tiefster aussagekräftiger Knoten:** Von der Wurzel abwärts wird der Brutto-Zuwachs betrachtet. Erklärt ein einzelnes Kind **mehr als die Hälfte** davon, steigt die Suche in alle Kinder mit mindestens `minimumDelta` (Standard 1 MB) ab und der Ordner selbst erscheint nicht; sonst ist der Zuwachs verteilt, und der Ordner erscheint. Die Einträge sind so nie Vorfahren voneinander. Beispiele: 20 GB in `~/Library/Caches/foo` (viele Dateien) → `foo`; ein neuer Ordner `x` mit fünf gleich großen Dateien → `x`; ein Ordner, in dem eine einzige große Datei dazukam → die Datei. Mit `growth: false` dasselbe für den Rückgang. Sortiert wird nach dem Brutto-Wert (`amount`), angezeigt wird zusätzlich das Netto-Delta.
- **Warnungen:** andere Scan-Optionen (versteckte Dateien, Ausschlussliste, Volumes), andere Scan-Wurzel, anderes Volume, unterschiedliche Mindestgröße (nur, wenn beide Seiten eine haben; ein frischer Scan ohne Mindestgröße ist der Normalfall).

### Performance-Tests im Release-Build
- Die Zielwerte (Einhängen unter 100 ms, Vergleich von 2 Mio. Knoten unter 2 s) gelten für das optimierte Programm. Der Debug-Build ist beim Vergleich etwa 15-mal langsamer (5,4 s). `scripts/check.sh` führt die Performance-Tests deshalb zusätzlich mit `swift test -c release -Xswiftc -enable-testing` aus; dort gilt die strenge Grenze, im Debug-Build eine lockere.

## API-Änderungen (für den Merge mit dem UI-Branch)

Keine bestehende öffentliche API wurde umbenannt oder entfernt. Geändert bzw. neu:

**Verhalten, das die Oberfläche betreffen kann**
- `ScanTree.nodes` kann nach `replacingSubtree`/`removingNode` tote Knoten (`NodeFlags.dead`) enthalten. Sie sind über `childIndices` nie erreichbar; wer `nodes` linear durchläuft (z. B. „größte Dateien“), muss sie überspringen. `count` zählt sie mit, `liveCount` nicht. Frische Scans und geladene Snapshots haben keine toten Knoten.
- Nach einer Änderung gilt „Eltern vor Kindern“ weiterhin, die globale Breitensuche-Reihenfolge aber erst wieder nach einer Kompaktierung.
- Ordnergrößen enthalten die Eigengröße des Ordners (auf APFS 0). Belegt ist ein Ordner damit *mindestens* die Summe seiner Kinder.
- `ScanOptions.snapshotDepth` ist standardmäßig 6 statt 3.
- `ScanEngine.events(_:)` puffert höchstens 8 Ereignisse (die neuesten bleiben); `ScanEvent` ist unverändert.
- `ScanTree.index(ofPath:)` und `NodeRef.child(named:)` vergleichen bei Bedarf kanonisch äquivalent (NFC/NFD) und akzeptieren den Wurzelpfad nur an Komponentengrenzen.

**Neu in bestehenden Typen**
- `NodeFlags.dead`
- `ScanProgress.activeWorkers: Int` (mit Standardwert 0; der memberwise-Initialisierer bleibt ohne den Parameter aufrufbar)
- `ScanEngine.eventBufferLimit` (statisch, 8)
- `ScanTree`: `isComplete`, `deadCount`, `liveCount`, `validate(limit:) -> [String]`, `childIndex(of:nameBytes:)`, `sortedChildIndices(of:by:)`, `itemCount(of:)`, `needsCompaction`, `compactionThreshold` (statisch), `replacingSubtree(at:with:compactIfNeeded:) -> TreeEdit`, `removingNode(at:compactIfNeeded:) -> TreeEdit`, `compacted() -> TreeEdit`
- `NodeRef`: `isDataless`, `isMountPoint`, `isHardlinkDuplicate`, `itemCount`, `children(sortedBy:)`
- `ScanEngine`: `rescanBlocking(subtree:in:cancellation:) -> RescanResult`, `rescan(subtree:in:) async -> RescanResult`, `rescanBlocking(path:in:cancellation:) -> RescanResult`

**Neue Typen**
- `TreeEdit` (`tree`, `index`, `allocatedBefore/After`, `logicalBefore/After`, `allocatedDelta`, `logicalDelta`, `compacted`, `translate(_:)`)
- `RescanResult` (`edit`, `tree`, `path`, `removed`, `unreadablePaths`, `scanDuration`, `mergeDuration`)
- `Snapshot`, `SnapshotMetadata` (`current(for:volume:name:date:)`), `SnapshotScanOptions`, `VolumeMetrics`, `SnapshotInfo`, `SnapshotError`, `SnapshotFile` (`encode`, `decode`, `readMetadata`, `normalized`), `SnapshotStore` (`save`, `condense`, `list`, `load`, `delete`, `rename`, `prune`, `defaultBaseDirectory`)
- `SnapshotDiff` (`entries`, `entryForOld/New`, `oldSize`, `newSize`, `delta`, `status`, `name(of:)`, `path(of:)`, `childEntries(of:)`, `childEntriesSortedByDelta(of:)`, `entry(forPath:)`, `largestChanges(limit:minimumDelta:growth:mode:)`, `growthTree(mode:)`, `summary`, `warnings`), `DiffEntry`, `DiffStatus`, `DiffChange`, `DiffSummary` (`headline`), `DiffWarning`

**Intern, aber vom UI-Branch genutzt und unverändert in der Signatur**
- `TreeBuilder.build(_:rootPath:…)` (neue optionale Parameter `hardlinks`, `indexMap` mit Standardwerten), `RawTree.append(…)`, `RawTree.reserve(_:nameBytes:)`. Der `ScanTreeBuilder` des UI-Branchs funktioniert damit unverändert.

## M2/M3 – Oberfläche und Sunburst

### Build ohne Xcode: `@State` als Makro
- Im SDK von macOS 27 ist `@State` zusätzlich ein Makro (`SwiftUIMacros.StateMacro`). Dessen Plugin liefern nur Xcode, nicht die Command Line Tools; `@State` bricht den Build daher mit „plugin for module 'SwiftUIMacros' not found“ ab.
- Lösung: `typealias ViewState<Value> = SwiftUI.State<Value>` (in `Sources/DiskRings/Support/Support.swift`) und überall `@ViewState` statt `@State`. Als Typalias greift der Property Wrapper, nicht das Makro. Mit Xcode funktioniert das genauso.

### Layout (`SunburstLayout`)
- Winkel im Bogenmaß, 0 = oben, im Uhrzeigersinn. Die Arcs werden ringweise in Breitensuche erzeugt; so ist jeder Ring nach Winkel sortiert (Voraussetzung für die binäre Suche im Hit-Test), und eine Obergrenze für die Arcs schneidet außen ab statt einseitig.
- **Obergrenze** (Standard 12 000 Arcs): Ein Ring, der sie sprengen würde, entfällt ganz. Nur der erste Ring wird gekürzt (Rest ins Sammelsegment).
- **Sammelsegment** je Elternknoten für alle Kinder unter der Schwelle; die Schwelle gilt in absoluten Grad (0,5°), wie in der Spec. Ein einzelnes zu kleines Element landet ebenfalls im Sammelsegment („1 kleineres Element“).
- **Restsegment** (zusätzlich zur Spec): Live-Snapshots enthalten nur Ordner, deren Größe schon die Dateien enthält. Die Differenz Ordnergröße − Summe der Kinder erscheint als graues Segment „Dateien in diesem Ordner“, damit die Winkel stimmen.
- Im Modus „belegt“ läuft die Berechnung nur bis zum ersten zu kleinen Kind (die Kinder sind sortiert); das Sammelsegment ist Elterngröße − platzierte Kinder. Damit ist das Layout O(Arcs). Im Modus „logisch“ werden die Kinder jedes sichtbaren Ordners einmal durchlaufen und die großen nach logischer Größe sortiert.
- Das Sammelsegment enthält auch eine eventuelle Eigengröße des Ordners (Live-Snapshots, künftig Ordner-Eigengröße). Ein eigenes Restsegment „Dateien in diesem Ordner“ gibt es nur, wenn keine weiteren Kinder übrig sind.
- Kinder mit Größe 0 bekommen nie einen Arc. Die Obergrenze für Arcs gilt hart (auch mit „Nicht zugeordnet“; bei `maxArcs = 1` bleibt nur dieses Segment). Bei inkonsistenten Bäumen (Kindersumme > Elterngröße) wird geklemmt, kein Kind ragt über den Eltern-Arc hinaus.
- Der Schwellenvergleich ist „≥“ mit einer relativen Toleranz von 10⁻⁹, damit ein Element genau auf der Schwelle trotz Gleitkomma-Rundung einzeln erscheint.
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
- „Rescan“ in der Toolbar liest seit M4 den fokussierten Ordner neu ein (Teil-Rescan, siehe unten); der komplette neue Scan steht im Menü des Knopfs und unter „Ablage → Komplett neu scannen“ (⌥⌘R). Der Fokus wird danach über den Pfad wiederhergestellt.

### Oberfläche
- Die Toolbar (Zurück/Vor, Breadcrumb, Rescan) liegt im Fensterinhalt statt in der `NSToolbar` des Fensters. Grund: So lässt sie sich in den Vorschaubildern mitrendern, und die Breadcrumb hat die volle Breite.
- Diagramm und Liste: seit M4 mit verstellbarer Listenbreite (siehe „M4/M5 – Oberfläche“).
- Die Detailliste ist eine eigene Outline aus `ScrollView` + `LazyVStack` (keine `List`/`OutlineGroup`): Prozentbalken, Farbfeld aus dem Diagramm und Hover-Sync sind so einfacher. Je Ebene höchstens 400 Zeilen, der Rest als eine Zeile „N kleinere Elemente“. An der Volume-Wurzel steht „Nicht zugeordnet“ als eigene Zeile, nach Größe einsortiert. Der Prozentwert einer Zeile bezieht sich auf ihren Elternordner.
- Die Liste zeigt ein Farbfeld nur für Knoten, die im Diagramm bis Ring 3 sichtbar sind.
- Das Fenster ist ein einzelnes `Window` (keine `WindowGroup`), damit die Menübefehle (⌘[ / ⌘] / ⌘↑) ohne Fokus-Verwaltung auf den einen `AppState` wirken.
- Kontextmenü: seit M4 vollständig, siehe „M4 – Kontextmenü“.
- Einstellungen, die schon wirken: Ringanzahl, Farbschema (mit Legende), Schwelle für das Sammelsegment (0,1–3°), Beschriftung an/aus, Größenmodus, versteckte Dateien, andere Volumes überqueren, Ausschlussliste. Die Scan-Optionen wirken beim nächsten Scan. Snapshot-Einstellungen fehlen noch (M6).

### Vorschaubilder (visuelle Prüfung)
- `DiskRings --render-snapshots <ordner> [--scan <pfad>]` rendert die Szenen hell und dunkel als PNG und beendet sich. Es gibt kein Test-Target für die App: Ein Test-Target, das vom ausführbaren SwiftUI-Target abhängt, wäre mit den Command Line Tools ein weiterer Sonderweg.
- Das Diagramm allein wird mit `ImageRenderer` gerendert. Ganze Ansichten (Hauptansicht, Start, Scan, Einstellungen) dagegen über ein unsichtbares Fenster mit `NSHostingView` und `cacheDisplay`: `ImageRenderer` zeichnet AppKit-gestützte Bausteine (Buttons, ScrollView, Form) nicht, dort erschienen nur gelbe Platzhalter.
- `ImageRenderer` löst dynamische `NSColor`s nicht nach dem Hell-/Dunkelmodus auf; der Hintergrund ist dort deshalb fest gesetzt.

### Bündel
- `scripts/make-app.sh` baut `build/DiskRings.app` (Release, Info.plist mit `de.stefanrichter.DiskRings`, `LSMinimumSystemVersion` 14.0) und signiert ad hoc. Developer ID, Hardened Runtime, Icon und Notarisierung kommen in M7.
- `--scan <pfad>` als Startargument startet sofort einen Scan (zum Testen: `open build/DiskRings.app --args --scan /usr/share`).

### Nachbesserungen nach der Prüfung (M2/M3)
- **Scan-Wettlauf:** Die Ereignisschleife liegt jetzt in `ScanController` (Core, testbar). Jeder Scan hat eine Generationsnummer; vor jeder Weitergabe und im Fehlerfall wird `Task.isCancelled` und die Generation geprüft. So überschreiben gepufferte Ereignisse eines abgebrochenen oder ersetzten Scans den neuen nicht mehr. Der Stream ist für Tests austauschbar; der Regressionstest arbeitet mit einem vorgefüllten Stream, weil sich der Wettlauf mit der echten Engine nicht zuverlässig auslösen lässt.
- **Prozentwerte:** Liste und Tooltip beziehen alle Anteile auf dieselbe Größe wie das Diagramm (`layout.totalSize`: der Fokus, an der Volume-Wurzel samt „Nicht zugeordnet“). Damit summiert sich die oberste Ebene zu 100 %. Auch aufgeklappte Unterzeilen zeigen den Anteil am Fokus, nicht am Elternordner. Der Tooltip schreibt „x % von <Fokus>“.
- **Beschriftung:** Zu lange Namen werden in einer Schleife gekürzt, bis sie passen (mindestens 4 Zeichen plus „…“). Geprüft mit einem Render von `/Applications`.
- **Wischgesten:** Zwei-Finger-Wischen über `trackSwipeEvent` (wenn „Zwischen Seiten blättern“ aktiv ist) und Drei-Finger-Wischen (`NSEvent.swipe`), Richtung wie in Safari. Nur in der Hauptansicht. Die Richtung ist nach der Dokumentation umgesetzt, aber nicht von Hand am Trackpad geprüft. Horizontales Wischen über der Breadcrumb navigiert ebenfalls, statt sie zu scrollen.
- **Volumes:** Die Liste aktualisiert sich bei `NSWorkspace.didMount`/`didUnmount`/`didRenameVolume`.
- **Liste:** Nur ein Klick-Handler; der Doppelklick wird über `NSEvent.clickCount` erkannt, sodass der Einzelklick nicht mehr auf den Doppelklick wartet.
- **Farben** werden je Layout (Baum, Fokus, Optionen, Schema, Modus) im `AppState` gecacht; Hover rechnet sie nicht mehr neu.
- **Bereinigbar** im Belegungsbalken: eigener Ton (`systemTeal`) statt halbtransparentem Akzent, gut sichtbar in beiden Modi.

## M4 – Kontextmenü, Papierkorb, Schutzliste; Teil-Rescan in der Oberfläche; M5-Rest

### Kontextmenü: zentrale, erweiterbare Struktur
- **Core:** `NodeAction` (Reihenfolge, Titel, SF-Symbol, `ActionShortcut`, Gruppen) und `NodeAction.availability(targets:context:) -> ActionAvailability` (an/aus plus Begründung für den Tooltip). Kontextmenü, Hauptmenü „Objekt“ und Tastenkürzel nutzen **dieselbe** Prüfung; `AppState.perform` prüft sie vor jeder Ausführung noch einmal. Damit wirkt auch ein Tastenkürzel auf einen geschützten Pfad nicht (SPEC 9).
- **App (`Browser/NodeContextMenu.swift`):** `ContextMenuRegistry.sections(for:state:)` liefert die Abschnitte. Eingebaut sind (IDs in dieser Reihenfolge) `open` (Finder, Öffnen, Quick Look), `navigate` (Hineinzoomen), `info` (Pfad kopieren, Informationen), `rescan`, `trash`. Ein Eintrag ist ein `ContextMenuItem` (`id`, `title(target, state)`, `systemImage`, `shortcut`, `availability(target, state)`, `perform(target, state)`, optional `showsReasonInline`); ein Abschnitt ist eine `ContextMenuSection` (`id`, `items`, optional `isVisible(target, state)`, z. B. „nur im Vergleichsmodus“).
- **Erweitern (z. B. Snapshots/Vergleich):** `ContextMenuRegistry.register(ContextMenuSection(...), before: "trash")` einmal beim Start aufrufen (z. B. im `init` der eigenen Komponente oder in `RootView.onAppear`); eine erneute Registrierung mit derselben ID ersetzt den Abschnitt, `unregister(id)` entfernt ihn. Am bestehenden Code muss dafür nichts geändert werden. Ziel eines Menüs ist ein `ContextMenuTarget` (`nodes` = alle Ziele, `clicked` = angeklickter Knoten); Knotenindizes beziehen sich auf `state.tree`. Ein Vergleichsmodus mit eigenem Baum braucht dafür ggf. eine Abbildung auf `state.tree` (z. B. über den Pfad).
- **Ziele:** Rechtsklick auf ein Element der Auswahl wirkt auf die ganze Auswahl, sonst nur auf das Element (wie im Finder). Hauptmenü und Kürzel wirken auf die Auswahl; „Neu scannen“ ohne Auswahl auf den Fokus.
- **Begründung bei ausgegrauten Einträgen:** `.help(...)` (Tooltip) und beim Papierkorb zusätzlich eine graue Textzeile unter dem Eintrag, weil Tooltips in Menüs erst verzögert erscheinen.
- **Tastenkürzel:** ⌘R, ⌥⌘C, ⌘I, ⇧⌘R, ⌘⌫ hängen am Menü „Objekt“. Steht der Cursor im Suchfeld, gehören die Tasten dem Textfeld (⌘⌫ löscht dann bis zum Zeilenanfang, ⌘Z/⇧⌘Z gehen an das Textfeld). Die **Leertaste** für Quick Look läuft über einen lokalen Tastatur-Monitor (`KeyboardMonitor`), weil ein Menü-Kürzel ohne Modifikator Leerzeichen im Suchfeld schlucken würde; im Menü steht zusätzlich ⌘Y wie im Finder.
- **Informationen (⌘I):** eigenes Info-Fenster (Ort, belegte/logische Größe, Inhalt, Daten, Kennzeichen, ggf. Schutzgrund). Die Spec erlaubt das; das Finder-Info-Fenster per AppleScript bräuchte die Automations-Freigabe.
- **Quick Look:** `QLPreviewPanel`; der `QuickLookController` hängt sich als Responder hinter das Fenster. Doppelklick auf eine Datei (Liste und Diagramm) öffnet Quick Look, Doppelklick auf einen Ordner zoomt hinein.
- Das Kontextmenü wird für die Vorschaubilder als `ContextMenuPreview` nachgebildet (gleiche Abschnitte, Titel, Kürzel, Verfügbarkeit); ein echtes `NSMenu` lässt sich offscreen nicht rendern.

### Papierkorb (SPEC 3.6)
- `TrashPlan.make` (Core) baut aus der Auswahl den Plan: nur die obersten Knoten (ein mit ausgewählter Unterordner wandert mit dem Vorfahren), Abbruch bei Scan-Wurzel, toten Knoten oder einem geschützten Pfad (die ganze Aktion ist dann aus, nicht nur das eine Element). Titel und Text des Dialogs kommen aus dem Plan.
- **„Nicht mehr fragen“** (`TrashConfirmation`): nur, wenn die Summe unter 1 GB (dezimal, 1 000 000 000 Byte) liegt; bei Mehrfachauswahl zählt die Summe. Als Größe gilt das Maximum aus belegter und logischer Größe, damit eine Sparse-Datei mit kleiner Belegung nicht durchrutscht. Die Einstellung lässt sich unter „Einstellungen → Papierkorb“ wieder abschalten.
- `TrashService` arbeitet über das Protokoll `FileTrashing` (`FileManager` erfüllt es; Tests nutzen einen Papierkorb im Temp-Verzeichnis). Gelöscht wird nur über `trashItem(at:resultingItemURL:)`. Der Dienst prüft die Schutzliste **ein zweites Mal**. Ein schon verschwundenes Element wird nicht als Fehler, sondern als „fehlt“ gemeldet und aus dem Baum entfernt.
- Danach `ScanTree.removingNodes(atPaths:)` → `TreeEditChain`; Fokus, Auswahl, Historie, aufgeklappte Ordner und Suchtreffer werden über `translate` nachgeführt (`AppState.applyEdit`).
- **Undo (⌘Z):** `TrashService.restore` legt per `moveItem` an den alten Ort zurück, überschreibt aber nie ein inzwischen dort liegendes Objekt und legt keinen fehlenden Elternordner an (dann Fehlermeldung). Danach Teil-Rescan des nächsten vorhandenen Vorfahren (des Elternordners). Der Undo-Stapel gilt pro Scan; ein neuer Scan leert ihn.
- **Papierkorb im Baum:** Liegt der Papierkorb-Ordner (z. B. `~/.Trash` beim Scan von „/“ oder „~“) im Baum, wird er nach Papierkorb und Undo still neu eingelesen; sonst stimmte die Summe nicht.
- **„Nicht zugeordnet“ nach dem Papierkorb:** wird aus den frischen Volume-Kennzahlen neu berechnet. Weil der Papierkorb auf demselben Volume liegt, bleibt „belegt“ gleich; liegt der Papierkorb nicht im Baum, wächst „Nicht zugeordnet“ deshalb um die verschobene Größe, bis der Papierkorb geleert wird. Das ist korrekt (der Platz ist noch belegt), wird aber im Hinweis nicht eigens erklärt.
- Fehlerbehebung im Core: `TreeEdit.translate` lieferte für einen mit `removingNode` entfernten Knoten das nachgerückte Geschwister statt `nil` (der tote Datensatz wurde verschoben, aber nicht als verschoben vermerkt).

### Schutzliste (`ProtectedPaths`, Core)
- Wie SPEC 3.6, dazu **Ordner, die einen geschützten Bereich enthalten** (z. B. `/Users`, `/Library`, `/private`, `/Applications` mit der laufenden App): Mit ihnen würde der geschützte Bereich mitverschoben. Das ist eine Erweiterung der Spec, die nur mehr schützt.
- Normalisierung vor dem Vergleich: `.`/`..`, Mehrfach- und Endschrägstriche, `/var|/etc|/tmp` → `/private/…`, Firmlink-Pfade unter `/System/Volumes/Data/…` → `/…`, Vergleich ohne Groß-/Kleinschreibung und NFC/NFD-unabhängig.
- Volume-Wurzeln über `getmntinfo`; die laufende App über `Bundle.main.bundlePath` (nur, wenn es ein `.app` ist; bei `swift run` gibt es keine).

### Teil-Rescan in der Oberfläche (SPEC 3.8)
- Rechtsklick → „Diesen Ordner neu scannen“, ⇧⌘R (Auswahl bzw. Fokus) und der Rescan-Knopf (Fokus).
- **Ablauf:** Der Ordner wird auf einem eigenen Thread mit den Optionen des ursprünglichen Scans gelesen (`PartialRescan.scan`); das Ergebnis wird erst beim Eintreffen in den **dann aktuellen** Baum eingehängt (`PartialRescan.merge`). Der vorhandene `ScanEngine.rescan(subtree:in:)` hängt dagegen in den Baum vom Start ein; zwei parallele Rescans würden sich damit gegenseitig überschreiben.
- **Spezialfälle** (`RescanQueue`, Core, getestet): Während eines vollständigen Scans gibt es keinen Teil-Rescan (Hinweis; Menüeintrag ausgegraut). Ein neuer vollständiger Scan bricht laufende Teil-Rescans ab. Derselbe Ordner oder ein Unterordner eines laufenden Rescans startet nicht doppelt. Ein Vorfahr ersetzt laufende Rescans seiner Unterordner (deren Ergebnis wird verworfen). Unabhängige Ordner laufen parallel. Existiert der Ordner nicht mehr, wird er entfernt („x: nicht mehr vorhanden (−…)“). Ist die Scan-Wurzel selbst verschwunden, bleibt der Baum unverändert, und eine Fehlermeldung erscheint.
- **Fortschritt:** Das Segment wird abgedunkelt und bekommt am Außenrand einen Fortschrittsring. Der Fortschritt wird aus den bisher gelesenen Bytes und der alten Größe geschätzt (höchstens 97 %); bei alter Größe 0 läuft ein unbestimmter Bogen um. Ist der Ordner nicht als Segment sichtbar, trägt sein nächster sichtbarer Vorfahr den Ring, beim Fokus selbst die Mitte. In der Liste steht statt der Größe ein kleiner Fortschrittskreis. Die App bleibt bedienbar.
- **Hinweis:** „Name: alt → neu (±Δ)“ als Toast unten im Diagramm (ohne Änderung „Name: x (unverändert)“).
- Die Kompaktierung läuft wie im Core vorgesehen sofort beim Einhängen (`compactIfNeeded: true`), nicht im Hintergrund; bei den gemessenen Zeiten (siehe M6) war das nicht nötig.

### Animation nach Änderungen (`EditTransition`, Core)
- Nach Papierkorb, Teil-Rescan und Undo werden Arcs über die Index-Übersetzung zugeordnet: Gleiche Knoten wandern von alter zu neuer Lage, entfernte schrumpfen auf ihre Mitte und blenden aus, neue wachsen aus ihrer Mitte (450 ms). Sammel- und Restsegmente werden über ihren Elternknoten zugeordnet. Die Farben des Ausgangsbilds kommen aus dem alten Baum (`ActiveTransition.fromTree`). Bei „Bewegung reduzieren“ entfällt die Animation.

### M4/M5 – Oberfläche
- **Verstellbare Liste:** eigener Teiler (1 pt Linie, 7 pt Griff, Doppelklick = 400 pt) statt `HSplitView`, Breite 300–720 pt, in den Einstellungen gespeichert. `HSplitView` übernahm die Startbreite nicht (die Liste startete mit Minimal- oder halber Fensterbreite) und kürzte die Namen in den Vorschaubildern auf wenige Zeichen.
- **Mehrfachauswahl** in der Liste (`NodeSelection`, Core): Klick wählt aus, ⌘-Klick schaltet um, ⇧-Klick wählt den Bereich der sichtbaren Zeilen ab dem Anker. Das Diagramm umrandet alle ausgewählten Segmente.
- **Suche** (Lupe in der Toolbar, ⌘F): Teilzeichenfolge im ganzen Baum ohne Groß-/Kleinschreibung und Akzente (`TreeSearch`, Core; 2 Mio. Knoten in rund 40 ms im Release-Build). Die Treffer (größte zuerst, höchstens 300) ersetzen rechts die Liste; ein Klick fokussiert den Elternordner, wählt den Treffer aus und klappt die Liste bis dorthin auf; ⏎ springt zum größten Treffer, Esc schließt die Suche.
- **M5-Prüfung:** „Nicht zugeordnet“ (Segment, Listenzeile, Statusleiste) und Live-Update während des Scans waren vollständig. Ergänzt: Statusleiste mit Hinweis-Symbol „Klone und Snapshots können Abweichungen verursachen“ (SPEC 4.1 Punkt 3, vorher nur im Tooltip von „nicht zugeordnet“), Hinweis „Kein Festplattenvollzugriff“ in der Statusleiste der Hauptansicht (vorher nur auf dem Startbildschirm und in der aufgeklappten Scan-Zusammenfassung), Neuberechnung von „Nicht zugeordnet“ nach Änderungen und bei Rückkehr in die App, Volume-Kennzahlen schon während des Scans.

### API-Änderungen M4 (Core)
- Neu: `ProtectedPaths` (`reason(for:)`, `isProtected`, `Reason.message`, `mountedVolumeRoots()`, `runningAppBundlePath()`), `NodeSelection`, `NodeAction`, `ActionShortcut`, `ActionAvailability`, `ActionContext`, `FileTrashing` (mit `FileManager`-Konformität), `TrashItem`, `TrashPlan`, `TrashPlanError`, `TrashConfirmation`, `TrashRecord`, `TrashFailure`, `TrashOutcome`, `RestoreOutcome`, `TrashService`, `TreeEditChain`, `ScanTree.removingNodes(_:)`/`removingNodes(atPaths:)`, `FocusHistory.translated(from:by:)`, `RescanQueue`, `RescanMerge`, `PartialRescan` (`scan`, `merge`, `summary`, `estimatedProgress`), `EditTransition`, `TreeSearch`.
- Geändert: `ScanEngine.nearestExistingIndex(of:in:)` ist öffentlich; `TreeEdit.translate` liefert für entfernte Knoten zuverlässig `nil` (Fehlerbehebung, siehe oben).
- App: `AppState.selected` ist jetzt eine berechnete Eigenschaft über `selection` (Mehrfachauswahl); `ActiveTransition` hält statt `zoom` ein `animation: any LayoutTransition` und `fromTree`; `BrowserBody` liegt jetzt in `BrowserView.swift`.

## M6 – Snapshots und Vergleich (Oberfläche)

### Aufteilung
- Logik in Core (getestet): `CompareModel` (Anzeigebäume, Fokus, Layout, Arc/Hit-Test → Vergleichseintrag, Delta-Farben, Sortierung, Breadcrumb), `CompareHeadline`, `DeltaScale` und die Delta-Farben in `Palette+Delta.swift`, `SnapshotRetention`, `SnapshotMatching`, `SnapshotNaming`, `SnapshotStore.saveAndPrune/autoSave`, `CompareDemo` (Beispielbaum).
- Oberfläche in neuen Dateien: `Sources/DiskRings/Snapshots/SnapshotLibrary.swift` (Einstellungen, Ablage, Speichern), `Snapshots/SnapshotsWindow.swift` (Fenster, ⌘S-Dialog, Menübefehle, Einstellungsabschnitt), `Compare/*` (Vergleichsmodus, Toolbar-Button, Vorschaubilder).
- Bestehende Dateien haben nur kleine Haken bekommen (Liste im Merge-Abschnitt unten).

### Vergleichsmodus
- **Fokus als Vergleichseintrag:** Navigation, Liste und Breadcrumb arbeiten auf `SnapshotDiff.entries`, nicht auf Knoten eines Baums. So bleibt der Fokus beim Umschalten zwischen „Wachstum“ und „Delta-Färbung“ erhalten. Fehlt der Eintrag im Wachstumsbaum (kein Zuwachs), zeigt das Diagramm den nächsten vorhandenen Vorfahren.
- **Delta-Färbung braucht einen eigenen Baum:** Entfernte Elemente haben im neuen Baum keine Größe und damit keinen Winkel. Der „Vergleichsbaum“ enthält alle Einträge; bestehende mit ihrer neuen Größe, entfernte mit der alten. Ein Ordner ist damit so groß wie jetzt plus die darin entfernten Teilbäume. Abweichung von „normale Ansicht“: Die Winkel weichen um die entfernten Elemente von der normalen Ansicht ab; dafür sind entfernte Elemente (grau gestrichelt) sichtbar, wie die Spec es verlangt.
- **Wachstum:** Segmentgröße = Brutto-Zuwachs (`growthTree`), gefärbt mit dem normalen Farbschema (Ast bzw. Dateityp), neue Elemente mit Punkt. Die Mitte zeigt „+X Zuwachs“; das kann größer sein als das Netto-Δ in der Liste (z. B. Downloads +70 MB Zuwachs, Δ +62 MB, weil eine Datei kleiner wurde). Der Tooltip zeigt beides.
- **Delta-Farben:** Rot (Farbton 4°) gewachsen und neu, Grün (142°) geschrumpft, Grau unverändert, sehr helles bzw. sehr dunkles Grau mit gestricheltem Rand für entfernt, Punkt in Kontrastfarbe für neu. Intensität: Wurzelskala zwischen 0,15 und 1, Referenz ist die größte Änderung im ersten Ring des aktuellen Layouts. Eine logarithmische Skala (erster Versuch) ließ in der Vorschau fast alle gewachsenen Ordner gleich rot erscheinen.
- **Kopfzeile:** An der Volume-Wurzel wie in der Spec („belegt · frei · davon nicht zugeordnet“). Bei einem Ordner-Scan steht zuerst das Δ des Ordners (Scan-Summe), dann „Volume belegt“ und „frei“, weil „belegt“ sonst das ganze Volume meint und mit dem Ordner nichts zu tun haben muss. Zwei Snapshots: „Von … bis …“.
- **Liste:** Eigene Outline (`CompareListView`) statt Erweiterung der `DetailListView`, mit den Spalten Name, Vorher, Jetzt, Δ; Klick auf die Überschrift sortiert (gleiche Spalte dreht die Richtung). Standard: Δ absteigend. Entfernte Einträge durchgestrichen.
- **„Größte Veränderungen“** ist ein Tab der rechten Spalte (neben „Inhalt“), mit Umschalter Zuwachs/Rückgang. Klick auf eine Zeile zoomt in deren Elternordner und wählt sie aus.
- **Kein Zoom-Übergang** im Vergleichsmodus (der Fokus springt). Das Menü „Gehe zu“ (⌘[ / ⌘] / ⌘↑) und die Wischgesten wirken im Vergleich auf den Vergleich (seit der Integration, siehe unten); zusätzlich gibt es eigene Zurück/Vor-Knöpfe.
- Der Vergleich wird im Hintergrund berechnet (`Task.detached`), mit Hinweis „Vergleich wird berechnet…“. Der Vergleich nutzt den aktuellen Baum (`AppState.tree`), nicht `result.tree`, damit spätere Änderungen durch Papierkorb oder Teil-Rescan enthalten sind. Ändert sich der Baum während des Vergleichs (Papierkorb, Undo, Teil-Rescan), wird der Vergleich neu berechnet (siehe „Integration M4/M6“).
- „Vergleichen mit…“ bietet nur Snapshots an, die **vor** dem Ende des aktuellen Scans entstanden sind; der automatisch gespeicherte Snapshot des aktuellen Scans ergäbe überall 0.

### Snapshots speichern und verwalten
- Automatisch nach jedem vollständigen Scan (`AppState.finish`), abschaltbar; manuell mit „Ablage → Snapshot sichern…“ (⌘S, ersetzt den Menüpunkt „Sichern“) und optionalem Namen. Nach jedem Speichern wird auf die Höchstzahl pro Scan-Wurzel aufgeräumt (Standard 20, Bereich 1–500). Auch benannte Snapshots werden dabei gelöscht, wenn sie die ältesten sind (so steht es in der Spec; ein Schutz für benannte Snapshots wäre eine Erweiterung).
- Fenster „Snapshots“ (Menü „Ablage → Snapshots…“, ⌥⌘S): Tabelle mit Datum, Name, Scan-Wurzel, Gesamtgröße und Dateigröße; Umbenennen, Löschen (Bestätigungsdialog; gelöscht wird nur die `.drsnap`-Datei in der Ablage, über `SnapshotStore.delete`), Im Finder zeigen, „Vergleichen“ bei genau zwei ausgewählten (der ältere ist „vorher“).
- Einstellungen: neuer Abschnitt „Snapshots“ (automatisch speichern, Höchstzahl), Schlüssel `snapshotAutoSave`, `snapshotMaxCount`.
- `SnapshotLibrary` greift beim Anlegen nicht auf die Platte zu; die Vorschaubilder tauschen die Ablage gegen einen temporären Ordner aus. Tests verwenden nie `~/Library/Application Support/DiskRings`.

### Kontextmenü im Vergleichsmodus (Anforderungen; umgesetzt, siehe „Integration M4/M6“)
Ursprünglich ohne Kontextmenü (die zentrale Struktur entstand parallel in M4). Nötig sind dort:
- Für Einträge, die im aktuellen Baum existieren (Status neu, gewachsen, geschrumpft, unverändert): alle Einträge aus SPEC 3.5, ausgeführt auf dem Knoten `state.tree.index(ofPath: diff.path(of: entry))` – also Im Finder zeigen, Öffnen, Quick Look, Hier hineinzoomen (im Vergleich: `CompareSession.navigate`), Pfad kopieren, Informationen, Diesen Ordner neu scannen, In den Papierkorb legen. Nach Papierkorb/Teil-Rescan muss der Vergleich neu berechnet werden (siehe oben).
- Für entfernte Einträge: nur „Pfad kopieren“ und „Hier hineinzoomen“; Finder, Öffnen, Quick Look, Info, Rescan und Papierkorb ausgegraut (Datei existiert nicht mehr).
- Beim Vergleich zweier Snapshots ohne aktuellen Scan: nur Aktionen, die auf dem Dateisystem funktionieren, wenn der Pfad noch existiert; Papierkorb ausgegraut, weil der Baum nicht aktualisiert werden kann.
- Zusätzlich sinnvoll: „Im Vergleich hineinzoomen“ und für Zeilen in „Größte Veränderungen“ „Im Diagramm zeigen“.
- Anschlussstellen: `CompareSunburstInteraction` (Hover-Eintrag `session.hoverEntry`) und `CompareRowView`/`LargestChangeRow`.

### Vorschaubilder
- `DiskRings --render-snapshots <ordner> --compare-demo` legt den Beispielbaum in einem temporären Ordner an, speichert Snapshots in eine temporäre Ablage, verändert den Baum, scannt neu und rendert hell und dunkel: `compare-growth`, `compare-growth-downloads`, `compare-delta`, `compare-largest`, `compare-largest-shrink`, `compare-two-snapshots-warning`, `compare-browser-toolbar`, `compare-picker`, `snapshots-window`, `snapshot-save-sheet`, `settings-snapshots`. Der temporäre Ordner wird danach gelöscht. Volume-Kennzahlen und Zeitpunkte sind fest vorgegeben (die Beispielwurzel gilt als Volume-Wurzel „Macintosh HD“), damit die Kopfzeile reproduzierbar ist.
- Der Tooltip in `compare-growth` steht nur ungefähr am Segment (die Mausposition wird aus einer geschätzten Diagrammgröße berechnet).

### Merge-Haken in bestehenden Dateien
- `App/AppState.swift`: Eigenschaften `snapshots` und `compare`; `compare = nil` in `startScan` und `backToStart`; `snapshots.didFinishScan(…)` am Ende von `finish`.
- `App/Preferences.swift`: `let snapshots: SnapshotPreferences` und dessen Initialisierung.
- `App/DiskRingsApp.swift`: `--compare-demo` in `Entry.main`; `SnapshotCommands` in `.commands`; Szene `Window("Snapshots")`; `.modifier(SnapshotUIHost(state:))` in `RootView`.
- `Browser/BrowserView.swift`: `CompareToolbarButton` in `BrowserToolbar`; `.modifier(CompareModeSwitch(…))` am Ende von `BrowserView.body`.
- `Settings/SettingsView.swift`: `SnapshotSettingsSection(prefs: prefs.snapshots)` nach dem Abschnitt „Scan“.
- Core: keine bestehende API geändert; neu sind die oben genannten Typen und `DiffStatus.label`.

## Integration M4/M6 (nach dem Merge)

### Merge
- Konflikte nur an den in „Merge-Haken“ genannten Stellen. `CompareModeSwitch` sitzt in `BrowserView` **vor** den Sheets für Papierkorb und Info, sonst würde der Vergleich sie mit ausblenden. Der Vergleichsknopf steht links neben dem Rescan-Menü aus M4. Der Vergleich übergibt dem Renderer die Auswahl als Menge (`selected`/`primarySelected`, API aus M4).

### Kontextmenü im Vergleich
- Core: `CompareActions` (`node(forEntry:diff:in:)`, `nodes(forEntries:context:)`, `availability(_:entries:context:)`) mit `CompareActionContext`. Vergleichseinträge werden über den Pfad auf den **aktuellen** Baum abgebildet und dann mit `NodeAction.availability` geprüft, also auch gegen die Schutzliste (SPEC 9). Entfernte Einträge: nur „Pfad kopieren“ und „Hineinzoomen“, alle anderen ausgegraut mit „„x“ existiert nicht mehr (seit dem Snapshot entfernt)“. Vergleich zweier Snapshots: Finder/Öffnen/Quick Look nur, wenn der Pfad auf dem Datenträger existiert; Info, Rescan und Papierkorb aus („Beim Vergleich zweier Snapshots nicht möglich“). Ein Eintrag, den es im aktuellen Baum nicht mehr gibt (Neuberechnung steht noch aus), ist aus („Nicht mehr im aktuellen Scan“).
- App: `ContextMenuTarget.compareEntries` kennzeichnet ein Ziel im Vergleich. Die eingebauten Abschnitte sind dann ausgeblendet; `Compare/CompareContextMenu.swift` registriert über `ContextMenuRegistry.register(_:before:)` je einen Abschnitt `compare.open|navigate|info|rescan|trash` (gleiche Reihenfolge, Titel, Symbole und Kürzel) plus „Im Diagramm zeigen“ (für „Größte Veränderungen“). Kontextmenüs hängen am Vergleichsdiagramm (Segment bzw. Mitte), an den Zeilen der Vergleichsliste und an „Größte Veränderungen“. Die Kopfzeile zeigt bei entfernten Elementen „(entfernt)“.
- Hauptmenü „Objekt“, Tastenkürzel und Leertaste wirken im Vergleich auf den ausgewählten Vergleichseintrag (⇧⌘R ohne Auswahl auf den Fokus), nicht auf die verdeckte normale Ansicht; sonst hätte z. B. ⌘⌫ ein unsichtbar ausgewähltes Element gelöscht.
- Vorschaubild `compare-contextmenu` (bestehender Ordner, entferntes Element, zwei Snapshots).

### Neuberechnung nach Änderungen
- `AppState.applyEdit` (gemeinsamer Weg von Papierkorb, Teil-Rescan und dem Teil-Rescan nach Undo) ruft `scheduleCompareRefresh()`. Nur Vergleiche „Snapshot ↔ aktueller Scan“ (`CompareSource.currentScan`) werden neu berechnet; der alte Snapshot steckt schon im Diff (`diff.old`), es wird nichts neu geladen. Mehrere Änderungen innerhalb von 250 ms ergeben eine Berechnung (Generationszähler); ein inzwischen beendeter oder ersetzter Vergleich wird nicht überschrieben.
- Ansicht, Sortierung, Tab, Fokus, Historie, Auswahl und aufgeklappte Ordner werden über `CompareEntryMapping` (Core, Pfad-Zuordnung; fehlender Fokus → nächster vorhandener Vorfahr) übernommen. Dazu neu: `FocusHistory.translated(current:by:)`.

### Navigation
- `AppState.navigateBack/Forward/Up/ToRoot` und `canNavigate…` leiten im Vergleich an `CompareSession` weiter; Menü „Gehe zu“ und `SwipeNavigation` nutzen nur noch diese. ⇧⌘↑ heißt im Vergleich „Zur Vergleichswurzel“.

### Startbildschirm
- Das App-Icon (`NSApp.applicationIconImage`, wenn das Bündel eins hat) ersetzt das Kreis-Symbol. Bei `swift run` und in den Vorschaubildern gibt es kein Bündel-Icon; dann wird `Resources/DiskRings.icns` über `#filePath` aus dem Quellbaum geladen (nur Entwicklung; im Bündel greift immer der erste Weg).

## M7 – Distribution

### Icon
- Das Icon wird programmatisch mit CoreGraphics gezeichnet (`swift scripts/make-icon.swift`): drei Sunburst-Ringe mit fünf Ästen auf einem dunklen, abgerundeten Quadrat (Superellipse im 824/1024-Raster der macOS-Icons). Für 16 und 32 px gibt es vereinfachte Varianten (ein bzw. zwei Ringe, breitere Fugen), sonst verschwimmen die Segmente. `iconutil` macht daraus `Resources/DiskRings.icns`, die eingecheckt ist; das iconset liegt nur in `build/`. Kein Asset-Katalog (`actool` gibt es nur mit Xcode).

### Bündel und Signatur (`scripts/make-app.sh`)
- **Universal:** `swift build -c release --arch arm64 --arch x86_64` funktioniert mit den Command Line Tools (Swift 6.4). Produkt liegt dann unter `.build/out/Products/Release`. Falls der Universal-Build einmal scheitert, fällt das Skript mit Warnung auf die Rechner-Architektur zurück.
- **Version** aus der Datei `VERSION`, Build-Nummer = `git rev-list --count HEAD`.
- **Signatur:** Developer ID mit Hardened Runtime (`--options runtime --timestamp`). **Keine Entitlements:** Die App ist nicht sandboxed, nutzt weder JIT noch Apple Events. Sollte „Informationen“ (SPEC 3.5) später per `NSAppleScript` umgesetzt werden, braucht es `com.apple.security.automation.apple-events` und `NSAppleEventsUsageDescription`.
- codesign läuft mit einem Zeitlimit (60 s), weil ein Schlüsselbund-Dialog es sonst unbemerkt hängen lässt. Fehlt die Identität oder ist `DISKRINGS_ADHOC=1` gesetzt, wird ad hoc signiert.

### Release (`scripts/release.sh`)
- Zwei Notarisierungen: zuerst die App (als ZIP eingereicht), damit das endgültige ZIP und das DMG die geheftete App enthalten; danach das signierte DMG, damit auch dieses ein Ticket bekommt.
- Das Profil `diskrings` wird erst unmittelbar vor der Notarisierung geprüft, damit Tests und Bündel vorher schon laufen; fehlt es, bricht das Skript mit der `store-credentials`-Anleitung ab.
- `gh release create` nur mit `--publish`, nur bei sauberem Arbeitsverzeichnis und neuem Tag.

### CI
- `Package.swift` setzt `-plugin-path` jetzt nur, wenn die Command Line Tools die aktive Toolchain sind (erkannt über `SDKROOT`, das SwiftPM beim Auswerten des Manifests setzt; Rückfall `DEVELOPER_DIR` bzw. `/var/db/xcode_select_link`). Grund: GitHub-Runner haben Xcode **und** die CLT installiert; die alte Bedingung („Pfad existiert“) hätte dort Xcodes Compiler das Makro-Plugin einer anderen Swift-Version untergeschoben. Die CI prüft das mit `swift package dump-package`.
- Die Performance-Tests laufen in der CI nicht (`swift test --skip 'Performance|performance'`): Die Grenzen sind auf einem lokalen Apple-Silicon-Rechner kalibriert, die geteilten Runner schwanken zu stark. Sie bleiben in `scripts/check.sh`.

## Nachbesserungen nach der Abnahmeprüfung

### Papierkorb: Identität beim Undo, aufgelöste Pfade
- **Undo prüft die Identität.** Beim Verschieben merkt sich `TrashRecord.identity` (`FileIdentity`: Gerät und Inode per `lstat`, das entspricht `volumeIdentifier` plus `fileResourceIdentifier`; bei Dateien zusätzlich Größe und Änderungsdatum in ns). `restore` legt nur zurück, wenn das Element unter der Papierkorb-Adresse dieselbe Identität hat; sonst „Im Papierkorb liegt unter diesem Namen inzwischen ein anderes Objekt …“ und das fremde Element bleibt im Papierkorb. Ohne gemerkte Identität gibt es kein Undo. Bei Ordnern zählen Größe und Änderungsdatum nicht, weil der Finder beim Öffnen des Papierkorbs darin `.DS_Store` anlegen kann. Eine im Papierkorb veränderte Datei wird damit ebenfalls nicht zurückgelegt; das ist Absicht (lieber kein Undo als ein falsches).
- `FileTrashing` hat dafür `identity(atPath:)` und `resolvedPath(_:)` bekommen, beide mit Standard-Implementierung (`lstat`, `realpath`), damit eigene Test-Papierkörbe nichts ändern müssen.
- **Aufgelöster Pfad vor `trashItem`.** `TrashPlan` trägt die Scan-Wurzel (`rootPath`, von `TrashPlan.make` gesetzt). `TrashService` löst die Elternkette mit `realpath` auf (das letzte Element selbst nicht: ein Symlink wird als Symlink verschoben) und prüft den Ergebnis-Pfad noch einmal gegen die Schutzliste. Mit Wurzel muss der aufgelöste Pfad außerdem genau „aufgelöste Wurzel + relativer Pfad“ sein (Vergleich normalisiert wie in `ProtectedPaths`). Weil der Scanner keinen Symlinks folgt, gibt es unterhalb der Wurzel keinen legitimen Symlink im Pfad; ein Symlink im Pfad der Wurzel selbst (z. B. `/tmp`) bleibt erlaubt. Pläne ohne Wurzel (nur in Tests) prüfen nur die Schutzliste.

### Snapshots: beschädigte Dateien, Umbenennen, atomares Speichern
- `SnapshotStore.listAll()` teilt die `.drsnap`-Dateien in lesbare (`SnapshotInfo`) und beschädigte (`DamagedSnapshot`: URL, Dateigröße, Grund, Metadaten falls der Kopf lesbar ist). Geprüft werden Vorspann, Kopf und die **Dateilänge laut Längenangabe** (`SnapshotFile.inspect`); damit fällt eine abgeschnittene Datei auf, ohne die Nutzdaten zu lesen. Die Prüfsumme wird weiterhin erst beim Laden geprüft (20 × 15 MB bei jedem Öffnen der Liste zu lesen wäre zu teuer); ein Snapshot mit richtiger Länge, aber verfälschten Bytes erscheint deshalb normal und meldet den Fehler beim Vergleichen.
- Das Fenster „Snapshots“ zeigt beschädigte Dateien unter der Tabelle mit Kennzeichen „beschädigt“, Grund, Größe, „Im Finder zeigen“ und „Löschen…“ (mit Bestätigung; gelöscht wird nur innerhalb der Ablage).
- `prune` räumt beschädigte Dateien mit auf: solche derselben Scan-Wurzel (Kopf lesbar) und solche ohne lesbaren Kopf im Ordner des Volumes. Sie stehen nicht in der Rückgabe (keine `SnapshotInfo`).
- **Speichern** schreibt erst eine versteckte temporäre Datei (`.<uuid>.tmp`) und benennt sie dann mit `renamex_np(RENAME_EXCL)` um. Vorher wurde direkt in die `.drsnap` geschrieben; ein gleichzeitiges `prune` (automatisches und manuelles Speichern laufen parallel) hätte die halb geschriebene Datei jetzt für beschädigt gehalten und gelöscht.
- **Umbenennen** schreibt nur den Kopf neu (`SnapshotFile.replacingHeader`): Längenangaben, Prüfsumme und komprimierte Nutzdaten werden unverändert kopiert, nicht dekomprimiert. Weil der Kopf variabel lang vor den Nutzdaten steht, wird die Datei trotzdem einmal (atomar) neu geschrieben; das läuft in der App im Hintergrund (`Task.detached`), nicht mehr auf dem MainActor. Eine abgeschnittene Datei lässt sich nicht umbenennen und bleibt unverändert.
