# DiskRings

Festplatten-Analysator für macOS: zeigt die Belegung eines Volumes oder Ordners als Sunburst-Diagramm, mit Drill-down, „Im Finder zeigen“, Papierkorb, Teil-Rescan und Snapshot-Vergleich („Wo ist mein Speicher hin?“).

Status: Meilenstein M1 (Scan-Engine und Kommandozeilen-Werkzeug). Spezifikation: [SPEC.md](SPEC.md), Entscheidungen: [docs/DECISIONS.md](docs/DECISIONS.md), Messwerte: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

```sh
scripts/check.sh                                  # Build und alle Tests
swift run -c release diskrings-cli scan ~ --top 10 --depth 2
swift run -c release diskrings-cli scan / --json
swift run -c release diskrings-cli volumes
```
