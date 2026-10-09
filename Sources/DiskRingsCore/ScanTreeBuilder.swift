/// Baut einen `ScanTree` aus Einträgen im Speicher, ohne Dateisystem.
///
/// Gedacht für Fixture-Bäume (Tests, gerenderte Vorschauen der Oberfläche)
/// und für synthetische Bäume in Performance-Messungen. Größen werden wie
/// beim Scan nach oben propagiert und die Kinder absteigend sortiert.
public struct ScanTreeBuilder: Sendable {
    private var parents: [Int32] = []
    private var nameBytes: [UInt8] = []
    private var nameRanges: [(offset: Int, length: Int)] = []
    private var flags: [NodeFlags] = []
    private var allocated: [UInt64] = []
    private var logical: [UInt64] = []
    private var ownFiles: [UInt32] = []

    /// Legt die Wurzel (Index 0) an.
    public init(rootName: String, reserve: Int = 0) {
        if reserve > 0 {
            parents.reserveCapacity(reserve)
            nameRanges.reserveCapacity(reserve)
            flags.reserveCapacity(reserve)
            allocated.reserveCapacity(reserve)
            logical.reserveCapacity(reserve)
            ownFiles.reserveCapacity(reserve)
        }
        _ = append(parent: -1, name: rootName, flags: .directory, allocated: 0, logical: 0, files: 0)
    }

    public var count: Int { parents.count }

    /// Legt einen Ordner an und gibt seinen (vorläufigen) Index zurück.
    @discardableResult
    public mutating func directory(_ name: String, in parent: Int32 = 0, flags extra: NodeFlags = []) -> Int32 {
        append(parent: parent, name: name, flags: extra.union(.directory), allocated: 0, logical: 0, files: 0)
    }

    /// Legt eine Datei an. Ohne `logical` ist die logische gleich der belegten Größe.
    @discardableResult
    public mutating func file(
        _ name: String, size: UInt64, logical: UInt64? = nil, in parent: Int32 = 0, flags extra: NodeFlags = []
    ) -> Int32 {
        append(parent: parent, name: name, flags: extra.subtracting(.directory),
               allocated: size, logical: logical ?? size, files: 1)
    }

    /// Ordner mit eigener, nicht aufgeschlüsselter Größe (wie in den
    /// Live-Snapshots der Scan-Engine, in denen Dateien noch fehlen).
    @discardableResult
    public mutating func partialDirectory(_ name: String, ownSize: UInt64, files: UInt32, in parent: Int32 = 0) -> Int32 {
        append(parent: parent, name: name, flags: .directory, allocated: ownSize, logical: ownSize, files: files)
    }

    private mutating func append(
        parent: Int32, name: String, flags f: NodeFlags, allocated a: UInt64, logical l: UInt64, files: UInt32
    ) -> Int32 {
        precondition(parent < Int32(parents.count), "Elternknoten muss vor dem Kind angelegt werden")
        let idx = Int32(parents.count)
        parents.append(parent)
        let bytes = Array(name.utf8.prefix(Int(UInt16.max)))
        nameRanges.append((nameBytes.count, bytes.count))
        nameBytes.append(contentsOf: bytes)
        flags.append(f)
        allocated.append(a)
        logical.append(l)
        ownFiles.append(files)
        return idx
    }

    /// Erzeugt den sortierten Baum. Die Indizes im Ergebnis entsprechen
    /// **nicht** denen, die `directory`/`file` geliefert haben; Knoten
    /// findet man über `ScanTree.index(ofPath:)`.
    public func build(rootPath: String) -> ScanTree {
        var raw = RawTree()
        raw.reserve(parents.count, nameBytes: nameBytes.count)
        nameBytes.withUnsafeBufferPointer { all in
            for i in parents.indices {
                let r = nameRanges[i]
                raw.append(parent: parents[i], name: UnsafeBufferPointer(rebasing: all[r.offset ..< r.offset + r.length]),
                           flags: flags[i], allocated: allocated[i], logical: logical[i], ownFiles: ownFiles[i])
            }
        }
        // Ohne Abbruch-Callback kann der Aufbau nicht fehlschlagen.
        // swiftlint:disable:next force_try
        return try! TreeBuilder.build(raw, rootPath: rootPath)
    }
}
