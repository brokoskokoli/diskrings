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
                    Picker(L("compare.listPicker"), selection: Binding(get: { session.tab }, set: { session.tab = $0 })) {
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
        .onChange(of: state.prefs.layoutKey) { _, _ in session.setOptions(state.prefs.layoutOptions()) }
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
                    .help(L("menu.back"))
                    .accessibilityLabel(L("menu.back"))
                Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.history.canGoForward)
                    .help(L("menu.forward"))
                    .accessibilityLabel(L("menu.forward"))
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            CompareBreadcrumb(state: state, session: session)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker(L("compare.viewPicker"), selection: Binding(get: { session.view }, set: { session.view = $0 })) {
                ForEach(CompareViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(L("compare.viewPicker.help"))
            Button { state.endCompare() } label: { Label(L("compare.end"), systemImage: "xmark.circle") }
                .keyboardShortcut(.escape, modifiers: [])
                .help(L("compare.end.help"))
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
        .accessibilityLabel(L("compare.breadcrumb"))
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
            labeledText(h)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Text(session.oldTitle + "  →  " + session.newTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityElement(children: .combine)
    }

    /// „Seit …: belegt +38 GB · frei −38 GB“ mit lokalisiertem Doppelpunkt
    /// und Trennzeichen (`TextFormat`); Präfix und Werte fett.
    private func labeledText(_ h: CompareHeadline) -> Text {
        // Die Vorlage „%1$@: %2$@“ an den Platzhaltern zerlegen, damit die Teile
        // unterschiedlich formatiert werden können.
        let marker = "\u{1}"
        let template = TextFormat.labeled(marker, marker).components(separatedBy: marker)
        let between = template.count == 3 ? template[1] : ": "
        var t = Text(template.first ?? "") + Text(h.prefix + between).fontWeight(.semibold)
        let separator = L("format.inlineSeparator")
        for (i, p) in h.parts.enumerated() {
            if i > 0 { t = t + Text(" " + separator + " ").foregroundColor(.secondary) }
            t = t + Text(p.label + " ") + Text(p.text).fontWeight(.semibold).monospacedDigit()
        }
        return t + Text(template.count == 3 ? template[2] : "")
    }
}

struct CompareWarningBar: View {
    let texts: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(texts, id: \.self) { Text($0) }
                Text(L("compare.warning.footer"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("compare.warning.accessibility", texts.joined(separator: ". ")))
    }
}

// MARK: Legende

struct CompareLegend: View {
    let session: CompareSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.forcedAccessibility) private var forced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || forced.differentiateWithoutColor }

    var body: some View {
        let palette = Palette(appearance: PaletteAppearance(colorScheme))
        VStack(alignment: .leading, spacing: 5) {
            switch session.view {
            case .growth:
                Text(L("compare.legend.growth", CompareHeadline.shortDate(session.diff.summary.oldDate)))
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(palette.unchangedFill)).frame(width: 14, height: 10)
                        .overlay(Circle().fill(Color(palette.label(on: palette.unchangedFill))).frame(width: 5, height: 5))
                    Text(L("diff.added")).font(.subheadline)
                }
            case .delta:
                HStack(spacing: 6) {
                    gradient(palette, .grown)
                    Text(L("diff.grown"))
                    gradient(palette, .shrunk)
                    Text(L("diff.shrunk"))
                }
                .font(.subheadline)
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        marker(palette)
                        Text(L("diff.added"))
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(palette.removedFill))
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color(palette.removedStroke), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .frame(width: 14, height: 10)
                        Text(L("diff.removed"))
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(palette.unchangedFill)).frame(width: 14, height: 10)
                        Text(L("diff.unchanged"))
                    }
                }
                .font(.subheadline)
                Text(L("compare.legend.intensity")).font(.caption).foregroundStyle(.secondary)
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
            .frame(width: 44, height: differentiateWithoutColor ? 14 : 10)
            .overlay {
                if differentiateWithoutColor, let mark = Palette.deltaMark(for: s) {
                    Text(mark).font(.caption.weight(.bold))
                        .foregroundStyle(Color(p.label(on: p.deltaColor(status: s, intensity: 1))))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func marker(_ p: Palette) -> some View {
        let fill = p.deltaColor(status: .added, intensity: 1)
        return RoundedRectangle(cornerRadius: 2).fill(Color(fill)).frame(width: 14, height: 10)
            .overlay(Circle().fill(Color(p.addedMarker(on: fill))).frame(width: 5, height: 5))
    }
}

// MARK: Hilfen

/// Farbe für Δ-Werte in Liste und Tooltip: Orange gewachsen, Blau
/// geschrumpft (`Palette.deltaTextColor`, lesbar und farbenblind-tauglich),
/// passend zum Hell- oder Dunkelmodus.
func deltaTextColor(_ d: Int64) -> Color {
    if d == 0 { return .secondary }
    return Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let c = Palette(appearance: dark ? .dark : .light).deltaTextColor(d)
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    })
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
    case .added, .grown: deltaTextColor(1)
    case .shrunk: deltaTextColor(-1)
    case .removed, .unchanged: .secondary
    }
}
