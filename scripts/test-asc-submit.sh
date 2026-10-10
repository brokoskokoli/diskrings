#!/bin/bash
# Lokale Tests für scripts/asc-submit.sh und scripts/asc-jwt.swift, ohne Apple:
# Ein kleiner Mock-Server (python3, Standardbibliothek) spielt die App Store
# Connect API nach; jedes Szenario startet ihn neu auf einem freien Port.
#
#   scripts/test-asc-submit.sh            # alle Tests (ca. 10–20 s, kompiliert asc-jwt.swift)
#
# Geprüft: Release Notes (fehlend, leer, zu lang, Unicode), Build-Abfrage bis
# VALID / INVALID / Zeitlimit, Version anlegen / wiederverwenden / umbenennen,
# Lokalisierung PATCH / POST, schon eingereicht, andere Einreichung läuft,
# Fehlerdetails (errors[].detail, associatedErrors), Wiederholung bei 429/5xx,
# Token-Erneuerung, JWT (Header, Payload, Signatur mit openssl geprüft).
# Alles läuft in einem temporären Verzeichnis; nichts verlässt den Rechner.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

WORK=$(mktemp -d "${TMPDIR:-/tmp}/asc-submit-test.XXXXXX")
SERVER_PID=
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { # check <beschreibung> <befehl…>
    local what=$1; shift
    if "$@"; then ok "$what"; else bad "$what"; fi
}
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
count() { grep -cF -- "$2" "$1" || true; }

# --- Mock-Server -------------------------------------------------------------------
cat > "$WORK/mock.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs

S = os.environ["MOCK_SCENARIO"]
LOG = os.environ["MOCK_LOG"]
state = {"build_polls": 0, "apps_calls": 0, "versions": {}, "locs": {}, "subs": {}, "items": [], "next": 100}

def nid():
    state["next"] += 1
    return str(state["next"])

if S in ("reuse", "already", "busy", "unresolved", "submit_error", "first_version"):
    state["versions"]["V1"] = {"versionString": "1.2.3", "platform": "MAC_OS", "releaseType": "MANUAL",
        "appVersionState": {"already": "WAITING_FOR_REVIEW"}.get(S, "PREPARE_FOR_SUBMISSION")}
if S == "rename":
    state["versions"]["V0"] = {"versionString": "1.2.2", "platform": "MAC_OS", "releaseType": "MANUAL",
                               "appVersionState": "PREPARE_FOR_SUBMISSION"}
if S in ("reuse", "first_version"):
    state["locs"]["L-en"] = {"locale": "en-US", "whatsNew": None, "version": "V1"}
    state["locs"]["L-de"] = {"locale": "de-DE", "whatsNew": None, "version": "V1"}
if S == "fresh":
    pass
if S == "reuse":
    state["subs"]["S1"] = {"state": "READY_FOR_REVIEW"}
    state["items"].append({"id": "I1", "sub": "S1", "version": "V1"})
if S == "busy":
    state["subs"]["S9"] = {"state": "IN_REVIEW"}
if S == "unresolved":
    state["subs"]["S8"] = {"state": "UNRESOLVED_ISSUES"}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def err(self, code, detail, **extra):
        e = {"status": str(code), "code": "STATE_ERROR", "title": "Fehler", "detail": detail}
        e.update(extra)
        self.send(code, {"errors": [e]})

    def handle_any(self, method):
        u = urlsplit(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n)) if n else None
        auth = self.headers.get("Authorization", "")
        with open(LOG, "a") as f:
            f.write(json.dumps({"m": method, "p": u.path, "q": q, "b": body, "auth": auth}) + "\n")
        if not auth.startswith("Bearer ") or len(auth) < 12:
            return self.err(401, "no token")
        p = u.path.rstrip("/").split("/")[1:]  # ['v1', ...]

        if method == "GET" and p == ["v1", "apps"]:
            state["apps_calls"] += 1
            if S == "retry" and state["apps_calls"] == 1: return self.err(503, "busy")
            if S == "retry" and state["apps_calls"] == 2: return self.err(429, "slow down")
            if q.get("filter[bundleId]") != "de.stefanrichter.DiskRings": return self.send(200, {"data": []})
            return self.send(200, {"data": [{"type": "apps", "id": "APP1", "attributes": {"bundleId": "de.stefanrichter.DiskRings"}}]})

        if method == "GET" and p == ["v1", "builds"]:
            assert q["filter[app]"] == "APP1", q
            assert q["filter[preReleaseVersion.platform]"] == "MAC_OS", q
            if q["filter[version]"] != "42" or q["filter[preReleaseVersion.version]"] != "1.2.3":
                return self.send(200, {"data": []})
            state["build_polls"] += 1
            k = state["build_polls"]
            if S == "fresh": st = [None, "PROCESSING", "VALID"][min(k, 3) - 1]
            elif S == "invalid": st = "PROCESSING" if k == 1 else "INVALID"
            elif S == "timeout": st = "PROCESSING"
            else: st = "VALID"
            if st is None: return self.send(200, {"data": []})
            return self.send(200, {"data": [{"type": "builds", "id": "B42", "attributes": {"version": "42", "processingState": st}}]})

        if method == "GET" and p == ["v1", "apps", "APP1", "appStoreVersions"]:
            res = []
            for vid, v in state["versions"].items():
                if q.get("filter[platform]") and v["platform"] != q["filter[platform]"]: continue
                if q.get("filter[versionString]") and v["versionString"] != q["filter[versionString]"]: continue
                if q.get("filter[appVersionState]") and v["appVersionState"] not in q["filter[appVersionState]"].split(","): continue
                res.append({"type": "appStoreVersions", "id": vid, "attributes": dict(v)})
            return self.send(200, {"data": res})

        if method == "POST" and p == ["v1", "appStoreVersions"]:
            a = body["data"]["attributes"]
            assert body["data"]["relationships"]["app"]["data"] == {"type": "apps", "id": "APP1"}
            vid = "V" + nid()
            state["versions"][vid] = {"versionString": a["versionString"], "platform": a["platform"],
                                      "releaseType": a.get("releaseType"), "appVersionState": "PREPARE_FOR_SUBMISSION"}
            return self.send(201, {"data": {"type": "appStoreVersions", "id": vid, "attributes": state["versions"][vid]}})

        if method == "PATCH" and len(p) == 3 and p[:2] == ["v1", "appStoreVersions"]:
            state["versions"][p[2]].update(body["data"]["attributes"])
            return self.send(200, {"data": {"type": "appStoreVersions", "id": p[2], "attributes": state["versions"][p[2]]}})

        if method == "GET" and len(p) == 4 and p[3] == "appStoreVersionLocalizations":
            res = [{"type": "appStoreVersionLocalizations", "id": i, "attributes": {"locale": l["locale"], "whatsNew": l["whatsNew"]}}
                   for i, l in state["locs"].items() if l["version"] == p[2]]
            return self.send(200, {"data": res})

        if p[:2] == ["v1", "appStoreVersionLocalizations"]:
            if S == "first_version":
                return self.err(409, "The attribute 'whatsNew' can not be edited at this time.",
                                source={"pointer": "/data/attributes/whatsNew"})
            if method == "PATCH":
                state["locs"][p[2]]["whatsNew"] = body["data"]["attributes"]["whatsNew"]
                return self.send(200, {"data": {"type": "appStoreVersionLocalizations", "id": p[2]}})
            if method == "POST":
                a = body["data"]["attributes"]
                lid = "L" + nid()
                state["locs"][lid] = {"locale": a["locale"], "whatsNew": a.get("whatsNew"),
                                      "version": body["data"]["relationships"]["appStoreVersion"]["data"]["id"]}
                return self.send(201, {"data": {"type": "appStoreVersionLocalizations", "id": lid}})

        if method == "PATCH" and len(p) == 5 and p[3:] == ["relationships", "build"]:
            assert body == {"data": {"type": "builds", "id": "B42"}}, body
            return self.send(204)

        if method == "GET" and p == ["v1", "reviewSubmissions"]:
            states = q["filter[state]"].split(",")
            res = [{"type": "reviewSubmissions", "id": i, "attributes": {"platform": "MAC_OS", "state": s["state"]}}
                   for i, s in state["subs"].items() if s["state"] in states]
            return self.send(200, {"data": res})

        if method == "POST" and p == ["v1", "reviewSubmissions"]:
            assert body["data"]["attributes"]["platform"] == "MAC_OS"
            sid = "S" + nid()
            state["subs"][sid] = {"state": "READY_FOR_REVIEW"}
            return self.send(201, {"data": {"type": "reviewSubmissions", "id": sid, "attributes": state["subs"][sid]}})

        if method == "GET" and len(p) == 4 and p[1] == "reviewSubmissions" and p[3] == "items":
            res = [{"type": "reviewSubmissionItems", "id": it["id"],
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": it["version"]}}}}
                   for it in state["items"] if it["sub"] == p[2]]
            return self.send(200, {"data": res})

        if method == "POST" and p == ["v1", "reviewSubmissionItems"]:
            r = body["data"]["relationships"]
            state["items"].append({"id": "I" + nid(), "sub": r["reviewSubmission"]["data"]["id"],
                                   "version": r["appStoreVersion"]["data"]["id"]})
            return self.send(201, {"data": {"type": "reviewSubmissionItems", "id": state["items"][-1]["id"]}})

        if method == "PATCH" and len(p) == 3 and p[1] == "reviewSubmissions":
            if S == "submit_error":
                return self.send(409, {"errors": [{"status": "409", "code": "STATE_ERROR.ENTITY_STATE_INVALID",
                    "title": "appStoreVersions with id 'V1' is not in valid state.",
                    "detail": "This resource cannot be reviewed, please check associated errors to see why.",
                    "meta": {"associatedErrors": {"/v1/appStoreVersions/V1": [
                        {"code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "detail": "You must provide a value for the attribute 'copyright' with this request"}],
                        "/v1/appScreenshotSets": [{"code": "ENTITY_ERROR", "detail": "Screenshots are required."}]}}}]})
            assert body["data"]["attributes"] == {"submitted": True}, body
            state["subs"][p[2]]["state"] = "WAITING_FOR_REVIEW"
            return self.send(200, {"data": {"type": "reviewSubmissions", "id": p[2], "attributes": state["subs"][p[2]]}})

        return self.err(404, "unbekannt: %s %s" % (method, u.path))

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PATCH(self): self.handle_any("PATCH")

srv = HTTPServer(("127.0.0.1", 0), H)
with open(os.environ["MOCK_PORT_FILE"], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY

NOTES="$WORK/notes"
mkdir -p "$NOTES"
printf 'Faster scans.\nNew: “Größte Veränderungen”.\n\n' > "$NOTES/1.2.3.en.txt"
printf 'Schnellere Scans.\n' > "$NOTES/1.2.3.de.txt"

# run_scenario <name> [VAR=wert …]: Server starten, submit ausführen.
# Ergebnis: $WORK/<name>.out (Ausgabe), .log (Anfragen), .summary, .rc
run_scenario() {
    local name=$1; shift
    local port_file="$WORK/$name.port"
    : > "$WORK/$name.log"
    MOCK_SCENARIO=$name MOCK_LOG="$WORK/$name.log" MOCK_PORT_FILE="$port_file" python3 -I "$WORK/mock.py" &
    SERVER_PID=$!
    for _ in $(seq 1 50); do [ -s "$port_file" ] && break; sleep 0.1; done
    [ -s "$port_file" ] || { echo "Mock-Server startet nicht" >&2; exit 1; }
    local rc=0
    env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        ASC_API_BASE="http://127.0.0.1:$(cat "$port_file")" ASC_STATE="$WORK/$name.state" \
        ASC_NOTES_DIR="$NOTES" VERSION=1.2.3 BUILD_NUMBER=42 \
        ASC_JWT_CMD='echo test.token.value' ASC_POLL_INTERVAL=0 ASC_POLL_ATTEMPTS=5 ASC_RETRY_SLEEP=0 \
        GITHUB_STEP_SUMMARY="$WORK/$name.summary" \
        "$@" bash "$ROOT/scripts/asc-submit.sh" submit > "$WORK/$name.out" 2>&1 || rc=$?
    echo "$rc" > "$WORK/$name.rc"
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
}
rc_of() { cat "$WORK/$1.rc"; }
show_on_fail() { if [ "$FAIL" -gt "$1" ]; then sed 's/^/      | /' "$WORK/$2.out"; fi; }

echo "== Release Notes prüfen"
notes_check() { ASC_NOTES_DIR=$1 bash scripts/asc-submit.sh check-notes 1.2.3 > "$WORK/notes.out" 2>&1; }
check "gültige Notes (mit Unicode) werden angenommen" notes_check "$NOTES"
mkdir -p "$WORK/n1"; printf 'x\n' > "$WORK/n1/1.2.3.en.txt"
check "fehlende Datei wird gemeldet" bash -c "! ASC_NOTES_DIR='$WORK/n1' bash scripts/asc-submit.sh check-notes 1.2.3 > '$WORK/n1.out' 2>&1"
check "  … mit Dateinamen" has "$WORK/n1.out" "1.2.3.de.txt fehlt"
mkdir -p "$WORK/n2"; printf 'x\n' > "$WORK/n2/1.2.3.en.txt"; printf ' \n\n' > "$WORK/n2/1.2.3.de.txt"
check "leere Datei wird gemeldet" bash -c "! ASC_NOTES_DIR='$WORK/n2' bash scripts/asc-submit.sh check-notes 1.2.3 > '$WORK/n2.out' 2>&1"
check "  … als leer" has "$WORK/n2.out" "1.2.3.de.txt ist leer"
mkdir -p "$WORK/n3"; printf 'x\n' > "$WORK/n3/1.2.3.en.txt"
python3 -I -c 'import sys; open(sys.argv[1],"w").write("ä"*4000 + "\n\n")' "$WORK/n3/1.2.3.de.txt"
check "4000 Zeichen (8000 Bytes Umlaute) sind erlaubt" notes_check "$WORK/n3"
python3 -I -c 'import sys; open(sys.argv[1],"w").write("a"*4001)' "$WORK/n3/1.2.3.de.txt"
check "4001 Zeichen werden abgelehnt" bash -c "! ASC_NOTES_DIR='$WORK/n3' bash scripts/asc-submit.sh check-notes 1.2.3 > '$WORK/n3.out' 2>&1"
check "  … mit Länge" has "$WORK/n3.out" "4001 Zeichen"
mkdir -p "$WORK/n4"; cp dev/release-notes/TEMPLATE.en.txt "$WORK/n4/1.2.3.en.txt"; cp dev/release-notes/TEMPLATE.de.txt "$WORK/n4/1.2.3.de.txt"
check "unveränderte Vorlage wird abgelehnt" bash -c "! ASC_NOTES_DIR='$WORK/n4' bash scripts/asc-submit.sh check-notes 1.2.3 > '$WORK/n4.out' 2>&1"
check "  … wegen Platzhaltern" has "$WORK/n4.out" "Platzhalter"

echo "== Neue Version: Build abwarten, Version und Lokalisierung anlegen, einreichen"
f=$FAIL
run_scenario fresh
L="$WORK/fresh.log"
check "Erfolg" test "$(rc_of fresh)" = 0
check "App-ID über Bundle-ID gesucht" has "$L" '"p": "/v1/apps", "q": {"filter[bundleId]": "de.stefanrichter.DiskRings"'
check "Build dreimal abgefragt (leer, PROCESSING, VALID)" test "$(count "$L" '"p": "/v1/builds"')" = 3
check "Version mit MANUAL angelegt" has "$L" '"attributes": {"platform": "MAC_OS", "versionString": "1.2.3", "releaseType": "MANUAL"}'
check "en-US und de-DE per POST angelegt" test "$(count "$L" '"m": "POST", "p": "/v1/appStoreVersionLocalizations"')" = 2
whats_new_en() { jq -r 'select(.m == "POST" and .p == "/v1/appStoreVersionLocalizations" and .b.data.attributes.locale == "en-US") | .b.data.attributes.whatsNew' "$L"; }
check "whatsNew Unicode erhalten" test "$(whats_new_en)" = "$(printf 'Faster scans.\nNew: “Größte Veränderungen”.')"
whats_new_trimmed() { jq -e 'select(.m == "POST" and .p == "/v1/appStoreVersionLocalizations") | .b.data.attributes.whatsNew | endswith(".")' "$L" >/dev/null; }
check "whatsNew ohne Leerraum am Ende" whats_new_trimmed
check "Build angehängt" has "$L" '"m": "PATCH", "p": "/v1/appStoreVersions/V101/relationships/build"'
check "Einreichung angelegt" has "$L" '"m": "POST", "p": "/v1/reviewSubmissions"'
check "Item hinzugefügt" has "$L" '"m": "POST", "p": "/v1/reviewSubmissionItems"'
check "eingereicht (submitted: true)" has "$L" '"attributes": {"submitted": true}'
check "Zusammenfassung nennt Einreichung" has "$WORK/fresh.summary" "Zur Prüfung eingereicht"
check "Zusammenfassung nennt manuelle Veröffentlichung" has "$WORK/fresh.summary" "manuelle Veröffentlichung"
check "Token nicht in der Ausgabe" hasnt "$WORK/fresh.out" "test.token.value"
check "Arbeitsverzeichnis ohne Auth-Header danach" test ! -e "$WORK/fresh.state/auth-header"
show_on_fail "$f" fresh

echo "== Vorhandene Version und Einreichung wiederverwenden"
f=$FAIL
run_scenario reuse APPSTORE_APP_ID=APP1 RELEASE_AFTER_APPROVAL=true
L="$WORK/reuse.log"
check "Erfolg" test "$(rc_of reuse)" = 0
check "keine App-Suche mit APPSTORE_APP_ID" hasnt "$L" '"p": "/v1/apps", '
check "keine neue Version" hasnt "$L" '"m": "POST", "p": "/v1/appStoreVersions"'
check "releaseType auf AFTER_APPROVAL geändert" has "$L" '"attributes": {"releaseType": "AFTER_APPROVAL"}'
check "beide Lokalisierungen per PATCH" test "$(count "$L" '"m": "PATCH", "p": "/v1/appStoreVersionLocalizations/')" = 2
check "keine neue Lokalisierung" hasnt "$L" '"m": "POST", "p": "/v1/appStoreVersionLocalizations"'
check "offene Einreichung wiederverwendet" hasnt "$L" '"m": "POST", "p": "/v1/reviewSubmissions"'
check "Item nicht doppelt" hasnt "$L" '"m": "POST", "p": "/v1/reviewSubmissionItems"'
check "S1 eingereicht" has "$L" '"m": "PATCH", "p": "/v1/reviewSubmissions/S1"'
show_on_fail "$f" reuse

echo "== Bearbeitbare ältere Version umbenennen"
f=$FAIL
run_scenario rename APPSTORE_APP_ID=APP1
L="$WORK/rename.log"
check "Erfolg" test "$(rc_of rename)" = 0
check "V0 in 1.2.3 umbenannt" has "$L" '"p": "/v1/appStoreVersions/V0", "q": {}, "b": {"data": {"type": "appStoreVersions", "id": "V0", "attributes": {"versionString": "1.2.3"}}}'
check "keine neue Version" hasnt "$L" '"m": "POST", "p": "/v1/appStoreVersions"'
show_on_fail "$f" rename

echo "== Schon eingereicht"
f=$FAIL
run_scenario already APPSTORE_APP_ID=APP1
L="$WORK/already.log"
check "Erfolg ohne Änderungen" test "$(rc_of already)" = 0
check "Meldung 'bereits eingereicht'" has "$WORK/already.out" "bereits eingereicht"
check "nichts geändert" hasnt "$L" '"m": "PATCH"'
check "Zusammenfassung sagt es" has "$WORK/already.summary" "bereits eingereicht oder freigegeben"
show_on_fail "$f" already

echo "== Andere Einreichung läuft / offene Ablehnung"
f=$FAIL
run_scenario busy APPSTORE_APP_ID=APP1
check "Fehler" test "$(rc_of busy)" = 1
check "klare Meldung" has "$WORK/busy.out" "läuft schon eine andere Einreichung (IN_REVIEW)"
check "nicht eingereicht" hasnt "$WORK/busy.log" '"m": "PATCH", "p": "/v1/reviewSubmissions'
run_scenario unresolved APPSTORE_APP_ID=APP1
check "UNRESOLVED_ISSUES: Fehler mit Hinweis" has "$WORK/unresolved.out" "UNRESOLVED_ISSUES"
show_on_fail "$f" busy

echo "== Apple lehnt die Einreichung ab: Fehlerdetails sichtbar"
f=$FAIL
run_scenario submit_error APPSTORE_APP_ID=APP1
check "Fehler" test "$(rc_of submit_error)" = 1
check "HTTP-Status genannt" has "$WORK/submit_error.out" "HTTP 409"
check "errors[].detail ausgegeben" has "$WORK/submit_error.out" "please check associated errors"
check "associatedErrors ausgegeben" has "$WORK/submit_error.out" "attribute 'copyright'"
check "  … auch Screenshots" has "$WORK/submit_error.out" "Screenshots are required."
check "Zusammenfassung mit Details" has "$WORK/submit_error.summary" "attribute 'copyright'"
check "Zusammenfassung: nicht eingereicht" has "$WORK/submit_error.summary" "Nicht eingereicht"
show_on_fail "$f" submit_error

echo "== Erste Version: whatsNew nicht erlaubt → Warnung, weiter"
f=$FAIL
run_scenario first_version APPSTORE_APP_ID=APP1
check "Erfolg" test "$(rc_of first_version)" = 0
check "Warnung" has "$WORK/first_version.out" "nicht zu"
check "trotzdem eingereicht" has "$WORK/first_version.log" '"attributes": {"submitted": true}'
show_on_fail "$f" first_version

echo "== Build INVALID / Zeitlimit"
run_scenario invalid
check "INVALID: Fehler" test "$(rc_of invalid)" = 1
check "INVALID: Meldung" has "$WORK/invalid.out" "Build 42 ist INVALID"
check "INVALID: keine Version angelegt" hasnt "$WORK/invalid.log" '"p": "/v1/apps/APP1/appStoreVersions"'
run_scenario timeout ASC_POLL_ATTEMPTS=3
check "Zeitlimit: Fehler nach 3 Abfragen" test "$(rc_of timeout)" = 1 -a "$(count "$WORK/timeout.log" '"p": "/v1/builds"')" = 3
check "Zeitlimit: Meldung" has "$WORK/timeout.out" "nach 3 Abfragen noch nicht fertig"

echo "== Wiederholung bei 503/429 und Token-Erneuerung"
printf '0' > "$WORK/tokens"
run_scenario retry ASC_TOKEN_MAX_AGE=0 \
    ASC_JWT_CMD="n=\$(cat '$WORK/tokens'); echo \$((n+1)) > '$WORK/tokens'; echo tok.\$n.abc"
check "Erfolg trotz 503 und 429" test "$(rc_of retry)" = 0
check "App-Suche dreimal" test "$(count "$WORK/retry.log" '"p": "/v1/apps", ')" = 3
check "Token bei jeder Anfrage neu (MAX_AGE=0)" test "$(cat "$WORK/tokens")" -ge "$(wc -l < "$WORK/retry.log")"
check "neue Tokens tatsächlich gesendet" has "$WORK/retry.log" '"auth": "Bearer tok.3.abc"'

echo "== JWT (scripts/asc-jwt.swift) mit openssl prüfen"
J="$WORK/jwt"
mkdir -p "$J"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$J/key.p8" 2>/dev/null
openssl pkey -in "$J/key.p8" -pubout -out "$J/pub.pem" 2>/dev/null
swiftc -O scripts/asc-jwt.swift -o "$J/asc-jwt" 2>"$J/swiftc.err" || { cat "$J/swiftc.err"; exit 1; }
NOW=$(date +%s)
TOKEN=$(ASC_KEY_PATH="$J/key.p8" ASC_KEY_ID=ABCDE12345 ASC_ISSUER_ID=69a6de70-0000-47e3-e053-5b8c7c11a4d1 "$J/asc-jwt")
python3 -I - "$TOKEN" "$J" "$NOW" <<'PY' > "$J/check.out"
import base64, json, sys
tok, d, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
def b64(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
h, p, s = tok.split(".")
hdr, pl, sig = json.loads(b64(h)), json.loads(b64(p)), b64(s)
print("header", hdr == {"alg": "ES256", "kid": "ABCDE12345", "typ": "JWT"})
print("payload", pl["iss"] == "69a6de70-0000-47e3-e053-5b8c7c11a4d1" and pl["aud"] == "appstoreconnect-v1"
      and abs(pl["iat"] - now) < 60 and 0 < pl["exp"] - pl["iat"] <= 1200)
print("siglen", len(sig) == 64)
def der_int(b):
    b = b.lstrip(b"\0") or b"\0"
    if b[0] & 0x80: b = b"\0" + b
    return b"\x02" + bytes([len(b)]) + b
seq = der_int(sig[:32]) + der_int(sig[32:])
open(d + "/sig.der", "wb").write(b"\x30" + bytes([len(seq)]) + seq)
open(d + "/input", "wb").write((h + "." + p).encode())
PY
check "Header alg/kid/typ" has "$J/check.out" "header True"
check "Payload iss/aud/iat/exp (≤ 20 min)" has "$J/check.out" "payload True"
check "Signatur roh r||s (64 Bytes)" has "$J/check.out" "siglen True"
check "Signatur von openssl bestätigt" bash -c "openssl dgst -sha256 -verify '$J/pub.pem' -signature '$J/sig.der' '$J/input' >/dev/null"
printf 'X' >> "$J/input"
check "veränderte Daten werden abgelehnt" bash -c "! openssl dgst -sha256 -verify '$J/pub.pem' -signature '$J/sig.der' '$J/input' >/dev/null 2>&1"
check "Laufzeit über 20 min wird abgelehnt" bash -c "! ASC_JWT_LIFETIME=1201 ASC_KEY_PATH='$J/key.p8' ASC_KEY_ID=A ASC_ISSUER_ID=B '$J/asc-jwt' >/dev/null 2>&1"
printf 'kein schlüssel\n' > "$J/bad.p8"
check "kaputte .p8: Fehler ohne Ausgabe auf stdout" bash -c "out=\$(ASC_KEY_PATH='$J/bad.p8' ASC_KEY_ID=A ASC_ISSUER_ID=B '$J/asc-jwt' 2>/dev/null); [ \$? -ne 0 ] && [ -z \"\$out\" ]"

echo "== Ganzer Ablauf mit echtem JWT und .p8 aus base64"
f=$FAIL
mkdir -p "$WORK/jwtflow.state" && cp "$J/asc-jwt" "$WORK/jwtflow.state/asc-jwt"
# Der Mock kennt nur Szenarien; "jwtflow" verhält sich wie eine frische Version ohne Wartezeit.
run_scenario jwtflow APPSTORE_APP_ID=APP1 ASC_JWT_CMD= \
    NOTARY_API_KEY_ID=ABCDE12345 NOTARY_API_ISSUER_ID=69a6de70-0000-47e3-e053-5b8c7c11a4d1 \
    NOTARY_API_KEY_P8_BASE64="$(base64 < "$J/key.p8")"
check "Erfolg" test "$(rc_of jwtflow)" = 0
check "Bearer-JWT gesendet" has "$WORK/jwtflow.log" '"auth": "Bearer eyJ'
check "dekodierte .p8 danach gelöscht" test ! -e "$WORK/jwtflow.state/asc-key.p8"
show_on_fail "$f" jwtflow

echo
echo "$PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
