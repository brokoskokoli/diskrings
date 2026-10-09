import DiskRingsCore
import Foundation

let usage = """
Verwendung:
  diskrings-cli scan <pfad> [--top N] [--depth D] [--json] [--logical]
                            [--no-hidden] [--exclude PFAD]... [--workers N]
                            [--cross-mounts] [--progress] [--live [--live-depth K]]
  diskrings-cli volumes [--json]
  diskrings-cli snapshot save <pfad> [--name NAME] [--dir VERZ] [--min-size BYTE]
                                     [--no-hidden] [--exclude PFAD]... [--workers N]
  diskrings-cli snapshot list [--dir VERZ]
  diskrings-cli diff <snapshotA> [<snapshotB> | --scan <pfad>] [--top N] [--dir VERZ]

  scan      Scannt <pfad> und gibt Gesamtsumme, Dateianzahl, Dauer und die
            größten Ordner aus (Standard: --top 10 --depth 1).
  volumes   Listet die eingehängten Volumes.
  snapshot  save: scannt <pfad> und speichert einen Snapshot (Standard-Ablage
            ~/Library/Application Support/DiskRings/Snapshots, Dateien unter
            1 MB nur in der Ordnersumme). list: zeigt alle Snapshots.
  diff      Vergleicht Snapshot A mit Snapshot B oder mit einem frischen Scan
            (Standard: --scan mit der Scan-Wurzel von A) und zeigt die
            größten Veränderungen (Standard: --top 20). Snapshots werden als
            Datei (.drsnap) oder über den Anfang ihrer ID aus „snapshot list“
            angegeben.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Fehler: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

struct ScanArgs {
    var path: String?
    var top = 10
    var depth = 1
    var json = false
    var logical = false
    var progress = false
    var live = false
    var options = ScanOptions()
}

func parseScan(_ args: ArraySlice<String>) -> ScanArgs {
    var a = ScanArgs()
    var it = args.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) erwartet einen Wert") }
        return v
    }
    func int(_ flag: String) -> Int {
        guard let v = Int(value(flag)), v >= 0 else { fail("\(flag) erwartet eine Zahl ≥ 0") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--top": a.top = int(arg)
        case "--depth": a.depth = int(arg)
        case "--json": a.json = true
        case "--logical": a.logical = true
        case "--progress": a.progress = true
        case "--live": a.live = true
        case "--live-depth": a.options.snapshotDepth = int(arg)
        case "--no-hidden": a.options.includeHidden = false
        case "--cross-mounts": a.options.crossMountPoints = true
        case "--exclude": a.options.excludedPaths.append(value(arg))
        case "--workers": a.options.workerCount = max(1, int(arg))
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("--") { fail("Unbekannte Option \(arg)") }
            if a.path != nil { fail("Nur ein Pfad erlaubt") }
            a.path = arg
        }
    }
    return a
}

// MARK: - Ausgabe

struct TopEntry: Encodable {
    let path: String
    let name: String
    let allocatedSize: UInt64
    let logicalSize: UInt64
    let fileCount: Int
    let isDirectory: Bool
    let flags: [String]
    let children: [TopEntry]?
}

struct VolumeJSON: Encodable {
    let name: String
    let path: String
    let uuid: String?
    let total: UInt64
    let available: UInt64
    let availableForImportantUsage: UInt64
    let used: UInt64
}

struct ScanJSON: Encodable {
    let root: String
    let allocatedSize: UInt64
    let logicalSize: UInt64
    let fileCount: Int
    let directoryCount: Int
    let durationSeconds: Double
    let workers: Int
    let nodeCount: Int
    let treeBytes: Int
    let hardlinkDuplicates: Int
    let unreadablePaths: [String]
    let skippedMountPoints: [String]
    let volume: VolumeJSON?
    let unassigned: UInt64?
    let top: [TopEntry]
}

func flagNames(_ f: NodeFlags) -> [String] {
    var out: [String] = []
    if f.contains(.package) { out.append("paket") }
    if f.contains(.symlink) { out.append("symlink") }
    if f.contains(.unreadable) { out.append("nicht-lesbar") }
    if f.contains(.dataless) { out.append("nur-in-cloud") }
    if f.contains(.hardlinkDuplicate) { out.append("hardlink-duplikat") }
    if f.contains(.mountPoint) { out.append("einhaengepunkt") }
    if f.contains(.hidden) { out.append("versteckt") }
    return out
}

func topEntries(_ node: NodeRef, top: Int, depth: Int, mode: SizeMode) -> [TopEntry] {
    guard depth > 0 else { return [] }
    // Kinder sind nach belegter Größe sortiert; im logischen Modus neu sortieren.
    var kids = node.children
    if mode == .logical { kids.sort { $0.logicalSize > $1.logicalSize } }
    return kids.prefix(top).map { c in
        TopEntry(path: c.path, name: c.name, allocatedSize: c.allocatedSize, logicalSize: c.logicalSize,
                 fileCount: c.fileCount, isDirectory: c.isDirectory, flags: flagNames(c.flags),
                 children: c.isDirectory && depth > 1 ? topEntries(c, top: top, depth: depth - 1, mode: mode) : nil)
    }
}

func printTop(_ entries: [TopEntry], parentSize: UInt64, indent: Int, mode: SizeMode) {
    for e in entries {
        let size = mode == .allocated ? e.allocatedSize : e.logicalSize
        let share = parentSize > 0 ? Double(size) / Double(parentSize) : 0
        let sizeText = ByteFormat.string(size).padding(toLength: 12, withPad: " ", startingAt: 0)
        let pct = ByteFormat.percent(share).padding(toLength: 7, withPad: " ", startingAt: 0)
        let pad = String(repeating: "  ", count: indent)
        let marker = e.isDirectory ? "▸ " : "  "
        let extra = e.flags.isEmpty ? "" : "  [\(e.flags.joined(separator: ", "))]"
        print("\(sizeText) \(pct) \(pad)\(marker)\(e.name)\(e.isDirectory ? "  (\(ByteFormat.count(e.fileCount)) Dateien)" : "")\(extra)")
        if let kids = e.children { printTop(kids, parentSize: size, indent: indent + 1, mode: mode) }
    }
}

func volumeJSON(_ v: VolumeInfo) -> VolumeJSON {
    VolumeJSON(name: v.name, path: v.path, uuid: v.uuid, total: v.totalCapacity, available: v.availableCapacity,
               availableForImportantUsage: v.availableForImportantUsage, used: v.usedCapacity)
}

func runScan(_ a: ScanArgs) -> Int32 {
    guard let path = a.path else { fail("Pfad fehlt") }
    let engine = ScanEngine(options: a.options)
    let mode: SizeMode = a.logical ? .logical : .allocated
    let cancel = ScanCancellation()
    signal(SIGINT, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigSource.setEventHandler { cancel.cancel() }
    sigSource.resume()

    let result: ScanResult
    // --live: Live-Snapshots wie in der App anfordern (zum Messen des Aufwands).
    final class LiveStats: @unchecked Sendable { var count = 0; var lastNodes = 0 }
    let live = LiveStats()
    do {
        result = try engine.scanBlocking(path, cancellation: cancel, onProgress: a.progress ? { p in
            let line = "\r\(ByteFormat.count(p.filesScanned)) Dateien · \(ByteFormat.string(p.allocatedBytes)) · \(ByteFormat.duration(p.elapsed))   "
            FileHandle.standardError.write(Data(line.utf8))
        } : nil, onSnapshot: a.live ? { t in
            live.count += 1
            live.lastNodes = t.count
        } : nil)
    } catch is CancellationError {
        FileHandle.standardError.write(Data("\nAbgebrochen.\n".utf8))
        return 130
    } catch {
        FileHandle.standardError.write(Data("Fehler: \(error)\n".utf8))
        return 1
    }
    if a.progress { FileHandle.standardError.write(Data("\n".utf8)) }

    let tree = result.tree
    let volume = VolumeInfo.forPath(tree.rootPath)
    let isVolumeRoot = volume.map { $0.path == tree.rootPath } ?? false
    let unassigned = isVolumeRoot ? volume.map { $0.unassigned(scanTotal: result.allocatedSize) } : nil
    let top = topEntries(tree.root, top: a.top, depth: a.depth, mode: mode)

    if a.json {
        let out = ScanJSON(
            root: tree.rootPath, allocatedSize: result.allocatedSize, logicalSize: result.logicalSize,
            fileCount: result.fileCount, directoryCount: result.directoryCount,
            durationSeconds: result.duration, workers: a.options.effectiveWorkerCount,
            nodeCount: tree.count, treeBytes: tree.memoryFootprint,
            hardlinkDuplicates: result.hardlinkDuplicates, unreadablePaths: result.unreadablePaths,
            skippedMountPoints: result.skippedMountPoints, volume: volume.map(volumeJSON),
            unassigned: unassigned, top: top)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // swiftlint:disable:next force_try
        print(String(decoding: try! enc.encode(out), as: UTF8.self))
        return 0
    }

    print("Scan von \(tree.rootPath)")
    print("Belegt:        \(ByteFormat.string(result.allocatedSize))  (\(ByteFormat.count(result.allocatedSize)) Byte)")
    print("Logisch:       \(ByteFormat.string(result.logicalSize))")
    print("Dateien:       \(ByteFormat.count(result.fileCount))")
    print("Ordner:        \(ByteFormat.count(result.directoryCount))")
    print("Dauer:         \(ByteFormat.duration(result.duration)) (\(a.options.effectiveWorkerCount) Worker)")
    print("Baum:          \(ByteFormat.count(tree.count)) Knoten, \(ByteFormat.string(UInt64(tree.memoryFootprint))) im Speicher")
    if a.live {
        print("Live-Snapshots: \(live.count) (Tiefe \(a.options.snapshotDepth), zuletzt \(ByteFormat.count(live.lastNodes)) Knoten)")
    }
    if result.hardlinkDuplicates > 0 {
        print("Hardlinks:     \(ByteFormat.count(result.hardlinkDuplicates)) Duplikate nicht doppelt gezählt")
    }
    if !result.unreadablePaths.isEmpty {
        print("Nicht lesbar:  \(ByteFormat.count(result.unreadablePaths.count)) Ordner")
        for p in result.unreadablePaths.prefix(10) { print("               \(p)") }
        if result.unreadablePaths.count > 10 { print("               …") }
    }
    if !result.skippedMountPoints.isEmpty {
        print("Andere Volumes (nicht betreten): \(result.skippedMountPoints.joined(separator: ", "))")
    }
    if let v = volume {
        print("Volume:        \(v.name) · \(ByteFormat.string(v.totalCapacity)) · belegt \(ByteFormat.string(v.usedCapacity)) · frei \(ByteFormat.string(v.availableCapacity))")
        if let u = unassigned {
            print("Nicht zugeordnet (System, Snapshots, Purgeable): \(ByteFormat.string(u))")
        }
    }
    print("")
    print("Größte Einträge (\(mode == .allocated ? "belegt" : "logisch")):")
    printTop(top, parentSize: tree.root.size(mode), indent: 0, mode: mode)
    return 0
}

func runVolumes(json: Bool) -> Int32 {
    let vols = VolumeInfo.mountedVolumes()
    if json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // swiftlint:disable:next force_try
        print(String(decoding: try! enc.encode(vols.map(volumeJSON)), as: UTF8.self))
        return 0
    }
    for v in vols {
        print("\(v.name) (\(v.path))")
        print("  gesamt \(ByteFormat.string(v.totalCapacity)) · belegt \(ByteFormat.string(v.usedCapacity)) · frei \(ByteFormat.string(v.availableCapacity)) (für Wichtiges \(ByteFormat.string(v.availableForImportantUsage)))")
        if let u = v.uuid { print("  UUID \(u)") }
    }
    return 0
}

// MARK: - Snapshots und Vergleich

func makeStore(_ dir: String?, minSize: UInt64? = nil) -> SnapshotStore {
    let base = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? SnapshotStore.defaultBaseDirectory
    return SnapshotStore(baseDirectory: base, minimumFileSize: minSize ?? SnapshotStore.defaultMinimumFileSize)
}

func dateText(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "dd.MM.yyyy HH:mm:ss"
    return f.string(from: d)
}

func scanWithSignal(_ path: String, options: ScanOptions) -> ScanResult {
    let cancel = ScanCancellation()
    signal(SIGINT, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigSource.setEventHandler { cancel.cancel() }
    sigSource.resume()
    do {
        return try ScanEngine(options: options).scanBlocking(path, cancellation: cancel)
    } catch is CancellationError {
        FileHandle.standardError.write(Data("\nAbgebrochen.\n".utf8))
        exit(130)
    } catch {
        FileHandle.standardError.write(Data("Fehler: \(error)\n".utf8))
        exit(1)
    }
}

func runSnapshot(_ args: ArraySlice<String>) -> Int32 {
    guard let sub = args.first else { fail("snapshot erwartet save oder list") }
    var it = args.dropFirst().makeIterator()
    var path: String?
    var name: String?
    var dir: String?
    var minSize: UInt64?
    var options = ScanOptions()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) erwartet einen Wert") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--name": name = value(arg)
        case "--dir": dir = value(arg)
        case "--min-size":
            guard let v = UInt64(value(arg)) else { fail("--min-size erwartet eine Zahl in Byte") }
            minSize = v
        case "--no-hidden": options.includeHidden = false
        case "--exclude": options.excludedPaths.append(value(arg))
        case "--workers":
            guard let v = Int(value(arg)), v > 0 else { fail("--workers erwartet eine Zahl > 0") }
            options.workerCount = v
        default:
            if arg.hasPrefix("--") { fail("Unbekannte Option \(arg)") }
            if path != nil { fail("Nur ein Pfad erlaubt") }
            path = arg
        }
    }
    let store = makeStore(dir, minSize: minSize)
    switch sub {
    case "save":
        guard let path else { fail("Pfad fehlt") }
        let result = scanWithSignal(path, options: options)
        let start = Date()
        do {
            let info = try store.save(result, name: name)
            let saveTime = Date().timeIntervalSince(start)
            print("Snapshot gespeichert: \(info.url.path)")
            print("ID:            \(info.metadata.id.uuidString)")
            print("Scan-Wurzel:   \(info.metadata.rootPath)")
            print("Belegt:        \(ByteFormat.string(info.metadata.allocatedSize))")
            print("Knoten:        \(ByteFormat.count(info.metadata.nodeCount)) von \(ByteFormat.count(result.tree.count)) (Dateien unter \(ByteFormat.string(store.minimumFileSize)) nur in der Ordnersumme)")
            print("Dateigröße:    \(ByteFormat.string(info.fileSize))")
            print("Dauer:         Scan \(ByteFormat.duration(result.duration)), Speichern \(ByteFormat.duration(saveTime))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Fehler beim Speichern: \(error)\n".utf8))
            return 1
        }
    case "list":
        do {
            let all = try store.list()
            if all.isEmpty { print("Keine Snapshots in \(store.baseDirectory.path)") }
            for info in all {
                let m = info.metadata
                let label = m.name.map { " „\($0)“" } ?? ""
                print("\(dateText(m.date))\(label)  \(ByteFormat.string(m.allocatedSize))  \(m.rootPath)")
                print("    ID \(m.id.uuidString) · \(ByteFormat.count(m.nodeCount)) Knoten · \(ByteFormat.string(info.fileSize)) · \(info.url.path)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Fehler: \(error)\n".utf8))
            return 1
        }
    default:
        fail("Unbekannter Unterbefehl snapshot \(sub)")
    }
}

/// Lädt einen Snapshot über den Dateipfad oder den Anfang seiner ID.
func loadSnapshot(_ ref: String, store: SnapshotStore) -> Snapshot {
    do {
        let expanded = (ref as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return try store.load(url: URL(fileURLWithPath: expanded))
        }
        let matches = try store.list().filter { $0.metadata.id.uuidString.lowercased().hasPrefix(ref.lowercased()) }
        guard matches.count == 1 else {
            fail(matches.isEmpty ? "Snapshot \(ref) nicht gefunden" : "Snapshot-ID \(ref) ist nicht eindeutig")
        }
        return try store.load(matches[0])
    } catch {
        FileHandle.standardError.write(Data("Fehler beim Laden von \(ref): \(error)\n".utf8))
        exit(1)
    }
}

func runDiff(_ args: ArraySlice<String>) -> Int32 {
    var it = args.makeIterator()
    var refs: [String] = []
    var scanPath: String?
    var scanFlag = false
    var top = 20
    var dir: String?
    while let arg = it.next() {
        switch arg {
        case "--scan":
            scanFlag = true
            if let v = it.next() { scanPath = v }
        case "--top":
            guard let v = it.next().flatMap({ Int($0) }), v >= 0 else { fail("--top erwartet eine Zahl ≥ 0") }
            top = v
        case "--dir":
            guard let v = it.next() else { fail("--dir erwartet einen Wert") }
            dir = v
        default:
            if arg.hasPrefix("--") { fail("Unbekannte Option \(arg)") }
            refs.append(arg)
        }
    }
    guard let first = refs.first, refs.count <= 2 else { fail("diff erwartet einen oder zwei Snapshots") }
    if refs.count == 2, scanFlag { fail("Entweder <snapshotB> oder --scan, nicht beides") }
    let store = makeStore(dir)
    let old = loadSnapshot(first, store: store)
    let new: Snapshot
    if refs.count == 2 {
        new = loadSnapshot(refs[1], store: store)
    } else {
        let path = scanPath ?? old.metadata.rootPath
        var options = ScanOptions()
        options.includeHidden = old.metadata.options.includeHidden
        options.excludedPaths = old.metadata.options.excludedPaths
        options.crossMountPoints = old.metadata.options.crossMountPoints
        let result = scanWithSignal(path, options: options)
        new = Snapshot(metadata: .current(for: result), tree: result.tree)
    }
    let start = Date()
    let diff = SnapshotDiff(old: old, new: new)
    let changes = diff.largestChanges(limit: top)
    let elapsed = Date().timeIntervalSince(start)

    print("Vergleich \(dateText(old.metadata.date)) → \(dateText(new.metadata.date))")
    print(diff.summary.headline)
    print("Scan-Summe:    \(ByteFormat.string(old.tree.root.allocatedSize)) → \(ByteFormat.string(new.tree.root.allocatedSize)) (\(ByteFormat.signed(diff.summary.scanDelta)))")
    for w in diff.warnings { print("Warnung:       \(w)") }
    print("Dauer:         \(ByteFormat.duration(elapsed)) für \(ByteFormat.count(diff.count)) Einträge")
    print("")
    print("Größte Veränderungen:")
    if changes.isEmpty { print("  (keine)") }
    let statusText: [DiffStatus: String] = [.added: "neu", .removed: "entfernt", .grown: "gewachsen",
                                            .shrunk: "geschrumpft", .unchanged: "unverändert"]
    for c in changes {
        let d = ByteFormat.signed(c.delta).padding(toLength: 12, withPad: " ", startingAt: 0)
        let st = (statusText[c.status] ?? "").padding(toLength: 11, withPad: " ", startingAt: 0)
        print("\(d) \(st) \(c.path)\(c.isDirectory ? "/" : "")")
    }
    return 0
}

let argv = CommandLine.arguments.dropFirst()
guard let command = argv.first else { print(usage); exit(2) }
switch command {
case "scan":
    exit(runScan(parseScan(argv.dropFirst())))
case "volumes":
    exit(runVolumes(json: argv.contains("--json")))
case "snapshot":
    exit(runSnapshot(argv.dropFirst()))
case "diff":
    exit(runDiff(argv.dropFirst()))
case "-h", "--help", "help":
    print(usage)
default:
    fail("Unbekannter Befehl \(command)")
}
