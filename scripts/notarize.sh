#!/bin/bash
# Notarisierung über notarytool, gemeinsam für scripts/release.sh (lokal) und
# den Release-Workflow (.github/workflows/release.yml).
#
#   scripts/notarize.sh check          # Zugangsdaten prüfen (notarytool history)
#   scripts/notarize.sh submit <datei> # einreichen, warten, bei Ablehnung Protokoll zeigen
#
# Zwei Wege, ausgewählt über die Umgebung:
#
# 1. App Store Connect API Key (CI, auch lokal möglich), wenn NOTARY_API_KEY_ID
#    gesetzt ist:
#      NOTARY_API_KEY_ID         Key-ID (10 Zeichen)
#      NOTARY_API_ISSUER_ID      Issuer-ID (UUID)
#      NOTARY_API_KEY_PATH       Pfad zur .p8-Datei, oder
#      NOTARY_API_KEY_P8_BASE64  Inhalt der .p8 base64-kodiert; wird nur für die
#                                Dauer des Aufrufs in eine temporäre Datei (0600)
#                                geschrieben und danach gelöscht.
# 2. Schlüsselbund-Profil (lokal, Standard): DISKRINGS_NOTARY_PROFILE, Standard
#    "diskrings", angelegt mit `xcrun notarytool store-credentials`.
#
# Zugangsdaten werden nie ausgegeben; das Skript nutzt kein `set -x`.
set -euo pipefail

PROFILE=${DISKRINGS_NOTARY_PROFILE:-diskrings}
TEAM_ID=AGRWTKQZ8C
TIMEOUT=${DISKRINGS_NOTARY_CHECK_TIMEOUT:-60}

die() { echo "error: $*" >&2; exit 1; }

# Führt einen Befehl mit Zeitlimit aus (Schlüsselbund-Dialoge können ihn sonst
# unbemerkt hängen lassen). 124 = Zeitüberschreitung.
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

TMP_KEY_DIR=
cleanup() { if [ -n "$TMP_KEY_DIR" ]; then rm -rf "$TMP_KEY_DIR"; fi; }
trap cleanup EXIT

# Setzt AUTH (Argumente für notarytool) und METHOD.
AUTH=()
METHOD=
setup_auth() {
    if [ -n "${NOTARY_API_KEY_ID:-}" ] || [ -n "${NOTARY_API_ISSUER_ID:-}" ] \
        || [ -n "${NOTARY_API_KEY_PATH:-}" ] || [ -n "${NOTARY_API_KEY_P8_BASE64:-}" ]; then
        local missing=() key_path=${NOTARY_API_KEY_PATH:-}
        [ -n "${NOTARY_API_KEY_ID:-}" ] || missing+=(NOTARY_API_KEY_ID)
        [ -n "${NOTARY_API_ISSUER_ID:-}" ] || missing+=(NOTARY_API_ISSUER_ID)
        [ -n "$key_path" ] || [ -n "${NOTARY_API_KEY_P8_BASE64:-}" ] \
            || missing+=("NOTARY_API_KEY_PATH oder NOTARY_API_KEY_P8_BASE64")
        if [ "${#missing[@]}" -gt 0 ]; then
            die "API-Key-Notarisierung unvollständig, es fehlt: ${missing[*]}"
        fi
        if [ -z "$key_path" ]; then
            TMP_KEY_DIR=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/notary-key.XXXXXX")
            chmod 700 "$TMP_KEY_DIR"
            key_path="$TMP_KEY_DIR/AuthKey.p8"
            (umask 077; printf '%s' "$NOTARY_API_KEY_P8_BASE64" | tr -d '[:space:]' \
                | base64 --decode > "$key_path") 2>/dev/null \
                || die "NOTARY_API_KEY_P8_BASE64 ist kein gültiges base64."
        fi
        [ -r "$key_path" ] || die "API-Key-Datei nicht lesbar: $key_path"
        grep -q -- '-----BEGIN PRIVATE KEY-----' "$key_path" \
            || die "API-Key ist keine .p8-Datei (erwartet '-----BEGIN PRIVATE KEY-----')."
        AUTH=(--key "$key_path" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
        METHOD="API-Key $NOTARY_API_KEY_ID"
    else
        AUTH=(--keychain-profile "$PROFILE")
        METHOD="Schlüsselbund-Profil \"$PROFILE\""
    fi
}

help_profile() {
    cat >&2 <<MSG

error: Notarisierung nicht möglich: Profil "$PROFILE" fehlt oder ist ungültig.

Weg A: Schlüsselbund-Profil (lokal). Einmalig anlegen, fragt nach einem
app-spezifischen Passwort (https://account.apple.com → Anmeldung und
Sicherheit → App-spezifische Passwörter):

    xcrun notarytool store-credentials $PROFILE --apple-id <deine-apple-id> --team-id $TEAM_ID

Weg B: App Store Connect API Key (wie im Release-Workflow), siehe docs/RELEASING.md:

    export NOTARY_API_KEY_ID=… NOTARY_API_ISSUER_ID=… NOTARY_API_KEY_PATH=~/…/AuthKey_….p8
MSG
}

help_api_key() {
    cat >&2 <<MSG

error: Notarisierung nicht möglich: Apple lehnt den API-Key ab ($METHOD).

Prüfen (siehe docs/RELEASING.md):
  - Key-ID und Issuer-ID stimmen (App Store Connect → Users and Access →
    Integrations → Team Keys; die Issuer-ID steht über der Liste).
  - Der Key ist ein Team Key (kein Individual Key) mit Rolle "Developer"
    oder höher und nicht widerrufen.
  - Die .p8 gehört zu genau dieser Key-ID.
MSG
}

cmd_check() {
    setup_auth
    echo "==> Notarisierung: $METHOD prüfen"
    local rc=0 out
    out=$(run_with_timeout "$TIMEOUT" xcrun notarytool history "${AUTH[@]}" 2>&1) || rc=$?
    if [ "$rc" -eq 124 ]; then
        die "notarytool hat nach ${TIMEOUT} s nicht geantwortet (Schlüsselbund-Dialog?)."
    elif [ "$rc" -ne 0 ]; then
        echo "notarytool meldet:" >&2
        tail -n 5 <<<"$out" | sed 's/^/    /' >&2
        if [ "${AUTH[0]}" = "--keychain-profile" ]; then help_profile; else help_api_key; fi
        exit 1
    fi
}

cmd_submit() {
    local file=$1 out id
    [ -f "$file" ] || die "Datei fehlt: $file"
    setup_auth
    echo "==> notarytool submit $file ($METHOD; wartet auf Apple, meist wenige Minuten)"
    out=$(xcrun notarytool submit "$file" "${AUTH[@]}" --wait 2>&1) || true
    echo "$out"
    if ! grep -q "status: Accepted" <<<"$out"; then
        id=$(grep -m1 -Eo 'id: [0-9a-f-]{36}' <<<"$out" | cut -d' ' -f2 || true)
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" "${AUTH[@]}" >&2 || true
        fi
        die "Notarisierung von $file nicht akzeptiert."
    fi
}

case "${1:-}" in
    check) cmd_check ;;
    submit) [ $# -eq 2 ] || die "Aufruf: $0 submit <datei>"; cmd_submit "$2" ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Aufruf: $0 check | submit <datei>" >&2; exit 2 ;;
esac
