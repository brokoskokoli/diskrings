#if AISessions
@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

// Interaktive KI-Sitzungen (nur GitHub-Variante, Trait `AISessions`):
// Katalog nur lesend, Erkennung, Startskript mit fiesen Namen.

@Suite("KI-CLIs: Katalog")
struct AICLICatalogTests {
    @Test("Eindeutige IDs, absolute Namen ohne Pfad, keine automatische Freigabe")
    func catalog() {
        let ids = AICLICatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for t in AICLICatalog.all {
            #expect(t.id.hasPrefix("cli."))
            #expect(!t.arguments.isEmpty, "\(t.id): ohne nur lesenden Modus")
            for name in t.executables { #expect(!name.contains("/") && name.wholeMatch(of: /[a-z0-9-]+/) != nil) }
            for arg in t.argv(prompt: "") where !arg.isEmpty {
                let lower = arg.lowercased()
                for bad in AICLICatalog.forbiddenArgumentFragments {
                    #expect(!lower.contains(bad), "\(t.id): \(arg) enthält \(bad)")
                }
            }
        }
    }

    @Test("Feste, recherchierte Argumente je CLI")
    func flags() throws {
        #expect(try #require(AICLICatalog.tool(id: "cli.claude")).argv(prompt: "P")
            == ["--permission-mode", "plan", "--setting-sources", "user", "--strict-mcp-config", "P"])
        #expect(try #require(AICLICatalog.tool(id: "cli.codex")).argv(prompt: "P")
            == ["--sandbox", "read-only", "--ask-for-approval", "on-request", "P"])
        #expect(try #require(AICLICatalog.tool(id: "cli.copilot")).argv(prompt: "P") == ["--plan", "-i", "P"])
    }

    @Test("Nur CLIs mit Vertrauensabfrage bzw. abgeschalteter Projektkonfiguration (Verifier-Fund 1)")
    func onlyHardened() throws {
        // Gemini CLI (Folder Trust standardmäßig aus), opencode (keine Abfrage, Projektkonfiguration
        // nicht abschaltbar) und Cursor CLI (Vertrauensverhalten nicht offiziell dokumentiert) fehlen.
        #expect(AICLICatalog.all.map(\.id) == ["cli.claude", "cli.codex", "cli.copilot"])
        for removed in ["cli.gemini", "cli.opencode", "cli.cursor"] { #expect(AICLICatalog.tool(id: removed) == nil) }
        // Claude Code: keine Projekt-Einstellungen (Hooks, Freigaben) und keine MCP-Server aus dem Ordner.
        let claude = try #require(AICLICatalog.tool(id: "cli.claude")).arguments
        let i = try #require(claude.firstIndex(of: "--setting-sources"))
        #expect(claude[i + 1] == "user")
        #expect(claude.contains("--strict-mcp-config"))
        #expect(!claude.contains("--mcp-config"))
    }

    @Test("Bekannte Orte in App-Bundles: relativ, ohne „..“, Codex aus ChatGPT- und Codex-App")
    func appBundles() throws {
        for t in AICLICatalog.all {
            for rel in t.appBundleExecutables {
                #expect(!rel.hasPrefix("/") && !rel.contains("..") && rel.contains(".app/Contents/"), "\(t.id): \(rel)")
            }
        }
        #expect(try #require(AICLICatalog.tool(id: "cli.codex")).appBundleExecutables == [
            "ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "Codex.app/Contents/Resources/codex-cli/bin/codex",
            "Codex.app/Contents/Resources/codex",
        ])
    }

    @Test("Web- und CLI-IDs kollidieren nicht")
    func noCollision() {
        #expect(Set(AICLICatalog.all.map(\.id)).isDisjoint(with: AIWebCatalog.all.map(\.id)))
    }
}

@Suite("KI-CLIs: Erkennung")
struct AICLIDetectorTests {
    @Test("Nur ausführbare reguläre Dateien oder Symlinks darauf")
    func executables() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let exe = try fx.file("bin/claude", size: 10)
        chmod(exe, 0o755)
        let plain = try fx.file("bin/codex", size: 10)
        chmod(plain, 0o644)
        try fx.dir("bin/gemini")
        chmod(fx.path("bin/gemini"), 0o755)
        try fx.symlink("bin/opencode", to: exe)
        try fx.symlink("bin/copilot", to: fx.path("bin/missing"))
        try fx.symlink("bin/cursor-agent", to: fx.path("bin/gemini"))
        #expect(AICLIDetector.isUsableExecutable(exe))
        #expect(!AICLIDetector.isUsableExecutable(plain))
        #expect(!AICLIDetector.isUsableExecutable(fx.path("bin/gemini")))
        #expect(AICLIDetector.isUsableExecutable(fx.path("bin/opencode")))
        #expect(!AICLIDetector.isUsableExecutable(fx.path("bin/copilot")))
        #expect(!AICLIDetector.isUsableExecutable(fx.path("bin/cursor-agent")))
        #expect(!AICLIDetector.isUsableExecutable("bin/claude"))
        #expect(!AICLIDetector.isUsableExecutable(fx.path("nothing")))

        let found = AICLIDetector.resolve(catalog: AICLICatalog.all, shellPaths: [:], directories: [fx.path("bin")])
        #expect(found.map(\.id) == ["cli.claude"])
    }

    @Test("Shell-Pfad hat Vorrang, ausgeschlossene Orte (VS-Code-Hilfe für copilot) zählen nicht")
    func precedenceAndExclusion() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let a = try fx.file("shell/claude", size: 1)
        let b = try fx.file("known/claude", size: 1)
        let shim = try fx.file("Code/User/globalStorage/github.copilot-chat/copilotCli/copilot", size: 1)
        let real = try fx.file("known/copilot", size: 1)
        for p in [a, b, shim, real] { chmod(p, 0o755) }
        let found = AICLIDetector.resolve(catalog: AICLICatalog.all, shellPaths: ["claude": a, "copilot": shim],
                                          directories: [fx.path("known")])
        #expect(found.first { $0.id == "cli.claude" }?.path == a)
        #expect(found.first { $0.id == "cli.copilot" }?.path == real)
        let onlyShim = AICLIDetector.resolve(catalog: AICLICatalog.all, shellPaths: ["copilot": shim], directories: [])
        #expect(onlyShim.isEmpty)
    }

    /// Fake-Bundle wie in ChatGPT.app: `/bin/sh`-Wrapper in `codex-cli/bin`,
    /// der `../CodexCLI.app/Contents/MacOS/codex` startet.
    static func fakeCodexBundle(_ fx: Fixture, appsDir: String, app: String = "ChatGPT.app",
                                mode: mode_t = 0o755) throws -> String {
        let res = "\(appsDir)/\(app)/Contents/Resources/codex-cli"
        let real = try fx.file("\(res)/CodexCLI.app/Contents/MacOS/codex", size: 1)
        chmod(real, 0o755)
        let wrapper = fx.path("\(res)/bin/codex")
        try fx.dir("\(res)/bin")
        try "#!/bin/sh\nbin_dir=$(CDPATH= cd -P -- \"$(dirname -- \"$0\")\" && pwd)\nexec \"$bin_dir/../CodexCLI.app/Contents/MacOS/codex\" \"$@\"\n"
            .write(toFile: wrapper, atomically: true, encoding: .utf8)
        chmod(wrapper, mode)
        return wrapper
    }

    @Test("Codex aus der ChatGPT-App (Bundle), auch unter ~/Applications und aus einer Codex-App")
    func codexInAppBundle() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let wrapper = try Self.fakeCodexBundle(fx, appsDir: "Applications")
        let apps = [fx.path("System Applications"), fx.path("Applications")]
        let found = AICLIDetector.resolve(catalog: AICLICatalog.all, shellPaths: [:], directories: [fx.path("bin")],
                                          applicationDirectories: apps)
        #expect(found.map(\.id) == ["cli.codex"])
        #expect(found.first?.path == wrapper)

        // Eigenständige Codex-App, beide bekannten Orte im Bundle.
        let fx2 = try Fixture()
        defer { fx2.remove() }
        let standalone = try Self.fakeCodexBundle(fx2, appsDir: "Apps", app: "Codex.app")
        #expect(AICLIDetector.resolve(catalog: AICLICatalog.all, shellPaths: [:], directories: [],
                                      applicationDirectories: [fx2.path("Apps")]).first?.path == standalone)
        let flat = try fx2.file("Apps2/Codex.app/Contents/Resources/codex", size: 1)
        chmod(flat, 0o755)
        #expect(AICLIDetector.resolve(catalog: AICLICatalog.all, shellPaths: [:], directories: [],
                                      applicationDirectories: [fx2.path("Apps2")]).first?.path == flat)
    }

    @Test("Reihenfolge: Shell-PATH vor bekannten Orten vor App-Bundles; nicht ausführbar im Bundle zählt nicht")
    func appBundlePrecedence() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let bundled = try Self.fakeCodexBundle(fx, appsDir: "Applications")
        let shell = try fx.file("shell/codex", size: 1)
        let known = try fx.file("known/codex", size: 1)
        for p in [shell, known] { chmod(p, 0o755) }
        let apps = [fx.path("Applications")]
        func pick(_ shellPaths: [String: String], _ dirs: [String]) -> String? {
            AICLIDetector.resolve(catalog: AICLICatalog.all, shellPaths: shellPaths, directories: dirs,
                                  applicationDirectories: apps).first { $0.id == "cli.codex" }?.path
        }
        #expect(pick(["codex": shell], [fx.path("known")]) == shell)
        #expect(pick([:], [fx.path("known")]) == known)
        #expect(pick([:], []) == bundled)
        chmod(bundled, 0o644)
        #expect(pick([:], []) == nil)
        // Ohne App-Ordner (Standard des Parameters) kein Fund im Bundle.
        chmod(bundled, 0o755)
        #expect(AICLIDetector.resolve(catalog: AICLICatalog.all, shellPaths: [:], directories: []).isEmpty)
    }

    @Test("App-Ordner: /Applications und ~/Applications; detect sucht dort (ohne Login-Shell)")
    func applicationDirectories() throws {
        #expect(AICLIDetector.applicationDirectories(home: "/Users/x") == ["/Applications", "/Users/x/Applications"])
        let fx = try Fixture()
        defer { fx.remove() }
        let wrapper = try Self.fakeCodexBundle(fx, appsDir: "Applications")
        let found = AICLIDetector.detect(environment: AppEnvironment(isSandboxed: false), home: fx.root, shell: nil,
                                         catalog: AICLICatalog.all.filter { $0.id == "cli.codex" },
                                         useLoginShell: false, applicationDirectories: [fx.path("Applications")])
        #expect(found.first?.path == wrapper)
        #expect(AICLIDetector.detect(environment: AppEnvironment(isSandboxed: true), home: fx.root, shell: nil,
                                     useLoginShell: false, applicationDirectories: [fx.path("Applications")]).isEmpty)
    }

    @Test("Ausgabe der Login-Shell: nur markierte Zeilen mit absolutem Pfad")
    func parse() {
        let out = """
        Welcome to your shell!
        __DISKRINGS_AI__claude=/opt/homebrew/bin/claude
        __DISKRINGS_AI__codex=alias codex='codex --yolo'
        __DISKRINGS_AI__gemini=gemini
        noise __DISKRINGS_AI__opencode=/tmp/x
        __DISKRINGS_AI__copilot=/Users/x/My Tools/copilot
        """
        #expect(AICLIDetector.parseLookup(out) == ["claude": "/opt/homebrew/bin/claude",
                                                   "copilot": "/Users/x/My Tools/copilot"])
    }

    @Test("Suchskript nur mit sicheren Namen")
    func script() {
        #expect(AICLIDetector.lookupScript(names: ["claude", "bad;rm -rf", "$(x)"])?.contains("bad") == false)
        #expect(AICLIDetector.lookupScript(names: ["a;b"]) == nil)
    }

    @Test("Echte Shell-Abfrage mit Zeitlimit; hängende Shell bricht ab")
    func loginShell() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let exe = try fx.file("bin/codex", size: 1)
        chmod(exe, 0o755)
        // Eigene „Shell“: ein sh-Skript, das PATH erweitert und den Befehl ausführt.
        let shell = try fx.file("fake-sh", size: 0)
        try "#!/bin/sh\nPATH=\(AICLILaunch.shellQuote(fx.path("bin"))):$PATH\nexport PATH\nshift\nexec /bin/sh -c \"$2\"\n"
            .write(toFile: shell, atomically: true, encoding: .utf8)
        chmod(shell, 0o755)
        let hits = AICLIDetector.loginShellLookup(shell: shell, names: ["codex", "doesnotexist-xyz"], timeout: 5)
        #expect(hits == ["codex": exe])

        let hang = try fx.file("hang-sh", size: 0)
        try "#!/bin/sh\nsleep 30 &\nsleep 30\n".write(toFile: hang, atomically: true, encoding: .utf8)
        chmod(hang, 0o755)
        let start = Date()
        #expect(AICLIDetector.loginShellLookup(shell: hang, names: ["codex"], timeout: 0.5).isEmpty)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    /// Lebt der Prozess noch (oder ist er nur noch nicht abgeräumt)? Wartet bis zu 3 s.
    static func waitGone(_ pid: pid_t) -> Bool {
        for _ in 0 ..< 300 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            usleep(10_000)
        }
        return false
    }

    @Test("Zeitlimit beendet die ganze Prozessgruppe, auch Kinder, die SIGTERM ignorieren (Verifier-Fund 2)")
    func timeoutKillsGroup() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let pidFile = fx.path("child.pid")
        let shell = try fx.file("trap-sh", size: 0)
        try "#!/bin/sh\ntrap '' TERM\n(trap '' TERM; sleep 20) &\necho $! > \(AICLILaunch.shellQuote(pidFile))\nsleep 20\n"
            .write(toFile: shell, atomically: true, encoding: .utf8)
        chmod(shell, 0o755)
        let start = Date()
        #expect(AICLIDetector.loginShellLookup(shell: shell, names: ["codex"], timeout: 0.7).isEmpty)
        #expect(Date().timeIntervalSince(start) < 3)
        let child = try #require(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(Self.waitGone(child), "Kindprozess \(child) lebt noch")
    }

    @Test("Auch nach normalem Ende bleiben keine Hintergrundprozesse der Startdateien zurück")
    func normalExitKillsOrphans() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let exe = try fx.file("bin/codex", size: 1)
        chmod(exe, 0o755)
        let pidFile = fx.path("bg.pid")
        // Wie `sleep 15 &` in .zprofile: Hintergrundprozess, Ausgabe nicht geerbt.
        let shell = try fx.file("bg-sh", size: 0)
        try ("#!/bin/sh\nsleep 15 >/dev/null 2>&1 &\necho $! > \(AICLILaunch.shellQuote(pidFile))\n"
            + "PATH=\(AICLILaunch.shellQuote(fx.path("bin"))):$PATH\nexport PATH\nshift\nexec /bin/sh -c \"$2\"\n")
            .write(toFile: shell, atomically: true, encoding: .utf8)
        chmod(shell, 0o755)
        #expect(AICLIDetector.loginShellLookup(shell: shell, names: ["codex"], timeout: 5) == ["codex": exe])
        let bg = try #require(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(Self.waitGone(bg), "Hintergrundprozess \(bg) lebt noch")
    }

    @Test("Eingabe ist /dev/null (liest sofort EOF)")
    func stdinIsDevNull() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let shell = try fx.file("read-sh", size: 0)
        try "#!/bin/sh\nif read x; then echo got; else echo eof; fi\n".write(toFile: shell, atomically: true, encoding: .utf8)
        chmod(shell, 0o755)
        let out = AICLIDetector.run(executable: shell, arguments: [], timeout: 3).map { String(decoding: $0, as: UTF8.self) }
        #expect(out == "eof\n")
    }

    @Test("Shell-Auswahl: POSIX-artige Login-Shell, sonst zsh")
    func shellChoice() {
        #expect(AICLIDetector.lookupShell("/bin/zsh") == "/bin/zsh")
        #expect(AICLIDetector.lookupShell("/bin/bash") == "/bin/bash")
        #expect(AICLIDetector.lookupShell("/opt/homebrew/bin/fish") == "/bin/zsh")
        #expect(AICLIDetector.lookupShell(nil) == "/bin/zsh")
        #expect(AICLIDetector.lookupShell("zsh") == "/bin/zsh")
    }

    @Test("In der Sandbox: keine Suche")
    func sandbox() {
        #expect(AICLIDetector.detect(environment: AppEnvironment(isSandboxed: true), home: "/Users/x", shell: "/bin/zsh").isEmpty)
    }

    @Test("Bekannte Orte enthalten Home-Ordner-Pfade und nvm-Versionen absteigend")
    func known() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.dir(".nvm/versions/node/v18.20.1/bin")
        try fx.dir(".nvm/versions/node/v22.3.0/bin")
        try fx.dir(".nvm/versions/node/v9.0.0/bin")
        let dirs = AICLIDetector.knownDirectories(home: fx.root)
        #expect(dirs.contains("/opt/homebrew/bin"))
        #expect(dirs.contains(fx.root + "/.local/bin"))
        #expect(dirs.contains(fx.root + "/.claude/local"))
        let nvm = dirs.filter { $0.contains("/.nvm/") }
        #expect(nvm == ["v22.3.0", "v18.20.1", "v9.0.0"].map { fx.root + "/.nvm/versions/node/\($0)/bin" })
        #expect(Set(dirs).count == dirs.count)
    }
}

@Suite("KI-CLIs: Startskript")
struct AICLILaunchTests {
    static let nasty = [
        "Ordner mit Leerzeichen",
        "it's \"quoted\"",
        "$HOME `whoami` $(id) ${PATH}",
        "back\\slash; rm -rf ~ &| *",
        "Zeile1\nZeile2",
        "日本語 ü 😀",
        "-n",
        String(repeating: "lang", count: 60),
    ]

    @Test("Quoting für /bin/sh")
    func quoting() {
        #expect(AICLILaunch.shellQuote("a b") == "'a b'")
        #expect(AICLILaunch.shellQuote("it's") == "'it'\\''s'")
        #expect(AICLILaunch.shellQuote("") == "''")
    }

    @Test("Skript ist syntaktisch gültig (sh -n) für fiese Namen")
    func syntax() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let tool = try #require(AICLICatalog.tool(id: "cli.copilot"))
        for (i, name) in Self.nasty.enumerated() {
            let s = AICLILaunch.script(tool: tool, executable: "/opt/x y/\(name)/gemini", workingDirectory: "/tmp/\(name)",
                                       promptFile: "/tmp/\(name)/p.txt", scriptFile: "/tmp/\(name)/s.command",
                                       banner: "Banner \(name)")
            let f = fx.path("s\(i).sh")
            try s.write(toFile: f, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-n", f]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(name)")
            #expect(!s.contains("--yolo"))
        }
    }

    @Test("Ausführung mit Fake-CLI: argv exakt, Arbeitsordner, Prompt ohne Shell-Auswertung, Aufräumen")
    func runWithFakeCLI() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for tool in AICLICatalog.all {
            for (i, name) in Self.nasty.enumerated() {
                let work = try fx.dir("work-\(tool.id)-\(i)/\(name)")
                let binDir = try fx.dir("bin \(i)/\(name)")
                let out = fx.path("out-\(tool.id)-\(i).txt")
                let cli = binDir + "/fake"
                // Fake-CLI: schreibt Arbeitsordner und alle Argumente NUL-getrennt.
                try "#!/bin/sh\nprintf '%s\\0' \"$(pwd -P)\" \"$@\" > \(AICLILaunch.shellQuote(out))\n"
                    .write(toFile: cli, atomically: true, encoding: .utf8)
                chmod(cli, 0o755)
                let prompt = "Prompt with $HOME `id` $(whoami) \"q\" 'q' \\ \n second line \(name)\n"
                let base = URL(fileURLWithPath: fx.path("launch"))
                let scriptURL = try AICLILaunch.prepare(tool: tool, executable: cli, workingDirectory: work, prompt: prompt,
                                                        banner: "DiskRings \(name)", base: base)
                // Rechte: Ordner 0700, Prompt 0600, Skript 0700.
                var st = stat()
                #expect(stat(scriptURL.deletingLastPathComponent().path, &st) == 0 && st.st_mode & 0o777 == 0o700)
                #expect(stat(scriptURL.deletingLastPathComponent().appendingPathComponent("prompt.txt").path, &st) == 0
                    && st.st_mode & 0o777 == 0o600)
                #expect(stat(scriptURL.path, &st) == 0 && st.st_mode & 0o777 == 0o700)
                #expect(scriptURL.pathExtension == "command")

                let p = Process()
                p.executableURL = scriptURL
                p.standardOutput = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                #expect(p.terminationStatus == 0, "\(tool.id) \(name)")
                let data = try Data(contentsOf: URL(fileURLWithPath: out))
                var args = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
                    .map { String(decoding: $0, as: UTF8.self) }
                let pwd = args.isEmpty ? "" : args.removeFirst()
                let real = String(cString: realpath(work, nil))
                #expect(pwd == real, "\(tool.id) \(name)")
                // $(cat) entfernt nur abschließende Zeilenumbrüche.
                var expectedPrompt = prompt
                while expectedPrompt.hasSuffix("\n") { expectedPrompt.removeLast() }
                #expect(args == tool.argv(prompt: expectedPrompt), "\(tool.id) \(name)")
                // Prompt, Skript und Ordner sind weg.
                #expect(!FileManager.default.fileExists(atPath: scriptURL.deletingLastPathComponent().path))
            }
        }
    }

    @Test("Start eines Wrappers in einem App-Bundle mit Leerzeichen im Pfad (Codex aus ChatGPT.app)")
    func launchFromAppBundle() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let tool = try #require(AICLICatalog.tool(id: "cli.codex"))
        let res = "My Apps/Chat GPT.app/Contents/Resources/codex-cli"
        let out = fx.path("out.txt")
        let real = try fx.file("\(res)/CodexCLI.app/Contents/MacOS/codex", size: 1)
        try "#!/bin/sh\nprintf '%s\\0' \"$(pwd -P)\" \"$@\" > \(AICLILaunch.shellQuote(out))\n"
            .write(toFile: real, atomically: true, encoding: .utf8)
        chmod(real, 0o755)
        try fx.dir("\(res)/bin")
        let wrapper = fx.path("\(res)/bin/codex")
        try "#!/bin/sh\nset -eu\nbin_dir=$(CDPATH= cd -P -- \"$(dirname -- \"$0\")\" && pwd)\nexec \"$bin_dir/../CodexCLI.app/Contents/MacOS/codex\" \"$@\"\n"
            .write(toFile: wrapper, atomically: true, encoding: .utf8)
        chmod(wrapper, 0o755)
        #expect(AICLIDetector.isUsableExecutable(wrapper))
        let work = try fx.dir("work dir")
        let script = AICLILaunch.script(tool: tool, executable: wrapper, workingDirectory: work, promptFile: "/p",
                                        scriptFile: "/s/x.command", banner: "B")
        #expect(script.contains("PATH='\(fx.path("\(res)/bin"))':\"$PATH\""))
        let scriptURL = try AICLILaunch.prepare(tool: tool, executable: wrapper, workingDirectory: work, prompt: "Hallo",
                                                banner: "B", base: URL(fileURLWithPath: fx.path("launch")))
        let p = Process()
        p.executableURL = scriptURL
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let args = try Data(contentsOf: URL(fileURLWithPath: out)).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(args.first == String(cString: realpath(work, nil)))
        #expect(Array(args.dropFirst()) == tool.argv(prompt: "Hallo"))
    }

    @Test("Arbeitsordner: Ordner selbst, sonst Elternordner")
    func workingDirectory() {
        #expect(AICLILaunch.workingDirectory(forPath: "/a/b", isDirectory: true) == "/a/b")
        #expect(AICLILaunch.workingDirectory(forPath: "/a/b.txt", isDirectory: false) == "/a")
    }

    @Test("Alte Reste werden entfernt, neue bleiben")
    func stale() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let base = URL(fileURLWithPath: try fx.dir("launch"))
        let old = try fx.dir("launch/old")
        let new = try fx.dir("launch/new")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old)
        AICLILaunch.removeStale(base: base)
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: new))
    }
}
#endif

@Suite("KI-CLIs: Trennung von der Store-Variante")
struct AISessionsSeparationTests {
    @Test("Code für CLI-Sitzungen steht nur unter #if AISessions")
    func guarded() throws {
        let needles = ["AICLILaunch", "AICLIDetector", "AICLICatalog", "com.apple.Terminal"]
        for file in SourceTree.swiftSources() where file.path.hasPrefix("Sources/") {
            // Stapel der #if-Blöcke: true = Zweig von `#if AISessions`.
            var guardedDepth: [Bool] = []
            for line in file.text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#if ") { guardedDepth.append(t == "#if AISessions"); continue }
                if t.hasPrefix("#else") { _ = guardedDepth.popLast(); guardedDepth.append(false); continue }
                if t.hasPrefix("#endif") { _ = guardedDepth.popLast(); continue }
                if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                let inside = guardedDepth.contains(true)
                for n in needles where line.contains(n) && !inside {
                    Issue.record("\(file.path): \(line)")
                }
            }
        }
    }
}
