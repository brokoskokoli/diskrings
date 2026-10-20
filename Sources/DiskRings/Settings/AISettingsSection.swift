import DiskRingsCore
import SwiftUI

/// Reiter „KI“: welche Web-KIs (und in der GitHub-Variante welche CLIs) im
/// Menü „Mit KI analysieren“ erscheinen, Datenschutz-Hinweis wieder zeigen.
/// „Prompt kopieren“ ist immer da und hat deshalb keinen Schalter.
struct AISettingsSections: View {
    @Bindable var prefs: Preferences
    var state: AppState?

    var body: some View {
        Section {
            ForEach(AIWebCatalog.all) { service in
                Toggle(isOn: binding(service.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.name)
                        Text(service.handoff == .copyAndOpen ? L("settings.ai.copyOpen") : L("settings.ai.prefill"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help(service.homeURL)
            }
            selectButtons(AIWebCatalog.all.map(\.id))
        } header: {
            Text(L("settings.ai.web"))
        } footer: {
            Text(L("settings.ai.web.footer")).font(.footnote).foregroundStyle(.secondary)
        }
        #if AISessions
        if let state, !state.isSandboxed {
            AICLISettingsSection(prefs: prefs, state: state, binding: binding, selectButtons: selectButtons)
        }
        #endif
        Section(L("settings.ai.privacy")) {
            // „Nicht mehr fragen“ gilt getrennt für Web und Sitzung; der Knopf setzt beide zurück.
            Button(L("settings.ai.askConsent")) { prefs.aiConsent.reset() }
                .disabled(prefs.aiConsent.asksAlways)
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { prefs.aiSelection.isEnabled(id) },
                set: { on in
                    var s = prefs.aiSelection
                    s.set(id, enabled: on)
                    prefs.aiSelection = s
                })
    }

    private func selectButtons(_ ids: [String]) -> some View {
        HStack {
            Spacer()
            Button(L("settings.ai.selectAll")) {
                var s = prefs.aiSelection
                s.setAll(ids, enabled: true)
                prefs.aiSelection = s
            }
            Button(L("settings.ai.deselectAll")) {
                var s = prefs.aiSelection
                s.setAll(ids, enabled: false)
                prefs.aiSelection = s
            }
        }
        .controlSize(.small)
    }
}

#if AISessions
/// CLIs: gefundene wählbar (Pfad als Untertitel), fehlende ausgegraut.
private struct AICLISettingsSection<Buttons: View>: View {
    @Bindable var prefs: Preferences
    let state: AppState
    let binding: (String) -> Binding<Bool>
    let selectButtons: ([String]) -> Buttons

    var body: some View {
        Section {
            ForEach(AICLICatalog.all) { tool in
                let found = state.ai.tools?.first { $0.id == tool.id }
                Toggle(isOn: found == nil ? .constant(false) : binding(tool.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.name)
                        Text(found.map { state.promptAnonymizer.displayPath($0.path) }
                            ?? (state.ai.tools == nil ? L("ai.session.searching") : L("settings.ai.notInstalled")))
                            .font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(found == nil)
                .help(found?.path ?? "")
            }
            HStack {
                Button(L("ai.session.rescan")) { state.ai.detectTools(environment: state.environment) }
                    .disabled(state.ai.isSearching)
                if state.ai.isSearching { ProgressView().controlSize(.small) }
                Spacer()
                selectButtons(AICLICatalog.all.map(\.id))
            }
            .controlSize(.small)
        } header: {
            Text(L("settings.ai.cli"))
        } footer: {
            Text(L("settings.ai.cli.footer")).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
#endif
