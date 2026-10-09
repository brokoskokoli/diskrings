import DiskRingsCore
import Foundation
import Observation

/// Einstellungen (SPEC 3.7), gespeichert in den UserDefaults.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let rings = "ringCount"
        static let scheme = "paletteScheme"
        static let minAngle = "minAngleDegrees"
        static let sizeMode = "sizeMode"
        static let hidden = "includeHidden"
        static let crossMounts = "crossMountPoints"
        static let excluded = "excludedPaths"
        static let labels = "showLabels"
        static let skipTrash = "skipTrashConfirmation"
        static let listWidth = "listWidth"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var ringCount: Int { didSet { defaults.set(ringCount, forKey: Key.rings) } }
    var paletteScheme: PaletteScheme { didSet { defaults.set(paletteScheme.rawValue, forKey: Key.scheme) } }
    var minAngleDegrees: Double { didSet { defaults.set(minAngleDegrees, forKey: Key.minAngle) } }
    var sizeMode: SizeMode { didSet { defaults.set(sizeMode.rawValue, forKey: Key.sizeMode) } }
    var includeHidden: Bool { didSet { defaults.set(includeHidden, forKey: Key.hidden) } }
    var crossMountPoints: Bool { didSet { defaults.set(crossMountPoints, forKey: Key.crossMounts) } }
    var excludedPaths: [String] { didSet { defaults.set(excludedPaths, forKey: Key.excluded) } }
    var showLabels: Bool { didSet { defaults.set(showLabels, forKey: Key.labels) } }
    /// „Nicht mehr fragen“ im Papierkorb-Dialog (gilt nur unter 1 GB, SPEC 3.6).
    var skipTrashConfirmation: Bool { didSet { defaults.set(skipTrashConfirmation, forKey: Key.skipTrash) } }
    /// Breite der Detailliste in Punkt (verstellbar über den Teiler).
    var listWidth: Double { didSet { defaults.set(listWidth, forKey: Key.listWidth) } }
    static let listWidthRange: ClosedRange<Double> = 300 ... 720

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rings = defaults.object(forKey: Key.rings) as? Int ?? SunburstOptions.defaultRings
        ringCount = SunburstOptions.ringRange.contains(rings) ? rings : SunburstOptions.defaultRings
        paletteScheme = defaults.string(forKey: Key.scheme).flatMap(PaletteScheme.init(rawValue:)) ?? .branch
        let angle = defaults.object(forKey: Key.minAngle) as? Double ?? SunburstOptions.defaultMinAngleDegrees
        minAngleDegrees = Self.minAngleRange.contains(angle) ? angle : SunburstOptions.defaultMinAngleDegrees
        sizeMode = defaults.string(forKey: Key.sizeMode).flatMap(SizeMode.init(rawValue:)) ?? .allocated
        includeHidden = defaults.object(forKey: Key.hidden) as? Bool ?? true
        crossMountPoints = defaults.object(forKey: Key.crossMounts) as? Bool ?? false
        excludedPaths = defaults.stringArray(forKey: Key.excluded) ?? []
        showLabels = defaults.object(forKey: Key.labels) as? Bool ?? true
        skipTrashConfirmation = defaults.object(forKey: Key.skipTrash) as? Bool ?? false
        let w = defaults.object(forKey: Key.listWidth) as? Double ?? 400
        listWidth = Self.listWidthRange.contains(w) ? w : 400
    }

    /// Erlaubter Bereich der Winkelschwelle in Grad.
    static let minAngleRange: ClosedRange<Double> = 0.1 ... 3

    var scanOptions: ScanOptions {
        ScanOptions(includeHidden: includeHidden, excludedPaths: excludedPaths, crossMountPoints: crossMountPoints)
    }

    func layoutOptions(unassigned: UInt64) -> SunburstOptions {
        SunburstOptions(maxRings: ringCount, minAngleDegrees: minAngleDegrees, sizeMode: sizeMode,
                        unassigned: sizeMode == .allocated ? unassigned : 0)
    }

    /// Alles, was das Layout beeinflusst (für `onChange`).
    var layoutKey: String { "\(ringCount)|\(minAngleDegrees)|\(sizeMode.rawValue)" }
}
