#!/bin/bash
# Baut build/DiskRings.app aus dem Release-Build und signiert es.
#
#   scripts/make-app.sh                 # Developer ID + Hardened Runtime, sonst ad hoc
#   DISKRINGS_ADHOC=1 scripts/make-app.sh   # immer ad hoc (z. B. für schnelle lokale Tests)
#   scripts/make-app.sh --appstore      # Mac-App-Store-Variante (Sandbox) + .pkg
#
# --appstore (SPEC 11, docs/APPSTORE.md): baut build/appstore/DiskRings.app
# (die Developer-ID-App in build/DiskRings.app bleibt unberührt) mit den
# Entitlements aus Resources/DiskRings-AppStore.entitlements (nur App Sandbox,
# vom Nutzer gewählte Dateien, app-bezogene Bookmarks) und
# ITSAppUsesNonExemptEncryption = false. Signatur mit
#   DISKRINGS_APPSTORE_IDENTITY   (Standard "Apple Distribution: Stefan Richter (AGRWTKQZ8C)"),
# fehlt sie, ad hoc MIT den Sandbox-Entitlements (nur für lokale Tests, Warnung).
#   DISKRINGS_PROVISIONING_PROFILE   Pfad zum Profil „Mac App Store Connect“;
#                                    wird als embedded.provisionprofile eingebettet,
#                                    application-identifier und team-identifier kommen
#                                    daraus in die Entitlements.
# Danach build/DiskRings-<version>.pkg per productbuild, signiert mit
#   DISKRINGS_INSTALLER_IDENTITY  (Standard "3rd Party Mac Developer Installer: Stefan
#                                  Richter (AGRWTKQZ8C)", ersatzweise "Mac Installer
#                                  Distribution: Stefan Richter (AGRWTKQZ8C)"),
# sonst unsigniert (Warnung; so nimmt App Store Connect es nicht an).
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

APPSTORE=0
for arg in "$@"; do
    case "$arg" in
        --appstore) APPSTORE=1 ;;
        -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

APP=build/DiskRings.app
if [ "$APPSTORE" = "1" ]; then APP=build/appstore/DiskRings.app; fi
ENTITLEMENTS=Resources/DiskRings-AppStore.entitlements
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

# Der App Store verlangt das Icon in voller Größe (1024 px = 512@2x).
if [ "$APPSTORE" = "1" ]; then
    ICONSET=$(mktemp -d "${TMPDIR:-/tmp}/diskrings-icon.XXXXXX")
    rm -rf "$ICONSET"
    iconutil -c iconset -o "$ICONSET.iconset" Resources/DiskRings.icns
    ICON_PX=$(sips -g pixelWidth "$ICONSET.iconset/icon_512x512@2x.png" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    rm -rf "$ICONSET.iconset"
    if [ "${ICON_PX:-0}" != "1024" ]; then
        echo "error: Resources/DiskRings.icns enthält kein 1024-px-Bild (512@2x)" >&2
        exit 1
    fi
    echo "    Icon enthält 1024 px (512@2x)"
fi

# Lokalisierung: die .lproj-Ordner aus DiskRingsCore (Localizable.strings,
# .stringsdict, InfoPlist.strings) ins Haupt-Bundle. Dann nutzt die App das
# Haupt-Bundle (L10n.bundle), macOS kennt die Sprachen (Sprache pro App in den
# Systemeinstellungen) und übersetzt auch die Datenschutz-Texte.
LOCALIZATIONS=""
for lproj in Sources/DiskRingsCore/Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
    LOCALIZATIONS="$LOCALIZATIONS<string>$(basename "$lproj" .lproj)</string>"
done

# Store-Variante: keine eigene Verschlüsselung (erspart die Exportfrage beim Hochladen).
APPSTORE_PLIST=""
if [ "$APPSTORE" = "1" ]; then
    APPSTORE_PLIST="<key>ITSAppUsesNonExemptEncryption</key><false/>"
fi

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
    ${APPSTORE_PLIST}
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
if [ "$APPSTORE" = "1" ]; then
    APPSTORE_IDENTITY=${DISKRINGS_APPSTORE_IDENTITY:-"Apple Distribution: Stefan Richter (AGRWTKQZ8C)"}
    PROFILE=${DISKRINGS_PROVISIONING_PROFILE:-}
    SIGN_ENTITLEMENTS="$ENTITLEMENTS"
    if [ -n "$PROFILE" ]; then
        if [ ! -f "$PROFILE" ]; then
            echo "error: DISKRINGS_PROVISIONING_PROFILE=$PROFILE existiert nicht" >&2
            exit 1
        fi
        echo "==> Provisioning Profile einbetten"
        cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    fi
    if [ "${DISKRINGS_ADHOC:-0}" != "1" ] && grep -qF "\"$APPSTORE_IDENTITY\"" <<<"$IDENTITIES"; then
        if [ -n "$PROFILE" ]; then
            # application-identifier und team-identifier aus dem Profil; ohne sie
            # lehnt App Store Connect den Build ab.
            PROFILE_PLIST=$(mktemp "${TMPDIR:-/tmp}/diskrings-profile.XXXXXX")
            SIGN_ENTITLEMENTS=$(mktemp "${TMPDIR:-/tmp}/diskrings-entitlements.XXXXXX")
            security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
            APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST")
            TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$PROFILE_PLIST")
            rm -f "$PROFILE_PLIST"
            if [ "$APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]; then
                echo "error: Profil gehört zu $APP_ID, erwartet $TEAM_ID.$BUNDLE_ID" >&2
                exit 1
            fi
            cp "$ENTITLEMENTS" "$SIGN_ENTITLEMENTS"
            /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" "$SIGN_ENTITLEMENTS"
            /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$SIGN_ENTITLEMENTS"
        else
            echo "warning: Kein DISKRINGS_PROVISIONING_PROFILE: Der Build lässt sich so nicht hochladen" >&2
        fi
        echo "==> codesign ($APPSTORE_IDENTITY, Sandbox, Timeout ${SIGN_TIMEOUT}s)"
        set +e
        codesign_with_timeout --force --sign "$APPSTORE_IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
            --entitlements "$SIGN_ENTITLEMENTS" --options runtime --timestamp=none "$APP"
        rc=$?
        set -e
        if [ "$SIGN_ENTITLEMENTS" != "$ENTITLEMENTS" ]; then rm -f "$SIGN_ENTITLEMENTS"; fi
        if [ "$rc" -ne 0 ]; then
            echo "error: codesign fehlgeschlagen (Code $rc; 124 = Schlüsselbund-Dialog?)" >&2
            exit "$rc"
        fi
        SIGNED_WITH=apple-distribution
    else
        if [ -n "$KEYCHAIN" ]; then
            echo "error: Identität \"$APPSTORE_IDENTITY\" nicht im Schlüsselbund $KEYCHAIN" >&2
            exit 1
        fi
        cat >&2 <<MSG
warning: Identität "$APPSTORE_IDENTITY" nicht im Schlüsselbund (oder DISKRINGS_ADHOC=1).
         Signiere ad hoc MIT den Sandbox-Entitlements: nur zum lokalen Testen,
         nicht für App Store Connect (siehe docs/APPSTORE.md).
MSG
        echo "==> codesign (ad hoc, Sandbox-Entitlements)"
        codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
        SIGNED_WITH=adhoc-sandbox
    fi
elif [ "${DISKRINGS_ADHOC:-0}" = "1" ]; then
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
if [ "$APPSTORE" = "1" ]; then
    echo "==> Entitlements"
    codesign -d --entitlements - "$APP" 2>/dev/null || true
fi
echo "==> $APP ($SIGNED_WITH)"

# --- Installer-Paket (nur App Store) ----------------------------------------
if [ "$APPSTORE" = "1" ]; then
    PKG="build/DiskRings-$VERSION.pkg"
    rm -f "$PKG"
    if [ -n "$KEYCHAIN" ]; then
        ALL_IDENTITIES=$(security find-identity "$KEYCHAIN")
    else
        ALL_IDENTITIES=$(security find-identity -v)
    fi
    INSTALLER_IDENTITY=
    for candidate in "${DISKRINGS_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: Stefan Richter (AGRWTKQZ8C)}" \
                     "Mac Installer Distribution: Stefan Richter (AGRWTKQZ8C)"; do
        if grep -qF "\"$candidate\"" <<<"$ALL_IDENTITIES"; then INSTALLER_IDENTITY=$candidate; break; fi
    done
    if [ -n "$INSTALLER_IDENTITY" ] && [ "$SIGNED_WITH" = "apple-distribution" ]; then
        echo "==> productbuild ($INSTALLER_IDENTITY)"
        productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" \
            ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$PKG"
        pkgutil --check-signature "$PKG" | head -4 || true
    else
        echo "warning: Keine Installer-Identität (oder App nur ad hoc signiert): $PKG bleibt unsigniert und ist nicht für App Store Connect geeignet" >&2
        echo "==> productbuild (unsigniert)"
        productbuild --component "$APP" /Applications "$PKG"
    fi
    echo "==> $PKG"
fi
