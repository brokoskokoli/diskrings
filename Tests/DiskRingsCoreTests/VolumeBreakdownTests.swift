@testable import DiskRingsCore
import Foundation
import Testing

@Suite("VolumeBreakdown", .language("de"))
struct VolumeBreakdownTests {
    static func vol(_ name: String, _ used: UInt64, device: String = "disk9s9", mount: String? = nil,
                    roles: [String] = []) -> ContainerVolume {
        ContainerVolume(name: name, device: device, mountPoint: mount, roles: roles, used: used)
    }

    @Test("Teile ergeben genau das bisherige „Nicht zugeordnet“")
    func basicSplit() {
        // Gesamt 1000, frei 200 → belegt 800; Scan 500 → nicht zugeordnet 300.
        let b = VolumeBreakdown(total: 1000, available: 200, availableForImportantUsage: 250, scanned: 500,
                                otherVolumes: [Self.vol("Preboot", 100, roles: ["Preboot"]), Self.vol("VM", 80)])
        #expect(b.used == 800)
        #expect(b.unassigned == 300)
        #expect(b.otherVolumes == 180)
        #expect(b.purgeable == 50)
        #expect(b.unreadable == 70)
        #expect(b.systemData == 250)
        #expect(b.free == 200)
        #expect(b.yourData == 500)
        #expect(b.yourData + b.systemData + b.purgeable + b.free == 1000)
        // Teile: absteigend nach Größe, ohne Nullgrößen.
        #expect(b.systemParts.map(\.size) == [100, 80, 70])
        #expect(b.systemParts.last?.kind == .unreadable)
    }

    @Test("Löschbar größer als der Rest wird geklemmt")
    func purgeableClamped() {
        let b = VolumeBreakdown(total: 1000, available: 200, availableForImportantUsage: 600, scanned: 700,
                                otherVolumes: [Self.vol("VM", 40)])
        #expect(b.unassigned == 100)
        #expect(b.otherVolumes == 40)
        #expect(b.purgeable == 60)
        #expect(b.unreadable == 0)
        #expect(!b.systemParts.contains { $0.kind == .unreadable })
    }

    @Test("Andere Volumes größer als der Rest werden geklemmt")
    func otherVolumesClamped() {
        let b = VolumeBreakdown(total: 1000, available: 200, availableForImportantUsage: 300, scanned: 750,
                                otherVolumes: [Self.vol("A", 30), Self.vol("B", 40)])
        // Nicht zugeordnet 50: B (größer) zuerst ganz, A nur noch 10.
        #expect(b.unassigned == 50)
        #expect(b.otherVolumes == 50)
        #expect(b.systemParts.map(\.size) == [40, 10])
        #expect(b.purgeable == 0)
        #expect(b.unreadable == 0)
    }

    @Test("Scan-Summe über belegt: alles 0, nur frei bleibt")
    func scanAboveUsed() {
        let b = VolumeBreakdown(total: 1000, available: 200, availableForImportantUsage: 300, scanned: 900,
                                otherVolumes: [Self.vol("VM", 40)])
        #expect(b.unassigned == 0)
        #expect(b.systemData == 0)
        #expect(b.purgeable == 0)
        #expect(b.systemParts.isEmpty)
        #expect(b.free == 200)
        #expect(b.yourData == 800)
    }

    @Test("Ohne andere Volumes ist alles Übrige nicht lesbar oder löschbar")
    func noOtherVolumes() {
        let b = VolumeBreakdown(total: 1000, available: 100, availableForImportantUsage: 130, scanned: 600,
                                otherVolumes: [])
        #expect(b.otherVolumes == 0)
        #expect(b.purgeable == 30)
        #expect(b.unreadable == 270)
        #expect(b.systemParts.map(\.kind) == [.unreadable])
    }

    @Test("Wichtige Kapazität unter frei (negative Differenz) ergibt 0 löschbar")
    func negativePurgeable() {
        let b = VolumeBreakdown(total: 1000, available: 300, availableForImportantUsage: 200, scanned: 500,
                                otherVolumes: [])
        #expect(b.purgeable == 0)
        #expect(b.unreadable == 200)
    }

    @Test("Frei über Gesamt: belegt 0, keine Systemdaten")
    func availableAboveTotal() {
        let b = VolumeBreakdown(total: 100, available: 200, availableForImportantUsage: 200, scanned: 10,
                                otherVolumes: [Self.vol("VM", 5)])
        #expect(b.used == 0)
        #expect(b.unassigned == 0)
        #expect(b.systemParts.isEmpty)
        #expect(b.free == 200)
    }

    @Test("Volumes mit 0 Byte erscheinen nicht")
    func zeroVolumesDropped() {
        let b = VolumeBreakdown(total: 1000, available: 0, availableForImportantUsage: 0, scanned: 900,
                                otherVolumes: [Self.vol("Leer", 0), Self.vol("VM", 20)])
        #expect(b.systemParts.map(\.title) == ["Nicht lesbare Systemdaten", "Auslagerung & Ruhezustand (VM)"])
        #expect(b.systemParts.map(\.size) == [80, 20])
    }

    @Test("Invariante über viele Kombinationen, auch mit Überlauf-Kandidaten")
    func invariantProperty() {
        var rng = SplitMix(seed: 42)
        let big = UInt64.max / 4
        for _ in 0 ..< 5000 {
            let pick: (UInt64) -> UInt64 = { m in m == 0 ? 0 : rng.next() % (m + 1) }
            let scale: UInt64 = [1000, 1_000_000_000_000, big].randomElement(using: &rng)!
            let total = pick(scale)
            let available = pick(scale)
            let important = pick(scale)
            let scanned = pick(scale)
            let others = (0 ..< Int(rng.next() % 4)).map { i in Self.vol("V\(i)", pick(scale / 2)) }
            let b = VolumeBreakdown(total: total, available: available, availableForImportantUsage: important,
                                    scanned: scanned, otherVolumes: others)
            let old = VolumeInfo.unassigned(volumeUsed: total > available ? total - available : 0, scanTotal: scanned)
            #expect(b.unassigned == old)
            #expect(b.otherVolumes + b.purgeable + b.unreadable == old)
            #expect(b.systemParts.reduce(0) { $0 + $1.size } == b.systemData)
            #expect(b.systemParts.allSatisfy { $0.size > 0 })
            #expect(b.yourData + b.unassigned == b.used)
            #expect(b.free == available)
        }
    }

    @Test("Schätzung ohne Scan: eigene Daten = belegt − andere Volumes − löschbar")
    func estimate() {
        let v = VolumeInfo(name: "HD", path: "/", totalCapacity: 1000, availableCapacity: 200,
                           availableForImportantUsage: 260)
        let b = VolumeBreakdown.estimate(volume: v, otherVolumes: [Self.vol("VM", 90)])
        #expect(b.otherVolumes == 90)
        #expect(b.purgeable == 60)
        #expect(b.unreadable == 0)
        #expect(b.yourData == 650)
        #expect(b.yourData + b.systemData + b.purgeable + b.free == 1000)
    }

    @Test("Segmente für das Diagramm, frei abschaltbar")
    func rootSegments() {
        let b = VolumeBreakdown(total: 1000, available: 200, availableForImportantUsage: 250, scanned: 500,
                                otherVolumes: [Self.vol("VM", 80)])
        let s = b.rootSegments(showFree: true)
        #expect(s.system == 250)
        #expect(s.purgeable == 50)
        #expect(s.free == 200)
        #expect(s.total == 500)
        #expect(b.rootSegments(showFree: false).free == 0)
        #expect(RootSegments.none.isEmpty)
        #expect(!s.isEmpty)
    }

    @Test("Mitte der Volume-Wurzel: belegt von gesamt")
    func centerText() {
        let b = VolumeBreakdown(total: 494_000_000_000, available: 182_000_000_000,
                                availableForImportantUsage: 196_000_000_000, scanned: 248_800_000_000, otherVolumes: [])
        #expect(b.centerText == "312,0\u{00A0}GB belegt\nvon 494,0\u{00A0}GB")
    }

    @Test("Bekannte Rollen bekommen verständliche Namen, andere ihren Volume-Namen")
    func friendlyNames() {
        #expect(Self.vol("Preboot", 1, roles: ["Preboot"]).displayName == "Startdaten (Preboot)")
        #expect(Self.vol("VM", 1, roles: ["VM"]).displayName == "Auslagerung & Ruhezustand (VM)")
        #expect(Self.vol("Recovery", 1).displayName == "Wiederherstellung (Recovery)")
        #expect(Self.vol("Update", 1, mount: "/System/Volumes/Update").displayName == "Systemupdates (Update)")
        #expect(Self.vol("Macintosh HD", 1, roles: ["System"]).displayName == "macOS-System (Macintosh HD)")
        #expect(Self.vol("Nix Store", 1).displayName == "Nix Store")
        #expect(Self.vol("Nix Store", 1).role == .other)
        // Rolle aus dem Einhängepunkt, wenn kein Rollen-Eintrag vorliegt.
        #expect(Self.vol("Foo", 1, mount: "/System/Volumes/VM").role == .vm)
    }

    @Test("Hinweis zu nicht lesbaren Systemdaten: Festplattenvollzugriff, in der Sandbox Ordnerfreigaben")
    func accessHints() {
        let unreadable = VolumeBreakdown.SystemPart(kind: .unreadable, size: 5)
        let base = unreadable.detail(accessHint: .none)
        #expect(unreadable.detail(fullDiskAccessDenied: false) == base)
        #expect(unreadable.detail(fullDiskAccessDenied: true) == unreadable.detail(accessHint: .fullDiskAccess))
        #expect(unreadable.detail(accessHint: .fullDiskAccess).hasSuffix(L("arc.unreadableSystem.fdaHint")))
        let sandbox = unreadable.detail(accessHint: .sandbox)
        #expect(sandbox.hasPrefix(base))
        #expect(sandbox.hasSuffix(L("arc.unreadableSystem.sandboxHint")))
        #expect(!sandbox.contains(L("arc.unreadableSystem.fdaHint")))
        let volume = VolumeBreakdown.SystemPart(kind: .volume(ContainerVolume(name: "VM", device: "disk3s6", mountPoint: nil,
                                                                             roles: ["VM"], used: 1)), size: 1)
        #expect(volume.detail(accessHint: .sandbox) == volume.detail(accessHint: .none))
    }
}

extension RootSegments {
    /// Nur Systemdaten aus einem nicht lesbaren Teil (früher „Nicht zugeordnet“).
    static func unreadable(_ n: UInt64) -> RootSegments {
        RootSegments(systemParts: [VolumeBreakdown.SystemPart(kind: .unreadable, size: n)])
    }

    /// Alle Segmente: Systemdaten 300 (Volume „V“) + 200 (nicht lesbar), löschbar 100, frei 400.
    static let full = RootSegments(
        systemParts: [VolumeBreakdown.SystemPart(kind: .volume(ContainerVolume(name: "V", device: "disk9s1",
                                                                               mountPoint: nil, roles: [], used: 300)),
                                                 size: 300),
                      VolumeBreakdown.SystemPart(kind: .unreadable, size: 200)],
        purgeable: 100, free: 400)
}

/// Deterministischer Zufallsgenerator für Eigenschaftstests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
