#!/bin/bash
# Build und alle Tests; bricht beim ersten Fehler ab.
# Zusätzlich laufen die Performance-Tests im Release-Build, weil die
# Zielwerte der Spec (z. B. Vergleich von 2 Mio. Knoten unter 2 s) für das
# optimierte Programm gelten; im Debug-Build prüfen sie nur grobe Grenzen.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "==> swift build"
swift build
echo "==> swift test"
swift test
echo "==> swift test -c release (Performance)"
swift test -c release -Xswiftc -enable-testing --filter 'Performance|performance'
echo "==> OK"
