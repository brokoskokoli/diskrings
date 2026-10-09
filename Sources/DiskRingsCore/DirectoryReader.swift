import Darwin

/// Ein Verzeichniseintrag, wie ihn `getattrlistbulk` liefert. `name` zeigt in
/// den Lesepuffer und ist nur innerhalb des Callbacks gültig.
struct RawEntry {
    var name: UnsafeBufferPointer<UInt8>
    var objType: UInt32
    var dev: Int32
    var fileID: UInt64
    /// `st_flags` (`UF_HIDDEN`, `SF_DATALESS` …).
    var bsdFlags: UInt32
    var linkCount: UInt32
    var allocatedSize: UInt64
    var logicalSize: UInt64
    /// `DIR_MNTSTATUS_*` bei Ordnern.
    var mountStatus: UInt32
    /// Eigene belegte Größe eines Ordners (`ATTR_DIR_ALLOCSIZE`, entspricht
    /// `st_blocks * 512`). Auf APFS 0, auf ExFAT/FAT ein Cluster und mehr.
    var dirAllocatedSize: UInt64
    /// Fehlercode für diesen Eintrag (0 = in Ordnung).
    var error: UInt32
}

enum FileFlags {
    static let hidden: UInt32 = 0x0000_8000 // UF_HIDDEN
    static let dataless: UInt32 = 0x4000_0000 // SF_DATALESS
}

/// Liest Verzeichnisse blockweise mit `getattrlistbulk`: Name, Typ, Gerät,
/// Inode, Flags, Linkanzahl, belegte und logische Größe in einem Syscall pro
/// Block statt `readdir` plus `lstat` pro Eintrag.
struct DirectoryReader: ~Copyable {
    private let buffer: UnsafeMutableRawBufferPointer
    private var attrs: attrlist

    static let bufferSize = 256 * 1024

    init() {
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        attrs.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS) | attrgroup_t(ATTR_DIR_ALLOCSIZE)
        attrs.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_DATALENGTH)
    }

    deinit { buffer.deallocate() }

    /// Liest alle Einträge des geöffneten Verzeichnisses. Gibt 0 oder den
    /// `errno` des ersten fehlgeschlagenen Aufrufs zurück. `shouldStop` wird
    /// nach jedem Block geprüft, `onBlock` nach jedem gelesenen Block
    /// aufgerufen (Herzschlag für die Fortschrittsanzeige).
    mutating func read(
        fd: Int32,
        shouldStop: () -> Bool,
        onBlock: () -> Void = {},
        _ body: (RawEntry) -> Void
    ) -> Int32 {
        let base = buffer.baseAddress!
        while true {
            let count = getattrlistbulk(fd, &attrs, base, buffer.count, 0)
            if count < 0 { return errno }
            if count == 0 { return 0 }
            var p = base
            for _ in 0 ..< count {
                let entryLength = Int(p.loadUnaligned(as: UInt32.self))
                Self.parse(p, body)
                p += entryLength
            }
            onBlock()
            if shouldStop() { return 0 }
        }
    }

    @inline(__always)
    private static func parse(_ entryStart: UnsafeMutableRawPointer, _ body: (RawEntry) -> Void) {
        var p = UnsafeRawPointer(entryStart) + MemoryLayout<UInt32>.size
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size

        var e = RawEntry(
            name: UnsafeBufferPointer(start: nil, count: 0), objType: 0, dev: 0, fileID: 0,
            bsdFlags: 0, linkCount: 1, allocatedSize: 0, logicalSize: 0, mountStatus: 0, dirAllocatedSize: 0,
            error: 0
        )
        let common = returned.commonattr
        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            e.error = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if common & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let ref = p.loadUnaligned(as: attrreference_t.self)
            let start = (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
            // Länge enthält das abschließende NUL.
            e.name = UnsafeBufferPointer(start: start, count: max(Int(ref.attr_length) - 1, 0))
            p += MemoryLayout<attrreference_t>.size
        }
        if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            e.dev = p.loadUnaligned(as: Int32.self)
            p += 4
        }
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            e.objType = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            e.bsdFlags = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            e.fileID = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            e.mountStatus = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if returned.dirattr & attrgroup_t(ATTR_DIR_ALLOCSIZE) != 0 {
            e.dirAllocatedSize = UInt64(clamping: p.loadUnaligned(as: off_t.self))
            p += 8
        }
        let file = returned.fileattr
        if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            e.linkCount = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            e.allocatedSize = UInt64(clamping: p.loadUnaligned(as: off_t.self))
            p += 8
        }
        if file & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            e.logicalSize = UInt64(clamping: p.loadUnaligned(as: off_t.self))
            p += 8
        }
        body(e)
    }
}

/// Flags zum Öffnen eines Verzeichnisses zum Lesen, ohne Symlinks zu folgen.
let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

/// Öffnet ein Verzeichnis ohne Symlinks zu folgen. Pfade über `PATH_MAX`
/// werden stückweise mit `openat` geöffnet.
func openDirectory(_ path: String) -> Int32 {
    let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    let utf8 = path.utf8
    if utf8.count < Int(PATH_MAX) - 1 {
        return open(path, flags)
    }
    // Lange Pfade: in Stücke unter PATH_MAX an „/“-Grenzen zerlegen.
    let bytes = Array(utf8)
    var fd: Int32 = bytes.first == UInt8(ascii: "/") ? open("/", flags) : AT_FDCWD
    var start = bytes.first == UInt8(ascii: "/") ? 1 : 0
    let limit = Int(PATH_MAX) - 64
    while start < bytes.count {
        var end = min(start + limit, bytes.count)
        if end < bytes.count {
            while end > start, bytes[end] != UInt8(ascii: "/") { end -= 1 }
            if end == start { // einzelne Komponente zu lang
                if fd >= 0 { close(fd) }
                errno = ENAMETOOLONG
                return -1
            }
        }
        let chunk = String(decoding: bytes[start ..< end], as: UTF8.self)
        let next = openat(fd, chunk, flags)
        let savedErrno = errno
        if fd >= 0 { close(fd) }
        if next < 0 { errno = savedErrno; return -1 }
        fd = next
        start = end + 1
    }
    return fd
}
