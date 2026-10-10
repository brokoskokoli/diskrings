#!/bin/bash
# Hilfsschritte für den Release-Workflow (.github/workflows/release.yml).
# Lokal aufrufbar, um den Workflow nachzustellen (siehe dev/RELEASING.md).
#
#   scripts/ci-release.sh preflight         # Tag gegen VERSION, Secrets vorhanden?
#   scripts/ci-release.sh keychain-setup    # .p12 in eine temporäre Keychain importieren
#   scripts/ci-release.sh keychain-cleanup  # Keychain löschen, Suchliste wiederherstellen
#
# preflight liest: GITHUB_EVENT_NAME, GITHUB_REF_TYPE, GITHUB_REF_NAME, DRY_RUN
# (Eingabe von workflow_dispatch) und prüft, ob diese Secrets gesetzt sind:
# MACOS_CERTIFICATE_P12_BASE64, MACOS_CERTIFICATE_PASSWORD,
# NOTARY_API_KEY_P8_BASE64, NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID.
# Ausgabe nach GITHUB_OUTPUT: version, tag, publish (true/false).
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

err() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; else echo "error: $*" >&2; fi
}
die() { err "$*"; exit 1; }
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

# Legt die temporäre Keychain an und importiert ein base64-kodiertes .p12.
#   keychain_import <Name der Variable mit dem .p12> <Name der Variable mit dem Passwort> <Hinweis bei Fehlern>
keychain_import() {
    local p12_var=$1 pass_var=$2 hint=$3
    [ -n "${!p12_var:-}" ] || die "$p12_var fehlt."
    [ -n "${!pass_var:-}" ] || die "$pass_var fehlt."
    [ ! -e "$KEYCHAIN" ] || die "Keychain existiert schon: $KEYCHAIN (vorher keychain-cleanup)."
    mkdir -p "$STATE"
    chmod 700 "$STATE"

    local kc_pass p12="$STATE/cert.p12"
    kc_pass=$($OPENSSL rand -base64 32)
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$kc_pass"; fi

    (umask 077; printf '%s' "${!p12_var}" | tr -d '[:space:]' \
        | base64 --decode > "$p12") 2>/dev/null \
        || { rm -f "$p12"; die "$p12_var ist kein gültiges base64."; }

    echo "==> Temporäre Keychain $KEYCHAIN"
    user_searchlist > "$SEARCHLIST_FILE"
    security create-keychain -p "$kc_pass" "$KEYCHAIN"
    # Sperren nach 6 h Inaktivität bzw. beim Ruhezustand; der Job ist längst vorher fertig.
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$kc_pass" "$KEYCHAIN"

    echo "==> .p12 importieren"
    if ! security import "$p12" -k "$KEYCHAIN" -f pkcs12 -P "${!pass_var}" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign \
        >/dev/null 2>"$STATE/import.err"; then
        rm -f "$p12"
        sed 's/^/    /' "$STATE/import.err" >&2
        die "Import des .p12 fehlgeschlagen. Falsches $pass_var oder beschädigtes .p12? $hint"
    fi
    rm -f "$p12" "$STATE/import.err"

    # Partition-List: codesign (apple-tool:, codesign:) darf den Schlüssel ohne Dialog nutzen.
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
        echo "Gefundene Identitäten im .p12 (Policy $policy):" >&2
        grep -E '^[[:space:]]+[0-9]+\)' <<<"$all" | sed 's/^/    /' >&2 || echo "    (keine)" >&2
        die "Das .p12 enthält nicht die Identität \"$identity\" (mit privatem Schlüssel)."
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
    keychain_import MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD \
        "Neu erzeugen mit scripts/setup-release-secrets.sh."
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

# Beim Einbinden mit `source` (scripts/ci-appstore.sh) nur die Funktionen.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        preflight) cmd_preflight ;;
        keychain-setup) cmd_keychain_setup ;;
        keychain-cleanup) cmd_keychain_cleanup ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) echo "Aufruf: $0 preflight | keychain-setup | keychain-cleanup" >&2; exit 2 ;;
    esac
fi
