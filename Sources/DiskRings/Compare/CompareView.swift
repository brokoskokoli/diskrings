import AppKit
import DiskRingsCore
import SwiftUI

/// Ersetzt die Hauptansicht durch den Vergleichsmodus, solange einer aktiv
/// ist (einziger Haken in `BrowserView`).
struct CompareModeSwitch: ViewModifier {
    let state: AppState
    var frozenTime: Date?

    func body(content: Content) -> some View {
        if let session = state.compare {
            CompareView(state: state, session: session)
        } else {
            content
        }
    }
}

/// Vergleichsmodus (SPEC 3.9): Leiste mit Navigation, Ansichtsumschalter und
/// „Vergleich beenden“, Kopfzeile mit den Deltas, Warnungen, links der
/// Sunburst („Wachstum“ oder „Delta-Färbung“), rechts die Liste mit Vorher,
/// Jetzt und Δ bzw. „Größte Veränderungen“.
struct CompareView: View {
    let state: AppState
    let session: CompareSession

    static let listWidth: CGFloat = 470

    var body: some View {
        VStack(spacing: 0) {
            CompareToolbar(state: state, session: session)
            Divider()
            CompareHeadlineBar(session: session)
            if !session.model.warningTexts.isEmpty {
                Divider()
                CompareWarningBar(texts: session.model.warningTexts)
            }
            Divider()
            HStack(spacing: 0) {
                CompareSunburstView(state: state, session: session)
                    .padding(16)
                    .overlay(alignment: .bottomLeading) {
                        CompareLegend(session: session).padding(12)
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    Picker("Liste", selection: Binding(get: { session.tab }, set: { session.tab = $0 })) {
                        ForEach(CompareSession.Tab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                    switch session.tab {
                    case .contents: CompareListView(state: state, session: session)
                    case .largest: LargestChangesView(state: state, session: session)
                    }
                }
                .frame(width: Self.listWidth)
                .frame(maxHeight: .infinity)
            }
            Divider()
            StatusBar(state: state)
        }
        .onChange(of: state.prefs.layoutKey) { _, _ in session.setOptions(state.prefs.layoutOptions(unassigned: 0)) }
    }
}

// MARK: Leiste

struct CompareToolbar: View {
    let state: AppState
    let session: CompareSession

    var body: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.history.canGoBack)
                    .help("Zurück")
                    .accessibilityLabel("Zurück")
                Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.history.canGoForward)
                    .help("Vor")
                    .accessibilityLabel("Vor")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            CompareBreadcrumb(state: state, session: session)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Darstellung", selection: Binding(get: { session.view }, set: { session.view = $0 })) {
                ForEach(CompareViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Wachstum: Segmentgröße = Zuwachs. Delta-Färbung: normale Größen, rot gewachsen, grün geschrumpft.")
            Button { state.endCompare() } label: { Label("Vergleich beenden", systemImage: "xmark.circle") }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Zurück zur normalen Ansicht (Esc)")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Breadcrumb über die Vergleichseinträge.
struct CompareBreadcrumb: View {
    let state: AppState
    let session: CompareSession

    var body: some View {
        let model = session.model
        let path = model.ancestors(of: session.focus)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.secondary).padding(.trailing, 2)
                    .accessibilityHidden(true)
                ForEach(Array(path.enumerated()), id: \.element) { i, e in
                    if i > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button { session.navigate(to: e) } label: {
                        Text(i == 0 ? rootLabel : model.diff.name(of: e))
                            .lineLimit(1)
                            .fontWeight(e == session.focus ? .semibold : .regular)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 13))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pfad im Vergleich")
    }

    private var rootLabel: String {
        let root = session.model.diff.new.metadata
        if let v = root.volume, root.volume?.unassigned != nil { return v.name }
        return root.rootPath
    }
}

// MARK: Kopfzeile und Warnung

struct CompareHeadlineBar: View {
    let session: CompareSession

    var body: some View {
        let h = session.headline
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary).accessibilityHidden(true)
            (Text(h.prefix + ": ").fontWeight(.semibold) + partsText(h))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Text("\(session.oldTitle)  →  \(session.newTitle)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityElement(children: .combine)
    }

    private func partsText(_ h: CompareHeadline) -> Text {
        var t = Text("")
        for (i, p) in h.parts.enumerated() {
            if i > 0 { t = t + Text("  ·  ").foregroundColor(.secondary) }
            t = t + Text(p.label + " ") + Text(p.text).fontWeight(.semibold).monospacedDigit()
        }
        return t
    }
}

struct CompareWarningBar: View {
    let texts: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(texts, id: \.self) { Text($0) }
                Text("Unterschiede können deshalb auch von den Einstellungen kommen.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warnung: " + texts.joined(separator: ". "))
    }
}

// MARK: Legende

struct CompareLegend: View {
    let session: CompareSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette(appearance: PaletteAppearance(colorScheme))
        VStack(alignment: .leading, spacing: 5) {
            switch session.view {
            case .growth:
                Text("Segmentgröße = Zuwachs seit \(CompareHeadline.shortDate(session.diff.summary.oldDate))")
                    .font(.system(size: 11, weight: .medium))
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(palette.unchangedFill)).frame(width: 14, height: 10)
                        .overlay(Circle().fill(Color(palette.label(on: palette.unchangedFill))).frame(width: 5, height: 5))
                    Text("neu").font(.system(size: 11))
                }
            case .delta:
                HStack(spacing: 6) {
                    gradient(palette, .grown)
                    Text("gewachsen").font(.system(size: 11))
                    gradient(palette, .shrunk)
                    Text("geschrumpft").font(.system(size: 11))
                }
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        marker(palette)
                        Text("neu")
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(palette.removedFill))
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color(palette.removedStroke), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .frame(width: 14, height: 10)
                        Text("entfernt")
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(palette.unchangedFill)).frame(width: 14, height: 10)
                        Text("unverändert")
                    }
                }
                .font(.system(size: 11))
                Text("Kräftiger = größere Änderung").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func gradient(_ p: Palette, _ s: DiffStatus) -> some View {
        LinearGradient(colors: p.deltaLegendStops(status: s, count: 5).map { Color($0) }, startPoint: .leading,
                       endPoint: .trailing)
            .frame(width: 44, height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func marker(_ p: Palette) -> some View {
        let fill = p.deltaColor(status: .added, intensity: 1)
        return RoundedRectangle(cornerRadius: 2).fill(Color(fill)).frame(width: 14, height: 10)
            .overlay(Circle().fill(Color(p.addedMarker(on: fill))).frame(width: 5, height: 5))
    }
}

// MARK: Hilfen

/// Farbe für Δ-Werte in Liste und Tooltip.
func deltaTextColor(_ d: Int64) -> Color {
    d > 0 ? Color(nsColor: .systemRed) : (d < 0 ? Color(nsColor: .systemGreen) : .secondary)
}

/// SF-Symbol je Status.
func statusSymbol(_ s: DiffStatus) -> String {
    switch s {
    case .added: "plus.circle.fill"
    case .removed: "xmark.circle"
    case .grown: "arrow.up.circle"
    case .shrunk: "arrow.down.circle"
    case .unchanged: "equal.circle"
    }
}

func statusColor(_ s: DiffStatus) -> Color {
    switch s {
    case .added, .grown: Color(nsColor: .systemRed)
    case .shrunk: Color(nsColor: .systemGreen)
    case .removed, .unchanged: .secondary
    }
}
