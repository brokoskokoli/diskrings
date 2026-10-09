/// Steuert genau einen laufenden Scan für die Oberfläche und reicht dessen
/// Ereignisse auf dem Main Actor weiter.
///
/// Ein neuer `start` oder `cancel` beendet den vorigen Scan. Dessen Ereignisse,
/// die noch im Stream gepuffert sind, werden verworfen: Jeder Scan bekommt eine
/// Generationsnummer, und die Schleife prüft vor jeder Weitergabe (und im
/// Fehlerfall) `Task.isCancelled` und ob ihre Generation noch aktuell ist.
@MainActor
public final class ScanController {
    public enum Event: Sendable {
        case progress(ScanProgress)
        case snapshot(ScanTree)
        case finished(ScanResult)
        case failed(any Error)
    }

    /// Liefert den Ereignis-Stream eines Scans (austauschbar für Tests).
    public typealias StreamFactory = @Sendable (_ path: String, _ options: ScanOptions, _ includeSnapshots: Bool)
        -> AsyncThrowingStream<ScanEvent, Error>

    public var handler: @MainActor (Event) -> Void
    private let makeStream: StreamFactory
    public private(set) var isRunning = false
    /// Generation des aktuellen Scans (steigt bei jedem `start` und `cancel`).
    public private(set) var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    public init(
        handler: @escaping @MainActor (Event) -> Void = { _ in },
        makeStream: @escaping StreamFactory = { path, options, snapshots in
            ScanEngine(options: options).events(path, includeSnapshots: snapshots)
        }
    ) {
        self.handler = handler
        self.makeStream = makeStream
    }

    public func start(_ path: String, options: ScanOptions = ScanOptions(), includeSnapshots: Bool = true) {
        cancel()
        let id = generation
        isRunning = true
        let stream = makeStream(path, options, includeSnapshots)
        task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled, let self, self.generation == id else { return }
                    switch event {
                    case .progress(let p): self.handler(.progress(p))
                    case .snapshot(let t): self.handler(.snapshot(t))
                    case .finished(let r):
                        self.isRunning = false
                        self.task = nil
                        self.handler(.finished(r))
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == id, !(error is CancellationError) else { return }
                self.isRunning = false
                self.task = nil
                self.handler(.failed(error))
            }
        }
    }

    /// Bricht den laufenden Scan ab; danach kommen keine Ereignisse mehr von ihm.
    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isRunning = false
    }
}
