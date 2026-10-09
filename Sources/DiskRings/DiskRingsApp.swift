import DiskRingsCore
import SwiftUI

/// Platzhalter-App für M1: ein Fenster mit Hinweistext. Die eigentliche
/// Oberfläche folgt ab M2.
@main
struct DiskRingsApp: App {
    var body: some Scene {
        WindowGroup("DiskRings") {
            PlaceholderView()
        }
    }
}

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("DiskRings")
                .font(.title)
            Text("Die Scan-Engine ist bereit. Die Oberfläche folgt in Meilenstein 2.")
                .foregroundStyle(.secondary)
            Text("Zum Testen: diskrings-cli scan <Pfad>")
                .font(.callout.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}
