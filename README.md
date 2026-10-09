# DiskRings

Festplatten-Analysator für macOS: zeigt die Belegung eines Volumes oder Ordners als Sunburst-Diagramm, mit Drill-down, „Im Finder zeigen“, Papierkorb, Teil-Rescan und Snapshot-Vergleich („Wo ist mein Speicher hin?“).

Status: Meilensteine M1–M3 (Scan-Engine, Kommandozeilen-Werkzeug, SwiftUI-Oberfläche mit Sunburst). Spezifikation: [SPEC.md](SPEC.md), Entscheidungen: [docs/DECISIONS.md](docs/DECISIONS.md), Messwerte: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

```sh
scripts/check.sh                                  # Build und alle Tests
swift run -c release diskrings-cli scan ~ --top 10 --depth 2
swift run -c release diskrings-cli scan / --json
swift run -c release diskrings-cli volumes
```

App:

```sh
scripts/make-app.sh && open build/DiskRings.app          # Bündel bauen und starten
swift run DiskRings --render-snapshots build/snapshots --scan /usr/share   # Vorschaubilder (PNG, hell/dunkel)
```
