#if AISessions
import Darwin
import Foundation

// Interaktive KI-Sitzungen mit lokal installierten Agenten-CLIs (nur
// GitHub-Variante: Package Trait `AISessions`, zur Laufzeit zusätzlich nie in
// der Sandbox). Jede CLI startet ausschließlich in einem nur lesenden bzw.
// freigabepflichtigen Modus; Befehle, Flags, Quellen in dev/DECISIONS.md.

/// Eine Agenten-CLI aus dem Katalog.
public struct AICLITool: Sendable, Equatable, Identifiable {
    /// Wie der Startprompt übergeben wird.
    public enum PromptPassing: Sendable, Equatable {
        /// Als letztes Positionsargument.
        case positional
        /// Hinter einer Option, z. B. `-i <prompt>`.
        case option(String)
    }

    /// Stabile ID (Einstellungen), z. B. `cli.claude`.
    public let id: String
    public let name: String
    /// Namen des Programms in dieser Reihenfolge.
    public let executables: [String]
    /// Feste Argumente vor dem Prompt (nur lesend bzw. mit Freigabepflicht).
    public let arguments: [String]
    public let promptPassing: PromptPassing
    /// Gefundene Pfade, die diese Teile enthalten, sind keine echte
    /// Installation (z. B. die Installationshilfe von VS Code für `copilot`).
    public let excludedPathFragments: [String]
    /// Zusätzliche bekannte Orte relativ zum Home-Ordner.
    public let extraHomeDirectories: [String]

    public init(id: String, name: String, executables: [String], arguments: [String], promptPassing: PromptPassing,
                excludedPathFragments: [String] = [], extraHomeDirectories: [String] = []) {
        self.id = id
        self.name = name
        self.executables = executables
        self.arguments = arguments
        self.promptPassing = promptPassing
        self.excludedPathFragments = excludedPathFragments
        self.extraHomeDirectories = extraHomeDirectories
    }

    /// Argumente samt Prompt (für die Prüfung in Tests; das Skript setzt den
    /// Prompt erst zur Laufzeit aus der Datei ein).
    public func argv(prompt: String) -> [String] {
        switch promptPassing {
        case .positional: arguments + [prompt]
        case .option(let o): arguments + [o, prompt]
        }
    }
}

public enum AICLICatalog {
    /// Nur CLIs, die projektlokale Konfiguration (MCP-Server, Hooks,
    /// Berechtigungen) aus dem Zielordner erst nach einer Vertrauensabfrage
    /// laden oder sie per Flag abschalten (dev/DECISIONS.md: Gemini CLI,
    /// opencode und Cursor CLI wurden deshalb entfernt).
    public static let all: [AICLITool] = [
        // Vertrauensabfrage für unbekannte Ordner; zusätzlich nur Benutzer-
        // Einstellungen (keine Projekt-Hooks/-Freigaben) und keine MCP-Server.
        AICLITool(id: "cli.claude", name: "Claude Code", executables: ["claude"],
                  arguments: ["--permission-mode", "plan", "--setting-sources", "user", "--strict-mcp-config"],
                  promptPassing: .positional, extraHomeDirectories: [".claude/local"]),
        // Vertrauensabfrage; `.codex/` des Projekts gilt erst nach Zustimmung.
        AICLITool(id: "cli.codex", name: "Codex CLI", executables: ["codex"],
                  arguments: ["--sandbox", "read-only", "--ask-for-approval", "on-request"], promptPassing: .positional),
        // Vertrauensabfrage für den Ordner; Werkzeuge mit Änderungen fragen nach.
        AICLITool(id: "cli.copilot", name: "GitHub Copilot CLI", executables: ["copilot"],
                  arguments: ["--plan"], promptPassing: .option("-i"),
                  excludedPathFragments: ["/globalStorage/github.copilot-chat/"]),
    ]

    public static func tool(id: String) -> AICLITool? { all.first { $0.id == id } }

    /// Teile von Argumenten, die nie vorkommen dürfen (automatische Freigabe).
    public static let forbiddenArgumentFragments = [
        "yolo", "dangerous", "bypass", "skip-permissions", "allow-all", "auto", "force", "full-access", "never",
        "accept", "dontask",
    ]
}

/// Eine gefundene CLI.
public struct AICLIInstallation: Sendable, Equatable, Identifiable {
    public var tool: AICLITool
    /// Absoluter Pfad des Programms (Symlink möglich).
    public var path: String
    public var id: String { tool.id }

    public init(tool: AICLITool, path: String) {
        self.tool = tool
        self.path = path
    }
}

/// Sucht die CLIs: über die Login-Shell des Nutzers (eine GUI-App kennt
/// deren `PATH` nicht) mit hartem Zeitlimit und an bekannten Orten.
public enum AICLIDetector {
    public static let defaultTimeout: TimeInterval = 3

    /// Bekannte Orte (Homebrew, npm, bun, volta, nvm, …); nvm-Versionen absteigend.
    public static func knownDirectories(home: String, fileManager: FileManager = .default) -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let rel = [".local/bin", ".claude/local", ".npm-global/bin", ".npm/bin", ".bun/bin", ".volta/bin",
                   ".opencode/bin", ".cargo/bin", ".yarn/bin", "Library/pnpm", ".local/share/pnpm",
                   ".asdf/shims", ".local/share/mise/shims", ".deno/bin", "bin"]
        dirs += rel.map { home + "/" + $0 }
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvm) {
            let sorted = versions.filter { !$0.hasPrefix(".") }.sorted {
                $0.compare($1, options: [.numeric]) == .orderedDescending
            }
            dirs += sorted.map { nvm + "/" + $0 + "/bin" }
        }
        for t in AICLICatalog.all { dirs += t.extraHomeDirectories.map { home + "/" + $0 } }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// Nur ausführbare reguläre Dateien (direkt oder als Symlink darauf).
    public static func isUsableExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var l = stat()
        guard lstat(path, &l) == 0 else { return false }
        let lt = l.st_mode & S_IFMT
        guard lt == S_IFREG || lt == S_IFLNK else { return false }
        var s = stat()
        guard stat(path, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    static let marker = "__DISKRINGS_AI__"

    /// Shell-Skript für `command -v` aller Namen; nur sichere Namen.
    static func lookupScript(names: [String]) -> String? {
        let safe = names.filter { $0.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil }
        guard !safe.isEmpty else { return nil }
        return "for n in \(safe.joined(separator: " ")); do p=$(command -v \"$n\" 2>/dev/null) && "
            + "printf '\\n\(marker)%s=%s\\n' \"$n\" \"$p\"; done; exit 0"
    }

    /// Wertet die Ausgabe aus: nur markierte Zeilen mit absolutem Pfad
    /// (Aliasse, Funktionen und Ausgaben der Startdateien fallen heraus).
    public static func parseLookup(_ output: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(marker) else { continue }
            let rest = line.dropFirst(marker.count)
            guard let eq = rest.firstIndex(of: "=") else { continue }
            let name = String(rest[..<eq]), path = String(rest[rest.index(after: eq)...])
            if path.hasPrefix("/"), out[name] == nil { out[name] = path }
        }
        return out
    }

    /// Shell für die Suche: die Login-Shell des Nutzers, wenn sie POSIX-artig
    /// ist (sh, bash, zsh, ksh, dash); sonst `/bin/zsh`.
    public static func lookupShell(_ shell: String?) -> String {
        if let shell, shell.hasPrefix("/"),
           ["sh", "bash", "zsh", "ksh", "dash"].contains((shell as NSString).lastPathComponent),
           isUsableExecutable(shell) { return shell }
        return "/bin/zsh"
    }

    /// Fragt die Login-Shell (`-l -c`, nicht interaktiv, Eingabe `/dev/null`)
    /// mit hartem Zeitlimit. Nach dem Zeitlimit wird nicht weiter gewartet,
    /// auch wenn ein Kindprozess die Ausgabe noch offen hält.
    public static func loginShellLookup(shell: String, names: [String], timeout: TimeInterval) -> [String: String] {
        guard let script = lookupScript(names: names),
              let data = run(executable: shell, arguments: ["-l", "-c", script], timeout: timeout),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        return parseLookup(text)
    }

    /// Startet ein Programm in einer **eigenen Prozessgruppe** (Eingabe
    /// `/dev/null`, Fehlerausgabe verworfen), sammelt die Ausgabe und beendet
    /// danach die ganze Gruppe mit `SIGKILL`: Hintergrundprozesse aus den
    /// Startdateien der Shell (z. B. `sleep 15 &` in `.zprofile`) und Kinder,
    /// die `SIGTERM` ignorieren, bleiben so nicht zurück. `nil` bei Fehler,
    /// Zeitüberschreitung oder Abbruch durch ein Signal.
    static func run(executable: String, arguments: [String], timeout: TimeInterval) -> Data? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Eigene Gruppe (pgid = pid); alle übrigen Deskriptoren schließen.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            return nil
        }
        let reader = fds[0]
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var exited = false
        var exitTime: Date?
        var eof = false
        while true {
            if !exited, waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                exitTime = Date()
            }
            if exited && (eof || Date().timeIntervalSince(exitTime ?? Date()) > 0.3) { break }
            if Date() >= deadline { break }
            if !eof {
                var p = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                _ = poll(&p, 1, 20)
                while true {
                    let n = read(reader, &buffer, buffer.count)
                    if n > 0 {
                        data.append(buffer, count: n)
                    } else {
                        if n == 0 { eof = true }
                        break
                    }
                }
            } else {
                usleep(10_000)
            }
        }
        // Ganze Gruppe beenden (auch nach normalem Ende: verwaiste Kinder).
        killpg(pid, SIGKILL)
        if !exited {
            _ = waitpid(pid, &status, 0)
        }
        close(reader)
        // Nur normal beendet (kein Signal) und innerhalb des Zeitlimits.
        guard exited, status & 0x7f == 0 else { return nil }
        return data
    }

    /// Findet die installierten CLIs. In der Sandbox: keine Suche, kein
    /// Prozessstart (leeres Ergebnis).
    public static func detect(environment: AppEnvironment, home: String, shell: String?,
                              catalog: [AICLITool] = AICLICatalog.all, timeout: TimeInterval = defaultTimeout,
                              useLoginShell: Bool = true) -> [AICLIInstallation] {
        guard !environment.isSandboxed else { return [] }
        let names = catalog.flatMap(\.executables)
        let fromShell = useLoginShell
            ? loginShellLookup(shell: lookupShell(shell), names: names, timeout: timeout) : [:]
        let dirs = knownDirectories(home: home)
        return resolve(catalog: catalog, shellPaths: fromShell, directories: dirs)
    }

    /// Wählt je CLI den ersten brauchbaren Pfad: zuerst aus der Shell, dann
    /// aus den bekannten Orten.
    public static func resolve(catalog: [AICLITool], shellPaths: [String: String],
                               directories: [String]) -> [AICLIInstallation] {
        var out: [AICLIInstallation] = []
        for tool in catalog {
            var candidates: [String] = tool.executables.compactMap { shellPaths[$0] }
            for d in directories { candidates += tool.executables.map { d + "/" + $0 } }
            if let hit = candidates.first(where: { c in
                isUsableExecutable(c) && !tool.excludedPathFragments.contains { c.contains($0) }
            }) {
                out.append(AICLIInstallation(tool: tool, path: hit))
            }
        }
        return out
    }
}

/// Startskript für Terminal.app: wechselt in den Ordner, liest den Prompt
/// aus einer Datei (keine Shell-Auswertung des Prompts), löscht Prompt und
/// Skript und startet die CLI mit absolutem Pfad und festen Argumenten.
public enum AICLILaunch {
    /// Einfache Anführungszeichen für `/bin/sh`: alles wörtlich, `'` als `'\''`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Inhalt des Skripts (rein, testbar).
    public static func script(tool: AICLITool, executable: String, workingDirectory: String, promptFile: String,
                              scriptFile: String, banner: String) -> String {
        let q = shellQuote
        let exeDir = (executable as NSString).deletingLastPathComponent
        let scriptDir = (scriptFile as NSString).deletingLastPathComponent
        var call = [q(executable)] + tool.arguments.map(q)
        switch tool.promptPassing {
        case .positional: call.append("\"$prompt\"")
        case .option(let o): call += [q(o), "\"$prompt\""]
        }
        return """
        #!/bin/sh
        # DiskRings: interactive AI session (read-only / approval required). Deletes itself.
        prompt_file=\(q(promptFile))
        prompt=$(cat -- "$prompt_file") || exit 1
        rm -f -- "$prompt_file" \(q(scriptFile))
        rmdir -- \(q(scriptDir)) 2>/dev/null
        cd -- \(q(workingDirectory)) || exit 1
        PATH=\(q(exeDir)):"$PATH"
        export PATH
        printf '%s\\n\\n' \(q(banner))
        exec \(call.joined(separator: " "))

        """
    }

    /// Ablage der Startskripte (eigener Unterordner im temporären Ordner).
    public static func baseDirectory(temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appendingPathComponent("DiskRings-AI", isDirectory: true)
    }

    public enum LaunchError: Error, Equatable {
        case cannotWrite
    }

    /// Schreibt Prompt (0600) und Skript (0700, `.command`) in einen neuen
    /// Unterordner (0700) und liefert die URL des Skripts.
    public static func prepare(tool: AICLITool, executable: String, workingDirectory: String, prompt: String,
                               banner: String, base: URL = baseDirectory()) throws -> URL {
        let old = umask(0o077)
        defer { umask(old) }
        let fm = FileManager.default
        try? fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let promptURL = dir.appendingPathComponent("prompt.txt")
            let scriptURL = dir.appendingPathComponent("DiskRings AI Session.command")
            guard fm.createFile(atPath: promptURL.path, contents: Data(prompt.utf8),
                                attributes: [.posixPermissions: 0o600]) else { throw LaunchError.cannotWrite }
            let text = script(tool: tool, executable: executable, workingDirectory: workingDirectory,
                              promptFile: promptURL.path, scriptFile: scriptURL.path, banner: banner)
            guard fm.createFile(atPath: scriptURL.path, contents: Data(text.utf8),
                                attributes: [.posixPermissions: 0o700]) else { throw LaunchError.cannotWrite }
            return scriptURL
        } catch {
            try? fm.removeItem(at: dir)
            throw LaunchError.cannotWrite
        }
    }

    /// Entfernt Reste älterer Starts (z. B. nie geöffnete Skripte).
    public static func removeStale(base: URL = baseDirectory(), olderThan age: TimeInterval = 3600, now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for u in items {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(d) > age { try? fm.removeItem(at: u) }
        }
    }

    /// Arbeitsordner der Sitzung: der Ordner selbst bzw. bei Dateien und
    /// Symlinks der Elternordner.
    public static func workingDirectory(forPath path: String, isDirectory: Bool) -> String {
        isDirectory ? path : (path as NSString).deletingLastPathComponent
    }
}
#endif
