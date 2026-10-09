import AppKit
import DiskRingsCore
import SwiftUI

/// Einstellungen (SPEC 3.7), soweit sie in M2/M3 schon wirken.
struct SettingsView: View {
    @Bindable var prefs: Preferences
    @ViewState private var selectedExclusion: String?

    var body: some View {
        Form {
            LanguageSection()
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
                        Text(angleText + "°")
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
            Section {
                Toggle(L("settings.trash.confirm"), isOn: Binding(get: { !prefs.skipTrashConfirmation },
                                                                  set: { prefs.skipTrashConfirmation = !$0 }))
            } header: {
                Text(L("settings.section.trash"))
            } footer: {
                Text(L("settings.trash.footer")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("settings.includeHidden"), isOn: $prefs.includeHidden)
                Toggle(L("settings.crossMounts"), isOn: $prefs.crossMountPoints)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("settings.excluded"))
                    List(prefs.excludedPaths, id: \.self, selection: $selectedExclusion) { p in
                        Text(p).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(height: 90)
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
            SnapshotSettingsSection(prefs: prefs.snapshots)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
