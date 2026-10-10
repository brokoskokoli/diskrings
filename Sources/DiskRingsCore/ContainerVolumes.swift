import Darwin
import Foundation

/// Ein APFS-Volume in einem Container (z. B. Preboot, VM, Recovery, „Nix Store“).
/// Alle Volumes eines Containers teilen sich dessen Platz; was eines belegt,
/// zählt beim Volume „Macintosh HD“ als belegt, taucht aber in keinem Ordner auf.
public struct ContainerVolume: Sendable, Hashable, Codable {
    /// Name des Volumes, z. B. „Preboot“ oder „Nix Store“.
    public var name: String
    /// Gerät ohne `/dev/` und ohne Snapshot-Suffix, z. B. „disk3s2“.
    public var device: String
    /// Einhängepunkt, `nil` bei nicht eingehängten Volumes.
    public var mountPoint: String?
    /// APFS-Rollen laut `diskutil` („Preboot“, „VM“, „Data“ …), sonst leer.
    public var roles: [String]
    /// Belegter Platz des Volumes.
    public var used: UInt64

    public init(name: String, device: String, mountPoint: String?, roles: [String], used: UInt64) {
        self.name = name
        self.device = device
        self.mountPoint = mountPoint
        self.roles = roles
        self.used = used
    }

    /// Bekannte Rollen mit verständlichem Namen.
    public enum Role: String, Sendable {
        case system, data, preboot, recovery, vm, update, other
    }

    /// Rolle aus den APFS-Rollen, sonst aus Einhängepunkt bzw. Name.
    public var role: Role {
        let candidates = roles + [mountPoint.map { ($0 as NSString).lastPathComponent } ?? "", name]
        for c in candidates {
            switch c.lowercased() {
            case "system": if !roles.isEmpty { return .system }
            case "data": if !roles.isEmpty || mountPoint == "/System/Volumes/Data" { return .data }
            case "preboot": return .preboot
            case "recovery": return .recovery
            case "vm": return .vm
            case "update": return .update
            default: continue
            }
        }
        return .other
    }

    /// Anzeigename: bekannte Rollen verständlich, sonst der Volume-Name.
    public var displayName: String {
        switch role {
        case .system: L("volume.role.system", name)
        case .data: L("volume.role.data", name)
        case .preboot: L("volume.role.preboot")
        case .recovery: L("volume.role.recovery")
        case .vm: L("volume.role.vm")
        case .update: L("volume.role.update")
        case .other: name
        }
    }
}

/// Liefert die Volumes eines APFS-Containers aus einer weiteren Quelle
/// (z. B. `diskutil`), damit auch nicht eingehängte Volumes erscheinen.
public protocol APFSVolumeListing: Sendable {
    /// Volumes des Containers (z. B. „disk3“), `nil` bei einem Fehler.
    func volumes(inContainer container: String) -> [ContainerVolume]?
}

/// Volumes im selben APFS-Container wie ein gescanntes Volume (SPEC 4.1 Punkt 4).
///
/// Eingehängte Volumes werden über `getmntinfo` gefunden (Container aus
/// `f_mntfromname`, z. B. `/dev/disk3s1s1` → `disk3`) und ihr belegter Platz per
/// `getattrlist(ATTR_VOL_SPACEUSED)` gelesen; das geht ohne Administratorrechte.
/// Optional ergänzt eine `APFSVolumeListing` nicht eingehängte Volumes und Rollen.
public enum ContainerVolumes {
    /// Container eines Geräts: „/dev/disk3s1s1“ → „disk3“. `nil`, wenn das
    /// Gerät kein Volume eines Containers ist.
    public static func container(ofDevice device: String) -> String? {
        let parts = deviceParts(device)
        return parts.count >= 2 ? parts[0] : nil
    }

    /// Volume eines Geräts ohne Snapshot-Suffix: „/dev/disk3s1s1“ → „disk3s1“.
    public static func volumeDevice(_ device: String) -> String? {
        let parts = deviceParts(device)
        return parts.count >= 2 ? parts[0] + "s" + parts[1].dropFirst(4) : nil
    }

    /// „/dev/disk3s1s1“ → ["disk3", "disk1", "disk1"]: Basis plus je Ebene
    /// die Nummer (als „diskN“, um nur Ziffern zu prüfen). Leer, wenn kein
    /// gültiger Name.
    private static func deviceParts(_ device: String) -> [String] {
        var d = Substring(device)
        if d.hasPrefix("/dev/") { d = d.dropFirst(5) }
        guard d.hasPrefix("disk") else { return [] }
        let comps = d.dropFirst(4).split(separator: "s", omittingEmptySubsequences: false)
        guard !comps.isEmpty, comps.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigitChar) }) else { return [] }
        return comps.map { "disk" + $0 }
    }

    /// Alle eingehängten APFS-Volumes mit belegtem Platz (nur lesend).
    public static func mountedAPFS() -> [ContainerVolume] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        var out: [ContainerVolume] = []
        var seen: Set<String> = []
        for i in 0 ..< Int(n) {
            var fs = buf[i]
            let type = cString(&fs.f_fstypename)
            guard type == "apfs" else { continue }
            let from = cString(&fs.f_mntfromname)
            let mount = cString(&fs.f_mntonname)
            guard let dev = volumeDevice(from), !seen.contains(dev) else { continue }
            seen.insert(dev)
            let name = (try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeNameKey]))?.volumeName
                ?? (mount as NSString).lastPathComponent
            out.append(ContainerVolume(name: name, device: dev, mountPoint: mount, roles: [],
                                       used: spaceUsed(atMountPoint: mount) ?? 0))
        }
        return out
    }

    /// Belegter Platz eines eingehängten Volumes (`ATTR_VOL_SPACEUSED`).
    public static func spaceUsed(atMountPoint path: String) -> UInt64? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &attrs, raw.baseAddress, raw.count, 0)
        }
        guard rc == 0 else { return nil }
        // Aufbau: UInt32 Länge, danach off_t (Int64), nicht ausgerichtet.
        return buffer.withUnsafeBytes { raw in
            let length = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard length >= 12 else { return nil }
            let v = raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
            return UInt64(max(v, 0))
        }
    }

    /// Alle Volumes im Container des Volumes, das unter `path` eingehängt ist
    /// (einschließlich dieses Volumes). Leer, wenn es kein APFS-Volume ist.
    public static func read(forVolumeAt path: String, lister: (any APFSVolumeListing)?) -> [ContainerVolume] {
        let mounted = mountedAPFS()
        guard let own = mounted.first(where: { $0.mountPoint == path }),
              let container = container(ofDevice: own.device) else { return [] }
        let inContainer = mounted.filter { Self.container(ofDevice: $0.device) == container }
        return merge(mounted: inContainer, listed: lister?.volumes(inContainer: container))
    }

    /// Andere Volumes für den Scan von `scanRoot` auf dem Volume `volumePath`
    /// (lesen und filtern, siehe `others(in:…)`).
    public static func others(forVolumeAt volumePath: String, scanRoot: String, crossesMountPoints: Bool,
                              lister: (any APFSVolumeListing)?) -> [ContainerVolume] {
        others(in: read(forVolumeAt: volumePath, lister: lister), volumePath: volumePath, scanRoot: scanRoot,
               crossesMountPoints: crossesMountPoints)
    }

    /// Eingehängte Volumes mit Rollen aus der Liste ergänzen, nicht eingehängte anhängen.
    public static func merge(mounted: [ContainerVolume], listed: [ContainerVolume]?) -> [ContainerVolume] {
        guard let listed else { return mounted }
        let byDevice = Dictionary(listed.map { ($0.device, $0) }, uniquingKeysWith: { a, _ in a })
        var out = mounted.map { m -> ContainerVolume in
            var v = m
            if let l = byDevice[m.device] {
                v.roles = l.roles
                if v.used == 0 { v.used = l.used }
            }
            return v
        }
        let known = Set(mounted.map(\.device))
        out.append(contentsOf: listed.filter { !known.contains($0.device) })
        return out
    }

    /// Die Volumes, deren Platz der Scan nicht enthält: ohne das gescannte
    /// Volume selbst, beim Scan von „/“ ohne das über Firmlinks verbundene
    /// Data-Volume (SPEC 4.1 Punkt 5) und, wenn über Volume-Grenzen gescannt
    /// wurde, ohne Volumes, die unter der Scan-Wurzel eingehängt sind.
    public static func others(in all: [ContainerVolume], volumePath: String, scanRoot: String,
                              crossesMountPoints: Bool) -> [ContainerVolume] {
        let dataPath = "/System/Volumes/Data"
        let prefix = scanRoot.hasSuffix("/") ? scanRoot : scanRoot + "/"
        return all.filter { v in
            guard let m = v.mountPoint else { return true }
            if m == volumePath { return false }
            if volumePath == "/", m == dataPath { return false }
            if crossesMountPoints, m == scanRoot || m.hasPrefix(prefix) { return false }
            return true
        }
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

private extension Character {
    var isASCIIDigitChar: Bool { isASCII && isNumber }
}

/// Volumes eines Containers über `diskutil apfs list -plist` (auch nicht
/// eingehängte, z. B. Recovery). Nicht in der Sandbox (App-Store-Variante)
/// und nur mit Zeitlimit; bei jedem Fehler `nil`.
public struct DiskutilAPFSListing: APFSVolumeListing {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 4) {
        self.timeout = timeout
    }

    public func volumes(inContainer container: String) -> [ContainerVolume]? {
        guard !Self.isSandboxed(environment: ProcessInfo.processInfo.environment),
              let data = Self.run(executable: "/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist"],
                                  timeout: timeout) else { return nil }
        return Self.parse(data, container: container)
    }

    /// Läuft die App in der App-Sandbox?
    public static func isSandboxed(environment: [String: String]) -> Bool {
        environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Volumes des Containers aus der Plist-Ausgabe; `nil`, wenn sie sich nicht lesen lässt.
    public static func parse(_ data: Data, container: String) -> [ContainerVolume]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return nil }
        var out: [ContainerVolume] = []
        for c in containers where c["ContainerReference"] as? String == container {
            for v in c["Volumes"] as? [[String: Any]] ?? [] {
                guard let dev = v["DeviceIdentifier"] as? String else { continue }
                let used = (v["CapacityInUse"] as? NSNumber)?.uint64Value ?? 0
                out.append(ContainerVolume(name: v["Name"] as? String ?? dev, device: dev, mountPoint: nil,
                                           roles: v["Roles"] as? [String] ?? [], used: used))
            }
        }
        return out
    }

    /// Startet ein Programm und liefert seine Ausgabe, wenn es innerhalb des
    /// Zeitlimits mit Status 0 endet; sonst wird es beendet und `nil` geliefert.
    static func run(executable: String, arguments: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Wächter beendet den Prozess nach dem Zeitlimit; gelesen wird auf
        // diesem Thread (ein ausgelasteter Hintergrund-Thread verzögert so
        // höchstens den Abbruch, nie das Ergebnis).
        let watchdog = DispatchWorkItem { [p] in p.terminate() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        // Vom Wächter beendet: `.uncaughtSignal`.
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return data
    }
}
