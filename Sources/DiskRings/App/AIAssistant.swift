import AppKit
import DiskRingsCore
import Observation
import SystemConfiguration

/// Was „Mit KI analysieren“ ausführt.
enum AIAction: Equatable {
    /// Web-KI im Standardbrowser (Prompt im Link oder kopieren und öffnen).
    case web(AIWebService)
    /// Ausführlichen Prompt in die Zwischenablage.
    case copy
    /// Interaktive Sitzung mit einer lokalen CLI im Terminal (nur GitHub-Variante).
    case session(toolID: String, toolName: String, executable: String)

    /// Daten verlassen den Mac direkt (Prefill-Link, Sitzung): vorher einmal
    /// erklären, getrennt für Web und Sitzung; `nil` = kein Hinweis nötig.
    var consentKind: AIConsentState.Kind? {
        switch self {
        case .web(let s): s.handoff != .copyAndOpen ? .web : nil
        case .copy: nil
        case .session: .session
        }
    }

    /// Name des Empfängers für den Hinweis.
    var recipientName: String {
        switch self {
        case .web(let s): s.name
        case .copy: ""
        case .session(_, let name, _): name
        }
    }
}

/// Offener Datenschutz-Hinweis vor dem ersten Senden.
struct AIConsentRequest: Identifiable {
    let id = UUID()
    let action: AIAction
    let itemName: String
    let target: AITarget
}

/// Ziel einer KI-Aktion, über den Pfad festgehalten (der Baum kann sich bis
/// zur Bestätigung ändern).
struct AITarget: Equatable {
    let path: String
    let isDirectory: Bool
    let change: AIPromptFacts.Change?
}

/// Zustand von „Mit KI analysieren“: Datenschutz-Hinweis, gefundene CLIs.
@MainActor
@Observable
final class AIAssistant {
    /// Offener Datenschutz-Hinweis.
    var consent: AIConsentRequest?
    /// Öffnet das Einstellungsfenster (von `RootView` gesetzt).
    @ObservationIgnored var openSettings: (() -> Void)?

    /// Alle IDs, die die Menüauswahl kennt (Web-KIs, in der GitHub-Variante die CLIs).
    static var knownItemIDs: [String] {
        var ids = AIWebCatalog.all.map(\.id)
        #if AISessions
        ids += AICLICatalog.all.map(\.id)
        #endif
        return ids
    }

    #if AISessions
    /// Gefundene CLIs; `nil`, solange die Suche läuft (oder nie lief).
    private(set) var tools: [AICLIInstallation]?
    private(set) var isSearching = false
    @ObservationIgnored private var searchGate = GenerationGate()

    /// Sucht die CLIs im Hintergrund (nie in der Sandbox, nie auf dem Main Thread).
    func detectTools(environment: AppEnvironment) {
        guard !environment.isSandboxed else {
            tools = []
            return
        }
        let token = searchGate.begin()
        isSearching = true
        let home = environment.homeDirectory
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? AIAssistant.accountShell()
        Task {
            let found = await Task.detached(priority: .utility) {
                AICLILaunch.removeStale()
                return AICLIDetector.detect(environment: environment, home: home, shell: shell)
            }.value
            guard searchGate.isCurrent(token) else { return }
            tools = found
            isSearching = false
        }
    }

    /// Für die Bild-Renderer.
    func simulateTools(_ found: [AICLIInstallation]?) {
        tools = found
        isSearching = found == nil
    }

    nonisolated static func accountShell() -> String? {
        guard let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell else { return nil }
        return String(cString: s)
    }
    #endif
}

extension AppState {
    /// Anonymisierung mit den echten Namen dieses Macs.
    var promptAnonymizer: PromptAnonymizer {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return PromptAnonymizer(home: environment.homeDirectory, userName: NSUserName(),
                                fullName: NSFullUserName(), computerName: computer)
    }

    /// Ziel im aktuellen Baum bzw. Vergleich; `nil`, wenn es nicht genau eines ist.
    func aiTarget(for target: ContextMenuTarget) -> AITarget? {
        guard let tree else { return nil }
        if target.isCompare {
            guard let entries = currentCompareEntries(for: target), entries.count == 1,
                  let c = compareActionContext, let nodes = CompareActions.nodes(forEntries: entries, context: c),
                  nodes.count == 1 else { return nil }
            let d = c.diff
            let change = AIPromptFacts.Change(delta: d.delta(entries[0], c.sizeMode), since: d.old.metadata.date)
            return AITarget(path: tree.path(of: nodes[0]), isDirectory: tree.node(nodes[0]).isDirectory, change: change)
        }
        guard let nodes = currentNodes(for: target), nodes.count == 1 else { return nil }
        return AITarget(path: tree.path(of: nodes[0]), isDirectory: tree.node(nodes[0]).isDirectory, change: nil)
    }

    /// Verfügbarkeit des Untermenüs: genau ein Element, im Vergleich nur mit
    /// einem Element des aktuellen Scans.
    func aiAvailability(for target: ContextMenuTarget) -> ActionAvailability {
        if target.isCompare {
            guard target.compareEntries?.count == 1 else { return .disabled(L("reason.singleItemOnly")) }
            if compareActionContext?.comparesSnapshots ?? true { return .disabled(L("reason.twoSnapshots")) }
            guard target.nodes.count == 1 else { return .disabled(L("reason.notInCurrentScan")) }
            return .enabled
        }
        guard target.nodes.count == 1 else { return .disabled(L("reason.singleItemOnly")) }
        return availability(.info, targets: target.nodes)
    }

    /// Fakten für den Prompt (aktueller Baum, Dateisystem, `NSWorkspace`).
    func aiFacts(for t: AITarget) -> AIPromptFacts? {
        guard let tree, let node = tree.index(ofPath: t.path), tree.path(of: node) == t.path else { return nil }
        let a = promptAnonymizer
        return AIPromptFacts.make(node: node, in: tree, anonymizer: a,
                                  modified: AIPromptFacts.modificationDate(atPath: t.path),
                                  owner: ownerFact(for: t.path)?.anonymized(by: a), change: t.change,
                                  macOSVersion: AIPromptFacts.macOSVersionString())
    }

    /// Besitzer-App unter `~/Library` und ob sie installiert ist.
    func ownerFact(for path: String) -> OwnerAppFact? {
        let home = environment.homeDirectory
        guard let hint = OwnerAppHint.detect(path: path, home: home) else { return nil }
        switch hint.identifier {
        case .bundleID(let id):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
                return OwnerAppFact(hint: hint, install: .installed(name: name))
            }
            // Gruppen-IDs sind oft keine App-IDs: dann unbekannt statt „nicht installiert“.
            return OwnerAppFact(hint: hint, install: hint.location == .groupContainers ? .unknown : .notInstalled)
        case .name(let name):
            for dir in ["/Applications", home + "/Applications"] {
                let p = dir + "/" + name + ".app"
                if FileManager.default.fileExists(atPath: p) {
                    return OwnerAppFact(hint: hint, install: .installed(name: name))
                }
            }
            return OwnerAppFact(hint: hint, install: .unknown)
        }
    }

    /// Einstieg aus dem Menü: fragt bei Bedarf einmal nach, dann ausführen.
    func requestAI(_ action: AIAction, for target: ContextMenuTarget) {
        guard let t = aiTarget(for: target) else {
            NSSound.beep()
            return
        }
        if let kind = action.consentKind, prefs.aiConsent.needsConsent(kind) {
            ai.consent = AIConsentRequest(action: action, itemName: (t.path as NSString).lastPathComponent, target: t)
            return
        }
        performAI(action, target: t)
    }

    /// Antwort auf den Datenschutz-Hinweis.
    func answerAIConsent(_ request: AIConsentRequest, proceed: Bool, dontAskAgain: Bool) {
        ai.consent = nil
        guard proceed else { return }
        if dontAskAgain, let kind = request.action.consentKind { prefs.aiConsent.dontAskAgain(kind) }
        performAI(request.action, target: request.target)
    }

    func performAI(_ action: AIAction, target t: AITarget) {
        guard let facts = aiFacts(for: t) else {
            showToast(.error, L("reason.targetsChanged"))
            return
        }
        switch action {
        case .copy:
            FileActions.copyText(AIPromptBuilder.prompt(facts, style: .detailed))
            showToast(.success, L("ai.toast.copied"))
        case .web(let service):
            switch service.handoff {
            case .prefill:
                guard let url = AIWebLink.prefillURL(for: service, facts: facts), NSWorkspace.shared.open(url) else {
                    showToast(.error, L("ai.toast.openFailed", service.name))
                    return
                }
            case .copyAndOpen:
                FileActions.copyText(AIPromptBuilder.prompt(facts, style: .detailed))
                guard let url = URL(string: service.homeURL), NSWorkspace.shared.open(url) else {
                    showToast(.error, L("ai.toast.openFailed", service.name))
                    return
                }
                showToast(.success, L("ai.toast.copiedPaste", service.name))
            }
        case .session(let toolID, let toolName, let executable):
            startAISession(toolID: toolID, toolName: toolName, executable: executable, facts: facts, target: t)
        }
    }

    private func startAISession(toolID: String, toolName: String, executable: String, facts: AIPromptFacts,
                                target t: AITarget) {
        #if AISessions
        // Nie in der Sandbox: dort gibt es weder Suche noch Start.
        guard !environment.isSandboxed, let tool = AICLICatalog.tool(id: toolID),
              AICLIDetector.isUsableExecutable(executable),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            showToast(.error, L("ai.toast.sessionFailed", toolName))
            return
        }
        let prompt = AIPromptBuilder.prompt(facts, style: .session)
        let script: URL
        do {
            script = try AICLILaunch.prepare(
                tool: tool, executable: executable,
                workingDirectory: AICLILaunch.workingDirectory(forPath: t.path, isDirectory: t.isDirectory),
                prompt: prompt, banner: L("ai.session.banner", toolName))
        } catch {
            showToast(.error, L("ai.toast.sessionFailed", toolName))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: config) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.showToast(.error, L("ai.toast.sessionFailed", toolName))
                try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            }
        }
        #else
        showToast(.error, L("ai.toast.sessionFailed", toolName))
        #endif
    }
}
