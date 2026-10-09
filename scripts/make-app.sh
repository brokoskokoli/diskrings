#!/bin/bash
# Baut build/DiskRings.app aus dem Release-Build und signiert es.
#
#   scripts/make-app.sh                 # Developer ID + Hardened Runtime, sonst ad hoc
#   DISKRINGS_ADHOC=1 scripts/make-app.sh   # immer ad hoc (z. B. für schnelle lokale Tests)
#
# Architektur: universal (arm64 + x86_64). `swift build --arch arm64 --arch x86_64`
# funktioniert mit den Command Line Tools (getestet mit Swift 6.4); schlägt es fehl,
# fällt das Skript mit einer Warnung auf die Architektur des Rechners zurück.
# DISKRINGS_ARCHS="arm64" erzwingt eine bestimmte Liste.
#
# Version: Datei VERSION (CFBundleShortVersionString); Build-Nummer: Anzahl der
# git-Commits (CFBundleVersion). Beides lässt sich mit VERSION=… / BUILD=… überschreiben.
#
# Signatur: "Developer ID Application: Stefan Richter (AGRWTKQZ8C)" mit
# Hardened Runtime und sicherem Zeitstempel. Entitlements braucht die App nicht
# (nicht sandboxed, kein JIT, keine Apple Events). Beim ersten Zugriff auf den
# privaten Schlüssel fragt macOS evtl. per Dialog nach dem Schlüsselbund-Passwort;
# codesign hängt dann. Das Skript bricht codesign deshalb nach
# DISKRINGS_SIGN_TIMEOUT Sekunden (Standard 60) ab. Abhilfe: Im Dialog „Immer
# erlauben“ wählen (einmalig), danach läuft die Signatur ohne Rückfrage.
#
# DISKRINGS_IDENTITY=…   andere Signier-Identität (Name wie in `security find-identity`)
# DISKRINGS_KEYCHAIN=…   Identität nur in diesem Schlüsselbund suchen (z. B. die
#                        temporäre Keychain der Release-Workflows). Dann gibt es
#                        keinen Rückfall auf ad hoc: fehlt die Identität dort,
#                        bricht das Skript ab.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DiskRings.app
BUNDLE_ID=de.stefanrichter.DiskRings
IDENTITY=${DISKRINGS_IDENTITY:-"Developer ID Application: Stefan Richter (AGRWTKQZ8C)"}
KEYCHAIN=${DISKRINGS_KEYCHAIN:-}
SIGN_TIMEOUT=${DISKRINGS_SIGN_TIMEOUT:-60}
VERSION=${VERSION:-$(tr -d '[:space:]' < VERSION)}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
# Copyright: Erstveröffentlichung 2026 (MIT, siehe LICENSE); ab 2027 als Spanne.
YEAR=$(date +%Y)
COPYRIGHT_YEARS=2026
if [ "$YEAR" -gt 2026 ]; then COPYRIGHT_YEARS="2026–$YEAR"; fi

# --- Build -----------------------------------------------------------------
ARCHS=${DISKRINGS_ARCHS:-"arm64 x86_64"}
arch_flags() { for a in $1; do printf -- '--arch %s ' "$a"; done; }

echo "==> swift build -c release ($ARCHS)"
# shellcheck disable=SC2046
if ! swift build -c release --product DiskRings $(arch_flags "$ARCHS"); then
    if [ -n "${DISKRINGS_ARCHS:-}" ]; then exit 1; fi
    ARCHS=$(uname -m)
    echo "warning: Universal-Build fehlgeschlagen, baue nur $ARCHS" >&2
    # shellcheck disable=SC2046
    swift build -c release --product DiskRings $(arch_flags "$ARCHS")
fi
# shellcheck disable=SC2046
BIN_DIR="$(swift build -c release --product DiskRings $(arch_flags "$ARCHS") --show-bin-path)"
BIN="$BIN_DIR/DiskRings"
echo "    $(lipo -archs "$BIN")"

# --- Bündel ----------------------------------------------------------------
echo "==> Bündel $APP (Version $VERSION, Build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskRings"
cp Resources/DiskRings.icns "$APP/Contents/Resources/DiskRings.icns"

# Lokalisierung: die .lproj-Ordner aus DiskRingsCore (Localizable.strings,
# .stringsdict, InfoPlist.strings) ins Haupt-Bundle. Dann nutzt die App das
# Haupt-Bundle (L10n.bundle), macOS kennt die Sprachen (Sprache pro App in den
# Systemeinstellungen) und übersetzt auch die Datenschutz-Texte.
LOCALIZATIONS=""
for lproj in Sources/DiskRingsCore/Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
    LOCALIZATIONS="$LOCALIZATIONS<string>$(basename "$lproj" .lproj)</string>"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>DiskRings</string>
    <key>CFBundleDisplayName</key><string>DiskRings</string>
    <key>CFBundleExecutable</key><string>DiskRings</string>
    <key>CFBundleIconFile</key><string>DiskRings</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © ${COPYRIGHT_YEARS} Stefan Richter. MIT License.</string>
    <!-- Datenschutz-Abfragen (TCC): macOS zeigt diese Texte, wenn der Scan
         geschützte Orte öffnet. Ohne sie fragt macOS mit einem generischen
         Text bzw. verweigert den Zugriff still. Englische Basis; die
         Übersetzungen stehen in <sprache>.lproj/InfoPlist.strings (ein Test
         prüft, dass beide dieselben Schlüssel haben). -->
    <key>NSDesktopFolderUsageDescription</key><string>DiskRings reads the sizes of the files on your desktop to show how your space is used. Files are neither opened nor changed.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>DiskRings reads the sizes of the files in your Documents folder to show how your space is used. Files are neither opened nor changed.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>DiskRings reads the sizes of the files in your Downloads folder to show how your space is used. Files are neither opened nor changed.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>DiskRings reads the sizes of the files on removable volumes (such as USB drives) to show how their space is used.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>DiskRings reads the sizes of the files on network volumes to show how their space is used.</string>
    <key>NSFileProviderDomainUsageDescription</key><string>DiskRings reads the sizes of the files in cloud storage (such as iCloud Drive or Dropbox) to show how your space is used. No files are downloaded.</string>
    <key>NSPhotoLibraryUsageDescription</key><string>DiskRings reads the size of your photo library to show how your space is used. Photos are neither opened nor changed.</string>
    <key>NSAppleMusicUsageDescription</key><string>DiskRings reads the size of your music and media folders to show how your space is used.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- Signatur --------------------------------------------------------------
# Führt codesign im Hintergrund aus und bricht nach SIGN_TIMEOUT Sekunden ab.
# Rückgabe: 0 = ok, 124 = Zeitüberschreitung, sonst Fehlercode von codesign.
codesign_with_timeout() {
    codesign "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$SIGN_TIMEOUT" ]; then
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

sign_adhoc() {
    echo "==> codesign (ad hoc)"
    codesign --force --sign - --timestamp=none "$APP"
    SIGNED_WITH=adhoc
}

# Mit DISKRINGS_KEYCHAIN: nur dort suchen, ohne -v (Gültigkeit prüft codesign
# bzw. die Notarisierung), und ohne Rückfall auf ad hoc.
KEYCHAIN_ARGS=()
if [ -n "$KEYCHAIN" ]; then
    KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
    IDENTITIES=$(security find-identity -p codesigning "$KEYCHAIN")
else
    IDENTITIES=$(security find-identity -v -p codesigning)
fi

SIGNED_WITH=
if [ "${DISKRINGS_ADHOC:-0}" = "1" ]; then
    echo "    DISKRINGS_ADHOC=1: ad-hoc-Signatur"
    sign_adhoc
elif ! grep -qF "\"$IDENTITY\"" <<<"$IDENTITIES"; then
    if [ -n "$KEYCHAIN" ]; then
        echo "error: Identität \"$IDENTITY\" nicht im Schlüsselbund $KEYCHAIN" >&2
        exit 1
    fi
    echo "warning: Identität \"$IDENTITY\" nicht im Schlüsselbund, signiere ad hoc" >&2
    sign_adhoc
else
    echo "==> codesign ($IDENTITY, Hardened Runtime, Timeout ${SIGN_TIMEOUT}s)"
    set +e
    codesign_with_timeout --force --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
        --options runtime --timestamp "$APP"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        SIGNED_WITH=developer-id
    elif [ "$rc" -eq 124 ]; then
        cat >&2 <<MSG
error: codesign hat nach ${SIGN_TIMEOUT}s nicht geantwortet.
       Vermutlich wartet ein Schlüsselbund-Dialog auf die Freigabe des privaten
       Schlüssels von "$IDENTITY".
       Abhilfe: scripts/make-app.sh im Terminal starten und im Dialog das
       Anmeldepasswort eingeben und „Immer erlauben“ wählen (einmalig).
       Für einen lokalen Test ohne Developer ID: DISKRINGS_ADHOC=1 scripts/make-app.sh
MSG
        exit 124
    else
        echo "error: codesign fehlgeschlagen (Code $rc)" >&2
        exit "$rc"
    fi
fi

# --- Prüfung ---------------------------------------------------------------
echo "==> codesign --verify"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Format|Authority|Timestamp|TeamIdentifier|Runtime Version|CodeDirectory)' || true
echo "==> $APP ($SIGNED_WITH)"
