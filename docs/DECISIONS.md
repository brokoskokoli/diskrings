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
- Standard: Anzahl Performance-Kerne (`hw.perflevel0.physicalcpu`), höchstens 8.
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
