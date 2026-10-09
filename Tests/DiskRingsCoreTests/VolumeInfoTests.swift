@testable import DiskRingsCore
import Foundation
import Testing

@Suite("VolumeInfo")
struct VolumeInfoTests {
    @Test("Liste enthält das Startvolume mit plausiblen Kennzahlen")
    func mountedVolumes() throws {
        let vols = VolumeInfo.mountedVolumes()
        let root = try #require(vols.first { $0.path == "/" })
        #expect(root.isRootFileSystem)
        #expect(root.totalCapacity > 0)
        #expect(root.availableCapacity <= root.totalCapacity)
        #expect(root.availableForImportantUsage >= root.availableCapacity)
        #expect(root.usedCapacity == root.totalCapacity - root.availableCapacity)
        #expect(!root.name.isEmpty)
        #expect(root.uuid?.count == 36)
        #expect(Set(vols.map(\.id)).count == vols.count)
    }

    @Test("Volume zu einem Pfad")
    func forPath() throws {
        let home = try #require(VolumeInfo.forPath("~"))
        #expect(home.totalCapacity > 0)
        let usr = try #require(VolumeInfo.forPath("/usr/share"))
        #expect(usr.path == "/")
        #expect(VolumeInfo.forPath("/gibt/es/wirklich/nicht") == nil)
    }

    @Test("Nicht zugeordnet = belegt − Scan-Summe, nie negativ")
    func unassigned() {
        #expect(VolumeInfo.unassigned(volumeUsed: 800, scanTotal: 700) == 100)
        #expect(VolumeInfo.unassigned(volumeUsed: 700, scanTotal: 800) == 0)
        #expect(VolumeInfo.unassigned(volumeUsed: 0, scanTotal: 0) == 0)
        let v = VolumeInfo(name: "Test", path: "/Volumes/Test", totalCapacity: 1000, availableCapacity: 300,
                           availableForImportantUsage: 450)
        #expect(v.usedCapacity == 700)
        #expect(v.purgeableCapacity == 150)
        #expect(v.unassigned(scanTotal: 650) == 50)
        // Scan-Summe + Nicht zugeordnet = belegt (Akzeptanzkriterium)
        #expect(650 + v.unassigned(scanTotal: 650) == v.usedCapacity)
    }

    @Test("Belegt ist nie negativ")
    func usedClamp() {
        let v = VolumeInfo(name: "X", path: "/x", totalCapacity: 100, availableCapacity: 200,
                           availableForImportantUsage: 100)
        #expect(v.usedCapacity == 0)
        #expect(v.purgeableCapacity == 0)
    }
}
