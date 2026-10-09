extension ScanProgress {
    /// Öffentlicher Konstruktor (der memberwise-Initialisierer ist intern),
    /// z. B. für gerenderte Vorschauen der Scan-Ansicht.
    public static func make(
        filesScanned: Int, directoriesScanned: Int, allocatedBytes: UInt64, currentPath: String, elapsed: Double
    ) -> ScanProgress {
        ScanProgress(filesScanned: filesScanned, directoriesScanned: directoriesScanned,
                     allocatedBytes: allocatedBytes, currentPath: currentPath, elapsed: elapsed)
    }
}
