import DiskRingsCore
import SwiftUI

/// Hauptansicht (SPEC 3.3): Toolbar mit Zurück/Vor, Breadcrumb und Rescan,
/// links das Diagramm, rechts die Detailliste, unten die Statusleiste.
struct BrowserView: View {
    let state: AppState
    var frozenTime: Date?

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbar(state: state)
            Divider()
            if state.showSummary, let r = state.result {
                ScanSummaryBanner(state: state, result: r)
                Divider()
            }
            HStack(spacing: 0) {
                SunburstView(state: state, frozenTime: frozenTime)
                    .padding(16)
                    .overlay(alignment: .bottomLeading) {
                        if state.prefs.paletteScheme == .fileType {
                            FileTypeLegend()
                                .frame(width: 380)
                                .padding(10)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding(12)
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DetailListView(state: state)
                    .frame(width: 400)
                    .frame(maxHeight: .infinity)
            }
            Divider()
            StatusBar(state: state)
        }
    }
}

struct BrowserToolbar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { state.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!state.history.canGoBack)
                    .help("Zurück (⌘[)")
                    .accessibilityLabel("Zurück")
                Button { state.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!state.history.canGoForward)
                    .help("Vor (⌘])")
                    .accessibilityLabel("Vor")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            BreadcrumbView(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.phase == .scanning {
                ProgressView().controlSize(.small).accessibilityLabel("Scan läuft")
            }
            Button { state.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .help("Komplett neu scannen")
                .disabled(state.phase == .scanning)
            Button { state.backToStart() } label: { Label("Neuer Scan", systemImage: "externaldrive") }
                .help("Zurück zum Startbildschirm")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Breadcrumb (SPEC 3.3/3.4): Pfad bis zum Fokus, beim Hover verlängert um
/// den Pfad bis zum Segment unter der Maus.
struct BreadcrumbView: View {
    let state: AppState

    var body: some View {
        if let tree = state.tree {
            let focusPath = Breadcrumb.path(in: tree, to: state.focus)
            let hoverPath: [Int32] = {
                guard let h = state.hoverNode, h != state.focus,
                      Breadcrumb.isAncestor(state.focus, of: h, in: tree) else { return [] }
                return Array(Breadcrumb.path(in: tree, to: h).dropFirst(focusPath.count))
            }()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(focusPath.enumerated()), id: \.element) { i, node in
                        if i > 0 { separator }
                        Button { state.navigate(to: node) } label: {
                            HStack(spacing: 4) {
                                if i == 0 {
                                    Image(systemName: state.isVolumeRoot ? "internaldrive" : "folder")
                                        .foregroundStyle(.secondary)
                                }
                                Text(label(tree, node)).lineLimit(1)
                            }
                            .fontWeight(node == state.focus ? .semibold : .regular)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(label(tree, node))\(node == state.focus ? ", aktueller Ordner" : "")")
                    }
                    ForEach(hoverPath, id: \.self) { node in
                        separator
                        Text(tree.name(of: node))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                    }
                }
                .font(.system(size: 13))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pfad")
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func label(_ tree: ScanTree, _ node: Int32) -> String {
        if node == ScanTree.rootIndex {
            if state.isVolumeRoot, let v = state.volume { return v.name }
            return tree.rootPath
        }
        return tree.name(of: node)
    }
}

/// Statusleiste mit der Volume-Belegung (SPEC 3.3).
struct StatusBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if let v = state.volume {
                Image(systemName: "internaldrive").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(volumeText(v))
                if state.unassigned > 0 {
                    Text("· nicht zugeordnet \(ByteFormat.string(state.unassigned))")
                        .help("Belegung des Volumes, die in keinem Ordner auftaucht: System, lokale Time-Machine-Snapshots, bereinigbarer Speicher. Klone und Snapshots können Abweichungen verursachen.")
                }
            } else if let p = state.progress {
                Text("\(filesText(p.filesScanned)) · \(ByteFormat.string(p.allocatedBytes))")
            }
            Spacer()
            if let r = state.result {
                Text("Scan: \(filesText(r.fileCount)) in \(ByteFormat.duration(r.duration))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .accessibilityElement(children: .combine)
    }

    private func volumeText(_ v: VolumeInfo) -> String {
        var s = "\(v.name): \(ByteFormat.string(v.totalCapacity)) · belegt \(ByteFormat.string(v.usedCapacity)) · frei \(ByteFormat.string(v.availableCapacity))"
        if v.purgeableCapacity > 0 { s += " (davon \(ByteFormat.string(v.purgeableCapacity)) bereinigbar)" }
        return s
    }
}

/// Zusammenfassung nach dem Scan (SPEC 3.2) mit aufklappbarer Liste der
/// nicht lesbaren Ordner.
struct ScanSummaryBanner: View {
    let state: AppState
    let result: ScanResult
    @ViewState private var showUnreadable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text("Scan abgeschlossen: \(filesText(result.fileCount)), \(ByteFormat.count(result.directoryCount)) Ordner, \(ByteFormat.string(result.allocatedSize)) in \(ByteFormat.duration(result.duration))")
                if !result.unreadablePaths.isEmpty {
                    Button(showUnreadable ? "Weniger" : "\(ByteFormat.count(result.unreadablePaths.count)) nicht lesbar") {
                        showUnreadable.toggle()
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button { state.showSummary = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Zusammenfassung schließen")
            }
            if showUnreadable {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(result.unreadablePaths, id: \.self) { p in
                            Label(p, systemImage: "lock.fill").font(.system(size: 11)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                if state.fullDiskAccess == .denied {
                    Button("Festplattenvollzugriff erteilen…") { state.openFullDiskAccessSettings() }
                        .controlSize(.small)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.07))
    }
}
