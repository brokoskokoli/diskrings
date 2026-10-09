/// Deterministische Beispielbäume für gerenderte Vorschauen, Tests und
/// Performance-Messungen. Kein Dateisystemzugriff.
public enum DemoTree {
    /// Ein Home-Verzeichnis mit typischer Verteilung (Library, Filme, Fotos,
    /// Projekte …), rund 1 500 Knoten, ca. 180 GB.
    public static func home(rootPath: String = "/Users/demo") -> ScanTree {
        var b = ScanTreeBuilder(rootName: (rootPath as String).split(separator: "/").last.map(String.init) ?? "/")
        var rng = SplitMix64(seed: 42)
        let GB: UInt64 = 1_000_000_000, MB: UInt64 = 1_000_000

        func files(_ parent: Int32, prefix: String, ext: String, count: Int, avg: UInt64) {
            for i in 0 ..< count {
                let f = 0.15 + 1.7 * rng.nextUnit()
                b.file("\(prefix) \(i + 1).\(ext)", size: UInt64(Double(avg) * f * f), in: parent)
            }
        }

        let library = b.directory("Library")
        let containers = b.directory("Containers", in: library)
        for (name, size) in [("com.apple.mail", 9 * GB), ("com.docker.docker", 38 * GB), ("com.apple.Safari", 2 * GB),
                             ("com.spotify.client", 4 * GB), ("com.apple.Notes", 900 * MB)] {
            let c = b.directory(name, in: containers)
            let data = b.directory("Data", in: c)
            files(data, prefix: "blob", ext: "db", count: 6, avg: size / 6)
            files(c, prefix: "cache", ext: "bin", count: 30, avg: 2 * MB)
        }
        let caches = b.directory("Caches", in: library)
        for name in ["com.apple.Music", "Google", "com.spotify.client", "pip", "Homebrew", "com.microsoft.VSCode",
                     "org.swift.swiftpm", "com.apple.dt.Xcode"] {
            let c = b.directory(name, in: caches)
            files(c, prefix: "chunk", ext: "cache", count: 8 + Int(rng.next() % 40), avg: UInt64(rng.next() % 300) * MB + 20 * MB)
        }
        let developer = b.directory("Developer", in: library)
        let derived = b.directory("DerivedData", in: developer)
        for p in ["DiskRings-abc", "WeatherApp-def", "Playground-123"] {
            let d = b.directory(p, in: derived)
            let build = b.directory("Build", in: d)
            files(build, prefix: "obj", ext: "o", count: 40, avg: 60 * MB)
            files(d, prefix: "index", ext: "idx", count: 10, avg: 80 * MB)
        }
        let sims = b.directory("CoreSimulator", in: developer)
        for i in 1 ... 4 {
            let s = b.directory("Device \(i)", in: sims)
            files(s, prefix: "data", ext: "img", count: 5, avg: 1_400 * MB)
        }
        let appSupport = b.directory("Application Support", in: library)
        for name in ["MobileSync", "Slack", "Code", "Steam", "JetBrains"] {
            let c = b.directory(name, in: appSupport)
            files(c, prefix: "file", ext: "dat", count: 12, avg: UInt64(rng.next() % 900 + 50) * MB)
        }
        files(library, prefix: "prefs", ext: "plist", count: 120, avg: 40_000)

        let movies = b.directory("Movies")
        files(movies, prefix: "Vacation", ext: "mov", count: 9, avg: 3 * GB)
        let fcp = b.directory("Final Cut Library.fcpbundle", in: movies, flags: .package)
        files(fcp, prefix: "render", ext: "mov", count: 14, avg: 900 * MB)

        let pictures = b.directory("Pictures")
        let photos = b.directory("Photos Library.photoslibrary", in: pictures, flags: .package)
        let originals = b.directory("originals", in: photos)
        for h in "0123456789ABCDEF" {
            let d = b.directory(String(h), in: originals)
            files(d, prefix: "IMG", ext: "heic", count: 60, avg: 3 * MB)
        }
        files(pictures, prefix: "Scan", ext: "png", count: 50, avg: 4 * MB)

        let documents = b.directory("Documents")
        files(documents, prefix: "Invoice", ext: "pdf", count: 80, avg: 400_000)
        let archive = b.directory("Archive", in: documents)
        files(archive, prefix: "Backup", ext: "zip", count: 6, avg: 2 * GB)
        files(documents, prefix: "Note", ext: "txt", count: 200, avg: 4_000)

        let downloads = b.directory("Downloads")
        files(downloads, prefix: "Installer", ext: "dmg", count: 7, avg: 1_200 * MB)
        files(downloads, prefix: "File", ext: "zip", count: 25, avg: 90 * MB)

        let music = b.directory("Music")
        let mlib = b.directory("Music", in: music)
        for artist in ["Bach", "Coltrane", "Daft Punk", "Nina Simone", "Radiohead"] {
            let a = b.directory(artist, in: mlib)
            files(a, prefix: "Track", ext: "m4a", count: 24, avg: 9 * MB)
        }

        let projects = b.directory("Projects")
        for p in ["diskrings", "webshop", "ml-experiments", "dotfiles"] {
            let d = b.directory(p, in: projects)
            let src = b.directory("Sources", in: d)
            files(src, prefix: "file", ext: "swift", count: 30, avg: 12_000)
            let nm = b.directory(p == "ml-experiments" ? "datasets" : "node_modules", in: d)
            files(nm, prefix: "pkg", ext: p == "ml-experiments" ? "csv" : "js", count: 40,
                  avg: p == "ml-experiments" ? 300 * MB : 2 * MB)
        }
        b.directory("Leer")
        b.directory("Public")
        b.file(".zsh_history", size: 2 * MB, flags: .hidden)
        b.file(".DS_Store", size: 12_000, flags: .hidden)

        return b.build(rootPath: rootPath)
    }

    /// Synthetischer, breit verzweigter Baum mit etwa `nodeCount` Knoten
    /// (für Performance-Messungen). Größen folgen grob einem Potenzgesetz.
    public static func large(nodeCount: Int, fanout: Int = 24, seed: UInt64 = 7) -> ScanTree {
        var b = ScanTreeBuilder(rootName: "gross", reserve: nodeCount)
        var rng = SplitMix64(seed: seed)
        var queue: [Int32] = [0]
        var head = 0
        while b.count < nodeCount, head < queue.count {
            let parent = queue[head]
            head += 1
            let kids = 1 + Int(rng.next() % UInt64(fanout * 2))
            for k in 0 ..< kids where b.count < nodeCount {
                if rng.next() % 4 == 0 {
                    queue.append(b.directory("d\(k)", in: parent))
                } else {
                    let u = rng.nextUnit()
                    b.file("f\(k)", size: UInt64(4096 + 50_000_000 * u * u * u * u), in: parent)
                }
            }
        }
        return b.build(rootPath: "/gross")
    }
}

/// Kleiner deterministischer Zufallsgenerator (SplitMix64).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
