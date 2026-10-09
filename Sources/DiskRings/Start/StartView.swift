import AppKit
import DiskRingsCore
import SwiftUI

/// Startbildschirm (SPEC 3.1): Volumes mit Belegungsbalken, „Ordner wählen…“,
/// Drag & Drop und Hinweis auf den Festplattenvollzugriff.
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
                        Text("Wähle ein Volume oder einen Ordner, um zu sehen, wo der Platz hingeht.")
                            .foregroundStyle(.secondary)
                    }
                }
                if state.fullDiskAccess == .denied {
                    FullDiskAccessBanner(state: state)
                }
                if let err = state.scanError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Volumes").font(.headline).accessibilityAddTraits(.isHeader)
                VStack(spacing: 8) {
                    ForEach(state.volumes) { v in VolumeRow(volume: v) { state.startScan(v.path) } }
                    if state.volumes.isEmpty {
                        Text("Keine Volumes gefunden.").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button { state.chooseFolder() } label: {
                        Label("Ordner wählen…", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: .command)
                    Button { state.startScan(NSHomeDirectory()) } label: {
                        Label("Home-Ordner scannen", systemImage: "house")
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
                Text("Kein Festplattenvollzugriff").font(.headline)
                Text("Ohne Festplattenvollzugriff bleiben Ordner wie ~/Library/Mail, Safari oder die Container anderer Apps unlesbar. Sie fehlen im Diagramm und landen unter „Nicht zugeordnet“.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Systemeinstellungen öffnen…") { state.openFullDiskAccessSettings() }
                    Button("Erneut prüfen") { state.refreshVolumes() }
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

struct VolumeRow: View {
    let volume: VolumeInfo
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
                        Text("\(ByteFormat.string(volume.usedCapacity)) von \(ByteFormat.string(volume.totalCapacity)) belegt")
                            .font(.system(size: 12).monospacedDigit())
                    }
                    UsageBar(volume: volume).frame(height: 8)
                    HStack(spacing: 12) {
                        legend(Color.accentColor, "Belegt \(ByteFormat.string(volume.usedCapacity - min(volume.purgeableCapacity, volume.usedCapacity)))")
                        if volume.purgeableCapacity > 0 {
                            legend(Color.purgeable, "Bereinigbar \(ByteFormat.string(volume.purgeableCapacity))")
                        }
                        legend(Color.primary.opacity(0.12), "Frei \(ByteFormat.string(volume.availableCapacity))")
                    }
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
        .accessibilityLabel("\(volume.name), \(ByteFormat.string(volume.usedCapacity)) von \(ByteFormat.string(volume.totalCapacity)) belegt, \(ByteFormat.string(volume.availableCapacity)) frei")
        .accessibilityHint("Scannt dieses Volume")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

/// Belegungsbalken: belegt, davon bereinigbar, frei.
struct UsageBar: View {
    let volume: VolumeInfo

    var body: some View {
        GeometryReader { g in
            let total = Double(max(volume.totalCapacity, 1))
            let purge = Double(min(volume.purgeableCapacity, volume.usedCapacity))
            let used = Double(volume.usedCapacity) - purge
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: g.size.width * used / total)
                Rectangle().fill(Color.purgeable).frame(width: g.size.width * purge / total)
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.12))
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

private struct DropHint: View {
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.title2).foregroundStyle(.secondary)
                Text("oder einen Ordner hierher ziehen").foregroundStyle(.secondary)
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
            ScanProgressHeader(state: state)
            Divider()
            if state.tree != nil {
                BrowserBody(state: state, frozenTime: frozenTime)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Ordner werden gelesen…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ScanProgressHeader: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Scanne \(state.scanPath ?? "")")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let p = state.progress {
                    Text("\(filesText(p.filesScanned)) · \(ByteFormat.count(p.directoriesScanned)) Ordner · \(ByteFormat.string(p.allocatedBytes)) · \(ByteFormat.duration(p.elapsed))")
                        .font(.system(size: 12).monospacedDigit())
                    Text(p.currentPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Wird gestartet…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .cancel) { state.cancelScan() } label: { Text("Abbrechen") }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let p = state.progress else { return "Scan wird gestartet" }
        return "Scan läuft: \(filesText(p.filesScanned)), \(ByteFormat.string(p.allocatedBytes))"
    }
}

extension Color {
    /// Farbe für bereinigbaren Speicher im Belegungsbalken und in der Legende;
    /// heller Ton mit genug Kontrast auf hellem und dunklem Hintergrund.
    static let purgeable = Color(nsColor: .systemTeal)
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
