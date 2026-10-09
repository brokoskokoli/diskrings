import Foundation

/// Suche nach Namen im aktuellen Baum (Suchknopf der Skizze 3.3).
///
/// Teilzeichenfolge, ohne Rücksicht auf Groß-/Kleinschreibung und Akzente
/// („muller“ findet „Müller“). Treffer sind nach Größe absteigend sortiert.
/// Lineare Suche über den Teilbaum; für reine ASCII-Suchbegriffe ohne
/// String-Bildung pro Knoten (2 Mio. Knoten in rund einer Zehntelsekunde im
/// Release-Build).
public enum TreeSearch {
    public struct Result: Sendable, Equatable {
        /// Treffer, größte zuerst, höchstens `limit`.
        public var matches: [Int32]
        /// Gesamtzahl der Treffer.
        public var total: Int

        public init(matches: [Int32], total: Int) {
            self.matches = matches
            self.total = total
        }
    }

    public static func search(_ query: String, in tree: ScanTree, under start: Int32 = ScanTree.rootIndex,
                              sizeMode: SizeMode = .allocated, limit: Int = 200,
                              isCancelled: () -> Bool = { false }) -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Result(matches: [], total: 0) }
        let folded = fold(q)
        let asciiNeedle: [UInt8]? = folded.utf8.allSatisfy { $0 < 0x80 } ? Array(folded.utf8) : nil
        var hits: [Int32] = []
        var stack: [Int32] = [start]
        var visited = 0
        while let i = stack.popLast() {
            visited += 1
            if visited & 0xFFFF == 0, isCancelled() { break }
            let range = tree.childIndices(of: i)
            for c in range {
                if matches(tree.nameBytes(of: c), asciiNeedle: asciiNeedle, folded: folded) { hits.append(c) }
                if tree.nodes[Int(c)].childCount > 0 { stack.append(c) }
            }
        }
        let total = hits.count
        hits.sort { a, b in
            let sa = tree.nodes[Int(a)].size(sizeMode), sb = tree.nodes[Int(b)].size(sizeMode)
            return sa != sb ? sa > sb : a < b
        }
        if hits.count > limit { hits.removeSubrange(limit...) }
        return Result(matches: hits, total: total)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    static func matches(_ name: ArraySlice<UInt8>, asciiNeedle: [UInt8]?, folded: String) -> Bool {
        if let needle = asciiNeedle {
            // Reine ASCII-Namen bytewise vergleichen; Namen mit Nicht-ASCII-
            // Zeichen (Umlaute, NFD) über die Faltung, damit „u“ auch „ü“ findet.
            if name.allSatisfy({ $0 < 0x80 }) { return asciiContains(name, needle) }
        }
        return fold(String(decoding: name, as: UTF8.self)).contains(folded)
    }

    static func asciiContains(_ hay: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard n <= hay.count else { return false }
        let base = hay.startIndex
        var i = 0
        let last = hay.count - n
        while i <= last {
            var k = 0
            while k < n {
                var b = hay[base + i + k]
                if b >= 0x41 && b <= 0x5A { b |= 0x20 }
                if b != needle[k] { break }
                k += 1
            }
            if k == n { return true }
            i += 1
        }
        return false
    }
}
