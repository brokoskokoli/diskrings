# DiskRings – Arbeitsregeln

Zuerst lesen: `dev/ARCHITECTURE.md` (jede Datei, Datenfluss, Invarianten, die nicht brechen dürfen).

Die Spezifikation steht in `SPEC.md` und ist verbindlich. Wenn du von ihr abweichen musst, notiere die Abweichung mit Begründung in `dev/DECISIONS.md`.

## Struktur (Swift Package, kein Xcode-Projekt)
- `Sources/DiskRingsCore`: die gesamte Logik ohne UI: Scanner, Modell, Sunburst-Layout-Mathematik, Hit-Test, Snapshots/Diff, ProtectedPaths, Formatierung. Hier darf **kein** SwiftUI-Import stehen.
- `Sources/DiskRings`: SwiftUI/AppKit-App. Sie bleibt dünn, alle testbare Logik gehört nach Core.
- `Sources/diskrings-cli`: Kommandozeilen-Werkzeug (Scan, Top-Ordner, Snapshot, Diff) für Tests und Debugging.
- `Tests/DiskRingsCoreTests`: Unit- und Integrationstests mit temporären Fixture-Bäumen. Das einzige Testziel: Die App hat **kein** Testziel, Logik dort ist ungetestet und gehört deshalb nach Core.
- `scripts/`: `make-app.sh` (Bundle und Signatur), `release.sh` (Notarisierung), `check.sh` (Build und alle Tests).
- `dev/`: Entwickler-Doku (ARCHITECTURE, DECISIONS, PERFORMANCE, RELEASING, APPSTORE, APPSTORE-METADATA).
- `docs/`: **nur die Website** (GitHub Pages veröffentlicht diesen Ordner). Keine Entwickler-Doku hier ablegen; README-Bilder liegen in `docs/images/`.
- Mindest-OS macOS 14, Swift 6 im Strict-Concurrency-Modus.

## Arbeitsweise
- Testgetrieben: Zuerst den Test schreiben, dann den Code. Jede Funktion aus der Spec bekommt Tests, Fehlerfälle eingeschlossen (Hardlinks, Symlink-Zyklen, unlesbare Ordner, Sparse-Dateien, leere Ordner, Unicode-Namen).
- Vor jedem Commit muss `scripts/check.sh` grün sein (`swift build` und `swift test`, keine Warnungen in eigenem Code).
- UI-Views visuell prüfen: `swift run DiskRings --render-snapshots build/snapshots` rendert die Szenen hell und dunkel als PNG (optional `--scan <pfad>`, `--compare-demo`, `--language <code>`); neue Views dort als Szene ergänzen.
- Kleine, thematische Commits auf `main`; Commit-Nachrichten auf Deutsch, mit den Attribution-Zeilen aus dem System-Hinweis.
- Keine Zugangsdaten, Zertifikate oder Passwörter im Repo.
- Niemals echte Nutzerdaten löschen: Tests für Papierkorb und Löschen laufen ausschließlich in temporären Verzeichnissen.

## Ablauf mit Agenten (Coder und Verifier)
- Größere Aufgaben in thematische Pakete teilen (z. B. Scanner, Layout, Snapshots, UI, Lokalisierung). Jedes Paket setzt ein Coder-Subagent um, testgetrieben und bis `scripts/check.sh` grün ist. Unabhängige Pakete laufen parallel, wenn nötig in eigenen Worktrees.
- Danach prüft ein **eigener Verifier-Subagent** das Ergebnis, nicht derselbe Agent, der es gebaut hat. Er prüft gegen `SPEC.md`, sucht gezielt Fehlerfälle (Rennbedingungen, Pfad-Präfixe, Hardlinks, Mounts, Abbruch, Speicher) und meldet nur Funde mit konkretem Szenario.
- Jeder bestätigte Fund wird zuerst als Regressionstest geschrieben und dann behoben. Erst danach wird committet.
- Der Haupt-Agent koordiniert, führt die Ergebnisse zusammen, prüft selbst nach (Tests, gerenderte PNGs, CLI-Läufe auf echten Ordnern, nur lesend) und hält Abweichungen in `dev/DECISIONS.md` fest.
- Agenten exportieren keine Zertifikate, lesen keine Secrets, führen `scripts/setup-release-secrets.sh` nicht aus und setzen keine Secrets.
- GitHub-Actions nur auf geprüfte, mindestens zwei Wochen alte Versionen per Commit-SHA pinnen; keine Updates auf ganz frische Versionen.

## Releases
- Ablauf und Einrichtung: `dev/RELEASING.md`; Kurzfassung in `README.md` („Publishing a new version“).
- Version steht in `VERSION` (SemVer), der Tag `v<VERSION>` muss dazu passen. Die Build-Nummer ergibt sich aus der Zahl der Commits.
- Standardweg: `VERSION` erhöhen, committen, pushen, CI grün abwarten, annotierten Tag pushen. `release.yml` baut, signiert, notarisiert und veröffentlicht nach Freigabe im Environment `release`. Vorher ggf. Trockenlauf (`gh workflow run release.yml -f dry_run=true`).
- **Tags setzen, Releases veröffentlichen und Deployments freigeben nur auf ausdrückliche Anweisung des Maintainers**, jedes Mal neu.
- Lokal: `scripts/release.sh` nutzt das Schlüsselbund-Profil `diskrings` (notarytool) und die Developer ID im Anmelde-Schlüsselbund; `--publish` legt zusätzlich das GitHub-Release an.
