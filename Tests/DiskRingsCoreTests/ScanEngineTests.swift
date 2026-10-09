@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

@Suite("ScanEngine: Größen und Struktur", .timeLimit(.minutes(2)))
struct ScanEngineSizeTests {
    @Test("Größen, Summen und Sortierung stimmen mit lstat überein")
    func sizesAndSums() throws {
        let fx = try Fixture()
        let big = try fx.file("gross/datei.bin", size: 300_000)
        let mid = try fx.file("gross/unter/mittel.bin", size: 50_000)
        let small = try fx.file("klein.txt", size: 10)
        try fx.file("leer.txt", size: 0)
        try fx.dir("leerer-ordner")

        let r = try scan(fx.root) { $0.workerCount = 1 }
        let t = r.tree
        expectValidTree(t)
        #expect(t.rootPath == fx.root)
        #expect(r.fileCount == 4)
        #expect(r.directoryCount == 4) // Wurzel, gross, gross/unter, leerer-ordner
        #expect(r.allocatedSize == fx.expectedAllocatedTotal())
        #expect(r.logicalSize == 300_000 + 50_000 + 10)

        let gross = try #require(t.root.child(named: "gross"))
        #expect(gross.allocatedSize == Fixture.allocated(big) + Fixture.allocated(mid))
        #expect(gross.logicalSize == 350_000)
        #expect(gross.fileCount == 2)
        #expect(t.root.children.first?.name == "gross")
        #expect(t.root.child(named: "klein.txt")?.allocatedSize == Fixture.allocated(small))
        #expect(t.root.child(named: "klein.txt")?.logicalSize == 10)
        #expect(t.root.child(named: "leerer-ordner")?.isDirectory == true)
        #expect(t.root.child(named: "leerer-ordner")?.childCount == 0)
        #expect(r.unreadablePaths.isEmpty)
    }

    @Test("Leere Ordner und leere Wurzel")
    func emptyDirs() throws {
        let fx = try Fixture()
        let r0 = try scan(fx.root)
        #expect(r0.tree.count == 1)
        #expect(r0.allocatedSize == 0)
        #expect(r0.fileCount == 0)

        try fx.dir("a/b/c/d")
        try fx.dir("e")
        let r = try scan(fx.root)
        expectValidTree(r.tree)
        #expect(r.tree.count == 6)
        #expect(r.fileCount == 0)
        #expect(r.allocatedSize == 0)
        #expect(r.tree.index(ofPath: fx.path("a/b/c/d")) != nil)
    }

    @Test("Eine einzelne Datei als Wurzel")
    func fileRoot() throws {
        let fx = try Fixture()
        let p = try fx.file("einzeln.bin", size: 5000)
        let r = try scan(p)
        #expect(r.tree.count == 1)
        #expect(r.fileCount == 1)
        #expect(r.allocatedSize == Fixture.allocated(p))
        #expect(r.logicalSize == 5000)
        #expect(r.tree.root.name == "einzeln.bin")
    }

    @Test("Nicht vorhandener Pfad wirft notFound")
    func notFound() throws {
        let fx = try Fixture()
        #expect(throws: ScanError.notFound(fx.path("fehlt"))) {
            try scan(fx.path("fehlt"))
        }
    }

    @Test("Symlink als Wurzel wird aufgelöst, Tilde expandiert")
    func rootResolution() throws {
        let fx = try Fixture()
        try fx.file("ziel/a.bin", size: 8000)
        try fx.symlink("verweis", to: fx.path("ziel"))
        let r = try scan(fx.path("verweis"))
        #expect(r.tree.rootPath == fx.path("ziel"))
        #expect(r.fileCount == 1)
        #expect(ScanEngine.resolve("~") == ScanEngine.resolve(NSHomeDirectory()))
    }

    @Test("Hardlinks werden nur einmal gezählt")
    func hardlinks() throws {
        let fx = try Fixture()
        let original = try fx.file("a/original.bin", size: 200_000)
        try fx.hardlink(original, "b/link1.bin")
        try fx.hardlink(original, "c/tief/link2.bin")
        let one = Fixture.allocated(original)

        let r = try scan(fx.root)
        expectValidTree(r.tree)
        #expect(r.allocatedSize == one)
        #expect(r.logicalSize == 200_000)
        #expect(r.hardlinkDuplicates == 2)
        #expect(r.fileCount == 3) // Einträge zählen, Bytes nur einmal

        // Gezählt wird das Vorkommen mit dem kleinsten Pfad.
        let a = try #require(r.tree.index(ofPath: original))
        #expect(r.tree.node(a).allocatedSize == one)
        #expect(!r.tree.node(a).flags.contains(.hardlinkDuplicate))
        let l1 = try #require(r.tree.index(ofPath: fx.path("b/link1.bin")))
        #expect(r.tree.node(l1).allocatedSize == 0)
        #expect(r.tree.node(l1).flags.contains(.hardlinkDuplicate))
        #expect(r.tree.root.child(named: "a")?.allocatedSize == one)
        #expect(r.tree.root.child(named: "c")?.allocatedSize == 0)
    }

    @Test("Hardlink auf eine Datei außerhalb der Wurzel zählt (wie du)")
    func hardlinkOutside() throws {
        let fx = try Fixture()
        let original = try fx.file("draussen/x.bin", size: 100_000)
        try fx.hardlink(original, "innen/y.bin")
        let r = try scan(fx.path("innen"))
        #expect(r.allocatedSize == Fixture.allocated(original))
        #expect(r.hardlinkDuplicates == 0)
    }

    @Test("Sparse-Datei: belegt deutlich weniger als logisch")
    func sparse() throws {
        let fx = try Fixture()
        let logical = 1 << 30 // 1 GiB
        let p = try fx.sparseFile("sparse.img", logical: logical)
        let r = try scan(fx.root)
        let node = try #require(r.tree.root.child(named: "sparse.img"))
        #expect(node.logicalSize == UInt64(logical))
        #expect(node.allocatedSize == Fixture.allocated(p))
        #expect(node.allocatedSize < UInt64(logical) / 100)
        #expect(r.allocatedSize < UInt64(logical) / 100)
    }

    @Test("Symlink-Zyklen führen zu keinem Hänger")
    func symlinkCycle() throws {
        let fx = try Fixture()
        try fx.file("a/datei.bin", size: 4000)
        try fx.symlink("a/zurueck", to: "..")
        try fx.symlink("a/wurzel", to: fx.root)
        try fx.symlink("selbst", to: "selbst")
        try fx.symlink("x", to: "y")
        try fx.symlink("y", to: "x")
        let start = Date()
        let r = try scan(fx.root)
        #expect(Date().timeIntervalSince(start) < 5)
        expectValidTree(r.tree)
        #expect(r.fileCount == 6) // datei.bin + 5 Symlinks
        let link = try #require(r.tree.root.child(named: "a")?.child(named: "zurueck"))
        #expect(link.isSymlink)
        #expect(!link.isDirectory)
        #expect(link.childCount == 0)
    }

    @Test("Symlink auf einen großen Ordner zählt nur mit eigener Größe")
    func symlinkToBigDir() throws {
        let fx = try Fixture()
        try fx.file("gross/riesig.bin", size: 5_000_000)
        try fx.dir("innen")
        try fx.symlink("innen/verweis", to: fx.path("gross"))
        let r = try scan(fx.path("innen"))
        let link = try #require(r.tree.root.child(named: "verweis"))
        #expect(link.isSymlink)
        #expect(r.allocatedSize < 100_000)
        #expect(r.allocatedSize == Fixture.allocated(fx.path("innen/verweis")))
    }

    @Test("Unlesbarer Ordner wird markiert, der Scan läuft weiter", .enabled(if: getuid() != 0))
    func unreadable() throws {
        let fx = try Fixture()
        try fx.file("gesperrt/geheim.bin", size: 100_000)
        try fx.file("offen/da.bin", size: 20_000)
        chmod(fx.path("gesperrt"), 0o000)
        defer { chmod(fx.path("gesperrt"), 0o755) }

        let r = try scan(fx.root)
        expectValidTree(r.tree)
        let locked = try #require(r.tree.root.child(named: "gesperrt"))
        #expect(locked.isUnreadable)
        #expect(locked.isDirectory)
        #expect(locked.childCount == 0)
        #expect(locked.allocatedSize == 0)
        #expect(r.unreadablePaths == [fx.path("gesperrt")])
        #expect(r.tree.root.child(named: "offen")?.fileCount == 1)
        #expect(r.tree.paths(withFlag: .unreadable) == [fx.path("gesperrt")])
    }

    @Test("Unlesbare Wurzel ergibt markierten Baum statt Absturz", .enabled(if: getuid() != 0))
    func unreadableRoot() throws {
        let fx = try Fixture()
        try fx.file("zu/x.bin", size: 1000)
        chmod(fx.path("zu"), 0o000)
        defer { chmod(fx.path("zu"), 0o755) }
        let r = try scan(fx.path("zu"))
        #expect(r.tree.root.isUnreadable)
        #expect(r.tree.count == 1)
    }

    @Test("Unicode- und NFD-Namen bleiben bytegenau erhalten")
    func unicodeNames() throws {
        let fx = try Fixture()
        let nfd: [UInt8] = Array("Mu\u{0308}ller.txt".utf8) // u + kombinierendes Trema
        let nfc: [UInt8] = Array("Grüße.txt".precomposedStringWithCanonicalMapping.utf8)
        try fx.rawFile(dir: "namen", nameBytes: nfd, size: 100)
        try fx.rawFile(dir: "namen", nameBytes: nfc, size: 200)
        try fx.file("namen/😀 Emoji ✓/日本語.bin", size: 300)

        let r = try scan(fx.root)
        expectValidTree(r.tree)
        let namen = try #require(r.tree.root.child(named: "namen"))
        let byBytes = namen.children.map { Array(r.tree.nameBytes(of: $0.index)) }
        #expect(byBytes.contains(nfd))
        #expect(byBytes.contains(nfc))
        #expect(namen.fileCount == 3)
        let emoji = try #require(namen.child(named: "😀 Emoji ✓"))
        #expect(emoji.child(named: "日本語.bin")?.logicalSize == 300)
        #expect(emoji.children.first?.path == fx.path("namen/😀 Emoji ✓/日本語.bin"))
        let nfdNode = try #require(namen.children.first { Array(r.tree.nameBytes(of: $0.index)) == nfd })
        #expect(nfdNode.logicalSize == 100)
    }

    @Test("Sehr tiefe Verschachtelung (500 Ebenen, Pfad über PATH_MAX)")
    func deepNesting() throws {
        let fx = try Fixture()
        try fx.deepChain("tief", depth: 500, component: "ebene", leafFileSize: 7000)
        let r = try scan(fx.root) { $0.workerCount = 4 }
        expectValidTree(r.tree)
        #expect(r.fileCount == 1)
        #expect(r.unreadablePaths.isEmpty)
        #expect(r.directoryCount == 502)
        var n = try #require(r.tree.root.child(named: "tief"))
        for _ in 0 ..< 501 { n = try #require(n.children.first) }
        #expect(n.name == "blatt.bin")
        #expect(n.depth == 502)
        #expect(n.logicalSize == 7000)
        #expect(n.path.utf8.count > Int(PATH_MAX))
        #expect(r.allocatedSize == n.allocatedSize)
        #expect(n.allocatedSize > 0)
    }

    @Test("Viele Dateien (50 000)")
    func manyFiles() throws {
        let fx = try Fixture()
        var expectedLogical: UInt64 = 0
        for d in 0 ..< 50 {
            let dir = try fx.dir("viele/d\(d)")
            for f in 0 ..< 1000 {
                let size = (f % 10 == 0) ? 1000 + f : 0
                let fd = open("\(dir)/f\(f)", O_WRONLY | O_CREAT, 0o644)
                if size > 0 {
                    let buf = [UInt8](repeating: 0x41, count: size)
                    _ = buf.withUnsafeBytes { write(fd, $0.baseAddress, size) }
                    expectedLogical += UInt64(size)
                }
                close(fd)
            }
        }
        let r = try scan(fx.root)
        expectValidTree(r.tree)
        #expect(r.fileCount == 50_000)
        #expect(r.directoryCount == 52)
        #expect(r.logicalSize == expectedLogical)
        #expect(r.allocatedSize == fx.expectedAllocatedTotal())
        #expect(r.tree.count == 50_052)
    }
}

@Suite("ScanEngine: Optionen und Markierungen")
struct ScanEngineOptionTests {
    @Test("Pakete bekommen ein Flag und werden durchlaufen")
    func packages() throws {
        let fx = try Fixture()
        try fx.file("Programm.app/Contents/MacOS/programm", size: 30_000)
        try fx.file("Fotos.photoslibrary/originals/bild.heic", size: 40_000)
        try fx.file("Gross.APP/x", size: 10)
        try fx.file("normal.ordner/x", size: 10)
        try fx.file("datei.app", size: 10) // Datei, kein Ordner
        let r = try scan(fx.root)
        let app = try #require(r.tree.root.child(named: "Programm.app"))
        #expect(app.isPackage)
        #expect(app.fileCount == 1)
        #expect(app.child(named: "Contents")?.isPackage == false)
        #expect(r.tree.root.child(named: "Fotos.photoslibrary")?.isPackage == true)
        #expect(r.tree.root.child(named: "Gross.APP")?.isPackage == true)
        #expect(r.tree.root.child(named: "normal.ordner")?.isPackage == false)
        #expect(r.tree.root.child(named: "datei.app")?.isPackage == false)
        #expect(PackageDetector.isPackage(name: "X.xcodeproj"))
        #expect(!PackageDetector.isPackage(name: ".app"))
        #expect(!PackageDetector.isPackage(name: "app"))
    }

    @Test("Versteckte Dateien ein- und ausschaltbar")
    func hidden() throws {
        let fx = try Fixture()
        try fx.file("sichtbar.bin", size: 10_000)
        try fx.file(".versteckt.bin", size: 20_000)
        try fx.file(".git/objects/blob", size: 30_000)
        let flagged = try fx.file("ui-versteckt.bin", size: 40_000)
        #expect(chflags(flagged, UInt32(UF_HIDDEN)) == 0)

        let all = try scan(fx.root)
        #expect(all.fileCount == 4)
        #expect(all.tree.root.child(named: ".versteckt.bin")?.flags.contains(.hidden) == true)
        #expect(all.tree.root.child(named: "ui-versteckt.bin")?.flags.contains(.hidden) == true)
        #expect(all.tree.root.child(named: "sichtbar.bin")?.flags.contains(.hidden) == false)

        let visible = try scan(fx.root) { $0.includeHidden = false }
        expectValidTree(visible.tree)
        #expect(visible.fileCount == 1)
        #expect(visible.tree.root.children.map(\.name) == ["sichtbar.bin"])
        #expect(visible.allocatedSize == Fixture.allocated(fx.path("sichtbar.bin")))
    }

    @Test("Ausschlussliste überspringt Ordner und Dateien")
    func exclusions() throws {
        let fx = try Fixture()
        try fx.file("behalten/a.bin", size: 10_000)
        try fx.file("weg/b.bin", size: 50_000)
        try fx.file("weg/tief/c.bin", size: 50_000)
        try fx.file("behalten/auch-weg.bin", size: 70_000)
        let r = try scan(fx.root) {
            $0.excludedPaths = [fx.path("weg") + "/", fx.path("behalten/auch-weg.bin"), "/gibt/es/nicht"]
        }
        expectValidTree(r.tree)
        #expect(r.tree.root.children.map(\.name) == ["behalten"])
        #expect(r.fileCount == 1)
        #expect(r.allocatedSize == Fixture.allocated(fx.path("behalten/a.bin")))
    }

    @Test("Ausschluss über einen unaufgelösten Pfad (Symlink im Präfix)")
    func exclusionThroughSymlinkPrefix() throws {
        let fx = try Fixture()
        try fx.file("echt/weg/x.bin", size: 10_000)
        try fx.file("echt/da/y.bin", size: 10_000)
        try fx.symlink("alias", to: fx.path("echt"))
        let r = try scan(fx.path("echt")) { $0.excludedPaths = [fx.path("alias/weg")] }
        #expect(r.tree.root.children.map(\.name) == ["da"])
    }

    @Test("K1: Zwischen Auflisten und Öffnen verschwundener Ordner wird still verworfen")
    func vanishedDirectory() throws {
        let fx = try Fixture()
        try fx.file("bleibt/a.bin", size: 1000)
        try fx.dir("weg/innen")
        let target = fx.path("weg/innen")
        var engine = ScanEngine(options: ScanOptions(workerCount: 1))
        engine.hooks.beforeOpenDirectory = { p in if p == target { rmdir(target) } }
        let r = try engine.scanBlocking(fx.root)
        expectValidTree(r.tree)
        #expect(r.unreadablePaths.isEmpty)
        #expect(r.tree.paths(withFlag: .unreadable).isEmpty)
        #expect(r.tree.index(ofPath: target) == nil)
        #expect(r.tree.root.child(named: "weg")?.childCount == 0)
        #expect(r.directoryCount == 3) // Wurzel, bleibt, weg
    }

    @Test("K3: Unterordner werden relativ zum Elternordner geöffnet (kein Pfad-Tausch per Symlink)")
    func openatRelativeToParent() throws {
        let fx = try Fixture()
        try fx.file("scan/a/b/echt.bin", size: 4000)
        try fx.file("fremd/b/fremd.bin", size: 400_000)
        let a = fx.path("scan/a")
        let target = fx.path("scan/a/b")
        let fremd = fx.path("fremd")
        var engine = ScanEngine(options: ScanOptions(workerCount: 1))
        // Nachdem „a“ gelesen wurde, wird „a“ gegen einen Symlink getauscht.
        engine.hooks.beforeOpenDirectory = { p in
            if p == target {
                rename(a, a + "-alt")
                Darwin.symlink(fremd, a)
            }
        }
        let r = try engine.scanBlocking(fx.path("scan"))
        let b = try #require(r.tree.index(ofPath: target))
        #expect(r.tree[b].children.map(\.name) == ["echt.bin"])
        #expect(r.allocatedSize < 100_000)
    }

    @Test("Einhängepunkte werden nicht betreten")
    func mountPoints() throws {
        // /System/Volumes enthält nur Einhängepunkte (Data, VM, Preboot …).
        var st = stat()
        try #require(lstat("/System/Volumes/Data", &st) == 0)
        let r = try scan("/System/Volumes")
        let data = try #require(r.tree.root.child(named: "Data"))
        #expect(data.flags.contains(.mountPoint))
        #expect(data.childCount == 0)
        #expect(r.skippedMountPoints.contains("/System/Volumes/Data"))
        // Kein Inhalt eines anderen Volumes landet im Baum.
        #expect(r.tree.count < 200)
    }

    @Test("Firmlinks: Data-Volume-Einhängepunkt wird nie betreten, seine Geräte-ID ist erlaubt")
    func firmlinkDevices() throws {
        var sRoot = stat(), sData = stat(), sUsers = stat()
        try #require(lstat("/", &sRoot) == 0 && lstat("/System/Volumes/Data", &sData) == 0)
        try #require(ScanContext.isMountPoint("/System/Volumes/Data"))
        #expect(ScanContext.isMountPoint("/"))
        #expect(!ScanContext.isMountPoint("/usr"))
        let ctx = ScanContext(options: ScanOptions(), rootPath: "/", rootDev: sRoot.st_dev, rootName: "/",
                              cancellation: ScanCancellation())
        // Seit macOS 10.15 haben System- und Data-Volume dasselbe st_dev.
        #expect(ctx.allowedDevices == Set([sRoot.st_dev, sData.st_dev]))
        #expect(ctx.neverEnter == ["/System/Volumes/Data"])
        // Firmlink: /Users liegt auf dem Data-Volume, erscheint aber unter /
        // und muss deshalb erlaubt sein.
        try #require(lstat("/Users", &sUsers) == 0)
        #expect(ctx.allowedDevices.contains(sUsers.st_dev))
    }
}

@Suite("ScanEngine: Abgleich mit du", .serialized, .timeLimit(.minutes(2)))
struct ScanEngineDuTests {
    @Test("S3: Fixture-Baum ergibt exakt du -sk (Hardlinks, Sparse, Symlink)")
    func fixtureVsDu() throws {
        let fx = try Fixture()
        for i in 0 ..< 200 {
            try fx.file("a\(i % 7)/b\(i % 3)/f\(i).bin", size: (i * 7919) % 300_000)
        }
        let orig = try fx.file("h/orig.bin", size: 123_456)
        try fx.hardlink(orig, "h/zwei.bin")
        _ = try fx.sparseFile("sparse.bin", logical: 50_000_000)
        try fx.symlink("link", to: "a0")
        try fx.dir("leer/ganz/tief")
        let r = try scan(fx.root) { $0.workerCount = 4 }
        #expect(r.hardlinkDuplicates == 1)
        #expect(r.allocatedSize == (try duBytes(fx.root)))
    }

    @Test("S3: Genau zwei Hardlinks – exakte Größen und Markierung")
    func twoHardlinksExact() throws {
        let fx = try Fixture()
        let orig = try fx.file("x/orig.bin", size: 300_000)
        try fx.hardlink(orig, "y/zwei.bin")
        let one = Fixture.allocated(orig)
        var st = stat()
        #expect(lstat(orig, &st) == 0 && st.st_nlink == 2)
        let r = try scan(fx.root)
        expectValidTree(r.tree)
        #expect(r.hardlinkDuplicates == 1)
        #expect(r.fileCount == 2)
        #expect(r.allocatedSize == one)
        #expect(r.logicalSize == 300_000)
        #expect(r.tree.root.child(named: "x")?.allocatedSize == one)
        #expect(r.tree.root.child(named: "y")?.allocatedSize == 0)
        #expect(r.tree.root.child(named: "y")?.child(named: "zwei.bin")?.isHardlinkDuplicate == true)
        #expect(r.allocatedSize == (try duBytes(fx.root)))
    }

    /// Füllt ein eingehängtes Image mit vielen Ordnern und Dateien.
    func populate(_ root: String) throws {
        for d in 0 ..< 40 {
            let dir = root + "/ordner\(d % 8)/unter\(d)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for f in 0 ..< (d % 5) {
                let data = Data(repeating: UInt8(f), count: 1000 + d * 3000 + f * 17)
                try data.write(to: URL(fileURLWithPath: dir + "/f\(f).bin"))
            }
        }
        try FileManager.default.createDirectory(atPath: root + "/leer/a/b/c", withIntermediateDirectories: true)
    }

    @Test("S1: Ordner-Eigengröße zählt mit – ExFAT-Image gleich du -sk",
          .enabled(if: DiskImage.isAvailable, "hdiutil nicht verfügbar"))
    func exfatVsDu() throws {
        let fx = try Fixture()
        let img = try DiskImage(fs: "ExFAT", in: fx.root)
        defer { img.detach() }
        try populate(img.mountPoint)
        let r = try scan(img.mountPoint) { $0.workerCount = 4 }
        let du = try duBytes(img.mountPoint)
        #expect(r.allocatedSize == du, "Scan \(r.allocatedSize) vs. du \(du)")
        // Ordner belegen auf ExFAT eigene Cluster.
        let leer = try #require(r.tree.index(ofPath: img.mountPoint + "/leer/a/b/c"))
        #expect(r.tree.node(leer).allocatedSize == Fixture.allocated(img.mountPoint + "/leer/a/b/c"))
        #expect(r.tree.node(leer).allocatedSize > 0)
        #expect(r.tree.node(leer).logicalSize == 0)
        expectValidTree(r.tree)
    }

    @Test("S1: HFS+-Image (mit Hardlinks) gleich du -sk",
          .enabled(if: DiskImage.isAvailable, "hdiutil nicht verfügbar"))
    func hfsVsDu() throws {
        let fx = try Fixture()
        let img = try DiskImage(fs: "HFS+", in: fx.root)
        defer { img.detach() }
        try populate(img.mountPoint)
        let orig = img.mountPoint + "/ordner1/unter1/f0.bin"
        #expect(link(orig, img.mountPoint + "/ordner2/zweit.bin") == 0)
        let r = try scan(img.mountPoint) { $0.workerCount = 4 }
        let du = try duBytes(img.mountPoint)
        #expect(r.allocatedSize == du, "Scan \(r.allocatedSize) vs. du \(du)")
        #expect(r.hardlinkDuplicates >= 1)
        expectValidTree(r.tree)
    }

    @Test("Integration: /usr/share, Abweichung zu du -sk unter 1 %")
    func usrShareVsDu() throws {
        let r = try ScanEngine().scanBlocking("/usr/share")
        let du = try duBytes("/usr/share")
        let diff = Double(max(r.allocatedSize, du) - min(r.allocatedSize, du)) / Double(max(du, 1))
        #expect(diff < 0.01, "Scan \(r.allocatedSize) vs. du \(du)")
        #expect(r.fileCount > 1000)
        expectValidTree(r.tree)
    }
}

@Suite("ScanEngine: Parallelität, Abbruch, Fortschritt", .serialized, .timeLimit(.minutes(2)))
struct ScanEngineConcurrencyTests {
    @Test("Paralleler und sequenzieller Scan ergeben identische Bäume (Fixture)")
    func determinismFixture() throws {
        let fx = try Fixture()
        for d in 0 ..< 30 {
            for f in 0 ..< 40 {
                // Viele gleich große Dateien erzwingen den Namens-Tiebreak.
                try fx.file("o\(d % 5)/u\(d)/f\(f).bin", size: (f % 4) * 4096)
            }
        }
        let shared = try fx.file("o0/geteilt.bin", size: 100_000)
        for i in 0 ..< 10 { try fx.hardlink(shared, "o\(i % 5)/u\(i)/link\(i).bin") }
        try fx.deepChain("o4/tief", depth: 60, leafFileSize: 100)

        let seq = try scan(fx.root) { $0.workerCount = 1 }
        for workers in [2, 8] {
            let par = try scan(fx.root) {
                $0.workerCount = workers
                $0.splitThreshold = 10
            }
            #expect(par.tree.isIdentical(to: seq.tree), "\(workers) Worker")
            #expect(par.hardlinkDuplicates == seq.hardlinkDuplicates)
        }
        #expect(seq.hardlinkDuplicates == 10)
    }

    @Test("Paralleler und sequenzieller Scan ergeben identische Bäume (/usr/share)")
    func determinismReal() throws {
        let seq = try scan("/usr/share") { $0.workerCount = 1 }
        let par = try scan("/usr/share") { $0.workerCount = 8; $0.splitThreshold = 100 }
        #expect(par.tree.isIdentical(to: seq.tree))
    }

    @Test("Abbruch vor dem Start wirft sofort")
    func cancelBeforeStart() throws {
        let token = ScanCancellation()
        token.cancel()
        #expect(throws: CancellationError.self) {
            try ScanEngine().scanBlocking("/usr/share", cancellation: token)
        }
    }

    @Test("Abbruch während des Scans greift in unter 0,5 s")
    func cancelLatency() throws {
        let token = ScanCancellation()
        let cancelledAt = OSAllocatedUnfairLockBox<Date?>(nil)
        let engine = ScanEngine(options: ScanOptions(progressInterval: 0.01))
        var thrown: Error?
        do {
            _ = try engine.scanBlocking("/System/Library", cancellation: token, onProgress: { p in
                if p.filesScanned > 0, cancelledAt.value == nil {
                    cancelledAt.value = Date()
                    token.cancel()
                }
            })
        } catch {
            thrown = error
        }
        let start = try #require(cancelledAt.value, "Scan war zu schnell für den Test")
        let latency = Date().timeIntervalSince(start)
        #expect(thrown is CancellationError)
        #expect(latency < 0.5, "Abbruch dauerte \(latency) s")
    }

    @Test("S5: Abbruch mit mehreren aktiven Workern nach ≥ 20 000 Dateien greift in unter 0,5 s")
    func cancelWithBusyWorkers() throws {
        let token = ScanCancellation()
        let cancelledAt = OSAllocatedUnfairLockBox<Date?>(nil)
        let seen = OSAllocatedUnfairLockBox<ScanProgress?>(nil)
        let engine = ScanEngine(options: ScanOptions(workerCount: 8, progressInterval: 0.005))
        var thrown: Error?
        do {
            _ = try engine.scanBlocking("/System/Library", cancellation: token, onProgress: { p in
                if cancelledAt.value == nil, p.filesScanned >= 20_000, p.activeWorkers >= 2 {
                    seen.value = p
                    cancelledAt.value = Date()
                    token.cancel()
                }
            })
        } catch {
            thrown = error
        }
        let start = try #require(cancelledAt.value, "Bedingung (≥ 20 000 Dateien, ≥ 2 aktive Worker) nie erreicht")
        let latency = Date().timeIntervalSince(start)
        #expect(thrown is CancellationError)
        #expect(latency < 0.5, "Abbruch dauerte \(latency) s")
        #expect((seen.value?.activeWorkers ?? 0) >= 2)
    }

    @Test("S5: Abbruch während des Zusammenführens bzw. Baumaufbaus", arguments: [ScanPhase.assembling, .building])
    func cancelDuringAssembly(phase: ScanPhase) throws {
        let fx = try Fixture()
        for d in 0 ..< 10 { for f in 0 ..< 50 { try fx.file("d\(d)/f\(f)", size: 100) } }
        let token = ScanCancellation()
        var engine = ScanEngine(options: ScanOptions(workerCount: 4))
        engine.hooks.phase = { p in if p == phase { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try engine.scanBlocking(fx.root, cancellation: token)
        }
        // Ohne Abbruch läuft derselbe Scan durch.
        var plain = ScanEngine(options: ScanOptions(workerCount: 4))
        plain.hooks.phase = { _ in }
        #expect(try plain.scanBlocking(fx.root).fileCount == 500)
    }

    @Test("S6: Ereignis-Stream puffert bei langsamem Konsumenten nur die neuesten Ereignisse")
    func boundedEventStream() async throws {
        let fx = try Fixture()
        for d in 0 ..< 200 { try fx.file("d\(d)/f", size: 10) }
        var engine = ScanEngine(options: ScanOptions(workerCount: 1, progressInterval: 0.001))
        // Jeder Ordner dauert 2 ms: ~400 ms Scan, ~400 Fortschrittsmeldungen.
        engine.hooks.beforeOpenDirectory = { _ in usleep(2000) }
        // Erst lesen, wenn der Scan sicher fertig ist: Eine feste Wartezeit
        // reichte auf langsamen CI-Runnern nicht (der Konsument las mit, und
        // es kamen mehr Ereignisse an als gepuffert werden).
        let building = OSAllocatedUnfairLockBox(false)
        engine.hooks.phase = { p in if p == .building { building.value = true } }
        let stream = engine.events(fx.root)
        let deadline = Date().addingTimeInterval(30)
        while !building.value, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try #require(building.value, "Scan kam nicht bis zum Baumaufbau")
        try await Task.sleep(nanoseconds: 500_000_000) // Baum von 200 Dateien und .finished: Millisekunden
        var count = 0
        var finished = false
        for try await e in stream {
            count += 1
            if case .finished(let r) = e {
                finished = true
                #expect(r.fileCount == 200)
            }
        }
        #expect(finished)
        #expect(count <= ScanEngine.eventBufferLimit, "\(count) Ereignisse gepuffert")
    }

    @Test("Abbruch der Task bricht den asynchronen Scan ab")
    func cancelAsync() async throws {
        let task = Task {
            try await ScanEngine(options: ScanOptions(progressInterval: 0.01)).scan("/System/Library")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        task.cancel()
        let result = await task.result
        let latency = Date().timeIntervalSince(start)
        if case .success = result {
            Issue.record("Scan wurde nicht abgebrochen")
        } else if case .failure(let e) = result {
            #expect(e is CancellationError)
        }
        #expect(latency < 0.5, "Abbruch dauerte \(latency) s")
    }

    @Test("Fortschrittsmeldungen sind monoton und enden mit den Endwerten")
    func progress() throws {
        let fx = try Fixture()
        for d in 0 ..< 20 {
            for f in 0 ..< 500 { try fx.file("p\(d)/f\(f)", size: f % 3 == 0 ? 5000 : 0) }
        }
        let box = OSAllocatedUnfairLockBox<[ScanProgress]>([])
        let r = try ScanEngine(options: ScanOptions(workerCount: 1, progressInterval: 0.001))
            .scanBlocking(fx.root, onProgress: { p in box.value.append(p) })
        let all = box.value
        #expect(!all.isEmpty)
        for (a, b) in zip(all, all.dropFirst()) {
            #expect(a.filesScanned <= b.filesScanned)
            #expect(a.directoriesScanned <= b.directoriesScanned)
            #expect(a.allocatedBytes <= b.allocatedBytes)
            #expect(a.elapsed <= b.elapsed)
        }
        let last = try #require(all.last)
        #expect(last.filesScanned == 10_000)
        #expect(last.directoriesScanned == 21)
        #expect(last.allocatedBytes == r.allocatedSize)
        #expect(last.currentPath.hasPrefix(fx.root))
    }

    @Test("Live-Snapshots zeigen die obersten k Ebenen mit vorläufigen Größen")
    func liveSnapshots() throws {
        let box = OSAllocatedUnfairLockBox<[ScanTree]>([])
        let engine = ScanEngine(options: ScanOptions(workerCount: 2, progressInterval: 0.02, snapshotDepth: 2))
        let r = try engine.scanBlocking("/System/Library", onSnapshot: { t in box.value.append(t) })
        let snaps = box.value
        try #require(!snaps.isEmpty)
        for s in snaps {
            #expect(s.validate().isEmpty)
            #expect(!s.isComplete)
            #expect(s.rootPath == r.tree.rootPath)
            #expect(s.nodes.allSatisfy { $0.isDirectory })
            #expect((0 ..< Int32(s.count)).allSatisfy { s.depth(of: $0) <= 2 })
            #expect(s.root.fileCount <= r.fileCount)
            // Kinder sortiert
            let kids = s.root.children.map(\.allocatedSize)
            #expect(kids == kids.sorted(by: >))
        }
        // Spätere Snapshots wachsen monoton.
        for (a, b) in zip(snaps, snaps.dropFirst()) {
            #expect(a.root.allocatedSize <= b.root.allocatedSize)
        }
        // Jeder Ordner des letzten Snapshots existiert im Endergebnis und hat
        // dort mindestens so viele Dateien. (Bytes können vorläufig höher sein,
        // weil Hardlinks erst am Ende bereinigt werden.)
        let last = try #require(snaps.last)
        var missing = 0, tooMany = 0
        for i in 1 ..< Int32(last.count) {
            guard let idx = r.tree.index(ofPath: last.path(of: i)) else { missing += 1; continue }
            if last.node(i).fileCount > r.tree.node(idx).fileCount { tooMany += 1 }
        }
        #expect(missing == 0)
        #expect(tooMany == 0)
    }

    /// CI-Befund: Auf einem langsamen Runner kam ein Live-Snapshot, bevor
    /// irgendein Ordner Größen trug; die Heuristik in `TreeBuilder` hielt ihn
    /// deshalb für vollständig.
    @Test("Früher Live-Snapshot ohne Größen gilt nie als vollständig")
    func earlyLiveSnapshotIsIncomplete() throws {
        let fx = try Fixture()
        for d in 0 ..< 3 { try fx.file("d\(d)/f", size: 1000) }
        let box = OSAllocatedUnfairLockBox<[ScanTree]>([])
        var engine = ScanEngine(options: ScanOptions(workerCount: 1, progressInterval: 0.005))
        // Der erste Ordner hängt 100 ms: Bis dahin enthält das Skelett nur Ordner ohne Größen.
        engine.hooks.beforeOpenDirectory = { _ in usleep(100_000) }
        let r = try engine.scanBlocking(fx.root, onSnapshot: { t in box.value.append(t) })
        let snaps = box.value
        try #require(!snaps.isEmpty)
        #expect(snaps.contains { $0.root.fileCount == 0 }, "Test braucht einen Snapshot vor der ersten Datei")
        #expect(snaps.allSatisfy { !$0.isComplete })
        #expect(r.tree.isComplete)
    }

    @Test("K7: Live-Snapshots reichen standardmäßig 6 Ebenen tief")
    func liveSnapshotDefaultDepth() throws {
        #expect(ScanOptions().snapshotDepth == 6)
        let fx = try Fixture()
        try fx.file("1/2/3/4/5/6/7/8/datei.bin", size: 5000)
        let box = OSAllocatedUnfairLockBox<[ScanTree]>([])
        var engine = ScanEngine(options: ScanOptions(workerCount: 1, progressInterval: 0.001))
        engine.hooks.beforeOpenDirectory = { _ in usleep(20_000) }
        _ = try engine.scanBlocking(fx.root, onSnapshot: { t in box.value.append(t) })
        let last = try #require(box.value.last)
        #expect(last.index(ofPath: "1/2/3/4/5/6") != nil)
        #expect(last.index(ofPath: "1/2/3/4/5/6/7") == nil)
    }

    @Test("Ereignis-Stream liefert Fortschritt und Endergebnis")
    func eventStream() async throws {
        let fx = try Fixture()
        try fx.file("a/b.bin", size: 10_000)
        var sawFinished = false
        var progressCount = 0
        for try await event in ScanEngine(options: ScanOptions(progressInterval: 0.001)).events(fx.root) {
            switch event {
            case .progress: progressCount += 1
            case .snapshot: break
            case .finished(let r):
                sawFinished = true
                #expect(r.fileCount == 1)
            }
        }
        #expect(sawFinished)
        #expect(progressCount >= 1)
    }
}

/// Kleiner thread-sicherer Behälter für Test-Callbacks.
final class OSAllocatedUnfairLockBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
