#!/bin/bash
# Hilfsschritte für den Release-Workflow (.github/workflows/release.yml).
# Lokal aufrufbar, um den Workflow nachzustellen (siehe dev/RELEASING.md).
#
#   scripts/ci-release.sh preflight         # Tag gegen VERSION, Secrets vorhanden?
#   scripts/ci-release.sh keychain-setup    # .p12 in eine temporäre Keychain importieren
#   scripts/ci-release.sh keychain-cleanup  # Keychain löschen, Suchliste wiederherstellen
#   scripts/ci-release.sh appcast           # Sparkle: ZIP signieren, dist/appcast.xml schreiben
#
# preflight liest: GITHUB_EVENT_NAME, GITHUB_REF_TYPE, GITHUB_REF_NAME, DRY_RUN
# (Eingabe von workflow_dispatch) und prüft, ob diese Secrets gesetzt sind:
# MACOS_CERTIFICATE_P12_BASE64, MACOS_CERTIFICATE_PASSWORD,
# NOTARY_API_KEY_P8_BASE64, NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID.
# Für automatische Updates (Sparkle) zusätzlich SPARKLE_ED_PRIVATE_KEY und die
# Datei Resources/sparkle-public-ed-key.txt: beim Veröffentlichen Pflicht, im
# Trockenlauf nur eine Warnung.
# Ausgabe nach GITHUB_OUTPUT: version, tag, publish (true/false).
#
# appcast liest SPARKLE_ED_PRIVATE_KEY (privater EdDSA-Schlüssel wie von
# `generate_keys -x`, nur über stdin an sign_update, nie auf der Platte; lokal
# ersatzweise der Schlüsselbund, Konto DISKRINGS_SPARKLE_ACCOUNT) und
# DISKRINGS_REQUIRE_APPCAST (true/1: fehlender Schlüssel ist ein Fehler, sonst
# Warnung und kein Appcast). Es lädt die Sparkle-Werkzeuge aus dem offiziellen
# Release-Archiv (Version und SHA-256 fest in scripts/sparkle-tools.sh;
# DISKRINGS_SPARKLE_ARCHIVE = schon geladene Datei, wird ebenso geprüft),
# signiert dist/DiskRings-<VERSION>.zip,
# prüft die Signatur gegen Resources/sparkle-public-ed-key.txt und den Schlüssel
# in build/DiskRings.app, schreibt dist/appcast.xml (scripts/make-appcast.sh)
# und ergänzt dist/SHA256SUMS. DISKRINGS_DIST und DISKRINGS_APP ersetzen dist/
# und build/DiskRings.app (Tests: scripts/test-make-appcast.sh).
#
# keychain-setup liest MACOS_CERTIFICATE_P12_BASE64, MACOS_CERTIFICATE_PASSWORD
# und DISKRINGS_IDENTITY (Standard: Developer ID von make-app.sh). Es legt die
# Keychain mit Zufallspasswort unter $DISKRINGS_CI_STATE an (Standard
# $RUNNER_TEMP/diskrings-release), entsperrt sie, setzt die Partition-List
# (codesign ohne Dialog), nimmt sie vorn in die Suchliste auf und schreibt
# DISKRINGS_KEYCHAIN nach GITHUB_ENV. DISKRINGS_REQUIRE_VALID_IDENTITY=1 verlangt
# zusätzlich eine gültige (vertrauenswürdige, nicht abgelaufene) Identität.
#
# scripts/ci-appstore.sh bindet dieses Skript mit `source` ein und nutzt die
# Funktionen (Keychain, Zwischenzertifikat, Ausgabe); die Befehle unten laufen
# nur beim direkten Aufruf.
#
# Kein `set -x`: Secrets dürfen nicht im Log landen.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IDENTITY=${DISKRINGS_IDENTITY:-"Developer ID Application: Stefan Richter (AGRWTKQZ8C)"}
STATE=${DISKRINGS_CI_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/diskrings-release}
KEYCHAIN="$STATE/diskrings-signing.keychain-db"
SEARCHLIST_FILE="$STATE/searchlist.orig"
# Zwischenzertifikat "Developer ID Certification Authority" (G2), SHA-256 von
# https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer (gültig bis 2031).
DEVID_G2_URL=https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
DEVID_G2_SHA256=F16CD3C54C7F83CEA4BF1A3E6A0819C8AAA8E4A1528FD144715F350643D2DF3A
# LibreSSL des Systems: erzeugt bzw. liest PKCS#12 so, wie `security` es versteht.
OPENSSL=/usr/bin/openssl
# Sparkle-Werkzeuge (sign_update): Version, Archiv und SHA-256 in scripts/sparkle-tools.sh.
# shellcheck source=scripts/sparkle-tools.sh
source "$(dirname "${BASH_SOURCE[0]}")/sparkle-tools.sh"
SPARKLE_PUBLIC_KEY_FILE=${DISKRINGS_UPDATE_KEY_FILE:-Resources/sparkle-public-ed-key.txt}
REPO_URL=https://github.com/brokoskokoli/diskrings
APPCAST_DIST=${DISKRINGS_DIST:-dist}
APPCAST_APP=${DISKRINGS_APP:-build/DiskRings.app}

err() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; else echo "error: $*" >&2; fi
}
die() { err "$*"; exit 1; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$*"; else echo "warning: $*" >&2; fi; }
# Öffentlicher Ed25519-Schlüssel: base64 von genau 32 Byte.
is_ed_public_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]] && [ "$(printf '%s' "$1" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')" = 32 ]
}
# Privater Schlüssel aus `generate_keys -x`: Standard-base64 mit korrektem Padding
# (macOS-base64 dekodiert auch URL-safe-Zeichen und Reste nach '=', sign_update
# nicht), dekodiert genau 32 Byte (Seed) oder 96 Byte (altes Format); nur diese
# beiden nimmt sign_update 2.10.0 an. Leerraum wird ignoriert (wie beim Signieren).
is_ed_private_key() {
    local k n
    k=$(printf '%s' "$1" | tr -d '[:space:]')
    [[ "$k" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || return 1
    n=$(printf '%s' "$k" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')
    [ "$n" = 32 ] || [ "$n" = 96 ]
}
read_public_key() { if [ -f "$SPARKLE_PUBLIC_KEY_FILE" ]; then tr -d '[:space:]' < "$SPARKLE_PUBLIC_KEY_FILE"; fi; }
gh_output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }

# --- preflight ---------------------------------------------------------------
missing_secrets_help() {
    local repo=${GITHUB_REPOSITORY:-brokoskokoli/diskrings}
    cat <<MSG

==============================================================================
 Release nicht möglich: Es fehlen Secrets.

 Fehlend: $*

 So richtest du sie einmalig ein (Details: dev/RELEASING.md):

 1. App Store Connect → Users and Access → Integrations → App Store Connect API
    → Team Keys: Key mit Rolle "Developer" anlegen, .p8 herunterladen (nur einmal möglich),
    Key-ID und Issuer-ID notieren.
 2. Auf dem Mac mit dem Developer-ID-Zertifikat im Schlüsselbund:

        scripts/setup-release-secrets.sh

    Das Skript exportiert das Zertifikat als .p12 und setzt alle Secrets per
    gh secret set im Environment "release" von $repo.
 3. Workflow erneut starten (Actions → Release → Re-run, oder Tag neu pushen).

 Manuell: Settings → Environments → release → Environment secrets:
   MACOS_CERTIFICATE_P12_BASE64  .p12 (Zertifikat + privater Schlüssel), base64
   MACOS_CERTIFICATE_PASSWORD    Passwort des .p12
   NOTARY_API_KEY_P8_BASE64      AuthKey_<KeyID>.p8, base64
   NOTARY_API_KEY_ID             Key-ID (10 Zeichen)
   NOTARY_API_ISSUER_ID          Issuer-ID (UUID)
==============================================================================
MSG
}

cmd_preflight() {
    local version tag publish=false event=${GITHUB_EVENT_NAME:-workflow_dispatch}
    local ref_type=${GITHUB_REF_TYPE:-branch} ref_name=${GITHUB_REF_NAME:-} dry_run=${DRY_RUN:-true}
    version=$(tr -d '[:space:]' < VERSION)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] \
        || die "VERSION enthält keine gültige Versionsnummer: '$version'"
    tag="v$version"

    if [ "$ref_type" = "tag" ]; then
        if [ "$ref_name" != "$tag" ]; then
            die "Tag '$ref_name' passt nicht zu VERSION ($version). Erwartet: $tag. VERSION erhöhen und committen, dann den passenden Tag pushen (alten Tag löschen: git push origin :refs/tags/$ref_name)."
        fi
    fi

    case "$event" in
        push)
            [ "$ref_type" = "tag" ] || die "Der Release-Workflow läuft bei push nur für Tags v*."
            publish=true ;;
        workflow_dispatch)
            if [ "$dry_run" = "true" ]; then
                publish=false
            elif [ "$ref_type" = "tag" ]; then
                publish=true
            else
                die "Veröffentlichen (dry_run = false) geht nur, wenn der Workflow auf einem Tag gestartet wird (\"Use workflow from\" → Tags → $tag). Für einen Probelauf dry_run anhaken."
            fi ;;
        *) die "Unerwartetes Ereignis: $event" ;;
    esac

    local missing=() name
    for name in MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD \
        NOTARY_API_KEY_P8_BASE64 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID; do
        if [ -z "${!name:-}" ]; then missing+=("$name"); fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        missing_secrets_help "${missing[*]}"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            { echo '```'; missing_secrets_help "${missing[*]}"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
        fi
        die "Secrets fehlen: ${missing[*]} (Anleitung siehe oben bzw. dev/RELEASING.md)"
    fi

    # Format grob prüfen, ohne Werte auszugeben.
    [[ "$NOTARY_API_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] \
        || die "NOTARY_API_KEY_ID sieht nicht wie eine Key-ID aus (10 Zeichen, A-Z und 0-9)."
    [[ "$NOTARY_API_ISSUER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || die "NOTARY_API_ISSUER_ID sieht nicht wie eine Issuer-ID aus (UUID)."
    # Erst einlesen, dann suchen: `grep -q` direkt in der Pipe kann unter pipefail
    # per SIGPIPE einen Fehler vortäuschen.
    local p8
    p8=$(printf '%s' "$NOTARY_API_KEY_P8_BASE64" | tr -d '[:space:]' | base64 --decode 2>/dev/null || true)
    grep -q -- '-----BEGIN PRIVATE KEY-----' <<<"$p8" \
        || die "NOTARY_API_KEY_P8_BASE64 ist keine base64-kodierte .p8-Datei (base64 -i AuthKey_….p8)."
    unset p8
    if ! printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | tr -d '[:space:]' | base64 --decode >/dev/null 2>&1; then
        die "MACOS_CERTIFICATE_P12_BASE64 ist kein gültiges base64 (base64 -i zertifikat.p12)."
    fi

    # Automatische Updates (Sparkle): Schlüssel für den Appcast.
    local sparkle_missing=() pubkey
    pubkey=$(read_public_key)
    if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
        sparkle_missing+=("Secret SPARKLE_ED_PRIVATE_KEY")
    elif ! is_ed_private_key "$SPARKLE_ED_PRIVATE_KEY"; then
        die "SPARKLE_ED_PRIVATE_KEY ist kein privater EdDSA-Schlüssel (Standard-base64 aus generate_keys -x, 32 oder 96 Byte)."
    fi
    if [ -z "$pubkey" ]; then
        sparkle_missing+=("$SPARKLE_PUBLIC_KEY_FILE (öffentlicher Schlüssel)")
    elif ! is_ed_public_key "$pubkey"; then
        die "$SPARKLE_PUBLIC_KEY_FILE enthält keinen gültigen öffentlichen EdDSA-Schlüssel (base64, 32 Byte)."
    fi
    if [ "${#sparkle_missing[@]}" -gt 0 ]; then
        local msg="Automatische Updates nicht eingerichtet, es fehlt: ${sparkle_missing[*]}. Einrichten mit scripts/setup-release-secrets.sh --sparkle (dev/RELEASING.md)."
        if [ "$publish" = "true" ]; then
            die "$msg Ohne appcast.xml bekämen Nutzer dieses Release nicht als Update."
        fi
        warn "$msg Trockenlauf ohne appcast.xml."
    fi

    echo "Version $version, Tag $tag, Ereignis $event, veröffentlichen: $publish"
    gh_output version "$version"
    gh_output tag "$tag"
    gh_output publish "$publish"
}

# --- keychain ----------------------------------------------------------------
# Gibt die Keychains der Nutzer-Suchliste zeilenweise aus (ohne Anführungszeichen).
user_searchlist() {
    security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

# Lädt ein Zwischenzertifikat von apple.com in die temporäre Keychain, falls es
# (mit genau dieser SHA-256-Summe) noch in keiner Keychain der Suchliste liegt.
#   ensure_intermediate <Common Name> <URL> <SHA-256 groß, ohne Doppelpunkte>
ensure_intermediate() {
    local cn=$1 url=$2 want=$3 found
    found=$(security find-certificate -a -c "$cn" -Z 2>/dev/null || true)
    if grep -q "SHA-256 hash: $want" <<<"$found"; then
        return 0
    fi
    echo "==> Zwischenzertifikat \"$cn\" fehlt, lade es von apple.com"
    local cer sum
    cer="$STATE/$(basename "$url")"
    curl -fsSL --retry 3 -o "$cer" "$url" || die "Download von $url fehlgeschlagen."
    sum=$(shasum -a 256 "$cer" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')
    [ "$sum" = "$want" ] || die "Prüfsumme des Zwischenzertifikats $url stimmt nicht ($sum)."
    security import "$cer" -k "$KEYCHAIN" >/dev/null
}

ensure_devid_intermediate() {
    ensure_intermediate "Developer ID Certification Authority" "$DEVID_G2_URL" "$DEVID_G2_SHA256"
}

# Legt die temporäre Keychain an und importiert ein oder mehrere base64-kodierte
# .p12 (alle mit demselben Passwort) nacheinander in dieselbe Keychain.
#   keychain_import <Hinweis bei Fehlern> <Variable mit dem Passwort> <Variable mit dem .p12>...
# Mehrere .p12 statt eines zusammengeführten: Teilen sich zwei Zertifikate einen
# privaten Schlüssel (z. B. "Apple Distribution" und "3rd Party Mac Developer
# Installer" aus derselben CSR), ordnet `security import` den Schlüssel aus EINEM
# .p12 nur einem der Zertifikate zu. Getrennt importiert sind beide Identitäten da.
keychain_import() {
    local hint=$1 pass_var=$2 p12_var; shift 2
    [ "$#" -gt 0 ] || die "keychain_import: kein .p12 angegeben."
    for p12_var in "$@"; do
        [ -n "${!p12_var:-}" ] || die "$p12_var fehlt."
    done
    [ -n "${!pass_var:-}" ] || die "$pass_var fehlt."
    [ ! -e "$KEYCHAIN" ] || die "Keychain existiert schon: $KEYCHAIN (vorher keychain-cleanup)."
    mkdir -p "$STATE"
    chmod 700 "$STATE"

    local kc_pass p12="$STATE/cert.p12"
    kc_pass=$($OPENSSL rand -base64 32)
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$kc_pass"; fi

    # Erst alle Secrets prüfen (früh scheitern), dann die Keychain anlegen.
    for p12_var in "$@"; do
        printf '%s' "${!p12_var}" | tr -d '[:space:]' | base64 --decode >/dev/null 2>&1 \
            || die "$p12_var ist kein gültiges base64."
    done

    echo "==> Temporäre Keychain $KEYCHAIN"
    user_searchlist > "$SEARCHLIST_FILE"
    security create-keychain -p "$kc_pass" "$KEYCHAIN"
    # Sperren nach 6 h Inaktivität bzw. beim Ruhezustand; der Job ist längst vorher fertig.
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$kc_pass" "$KEYCHAIN"

    for p12_var in "$@"; do
        echo "==> .p12 importieren ($p12_var)"
        (umask 077; printf '%s' "${!p12_var}" | tr -d '[:space:]' | base64 --decode > "$p12") 2>/dev/null \
            || { rm -f "$p12"; die "$p12_var ist kein gültiges base64."; }
        if ! security import "$p12" -k "$KEYCHAIN" -f pkcs12 -P "${!pass_var}" \
            -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign \
            >/dev/null 2>"$STATE/import.err"; then
            # Schlüssel schon aus einem vorigen .p12 da (errSecDuplicateItem, -25299):
            # kein Fehler; ob die Identitäten vollständig sind, prüft require_identity.
            if grep -qiE 'already exists|-25299|duplicate' "$STATE/import.err"; then
                echo "    (Teile schon vorhanden, z. B. der gemeinsame Schlüssel; wird danach geprüft)"
            else
                rm -f "$p12"
                sed 's/^/    /' "$STATE/import.err" >&2
                rm -f "$STATE/import.err"
                die "Import von $p12_var fehlgeschlagen. Falsches $pass_var oder beschädigtes .p12? $hint"
            fi
        fi
        rm -f "$p12" "$STATE/import.err"
    done

    # Partition-List (nach allen Importen): codesign (apple-tool:, codesign:) darf
    # die Schlüssel ohne Dialog nutzen.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$KEYCHAIN" >/dev/null

    # Vorn in die Suchliste, damit codesign die Kette (Zwischenzertifikat) findet.
    local list=()
    while IFS= read -r line; do [ -n "$line" ] && list+=("$line"); done < "$SEARCHLIST_FILE"
    security list-keychains -d user -s "$KEYCHAIN" ${list[@]+"${list[@]}"}
}

# Prüft, dass die Keychain die Identität (Zertifikat + privater Schlüssel) enthält.
#   require_identity <Name> [Policy, Standard codesigning]
# DISKRINGS_REQUIRE_VALID_IDENTITY=1: zusätzlich gültig (vertrauenswürdig, nicht abgelaufen).
require_identity() {
    local identity=$1 policy=${2:-codesigning} all valid
    all=$(security find-identity -p "$policy" "$KEYCHAIN")
    if ! grep -qF "\"$identity\"" <<<"$all"; then
        echo "Gefundene Identitäten in der Keychain (Policy $policy):" >&2
        grep -E '^[[:space:]]+[0-9]+\)' <<<"$all" | sed 's/^/    /' >&2 || echo "    (keine)" >&2
        die "Die importierten .p12 enthalten nicht die Identität \"$identity\" (mit privatem Schlüssel)."
    fi
    valid=$(security find-identity -v -p "$policy" "$KEYCHAIN")
    if ! grep -qF "\"$identity\"" <<<"$valid"; then
        if [ "${DISKRINGS_REQUIRE_VALID_IDENTITY:-0}" = "1" ]; then
            die "Identität \"$identity\" ist nicht gültig (abgelaufen, widerrufen oder Kette unvollständig)."
        fi
        echo "warning: Identität \"$identity\" ist nicht als gültig markiert (z. B. selbst signiert)." >&2
    fi
    echo "==> Identität \"$identity\" bereit"
}

# DISKRINGS_KEYCHAIN für die folgenden Schritte bekannt machen.
export_keychain_env() {
    if [ -n "${GITHUB_ENV:-}" ]; then echo "DISKRINGS_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"; fi
    echo "DISKRINGS_KEYCHAIN=$KEYCHAIN"
}

cmd_keychain_setup() {
    keychain_import "Neu erzeugen mit scripts/setup-release-secrets.sh." \
        MACOS_CERTIFICATE_PASSWORD MACOS_CERTIFICATE_P12_BASE64
    ensure_devid_intermediate
    require_identity "$IDENTITY"
    export_keychain_env
}

cmd_keychain_cleanup() {
    if [ -f "$SEARCHLIST_FILE" ]; then
        local list=()
        while IFS= read -r line; do
            # Die temporäre Keychain selbst nie wieder aufnehmen.
            [ -n "$line" ] && [ "$line" != "$KEYCHAIN" ] && list+=("$line")
        done < "$SEARCHLIST_FILE"
        security list-keychains -d user -s ${list[@]+"${list[@]}"}
        echo "==> Suchliste wiederhergestellt"
    fi
    if [ -e "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" || rm -f "$KEYCHAIN"
        echo "==> Keychain gelöscht"
    fi
    rm -rf "$STATE"
    # Reste von scripts/notarize.sh, falls ein Lauf hart abgebrochen wurde (nur in der CI).
    if [ -n "${RUNNER_TEMP:-}" ]; then
        find "$RUNNER_TEMP" -maxdepth 1 -name 'notary-key.*' -exec rm -rf {} + 2>/dev/null || true
    fi
}

# --- appcast (Sparkle) ---------------------------------------------------------
cmd_appcast() {
    local require=0
    case "${DISKRINGS_REQUIRE_APPCAST:-false}" in 1|true) require=1 ;; esac
    local version zip pubkey
    version=$(tr -d '[:space:]' < VERSION)
    zip="$APPCAST_DIST/DiskRings-$version.zip"
    pubkey=$(read_public_key)

    # Schlüsselquelle: Secret/Umgebung, lokal ersatzweise der Schlüsselbund
    # (DISKRINGS_SPARKLE_ACCOUNT, von scripts/release.sh gesetzt; nie in der CI).
    local key_source=""
    if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
        key_source="env"
    elif [ -z "${GITHUB_ACTIONS:-}" ] && [ -n "${DISKRINGS_SPARKLE_ACCOUNT:-}" ]; then
        key_source="keychain"
    fi
    if [ -z "$key_source" ] || [ -z "$pubkey" ]; then
        local msg="Kein appcast.xml: SPARKLE_ED_PRIVATE_KEY oder $SPARKLE_PUBLIC_KEY_FILE fehlt (scripts/setup-release-secrets.sh --sparkle)."
        if [ "$require" = 1 ]; then die "$msg"; fi
        warn "$msg"
        return 0
    fi
    is_ed_public_key "$pubkey" || die "$SPARKLE_PUBLIC_KEY_FILE enthält keinen gültigen öffentlichen EdDSA-Schlüssel."
    if [ "$key_source" = env ]; then
        is_ed_private_key "$SPARKLE_ED_PRIVATE_KEY" \
            || die "SPARKLE_ED_PRIVATE_KEY ist kein privater EdDSA-Schlüssel (Standard-base64 aus generate_keys -x, 32 oder 96 Byte)."
    fi
    [ -f "$zip" ] || die "$zip fehlt (vorher scripts/release.sh)."
    [ -f "$APPCAST_APP/Contents/Info.plist" ] || die "$APPCAST_APP fehlt (vorher scripts/release.sh)."

    local build app_key app_version
    build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APPCAST_APP/Contents/Info.plist")
    app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APPCAST_APP/Contents/Info.plist")
    app_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APPCAST_APP/Contents/Info.plist" 2>/dev/null || true)
    [ "$app_version" = "$version" ] || die "$APPCAST_APP hat Version $app_version, VERSION sagt $version."
    [ "$app_key" = "$pubkey" ] \
        || die "SUPublicEDKey in $APPCAST_APP passt nicht zu $SPARKLE_PUBLIC_KEY_FILE (App neu bauen)."

    # Eigenes Arbeitsverzeichnis, nur für uns lesbar, am Ende gelöscht.
    local work
    work=$(umask 077; mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/diskrings-appcast.XXXXXX")
    # cmd_appcast ist der letzte Befehl des Aufrufs; `die` beendet mit exit.
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    local sign_update="$work/tools/bin/sign_update"
    if [ -n "${DISKRINGS_SIGN_UPDATE:-}" ]; then
        # Nur für scripts/test-make-appcast.sh (Attrappe); die Signatur wird unten
        # ohnehin gegen den öffentlichen Schlüssel geprüft.
        [ -z "${GITHUB_ACTIONS:-}" ] || die "DISKRINGS_SIGN_UPDATE ist nur für lokale Tests erlaubt."
        sign_update=$DISKRINGS_SIGN_UPDATE
    else
        sparkle_fetch_tools "$work" sign_update || die "Sparkle-Werkzeuge nicht verfügbar."
    fi

    echo "==> sign_update $zip ($key_source)"
    local sig rc=0
    if [ "$key_source" = env ]; then
        # Schlüssel nur über stdin (nie als Argument oder Datei), Ausgabe nur die Signatur.
        sig=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | tr -d '[:space:]' \
            | "$sign_update" --ed-key-file - -p "$zip" 2>"$work/sign.err") || rc=$?
    else
        # macOS fragt evtl., ob sign_update den Schlüsselbund-Eintrag lesen darf.
        sig=$("$sign_update" --account "$DISKRINGS_SPARKLE_ACCOUNT" -p "$zip" 2>"$work/sign.err") || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        # stderr von sign_update nie ausgeben: Bei kaputtem Schlüssel steht er dort im Klartext.
        if [ "$key_source" = keychain ] && [ "$require" != 1 ]; then
            warn "Kein appcast.xml: Kein Sparkle-Schlüssel im Schlüsselbund (Konto $DISKRINGS_SPARKLE_ACCOUNT)."
            return 0
        fi
        die "sign_update fehlgeschlagen (Code $rc; Ausgabe unterdrückt, weil sie Schlüsselmaterial enthalten kann). Schlüssel vorhanden und richtig?"
    fi
    sig=$(printf '%s' "$sig" | tr -d '[:space:]')

    echo "==> Signatur gegen den öffentlichen Schlüssel der App prüfen"
    swiftc -O scripts/sparkle-ed25519.swift -o "$work/sparkle-ed25519" >/dev/null 2>"$work/swiftc.err" \
        || { cat "$work/swiftc.err" >&2; die "scripts/sparkle-ed25519.swift lässt sich nicht kompilieren."; }
    "$work/sparkle-ed25519" verify "$pubkey" "$sig" "$zip" >/dev/null \
        || die "Die Signatur passt nicht zu $SPARKLE_PUBLIC_KEY_FILE: Der private Schlüssel gehört zu einem anderen Schlüsselpaar. Nutzer könnten dieses Update nicht installieren."

    local length notes=() tag="v$version"
    length=$(stat -f %z "$zip")
    if [ -f "dev/release-notes/$version.en.txt" ]; then notes=(--notes-file "dev/release-notes/$version.en.txt"); fi
    echo "==> $APPCAST_DIST/appcast.xml (Version $version, Build $build, $length Byte)"
    scripts/make-appcast.sh --version "$version" --build "$build" \
        --url "$REPO_URL/releases/download/$tag/DiskRings-$version.zip" \
        --length "$length" --signature "$sig" --min-system 14.0 \
        --notes-url "$REPO_URL/releases/tag/$tag" ${notes[@]+"${notes[@]}"} > "$work/appcast.xml"
    if command -v xmllint >/dev/null; then xmllint --noout "$work/appcast.xml" || die "appcast.xml ist kein gültiges XML."; fi
    cp "$work/appcast.xml" "$APPCAST_DIST/appcast.xml"
    chmod 644 "$APPCAST_DIST/appcast.xml"
    if [ -f "$APPCAST_DIST/SHA256SUMS" ]; then
        grep -v ' appcast.xml$' "$APPCAST_DIST/SHA256SUMS" > "$work/sums" || true
        (cd "$APPCAST_DIST" && shasum -a 256 appcast.xml) >> "$work/sums"
        cp "$work/sums" "$APPCAST_DIST/SHA256SUMS"
        chmod 644 "$APPCAST_DIST/SHA256SUMS"
    fi
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        { echo '### appcast.xml'; echo '```xml'; cat "$APPCAST_DIST/appcast.xml"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
    fi
    cat "$APPCAST_DIST/appcast.xml"
}

# Beim Einbinden mit `source` (scripts/ci-appstore.sh) nur die Funktionen.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        preflight) cmd_preflight ;;
        keychain-setup) cmd_keychain_setup ;;
        keychain-cleanup) cmd_keychain_cleanup ;;
        appcast) cmd_appcast ;;
        -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) echo "Aufruf: $0 preflight | keychain-setup | keychain-cleanup | appcast" >&2; exit 2 ;;
    esac
fi
