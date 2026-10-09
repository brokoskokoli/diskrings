/// Erkennt Pakete (Ordner, die der Finder als eine Datei zeigt) an der Endung.
///
/// Bewusst eine feste Liste statt LaunchServices/UTType: Das ist schnell,
/// deterministisch und ohne AppKit testbar (siehe docs/DECISIONS.md).
public enum PackageDetector {
    public static let extensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "qlgenerator", "mdimporter",
        "prefpane", "saver", "systemextension", "dext", "driver", "component", "vst", "vst3",
        "photoslibrary", "photolibrary", "aplibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "theater", "logicx", "band", "garageband",
        "rtfd", "pages", "numbers", "key", "scriptd", "workflow", "action",
        "xcodeproj", "xcworkspace", "playground", "xcarchive", "docarchive", "xcresult",
        "sparsebundle", "pkg", "mpkg", "lproj_bundle", "nib", "storyboardc", "scnassets",
        "lrlibrary", "lrdata", "cocatalog", "dSYM", "mlmodelc", "dictionary", "wdgt",
    ]

    private static let lowercased: Set<String> = Set(extensions.map { $0.lowercased() })

    public static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return !ext.isEmpty && lowercased.contains(ext.lowercased())
    }

    static func isPackage(nameBytes: UnsafeBufferPointer<UInt8>) -> Bool {
        // Schneller Vorabtest ohne String-Erzeugung: Gibt es überhaupt einen Punkt?
        guard let dot = nameBytes.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < nameBytes.count - 1,
              nameBytes.count - dot <= 17
        else { return false }
        return isPackage(name: String(decoding: nameBytes, as: UTF8.self))
    }
}
