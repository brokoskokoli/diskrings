import DiskRingsCore
import SwiftUI

/// Toolbar-Button „Vergleichen mit…“ (SPEC 3.9) mit einem Popup der
/// passenden Snapshots (gleiche Volume-UUID und Scan-Wurzel), der jüngste
/// vorausgewählt.
struct CompareToolbarButton: View {
    let state: AppState
    @ViewState private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: { Label("Vergleichen mit…", systemImage: "clock.arrow.2.circlepath") }
            .help("Diesen Scan mit einem gespeicherten Snapshot vergleichen")
            .disabled(state.result == nil || state.tree == nil || state.phase == .scanning)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                CompareSnapshotPicker(state: state) { showPicker = false }
            }
    }
}

/// Inhalt des Popups: Liste der passenden Snapshots.
struct CompareSnapshotPicker: View {
    let state: AppState
    var dismiss: () -> Void = {}
    @ViewState private var selection: SnapshotInfo.ID?

    var body: some View {
        let candidates = currentCandidates
        VStack(alignment: .leading, spacing: 10) {
            Text("Vergleichen mit…").font(.headline)
            if candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keine passenden Snapshots").font(.subheadline.weight(.medium))
                    Text("Es gibt noch keinen älteren Snapshot dieser Scan-Wurzel auf diesem Volume. Snapshots entstehen automatisch nach jedem Scan oder mit „Ablage → Snapshot sichern“ (⌘S).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                List(candidates, selection: $selection) { info in
                    SnapshotPickerRow(info: info).tag(info.id)
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .frame(height: min(CGFloat(candidates.count) * 50 + 10, 300))
                HStack {
                    Text("\(candidates.count) passend").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Vergleichen") {
                        if let info = candidates.first(where: { $0.id == selection }) ?? candidates.first {
                            state.startCompare(with: info)
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 400)
        .onAppear {
            state.snapshots.refresh()
            if selection == nil { selection = SnapshotMatching.defaultSelection(currentCandidates)?.id }
        }
    }

    private var currentCandidates: [SnapshotInfo] {
        guard let tree = state.tree else { return [] }
        return state.snapshots.candidates(rootPath: tree.rootPath, volumeUUID: state.volume?.uuid)
    }
}

struct SnapshotPickerRow: View {
    let info: SnapshotInfo

    var body: some View {
        let m = info.metadata
        VStack(alignment: .leading, spacing: 2) {
            Text(SnapshotNaming.title(m)).font(.system(size: 12, weight: .medium)).lineLimit(1)
            HStack(spacing: 6) {
                if SnapshotNaming.normalized(m.name) != nil { Text(SnapshotNaming.longDate(m.date)) }
                Text(ByteFormat.string(m.allocatedSize))
                Text(filesText(Int(m.fileCount)))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
