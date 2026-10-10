import AppKit
import DiskRingsCore
import SwiftUI

/// Startbildschirm (SPEC 3.1): Volumes mit Belegungsbalken, „Ordner wählen…“,
/// Drag & Drop und Hinweis auf den Festplattenvollzugriff (in der Sandbox
/// stattdessen auf die Ordnerfreigaben).
struct StartView: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: AppIcon.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DiskRings").font(.largeTitle.weight(.semibold))
                        Text(L("start.subtitle"))
                            .foregroundStyle(.secondary)
                    }
                }
                if state.isSandboxed {
                    SandboxAccessBanner(state: state)
                } else if state.fullDiskAccess == .denied {
                    FullDiskAccessBanner(state: state)
                }
                if let err = state.scanError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(L("start.volumes")).font(.headline).accessibilityAddTraits(.isHeader)
                VStack(spacing: 8) {
                    ForEach(state.volumes) { v in
                        VolumeRow(volume: v, breakdown: state.estimatedBreakdown(for: v)) { state.requestScan(v.path) }
                    }
                    if state.volumes.isEmpty {
                        Text(L("start.noVolumes")).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button { state.chooseFolder() } label: {
                        Label(L("menu.chooseFolder"), systemImage: "folder.badge.plus")
                    }
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: .command)
                    // Echter Home-Ordner (in der Sandbox nicht der Container).
                    Button { state.requestScan(state.environment.homeDirectory) } label: {
                        Label(L("start.scanHome"), systemImage: "house")
                    }
                    .controlSize(.large)
                    Spacer()
                }
                DropHint()
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

struct FullDiskAccessBanner: View {
    let state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("fda.alert.title")).font(.headline)
                Text(L("start.fda.message"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("start.fda.openSettings")) { state.openFullDiskAccessSettings() }
                    Button(L("start.fda.checkAgain")) { state.refreshVolumes() }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Hinweis der App-Store-Variante: DiskRings liest nur freigegebene Ordner.
struct SandboxAccessBanner: View {
    let state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.badge.person.crop")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("sandbox.banner.title")).font(.headline)
                Text(L("sandbox.banner.message"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("sandbox.grantMore")) { state.grantMoreFolders() }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

struct VolumeRow: View {
    let volume: VolumeInfo
    /// Aufteilung für Balken und Legende (ohne Scan geschätzt).
    let breakdown: VolumeBreakdown
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(nsImage: Volumes.icon(for: volume.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(volume.name).font(.system(size: 14, weight: .semibold))
                        Text(volume.path).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(L("start.volume.used", ByteFormat.string(volume.usedCapacity), ByteFormat.string(volume.totalCapacity)))
                            .font(.system(size: 12).monospacedDigit())
                    }
                    VolumeUsageBar(breakdown: breakdown).frame(height: 8)
                    VolumeUsageLegend(breakdown: breakdown)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(L("start.volume.accessibility", volume.name, ByteFormat.string(volume.usedCapacity), ByteFormat.string(volume.totalCapacity), ByteFormat.string(volume.availableCapacity)))
        .accessibilityHint(L("start.volume.hint"))
    }
}

private struct DropHint: View {
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.title2).foregroundStyle(.secondary)
                Text(L("start.dropHint")).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.tertiary)
        )
        .accessibilityHidden(true)
    }
}

/// Scan-Ansicht (SPEC 3.2): Fortschritt, Abbrechen und das sich live
/// aufbauende Diagramm aus den Snapshots der Engine.
struct ScanningView: View {
    let state: AppState
    var frozenTime: Date?

    var body: some View {
        VStack(spacing: 0) {
            // In den Vorschaubildern (frozenTime) ohne TimelineView, mit fester Uhrzeit.
            ScanProgressHeader(state: state, now: frozenTime == nil ? nil : Date())
            Divider()
            if state.tree != nil {
                BrowserBody(state: state, frozenTime: frozenTime)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(L("scan.reading")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ScanProgressHeader: View {
    let state: AppState
    /// Feste Uhrzeit für die Vorschaubilder (sonst die aktuelle).
    var now: Date?

    var body: some View {
        if let now {
            content(now: now)
        } else {
            // Einmal pro Sekunde prüfen, ob der Scan stillsteht (die Engine
            // meldet zwar alle 250 ms, aber nicht, wenn sie selbst hängt).
            TimelineView(.periodic(from: .now, by: 1)) { context in content(now: context.date) }
        }
    }

    private func content(now: Date) -> some View {
        VStack(spacing: 0) {
            header
            if state.isScanStalled(at: now) {
                Divider()
                StallHint(state: state)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("scan.title", state.scanPath ?? ""))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let p = state.progress {
                    Text(TextFormat.inline([filesText(p.filesScanned), L("count.folders", p.directoriesScanned, ByteFormat.count(p.directoriesScanned)), ByteFormat.string(p.allocatedBytes), ByteFormat.duration(p.elapsed)]))
                        .font(.system(size: 12).monospacedDigit())
                    Text(p.currentPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(L("scan.starting")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .cancel) { state.cancelScan() } label: { Text(L("common.cancel")) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let p = state.progress else { return L("scan.accessibility.starting") }
        return L("scan.accessibility.running", filesText(p.filesScanned), ByteFormat.string(p.allocatedBytes))
    }
}

/// Hinweis, wenn sich der Scan seit über 3 s nicht bewegt: Meist wartet ein
/// Datenschutz-Dialog von macOS (Schreibtisch, Dokumente, Downloads,
/// Wechsel- oder Netzlaufwerk) auf eine Antwort.
struct StallHint: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("scan.stalled.title"))
                    .font(.system(size: 12, weight: .semibold))
                Text(L("scan.stalled.message"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // In der Sandbox hilft der Festplattenvollzugriff nicht.
            if !state.isSandboxed {
                Button(L("scan.stalled.fda")) { state.openFullDiskAccessSettings() }
                    .buttonStyle(.link)
                    .help(L("scan.stalled.fda.help"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .combine)
    }
}

/// App-Icon für den Startbildschirm: aus dem Bündel (`NSApp.applicationIconImage`);
/// bei `swift run` und in den Vorschaubildern gibt es kein Bündel-Icon, dann
/// wird `Resources/DiskRings.icns` aus dem Quellbaum geladen.
@MainActor
enum AppIcon {
    static let image: NSImage = {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil, let app = NSApp {
            return app.applicationIconImage
        }
        // …/Sources/DiskRings/Start/StartView.swift → …/Resources/DiskRings.icns
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if let icns = NSImage(contentsOf: root.appendingPathComponent("Resources/DiskRings.icns")) { return icns }
        return NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }()
}
