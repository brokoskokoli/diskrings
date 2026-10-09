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
