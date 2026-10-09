import AppKit
import DiskRingsCore

/// Trackpad-Wischgesten für Zurück/Vor (SPEC 3.4); im Vergleichsmodus im Vergleich.
///
/// - Zwei-Finger-Wischen (horizontales Scrollen mit Phase, wenn in den
///   Systemeinstellungen „Zwischen Seiten blättern“ aktiv ist) wird mit
///   `trackSwipeEvent` verfolgt, wie in Safari.
/// - Drei-Finger-Wischen kommt als `NSEvent.swipe`.
/// Richtung wie in Safari: Finger nach rechts = zurück, nach links = vor.
@MainActor
final class SwipeNavigation {
    private var monitor: Any?
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// `true`, wenn das Ereignis verbraucht wurde.
    private func handle(_ event: NSEvent) -> Bool {
        guard let state, state.phase == .browsing else { return false }
        switch event.type {
        case .swipe:
            // deltaX > 0: Wischen nach rechts (wie Safari: zurück).
            if event.deltaX > 0, state.canNavigateBack {
                state.navigateBack()
                return true
            }
            if event.deltaX < 0, state.canNavigateForward {
                state.navigateForward()
                return true
            }
            return false
        case .scrollWheel:
            guard event.phase == .began, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2 else { return false }
            let canBack = state.canNavigateBack, canForward = state.canNavigateForward
            guard canBack || canForward else { return false }
            var done = false
            event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                                  dampenAmountThresholdMin: canForward ? -1 : 0,
                                  max: canBack ? 1 : 0) { [weak state] amount, phase, isComplete, _ in
                guard !done, phase == .ended, isComplete else { return }
                done = true
                MainActor.assumeIsolated {
                    if amount > 0 { state?.navigateBack() } else if amount < 0 { state?.navigateForward() }
                }
            }
            return true
        default:
            return false
        }
    }
}
