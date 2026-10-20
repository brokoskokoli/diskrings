@testable import DiskRingsCore
import Testing

/// Wunsch des Maintainers: Die Titelzeile zeigt die Versionsnummer,
/// z. B. „DiskRings 0.4.0“ bzw. „Library – DiskRings 0.4.0“.
@Suite("Fenstertitel")
struct WindowTitleTests {
    @Test("Startbildschirm: App-Name mit Version")
    func start() {
        #expect(WindowTitle.make(location: nil, version: "0.4.0") == "DiskRings 0.4.0")
    }

    @Test("Ordner: Ordnername, dann App-Name mit Version")
    func folder() {
        #expect(WindowTitle.make(location: "Library", version: "0.4.0") == "Library – DiskRings 0.4.0")
    }

    @Test("Ohne Version (swift run ohne Info.plist): nur App-Name", arguments: [nil, "", "  "])
    func noVersion(version: String?) {
        #expect(WindowTitle.make(location: nil, version: version) == "DiskRings")
        #expect(WindowTitle.make(location: "Macintosh HD", version: version) == "Macintosh HD – DiskRings")
    }

    @Test("Leerer Ordnername fällt auf den App-Namen zurück")
    func emptyLocation() {
        #expect(WindowTitle.make(location: "", version: "1.0") == "DiskRings 1.0")
    }
}
