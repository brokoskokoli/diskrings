import AppKit
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
            if state.showSummary, let r = state.summary {
                ScanSummaryBanner(state: state, result: r)
                Divider()
            }
            BrowserBody(state: state, frozenTime: frozenTime)
            Divider()
            StatusBar(state: state)
        }
        .modifier(CompareModeSwitch(state: state, frozenTime: frozenTime))
        .sheet(isPresented: Binding(get: { state.trashRequest != nil }, set: { if !$0 { state.trashRequest = nil } })) {
            if let plan = state.trashRequest {
                TrashConfirmationView(plan: plan, onCancel: { state.trashRequest = nil },
                                      onConfirm: { state.confirmTrash(dontAskAgain: $0) })
            }
        }
        .sheet(isPresented: Binding(get: { state.infoNode != nil }, set: { if !$0 { state.infoNode = nil } })) {
            if let n = state.infoNode { NodeInfoView(state: state, node: n) { state.infoNode = nil } }
        }
    }
}

/// Diagramm und Liste (Hauptansicht und Scan-Ansicht). Die Liste ist über
/// den Teiler in der Breite verstellbar (siehe dev/DECISIONS.md: eigener
/// Teiler statt `HSplitView`, weil dieser die Startbreite nicht übernimmt).
struct BrowserBody: View {
    let state: AppState
    var frozenTime: Date?
    @ViewState private var dragStart: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let maxList = max(Preferences.listWidthRange.lowerBound, min(Preferences.listWidthRange.upperBound,
                                                                         proxy.size.width - 420))
            let listWidth = min(state.prefs.listWidth, maxList)
            HStack(spacing: 0) {
                diagram
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                divider(maxList: maxList)
                list
                    .frame(width: listWidth)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var diagram: some View {
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
            .overlay(alignment: .bottom) {
                if let t = state.toast {
                    ToastView(state: state, toast: t)
                        .padding(.horizontal, 16)
                        .padding(.bottom, state.prefs.paletteScheme == .fileType ? 96 : 14)
                        // „Bewegung reduzieren“: nur einblenden, nicht hereinschieben.
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: state.toast?.id)
    }

    @ViewBuilder private var list: some View {
        if state.showSearchResults, state.searchVisible {
            SearchResultsView(state: state)
        } else {
            DetailListView(state: state)
        }
    }

    /// Teiler: 1 pt Linie, 7 pt Griffbereich, Doppelklick setzt auf 400 pt zurück.
    private func divider(maxList: Double) -> some View {
        Divider()
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            let start = dragStart ?? min(state.prefs.listWidth, maxList)
                            if dragStart == nil { dragStart = start }
                            let w = start - g.translation.width
                            state.prefs.listWidth = min(max(w, Preferences.listWidthRange.lowerBound), maxList)
                        }
                        .onEnded { _ in dragStart = nil })
                    .onTapGesture(count: 2) { state.prefs.listWidth = 400 }
            }
            .accessibilityLabel(L("browser.listWidth"))
            .accessibilityValue(L("browser.listWidth.value", ByteFormat.count(Int(state.prefs.listWidth))))
            .accessibilityAdjustableAction { dir in
                let step = dir == .increment ? 20.0 : -20.0
                state.prefs.listWidth = min(max(state.prefs.listWidth + step, Preferences.listWidthRange.lowerBound),
                                            maxList)
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
                    .help(L("browser.back.help"))
                    .accessibilityLabel(L("menu.back"))
                Button { state.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!state.history.canGoForward)
                    .help(L("browser.forward.help"))
                    .accessibilityLabel(L("menu.forward"))
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            BreadcrumbView(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.phase == .scanning || !state.rescanQueue.isEmpty {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(state.phase == .scanning ? L("browser.scanRunning") : L("browser.rescanRunning"))
            }
            CompareToolbarButton(state: state)
            let rescan = state.availability(.rescan, targets: [state.focus])
            Menu {
                Button(L("action.rescan")) { state.rescanFocus() }
                    .disabled(!rescan.isEnabled)
                Button(L("menu.fullRescan")) { state.rescan() }
                    .disabled(state.phase == .scanning)
            } label: {
                Label(L("browser.rescan"), systemImage: "arrow.clockwise")
            } primaryAction: {
                state.rescanFocus()
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(state.phase == .scanning)
            .help(rescan.isEnabled ? L("browser.rescan.help") : (rescan.reason ?? ""))
            if state.searchVisible {
                SearchField(state: state)
            }
            Button { state.toggleSearch() } label: { Image(systemName: "magnifyingglass") }
                .help(L("browser.search.help"))
                .accessibilityLabel(L("browser.search"))
                .disabled(state.tree == nil)
            Button { state.backToStart() } label: { Label(L("browser.newScan"), systemImage: "externaldrive") }
                .help(L("browser.newScan.help"))
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
                        .accessibilityLabel(node == state.focus ? L("browser.breadcrumb.current", label(tree, node)) : label(tree, node))
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
            .accessibilityLabel(L("browser.breadcrumb"))
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
                if let b = state.breakdown {
                    if b.systemData > 0 {
                        Text(TextFormat.inlineSeparatorGlyph + " " + L("status.systemData", ByteFormat.string(b.systemData)))
                            .help(L("status.systemData.help"))
                    }
                    VolumeUsageBar(breakdown: b).frame(width: 90, height: 6)
                }
            } else if let p = state.progress {
                Text(TextFormat.inline([filesText(p.filesScanned), ByteFormat.string(p.allocatedBytes)]))
            }
            if state.volume != nil {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(L("status.deviation.help"))
                    .accessibilityLabel(L("status.deviation"))
            }
            Spacer()
            if state.fullDiskAccess == .denied {
                Button { state.openFullDiskAccessSettings() } label: {
                    Label(L("fda.alert.title"), systemImage: "lock.shield")
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
                .help(L("status.fda.help"))
            }
            if let r = state.summary {
                Text(L("status.scanSummary", filesText(r.fileCount), ByteFormat.duration(r.duration)))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .accessibilityElement(children: .contain)
    }

    private func volumeText(_ v: VolumeInfo) -> String {
        var s = L("status.volume", v.name, ByteFormat.string(v.totalCapacity), ByteFormat.string(v.usedCapacity),
                  ByteFormat.string(v.availableCapacity))
        if v.purgeableCapacity > 0 { s += " " + L("status.volume.purgeable", ByteFormat.string(v.purgeableCapacity)) }
        return s
    }
}

/// Zusammenfassung nach dem Scan (SPEC 3.2) mit aufklappbarer Liste der
/// nicht lesbaren Ordner.
struct ScanSummaryBanner: View {
    let state: AppState
    let result: ScanSummary
    @ViewState private var showUnreadable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text(L("summary.finished", filesText(result.fileCount), L("count.folders", result.directoryCount, ByteFormat.count(result.directoryCount)), ByteFormat.string(result.allocatedSize), ByteFormat.duration(result.duration)))
                if !result.unreadablePaths.isEmpty {
                    Button(showUnreadable ? L("summary.less") : L("summary.unreadable", result.unreadablePaths.count, ByteFormat.count(result.unreadablePaths.count))) {
                        showUnreadable.toggle()
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button { state.showSummary = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("summary.close"))
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
                    Button(L("fda.grant")) { state.openFullDiskAccessSettings() }
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
