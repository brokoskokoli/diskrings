import DiskRingsCore
import Foundation
import Observation
import SwiftUI
#if Updates
import Sparkle
#endif

/// Dünne Hülle um Sparkle (automatische Updates, nur GitHub-Variante).
///
/// Sparkle ist nur mit dem Package Trait `Updates` eingebunden (Standard).
/// Die App-Store-Variante baut ohne Traits: Dann gibt es hier keinen Updater,
/// `isAvailable` ist immer `false`, Menüpunkt und Einstellungen fehlen. Ob der
/// Updater zur Laufzeit starten darf, entscheidet `UpdateConfiguration` (Core).
/// Die Erlaubnis für automatische Prüfungen fragt Sparkle selbst beim zweiten
/// Start ab (`SUEnableAutomaticChecks` ist absichtlich nicht gesetzt).
@MainActor
@Observable
final class AppUpdater {
    /// Gibt es einen laufenden Updater (Menüpunkt und Einstellungen sichtbar)?
    let isAvailable: Bool
    /// Sparkle meldet, ob gerade eine Prüfung möglich ist (nicht während einer laufenden).
    private(set) var canCheckForUpdates: Bool
    /// Spiegel von `SPUUpdater.automaticallyChecksForUpdates`.
    private(set) var automaticallyChecks: Bool

    #if Updates
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    #endif

    private init(isAvailable: Bool, canCheck: Bool, automaticallyChecks: Bool) {
        self.isAvailable = isAvailable
        self.canCheckForUpdates = canCheck
        self.automaticallyChecks = automaticallyChecks
    }

    /// Updater für die laufende App; einmal pro Prozess erzeugen (`AppDelegate`).
    static func live() -> AppUpdater {
        #if Updates
        // Info.plist-Schlüssel nur hier (unter `#if Updates`), nicht im Core:
        // Die Store-Variante enthält so keine Sparkle-Zeichenketten.
        let info = Bundle.main.infoDictionary
        let availability = UpdateConfiguration.availability(
            feedURL: info?["SUFeedURL"], publicKey: info?["SUPublicEDKey"],
            bundlePath: Bundle.main.bundlePath, environment: .current)
        guard availability.isEnabled else {
            if availability != .disabled(.notAppBundle) {
                // Nur ein Hinweis im Protokoll; die App läuft ohne Updater weiter.
                NSLog("DiskRings: automatic updates disabled (%@)", String(describing: availability))
            }
            return AppUpdater(isAvailable: false, canCheck: false, automaticallyChecks: false)
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        let updater = AppUpdater(isAvailable: true, canCheck: controller.updater.canCheckForUpdates,
                                 automaticallyChecks: controller.updater.automaticallyChecksForUpdates)
        updater.controller = controller
        updater.observeSparkle(controller.updater)
        return updater
        #else
        return AppUpdater(isAvailable: false, canCheck: false, automaticallyChecks: false)
        #endif
    }

    /// Für die Bild-Renderer: sichtbarer Updater ohne Sparkle.
    static func preview(automaticallyChecks: Bool) -> AppUpdater {
        AppUpdater(isAvailable: true, canCheck: true, automaticallyChecks: automaticallyChecks)
    }

    func checkForUpdates() {
        #if Updates
        controller?.checkForUpdates(nil)
        #endif
    }

    func setAutomaticallyChecks(_ on: Bool) {
        automaticallyChecks = on
        #if Updates
        controller?.updater.automaticallyChecksForUpdates = on
        #endif
    }

    #if Updates
    /// KVO auf die Sparkle-Eigenschaften. `SPUUpdater` ist an den MainActor
    /// gebunden; der Wert wird deshalb erst dort gelesen.
    private func observeSparkle(_ updater: SPUUpdater) {
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.syncFromSparkle() }
            },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.syncFromSparkle() }
            },
        ]
    }

    private func syncFromSparkle() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }
    #endif
}

/// Menüpunkt „Nach Updates suchen …“ im App-Menü direkt nach „Über DiskRings“.
struct UpdateCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isAvailable {
                Button(L("menu.checkForUpdates")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

/// Abschnitt „Updates“ im Reiter „Allgemein“ (nur GitHub-Variante).
struct UpdatesSection: View {
    let updater: AppUpdater

    var body: some View {
        Section {
            Toggle(L("settings.updates.automatic"),
                   isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }))
            Button(L("menu.checkForUpdates")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        } header: {
            Text(L("settings.section.updates"))
        } footer: {
            Text(L("settings.updates.footer")).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
