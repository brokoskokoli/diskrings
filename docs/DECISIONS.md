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

### Nachbesserungen nach der Prüfung (M2/M3)
- **Scan-Wettlauf:** Die Ereignisschleife liegt jetzt in `ScanController` (Core, testbar). Jeder Scan hat eine Generationsnummer; vor jeder Weitergabe und im Fehlerfall wird `Task.isCancelled` und die Generation geprüft. So überschreiben gepufferte Ereignisse eines abgebrochenen oder ersetzten Scans den neuen nicht mehr. Der Stream ist für Tests austauschbar; der Regressionstest arbeitet mit einem vorgefüllten Stream, weil sich der Wettlauf mit der echten Engine nicht zuverlässig auslösen lässt.
- **Prozentwerte:** Liste und Tooltip beziehen alle Anteile auf dieselbe Größe wie das Diagramm (`layout.totalSize`: der Fokus, an der Volume-Wurzel samt „Nicht zugeordnet“). Damit summiert sich die oberste Ebene zu 100 %. Auch aufgeklappte Unterzeilen zeigen den Anteil am Fokus, nicht am Elternordner. Der Tooltip schreibt „x % von <Fokus>“.
- **Beschriftung:** Zu lange Namen werden in einer Schleife gekürzt, bis sie passen (mindestens 4 Zeichen plus „…“). Geprüft mit einem Render von `/Applications`.
- **Wischgesten:** Zwei-Finger-Wischen über `trackSwipeEvent` (wenn „Zwischen Seiten blättern“ aktiv ist) und Drei-Finger-Wischen (`NSEvent.swipe`), Richtung wie in Safari. Nur in der Hauptansicht. Die Richtung ist nach der Dokumentation umgesetzt, aber nicht von Hand am Trackpad geprüft. Horizontales Wischen über der Breadcrumb navigiert ebenfalls, statt sie zu scrollen.
- **Volumes:** Die Liste aktualisiert sich bei `NSWorkspace.didMount`/`didUnmount`/`didRenameVolume`.
- **Liste:** Nur ein Klick-Handler; der Doppelklick wird über `NSEvent.clickCount` erkannt, sodass der Einzelklick nicht mehr auf den Doppelklick wartet.
- **Farben** werden je Layout (Baum, Fokus, Optionen, Schema, Modus) im `AppState` gecacht; Hover rechnet sie nicht mehr neu.
- **Bereinigbar** im Belegungsbalken: eigener Ton (`systemTeal`) statt halbtransparentem Akzent, gut sichtbar in beiden Modi.
