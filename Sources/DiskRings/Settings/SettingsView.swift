import AppKit
import DiskRingsCore
import SwiftUI

/// Einstellungen (SPEC 3.7), soweit sie in M2/M3 schon wirken.
struct SettingsView: View {
    @Bindable var prefs: Preferences
    @ViewState private var selectedExclusion: String?

    var body: some View {
        Form {
            Section("Diagramm") {
                Stepper(value: $prefs.ringCount, in: SunburstOptions.ringRange) {
                    LabeledContent("Ringanzahl", value: "\(prefs.ringCount)")
                }
                Picker("Farbschema", selection: $prefs.paletteScheme) {
                    Text("Nach Ast").tag(PaletteScheme.branch)
                    Text("Nach Dateityp").tag(PaletteScheme.fileType)
                }
                if prefs.paletteScheme == .fileType {
                    FileTypeLegend()
                }
                LabeledContent("Sammelsegment unter") {
                    HStack {
                        Slider(value: $prefs.minAngleDegrees, in: Preferences.minAngleRange, step: 0.1)
                            .frame(width: 160)
                            .accessibilityValue(String(format: "%.1f Grad", prefs.minAngleDegrees))
                        Text(String(format: "%.1f°", prefs.minAngleDegrees).replacingOccurrences(of: ".", with: ","))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Segmente beschriften", isOn: $prefs.showLabels)
            }
            Section("Größe") {
                Picker("Größenmodus", selection: $prefs.sizeMode) {
                    Text("Belegt auf Platte").tag(SizeMode.allocated)
                    Text("Logische Größe").tag(SizeMode.logical)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Toggle("Vor dem Papierkorb fragen", isOn: Binding(get: { !prefs.skipTrashConfirmation },
                                                                  set: { prefs.skipTrashConfirmation = !$0 }))
            } header: {
                Text("Papierkorb")
            } footer: {
                Text("Elemente ab 1 GB werden immer bestätigt.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Versteckte Dateien zählen", isOn: $prefs.includeHidden)
                Toggle("Andere Volumes beim Scan überqueren", isOn: $prefs.crossMountPoints)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ausgeschlossene Pfade")
                    List(prefs.excludedPaths, id: \.self, selection: $selectedExclusion) { p in
                        Text(p).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(height: 90)
                    .border(Color.primary.opacity(0.15))
                    HStack(spacing: 4) {
                        Button { addExclusion() } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Pfad hinzufügen")
                        Button {
                            if let s = selectedExclusion { prefs.excludedPaths.removeAll { $0 == s } }
                            selectedExclusion = nil
                        } label: { Image(systemName: "minus") }
                            .disabled(selectedExclusion == nil)
                            .accessibilityLabel("Ausgewählten Pfad entfernen")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Scan")
            } footer: {
                Text("Diese Einstellungen wirken beim nächsten Scan.").font(.footnote).foregroundStyle(.secondary)
            }
            SnapshotSettingsSection(prefs: prefs.snapshots)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Ausschließen"
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
        .accessibilityLabel("Legende: " + FileTypeCategory.allCases.map(\.label).joined(separator: ", "))
    }
}
