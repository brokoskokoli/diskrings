import AppKit
import DiskRingsCore
import SwiftUI

/// Abschnitt „Sprache“ der Einstellungen: Automatisch (System) oder eine feste
/// Sprache, gespeichert als `AppleLanguages` der App (`LanguageSetting`, Core).
/// Die Oberfläche übernimmt die Sprache erst nach einem Neustart.
struct LanguageSection: View {
    /// Für die Vorschaubilder: feste Wahl statt der gespeicherten.
    var previewChoice: LanguageChoice?
    @ViewState private var choice: LanguageChoice = LanguageSetting().choice

    var body: some View {
        Section {
            Picker(L("settings.language"), selection: Binding(get: { previewChoice ?? choice }, set: select)) {
                ForEach(LanguageChoice.all, id: \.self) { c in
                    Text(c.title).tag(c)
                }
            }
            if LanguageSetting.needsRestart(choice: previewChoice ?? choice, running: L10n.language) {
                HStack(alignment: .firstTextBaseline) {
                    Label(L("settings.language.restartNote"), systemImage: "arrow.clockwise.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L("settings.language.restartNow")) { AppRelauncher.relaunch() }
                }
            }
        } header: {
            Text(L("settings.section.language"))
        } footer: {
            Text(L("settings.language.footer")).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func select(_ c: LanguageChoice) {
        choice = c
        LanguageSetting().set(c)
    }
}

/// Startet die App neu: Ein kleiner Shell-Prozess wartet, bis dieser Prozess
/// beendet ist, und öffnet die App dann wieder (im Bündel per `open`, bei
/// `swift run` direkt das Programm). So laufen nie zwei Instanzen gleichzeitig.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath
        let wait = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done"
        let start: String
        let target: String
        if bundlePath.hasSuffix(".app") {
            start = "/usr/bin/open \"$0\""
            target = bundlePath
        } else {
            start = "\"$0\" >/dev/null 2>&1 &"
            target = Bundle.main.executablePath ?? CommandLine.arguments[0]
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "\(wait); \(start)", target]
        do {
            try task.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}
