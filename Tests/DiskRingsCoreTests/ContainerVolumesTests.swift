@testable import DiskRingsCore
import Foundation
import Testing

@Suite("ContainerVolumes")
struct ContainerVolumesTests {
    typealias V = ContainerVolume

    @Test("Container und Volume aus dem Gerätenamen")
    func deviceParsing() {
        #expect(ContainerVolumes.container(ofDevice: "/dev/disk3s1s1") == "disk3")
        #expect(ContainerVolumes.container(ofDevice: "disk3s5") == "disk3")
        #expect(ContainerVolumes.container(ofDevice: "/dev/disk12s2") == "disk12")
        #expect(ContainerVolumes.container(ofDevice: "disk3") == nil)
        #expect(ContainerVolumes.container(ofDevice: "map auto_home") == nil)
        #expect(ContainerVolumes.container(ofDevice: "devfs") == nil)
        #expect(ContainerVolumes.volumeDevice("/dev/disk3s1s1") == "disk3s1")
        #expect(ContainerVolumes.volumeDevice("/dev/disk3s5") == "disk3s5")
        #expect(ContainerVolumes.volumeDevice("disk10s12s3") == "disk10s12")
        #expect(ContainerVolumes.volumeDevice("disks1") == nil)
    }

    static let container: [V] = [
        V(name: "Macintosh HD", device: "disk3s1", mountPoint: "/", roles: ["System"], used: 13),
        V(name: "Preboot", device: "disk3s2", mountPoint: "/System/Volumes/Preboot", roles: ["Preboot"], used: 11),
        V(name: "Recovery", device: "disk3s3", mountPoint: nil, roles: ["Recovery"], used: 2),
        V(name: "Data", device: "disk3s5", mountPoint: "/System/Volumes/Data", roles: ["Data"], used: 440),
        V(name: "VM", device: "disk3s6", mountPoint: "/System/Volumes/VM", roles: ["VM"], used: 9),
        V(name: "Nix Store", device: "disk3s7", mountPoint: "/nix", roles: [], used: 3),
    ]

    @Test("Scan von /: System und Data sind durch den Scan abgedeckt")
    func othersForRoot() {
        let o = ContainerVolumes.others(in: Self.container, volumePath: "/", scanRoot: "/", crossesMountPoints: false)
        #expect(o.map(\.name) == ["Preboot", "Recovery", "VM", "Nix Store"])
    }

    @Test("Scan des Data-Volumes: das System-Volume zählt als anderes Volume")
    func othersForData() {
        let o = ContainerVolumes.others(in: Self.container, volumePath: "/System/Volumes/Data",
                                        scanRoot: "/System/Volumes/Data", crossesMountPoints: false)
        #expect(o.map(\.name) == ["Macintosh HD", "Preboot", "Recovery", "VM", "Nix Store"])
    }

    @Test("Über Volume-Grenzen gescannt: eingehängte Volumes unter der Wurzel sind schon im Scan")
    func othersCrossing() {
        let o = ContainerVolumes.others(in: Self.container, volumePath: "/", scanRoot: "/", crossesMountPoints: true)
        #expect(o.map(\.name) == ["Recovery"])
    }

    @Test("Ohne Data-Rolle zählt der Einhängepunkt /System/Volumes/Data")
    func dataByMountPoint() {
        var c = Self.container
        c[3].roles = []
        let o = ContainerVolumes.others(in: c, volumePath: "/", scanRoot: "/", crossesMountPoints: false)
        #expect(!o.contains { $0.name == "Data" })
    }

    @Test("Eingehängte Werte haben Vorrang, Rollen und nicht eingehängte Volumes kommen aus der Liste")
    func merge() {
        let mounted = [V(name: "Preboot", device: "disk3s2", mountPoint: "/System/Volumes/Preboot", roles: [], used: 100)]
        let listed = [
            V(name: "Preboot", device: "disk3s2", mountPoint: nil, roles: ["Preboot"], used: 90),
            V(name: "Recovery", device: "disk3s3", mountPoint: nil, roles: ["Recovery"], used: 5),
        ]
        let m = ContainerVolumes.merge(mounted: mounted, listed: listed)
        #expect(m.count == 2)
        #expect(m[0].used == 100)
        #expect(m[0].roles == ["Preboot"])
        #expect(m[0].mountPoint == "/System/Volumes/Preboot")
        #expect(m[1].name == "Recovery")
        #expect(ContainerVolumes.merge(mounted: mounted, listed: nil) == mounted)
    }

    @Test("diskutil-Ausgabe: nur Volumes des gesuchten Containers")
    func parseDiskutil() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Containers</key><array>
          <dict><key>ContainerReference</key><string>disk1</string><key>Volumes</key><array>
            <dict><key>DeviceIdentifier</key><string>disk1s1</string><key>Name</key><string>iSCPreboot</string>
              <key>CapacityInUse</key><integer>6086656</integer><key>Roles</key><array><string>Preboot</string></array></dict>
          </array></dict>
          <dict><key>ContainerReference</key><string>disk3</string><key>Volumes</key><array>
            <dict><key>DeviceIdentifier</key><string>disk3s3</string><key>Name</key><string>Recovery</string>
              <key>CapacityInUse</key><integer>1536483328</integer><key>Roles</key><array><string>Recovery</string></array></dict>
            <dict><key>DeviceIdentifier</key><string>disk3s7</string><key>Name</key><string>Nix Store</string>
              <key>CapacityInUse</key><integer>3379699712</integer><key>Roles</key><array/></dict>
            <dict><key>Name</key><string>ohne Gerät</string></dict>
          </array></dict>
        </array></dict></plist>
        """
        let vols = try #require(DiskutilAPFSListing.parse(Data(plist.utf8), container: "disk3"))
        #expect(vols.map(\.device) == ["disk3s3", "disk3s7"])
        #expect(vols[0].used == 1_536_483_328)
        #expect(vols[0].roles == ["Recovery"])
        #expect(vols[1].roles.isEmpty)
        #expect(DiskutilAPFSListing.parse(Data("kaputt".utf8), container: "disk3") == nil)
        #expect(DiskutilAPFSListing.parse(Data(plist.utf8), container: "disk7")?.isEmpty == true)
    }

    @Test("Sandbox wird an der Umgebungsvariable erkannt")
    func sandbox() {
        #expect(DiskutilAPFSListing.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "x"]))
        #expect(!DiskutilAPFSListing.isSandboxed(environment: [:]))
    }

    @Test("Liste mit Zeitlimit: hängender Prozess wird abgebrochen")
    func timeout() {
        let start = Date()
        let out = DiskutilAPFSListing.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.3)
        #expect(out == nil)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(DiskutilAPFSListing.run(executable: "/bin/echo", arguments: ["hallo"], timeout: 3)
            .map { String(decoding: $0, as: UTF8.self) } == "hallo\n")
        #expect(DiskutilAPFSListing.run(executable: "/gibt/es/nicht", arguments: [], timeout: 1) == nil)
    }

    @Test("Echtes System (nur lesend): Startvolume, Container und andere Volumes plausibel")
    func realSystem() throws {
        let mounted = ContainerVolumes.mountedAPFS()
        let root = try #require(mounted.first { $0.mountPoint == "/" })
        let container = try #require(ContainerVolumes.container(ofDevice: root.device))
        let all = ContainerVolumes.read(forVolumeAt: "/", lister: nil)
        #expect(all.contains { $0.mountPoint == "/" })
        #expect(all.allSatisfy { ContainerVolumes.container(ofDevice: $0.device) == container })
        // Belegt des Volumes ≈ Summe aller Volumes des Containers (APFS teilt sich den Platz).
        let v = try #require(VolumeInfo.forPath("/"))
        let sum = all.reduce(UInt64(0)) { $0 + $1.used }
        #expect(sum <= v.usedCapacity + v.usedCapacity / 20)
        let others = ContainerVolumes.others(in: all, volumePath: "/", scanRoot: "/", crossesMountPoints: false)
        #expect(!others.contains { $0.mountPoint == "/" || $0.mountPoint == "/System/Volumes/Data" })
        // Nicht vorhandener Pfad: leer statt Absturz.
        #expect(ContainerVolumes.read(forVolumeAt: "/gibt/es/nicht", lister: nil).isEmpty)
        // Mit diskutil (falls vorhanden): mindestens so viele Volumes.
        let withList = ContainerVolumes.read(forVolumeAt: "/", lister: DiskutilAPFSListing())
        #expect(withList.count >= all.count)
    }
}
