#!/bin/bash
# Hilfsschritte für den Workflow "App Store Upload" (.github/workflows/appstore.yml).
# Lokal aufrufbar, um den Workflow nachzustellen (siehe dev/APPSTORE.md).
#
#   scripts/ci-appstore.sh preflight         # Ref/VERSION, Secrets vorhanden und plausibel?
#   scripts/ci-appstore.sh keychain-setup    # beide .p12 (Apple Distribution, Installer) importieren
#   scripts/ci-appstore.sh build             # make-app.sh --appstore, Signaturen prüfen
#   scripts/ci-appstore.sh validate          # xcrun altool --validate-app (API Key)
#   scripts/ci-appstore.sh upload            # xcrun altool --upload-app (API Key)
#   scripts/ci-appstore.sh submit            # zur Prüfung einreichen (scripts/asc-submit.sh)
#   scripts/ci-appstore.sh summary           # Zusammenfassung nach GITHUB_STEP_SUMMARY
#   scripts/ci-appstore.sh cleanup           # API-Key-Datei, Keychain, Suchliste
#
# preflight liest GITHUB_REF_TYPE, GITHUB_REF_NAME, DRY_RUN, SUBMIT_FOR_REVIEW und prüft diese
# Secrets (Environment "appstore"), ohne Werte auszugeben:
#   APPSTORE_DISTRIBUTION_P12_BASE64  .p12 mit "Apple Distribution: …", base64
#   APPSTORE_INSTALLER_P12_BASE64     .p12 mit "3rd Party Mac Developer Installer: …", base64
#   APPSTORE_CERTIFICATES_PASSWORD    Passwort beider .p12
#   (Zwei .p12 statt einem: Beide Zertifikate stammen meist aus derselben CSR und
#   teilen sich den privaten Schlüssel; aus einem gemeinsamen .p12 ordnet
#   `security import` den Schlüssel nur einem Zertifikat zu.)
#   APPSTORE_PROVISIONING_PROFILE_BASE64  Profil "Mac App Store Connect", base64
#   NOTARY_API_KEY_P8_BASE64, NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID
#                                     App Store Connect API Key (Rolle App Manager)
# Ausgabe nach GITHUB_OUTPUT: version, tag, build, upload, submit (true/false).
# Hochgeladen wird nur bei dry_run = false auf einem Tag v<VERSION>. submit_for_review
# geht nur zusammen mit einem Upload und braucht dev/release-notes/<VERSION>.{en,de}.txt.
#
# Die temporäre Keychain und das Zwischenzertifikat übernimmt scripts/ci-release.sh
# (eingebunden mit `source`), Zustand unter $DISKRINGS_CI_STATE (Standard
# $RUNNER_TEMP/diskrings-appstore). Die .p8 liegt nur während eines altool-Aufrufs
# unter ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8 (0600) und wird danach
# (trap) bzw. spätestens in cleanup gelöscht.
#
# Kein `set -x`: Secrets dürfen nicht im Log landen.
set -euo pipefail

export DISKRINGS_CI_STATE=${DISKRINGS_CI_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/diskrings-appstore}
# shellcheck source=scripts/ci-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-release.sh"

BUNDLE_ID=de.stefanrichter.DiskRings
TEAM_ID=AGRWTKQZ8C
APPSTORE_IDENTITY=${DISKRINGS_APPSTORE_IDENTITY:-"Apple Distribution: Stefan Richter ($TEAM_ID)"}
# Installer-Identität: Das Zertifikat "Mac Installer Distribution" heißt im
# Schlüsselbund meist "3rd Party Mac Developer Installer: …"; beide Namen gehen.
INSTALLER_CANDIDATES=("3rd Party Mac Developer Installer: Stefan Richter ($TEAM_ID)"
                      "Mac Installer Distribution: Stefan Richter ($TEAM_ID)")
if [ -n "${DISKRINGS_INSTALLER_IDENTITY:-}" ]; then INSTALLER_CANDIDATES=("$DISKRINGS_INSTALLER_IDENTITY"); fi
INSTALLER_IDENTITY=${INSTALLER_CANDIDATES[0]}
APP=build/appstore/DiskRings.app
PROFILE_FILE="$STATE/DiskRings_App_Store.provisionprofile"
# Zwischenzertifikat "Apple Worldwide Developer Relations Certification Authority" (G3),
# SHA-256 von https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer (gültig bis 2030).
WWDR_G3_URL=https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
WWDR_G3_SHA256=DCF21878C77F4198E4B4614F03D696D89C66C66008D4244E1B99161AAC91601F
# Verzeichnis, in dem altool den Schlüssel AuthKey_<ID>.p8 sucht (eines von
# ./private_keys, ~/private_keys, ~/.private_keys, ~/.appstoreconnect/private_keys).
ALTOOL_KEY_DIR="$HOME/.appstoreconnect/private_keys"

version() { tr -d '[:space:]' < VERSION; }
pkg_path() { echo "build/DiskRings-$(version).pkg"; }

# --- preflight -----------------------------------------------------------------
SECRETS=(APPSTORE_DISTRIBUTION_P12_BASE64 APPSTORE_INSTALLER_P12_BASE64 APPSTORE_CERTIFICATES_PASSWORD
         APPSTORE_PROVISIONING_PROFILE_BASE64
         NOTARY_API_KEY_P8_BASE64 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID)

appstore_secrets_help() {
    local repo=${GITHUB_REPOSITORY:-brokoskokoli/diskrings}
    cat <<MSG

==============================================================================
 App-Store-Upload nicht möglich: Es fehlen Secrets.

 Fehlend: $*

 So richtest du sie einmalig ein (Details: dev/APPSTORE.md, "Upload per Workflow"):

 1. Environment "appstore" anlegen (Settings → Environments → New environment),
    Required reviewers: du, Deployment branches and tags: Tag v* und Branch main.
 2. App Store Connect API Key mit Rolle "App Manager" (oder höher). Der
    Notarisierungs-Key mit Rolle "Developer" darf keine Builds hochladen.
 3. Auf dem Mac mit den Zertifikaten "Apple Distribution" und
    "3rd Party Mac Developer Installer" im Schlüsselbund:

        scripts/setup-release-secrets.sh --appstore

    Das Skript exportiert beide Identitäten in je ein .p12, kodiert das
    Provisioning Profile und setzt alle Secrets im Environment "appstore"
    von $repo.
 4. Workflow erneut starten (Actions → App Store Upload → Run workflow).

 Manuell: Settings → Environments → appstore → Environment secrets:
   APPSTORE_DISTRIBUTION_P12_BASE64      .p12 mit "Apple Distribution: …", base64
   APPSTORE_INSTALLER_P12_BASE64         .p12 mit "3rd Party Mac Developer Installer: …", base64
   APPSTORE_CERTIFICATES_PASSWORD        Passwort beider .p12
   APPSTORE_PROVISIONING_PROFILE_BASE64  DiskRings_App_Store.provisionprofile, base64
   NOTARY_API_KEY_P8_BASE64              AuthKey_<KeyID>.p8, base64
   NOTARY_API_KEY_ID                     Key-ID (10 Zeichen)
   NOTARY_API_ISSUER_ID                  Issuer-ID (UUID)
==============================================================================
MSG
    if [ -n "${APPSTORE_CERTIFICATES_P12_BASE64:-}" ]; then
        cat <<'MSG'
 Hinweis: Das alte Secret APPSTORE_CERTIFICATES_P12_BASE64 (ein .p12 mit beiden
 Identitäten) wird nicht mehr verwendet. Bitte erneut ausführen:
     scripts/setup-release-secrets.sh --appstore
 Es setzt APPSTORE_DISTRIBUTION_P12_BASE64 und APPSTORE_INSTALLER_P12_BASE64
 und löscht das alte Secret.
==============================================================================
MSG
    fi
}

# Dekodiert APPSTORE_PROVISIONING_PROFILE_BASE64 nach $1 und prüft es: Mac App
# Store (keine Geräteliste), richtige App-ID, nicht abgelaufen.
decode_profile() {
    local out=$1 plist now exp
    mkdir -p "$(dirname "$out")"
    (umask 077; printf '%s' "$APPSTORE_PROVISIONING_PROFILE_BASE64" | tr -d '[:space:]' \
        | base64 --decode > "$out") 2>/dev/null \
        || { rm -f "$out"; die "APPSTORE_PROVISIONING_PROFILE_BASE64 ist kein gültiges base64."; }
    plist="$out.plist"
    security cms -D -i "$out" > "$plist" 2>/dev/null \
        || { rm -f "$out" "$plist"; die "APPSTORE_PROVISIONING_PROFILE_BASE64 ist kein Provisioning Profile (base64 -i DiskRings_App_Store.provisionprofile)."; }
    local app_id
    app_id=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$plist" 2>/dev/null || true)
    if [ "$app_id" != "$TEAM_ID.$BUNDLE_ID" ]; then
        rm -f "$plist"
        die "Provisioning Profile gehört zu '$app_id', erwartet $TEAM_ID.$BUNDLE_ID."
    fi
    if /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$plist" >/dev/null 2>&1 \
        || [ "$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$plist" 2>/dev/null || true)" = "true" ]; then
        rm -f "$plist"
        die "Provisioning Profile ist kein \"Mac App Store Connect\"-Profil (Development/Developer ID)."
    fi
    exp=$(plutil -extract ExpirationDate raw "$plist" 2>/dev/null || true)
    rm -f "$plist"
    if [ -n "$exp" ]; then
        exp=$(LC_ALL=C date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$exp" +%s 2>/dev/null || echo 0)
        now=$(date -u +%s)
        [ "$exp" -gt "$now" ] || die "Provisioning Profile ist abgelaufen. Neues Profil anlegen (dev/APPSTORE.md, Schritt 3)."
    fi
}

cmd_preflight() {
    local version tag upload=false build submit=${SUBMIT_FOR_REVIEW:-false}
    local ref_type=${GITHUB_REF_TYPE:-branch} ref_name=${GITHUB_REF_NAME:-} dry_run=${DRY_RUN:-true}
    version=$(version)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "VERSION enthält keine für den App Store gültige Versionsnummer (x.y.z): '$version'"
    tag="v$version"

    if [ "$ref_type" = "tag" ] && [ "$ref_name" != "$tag" ]; then
        die "Tag '$ref_name' passt nicht zu VERSION ($version). Erwartet: $tag."
    fi
    if [ "$dry_run" = "true" ]; then
        upload=false
    elif [ "$ref_type" = "tag" ]; then
        upload=true
    else
        die "Hochladen (dry_run = false) geht nur, wenn der Workflow auf einem Tag gestartet wird (\"Use workflow from\" → Tags → $tag). Für einen Probelauf dry_run anhaken."
    fi
    if [ "$submit" = "true" ]; then
        [ "$upload" = "true" ] \
            || die "submit_for_review geht nur zusammen mit einem Upload: auf dem Tag $tag starten und dry_run abhaken."
        # Früh scheitern, nicht erst nach 15 Minuten Bauen.
        scripts/asc-submit.sh check-notes "$version" \
            || die "Release Notes für $version fehlen oder sind ungültig (dev/release-notes/README.md)."
    else
        submit=false
    fi

    local missing=() name
    for name in "${SECRETS[@]}"; do
        if [ -z "${!name:-}" ]; then missing+=("$name"); fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        appstore_secrets_help "${missing[*]}"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            { echo '```'; appstore_secrets_help "${missing[*]}"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
        fi
        if [ -n "${APPSTORE_CERTIFICATES_P12_BASE64:-}" ]; then
            die "Secrets fehlen: ${missing[*]}. Das alte APPSTORE_CERTIFICATES_P12_BASE64 reicht nicht mehr: scripts/setup-release-secrets.sh --appstore erneut ausführen."
        fi
        die "Secrets fehlen: ${missing[*]} (Anleitung siehe oben bzw. dev/APPSTORE.md)"
    fi

    # Format grob prüfen, ohne Werte auszugeben.
    [[ "$NOTARY_API_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] \
        || die "NOTARY_API_KEY_ID sieht nicht wie eine Key-ID aus (10 Zeichen, A-Z und 0-9)."
    [[ "$NOTARY_API_ISSUER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || die "NOTARY_API_ISSUER_ID sieht nicht wie eine Issuer-ID aus (UUID)."
    local p8
    p8=$(printf '%s' "$NOTARY_API_KEY_P8_BASE64" | tr -d '[:space:]' | base64 --decode 2>/dev/null || true)
    grep -q -- '-----BEGIN PRIVATE KEY-----' <<<"$p8" \
        || die "NOTARY_API_KEY_P8_BASE64 ist keine base64-kodierte .p8-Datei (base64 -i AuthKey_….p8)."
    unset p8
    for name in APPSTORE_DISTRIBUTION_P12_BASE64 APPSTORE_INSTALLER_P12_BASE64; do
        if ! printf '%s' "${!name}" | tr -d '[:space:]' | base64 --decode >/dev/null 2>&1; then
            die "$name ist kein gültiges base64 (base64 -i datei.p12)."
        fi
    done
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    decode_profile "$STATE/preflight.provisionprofile"
    rm -f "$STATE/preflight.provisionprofile"

    # Build-Nummer wie make-app.sh: Anzahl der Commits (braucht fetch-depth: 0).
    if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
        die "Flacher Checkout: Die Build-Nummer (Anzahl der Commits) wäre falsch. fetch-depth: 0 setzen."
    fi
    build=$(git rev-list --count HEAD)

    echo "Version $version, Build $build, Ref $ref_type/$ref_name, hochladen: $upload, einreichen: $submit"
    gh_output version "$version"
    gh_output tag "$tag"
    gh_output build "$build"
    gh_output upload "$upload"
    gh_output submit "$submit"
}

# --- keychain ----------------------------------------------------------------
# Setzt INSTALLER_IDENTITY auf den ersten Kandidaten, den die Keychain $1 enthält.
pick_installer_identity() {
    local all candidate
    all=$(security find-identity -p basic "$1" 2>/dev/null || true)
    for candidate in "${INSTALLER_CANDIDATES[@]}"; do
        if grep -qF "\"$candidate\"" <<<"$all"; then INSTALLER_IDENTITY=$candidate; return 0; fi
    done
}

cmd_keychain_setup() {
    keychain_import "Neu erzeugen mit scripts/setup-release-secrets.sh --appstore." \
        APPSTORE_CERTIFICATES_PASSWORD APPSTORE_DISTRIBUTION_P12_BASE64 APPSTORE_INSTALLER_P12_BASE64
    ensure_intermediate "Apple Worldwide Developer Relations Certification Authority" \
        "$WWDR_G3_URL" "$WWDR_G3_SHA256"
    DISKRINGS_REQUIRE_VALID_IDENTITY=${DISKRINGS_REQUIRE_VALID_IDENTITY:-1} require_identity "$APPSTORE_IDENTITY" codesigning
    pick_installer_identity "$KEYCHAIN"
    DISKRINGS_REQUIRE_VALID_IDENTITY=${DISKRINGS_REQUIRE_VALID_IDENTITY:-1} require_identity "$INSTALLER_IDENTITY" basic
    export_keychain_env
}

# --- build -----------------------------------------------------------------------
# Liest einen Schlüssel aus einer Entitlements-plist (PlistBuddy: Punkte im Namen erlaubt).
ent() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true; }

cmd_build() {
    [ -n "${APPSTORE_PROVISIONING_PROFILE_BASE64:-}" ] || die "APPSTORE_PROVISIONING_PROFILE_BASE64 fehlt."
    local keychain=${DISKRINGS_KEYCHAIN:-$KEYCHAIN}
    [ -e "$keychain" ] || die "Keychain $keychain fehlt (vorher keychain-setup)."
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    decode_profile "$PROFILE_FILE"
    pick_installer_identity "$keychain"

    DISKRINGS_KEYCHAIN="$keychain" DISKRINGS_PROVISIONING_PROFILE="$PROFILE_FILE" \
        DISKRINGS_APPSTORE_IDENTITY="$APPSTORE_IDENTITY" DISKRINGS_INSTALLER_IDENTITY="$INSTALLER_IDENTITY" \
        scripts/make-app.sh --appstore
    rm -f "$PROFILE_FILE"

    echo "==> Signatur der App prüfen"
    codesign --verify --deep --strict "$APP"
    codesign -dvv "$APP" 2>&1 | grep -qF "Authority=$APPSTORE_IDENTITY" \
        || die "$APP ist nicht mit \"$APPSTORE_IDENTITY\" signiert."
    [ -f "$APP/Contents/embedded.provisionprofile" ] || die "embedded.provisionprofile fehlt in $APP."

    echo "==> Entitlements prüfen"
    local ents="$STATE/entitlements.plist"
    codesign -d --entitlements - --xml "$APP" > "$ents" 2>/dev/null \
        || die "Entitlements von $APP nicht lesbar."
    [ "$(ent com.apple.security.app-sandbox "$ents")" = "true" ] || die "App Sandbox fehlt in den Entitlements."
    [ "$(ent com.apple.application-identifier "$ents")" = "$TEAM_ID.$BUNDLE_ID" ] \
        || die "application-identifier fehlt oder ist falsch."
    [ "$(ent com.apple.developer.team-identifier "$ents")" = "$TEAM_ID" ] \
        || die "team-identifier fehlt oder ist falsch."
    [ "$(ent com.apple.security.get-task-allow "$ents")" != "true" ] || die "get-task-allow darf nicht gesetzt sein."
    rm -f "$ents"
    plutil -extract ITSAppUsesNonExemptEncryption raw "$APP/Contents/Info.plist" | grep -qx false \
        || die "ITSAppUsesNonExemptEncryption = false fehlt im Info.plist."

    echo "==> Signatur des Pakets prüfen"
    local pkg out
    pkg=$(pkg_path)
    [ -f "$pkg" ] || die "$pkg fehlt."
    out=$(pkgutil --check-signature "$pkg") || { echo "$out" >&2; die "$pkg ist nicht gültig signiert."; }
    echo "$out" | head -6
    grep -qE '3rd Party Mac Developer Installer|Mac Installer Distribution' <<<"$out" \
        || die "$pkg ist nicht mit einer Installer-Identität für den Mac App Store signiert."
    gh_output pkg "$pkg"
}

# --- altool ------------------------------------------------------------------------
KEY_FILE=
remove_key_file() {
    if [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ]; then rm -f "$KEY_FILE"; fi
    KEY_FILE=
}

# Schreibt die .p8 dorthin, wo altool sie sucht. Eine schon vorhandene Datei
# (z. B. lokal) bleibt unangetastet und wird auch nicht gelöscht.
install_key_file() {
    local missing=() name
    for name in NOTARY_API_KEY_P8_BASE64 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID; do
        if [ -z "${!name:-}" ]; then missing+=("$name"); fi
    done
    [ "${#missing[@]}" -eq 0 ] || die "API Key unvollständig, es fehlt: ${missing[*]}"
    [[ "$NOTARY_API_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || die "NOTARY_API_KEY_ID ist ungültig."
    local target="$ALTOOL_KEY_DIR/AuthKey_$NOTARY_API_KEY_ID.p8"
    if [ -f "$target" ]; then
        echo "==> $target existiert schon, wird verwendet"
        return 0
    fi
    (umask 077; mkdir -p "$ALTOOL_KEY_DIR")
    chmod 700 "$ALTOOL_KEY_DIR"
    trap remove_key_file EXIT
    KEY_FILE=$target
    (umask 077; printf '%s' "$NOTARY_API_KEY_P8_BASE64" | tr -d '[:space:]' \
        | base64 --decode > "$KEY_FILE") 2>/dev/null \
        || die "NOTARY_API_KEY_P8_BASE64 ist kein gültiges base64."
    chmod 600 "$KEY_FILE"
    grep -q -- '-----BEGIN PRIVATE KEY-----' "$KEY_FILE" || die "API Key ist keine .p8-Datei."
}

# Führt altool aus, zeigt die Ausgabe und wertet Exit-Code und Fehlerzeilen aus
# (ältere altool-Versionen enden bei manchen Fehlern trotzdem mit 0).
run_altool() {
    local what=$1; shift
    local out rc=0
    out=$(xcrun altool "$@" --apiKey "$NOTARY_API_KEY_ID" --apiIssuer "$NOTARY_API_ISSUER_ID" 2>&1) || rc=$?
    echo "$out"
    if [ "$rc" -ne 0 ] || grep -qE '(^|[^A-Za-z])(ERROR ITMS-[0-9]+|\*\*\* Error)' <<<"$out"; then
        if grep -qiE 'NOT_AUTHORIZED|FORBIDDEN|401|403|permission' <<<"$out"; then
            err "Apple lehnt den API Key ab oder er hat zu wenig Rechte. Der Key braucht die Rolle \"App Manager\" (oder höher), siehe dev/APPSTORE.md."
        fi
        if grep -qiE 'bundle version|CFBundleVersion|build number|previous' <<<"$out"; then
            err "Build-Nummer vermutlich nicht höher als beim letzten Upload (siehe dev/APPSTORE.md, \"Build-Nummer\")."
        fi
        die "altool $what fehlgeschlagen (Code $rc)."
    fi
}

require_altool() {
    xcrun --find altool >/dev/null 2>&1 \
        || die "altool fehlt (gehört zu Xcode, nicht zu den Command Line Tools). Xcode wählen: sudo xcode-select -s /Applications/Xcode.app"
}

cmd_validate() {
    require_altool
    local pkg
    pkg=$(pkg_path)
    [ -f "$pkg" ] || die "$pkg fehlt (vorher build)."
    install_key_file
    echo "==> altool --validate-app $pkg (API Key $NOTARY_API_KEY_ID)"
    run_altool validate --validate-app -f "$pkg" -t macos
    remove_key_file
    echo "==> Validierung erfolgreich"
}

cmd_upload() {
    require_altool
    local pkg help
    pkg=$(pkg_path)
    [ -f "$pkg" ] || die "$pkg fehlt (vorher build)."
    install_key_file
    help=$(xcrun altool --help 2>&1 || true)
    if grep -q -- '--upload-app' <<<"$help"; then
        echo "==> altool --upload-app $pkg (API Key $NOTARY_API_KEY_ID; dauert einige Minuten)"
        run_altool upload --upload-app -f "$pkg" -t macos
    else
        # Neuere altool-Versionen ohne --upload-app: --upload-package braucht die
        # numerische Apple ID der App (App Store Connect → App-Informationen),
        # als Repository-Variable APPSTORE_APP_ID.
        [ -n "${APPSTORE_APP_ID:-}" ] \
            || die "altool kennt --upload-app nicht mehr; für --upload-package die Apple ID der App als Variable APPSTORE_APP_ID setzen (Settings → Environments → appstore → Variables)."
        local plist="$APP/Contents/Info.plist" short bundle_version
        short=$(plutil -extract CFBundleShortVersionString raw "$plist")
        bundle_version=$(plutil -extract CFBundleVersion raw "$plist")
        echo "==> altool --upload-package $pkg (API Key $NOTARY_API_KEY_ID; dauert einige Minuten)"
        run_altool upload --upload-package "$pkg" -t macos --apple-id "$APPSTORE_APP_ID" \
            --bundle-id "$BUNDLE_ID" --bundle-version "$bundle_version" --bundle-short-version-string "$short"
    fi
    remove_key_file
    echo "==> Upload erfolgreich"
}

# --- submit ---------------------------------------------------------------------------
# Build-Nummer aus dem gebauten Bündel (wie hochgeladen), Rest in asc-submit.sh.
cmd_submit() {
    local build
    build=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist" 2>/dev/null || true)
    [ -n "$build" ] || die "CFBundleVersion von $APP nicht lesbar (vorher build)."
    BUILD_NUMBER=$build VERSION=$(version) ASC_STATE="$STATE/asc" scripts/asc-submit.sh submit
}

# --- summary / cleanup ---------------------------------------------------------------
cmd_summary() {
    local version build upload=${UPLOAD:-false} submit=${SUBMIT:-false} out=${GITHUB_STEP_SUMMARY:-/dev/stdout}
    version=$(version)
    pick_installer_identity "${DISKRINGS_KEYCHAIN:-$KEYCHAIN}"
    build=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist" 2>/dev/null || git rev-list --count HEAD)
    {
        echo "## DiskRings $version (Build $build) für den Mac App Store"
        echo
        echo "- Paket: \`$(pkg_path)\` (als Artefakt am Lauf, 1 Tag)"
        echo "- Signatur: $APPSTORE_IDENTITY / $INSTALLER_IDENTITY"
        echo "- Validierung durch App Store Connect: bestanden"
        if [ "$upload" = "true" ] && [ "$submit" = "true" ]; then
            echo "- **Hochgeladen und zur Prüfung eingereicht** (Details oben unter *Einreichung zur Prüfung*)."
            echo
            echo "### Nächste Schritte (von Hand)"
            echo
            echo "1. Auf die Prüfung warten (meist 1–3 Tage); Rückfragen von Apple in App Store Connect beantworten."
            echo "2. Bei manueller Veröffentlichung nach der Freigabe: **Diese Version veröffentlichen**."
        elif [ "$upload" = "true" ]; then
            echo "- **Hochgeladen.** Nach ca. 10–30 Minuten erscheint der Build in App Store Connect (E-Mail von Apple)."
            echo
            echo "### Nächste Schritte (von Hand)"
            echo
            echo "1. [App Store Connect](https://appstoreconnect.apple.com) → Apps → DiskRings → macOS-Version $version anlegen bzw. öffnen."
            echo "2. Unter **Build** den Build $build auswählen (optional vorher über TestFlight testen)."
            echo "3. **Zur Prüfung einreichen**."
        else
            echo "- **Trockenlauf: nicht hochgeladen.** Zum Hochladen den Workflow auf dem Tag \`v$version\` mit dry_run = false starten."
        fi
    } >> "$out"
}

cmd_cleanup() {
    if [ -n "${NOTARY_API_KEY_ID:-}" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
        # Nur in der CI: lokal könnte die Datei absichtlich dort liegen.
        rm -f "$ALTOOL_KEY_DIR/AuthKey_$NOTARY_API_KEY_ID.p8"
    fi
    rm -f "$PROFILE_FILE"
    rm -rf "$STATE/asc"
    cmd_keychain_cleanup
}

case "${1:-}" in
    preflight) cmd_preflight ;;
    keychain-setup) cmd_keychain_setup ;;
    build) cmd_build ;;
    validate) cmd_validate ;;
    upload) cmd_upload ;;
    submit) cmd_submit ;;
    summary) cmd_summary ;;
    cleanup) cmd_cleanup ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Aufruf: $0 preflight | keychain-setup | build | validate | upload | submit | summary | cleanup" >&2; exit 2 ;;
esac
