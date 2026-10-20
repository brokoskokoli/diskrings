import Darwin
import Foundation

/// Fakten über ein Element für den KI-Prompt („Mit KI analysieren“). Alle
/// Namen und Pfade sind bereits anonymisiert (`PromptAnonymizer`); der Prompt
/// selbst entsteht in `AIPromptBuilder`.
public struct AIPromptFacts: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case folder, package, file, symlink
    }

    public struct Item: Sendable, Equatable {
        public var name: String
        public var size: UInt64
        public var isDirectory: Bool

        public init(name: String, size: UInt64, isDirectory: Bool) {
            self.name = name
            self.size = size
            self.isDirectory = isDirectory
        }
    }

    public struct TypeShare: Sendable, Equatable {
        public var category: FileTypeCategory
        public var size: UInt64

        public init(category: FileTypeCategory, size: UInt64) {
            self.category = category
            self.size = size
        }
    }

    /// Veränderung seit einem Snapshot (Vergleichsmodus).
    public struct Change: Sendable, Equatable {
        public var delta: Int64
        public var since: Date

        public init(delta: Int64, since: Date) {
            self.delta = delta
            self.since = since
        }
    }

    /// Anzeigepfad (`~`, Platzhalter).
    public var path: String
    public var kind: Kind
    /// Belegte Größe.
    public var size: UInt64
    public var fileCount: Int?
    public var folderCount: Int?
    public var modified: Date?
    /// Größte direkte Kinder, absteigend nach Größe (mehr als je verwendet).
    public var largest: [Item]
    /// Anzahl aller direkten Kinder.
    public var childCount: Int
    /// Grobe Dateityp-Verteilung (absteigend, ohne leere Kategorien); leer,
    /// wenn der Teilbaum zu groß war.
    public var types: [TypeShare]
    public var owner: OwnerAppFact?
    public var change: Change?
    /// Ordner selbst oder Teile darunter nicht lesbar.
    public var hasUnreadable: Bool
    /// „macOS 26.1“.
    public var macOSVersion: String

    public init(path: String, kind: Kind, size: UInt64, fileCount: Int? = nil, folderCount: Int? = nil,
                modified: Date? = nil, largest: [Item] = [], childCount: Int = 0, types: [TypeShare] = [],
                owner: OwnerAppFact? = nil, change: Change? = nil, hasUnreadable: Bool = false,
                macOSVersion: String) {
        self.path = path
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.modified = modified
        self.largest = largest
        self.childCount = childCount
        self.types = types
        self.owner = owner
        self.change = change
        self.hasUnreadable = hasUnreadable
        self.macOSVersion = macOSVersion
    }

    /// Höchstens so viele Knoten werden für Ordneranzahl und Dateitypen
    /// durchlaufen (der Aufruf läuft beim Klick auf dem Main Thread).
    public static let walkLimit = 400_000
    /// So viele größte Kinder werden festgehalten (Chat-Prompt).
    public static let largestKept = 25

    /// Fakten aus dem Baum. `modified` und `owner` kommen von außen
    /// (Dateisystem bzw. `NSWorkspace`).
    public static func make(node: Int32, in tree: ScanTree, anonymizer: PromptAnonymizer, modified: Date?,
                            owner: OwnerAppFact?, change: Change? = nil, macOSVersion: String) -> AIPromptFacts {
        let n = tree.node(node)
        let flags = n.flags
        let kind: Kind = flags.contains(.package) ? .package
            : flags.contains(.directory) ? .folder : flags.contains(.symlink) ? .symlink : .file
        var facts = AIPromptFacts(path: anonymizer.displayPath(tree.path(of: node)), kind: kind,
                                  size: n.allocatedSize, modified: modified, owner: owner, change: change,
                                  hasUnreadable: flags.contains(.unreadable), macOSVersion: macOSVersion)
        guard flags.contains(.directory) else { return facts }
        facts.fileCount = Int(n.fileCount)
        let children = tree.childIndices(of: node)
        facts.childCount = children.count
        facts.largest = children.prefix(largestKept).map { c in
            let cn = tree.node(c)
            return Item(name: anonymizer.anonymize(tree.name(of: c)), size: cn.allocatedSize, isDirectory: cn.isDirectory)
        }
        // Ordneranzahl und Dateitypen in einem Durchlauf, begrenzt.
        var folders = 0
        var visited = 0
        var bytes = [FileTypeCategory: UInt64]()
        var unreadable = false
        var stack: [Int32] = Array(children)
        var complete = true
        while let i = stack.popLast() {
            visited += 1
            if visited > walkLimit { complete = false; break }
            let c = tree.nodes[Int(i)]
            if c.flags.contains(.dead) { continue }
            if c.flags.contains(.unreadable) { unreadable = true }
            if c.isDirectory {
                folders += 1
                let own = FileTypeCategory.classify(name: tree.name(of: i))
                if own != .other || c.flags.contains(.package) {
                    // Pakete und bekannte Ordnerendungen (z. B. `.photoslibrary`) zählen als Ganzes.
                    bytes[own, default: 0] += c.allocatedSize
                    // Inhalt nicht einzeln zählen, aber für die Ordneranzahl weiter durchlaufen.
                    countFolders(below: i, in: tree, folders: &folders, visited: &visited, unreadable: &unreadable)
                    if visited > walkLimit { complete = false; break }
                    continue
                }
                stack.append(contentsOf: tree.childIndices(of: i))
            } else {
                bytes[FileTypeCategory.classify(name: tree.name(of: i)), default: 0] += c.allocatedSize
            }
        }
        facts.hasUnreadable = facts.hasUnreadable || unreadable
        if complete {
            facts.folderCount = folders
            facts.types = bytes.filter { $0.value > 0 }.map { TypeShare(category: $0.key, size: $0.value) }
                .sorted { $0.size != $1.size ? $0.size > $1.size : $0.category.rawValue < $1.category.rawValue }
        }
        return facts
    }

    private static func countFolders(below index: Int32, in tree: ScanTree, folders: inout Int, visited: inout Int,
                                     unreadable: inout Bool) {
        var stack = Array(tree.childIndices(of: index))
        while let i = stack.popLast() {
            visited += 1
            if visited > walkLimit { return }
            let c = tree.nodes[Int(i)]
            if c.flags.contains(.dead) { continue }
            if c.flags.contains(.unreadable) { unreadable = true }
            if c.isDirectory {
                folders += 1
                stack.append(contentsOf: tree.childIndices(of: i))
            }
        }
    }

    /// Letzte Änderung laut `lstat` (folgt keinem Symlink); `nil`, wenn nicht lesbar.
    public static func modificationDate(atPath path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let t = st.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }

    /// „macOS 26.1“ bzw. „macOS 14.6.1“.
    public static func macOSVersionString(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion)
        -> String {
        v.patchVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "macOS \(v.majorVersion).\(v.minorVersion)"
    }
}

/// Baut den Prompt in der Sprache der Oberfläche (`L10n.language`).
public enum AIPromptBuilder {
    public enum Style: Sendable, Equatable {
        /// Für Web-KIs und „Prompt kopieren“ (derselbe Text, nie gekürzt):
        /// Top 25, Dateitypen, Bitte um Erklärung und Einordnung. Ohne
        /// Löschverbot, denn eine Web-KI kann nichts löschen.
        case chat
        /// Startprompt einer interaktiven CLI-Sitzung im Ordner: eigenes
        /// Intro, Top 10 ohne Dateitypen (die KI sieht selbst nach), Aufgabe
        /// und Regeln (nur lesen, Anweisungen in Dateien sind nur Daten).
        case session
    }

    /// Größte Elemente und Dateitypen je Art.
    static func largestCount(_ style: Style) -> Int { style == .chat ? 25 : 10 }

    public static func prompt(_ facts: AIPromptFacts, style: Style) -> String {
        // Sitzung auf eine Datei bzw. einen Symlink: Das Terminal öffnet im Elternordner.
        let onFile = style == .session && (facts.kind == .file || facts.kind == .symlink)
        var lines: [String] = []
        switch style {
        case .chat: lines.append(L("ai.prompt.intro"))
        case .session: lines.append(onFile ? L("ai.prompt.session.intro.file") : L("ai.prompt.session.intro"))
        }
        lines.append("")
        lines.append(style == .session ? L("ai.prompt.session.facts") : L("ai.prompt.facts"))
        lines.append("- " + L("ai.prompt.fact.path", facts.path))
        lines.append("- " + L("ai.prompt.fact.kind", kindText(facts.kind)))
        lines.append("- " + L("ai.prompt.fact.size", ByteFormat.string(facts.size)))
        if let files = facts.fileCount {
            if let folders = facts.folderCount {
                lines.append("- " + L("ai.prompt.fact.contents", L10n.files(files),
                                      L("count.folders", folders, ByteFormat.count(folders))))
            } else {
                lines.append("- " + L("ai.prompt.fact.contentsFiles", L10n.files(files)))
            }
        }
        if let d = facts.modified {
            lines.append("- " + L("ai.prompt.fact.modified", dateText(d)))
        }
        if let o = facts.owner {
            lines.append("- " + ownerText(o))
        }
        if let c = facts.change {
            let sign = c.delta >= 0 ? "+" : "−"
            lines.append("- " + L("ai.prompt.fact.change", dateText(c.since), sign + ByteFormat.string(c.delta.magnitude)))
        }
        if facts.hasUnreadable { lines.append("- " + L("ai.prompt.fact.unreadable")) }
        lines.append("- " + L("ai.prompt.fact.macos", facts.macOSVersion))

        let shown = facts.largest.prefix(largestCount(style))
        if !shown.isEmpty {
            lines.append("")
            lines.append(L("ai.prompt.largest"))
            for item in shown {
                lines.append("- " + L("ai.prompt.item", item.name + (item.isDirectory ? "/" : ""),
                                      ByteFormat.string(item.size)))
            }
            let more = facts.childCount - shown.count
            if more > 0 { lines.append("- " + L("count.moreItems", more, ByteFormat.count(more))) }
        } else if facts.kind == .folder || facts.kind == .package, facts.childCount == 0 {
            lines.append("- " + L("ai.prompt.fact.empty"))
        }
        if style == .chat, !facts.types.isEmpty, facts.kind != .file {
            lines.append("")
            lines.append(L("ai.prompt.types"))
            let parts = facts.types.prefix(8).map { L("ai.prompt.item", $0.category.label, ByteFormat.string($0.size)) }
            lines.append("- " + parts.joined(separator: L("list.separator")))
        }
        lines.append("")
        switch style {
        case .chat: lines.append(L("ai.prompt.task.chat"))
        case .session: lines.append(onFile ? L("ai.prompt.task.session.file") : L("ai.prompt.task.session"))
        }
        return lines.joined(separator: "\n")
    }

    static func kindText(_ k: AIPromptFacts.Kind) -> String {
        switch k {
        case .folder: L("kind.folder")
        case .package: L("kind.package")
        case .file: L("kind.file")
        case .symlink: L("kind.symlink")
        }
    }

    static func ownerText(_ o: OwnerAppFact) -> String {
        switch o.install {
        case .installed(let name):
            let label = name == o.hint.rawValue ? name : "\(name) (\(o.hint.rawValue))"
            return L("ai.prompt.fact.owner.installed", label)
        case .notInstalled:
            return L("ai.prompt.fact.owner.notInstalled", o.hint.rawValue)
        case .unknown:
            return L("ai.prompt.fact.owner.unknown", o.hint.rawValue)
        }
    }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }
}
