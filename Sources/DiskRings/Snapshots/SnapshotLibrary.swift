import AppKit
import DiskRingsCore
import Foundation
import Observation

/// Snapshot-Einstellungen (SPEC 3.7), gespeichert in den UserDefaults.
@MainActor
@Observable
final class SnapshotPreferences {
    private enum Key {
        static let autoSave = "snapshotAutoSave"
        static let maxCount = "snapshotMaxCount"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Key.autoSave) } }
    var maxCount: Int {
        didSet {
            let c = SnapshotRetention(maxCount: maxCount).maxCount
            if c != maxCount { maxCount = c }
            defaults.set(maxCount, forKey: Key.maxCount)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let standard = SnapshotRetention()
        autoSave = defaults.object(forKey: Key.autoSave) as? Bool ?? standard.autoSave
        maxCount = SnapshotRetention(maxCount: defaults.object(forKey: Key.maxCount) as? Int ?? standard.maxCount).maxCount
    }

    var retention: SnapshotRetention { SnapshotRetention(autoSave: autoSave, maxCount: maxCount) }
}

/// Verwaltung der gespeicherten Snapshots für die Oberfläche (SPEC 3.9):
/// Liste, automatisches und manuelles Speichern, Umbenennen, Löschen.
/// Gespeichert und geladen wird im Hintergrund; beim Anlegen findet kein
/// Dateizugriff statt (die Ablage ist für die Vorschaubilder austauschbar).
@MainActor
@Observable
final class SnapshotLibrary {
    let store: SnapshotStore
    private(set) var infos: [SnapshotInfo] = []
    /// Dateien in der Ablage, die sich nicht lesen lassen (abgeschnitten,
    /// beschädigt); im Fenster „Snapshots“ als „beschädigt“ gezeigt.
    private(set) var damaged: [DamagedSnapshot] = []
    /// Zeitpunkt, zu dem der aktuelle Scan fertig wurde. Snapshots ab diesem
    /// Zeitpunkt zeigen denselben Stand und werden nicht zum Vergleich angeboten.
    private(set) var currentScanDate: Date?
    /// Letzter Fehler (Speichern, Laden, Umbenennen, Löschen).
    var errorMessage: String?
    /// Kurze Rückmeldung („Snapshot gesichert“).
    var notice: String?
    /// Laufende Arbeit, z. B. „Vergleich wird berechnet…“.
    var busy: String?
    /// Dialog „Snapshot sichern“ (⌘S) anzeigen.
    var showSavePrompt = false

    init(store: SnapshotStore = SnapshotStore()) {
        self.store = store
    }

    func refresh() {
        do {
            (infos, damaged) = try store.listAll()
        } catch {
            errorMessage = "Snapshots konnten nicht gelesen werden: \(error)"
        }
    }

    /// Passende Snapshots für „Vergleichen mit…“ (gleiches Volume, gleiche Wurzel).
    func candidates(rootPath: String, volumeUUID: String?) -> [SnapshotInfo] {
        SnapshotMatching.candidates(infos, rootPath: rootPath, volumeUUID: volumeUUID, before: currentScanDate)
    }

    // MARK: Speichern

    /// Nach jedem vollständigen Scan: Zeitpunkt merken und, falls
    /// eingeschaltet, automatisch speichern und aufräumen.
    func didFinishScan(_ result: ScanResult, volume: VolumeInfo?, retention: SnapshotRetention) {
        let date = Date()
        markCurrentScan(date)
        guard retention.autoSave else { return }
        let store = store
        let meta = SnapshotMetadata.current(for: result, volume: volume, date: date)
        save(tree: result.tree, metadata: meta, retention: retention, announce: false, store: store)
    }

    func markCurrentScan(_ date: Date) {
        currentScanDate = date
    }

    /// „Ablage → Snapshot sichern“ (⌘S) mit optionalem Namen.
    func saveCurrent(state: AppState, name: String?) {
        guard let tree = state.tree, let result = state.result else { return }
        var meta = SnapshotMetadata.current(for: result, volume: state.volume, name: SnapshotNaming.normalized(name))
        // Der Baum kann sich seit dem Scan geändert haben (Papierkorb, Teil-Rescan).
        meta.allocatedSize = tree.root.allocatedSize
        meta.logicalSize = tree.root.logicalSize
        save(tree: tree, metadata: meta, retention: state.prefs.snapshots.retention, announce: true, store: store)
    }

    private func save(tree: ScanTree, metadata: SnapshotMetadata, retention: SnapshotRetention, announce: Bool,
                      store: SnapshotStore) {
        Task {
            do {
                let out = try await Task.detached(priority: .utility) {
                    try store.saveAndPrune(tree, metadata: metadata, retention: retention)
                }.value
                refresh()
                if announce {
                    showNotice("Snapshot „\(SnapshotNaming.title(out.saved.metadata))“ gesichert")
                }
            } catch {
                errorMessage = "Snapshot konnte nicht gespeichert werden: \(error)"
            }
        }
    }

    func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = nil }
        }
    }

    // MARK: Verwalten

    /// Umbenennen im Hintergrund: Es wird nur der Kopf der Datei neu
    /// geschrieben, die Datei aber trotzdem einmal kopiert (atomar ersetzt).
    func rename(_ info: SnapshotInfo, to name: String?) {
        let store = store
        let newName = SnapshotNaming.normalized(name)
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try store.rename(info, to: newName)
                }.value
            } catch {
                errorMessage = "Umbenennen fehlgeschlagen: \(error)"
            }
            refresh()
        }
    }

    /// Löscht beschädigte Dateien (nur innerhalb der Ablage).
    func deleteDamaged(_ items: [DamagedSnapshot]) {
        for d in items {
            do {
                try store.delete(d)
            } catch {
                errorMessage = "Löschen fehlgeschlagen: \(error)"
            }
        }
        refresh()
    }

    /// Löscht die Snapshot-Datei (nur innerhalb der Ablage; die Bestätigung
    /// holt die Oberfläche vorher ein).
    func delete(_ infos: [SnapshotInfo]) {
        for info in infos {
            do {
                try store.delete(info)
            } catch {
                errorMessage = "Löschen fehlgeschlagen: \(error)"
            }
        }
        refresh()
    }

    func revealInFinder(_ infos: [SnapshotInfo]) {
        NSWorkspace.shared.activateFileViewerSelecting(infos.map(\.url))
    }
}
