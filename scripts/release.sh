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
#   3. App als ZIP zur Notarisierung einreichen, Ticket an die App heften (stapler)
#   4. Endgültiges ZIP (ditto) und DMG (hdiutil, mit Link auf /Applications)
#      aus der gehefteten App; DMG signieren, einreichen, heften
#   5. Gatekeeper-Prüfung mit spctl
#   6. nur mit --publish: gh release create v<VERSION> mit ZIP und DMG
#
# Voraussetzung für die Notarisierung: ein Schlüsselbund-Profil "diskrings"
# (einmalig, siehe Abbruchmeldung). Zugangsdaten liegen nie im Repo.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${DISKRINGS_NOTARY_PROFILE:-diskrings}
IDENTITY=${DISKRINGS_IDENTITY:-"Developer ID Application: Stefan Richter (AGRWTKQZ8C)"}
TEAM_ID=AGRWTKQZ8C
SIGN_TIMEOUT=${DISKRINGS_SIGN_TIMEOUT:-60}
APP=build/DiskRings.app
DIST=dist

PUBLISH=0
SKIP_CHECKS=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        --skip-checks) SKIP_CHECKS=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

notary_help() {
    cat >&2 <<MSG

error: Kein Notarisierungs-Profil "$PROFILE" im Schlüsselbund.

Einmalig anlegen (fragt nach einem app-spezifischen Passwort, erzeugt unter
https://account.apple.com → Anmeldung und Sicherheit → App-spezifische Passwörter):

    xcrun notarytool store-credentials $PROFILE --apple-id <deine-apple-id> --team-id $TEAM_ID

Danach erneut starten (die Tests müssen nicht noch einmal laufen):

    scripts/release.sh --skip-checks

Bis hierher fertig: $APP (Developer ID signiert, noch nicht notarisiert).
MSG
}

# Reicht eine Datei ein und wartet auf das Ergebnis; bei Ablehnung das Protokoll zeigen.
notarize() {
    local file=$1 out id
    echo "==> notarytool submit $file (wartet auf Apple, meist wenige Minuten)"
    out=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait 2>&1) || true
    echo "$out"
    if ! grep -q "status: Accepted" <<<"$out"; then
        id=$(grep -m1 -Eo 'id: [0-9a-f-]{36}' <<<"$out" | cut -d' ' -f2 || true)
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        fi
        echo "error: Notarisierung von $file nicht akzeptiert." >&2
        exit 1
    fi
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
echo "==> Notarisierungs-Profil \"$PROFILE\" prüfen"
set +e
run_with_timeout 60 xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 124 ]; then
    echo "error: notarytool hat nach 60 s nicht geantwortet (Schlüsselbund-Dialog?)." >&2
    exit 124
elif [ "$rc" -ne 0 ]; then
    notary_help
    exit 1
fi

SUBMIT_ZIP="$DIST/.DiskRings-notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
notarize "$SUBMIT_ZIP"
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
hdiutil create -volname "DiskRings $VERSION" -srcfolder "$STAGE" -fs HFS+ \
    -format UDZO -ov "$DMG" >/dev/null

echo "==> codesign $DMG"
set +e
run_with_timeout "$SIGN_TIMEOUT" codesign --force --sign "$IDENTITY" --timestamp "$DMG"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "error: Signatur des DMG fehlgeschlagen (Code $rc; 124 = Schlüsselbund-Dialog?)." >&2
    exit "$rc"
fi
notarize "$DMG"
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
