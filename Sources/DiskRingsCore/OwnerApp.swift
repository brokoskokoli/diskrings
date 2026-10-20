import Foundation

/// Vermutliche Besitzer-App eines Pfads unter `~/Library` (für den KI-Prompt):
/// Container, Gruppen-Container, Application Support, Caches, Einstellungen,
/// gesicherter Fensterzustand, HTTP-Speicher, Protokolle. Erkannt wird nur
/// am Namen des Ordners bzw. der Datei direkt unter dem jeweiligen Ort; ob
/// die App installiert ist, prüft die App (`NSWorkspace`).
public struct OwnerAppHint: Sendable, Equatable {
    public enum Identifier: Sendable, Equatable {
        /// Bundle-ID (umgekehrte Domain), z. B. `com.tinyspeck.slackmacgap`.
        case bundleID(String)
        /// Name eines Ordners, z. B. `Google` oder `Code`.
        case name(String)
    }

    public enum Location: String, Sendable, CaseIterable {
        case containers, groupContainers, applicationSupport, caches, preferences, savedState, httpStorages, logs
    }

    public var identifier: Identifier
    public var location: Location

    public init(identifier: Identifier, location: Location) {
        self.identifier = identifier
        self.location = location
    }

    /// Text für Bundle-ID bzw. Namen.
    public var rawValue: String {
        switch identifier {
        case .bundleID(let s), .name(let s): s
        }
    }

    /// Ordner unter `~/Library` je Ort.
    static let folders: [(String, Location)] = [
        ("Containers", .containers), ("Group Containers", .groupContainers),
        ("Application Support", .applicationSupport), ("Caches", .caches), ("Preferences", .preferences),
        ("Saved Application State", .savedState), ("HTTPStorages", .httpStorages), ("Logs", .logs),
    ]

    /// Erkennt die Besitzer-App für `path` (absolut) relativ zum Home-Ordner
    /// `home`; `nil`, wenn der Pfad nicht unter einem der Orte liegt oder der
    /// Name nichts hergibt (UUID, Systemordner).
    public static func detect(path: String, home: String) -> OwnerAppHint? {
        var h = home
        while h.count > 1, h.hasSuffix("/") { h.removeLast() }
        let lib = h + "/Library/"
        guard h.count > 1, path.hasPrefix(lib) else { return nil }
        let rel = path.dropFirst(lib.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard rel.count >= 2, let loc = folders.first(where: { $0.0 == rel[0] })?.1 else { return nil }
        let raw = rel[1]
        var name = raw
        switch loc {
        case .preferences:
            guard name.hasSuffix(".plist"), name != "ByHost" else { return nil }
            name = String(name.dropLast(6))
        case .savedState:
            guard name.hasSuffix(".savedState") else { return nil }
            name = String(name.dropLast(11))
        case .httpStorages:
            if name.hasSuffix(".binarycookies") { name = String(name.dropLast(14)) }
        case .groupContainers:
            name = groupBase(name)
        default:
            break
        }
        guard !name.isEmpty, !name.hasPrefix("."), !isUUID(name) else { return nil }
        if isBundleID(name) { return OwnerAppHint(identifier: .bundleID(name), location: loc) }
        // Container heißen immer nach einer Bundle-ID; ein anderer Name ist kein Hinweis.
        // Gruppen-Container wie `UBF8T346G9.Office` behalten ihren ganzen Namen.
        if loc == .groupContainers { return name == raw ? nil : OwnerAppHint(identifier: .name(raw), location: loc) }
        if loc == .containers || loc == .savedState { return nil }
        return OwnerAppHint(identifier: .name(name), location: loc)
    }

    /// `group.com.foo.shared` → `com.foo.shared`; `ABCDE12345.com.foo` → `com.foo`.
    static func groupBase(_ name: String) -> String {
        if name.hasPrefix("group.") { return String(name.dropFirst(6)) }
        let parts = name.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10,
           parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
            return String(parts[1])
        }
        return name
    }

    /// Umgekehrte Domain: mindestens drei Teile aus Buchstaben, Ziffern, `-`, `_`.
    static func isBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        } && parts[0].first?.isLetter == true
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }
}

/// Ergebnis der Prüfung, ob die Besitzer-App installiert ist.
public enum OwnerAppInstallState: Sendable, Equatable {
    case installed(name: String)
    case notInstalled
    case unknown
}

/// Besitzer-App als Fakt im Prompt.
public struct OwnerAppFact: Sendable, Equatable {
    public var hint: OwnerAppHint
    public var install: OwnerAppInstallState

    public init(hint: OwnerAppHint, install: OwnerAppInstallState) {
        self.hint = hint
        self.install = install
    }
}

extension OwnerAppFact {
    /// Bundle-ID, Ordner- und App-Name ohne Benutzer-, Personen- und Rechnernamen.
    public func anonymized(by a: PromptAnonymizer) -> OwnerAppFact {
        let id: OwnerAppHint.Identifier
        switch hint.identifier {
        case .bundleID(let s): id = .bundleID(a.anonymize(s))
        case .name(let s): id = .name(a.anonymize(s))
        }
        let install: OwnerAppInstallState
        switch self.install {
        case .installed(let name): install = .installed(name: a.anonymize(name))
        case .notInstalled, .unknown: install = self.install
        }
        return OwnerAppFact(hint: OwnerAppHint(identifier: id, location: hint.location), install: install)
    }
}
