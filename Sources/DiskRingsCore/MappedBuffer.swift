import Darwin

/// Wachsender Puffer für einfache Werttypen, direkt per `mmap` angelegt.
///
/// Warum nicht `Array`? Die Scan-Puffer wachsen auf hunderte Megabyte und
/// werden nach dem Aufbau des Baums wieder freigegeben. Freigegebene große
/// Blöcke behält der macOS-Allocator im „Large Cache“, sodass der Speicher-
/// bedarf des Prozesses nach dem Scan nicht sinkt (gemessen: 314 MB statt
/// 92 MB für einen Baum mit 1,5 Mio. Knoten). `munmap` gibt den Speicher
/// sofort an das System zurück.
struct MappedBuffer<Element: BitwiseCopyable>: ~Copyable {
    private(set) var base: UnsafeMutablePointer<Element>?
    private(set) var count = 0
    private(set) var capacity = 0

    init() {}

    init(capacity: Int) {
        reserve(capacity)
    }

    /// Mit Nullen gefüllt (frische anonyme Seiten sind immer genullt).
    init(zeroedCount n: Int) {
        reserve(n)
        count = n
    }

    deinit {
        if let base { munmap(base, Self.bytes(for: capacity)) }
    }

    private static func bytes(for n: Int) -> Int {
        let raw = max(n, 1) * MemoryLayout<Element>.stride
        let page = Int(getpagesize())
        return (raw + page - 1) / page * page
    }

    mutating func reserve(_ n: Int) {
        guard n > capacity else { return }
        let size = Self.bytes(for: n)
        guard let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              p != MAP_FAILED
        else { fatalError("mmap von \(size) Byte fehlgeschlagen (errno \(errno))") }
        let newBase = p.bindMemory(to: Element.self, capacity: size / MemoryLayout<Element>.stride)
        if let base {
            newBase.update(from: base, count: count)
            munmap(base, Self.bytes(for: capacity))
        }
        base = newBase
        capacity = size / MemoryLayout<Element>.stride
    }

    @inline(__always)
    mutating func append(_ e: Element) {
        if count == capacity { reserve(Swift.max(capacity * 2, 4096)) }
        base.unsafelyUnwrapped[count] = e
        count += 1
    }

    mutating func append(contentsOf src: UnsafeBufferPointer<Element>) {
        guard !src.isEmpty else { return }
        if count + src.count > capacity { reserve(Swift.max(capacity * 2, count + src.count, 4096)) }
        (base.unsafelyUnwrapped + count).update(from: src.baseAddress!, count: src.count)
        count += src.count
    }

    mutating func append(contentsOf src: borrowing MappedBuffer<Element>) {
        append(contentsOf: UnsafeBufferPointer(src.buffer))
    }

    @inline(__always)
    subscript(i: Int) -> Element {
        get {
            assert(i >= 0 && i < count)
            return base.unsafelyUnwrapped[i]
        }
        nonmutating set {
            assert(i >= 0 && i < count)
            base.unsafelyUnwrapped[i] = newValue
        }
    }

    var buffer: UnsafeMutableBufferPointer<Element> {
        UnsafeMutableBufferPointer(start: base, count: count)
    }

    var isEmpty: Bool { count == 0 }

    func copy() -> MappedBuffer<Element> {
        var c = MappedBuffer(capacity: count)
        c.append(contentsOf: UnsafeBufferPointer(buffer))
        return c
    }

    func toArray() -> [Element] { Array(buffer) }
}
