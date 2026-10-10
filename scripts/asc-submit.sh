#!/bin/bash
# Reicht einen hochgeladenen Build über die App Store Connect API zur Prüfung
# ein (Workflow "App Store Upload", Eingabe submit_for_review; dev/APPSTORE.md).
#
#   scripts/asc-submit.sh check-notes [VERSION]   # Release Notes vorhanden, nicht leer, ≤ 4000 Zeichen?
#   scripts/asc-submit.sh submit                  # warten, Version, "Neu", Build, einreichen
#
# submit macht nacheinander:
#   1. App-ID: APPSTORE_APP_ID oder GET /v1/apps?filter[bundleId]=…
#   2. Build abwarten: GET /v1/builds?… bis processingState VALID (INVALID/FAILED: Fehler),
#      alle ASC_POLL_INTERVAL Sekunden, höchstens ASC_POLL_ATTEMPTS Mal (Standard 60 × 60 s).
#   3. App-Store-Version MAC_OS/<VERSION> suchen; sonst eine noch bearbeitbare macOS-Version
#      umbenennen (Apple erlaubt nur eine); sonst anlegen. releaseType MANUAL, mit
#      RELEASE_AFTER_APPROVAL=true AFTER_APPROVAL. Ist sie schon eingereicht, in Prüfung
#      oder freigegeben: Hinweis, Ende ohne Fehler.
#   4. "Neu in dieser Version" (whatsNew) für en-US und de-DE aus
#      dev/release-notes/<VERSION>.en.txt bzw. .de.txt setzen (PATCH oder POST).
#   5. Build an die Version hängen (PATCH …/relationships/build).
#   6. reviewSubmission anlegen oder eine offene (READY_FOR_REVIEW) wiederverwenden,
#      Version als Item hinzufügen, mit submitted: true einreichen.
#
# Eingaben (Umgebung):
#   ASC_KEY_ID, ASC_ISSUER_ID       Key-ID und Issuer-ID (sonst NOTARY_API_KEY_ID/_ISSUER_ID)
#   ASC_KEY_PATH                    .p8-Datei (sonst NOTARY_API_KEY_P8_BASE64, wird
#                                   nur für die Laufzeit nach $ASC_STATE geschrieben)
#   BUILD_NUMBER                    CFBundleVersion des hochgeladenen Builds (Pflicht)
#   VERSION                         Standard: Datei VERSION
#   APPSTORE_APP_ID                 numerische Apple ID der App (optional)
#   RELEASE_AFTER_APPROVAL          true: nach der Freigabe automatisch veröffentlichen
#   ASC_NOTES_DIR                   Standard dev/release-notes
#   ASC_API_BASE                    Standard https://api.appstoreconnect.apple.com (Tests: Mock)
#   ASC_JWT_CMD                     Befehl, der ein Token ausgibt (Tests); Standard: kompiliertes
#                                   scripts/asc-jwt.swift
#   ASC_TOKEN_MAX_AGE (900 s), ASC_RETRIES (5), ASC_RETRY_SLEEP (5 s), ASC_POLL_INTERVAL,
#   ASC_POLL_ATTEMPTS, ASC_STATE (Arbeitsverzeichnis, Standard $RUNNER_TEMP/diskrings-asc)
#
# API: https://developer.apple.com/documentation/appstoreconnectapi
# Braucht curl und jq (beides auf den macOS-Runnern von GitHub und ab macOS 15 im System).
# Kein `set -x`: Token und Schlüssel dürfen nicht ins Log.
# jq-Ausdrücke stehen absichtlich in einfachen Anführungszeichen ($var sind jq-Variablen).
# shellcheck disable=SC2016
set -euo pipefail

ASC_BUNDLE_ID=${ASC_BUNDLE_ID:-de.stefanrichter.DiskRings}
ASC_PLATFORM=MAC_OS
ASC_API_BASE=${ASC_API_BASE:-https://api.appstoreconnect.apple.com}
ASC_NOTES_DIR=${ASC_NOTES_DIR:-dev/release-notes}
ASC_NOTES_MAX=4000
ASC_TOKEN_MAX_AGE=${ASC_TOKEN_MAX_AGE:-900}
ASC_RETRIES=${ASC_RETRIES:-5}
ASC_RETRY_SLEEP=${ASC_RETRY_SLEEP:-5}
ASC_POLL_INTERVAL=${ASC_POLL_INTERVAL:-60}
ASC_POLL_ATTEMPTS=${ASC_POLL_ATTEMPTS:-60}
ASC_STATE=${ASC_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/diskrings-asc}
# Dateiendung der Release Notes → Locale in App Store Connect.
ASC_NOTE_SUFFIXES=(en de)

asc_err() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; else echo "error: $*" >&2; fi
}
asc_warn() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$*"; else echo "warning: $*" >&2; fi
}
asc_die() { asc_err "$*"; asc_summary "- **Fehler:** $*"; exit 1; }
asc_log() { echo "==> $*"; }

# Zeilen für die Zusammenfassung sammeln; asc_flush_summary schreibt sie am Ende.
ASC_SUMMARY_FILE=
asc_summary() {
    if [ -n "$ASC_SUMMARY_FILE" ]; then echo "$*" >> "$ASC_SUMMARY_FILE"; fi
}

asc_locale_for() {
    case "$1" in
        en) echo en-US ;;
        de) echo de-DE ;;
        *) return 1 ;;
    esac
}

asc_version() {
    if [ -n "${VERSION:-}" ]; then echo "$VERSION"; else tr -d '[:space:]' < VERSION; fi
}

# --- Release Notes --------------------------------------------------------------
# Text ohne Leerraum am Ende als JSON-String (so geht er an Apple). --rawfile statt
# -Rs: jq 1.7 zerlegt bei -R Umlaute an Puffergrenzen (aus Tests).
asc_note_json() { jq -n --rawfile t "$1" '$t | sub("\\s+$"; "")'; }

# Prüft dev/release-notes/<VERSION>.<en|de>.txt (vorhanden, nicht leer, ≤ 4000 Zeichen,
# keine Platzhalter <…> der Vorlage); meldet alle Probleme auf einmal.
asc_check_notes() {
    local version=$1 suffix file len problems=()
    for suffix in "${ASC_NOTE_SUFFIXES[@]}"; do
        file="$ASC_NOTES_DIR/$version.$suffix.txt"
        if [ ! -f "$file" ]; then
            problems+=("$file fehlt")
            continue
        fi
        # Zeichen (Unicode-Codepunkte), nicht Bytes; Leerraum am Ende zählt nicht.
        len=$(asc_note_json "$file" | jq 'length')
        if ! jq -ne --rawfile t "$file" '$t | test("\\S")' >/dev/null; then
            problems+=("$file ist leer")
        elif [ "$len" -gt "$ASC_NOTES_MAX" ]; then
            problems+=("$file hat $len Zeichen (höchstens $ASC_NOTES_MAX)")
        elif jq -ne --rawfile t "$file" '$t | test("<[^<>\\n]+>")' >/dev/null; then
            problems+=("$file enthält noch Platzhalter <…> aus der Vorlage")
        fi
    done
    if [ "${#problems[@]}" -gt 0 ]; then
        local p
        for p in "${problems[@]}"; do asc_err "Release Notes: $p"; done
        asc_err "Für submit_for_review braucht es $ASC_NOTES_DIR/$version.en.txt und $version.de.txt (Vorlage: $ASC_NOTES_DIR/TEMPLATE.*.txt, siehe $ASC_NOTES_DIR/README.md)."
        return 1
    fi
    echo "Release Notes für $version: ok (${ASC_NOTE_SUFFIXES[*]})"
}

# --- Token ---------------------------------------------------------------------------
ASC_TOKEN=
ASC_TOKEN_TIME=0
ASC_KEY_FILE_CREATED=
ASC_JWT_BIN=

asc_cleanup() {
    if [ -n "$ASC_KEY_FILE_CREATED" ]; then rm -f "$ASC_KEY_FILE_CREATED"; fi
    rm -f "$ASC_STATE/auth-header" "$ASC_STATE/response.json"
}

asc_prepare_key() {
    ASC_KEY_ID=${ASC_KEY_ID:-${NOTARY_API_KEY_ID:-}}
    ASC_ISSUER_ID=${ASC_ISSUER_ID:-${NOTARY_API_ISSUER_ID:-}}
    if [ -n "${ASC_JWT_CMD:-}" ]; then return 0; fi
    [ -n "$ASC_KEY_ID" ] || asc_die "ASC_KEY_ID bzw. NOTARY_API_KEY_ID fehlt."
    [ -n "$ASC_ISSUER_ID" ] || asc_die "ASC_ISSUER_ID bzw. NOTARY_API_ISSUER_ID fehlt."
    if [ -z "${ASC_KEY_PATH:-}" ]; then
        [ -n "${NOTARY_API_KEY_P8_BASE64:-}" ] || asc_die "ASC_KEY_PATH bzw. NOTARY_API_KEY_P8_BASE64 fehlt."
        ASC_KEY_PATH="$ASC_STATE/asc-key.p8"
        ASC_KEY_FILE_CREATED=$ASC_KEY_PATH
        (umask 077; printf '%s' "$NOTARY_API_KEY_P8_BASE64" | tr -d '[:space:]' | base64 --decode > "$ASC_KEY_PATH") 2>/dev/null \
            || asc_die "NOTARY_API_KEY_P8_BASE64 ist kein gültiges base64."
    fi
    [ -r "$ASC_KEY_PATH" ] || asc_die "Schlüsseldatei $ASC_KEY_PATH nicht lesbar."
    ASC_JWT_BIN="$ASC_STATE/asc-jwt"
    if [ ! -x "$ASC_JWT_BIN" ]; then
        asc_log "asc-jwt.swift kompilieren"
        swiftc -O "$(dirname "${BASH_SOURCE[0]}")/asc-jwt.swift" -o "$ASC_JWT_BIN" >/dev/null \
            || asc_die "scripts/asc-jwt.swift lässt sich nicht kompilieren."
    fi
}

asc_new_token() {
    local token
    if [ -n "${ASC_JWT_CMD:-}" ]; then
        token=$(bash -c "$ASC_JWT_CMD") || asc_die "Token konnte nicht erzeugt werden (ASC_JWT_CMD)."
    else
        token=$(ASC_KEY_PATH="$ASC_KEY_PATH" ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" "$ASC_JWT_BIN") \
            || asc_die "Token konnte nicht erzeugt werden (scripts/asc-jwt.swift)."
    fi
    [ -n "$token" ] || asc_die "Leeres Token."
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$token"; fi
    ASC_TOKEN=$token
    ASC_TOKEN_TIME=$(date +%s)
    # Header über eine Datei an curl, damit das Token nicht in der Prozessliste steht.
    (umask 077; printf 'Authorization: Bearer %s\n' "$ASC_TOKEN" > "$ASC_STATE/auth-header")
}

asc_ensure_token() {
    local now
    now=$(date +%s)
    if [ -z "$ASC_TOKEN" ] || [ $((now - ASC_TOKEN_TIME)) -ge "$ASC_TOKEN_MAX_AGE" ]; then
        asc_new_token
    fi
}

# --- HTTP ------------------------------------------------------------------------------
# asc_api METHOD PATH [JSON]: Antwort in $ASC_RESPONSE (Datei), Status in $ASC_STATUS.
# Wiederholt bei Netzwerkfehlern, 429 und 5xx; bei 401 einmal mit neuem Token.
# Rückgabe 0 bei 2xx, sonst 1 (Fehlerdetails mit asc_print_errors).
ASC_STATUS=
ASC_RESPONSE=
asc_api() {
    local method=$1 path=$2 body=${3:-} attempt=1 renewed=0
    ASC_RESPONSE="$ASC_STATE/response.json"
    local args=(-sS -g -o "$ASC_RESPONSE" -w '%{http_code}' -X "$method"
                -H "@$ASC_STATE/auth-header" -H 'Accept: application/json')
    if [ -n "$body" ]; then args+=(-H 'Content-Type: application/json' --data-binary "$body"); fi
    while :; do
        asc_ensure_token
        : > "$ASC_RESPONSE"
        ASC_STATUS=$(curl "${args[@]}" "$ASC_API_BASE$path" 2>"$ASC_STATE/curl.err") || ASC_STATUS=000
        case "$ASC_STATUS" in
            2??) return 0 ;;
            401)
                if [ "$renewed" -eq 0 ]; then renewed=1; ASC_TOKEN=; continue; fi
                return 1 ;;
            000|429|5??)
                if [ "$attempt" -ge "$ASC_RETRIES" ]; then
                    if [ "$ASC_STATUS" = 000 ]; then asc_err "Netzwerkfehler: $(cat "$ASC_STATE/curl.err")"; fi
                    return 1
                fi
                echo "    $method ${path%%\?*}: HTTP $ASC_STATUS, neuer Versuch $((attempt + 1))/$ASC_RETRIES"
                sleep $((ASC_RETRY_SLEEP * attempt))
                attempt=$((attempt + 1)) ;;
            *) return 1 ;;
        esac
    done
}

# Fehlerliste einer API-Antwort lesbar ausgeben (errors[] und meta.associatedErrors).
asc_print_errors() {
    local file=${1:-$ASC_RESPONSE}
    jq -r '
        def line: "  - " + ([.status, .code] | map(select(. != null)) | join(" "))
                  + (if .title then ": " + .title else "" end)
                  + (if .detail then "\n      " + .detail else "" end)
                  + (if .source.pointer then "\n      (Feld " + .source.pointer + ")"
                     elif .source.parameter then "\n      (Parameter " + .source.parameter + ")" else "" end);
        (.errors // [])[] | (line,
            ((.meta.associatedErrors // {}) | to_entries[] | .key as $k | .value[]
             | "      · " + (.detail // .title // .code // "?") + " [" + $k + "]"))
    ' "$file" 2>/dev/null || cat "$file"
}

# Bricht mit Status, Fehlerdetails und Hinweis ab.
asc_fail_api() {
    local what=$1 hint=${2:-}
    echo "App Store Connect: $what fehlgeschlagen (HTTP $ASC_STATUS):" >&2
    asc_print_errors >&2
    local details
    details=$(asc_print_errors | head -20)
    asc_summary "- **Fehler:** $what (HTTP $ASC_STATUS)"
    asc_summary ""
    asc_summary '```'
    asc_summary "$details"
    asc_summary '```'
    case "$ASC_STATUS" in
        401) hint=${hint:-"Token abgelehnt: Key-ID, Issuer-ID und .p8 prüfen."} ;;
        403) hint=${hint:-"Der API Key hat zu wenig Rechte (Rolle App Manager oder höher nötig)."} ;;
    esac
    if [ -n "$hint" ]; then asc_summary "- Hinweis: $hint"; echo "Hinweis: $hint" >&2; fi
    asc_err "$what fehlgeschlagen (HTTP $ASC_STATUS)"
    exit 1
}

asc_jq() { jq -r "$@" "$ASC_RESPONSE"; }

# --- Schritte --------------------------------------------------------------------------
APP_ID=
BUILD_ID=
VERSION_ID=
VERSION_STATE=
ALREADY_SUBMITTED=0

asc_resolve_app_id() {
    if [ -n "${APPSTORE_APP_ID:-}" ]; then
        APP_ID=$APPSTORE_APP_ID
        asc_log "App-ID $APP_ID (APPSTORE_APP_ID)"
        return 0
    fi
    asc_api GET "/v1/apps?filter[bundleId]=$ASC_BUNDLE_ID&fields[apps]=bundleId,name&limit=2" \
        || asc_fail_api "App suchen"
    APP_ID=$(asc_jq --arg b "$ASC_BUNDLE_ID" '[.data[] | select(.attributes.bundleId == $b)][0].id // empty')
    [ -n "$APP_ID" ] || asc_die "Keine App mit Bundle-ID $ASC_BUNDLE_ID in App Store Connect (oder der Key sieht sie nicht)."
    asc_log "App-ID $APP_ID (über Bundle-ID $ASC_BUNDLE_ID)"
}

asc_wait_for_build() {
    local version=$1 build=$2 attempt=1 state
    asc_log "Auf Build $build ($version) warten, bis App Store Connect ihn verarbeitet hat"
    while :; do
        asc_api GET "/v1/builds?filter[app]=$APP_ID&filter[version]=$build&filter[preReleaseVersion.version]=$version&filter[preReleaseVersion.platform]=$ASC_PLATFORM&fields[builds]=version,processingState,uploadedDate&limit=1" \
            || asc_fail_api "Build suchen"
        BUILD_ID=$(asc_jq '.data[0].id // empty')
        state=$(asc_jq '.data[0].attributes.processingState // empty')
        case "$state" in
            VALID)
                asc_log "Build $build verarbeitet (ID $BUILD_ID)"
                asc_summary "- Build $build: von App Store Connect verarbeitet (VALID)"
                return 0 ;;
            INVALID|FAILED)
                asc_die "Build $build ist $state: Apple hat ihn nicht angenommen (E-Mail von App Store Connect bzw. TestFlight → Build ansehen)." ;;
        esac
        if [ "$attempt" -ge "$ASC_POLL_ATTEMPTS" ]; then
            asc_die "Build $build nach $attempt Abfragen noch nicht fertig (Status: ${state:-noch nicht sichtbar}). Später den Workflow erneut starten oder von Hand einreichen."
        fi
        echo "    Versuch $attempt/$ASC_POLL_ATTEMPTS: ${state:-noch nicht sichtbar}, nächste Abfrage in ${ASC_POLL_INTERVAL} s"
        sleep "$ASC_POLL_INTERVAL"
        attempt=$((attempt + 1))
    done
}

# Zustände, in denen die Version nicht mehr bearbeitet und eingereicht werden kann.
asc_state_is_submitted() {
    case "$1" in
        WAITING_FOR_REVIEW|IN_REVIEW|ACCEPTED|PENDING_APPLE_RELEASE|PENDING_DEVELOPER_RELEASE|\
        PROCESSING_FOR_DISTRIBUTION|READY_FOR_DISTRIBUTION|PROCESSING_FOR_APP_STORE|READY_FOR_SALE|\
        PREORDER_READY_FOR_SALE|REPLACED_WITH_NEW_VERSION) return 0 ;;
        *) return 1 ;;
    esac
}
ASC_EDITABLE_STATES=PREPARE_FOR_SUBMISSION,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED,INVALID_BINARY,WAITING_FOR_EXPORT_COMPLIANCE,READY_FOR_REVIEW

# Setzt VERSION_ID; ALREADY_SUBMITTED=1, wenn sie schon eingereicht/freigegeben ist.
asc_find_or_create_version() {
    local version=$1 release_type=MANUAL current_type current_string patch_attrs body
    if [ "${RELEASE_AFTER_APPROVAL:-false}" = "true" ]; then release_type=AFTER_APPROVAL; fi
    asc_api GET "/v1/apps/$APP_ID/appStoreVersions?filter[versionString]=$version&filter[platform]=$ASC_PLATFORM&limit=1" \
        || asc_fail_api "App-Store-Version suchen"
    VERSION_ID=$(asc_jq '.data[0].id // empty')
    if [ -z "$VERSION_ID" ]; then
        # Apple erlaubt je Plattform nur eine bearbeitbare Version: eine solche umbenennen.
        asc_api GET "/v1/apps/$APP_ID/appStoreVersions?filter[platform]=$ASC_PLATFORM&filter[appVersionState]=$ASC_EDITABLE_STATES&limit=1" \
            || asc_fail_api "Bearbeitbare App-Store-Version suchen"
        VERSION_ID=$(asc_jq '.data[0].id // empty')
        if [ -n "$VERSION_ID" ]; then
            asc_log "Bearbeitbare Version $(asc_jq '.data[0].attributes.versionString') wird zu $version umbenannt"
            asc_summary "- Version: bearbeitbare Version $(asc_jq '.data[0].attributes.versionString') in $version umbenannt"
        fi
    fi
    if [ -z "$VERSION_ID" ]; then
        body=$(jq -nc --arg v "$version" --arg p "$ASC_PLATFORM" --arg r "$release_type" --arg app "$APP_ID" \
            '{data: {type: "appStoreVersions", attributes: {platform: $p, versionString: $v, releaseType: $r},
                     relationships: {app: {data: {type: "apps", id: $app}}}}}')
        asc_api POST /v1/appStoreVersions "$body" || asc_fail_api "App-Store-Version $version anlegen"
        VERSION_ID=$(asc_jq '.data.id')
        VERSION_STATE=$(asc_jq '.data.attributes.appVersionState // .data.attributes.appStoreState // "PREPARE_FOR_SUBMISSION"')
        asc_log "Version $version angelegt (ID $VERSION_ID, $release_type)"
        asc_summary "- Version $version: angelegt (Veröffentlichung: $release_type)"
        return 0
    fi
    VERSION_STATE=$(asc_jq '.data[0].attributes.appVersionState // .data[0].attributes.appStoreState // empty')
    current_type=$(asc_jq '.data[0].attributes.releaseType // empty')
    current_string=$(asc_jq '.data[0].attributes.versionString // empty')
    if asc_state_is_submitted "$VERSION_STATE"; then
        asc_log "Version $version ist bereits eingereicht bzw. freigegeben ($VERSION_STATE)"
        asc_summary "- Version $version ist **bereits eingereicht oder freigegeben** ($VERSION_STATE); nichts geändert."
        ALREADY_SUBMITTED=1
        return 0
    fi
    patch_attrs='{}'
    if [ "$current_string" != "$version" ]; then
        patch_attrs=$(jq -c --arg v "$version" '. + {versionString: $v}' <<<"$patch_attrs")
    fi
    if [ "$current_type" != "$release_type" ]; then
        patch_attrs=$(jq -c --arg r "$release_type" '. + {releaseType: $r}' <<<"$patch_attrs")
    fi
    if [ "$patch_attrs" != '{}' ]; then
        body=$(jq -nc --arg id "$VERSION_ID" --argjson a "$patch_attrs" \
            '{data: {type: "appStoreVersions", id: $id, attributes: $a}}')
        asc_api PATCH "/v1/appStoreVersions/$VERSION_ID" "$body" || asc_fail_api "App-Store-Version $version ändern"
    fi
    asc_log "Version $version vorhanden (ID $VERSION_ID, $VERSION_STATE, $release_type)"
    if [ "$current_string" = "$version" ]; then
        asc_summary "- Version $version: vorhanden ($VERSION_STATE), Veröffentlichung: $release_type"
    fi
}

asc_set_whats_new() {
    local version=$1 suffix locale text loc_id body locs
    asc_api GET "/v1/appStoreVersions/$VERSION_ID/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale,whatsNew&limit=50" \
        || asc_fail_api "Lokalisierungen der Version lesen"
    locs=$(cat "$ASC_RESPONSE")
    for suffix in "${ASC_NOTE_SUFFIXES[@]}"; do
        locale=$(asc_locale_for "$suffix")
        text=$(asc_note_json "$ASC_NOTES_DIR/$version.$suffix.txt")
        loc_id=$(jq -r --arg l "$locale" '[.data[] | select(.attributes.locale == $l)][0].id // empty' <<<"$locs")
        if [ -n "$loc_id" ]; then
            body=$(jq -nc --arg id "$loc_id" --argjson t "$text" \
                '{data: {type: "appStoreVersionLocalizations", id: $id, attributes: {whatsNew: $t}}}')
            if asc_api PATCH "/v1/appStoreVersionLocalizations/$loc_id" "$body"; then
                asc_log "Neu in dieser Version ($locale): aktualisiert"
                asc_summary "- Neu in dieser Version ($locale): aktualisiert"
                continue
            fi
        else
            body=$(jq -nc --arg l "$locale" --argjson t "$text" --arg v "$VERSION_ID" \
                '{data: {type: "appStoreVersionLocalizations", attributes: {locale: $l, whatsNew: $t},
                         relationships: {appStoreVersion: {data: {type: "appStoreVersions", id: $v}}}}}')
            if asc_api POST /v1/appStoreVersionLocalizations "$body"; then
                asc_log "Neu in dieser Version ($locale): Lokalisierung angelegt"
                asc_summary "- Neu in dieser Version ($locale): Lokalisierung angelegt (Beschreibung usw. ggf. in App Store Connect ergänzen)"
                continue
            fi
        fi
        # Bei der allerersten Version einer App lässt Apple whatsNew nicht zu (409).
        if [ "$ASC_STATUS" = 409 ] && grep -q whatsNew "$ASC_RESPONSE"; then
            asc_warn "Apple lässt \"Neu in dieser Version\" ($locale) nicht zu (z. B. erste Version der App), übersprungen."
            asc_print_errors
            asc_summary "- Neu in dieser Version ($locale): von Apple nicht zugelassen, übersprungen"
            continue
        fi
        asc_fail_api "Neu in dieser Version ($locale) setzen"
    done
}

asc_attach_build() {
    local body
    body=$(jq -nc --arg b "$BUILD_ID" '{data: {type: "builds", id: $b}}')
    asc_api PATCH "/v1/appStoreVersions/$VERSION_ID/relationships/build" "$body" \
        || asc_fail_api "Build an die Version hängen"
    asc_log "Build $BUILD_ID an Version $VERSION_ID gehängt"
    asc_summary "- Build an die Version gehängt"
}

asc_submit_for_review() {
    local version=$1 sub_id body busy unresolved
    asc_api GET "/v1/reviewSubmissions?filter[app]=$APP_ID&filter[platform]=$ASC_PLATFORM&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES&limit=20" \
        || asc_fail_api "Offene Einreichungen suchen"
    busy=$(asc_jq '[.data[] | select(.attributes.state == "WAITING_FOR_REVIEW" or .attributes.state == "IN_REVIEW")][0].attributes.state // empty')
    unresolved=$(asc_jq '[.data[] | select(.attributes.state == "UNRESOLVED_ISSUES")][0].id // empty')
    sub_id=$(asc_jq '[.data[] | select(.attributes.state == "READY_FOR_REVIEW")][0].id // empty')
    if [ -n "$busy" ]; then
        asc_die "Für macOS läuft schon eine andere Einreichung ($busy). Version $version ist vorbereitet (Build und Texte gesetzt), aber nicht eingereicht: Prüfung abwarten oder in App Store Connect zurückziehen, dann erneut starten."
    fi
    if [ -n "$unresolved" ]; then
        asc_die "Es gibt eine abgelehnte Einreichung mit offenen Punkten (UNRESOLVED_ISSUES, ID $unresolved). Bitte in App Store Connect beantworten oder entfernen, dann erneut starten. Version $version ist vorbereitet, aber nicht eingereicht."
    fi
    if [ -n "$sub_id" ]; then
        asc_log "Offene Einreichung $sub_id (READY_FOR_REVIEW) wird verwendet"
    else
        body=$(jq -nc --arg p "$ASC_PLATFORM" --arg app "$APP_ID" \
            '{data: {type: "reviewSubmissions", attributes: {platform: $p},
                     relationships: {app: {data: {type: "apps", id: $app}}}}}')
        asc_api POST /v1/reviewSubmissions "$body" || asc_fail_api "Einreichung anlegen"
        sub_id=$(asc_jq '.data.id')
        asc_log "Einreichung $sub_id angelegt"
    fi

    asc_api GET "/v1/reviewSubmissions/$sub_id/items?include=appStoreVersion&limit=50" \
        || asc_fail_api "Inhalt der Einreichung lesen"
    if [ -n "$(asc_jq --arg v "$VERSION_ID" '[.data[] | select(.relationships.appStoreVersion.data.id? == $v)][0].id // empty')" ]; then
        asc_log "Version ist schon Teil der Einreichung"
    else
        body=$(jq -nc --arg s "$sub_id" --arg v "$VERSION_ID" \
            '{data: {type: "reviewSubmissionItems",
                     relationships: {reviewSubmission: {data: {type: "reviewSubmissions", id: $s}},
                                     appStoreVersion: {data: {type: "appStoreVersions", id: $v}}}}}')
        asc_api POST /v1/reviewSubmissionItems "$body" \
            || asc_fail_api "Version zur Einreichung hinzufügen" "Fehlen Angaben der Version (Beschreibung, Screenshots, Copyright, Support-URL)? In App Store Connect ergänzen und erneut starten."
    fi

    body=$(jq -nc --arg s "$sub_id" '{data: {type: "reviewSubmissions", id: $s, attributes: {submitted: true}}}')
    asc_api PATCH "/v1/reviewSubmissions/$sub_id" "$body" \
        || asc_fail_api "Zur Prüfung einreichen" "Apple nennt oben die fehlenden oder ungültigen Angaben. In App Store Connect ergänzen und den Workflow erneut starten (Upload schlägt dann wegen gleicher Build-Nummer fehl: einreichen von Hand oder neue Version)."
    asc_log "Zur Prüfung eingereicht (Einreichung $sub_id, Status $(asc_jq '.data.attributes.state // "?"'))"
    asc_summary "- **Zur Prüfung eingereicht** (Einreichung $sub_id)"
}

asc_flush_summary() {
    local rc=$?
    asc_cleanup
    if [ -n "$ASC_SUMMARY_FILE" ] && [ -f "$ASC_SUMMARY_FILE" ]; then
        local out=${GITHUB_STEP_SUMMARY:-/dev/stdout}
        {
            echo
            echo "### Einreichung zur Prüfung (App Store Connect API)"
            echo
            cat "$ASC_SUMMARY_FILE"
            if [ "$rc" -ne 0 ]; then
                echo
                echo "Nicht eingereicht. Hochgeladen ist der Build trotzdem; der Rest geht von Hand in [App Store Connect](https://appstoreconnect.apple.com)."
            fi
        } >> "$out"
        rm -f "$ASC_SUMMARY_FILE"
    fi
    return "$rc"
}

asc_submit() {
    local version build
    version=$(asc_version)
    build=${BUILD_NUMBER:-}
    [ -n "$build" ] || { asc_err "BUILD_NUMBER fehlt (CFBundleVersion des Uploads)."; exit 1; }
    (umask 077; mkdir -p "$ASC_STATE")
    chmod 700 "$ASC_STATE"
    ASC_SUMMARY_FILE="$ASC_STATE/summary.md"
    : > "$ASC_SUMMARY_FILE"
    trap asc_flush_summary EXIT
    asc_summary "- Version $version, Build $build, Plattform macOS"

    asc_check_notes "$version" || asc_die "Release Notes fehlen oder sind ungültig."
    asc_prepare_key
    asc_resolve_app_id
    asc_wait_for_build "$version" "$build"
    asc_find_or_create_version "$version"
    if [ "$ALREADY_SUBMITTED" -eq 1 ]; then
        echo "Version $version ist bereits eingereicht oder freigegeben; nichts zu tun."
        return 0
    fi
    asc_set_whats_new "$version"
    asc_attach_build
    asc_submit_for_review "$version"
    if [ "${RELEASE_AFTER_APPROVAL:-false}" = "true" ]; then
        asc_summary "- Nach der Freigabe veröffentlicht Apple automatisch."
    else
        asc_summary "- Nach der Freigabe: in App Store Connect **Diese Version veröffentlichen** (manuelle Veröffentlichung)."
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        check-notes) asc_check_notes "${2:-$(asc_version)}" ;;
        submit) asc_submit ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) echo "Aufruf: $0 check-notes [VERSION] | submit" >&2; exit 2 ;;
    esac
fi
