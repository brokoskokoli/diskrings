import DiskRingsCore
import Foundation

let usage = """
Usage:
  diskrings-cli scan <path> [--top N] [--depth D] [--json] [--logical]
                            [--no-hidden] [--exclude PATH]... [--workers N]
                            [--cross-mounts] [--progress] [--live [--live-depth K]]
  diskrings-cli volumes [--json]
  diskrings-cli snapshot save <path> [--name NAME] [--dir DIR] [--min-size BYTES]
                                     [--no-hidden] [--exclude PATH]... [--workers N]
  diskrings-cli snapshot list [--dir DIR]
  diskrings-cli diff <snapshotA> [<snapshotB> | --scan <path>] [--top N] [--dir DIR]

  scan      Scans <path> and prints the total, file count, duration and the
            largest folders (default: --top 10 --depth 1).
  volumes   Lists the mounted volumes.
  snapshot  save: scans <path> and saves a snapshot (default location
            ~/Library/Application Support/DiskRings/Snapshots, files under
            1 MB only in the folder total). list: shows all snapshots.
  diff      Compares snapshot A with snapshot B or with a fresh scan
            (default: --scan with the scan root of A) and shows the largest
            changes (default: --top 20). Snapshots are given as a file
            (.drsnap) or by the beginning of their ID from "snapshot list".

Sizes and numbers are formatted for the system locale.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n\n\(usage)\n".utf8))
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
        guard let v = it.next() else { fail("\(flag) expects a value") }
        return v
    }
    func int(_ flag: String) -> Int {
        guard let v = Int(value(flag)), v >= 0 else { fail("\(flag) expects a number ≥ 0") }
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
            if arg.hasPrefix("--") { fail("Unknown option \(arg)") }
            if a.path != nil { fail("Only one path allowed") }
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
    if f.contains(.package) { out.append("package") }
    if f.contains(.symlink) { out.append("symlink") }
    if f.contains(.unreadable) { out.append("unreadable") }
    if f.contains(.dataless) { out.append("cloud-only") }
    if f.contains(.hardlinkDuplicate) { out.append("hardlink-duplicate") }
    if f.contains(.mountPoint) { out.append("mount-point") }
    if f.contains(.hidden) { out.append("hidden") }
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
        print("\(sizeText) \(pct) \(pad)\(marker)\(e.name)\(e.isDirectory ? "  (\(ByteFormat.count(e.fileCount)) files)" : "")\(extra)")
        if let kids = e.children { printTop(kids, parentSize: size, indent: indent + 1, mode: mode) }
    }
}

func volumeJSON(_ v: VolumeInfo) -> VolumeJSON {
    VolumeJSON(name: v.name, path: v.path, uuid: v.uuid, total: v.totalCapacity, available: v.availableCapacity,
               availableForImportantUsage: v.availableForImportantUsage, used: v.usedCapacity)
}

func runScan(_ a: ScanArgs) -> Int32 {
    guard let path = a.path else { fail("Path missing") }
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
            let line = "\r\(ByteFormat.count(p.filesScanned)) files · \(ByteFormat.string(p.allocatedBytes)) · \(ByteFormat.duration(p.elapsed))   "
            FileHandle.standardError.write(Data(line.utf8))
        } : nil, onSnapshot: a.live ? { t in
            live.count += 1
            live.lastNodes = t.count
        } : nil)
    } catch is CancellationError {
        FileHandle.standardError.write(Data("\nCancelled.\n".utf8))
        return 130
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
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

    print("Scan of \(tree.rootPath)")
    print("Allocated:     \(ByteFormat.string(result.allocatedSize))  (\(ByteFormat.count(result.allocatedSize)) bytes)")
    print("Logical:       \(ByteFormat.string(result.logicalSize))")
    print("Files:         \(ByteFormat.count(result.fileCount))")
    print("Folders:       \(ByteFormat.count(result.directoryCount))")
    print("Duration:      \(ByteFormat.duration(result.duration)) (\(a.options.effectiveWorkerCount) workers)")
    print("Tree:          \(ByteFormat.count(tree.count)) nodes, \(ByteFormat.string(UInt64(tree.memoryFootprint))) in memory")
    if a.live {
        print("Live snapshots: \(live.count) (depth \(a.options.snapshotDepth), last \(ByteFormat.count(live.lastNodes)) nodes)")
    }
    if result.hardlinkDuplicates > 0 {
        print("Hard links:    \(ByteFormat.count(result.hardlinkDuplicates)) duplicates not counted twice")
    }
    if !result.unreadablePaths.isEmpty {
        print("Unreadable:    \(ByteFormat.count(result.unreadablePaths.count)) folders")
        for p in result.unreadablePaths.prefix(10) { print("               \(p)") }
        if result.unreadablePaths.count > 10 { print("               …") }
    }
    if !result.skippedMountPoints.isEmpty {
        print("Other volumes (not entered): \(result.skippedMountPoints.joined(separator: ", "))")
    }
    if let v = volume {
        print("Volume:        \(v.name) · \(ByteFormat.string(v.totalCapacity)) · used \(ByteFormat.string(v.usedCapacity)) · free \(ByteFormat.string(v.availableCapacity))")
        if let u = unassigned {
            print("Unassigned (system, snapshots, purgeable): \(ByteFormat.string(u))")
        }
    }
    print("")
    print("Largest entries (\(mode == .allocated ? "allocated" : "logical")):")
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
        print("  total \(ByteFormat.string(v.totalCapacity)) · used \(ByteFormat.string(v.usedCapacity)) · free \(ByteFormat.string(v.availableCapacity)) (for important usage \(ByteFormat.string(v.availableForImportantUsage)))")
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
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
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
        FileHandle.standardError.write(Data("\nCancelled.\n".utf8))
        exit(130)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
}

func runSnapshot(_ args: ArraySlice<String>) -> Int32 {
    guard let sub = args.first else { fail("snapshot expects save or list") }
    var it = args.dropFirst().makeIterator()
    var path: String?
    var name: String?
    var dir: String?
    var minSize: UInt64?
    var options = ScanOptions()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) expects a value") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--name": name = value(arg)
        case "--dir": dir = value(arg)
        case "--min-size":
            guard let v = UInt64(value(arg)) else { fail("--min-size expects a number of bytes") }
            minSize = v
        case "--no-hidden": options.includeHidden = false
        case "--exclude": options.excludedPaths.append(value(arg))
        case "--workers":
            guard let v = Int(value(arg)), v > 0 else { fail("--workers expects a number > 0") }
            options.workerCount = v
        default:
            if arg.hasPrefix("--") { fail("Unknown option \(arg)") }
            if path != nil { fail("Only one path allowed") }
            path = arg
        }
    }
    let store = makeStore(dir, minSize: minSize)
    switch sub {
    case "save":
        guard let path else { fail("Path missing") }
        let result = scanWithSignal(path, options: options)
        let start = Date()
        do {
            let info = try store.save(result, name: name)
            let saveTime = Date().timeIntervalSince(start)
            print("Snapshot saved: \(info.url.path)")
            print("ID:            \(info.metadata.id.uuidString)")
            print("Scan root:     \(info.metadata.rootPath)")
            print("Allocated:     \(ByteFormat.string(info.metadata.allocatedSize))")
            print("Nodes:         \(ByteFormat.count(info.metadata.nodeCount)) of \(ByteFormat.count(result.tree.count)) (files under \(ByteFormat.string(store.minimumFileSize)) only in the folder total)")
            print("File size:     \(ByteFormat.string(info.fileSize))")
            print("Duration:      scan \(ByteFormat.duration(result.duration)), save \(ByteFormat.duration(saveTime))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Error while saving: \(error)\n".utf8))
            return 1
        }
    case "list":
        do {
            let all = try store.list()
            if all.isEmpty { print("No snapshots in \(store.baseDirectory.path)") }
            for info in all {
                let m = info.metadata
                let label = m.name.map { " \"\($0)\"" } ?? ""
                print("\(dateText(m.date))\(label)  \(ByteFormat.string(m.allocatedSize))  \(m.rootPath)")
                print("    ID \(m.id.uuidString) · \(ByteFormat.count(m.nodeCount)) nodes · \(ByteFormat.string(info.fileSize)) · \(info.url.path)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            return 1
        }
    default:
        fail("Unknown subcommand snapshot \(sub)")
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
            fail(matches.isEmpty ? "Snapshot \(ref) not found" : "Snapshot ID \(ref) is ambiguous")
        }
        return try store.load(matches[0])
    } catch {
        FileHandle.standardError.write(Data("Error while loading \(ref): \(error)\n".utf8))
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
            guard let v = it.next().flatMap({ Int($0) }), v >= 0 else { fail("--top expects a number ≥ 0") }
            top = v
        case "--dir":
            guard let v = it.next() else { fail("--dir expects a value") }
            dir = v
        default:
            if arg.hasPrefix("--") { fail("Unknown option \(arg)") }
            refs.append(arg)
        }
    }
    guard let first = refs.first, refs.count <= 2 else { fail("diff expects one or two snapshots") }
    if refs.count == 2, scanFlag { fail("Either <snapshotB> or --scan, not both") }
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

    print("Comparison \(dateText(old.metadata.date)) → \(dateText(new.metadata.date))")
    print(diff.summary.headline)
    print("Scan total:    \(ByteFormat.string(old.tree.root.allocatedSize)) → \(ByteFormat.string(new.tree.root.allocatedSize)) (\(ByteFormat.signed(diff.summary.scanDelta)))")
    for w in diff.warnings { print("Warning:       \(w)") }
    print("Duration:      \(ByteFormat.duration(elapsed)) for \(ByteFormat.count(diff.count)) entries")
    print("")
    print("Largest changes:")
    if changes.isEmpty { print("  (none)") }
    let statusText: [DiffStatus: String] = [.added: "new", .removed: "removed", .grown: "grown",
                                            .shrunk: "shrunk", .unchanged: "unchanged"]
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
    fail("Unknown command \(command)")
}
