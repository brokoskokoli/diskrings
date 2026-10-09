#!/bin/bash
# Erstellt ein notarisiertes Release von DiskRings in dist/.
#
#   scripts/release.sh               # prüfen, bauen, signieren, ZIP + DMG, notarisieren
#   scripts/release.sh --publish     # zusätzlich GitHub-Release v<VERSION> anlegen
#   scripts/release.sh --skip-checks # check.sh überspringen (z. B. beim zweiten Versuch)
#
# Ablauf:
#   1. scripts/check.sh (Build und alle Tests)
#   2. scripts/make-app.sh (Release, universal, Developer ID + Hardened Runtime)
#   3. App als ZIP zur Notarisierung einreichen (scripts/notarize.sh),
#      Ticket an die App heften (stapler)
#   4. Endgültiges ZIP (ditto) und DMG (hdiutil, mit Link auf /Applications)
#      aus der gehefteten App; DMG signieren, einreichen, heften
#   5. Gatekeeper-Prüfung mit spctl
#   6. nur mit --publish: gh release create v<VERSION> mit ZIP und DMG
#
# Notarisierung (scripts/notarize.sh): Schlüsselbund-Profil "diskrings"
# (Standard) oder App Store Connect API Key über NOTARY_API_KEY_ID,
# NOTARY_API_ISSUER_ID und NOTARY_API_KEY_PATH bzw. NOTARY_API_KEY_P8_BASE64.
# Signatur: DISKRINGS_IDENTITY, DISKRINGS_KEYCHAIN (siehe make-app.sh).
# Der Release-Workflow (.github/workflows/release.yml) ruft dieses Skript mit
# --skip-checks auf. Zugangsdaten liegen nie im Repo. Siehe docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=${DISKRINGS_IDENTITY:-"Developer ID Application: Stefan Richter (AGRWTKQZ8C)"}
KEYCHAIN_ARGS=()
if [ -n "${DISKRINGS_KEYCHAIN:-}" ]; then KEYCHAIN_ARGS=(--keychain "$DISKRINGS_KEYCHAIN"); fi
SIGN_TIMEOUT=${DISKRINGS_SIGN_TIMEOUT:-60}
APP=build/DiskRings.app
DIST=dist

PUBLISH=0
SKIP_CHECKS=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        --skip-checks) SKIP_CHECKS=1 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

if [ "${DISKRINGS_ADHOC:-0}" = "1" ]; then
    echo "error: DISKRINGS_ADHOC=1 ist für ein Release nicht erlaubt." >&2
    exit 1
fi

VERSION=$(tr -d '[:space:]' < VERSION)
ZIP="$DIST/DiskRings-$VERSION.zip"
DMG="$DIST/DiskRings-$VERSION.dmg"

if [ "$PUBLISH" = "1" ]; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "error: --publish nur mit sauberem Arbeitsverzeichnis (git status)." >&2
        exit 1
    fi
    if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
        echo "error: Tag v$VERSION existiert schon. VERSION erhöhen." >&2
        exit 1
    fi
    command -v gh >/dev/null || { echo "error: gh (GitHub CLI) fehlt." >&2; exit 1; }
fi

# Führt einen Befehl mit Zeitlimit aus (für codesign und Schlüsselbund-Zugriffe,
# die an einem unsichtbaren Dialog hängen können). 124 = Zeitüberschreitung.
run_with_timeout() {
    local limit=$1; shift
    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$limit" ]; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# --- 1. Prüfen -------------------------------------------------------------
if [ "$SKIP_CHECKS" = "1" ]; then
    echo "==> check.sh übersprungen (--skip-checks)"
else
    scripts/check.sh
fi

# --- 2. App bauen und signieren --------------------------------------------
scripts/make-app.sh
# Ausgabe erst einsammeln: `grep -q` direkt in der Pipe beendet sich beim ersten
# Treffer, codesign bekommt SIGPIPE, und mit pipefail gilt das als Fehler.
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
if ! grep -qF "Authority=$IDENTITY" <<<"$SIGN_INFO"; then
    echo "error: $APP ist nicht mit \"$IDENTITY\" signiert (ad hoc?). Kein Release möglich." >&2
    exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"

# --- 3. App notarisieren ---------------------------------------------------
if ! scripts/notarize.sh check; then
    cat >&2 <<MSG

Bis hierher fertig: $APP (Developer ID signiert, noch nicht notarisiert).
Nach dem Einrichten erneut starten (die Tests müssen nicht noch einmal laufen):

    scripts/release.sh --skip-checks
MSG
    exit 1
fi

SUBMIT_ZIP="$DIST/.DiskRings-notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
scripts/notarize.sh submit "$SUBMIT_ZIP"
rm -f "$SUBMIT_ZIP"
echo "==> stapler staple $APP"
xcrun stapler staple "$APP"

# --- 4. ZIP und DMG --------------------------------------------------------
echo "==> ZIP $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> DMG $DMG"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/diskrings-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/DiskRings.app"
ln -s /Applications "$STAGE/Applications"
# hdiutil scheitert auf CI-Runnern gelegentlich mit "Resource busy": bis zu 3 Versuche.
for attempt in 1 2 3; do
    if hdiutil create -volname "DiskRings $VERSION" -srcfolder "$STAGE" -fs HFS+ \
        -format UDZO -ov "$DMG" >/dev/null; then
        break
    fi
    if [ "$attempt" -eq 3 ]; then echo "error: hdiutil create fehlgeschlagen." >&2; exit 1; fi
    echo "warning: hdiutil create fehlgeschlagen, neuer Versuch in 5 s" >&2
    sleep 5
done

echo "==> codesign $DMG"
set +e
run_with_timeout "$SIGN_TIMEOUT" codesign --force --sign "$IDENTITY" \
    ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --timestamp "$DMG"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "error: Signatur des DMG fehlgeschlagen (Code $rc; 124 = Schlüsselbund-Dialog?)." >&2
    exit "$rc"
fi
scripts/notarize.sh submit "$DMG"
echo "==> stapler staple $DMG"
xcrun stapler staple "$DMG"

# --- 5. Gatekeeper ---------------------------------------------------------
echo "==> spctl"
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS)
echo "==> Artefakte:"
ls -l "$DIST"

# --- 6. Veröffentlichen ----------------------------------------------------
if [ "$PUBLISH" = "1" ]; then
    echo "==> gh release create v$VERSION"
    gh release create "v$VERSION" "$ZIP" "$DMG" "$DIST/SHA256SUMS" \
        --title "DiskRings $VERSION" --generate-notes --target "$(git rev-parse HEAD)"
else
    echo "==> Nicht veröffentlicht (dazu: scripts/release.sh --publish)"
fi
