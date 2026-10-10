#!/bin/bash
# Richtet einmalig die Secrets für den Release-Workflow ein (interaktiv).
#
#   scripts/setup-release-secrets.sh             # Environment "release" (release.yml)
#   scripts/setup-release-secrets.sh --appstore  # Environment "appstore" (appstore.yml)
#
# Ablauf:
#   1. Ziel wählen: Environment "release" (empfohlen) oder Repository-Secrets;
#      das Environment wird bei Bedarf angelegt, optional mit Pflicht-Freigabe.
#   2. Developer-ID-Zertifikat samt privatem Schlüssel als .p12:
#      a) automatisch aus dem Anmelde-Schlüsselbund (`security export`; macOS
#         fragt pro privatem Schlüssel einmal nach dem Anmeldepasswort), oder
#      b) eine selbst in der Schlüsselbundverwaltung exportierte .p12-Datei.
#      Das Skript reduziert das .p12 auf genau diese Identität (plus
#      Zwischenzertifikat) und verschlüsselt es mit einem neuen Passwort.
#   3. App Store Connect API Key: Pfad zur .p8, Key-ID, Issuer-ID.
#   4. Secrets per `gh secret set` setzen.
#   5. Temporäre Dateien löschen (auch bei Abbruch).
#
# Voraussetzungen: gh (angemeldet, Admin-Rechte am Repo), das Zertifikat
# "Developer ID Application: …" im Anmelde-Schlüsselbund. Siehe dev/RELEASING.md.
#
# --appstore (dev/APPSTORE.md, "Upload per Workflow"): statt der Developer ID
# die Identitäten "Apple Distribution: …" und "3rd Party Mac Developer Installer: …"
# (bzw. "Mac Installer Distribution: …") in EIN .p12 (über eine temporäre
# Keychain zusammengeführt), dazu das Provisioning Profile (Pfad) und derselbe
# API Key (Rolle App Manager). Secrets im Environment "appstore":
# APPSTORE_CERTIFICATES_P12_BASE64, APPSTORE_CERTIFICATES_PASSWORD,
# APPSTORE_PROVISIONING_PROFILE_BASE64, NOTARY_API_KEY_P8_BASE64,
# NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID.
#
# Nichts davon landet im Repo oder in der Shell-History; Werte werden nie
# ausgegeben. Kein `set -x`.
set -euo pipefail

IDENTITY=${DISKRINGS_IDENTITY:-"Developer ID Application: Stefan Richter (AGRWTKQZ8C)"}
ENV_NAME=${DISKRINGS_RELEASE_ENV:-release}
REPO=${DISKRINGS_REPO:-}
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
# LibreSSL des Systems: liest das PKCS#12 von `security export` und schreibt
# eines, das `security import` auf dem Runner versteht (3DES/SHA1).
OPENSSL=/usr/bin/openssl
SECRETS=(MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD
         NOTARY_API_KEY_P8_BASE64 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID)
# --appstore
MODE=release
TEAM_ID=AGRWTKQZ8C
BUNDLE_ID=de.stefanrichter.DiskRings
APPSTORE_IDENTITY=${DISKRINGS_APPSTORE_IDENTITY:-"Apple Distribution: Stefan Richter ($TEAM_ID)"}
INSTALLER_CANDIDATES=("3rd Party Mac Developer Installer: Stefan Richter ($TEAM_ID)"
                      "Mac Installer Distribution: Stefan Richter ($TEAM_ID)")
APPSTORE_SECRETS=(APPSTORE_CERTIFICATES_P12_BASE64 APPSTORE_CERTIFICATES_PASSWORD
                  APPSTORE_PROVISIONING_PROFILE_BASE64
                  NOTARY_API_KEY_P8_BASE64 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID)

WORK=
cleanup() {
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        # Überschreiben vor dem Löschen; auf APFS/SSD ist das keine Garantie
        # (Copy-on-Write), die Dateien lagen aber nur verschlüsselt bzw. kurz
        # in einem Verzeichnis mit Rechten 0700.
        find "$WORK" -type f -exec sh -c 'for f; do
            dd if=/dev/urandom of="$f" bs=1k count="$(( ($(stat -f %z "$f") + 1023) / 1024 ))" conv=notrunc 2>/dev/null
        done' sh {} + 2>/dev/null || true
        rm -rf "$WORK"
    fi
}

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ask "Frage" [Standard] → REPLY
ask() {
    local prompt=$1 def=${2:-}
    if [ -n "$def" ]; then prompt="$prompt [$def]"; fi
    read -r -p "$prompt: " REPLY
    REPLY=${REPLY:-$def}
}
# confirm "Frage" [j|n] → 0 bei Ja
confirm() {
    local def=${2:-n} hint="[j/N]"
    if [ "$def" = "j" ]; then hint="[J/n]"; fi
    read -r -p "$1 $hint " REPLY
    REPLY=${REPLY:-$def}
    [[ "$REPLY" =~ ^[jJyY] ]]
}
# ask_secret "Frage" [mindestlänge] → REPLY (zweimal eingeben)
ask_secret() {
    local a b min=${2:-1}
    while true; do
        read -r -s -p "$1: " a; echo
        if [ "${#a}" -lt "$min" ]; then say "Mindestens $min Zeichen."; continue; fi
        read -r -s -p "Wiederholen: " b; echo
        if [ "$a" = "$b" ]; then REPLY=$a; return 0; fi
        say "Stimmt nicht überein, bitte noch einmal."
    done
}

# Zerlegt die PEM-Ausgabe von `openssl pkcs12 -nodes` (stdin) in Blöcke und gibt je
# nach mode aus:
#   list  localKeyID jeder Identität "$id" (Zertifikat mit passendem Schlüssel), je Zeile
#   cert  das Zertifikat mit localKeyID "$want"
#   pair  Schlüssel + Zertifikat mit localKeyID "$want"
# shellcheck disable=SC2016
P12_AWK='
    /^Bag Attributes/ { lkid = ""; fname = ""; subj = ""; next }
    /^[[:space:]]+localKeyID:/ { sub(/^[[:space:]]+localKeyID:[[:space:]]*/, ""); lkid = $0; next }
    /^[[:space:]]+friendlyName:/ { sub(/^[[:space:]]+friendlyName:[[:space:]]*/, ""); fname = $0; next }
    /^subject=/ { subj = $0; next }
    /^-----BEGIN / { inpem = 1; type = ($0 ~ /CERTIFICATE/) ? "cert" : "key"; pem = $0 "\n"; next }
    inpem {
        pem = pem $0 "\n"
        if ($0 ~ /^-----END /) {
            inpem = 0; n++
            T[n] = type; L[n] = lkid; F[n] = fname; S[n] = subj; P[n] = pem
        }
        next
    }
    # Mehrere Zertifikate können denselben Schlüssel (dieselbe localKeyID) haben,
    # z. B. Apple Distribution und Installer aus derselben CSR; deshalb immer
    # zusätzlich über den Namen auswählen.
    function named(i) { return id == "" || F[i] == id || index(S[i], "CN=" id "/") || S[i] ~ ("CN=" id "$") }
    END {
        for (i = 1; i <= n; i++) if (T[i] == "key" && L[i] != "") K[L[i]] = i
        for (i = 1; i <= n; i++) {
            if (T[i] != "cert" || L[i] == "" || !(L[i] in K) || !named(i)) continue
            if (mode == "list") {
                print L[i]
            } else if (L[i] == want) {
                if (mode == "pair") printf "%s", P[K[L[i]]]
                printf "%s", P[i]
                exit 0
            }
        }
    }'

# PEM-Ausgabe eines PKCS#12 (privater Schlüssel unverschlüsselt, nur in der Pipe).
p12_dump() { IN_PASS=$2 "$OPENSSL" pkcs12 -in "$1" -nodes -passin env:IN_PASS 2>/dev/null; }

# notAfter eines Zertifikats (PEM auf stdin) als Unix-Zeit.
not_after_epoch() {
    local d
    d=$("$OPENSSL" x509 -noout -enddate | cut -d= -f2 | tr -s ' ')
    LC_ALL=C date -j -u -f '%b %d %T %Y GMT' "$d" +%s
}

# Schreibt aus einem PKCS#12 mit beliebig vielen Identitäten genau eine Identität
# $3 (Zertifikat + passender privater Schlüssel) in ein neues PKCS#12. Gibt es
# mehrere (z. B. nach einer Verlängerung), gewinnt die nicht abgelaufene mit dem
# spätesten Ablaufdatum.
#   extract_identity <in.p12> <in-passwort> <identität> <out.p12> <out-passwort> [kette.pem]
# Rückgabe: 0 ok, 1 Fehler (Passwort, Export), 3 Identität fehlt, 5 alle abgelaufen.
# Der private Schlüssel liegt dabei nur im Speicher (Pipe), nie unverschlüsselt auf der Platte.
extract_identity() {
    local in=$1 in_pass=$2 identity=$3 out=$4 out_pass=$5 chain=${6:-}
    local certfile=() lkids lkid pem end best="" best_end=0
    if [ -n "$chain" ] && [ -s "$chain" ]; then certfile=(-certfile "$chain"); fi
    # Passwort prüfen (nur Zertifikate). Schlüssel fließen ausschließlich durch Pipes,
    # nie durch Variablen oder Here-Strings (die bash in temporäre Dateien schreibt).
    IN_PASS=$in_pass "$OPENSSL" pkcs12 -in "$in" -nokeys -passin env:IN_PASS >/dev/null 2>&1 || return 1
    lkids=$(p12_dump "$in" "$in_pass" | awk -v mode=list -v id="$identity" "$P12_AWK")
    [ -n "$lkids" ] || return 3
    while IFS= read -r lkid; do
        pem=$(p12_dump "$in" "$in_pass" | awk -v mode=cert -v want="$lkid" -v id="$identity" "$P12_AWK")
        "$OPENSSL" x509 -noout -checkend 0 <<<"$pem" >/dev/null 2>&1 || continue
        end=$(not_after_epoch <<<"$pem") || continue
        if [ "$end" -gt "$best_end" ]; then best=$lkid; best_end=$end; fi
    done <<<"$lkids"
    [ -n "$best" ] || return 5
    p12_dump "$in" "$in_pass" | awk -v mode=pair -v want="$best" -v id="$identity" "$P12_AWK" \
        | OUT_PASS=$out_pass "$OPENSSL" pkcs12 -export -name "$identity" \
            ${certfile[@]+"${certfile[@]}"} \
            -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
            -passout env:OUT_PASS -out "$out" 2>/dev/null \
        || { rm -f "$out"; return 1; }
}

# Prüft ein PKCS#12: Identität vorhanden, Schlüssel passt zum Zertifikat, nicht abgelaufen.
verify_p12() {
    local p12=$1 pass=$2 identity=$3 cert subj
    cert=$(P=$pass "$OPENSSL" pkcs12 -in "$p12" -nokeys -clcerts -passin env:P 2>/dev/null) \
        || { say "  .p12 lässt sich mit diesem Passwort nicht öffnen."; return 1; }
    subj=$("$OPENSSL" x509 -noout -subject <<<"$cert")
    if [[ "$subj" != *"CN=$identity"* ]]; then
        say "  Zertifikat im .p12 ist nicht \"$identity\" ($subj)."
        return 1
    fi
    if ! "$OPENSSL" x509 -noout -checkend 0 <<<"$cert" >/dev/null; then
        say "  Zertifikat ist abgelaufen."
        return 1
    fi
    local pub_cert pub_key
    pub_cert=$("$OPENSSL" x509 -noout -pubkey <<<"$cert")
    pub_key=$(P=$pass "$OPENSSL" pkcs12 -in "$p12" -nocerts -nodes -passin env:P 2>/dev/null \
        | "$OPENSSL" pkey -pubout 2>/dev/null) || true
    if [ -z "$pub_key" ] || [ "$pub_cert" != "$pub_key" ]; then
        say "  Kein passender privater Schlüssel im .p12."
        return 1
    fi
    say "  OK: $subj, gültig bis $("$OPENSSL" x509 -noout -enddate <<<"$cert" | cut -d= -f2)"
}

# --- Schritte ------------------------------------------------------------------
step_target() {
    command -v gh >/dev/null || die "gh (GitHub CLI) fehlt: https://cli.github.com"
    gh auth status >/dev/null 2>&1 || die "gh ist nicht angemeldet: gh auth login"
    if [ -z "$REPO" ]; then
        REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo brokoskokoli/diskrings)
    fi
    ask "Repository" "$REPO"; REPO=$REPLY

    say ""
    say "Secrets im Environment \"$ENV_NAME\" sind nur für Jobs sichtbar, die dieses"
    say "Environment nutzen, und lassen sich mit einer Pflicht-Freigabe schützen (empfohlen)."
    if confirm "Secrets im Environment \"$ENV_NAME\" ablegen (sonst Repository-Secrets)?" j; then
        SECRET_SCOPE=(--env "$ENV_NAME")
        if ! gh api "repos/$REPO/environments/$ENV_NAME" >/dev/null 2>&1; then
            confirm "Environment \"$ENV_NAME\" existiert nicht. Anlegen?" j || die "Abgebrochen."
            gh api -X PUT "repos/$REPO/environments/$ENV_NAME" >/dev/null
            say "  Environment angelegt."
        fi
        step_protection
    else
        SECRET_SCOPE=()
    fi
}

step_protection() {
    say ""
    say "Schutz des Environments (jederzeit änderbar unter Settings → Environments → $ENV_NAME):"
    say "  - Pflicht-Freigabe: Jeder Lauf wartet, bis du ihn in GitHub freigibst."
    say "  - Nur Tags v* und der Branch main dürfen das Environment nutzen."
    confirm "Beides jetzt einrichten?" j || return 0
    local current uid
    current=$(gh api "repos/$REPO/environments/$ENV_NAME" --jq \
        '[(.protection_rules // [])[] | .type] | join(", ")' 2>/dev/null || true)
    if [ -n "$current" ]; then
        say "warning: Das Environment hat schon Schutzregeln ($current). Sie werden ersetzt:"
        say "         Reviewer nur noch du, Wartezeit und andere Regeln entfallen,"
        say "         Deployment-Regeln auf \"ausgewählte Branches und Tags\"."
        confirm "Vorhandene Schutzregeln überschreiben?" n || { say "  Unverändert gelassen."; return 0; }
    fi
    uid=$(gh api user --jq .id)
    if ! printf '{"reviewers":[{"type":"User","id":%s}],"prevent_self_review":false,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$uid" \
        | gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input - >/dev/null; then
        say "warning: Konnte den Schutz nicht setzen; bitte von Hand (dev/RELEASING.md)."
        return 0
    fi
    local existing
    existing=$(gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
        --jq '.branch_policies[] | "\(.type):\(.name)"' 2>/dev/null || true)
    grep -qx 'tag:v\*' <<<"$existing" || gh api -X POST \
        "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" -f name='v*' -f type=tag >/dev/null
    grep -qx 'branch:main' <<<"$existing" || gh api -X POST \
        "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" -f name=main -f type=branch >/dev/null
    say "  Pflicht-Freigabe und Tag-/Branch-Regeln gesetzt."
}

step_certificate() {
    say ""
    say "== Zertifikat: $IDENTITY"
    local identities
    identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
    if ! grep -qF "\"$IDENTITY\"" <<<"$identities"; then
        say "warning: \"$IDENTITY\" ist im Schlüsselbund nicht als gültige Identität zu finden."
    fi
    say "Passwort für das .p12 (wird als MACOS_CERTIFICATE_PASSWORD gespeichert;"
    say "am besten ein neues, zufälliges, z. B. aus dem Passwortmanager):"
    ask_secret "Passwort" 12
    P12_PASS=$REPLY
    P12="$WORK/developer-id.p12"

    local chain="$WORK/chain.pem"
    security find-certificate -a -c "Developer ID Certification Authority" -p \
        /Library/Keychains/System.keychain "$LOGIN_KC" > "$chain" 2>/dev/null || true

    say ""
    say "  a) automatisch aus dem Anmelde-Schlüsselbund exportieren (security export;"
    say "     macOS fragt pro privatem Schlüssel einmal nach dem Anmeldepasswort,"
    say "     dort \"Erlauben\" wählen)"
    say "  b) eine selbst exportierte .p12-Datei angeben"
    ask "Weg" a
    if [ "$REPLY" = "a" ]; then
        local all="$WORK/all.p12" tmp_pass
        tmp_pass=$("$OPENSSL" rand -hex 24)
        say "==> security export (alle Identitäten, wird gleich auf eine reduziert)"
        if ! security export -k "$LOGIN_KC" -t identities -f pkcs12 -P "$tmp_pass" -o "$all"; then
            manual_export_help
            die "security export fehlgeschlagen. Weg b) nutzen."
        fi
        local rc=0
        extract_identity "$all" "$tmp_pass" "$IDENTITY" "$P12" "$P12_PASS" "$chain" || rc=$?
        rm -f "$all"
        if [ "$rc" -eq 5 ]; then
            die "Alle Zertifikate \"$IDENTITY\" sind abgelaufen. Neues Developer-ID-Zertifikat anlegen."
        elif [ "$rc" -ne 0 ]; then
            manual_export_help
            die "Identität \"$IDENTITY\" samt Schlüssel nicht im Export gefunden. Weg b) nutzen."
        fi
    else
        manual_export_help
        ask "Pfad zur exportierten .p12"
        local src=${REPLY/#\~/$HOME}
        [ -f "$src" ] || die "Datei nicht gefunden: $src"
        read -r -s -p "Passwort dieser .p12: " src_pass; echo
        extract_identity "$src" "$src_pass" "$IDENTITY" "$P12" "$P12_PASS" "$chain" \
            || die "Identität \"$IDENTITY\" samt Schlüssel nicht in $src gefunden (oder falsches Passwort)."
        unset src_pass
        say "  Hinweis: Die Datei $src kannst du nach dem Einrichten löschen."
    fi
    verify_p12 "$P12" "$P12_PASS" "$IDENTITY" || die ".p12 ungültig."
}

manual_export_help() {
    cat <<MSG

  Export von Hand (Schlüsselbundverwaltung):
    1. Programme → Dienstprogramme → Schlüsselbundverwaltung öffnen.
    2. Links "Anmeldung", oben "Meine Zertifikate".
    3. "$IDENTITY" suchen; das Dreieck davor muss
       einen privaten Schlüssel zeigen.
    4. Rechtsklick auf das Zertifikat → "… exportieren", Format
       "Persönlicher Informationsaustausch (.p12)", Passwort vergeben.
    5. Diese Datei hier angeben (Weg b).
MSG
}

step_api_key() {
    say ""
    say "== App Store Connect API Key"
    if [ "$MODE" = "appstore" ]; then
        say "   Für den Upload braucht der Key die Rolle \"App Manager\" (oder höher). Hat dein"
        say "   Notarisierungs-Key nur \"Developer\", lege einen neuen Team Key mit \"App Manager\" an"
        say "   (App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys)."
    else
        say "   (App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys, Rolle \"Developer\")"
    fi
    ask "Pfad zur .p8-Datei (AuthKey_XXXXXXXXXX.p8)"
    P8=${REPLY/#\~/$HOME}
    [ -f "$P8" ] || die "Datei nicht gefunden: $P8"
    grep -q -- '-----BEGIN PRIVATE KEY-----' "$P8" || die "$P8 ist keine .p8-Datei."
    local guess=
    if [[ "$(basename "$P8")" =~ ^AuthKey_([A-Z0-9]{10})\.p8$ ]]; then guess=${BASH_REMATCH[1]}; fi
    while true; do
        ask "Key-ID" "$guess"; KEY_ID=$REPLY
        [[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] && break
        say "Die Key-ID hat 10 Zeichen (A-Z, 0-9)."
    done
    while true; do
        ask "Issuer-ID (UUID über der Key-Liste)"; ISSUER_ID=$REPLY
        [[ "$ISSUER_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] && break
        say "Die Issuer-ID ist eine UUID (8-4-4-4-12)."
    done
    if confirm "API-Key jetzt bei Apple prüfen (notarytool history)?" j; then
        NOTARY_API_KEY_ID=$KEY_ID NOTARY_API_ISSUER_ID=$ISSUER_ID NOTARY_API_KEY_PATH=$P8 \
            scripts/notarize.sh check || die "API-Key wird nicht akzeptiert."
        say "  API-Key funktioniert."
    fi
}

set_secret() {
    local name=$1
    gh secret set "$name" --repo "$REPO" ${SECRET_SCOPE[@]+"${SECRET_SCOPE[@]}"} >/dev/null
    say "  $name gesetzt"
}

step_set_secrets() {
    local where="Repository-Secrets"
    if [ "${#SECRET_SCOPE[@]}" -gt 0 ]; then where="Environment \"$ENV_NAME\""; fi
    say ""
    say "== Secrets setzen in $REPO ($where): ${SECRETS[*]}"
    confirm "Jetzt setzen (vorhandene werden überschrieben)?" j || die "Abgebrochen, nichts gesetzt."
    base64 -i "$P12" | tr -d '\n' | set_secret MACOS_CERTIFICATE_P12_BASE64
    printf '%s' "$P12_PASS" | set_secret MACOS_CERTIFICATE_PASSWORD
    base64 -i "$P8" | tr -d '\n' | set_secret NOTARY_API_KEY_P8_BASE64
    printf '%s' "$KEY_ID" | set_secret NOTARY_API_KEY_ID
    printf '%s' "$ISSUER_ID" | set_secret NOTARY_API_ISSUER_ID
}

# --- App Store (--appstore) ------------------------------------------------------
# Führt mehrere .p12 (je eine Identität, Passwort $2) über eine temporäre Keychain
# zu einem .p12 mit allen Identitäten zusammen (openssl kann nur einen Schlüssel
# pro PKCS#12 schreiben, `security export` alle einer Keychain).
#   merge_p12 <out.p12> <passwort> <in.p12>...
merge_p12() {
    local out=$1 pass=$2; shift 2
    local kc="$WORK/merge.keychain-db" kc_pass in
    kc_pass=$("$OPENSSL" rand -hex 24)
    security create-keychain -p "$kc_pass" "$kc"
    security unlock-keychain -p "$kc_pass" "$kc"
    for in in "$@"; do
        security import "$in" -k "$kc" -f pkcs12 -P "$pass" -T /usr/bin/security >/dev/null \
            || { security delete-keychain "$kc"; return 1; }
    done
    # Export ohne Rückfrage erlauben (nur diese temporäre Keychain).
    security set-key-partition-list -S apple-tool:,apple: -s -k "$kc_pass" "$kc" >/dev/null
    if ! security export -k "$kc" -t identities -f pkcs12 -P "$pass" -o "$out" >/dev/null; then
        security delete-keychain "$kc"
        return 1
    fi
    security delete-keychain "$kc"
}

# Erste Identität aus INSTALLER_CANDIDATES, die das .p12 $1 (Passwort $2) enthält.
find_installer_in_p12() {
    local candidate
    for candidate in "${INSTALLER_CANDIDATES[@]}"; do
        if [ -n "$(p12_dump "$1" "$2" | awk -v mode=list -v id="$candidate" "$P12_AWK")" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

step_appstore_certificates() {
    say ""
    say "== Zertifikate: $APPSTORE_IDENTITY"
    say "   und \"3rd Party Mac Developer Installer\" bzw. \"Mac Installer Distribution\""
    say "Passwort für das .p12 (wird als APPSTORE_CERTIFICATES_PASSWORD gespeichert;"
    say "am besten ein neues, zufälliges, z. B. aus dem Passwortmanager):"
    ask_secret "Passwort" 12
    P12_PASS=$REPLY
    P12="$WORK/appstore.p12"

    local chain="$WORK/chain.pem"
    security find-certificate -a -c "Apple Worldwide Developer Relations Certification Authority" -p \
        /Library/Keychains/System.keychain "$LOGIN_KC" > "$chain" 2>/dev/null || true

    say ""
    say "  a) automatisch aus dem Anmelde-Schlüsselbund exportieren (security export;"
    say "     macOS fragt pro privatem Schlüssel einmal nach dem Anmeldepasswort,"
    say "     dort \"Erlauben\" wählen)"
    say "  b) eine selbst exportierte .p12-Datei angeben, die BEIDE Identitäten enthält"
    say "     (in der Schlüsselbundverwaltung beide Zertifikate markieren → exportieren)"
    ask "Weg" a
    local way=$REPLY src src_pass
    if [ "$way" = "a" ]; then
        src="$WORK/all.p12"
        src_pass=$("$OPENSSL" rand -hex 24)
        say "==> security export (alle Identitäten, wird gleich auf zwei reduziert)"
        security export -k "$LOGIN_KC" -t identities -f pkcs12 -P "$src_pass" -o "$src" \
            || die "security export fehlgeschlagen. Weg b) nutzen."
    else
        ask "Pfad zur exportierten .p12"
        src=${REPLY/#\~/$HOME}
        [ -f "$src" ] || die "Datei nicht gefunden: $src"
        read -r -s -p "Passwort dieser .p12: " src_pass; echo
    fi

    local installer rc=0
    installer=$(find_installer_in_p12 "$src" "$src_pass") \
        || die "Keine Installer-Identität (${INSTALLER_CANDIDATES[*]}) samt Schlüssel gefunden (oder falsches Passwort)."
    extract_identity "$src" "$src_pass" "$APPSTORE_IDENTITY" "$WORK/dist.p12" "$P12_PASS" "$chain" || rc=$?
    [ "$rc" -eq 0 ] || die "Identität \"$APPSTORE_IDENTITY\" samt Schlüssel nicht gefunden oder abgelaufen (Code $rc)."
    extract_identity "$src" "$src_pass" "$installer" "$WORK/installer.p12" "$P12_PASS" "$chain" || rc=$?
    [ "$rc" -eq 0 ] || die "Identität \"$installer\" samt Schlüssel nicht gefunden oder abgelaufen (Code $rc)."
    if [ "$way" = "a" ]; then rm -f "$src"; else say "  Hinweis: Die Datei $src kannst du nach dem Einrichten löschen."; fi
    unset src_pass

    verify_p12 "$WORK/dist.p12" "$P12_PASS" "$APPSTORE_IDENTITY" || die ".p12 (Apple Distribution) ungültig."
    verify_p12 "$WORK/installer.p12" "$P12_PASS" "$installer" || die ".p12 (Installer) ungültig."
    say "==> Beide Identitäten in ein .p12 zusammenführen (temporäre Keychain)"
    merge_p12 "$P12" "$P12_PASS" "$WORK/dist.p12" "$WORK/installer.p12" \
        || die "Zusammenführen der .p12 fehlgeschlagen."
    rm -f "$WORK/dist.p12" "$WORK/installer.p12"
    local id
    for id in "$APPSTORE_IDENTITY" "$installer"; do
        [ -n "$(p12_dump "$P12" "$P12_PASS" | awk -v mode=list -v id="$id" "$P12_AWK")" ] \
            || die "Das zusammengeführte .p12 enthält \"$id\" nicht."
    done
    say "  OK: .p12 mit \"$APPSTORE_IDENTITY\" und \"$installer\""
}

step_profile() {
    say ""
    say "== Provisioning Profile \"Mac App Store Connect\" (dev/APPSTORE.md, Schritt 3)"
    ask "Pfad zum Profil" "$HOME/Library/MobileDevice/Provisioning Profiles/DiskRings_App_Store.provisionprofile"
    PROFILE=${REPLY/#\~/$HOME}
    [ -f "$PROFILE" ] || die "Datei nicht gefunden: $PROFILE"
    local plist="$WORK/profile.plist" app_id
    security cms -D -i "$PROFILE" > "$plist" 2>/dev/null || die "$PROFILE ist kein Provisioning Profile."
    app_id=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$plist" 2>/dev/null || true)
    [ "$app_id" = "$TEAM_ID.$BUNDLE_ID" ] || die "Profil gehört zu '$app_id', erwartet $TEAM_ID.$BUNDLE_ID."
    if /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$plist" >/dev/null 2>&1; then
        die "Das ist ein Development-Profil; gebraucht wird \"Mac App Store Connect\"."
    fi
    say "  OK: $app_id, gültig bis $(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$plist")"
}

step_set_secrets_appstore() {
    local where="Repository-Secrets"
    if [ "${#SECRET_SCOPE[@]}" -gt 0 ]; then where="Environment \"$ENV_NAME\""; fi
    say ""
    say "== Secrets setzen in $REPO ($where): ${APPSTORE_SECRETS[*]}"
    confirm "Jetzt setzen (vorhandene werden überschrieben)?" j || die "Abgebrochen, nichts gesetzt."
    base64 -i "$P12" | tr -d '\n' | set_secret APPSTORE_CERTIFICATES_P12_BASE64
    printf '%s' "$P12_PASS" | set_secret APPSTORE_CERTIFICATES_PASSWORD
    base64 -i "$PROFILE" | tr -d '\n' | set_secret APPSTORE_PROVISIONING_PROFILE_BASE64
    base64 -i "$P8" | tr -d '\n' | set_secret NOTARY_API_KEY_P8_BASE64
    printf '%s' "$KEY_ID" | set_secret NOTARY_API_KEY_ID
    printf '%s' "$ISSUER_ID" | set_secret NOTARY_API_ISSUER_ID
}

main_appstore() {
    say "DiskRings: Secrets für den Workflow \"App Store Upload\" einrichten (dev/APPSTORE.md)"
    step_target
    step_appstore_certificates
    step_profile
    step_api_key
    step_set_secrets_appstore
    unset P12_PASS

    cat <<MSG

Fertig. Nächste Schritte:
  - Trockenlauf: GitHub → Actions → App Store Upload → Run workflow (dry_run angehakt),
    oder: gh workflow run appstore.yml --repo $REPO -f dry_run=true
  - Temporäre Dateien werden jetzt gelöscht.
MSG
}

main() {
    case "${1:-}" in
        "") ;;
        --appstore) MODE=appstore; ENV_NAME=${DISKRINGS_APPSTORE_ENV:-appstore} ;;
        -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
        *) die "Unbekannte Option: $1 (erlaubt: --appstore)" ;;
    esac
    [ "$(uname -s)" = "Darwin" ] || die "Nur auf macOS (Schlüsselbund)."
    [ -t 0 ] || die "Interaktives Skript: bitte im Terminal starten."
    cd "$(dirname "$0")/.."
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/diskrings-secrets.XXXXXX")
    chmod 700 "$WORK"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    if [ "$MODE" = "appstore" ]; then
        main_appstore
        return 0
    fi
    say "DiskRings: Secrets für den Release-Workflow einrichten (dev/RELEASING.md)"
    step_target
    step_certificate
    step_api_key
    step_set_secrets
    unset P12_PASS

    cat <<MSG

Fertig. Nächste Schritte:
  - Trockenlauf: GitHub → Actions → Release → Run workflow (dry_run angehakt),
    oder: gh workflow run release.yml --repo $REPO -f dry_run=true
  - Die .p8 bewahrst du offline auf (Apple bietet sie nur einmal zum Download an)
    oder löschst sie; bei Bedarf einfach einen neuen Key anlegen.
  - Temporäre Dateien werden jetzt gelöscht.
MSG
}

# Nur beim direkten Aufruf ausführen (beim Einbinden mit `source` nur die Funktionen).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
