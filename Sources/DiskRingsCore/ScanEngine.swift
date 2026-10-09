import Darwin
import Foundation

/// Parallele Scan-Engine (SPEC 4.3).
///
/// Ablauf: Die Wurzel kommt als erster Job in eine gemeinsame Queue. *N* Worker
/// (eigene Threads, weil sie in blockierenden Syscalls stecken) lesen Ordner
/// mit `getattrlistbulk` und schreiben die Einträge ohne Locks in einen eigenen
/// lokalen Puffer. Unterordner landen auf dem lokalen Stapel des Workers; ist
/// ein anderer Worker untätig oder hat der Worker mehr als
/// `ScanOptions.splitThreshold` Einträge seit der letzten Abgabe gesammelt,
/// gibt er die Hälfte seiner offenen Ordner an die Queue ab (Aufteilen großer
/// Teilbäume). Am Ende fügt der Koordinator die Puffer zusammen, bereinigt
/// Hardlinks deterministisch und baut den sortierten `ScanTree`.
///
/// Ein paralleler und ein sequenzieller Scan desselben Baums ergeben
/// identische Bäume.
public struct ScanEngine: Sendable {
    public let options: ScanOptions
    /// Eingriffspunkte für Tests (z. B. Ordner zwischen Auflisten und Öffnen
    /// verschwinden lassen oder in einer bestimmten Phase abbrechen).
    var hooks = ScanHooks()

    /// So viele Ereignisse puffert `events(_:)` höchstens, wenn der Konsument
    /// nicht nachkommt. Ältere Fortschrittsmeldungen und Snapshots werden
    /// dann verworfen; `.finished` ist immer das letzte Ereignis und bleibt.
    public static let eventBufferLimit = 8

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Scannt `path` asynchron. Der Scan läuft auf eigenen Threads, nicht im
    /// kooperativen Thread-Pool. Ein Abbruch der umgebenden Task bricht den
    /// Scan ab (`CancellationError`).
    public func scan(
        _ path: String,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil,
        onSnapshot: (@Sendable (ScanTree) -> Void)? = nil
    ) async throws -> ScanResult {
        let token = ScanCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScanResult, Error>) in
                let thread = Thread {
                    do {
                        cont.resume(returning: try self.scanBlocking(
                            path, cancellation: token, onProgress: onProgress, onSnapshot: onSnapshot))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                thread.qualityOfService = .userInitiated
                thread.name = "DiskRings.ScanCoordinator"
                thread.start()
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Ereignis-Stream mit Fortschritt, Live-Snapshots und dem Endergebnis.
    /// Beendet der Konsument den Stream, wird der Scan abgebrochen.
    ///
    /// Der Puffer ist begrenzt (`eventBufferLimit`, die neuesten bleiben):
    /// Ein langsamer Konsument verpasst Zwischenstände, aber der Speicher
    /// wächst nicht mit der Scandauer.
    public func events(_ path: String, includeSnapshots: Bool = true) -> AsyncThrowingStream<ScanEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ScanEvent.self, throwing: Error.self, bufferingPolicy: .bufferingNewest(Self.eventBufferLimit))
        let progress: @Sendable (ScanProgress) -> Void = { p in continuation.yield(.progress(p)) }
        let snapshot: (@Sendable (ScanTree) -> Void)? =
            includeSnapshots ? { @Sendable t in _ = continuation.yield(.snapshot(t)) } : nil
        let engine = self
        let task = Task {
            do {
                let result = try await engine.scan(path, onProgress: progress, onSnapshot: snapshot)
                continuation.yield(.finished(result))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Synchroner Scan auf dem aufrufenden Thread (plus Worker-Threads).
    /// Der aufrufende Thread liefert die Fortschrittsmeldungen.
    public func scanBlocking(
        _ path: String,
        cancellation: ScanCancellation = ScanCancellation(),
        onProgress: ((ScanProgress) -> Void)? = nil,
        onSnapshot: ((ScanTree) -> Void)? = nil
    ) throws -> ScanResult {
        let startTime = DispatchTime.now()
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1e9 }

        if cancellation.isCancelled { throw CancellationError() }
        guard let rootPath = Self.resolve(path) else { throw ScanError.notFound(path) }
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw ScanError.notFound(path) }

        let rootName = rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR

        if !isDir {
            // Eine einzelne Datei als Wurzel.
            var raw = RawTree()
            var flags: NodeFlags = (st.st_mode & S_IFMT) == S_IFLNK ? [.symlink] : []
            let dataless = st.st_flags & FileFlags.dataless != 0
            if dataless { flags.insert(.dataless) }
            raw.append(parent: -1, name: Array(rootName.utf8), flags: flags,
                       allocated: dataless ? 0 : UInt64(st.st_blocks) * 512,
                       logical: UInt64(max(st.st_size, 0)), ownFiles: 1)
            let tree = try TreeBuilder.build(raw, rootPath: rootPath)
            return ScanResult(tree: tree, duration: elapsed(), fileCount: 1, directoryCount: 0,
                              unreadablePaths: [], skippedMountPoints: [], hardlinkDuplicates: 0,
                              options: options)
        }

        let ctx = ScanContext(
            options: options, rootPath: rootPath, rootDev: st.st_dev, rootName: rootName,
            cancellation: cancellation)
        ctx.hooks = hooks
        var rootFlags: NodeFlags = [.directory]
        if PackageDetector.isPackage(name: rootName) { rootFlags.insert(.package) }
        ctx.rootBuffer.append(parent: ScanContext.noParent, name: Array(rootName.utf8), flags: rootFlags,
                              allocated: 0, logical: 0)
        ctx.queue.append(ScanJob(ref: 0, path: rootPath, depth: 0, skeleton: 0))

        let workerCount = options.effectiveWorkerCount
        let workers = (0 ..< workerCount).map { ScanWorker(id: UInt64($0 + 1), context: ctx) }
        let group = DispatchGroup()
        for w in workers {
            group.enter()
            let t = Thread {
                w.run()
                group.leave()
            }
            t.qualityOfService = .userInitiated
            t.name = "DiskRings.ScanWorker"
            t.start()
        }

        func emit() {
            if let onProgress {
                var p = ctx.progressSnapshot()
                p.elapsed = elapsed()
                onProgress(p)
            }
            if let onSnapshot, !cancellation.isCancelled {
                let raw = ctx.skeletonSnapshot()
                if let tree = try? TreeBuilder.build(raw, rootPath: rootPath) { onSnapshot(tree) }
            }
        }

        // In kurzen Schritten warten, damit ein Abbruch schnell bei den
        // untätigen Workern ankommt; gemeldet wird im eingestellten Takt.
        let interval = max(options.progressInterval, 0.005)
        var nextEmit = elapsed() + interval
        while group.wait(timeout: .now() + min(interval, 0.05)) == .timedOut {
            if cancellation.isCancelled {
                ctx.wakeAll()
                continue
            }
            if elapsed() >= nextEmit {
                emit()
                nextEmit = elapsed() + interval
            }
        }
        if cancellation.isCancelled { throw CancellationError() }

        // Abschlussmeldung mit vollständigen Zählern.
        if let onProgress {
            var p = ctx.progressSnapshot()
            p.elapsed = elapsed()
            onProgress(p)
        }

        do {
            memDebug("scan done")
            hooks.phase?(.assembling)
            let assembled = try Assembler.assemble(ctx: ctx, workers: workers)
            memDebug("assembled")
            let raw = assembled.raw
            hooks.phase?(.building)
            let tree = try TreeBuilder.build(raw, rootPath: rootPath) { cancellation.isCancelled }
            memDebug("built")
            let root = tree.root
            return ScanResult(
                tree: tree, duration: elapsed(), fileCount: root.fileCount,
                directoryCount: tree.directoryCount,
                unreadablePaths: assembled.unreadablePaths.sorted(),
                skippedMountPoints: assembled.mountPoints.sorted(),
                hardlinkDuplicates: assembled.duplicates, options: options)
        } catch is TreeBuildError {
            throw CancellationError()
        }
    }

    /// Absoluter, aufgelöster Pfad (Symlinks in der Wurzel werden aufgelöst).
    static func resolve(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let r = realpath(expanded, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}

// MARK: - Gemeinsamer Zustand

/// Phasen nach dem Lesen, für Test-Eingriffe.
enum ScanPhase: Sendable { case assembling, building }

/// Eingriffspunkte für Tests; im normalen Betrieb leer.
struct ScanHooks: Sendable {
    /// Wird vor dem Öffnen jedes Ordners mit dessen Pfad aufgerufen.
    var beforeOpenDirectory: (@Sendable (String) -> Void)?
    /// Wird zu Beginn der Phasen nach dem Lesen aufgerufen.
    var phase: (@Sendable (ScanPhase) -> Void)?
}

struct ScanJob {
    /// Gepackte Referenz auf den Ordnerknoten: Puffer-ID (obere 24 Bit) und Index.
    var ref: UInt64
    var path: String
    var depth: Int32
    /// Index des zuständigen Knotens im Live-Skelett.
    var skeleton: Int32
}

/// Lokaler Rohpuffer eines Workers. Eltern sind gepackte Referenzen, weil
/// sie im Puffer eines anderen Workers liegen können.
struct WorkerBuffer: ~Copyable {
    var parentRef = MappedBuffer<UInt64>()
    var nameOffset = MappedBuffer<UInt32>()
    var nameLength = MappedBuffer<UInt16>()
    var flags = MappedBuffer<UInt16>()
    var allocated = MappedBuffer<UInt64>()
    var logical = MappedBuffer<UInt64>()
    var names = MappedBuffer<UInt8>()
    /// Dateien mit `nlink > 1`: (Gerät, Inode, lokaler Index).
    var hardlinks: [(dev: Int32, ino: UInt64, index: UInt32)] = []
    /// Ordner, die nicht gelesen werden konnten (gepackte Referenzen).
    var unreadable: [UInt64] = []
    var unreadablePaths: [String] = []
    var mountPoints: [String] = []

    init() {}

    var count: Int { parentRef.count }

    @discardableResult
    mutating func append(
        parent: UInt64, name: UnsafeBufferPointer<UInt8>, flags f: NodeFlags,
        allocated a: UInt64, logical l: UInt64
    ) -> Int {
        let idx = parentRef.count
        parentRef.append(parent)
        nameOffset.append(UInt32(names.count))
        let len = min(name.count, Int(UInt16.max))
        nameLength.append(UInt16(len))
        names.append(contentsOf: UnsafeBufferPointer(rebasing: name[0 ..< len]))
        flags.append(f.rawValue)
        allocated.append(a)
        logical.append(l)
        return idx
    }

    mutating func append(parent: UInt64, name: [UInt8], flags f: NodeFlags, allocated a: UInt64, logical l: UInt64) {
        _ = name.withUnsafeBufferPointer { append(parent: parent, name: $0, flags: f, allocated: a, logical: l) }
    }

    func nameBuffer(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: names.base.map { $0 + Int(nameOffset[i]) }, count: Int(nameLength[i]))
    }
}

final class ScanContext: @unchecked Sendable {
    static let indexBits: UInt64 = 40
    static let indexMask: UInt64 = (1 << indexBits) - 1
    static let noParent = UInt64.max

    let options: ScanOptions
    let rootPath: String
    let cancellation: ScanCancellation
    /// Geräte, auf denen gescannt wird (Wurzel-Volume, beim System-Volume
    /// zusätzlich das über Firmlinks verbundene Data-Volume).
    let allowedDevices: Set<Int32>
    /// Pfade, die nie betreten werden (`/System/Volumes/Data`).
    let neverEnter: Set<String>
    let excluded: Set<String>
    var hooks = ScanHooks()

    /// Puffer 0: nur die Wurzel. Wird vor dem Start befüllt und von
    /// Workern ausschließlich unter `cond` für Markierungen genutzt.
    var rootBuffer = WorkerBuffer()

    // Alles Folgende nur unter `cond`.
    let cond = NSCondition()
    var queue: [ScanJob] = []
    var active = 0
    var idle = 0
    var files = 0
    var dirs = 0
    var bytes: UInt64 = 0
    var currentPath = ""
    /// Live-Skelett der obersten Ebenen (Ordner bis `snapshotDepth`).
    var skeleton = RawTree()

    init(options: ScanOptions, rootPath: String, rootDev: Int32, rootName: String, cancellation: ScanCancellation) {
        self.options = options
        self.rootPath = rootPath
        self.cancellation = cancellation
        self.currentPath = rootPath

        // Firmlinks (SPEC 4.1 Punkt 5): „/“ und „/System/Volumes/Data“ bilden
        // eine APFS-Volume-Gruppe. Seit macOS 10.15 melden beide dasselbe
        // st_dev; auf älteren Systemen unterscheidet es sich. Der Einhängepunkt
        // des Data-Volumes wird nie betreten, weil seine Inhalte schon über die
        // Firmlinks (/Users, /Applications …) erscheinen.
        var allowed: Set<Int32> = [rootDev]
        var never: Set<String> = []
        let dataPath = "/System/Volumes/Data"
        if Self.isMountPoint(dataPath) {
            never.insert(dataPath)
            var sRoot = stat(), sData = stat()
            if lstat("/", &sRoot) == 0, lstat(dataPath, &sData) == 0, rootDev == sRoot.st_dev {
                allowed.insert(sData.st_dev)
            }
        }
        allowedDevices = allowed
        neverEnter = never

        var ex: Set<String> = []
        for p in options.excludedPaths {
            var s = (p as NSString).expandingTildeInPath
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            ex.insert(s)
            if let r = ScanEngine.resolve(s) { ex.insert(r) }
        }
        excluded = ex

        skeleton.append(parent: -1, name: Array(rootName.utf8), flags: .directory,
                        allocated: 0, logical: 0, ownFiles: 0)
    }

    /// Ist `path` selbst ein Einhängepunkt?
    static func isMountPoint(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let mnt = withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return mnt == path
    }

    func wakeAll() {
        cond.lock()
        cond.broadcast()
        cond.unlock()
    }

    func progressSnapshot() -> ScanProgress {
        cond.lock()
        defer { cond.unlock() }
        return ScanProgress(filesScanned: files, directoriesScanned: dirs, allocatedBytes: bytes,
                            currentPath: currentPath, elapsed: 0, activeWorkers: active)
    }

    func skeletonSnapshot() -> RawTree {
        cond.lock()
        defer { cond.unlock() }
        return skeleton.copy()
    }
}

// MARK: - Worker

final class ScanWorker: @unchecked Sendable {
    let id: UInt64
    let ctx: ScanContext
    var buffer = WorkerBuffer()

    init(id: UInt64, context: ScanContext) {
        self.id = id
        self.ctx = context
    }

    func run() {
        // Dataless-Dateien und -Ordner dürfen keinen iCloud-Download auslösen.
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        var reader = DirectoryReader()
        let cond = ctx.cond
        cond.lock()
        while true {
            if ctx.cancellation.isCancelled { break }
            if let job = ctx.queue.popLast() {
                ctx.active += 1
                cond.unlock()
                runLocal(job, reader: &reader)
                cond.lock()
                ctx.active -= 1
                if ctx.active == 0, ctx.queue.isEmpty { cond.broadcast() }
                continue
            }
            if ctx.active == 0 { break }
            ctx.idle += 1
            cond.wait()
            ctx.idle -= 1
        }
        cond.broadcast()
        cond.unlock()
    }

    private struct PendingDir {
        var localIndex: Int
        var path: String
    }

    private func runLocal(_ first: ScanJob, reader: inout DirectoryReader) {
        var stack: [ScanJob] = [first]
        var sinceShare = 0
        let options = ctx.options
        let includeHidden = options.includeHidden
        let cross = options.crossMountPoints
        let excluded = ctx.excluded
        let checkExcluded = !excluded.isEmpty
        let neverEnter = ctx.neverEnter
        let allowed = ctx.allowedDevices
        let snapshotDepth = Int32(max(options.snapshotDepth, 0))
        var pending: [PendingDir] = []

        while let job = stack.popLast() {
            if ctx.cancellation.isCancelled { return }
            pending.removeAll(keepingCapacity: true)
            var nFiles = 0
            var nAlloc: UInt64 = 0
            var nLogical: UInt64 = 0
            var entries = 0
            let parentPathPrefix = job.path == "/" ? "/" : job.path + "/"

            ctx.hooks.beforeOpenDirectory?(job.path)
            let fd = openDirectory(job.path)
            var readError: Int32 = 0
            if fd < 0 {
                readError = errno
            } else {
                readError = reader.read(fd: fd, shouldStop: { ctx.cancellation.isCancelled }) { e in
                    let name = e.name
                    guard name.count > 0 else { return }
                    entries += 1
                    var flags: NodeFlags = []
                    if name[0] == UInt8(ascii: ".") || e.bsdFlags & FileFlags.hidden != 0 {
                        if !includeHidden { return }
                        flags.insert(.hidden)
                    }
                    let isDir = e.objType == VDIR.rawValue
                    var childPath: String?
                    if isDir || checkExcluded {
                        let p = parentPathPrefix + String(decoding: name, as: UTF8.self)
                        if checkExcluded, excluded.contains(p) { return }
                        childPath = p
                    }
                    let dataless = e.bsdFlags & FileFlags.dataless != 0
                    if dataless { flags.insert(.dataless) }

                    if isDir {
                        flags.insert(.directory)
                        if PackageDetector.isPackage(nameBytes: name) { flags.insert(.package) }
                        var descend = !dataless && e.error == 0
                        if e.error != 0 { flags.insert(.unreadable) }
                        let path = childPath!
                        let isMount = e.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
                            || !allowed.contains(e.dev)
                        if neverEnter.contains(path) || (isMount && !cross) {
                            flags.insert(.mountPoint)
                            descend = false
                            buffer.mountPoints.append(path)
                        }
                        let idx = buffer.append(parent: job.ref, name: name, flags: flags, allocated: 0, logical: 0)
                        if descend { pending.append(PendingDir(localIndex: idx, path: path)) }
                        if e.error != 0 { buffer.unreadablePaths.append(path) }
                    } else {
                        if e.objType == VLNK.rawValue { flags.insert(.symlink) }
                        let alloc = dataless ? 0 : e.allocatedSize
                        let idx = buffer.append(parent: job.ref, name: name, flags: flags,
                                                allocated: alloc, logical: e.logicalSize)
                        if e.linkCount > 1 {
                            buffer.hardlinks.append((e.dev, e.fileID, UInt32(idx)))
                        }
                        nFiles += 1
                        nAlloc &+= alloc
                        nLogical &+= e.logicalSize
                    }
                }
                close(fd)
            }
            if ctx.cancellation.isCancelled { return }
            if readError != 0 {
                buffer.unreadable.append(job.ref)
                buffer.unreadablePaths.append(job.path)
            }
            sinceShare += entries

            // Zähler, Live-Skelett und Abgabe-Entscheidung unter einem Lock.
            var newJobs: [ScanJob] = []
            newJobs.reserveCapacity(pending.count)
            let childDepth = job.depth + 1
            let cond = ctx.cond
            cond.lock()
            ctx.files += nFiles
            ctx.dirs += 1
            ctx.bytes &+= nAlloc
            ctx.currentPath = job.path
            let sk = Int(job.skeleton)
            ctx.skeleton.allocated[sk] &+= nAlloc
            ctx.skeleton.logical[sk] &+= nLogical
            ctx.skeleton.ownFiles[sk] &+= UInt32(nFiles)
            for d in pending {
                var skel = job.skeleton
                if childDepth <= snapshotDepth {
                    skel = ctx.skeleton.append(
                        parent: job.skeleton, name: buffer.nameBuffer(d.localIndex),
                        flags: NodeFlags(rawValue: buffer.flags[d.localIndex]),
                        allocated: 0, logical: 0, ownFiles: 0)
                }
                newJobs.append(ScanJob(ref: (id << ScanContext.indexBits) | UInt64(d.localIndex),
                                       path: d.path, depth: childDepth, skeleton: skel))
            }
            let wantShare = ctx.idle > 0 || (sinceShare > options.splitThreshold && ctx.queue.isEmpty)
            cond.unlock()

            stack.append(contentsOf: newJobs)

            if wantShare, stack.count > 1 {
                let give = stack.count / 2
                let shared = Array(stack.prefix(give))
                stack.removeFirst(give)
                sinceShare = 0
                cond.lock()
                ctx.queue.append(contentsOf: shared)
                cond.broadcast()
                cond.unlock()
            }
        }
    }
}

// MARK: - Zusammenführen

enum Assembler {
    struct Output: ~Copyable {
        var raw: RawTree
        var unreadablePaths: [String]
        var mountPoints: [String]
        var duplicates: Int
    }

    static func assemble(ctx: ScanContext, workers: [ScanWorker]) throws -> Output {
        // Reihenfolge der Puffer: 0 = Wurzel, dann Worker 1…N.
        var counts = [ctx.rootBuffer.count]
        var nameBytes = ctx.rootBuffer.names.count
        for w in workers {
            counts.append(w.buffer.count)
            nameBytes += w.buffer.names.count
        }
        var base = [Int](repeating: 0, count: counts.count)
        for i in 1 ..< counts.count { base[i] = base[i - 1] + counts[i - 1] }
        let total = base.last! + counts.last!
        guard total < Int(Int32.max) - 1, nameBytes < Int(UInt32.max) else { throw ScanError.tooManyNodes }

        var raw = RawTree()
        raw.reserve(total, nameBytes: nameBytes)
        var lists = Lists()
        take(&ctx.rootBuffer, bufferIndex: 0, base: base, into: &raw, lists: &lists)
        for (i, w) in workers.enumerated() {
            take(&w.buffer, bufferIndex: i + 1, base: base, into: &raw, lists: &lists)
        }

        for r in lists.unreadableRefs {
            raw.flags[globalIndex(r, base)] |= NodeFlags.unreadable.rawValue
        }
        var links = lists.links

        // Hardlinks: pro (Gerät, Inode) zählt genau ein Vorkommen, und zwar
        // das mit dem kleinsten Pfad (bytewise). So ist das Ergebnis
        // unabhängig von der Reihenfolge, in der die Worker sie gefunden haben.
        var duplicates = 0
        if links.count > 1 {
            links.sort { $0.dev != $1.dev ? $0.dev < $1.dev : $0.ino < $1.ino }
            var s = 0
            while s < links.count {
                var e = s + 1
                while e < links.count, links[e].dev == links[s].dev, links[e].ino == links[s].ino { e += 1 }
                if e - s > 1 {
                    let group = links[s ..< e].map { ($0.index, pathBytes(raw, $0.index)) }
                    let winner = group.min { $0.1.lexicographicallyPrecedes($1.1) }!.0
                    for (idx, _) in group where idx != winner {
                        raw.allocated[Int(idx)] = 0
                        raw.logical[Int(idx)] = 0
                        raw.flags[Int(idx)] |= NodeFlags.hardlinkDuplicate.rawValue
                        duplicates += 1
                    }
                }
                s = e
            }
        }
        return Output(raw: raw, unreadablePaths: lists.unreadablePaths, mountPoints: lists.mountPoints,
                      duplicates: duplicates)
    }

    struct Lists {
        var unreadablePaths: [String] = []
        var mountPoints: [String] = []
        var unreadableRefs: [UInt64] = []
        var links: [(dev: Int32, ino: UInt64, index: Int32)] = []
    }

    @inline(__always)
    static func globalIndex(_ ref: UInt64, _ base: [Int]) -> Int {
        base[Int(ref >> ScanContext.indexBits)] + Int(ref & ScanContext.indexMask)
    }

    /// Hängt einen Worker-Puffer an den Rohbaum an und gibt ihn danach frei.
    static func take(
        _ b: inout WorkerBuffer, bufferIndex: Int, base: [Int], into raw: inout RawTree, lists: inout Lists
    ) {
        let nameBase = UInt32(raw.names.count)
        raw.names.append(contentsOf: b.names)
        for i in 0 ..< b.count {
            let pr = b.parentRef[i]
            raw.parent.append(pr == ScanContext.noParent ? -1 : Int32(globalIndex(pr, base)))
            raw.nameOffset.append(nameBase + b.nameOffset[i])
            raw.nameLength.append(b.nameLength[i])
            let f = b.flags[i]
            raw.flags.append(f)
            raw.allocated.append(b.allocated[i])
            raw.logical.append(b.logical[i])
            raw.ownFiles.append(f & NodeFlags.directory.rawValue != 0 ? 0 : 1)
        }
        for h in b.hardlinks {
            lists.links.append((h.dev, h.ino, Int32(base[bufferIndex] + Int(h.index))))
        }
        lists.unreadableRefs += b.unreadable
        lists.unreadablePaths += b.unreadablePaths
        lists.mountPoints += b.mountPoints
        b = WorkerBuffer() // Speicher sofort freigeben
    }

    /// Pfad relativ zur Wurzel als Bytes (Komponenten mit „/“ getrennt).
    static func pathBytes(_ raw: borrowing RawTree, _ index: Int32) -> [UInt8] {
        var comps: [Int32] = []
        var i = index
        while i > 0 { comps.append(i); i = raw.parent[Int(i)] }
        var out: [UInt8] = []
        let names = raw.names.buffer
        for c in comps.reversed() {
            let off = Int(raw.nameOffset[Int(c)]), len = Int(raw.nameLength[Int(c)])
            out.append(UInt8(ascii: "/"))
            out.append(contentsOf: names[off ..< off + len])
        }
        return out
    }
}
