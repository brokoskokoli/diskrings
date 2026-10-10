extension ScanResult {
    /// Öffentlicher Konstruktor (der memberwise-Initialisierer ist intern) für
    /// Bäume ohne echten Scan, z. B. Demo-Bäume in gerenderten Vorschauen und
    /// App-Store-Screenshots. Datei- und Ordneranzahl kommen aus dem Baum.
    public static func make(tree: ScanTree, duration: Double, options: ScanOptions = ScanOptions()) -> ScanResult {
        ScanResult(tree: tree, duration: duration, fileCount: tree.root.fileCount,
                   directoryCount: tree.directoryCount, unreadablePaths: [], skippedMountPoints: [],
                   hardlinkDuplicates: 0, options: options)
    }
}
