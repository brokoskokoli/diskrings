# DiskRings – Arbeitsregeln

Die Spezifikation steht in `SPEC.md` und ist verbindlich. Wenn du von ihr abweichen musst, notiere die Abweichung mit Begründung in `docs/DECISIONS.md`.

## Struktur (Swift Package, kein Xcode-Projekt)
- `Sources/DiskRingsCore`: die gesamte Logik ohne UI: Scanner, Modell, Sunburst-Layout-Mathematik, Hit-Test, Snapshots/Diff, ProtectedPaths, Formatierung. Hier darf **kein** SwiftUI-Import stehen.
- `Sources/DiskRings`: SwiftUI/AppKit-App. Sie bleibt dünn, alle testbare Logik gehört nach Core.
- `Sources/diskrings-cli`: Kommandozeilen-Werkzeug (Scan, Top-Ordner, Snapshot, Diff) für Tests und Debugging.
- `Tests/DiskRingsCoreTests`: Unit- und Integrationstests mit temporären Fixture-Bäumen.
- `scripts/`: `make-app.sh` (Bundle und Signatur), `release.sh` (Notarisierung), `check.sh` (Build und alle Tests).
- Mindest-OS macOS 14, Swift 6 im Strict-Concurrency-Modus.

## Arbeitsweise
- Testgetrieben: Zuerst den Test schreiben, dann den Code. Jede Funktion aus der Spec bekommt Tests, Fehlerfälle eingeschlossen (Hardlinks, Symlink-Zyklen, unlesbare Ordner, Sparse-Dateien, leere Ordner, Unicode-Namen).
- Vor jedem Commit muss `scripts/check.sh` grün sein (`swift build` und `swift test`, keine Warnungen in eigenem Code).
- UI-Views, wo möglich, über `ImageRenderer` in Tests als PNG nach `build/snapshots/` rendern, damit man sie visuell prüfen kann.
- Kleine, thematische Commits auf `main`; Commit-Nachrichten auf Deutsch, mit den Attribution-Zeilen aus dem System-Hinweis.
- Keine Zugangsdaten, Zertifikate oder Passwörter im Repo.
- Niemals echte Nutzerdaten löschen: Tests für Papierkorb und Löschen laufen ausschließlich in temporären Verzeichnissen.
