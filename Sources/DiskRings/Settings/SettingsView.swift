import AppKit
import DiskRingsCore
import SwiftUI

/// Reiter des Einstellungsfensters. „Ordnerzugriff“ gibt es nur in der
/// App-Store-Variante (Sandbox).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, chart, scan, snapshots, access

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("settings.tab.general")
        case .chart: L("settings.section.chart")
        case .scan: L("settings.section.scan")
        case .snapshots: L("settings.section.snapshots")
        case .access: L("settings.section.access")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .chart: "chart.pie"
        case .scan: "internaldrive"
        case .snapshots: "clock.arrow.circlepath"
        case .access: "lock.shield"
        }
    }

    static func visible(sandboxed: Bool) -> [SettingsTab] {
        sandboxed ? allCases : allCases.filter { $0 != .access }
    }
}

/// Einstellungen (SPEC 3.7) als Fenster mit Reitern. Jeder Reiter ist ein
/// eigenes, kurzes Formular, damit das Fenster auch auf kleinen Bildschirmen
/// ganz sichtbar bleibt; lange Listen scrollen innerhalb ihres Reiters.
struct SettingsView: View {
    @Bindable var prefs: Preferences
    /// Für die Ordnerfreigaben der App-Store-Variante; `nil` in Vorschaubildern ohne Zustand.
    var state: AppState?
    @AppStorage("settings.selectedTab") private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        let tabs = SettingsTab.visible(sandboxed: state?.isSandboxed ?? false)
        TabView(selection: $selectedTab) {
            ForEach(tabs) { tab in
                SettingsPage(tab: tab, prefs: prefs, state: state)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab.rawValue)
            }
        }
        .onAppear {
            if !tabs.map(\.rawValue).contains(selectedTab) { selectedTab = SettingsTab.general.rawValue }
        }
    }
}

/// Inhalt eines Reiters. Die Bild-Renderer zeichnen jeden Reiter einzeln.
struct SettingsPage: View {
    let tab: SettingsTab
    @Bindable var prefs: Preferences
    var state: AppState?
    @ViewState private var selectedExclusion: String?

    static let width: CGFloat = 500
    /// Höhe des Reiters „Ordnerzugriff“: Die Liste der Freigaben kann beliebig
    /// lang werden und scrollt deshalb in fester Höhe.
    static let accessHeight: CGFloat = 380

    var body: some View {
        switch tab {
        case .access:
            Form {
                if let state { FolderAccessSection(state: state) }
            }
            .formStyle(.grouped)
            .frame(width: Self.width, height: Self.accessHeight)
        default:
            // Die übrigen Reiter haben einen begrenzten Inhalt und sind so hoch wie nötig.
            Form { content }
                .formStyle(.grouped)
                .frame(width: Self.width)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:
            LanguageSection()
            Section {
                Toggle(L("settings.trash.confirm"), isOn: Binding(get: { !prefs.skipTrashConfirmation },
                                                                  set: { prefs.skipTrashConfirmation = !$0 }))
            } header: {
                Text(L("settings.section.trash"))
            } footer: {
                Text(L("settings.trash.footer")).font(.footnote).foregroundStyle(.secondary)
            }
        case .chart:
            Section(L("settings.section.chart")) {
                Stepper(value: $prefs.ringCount, in: SunburstOptions.ringRange) {
                    LabeledContent(L("settings.rings"), value: ByteFormat.count(prefs.ringCount))
                }
                Picker(L("settings.colorScheme"), selection: $prefs.paletteScheme) {
                    Text(L("settings.colorScheme.branch")).tag(PaletteScheme.branch)
                    Text(L("settings.colorScheme.fileType")).tag(PaletteScheme.fileType)
                }
                if prefs.paletteScheme == .fileType {
                    FileTypeLegend()
                }
                LabeledContent(L("settings.minAngle")) {
                    HStack {
                        Slider(value: $prefs.minAngleDegrees, in: Preferences.minAngleRange, step: 0.1)
                            .frame(width: 160)
                            .accessibilityValue(L("settings.minAngle.accessibilityValue", angleText))
                        Text(TextFormat.degrees(angleText))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle(L("settings.showLabels"), isOn: $prefs.showLabels)
            }
            Section(L("settings.section.size")) {
                Picker(L("settings.sizeMode"), selection: $prefs.sizeMode) {
                    Text(L("settings.sizeMode.allocated")).tag(SizeMode.allocated)
                    Text(L("settings.sizeMode.logical")).tag(SizeMode.logical)
                }
                .pickerStyle(.radioGroup)
            }
        case .scan:
            Section {
                Toggle(L("settings.includeHidden"), isOn: $prefs.includeHidden)
                Toggle(L("settings.crossMounts"), isOn: $prefs.crossMountPoints)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("settings.excluded"))
                    List(prefs.excludedPaths, id: \.self, selection: $selectedExclusion) { p in
                        Text(p).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(height: 120)
                    .border(Color.primary.opacity(0.15))
                    HStack(spacing: 4) {
                        Button { addExclusion() } label: { Image(systemName: "plus") }
                            .accessibilityLabel(L("settings.excluded.add"))
                        Button {
                            if let s = selectedExclusion { prefs.excludedPaths.removeAll { $0 == s } }
                            selectedExclusion = nil
                        } label: { Image(systemName: "minus") }
                            .disabled(selectedExclusion == nil)
                            .accessibilityLabel(L("settings.excluded.remove"))
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text(L("settings.section.scan"))
            } footer: {
                Text(L("settings.scan.footer")).font(.footnote).foregroundStyle(.secondary)
            }
        case .snapshots:
            SnapshotSettingsSection(prefs: prefs.snapshots)
        case .access:
            EmptyView()
        }
    }

    /// Winkelschwelle mit einer Nachkommastelle im Format des Locales („0.5“, „0,5“).
    private var angleText: String {
        prefs.minAngleDegrees.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("settings.excluded.prompt")
        if panel.runModal() == .OK {
            for url in panel.urls where !prefs.excludedPaths.contains(url.path) {
                prefs.excludedPaths.append(url.path)
            }
        }
    }
}

/// Legende für das Farbschema „Dateityp“.
struct FileTypeLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette(scheme: .fileType, appearance: PaletteAppearance(colorScheme))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 6) {
            ForEach(FileTypeCategory.allCases, id: \.self) { c in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(palette.categoryColor(c))).frame(width: 12, height: 12)
                    Text(c.label).font(.system(size: 11)).lineLimit(1).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("settings.legend.accessibility", FileTypeCategory.allCases.map(\.label).joined(separator: L("list.separator"))))
    }
}

/// Ordnerfreigaben der App-Store-Variante (SPEC 11.2): Liste, entfernen, hinzufügen.
struct FolderAccessSection: View {
    let state: AppState

    var body: some View {
        Section {
            if state.grantedFolders.isEmpty {
                Text(L("settings.access.empty")).foregroundStyle(.secondary)
            }
            ForEach(state.grantedFolders, id: \.path) { grant in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: grant.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(grant.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { state.revokeAccess(grant.path) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(L("settings.access.remove"))
                        .accessibilityLabel(L("settings.access.remove"))
                }
            }
            Button(L("sandbox.grantMore")) { state.grantMoreFolders() }
        } header: {
            Text(L("settings.section.access"))
        } footer: {
            Text(L("settings.access.footer")).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
