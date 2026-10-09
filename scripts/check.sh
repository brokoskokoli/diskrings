#!/bin/bash
# Build und alle Tests; bricht beim ersten Fehler ab.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "==> swift build"
swift build
echo "==> swift test"
swift test
echo "==> OK"
