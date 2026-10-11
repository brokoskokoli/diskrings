#!/bin/bash
# Lokale Tests für die Sparkle-Teile der Release-Pipeline, ohne GitHub und
# ohne echten Schlüssel (Wegwerf-Schlüssel in einem temporären Verzeichnis):
#
#   scripts/test-make-appcast.sh     # alle Tests (ca. 20–40 s, kompiliert sparkle-ed25519.swift)
#
# Geprüft:
#   - scripts/make-appcast.sh: Felder, XML-Maskierung (& < > " '), Wohlgeformtheit
#     (xmllint), Release-Notes als Text, Ablehnung ungültiger Eingaben.
#   - Sparkle-Version gleich in Package.swift, Package.resolved und scripts/sparkle-tools.sh.
#   - scripts/sparkle-ed25519.swift: öffentlicher Schlüssel aus dem Seed,
#     Prüfung von Signaturen aus Sparkles sign_update (gültig, Datei geändert,
#     falscher Schlüssel).
#   - scripts/ci-release.sh appcast: Ende-zu-Ende mit Attrappe von App und ZIP
#     (Signatur, SHA256SUMS, Pflicht/Warnung ohne Schlüssel, falscher
#     Schlüssel, falscher Schlüssel in der App, Schlüssel nie in der Ausgabe).
#   - scripts/ci-release.sh preflight: Sparkle-Schlüssel im Trockenlauf
#     optional, beim Veröffentlichen Pflicht.
#   - scripts/setup-release-secrets.sh --sparkle: Schritte mit Attrappen von
#     generate_keys und gh (Secret-Inhalt, Schlüsseldatei, nichts ausgegeben).
#
# Das Sparkle-Archiv (für sign_update) wird geladen und per SHA-256 geprüft;
# DISKRINGS_SPARKLE_ARCHIVE=<datei> nimmt eine schon geladene Kopie,
# DISKRINGS_TEST_OFFLINE=1 überspringt alle Tests, die sign_update brauchen.
# Die bash -c-Aufrufe nutzen absichtlich einfache Anführungszeichen (Argumente über "$@").
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/appcast-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

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
xpath() { xmllint --xpath "$2" "$1" 2>/dev/null; }
edv() { "$WORK/ed" verify "$@" >/dev/null; }   # Signatur prüfen, ohne Ausgabe

SIG88="$(head -c 64 /dev/zero | base64)"   # formal gültige Signatur (64 Byte)
URL="https://github.com/brokoskokoli/diskrings/releases/download/v1.2.3/DiskRings-1.2.3.zip"
mk() { scripts/make-appcast.sh --version 1.2.3 --build 140 --url "$URL" --length 4711 --signature "$SIG88" \
    --date "Sun, 11 Oct 2026 12:00:00 +0000" "$@"; }

# --- make-appcast.sh -------------------------------------------------------------
echo "== make-appcast.sh"
mk --notes-url "https://github.com/brokoskokoli/diskrings/releases/tag/v1.2.3" > "$WORK/a.xml"
check "wohlgeformtes XML" xmllint --noout "$WORK/a.xml"
NS='//*[local-name()="item"]'
check "sparkle:version = Build-Nummer" test "$(xpath "$WORK/a.xml" "string($NS/*[local-name()='version'])")" = 140
check "shortVersionString = VERSION" test "$(xpath "$WORK/a.xml" "string($NS/*[local-name()='shortVersionString'])")" = 1.2.3
check "minimumSystemVersion 14.0" test "$(xpath "$WORK/a.xml" "string($NS/*[local-name()='minimumSystemVersion'])")" = 14.0
check "enclosure url" test "$(xpath "$WORK/a.xml" "string($NS/enclosure/@url)")" = "$URL"
check "enclosure length" test "$(xpath "$WORK/a.xml" "string($NS/enclosure/@length)")" = 4711
check "enclosure edSignature" test "$(xpath "$WORK/a.xml" "string($NS/enclosure/@*[local-name()='edSignature'])")" = "$SIG88"
check "fullReleaseNotesLink" has "$WORK/a.xml" "<sparkle:fullReleaseNotesLink>https://github.com/brokoskokoli/diskrings/releases/tag/v1.2.3</sparkle:fullReleaseNotesLink>"
check "Sparkle-Namensraum" has "$WORK/a.xml" 'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'
check "pubDate" has "$WORK/a.xml" "<pubDate>Sun, 11 Oct 2026 12:00:00 +0000</pubDate>"
check "ohne Notizen keine description im item" test -z "$(xpath "$WORK/a.xml" "$NS/description")"

# Maskierung: Release-Notes und URLs mit Sonderzeichen.
printf '%s\n' '• Fixed: <script>alert("x")</script> & "quotes" '"'"'single'"'"'' 'Zeile 2 – Ünïcødé 日本' > "$WORK/notes.txt"
scripts/make-appcast.sh --version 1.2.3-beta.1 --build 7 --url "https://example.org/a?x=1&y=<2>" --length 1 \
    --signature "$SIG88" --notes-file "$WORK/notes.txt" --notes-url "https://example.org/n?a=1&b=2" > "$WORK/b.xml"
check "maskiertes XML wohlgeformt" xmllint --noout "$WORK/b.xml"
check "& in URL maskiert" has "$WORK/b.xml" 'url="https://example.org/a?x=1&amp;y=&lt;2&gt;"'
check "URL nach dem Parsen unverändert" test "$(xpath "$WORK/b.xml" "string($NS/enclosure/@url)")" = "https://example.org/a?x=1&y=<2>"
check "Notizen nach dem Parsen unverändert" test "$(xpath "$WORK/b.xml" "string($NS/description)")" = "$(cat "$WORK/notes.txt")"
check "kein rohes <script> im XML" hasnt "$WORK/b.xml" "<script>"
check "Notizen als reiner Text" has "$WORK/b.xml" '<description sparkle:format="plain-text">'
check "Vorabversion erlaubt" test "$(xpath "$WORK/b.xml" "string($NS/*[local-name()='shortVersionString'])")" = 1.2.3-beta.1
check "ohne --date ein RFC-822-Datum" grep -qE '<pubDate>[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} 20[0-9]{2} ' "$WORK/b.xml"

reject() { # reject <beschreibung> <argumente…>
    local what=$1; shift
    local out rc=0
    out=$(scripts/make-appcast.sh "$@" 2>/dev/null) || rc=$?
    if [ "$rc" = 2 ] && [ -z "$out" ]; then ok "lehnt ab: $what"; else bad "lehnt ab: $what (rc=$rc)"; fi
}
BASE=(--version 1.2.3 --build 140 --url "$URL" --length 4711 --signature "$SIG88")
reject "ohne Argumente"
reject "http-URL" --version 1.2.3 --build 140 --url "http://x/a.zip" --length 1 --signature "$SIG88"
reject "URL mit Leerzeichen" --version 1.2.3 --build 140 --url "https://x/a b.zip" --length 1 --signature "$SIG88"
reject "Länge 0" --version 1.2.3 --build 140 --url "$URL" --length 0 --signature "$SIG88"
reject "Länge keine Zahl" --version 1.2.3 --build 140 --url "$URL" --length 12a --signature "$SIG88"
reject "Build 0" --version 1.2.3 --build 0 --url "$URL" --length 1 --signature "$SIG88"
reject "Build mit Punkt" --version 1.2.3 --build 1.2 --url "$URL" --length 1 --signature "$SIG88"
reject "Version ungültig" --version "1.2" --build 1 --url "$URL" --length 1 --signature "$SIG88"
reject "Version mit XML" --version '1.2.3<x>' --build 1 --url "$URL" --length 1 --signature "$SIG88"
reject "Signatur zu kurz" --version 1.2.3 --build 1 --url "$URL" --length 1 --signature "AAAA"
reject "Signatur mit Anführungszeichen" --version 1.2.3 --build 1 --url "$URL" --length 1 --signature "${SIG88:0:85}\"=="
reject "unbekannte Option" "${BASE[@]}" --foo bar
reject "Wert fehlt" "${BASE[@]}" --notes-url
reject "Notizdatei fehlt" "${BASE[@]}" --notes-file "$WORK/gibtsnicht.txt"
reject "Notiz-URL http" "${BASE[@]}" --notes-url "http://x/"
reject "min-system ungültig" "${BASE[@]}" --min-system "14"
reject "Datum ungültig" "${BASE[@]}" --date "2026-10-11"

# --- Versionen ------------------------------------------------------------------
echo "== Sparkle-Version überall gleich"
# shellcheck source=scripts/sparkle-tools.sh
source scripts/sparkle-tools.sh
RESOLVED=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print([p["state"]["version"] for p in d["pins"] if p["identity"]=="sparkle"][0])' Package.resolved)
check "Package.resolved = sparkle-tools.sh ($SPARKLE_VERSION)" test "$RESOLVED" = "$SPARKLE_VERSION"
check "Package.swift exact = sparkle-tools.sh" grep -qF "sparkle-project/Sparkle\", exact: \"$SPARKLE_VERSION\"" Package.swift
check "Archiv-URL zur Version" test "$SPARKLE_ARCHIVE_URL" = "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
check "SHA-256 hat 64 Hex-Zeichen" grep -qE '^[0-9a-f]{64}$' <<<"$SPARKLE_ARCHIVE_SHA256"

# --- make-app.sh-Hilfen (sparkle-tools.sh) ------------------------------------------
echo "== make-app: rpath und Signatur des Frameworks"
printf 'int main(void) { return 0; }\n' > "$WORK/m.c"
if clang -arch arm64 -arch x86_64 -o "$WORK/m" "$WORK/m.c" -Wl,-rpath,/x/.build/out/Products/Release/PackageFrameworks \
    -Wl,-rpath,@loader_path -Wl,-rpath,/y/.build/z 2>"$WORK/clang.err"; then
    rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }'; }
    check "Testbinary universal mit doppelten rpaths" test "$(rpaths "$WORK/m" | grep -c '/.build/')" = 4
    if bash -c 'set -euo pipefail; source scripts/sparkle-tools.sh; sparkle_fix_rpaths "$1"' _ "$WORK/m" 2>"$WORK/rp.err"; then
        ok "universal: rpaths in den Build-Ordner entfernt, ohne Abbruch"
    else cat "$WORK/rp.err"; bad "universal: rpaths in den Build-Ordner entfernt, ohne Abbruch"; fi
    check "kein .build-rpath mehr" bash -c '! otool -l "$1" | grep -q "/.build/"' _ "$WORK/m"
    check "@executable_path/../Frameworks je Architektur einmal" test "$(rpaths "$WORK/m" | grep -cx '@executable_path/../Frameworks')" = 2
    check "andere rpaths bleiben" test "$(rpaths "$WORK/m" | grep -cx '@loader_path')" = 2
    check "zweiter Lauf ändert nichts (idempotent)" bash -c 'set -euo pipefail; source scripts/sparkle-tools.sh; sparkle_fix_rpaths "$1"; test "$(otool -l "$1" | grep -c "@executable_path/../Frameworks")" = 2' _ "$WORK/m"
else
    cat "$WORK/clang.err"; bad "Testbinary bauen (clang)"
fi

FW=$WORK/fw/Sparkle.framework
mkdir -p "$FW/Versions/B/XPCServices/Installer.xpc" "$FW/Versions/B/XPCServices/Downloader.xpc" "$FW/Versions/B/Updater.app"
touch "$FW/Versions/B/Autoupdate"
sign_test() { # sign_test <fehlschlag bei Muster|-> → Ausgabe: Aufrufe, dann "rc=<code>" und "weiter"
    bash -c '
        set -euo pipefail
        source scripts/sparkle-tools.sh
        fail_on=$2
        mock_codesign() { echo "codesign $*"; case "$*" in *"$fail_on"*) return 124 ;; esac; }
        rc=0
        sparkle_sign_framework "$1" mock_codesign --force --sign X || rc=$?
        echo "rc=$rc"
        echo weiter
    ' _ "$FW" "$1" > "$WORK/sign.out" 2>&1
}
sign_test "nie-vorhanden"
check "Signatur: Reihenfolge von innen nach außen" test "$(grep '^codesign' "$WORK/sign.out" | awk '{print $NF}' | sed "s|$FW|FW|")" = \
    "$(printf '%s\n' FW/Versions/B/XPCServices/Installer.xpc FW/Versions/B/XPCServices/Downloader.xpc FW/Versions/B/Autoupdate FW/Versions/B/Updater.app FW)"
check "Downloader.xpc behält Entitlements" grep -q -- '--preserve-metadata=entitlements .*Downloader.xpc$' "$WORK/sign.out"
check "kein --deep" hasnt "$WORK/sign.out" "--deep"
check "Erfolg: rc=0" has "$WORK/sign.out" "rc=0"
sign_test "Autoupdate"
check "Zeitüberschreitung: Code 124 bleibt erhalten" has "$WORK/sign.out" "rc=124"
check "Zeitüberschreitung: Aufrufer läuft unter set -e weiter (Erklärung möglich)" has "$WORK/sign.out" "weiter"
check "nach dem Fehler nicht weiter signiert" hasnt "$WORK/sign.out" "Updater.app"
check "make-app.sh nutzt die geprüften Hilfen" bash -c 'grep -q "sparkle_fix_rpaths" scripts/make-app.sh && grep -q "sparkle_sign_framework" scripts/make-app.sh'
check "make-app.sh: Developer-ID-Zweig fängt den Code ab (|| rc=\$?)" \
    bash -c 'grep -A1 "sparkle_sign_framework \"\$SPARKLE_FW\" codesign_with_timeout" scripts/make-app.sh | grep -qF "|| rc=\$?"'

# --- sparkle-ed25519.swift -----------------------------------------------------------
echo "== sparkle-ed25519.swift"
swiftc -O scripts/sparkle-ed25519.swift -o "$WORK/ed" 2>"$WORK/swiftc.err" || { cat "$WORK/swiftc.err"; exit 1; }
(umask 077; head -c 32 /dev/urandom | base64 > "$WORK/k1.key"; head -c 32 /dev/urandom | base64 > "$WORK/k2.key")
PUB1=$("$WORK/ed" public-key < "$WORK/k1.key")
PUB2=$("$WORK/ed" public-key < "$WORK/k2.key")
check "öffentlicher Schlüssel: 32 Byte base64" test "$(printf '%s' "$PUB1" | base64 --decode | wc -c | tr -d ' ')" = 32
check "verschiedene Seeds, verschiedene Schlüssel" test "$PUB1" != "$PUB2"
check "public-key lehnt 64-Byte-Eingabe ab" bash -c '! head -c 64 /dev/urandom | base64 | "$1" public-key 2>/dev/null' _ "$WORK/ed"
check "verify lehnt kaputten Schlüssel ab (Exit 2)" bash -c '"$1" verify AAAA "$2" "$3" 2>/dev/null; test $? = 2' _ "$WORK/ed" "$SIG88" "$WORK/a.xml"

SIGN_UPDATE=
if [ "${DISKRINGS_TEST_OFFLINE:-0}" != "1" ]; then
    if sparkle_fetch_tools "$WORK/sparkle" sign_update 2>"$WORK/fetch.err"; then
        SIGN_UPDATE="$WORK/sparkle/tools/bin/sign_update"
        ok "Sparkle-Archiv geladen, Prüfsumme stimmt"
    else
        cat "$WORK/fetch.err"; bad "Sparkle-Archiv laden"
    fi
    # Falsche Prüfsumme wird abgelehnt.
    printf 'kein archiv' > "$WORK/fake.tar.xz"
    check "falsches Archiv abgelehnt" bash -c 'source scripts/sparkle-tools.sh; ! DISKRINGS_SPARKLE_ARCHIVE="$1" sparkle_fetch_tools "$2" sign_update 2>/dev/null' _ "$WORK/fake.tar.xz" "$WORK/fake"
    check "aus falschem Archiv nichts entpackt" test ! -e "$WORK/fake/tools/bin/sign_update"
fi

if [ -n "$SIGN_UPDATE" ]; then
    head -c 200000 /dev/urandom > "$WORK/f.zip"
    SIG=$("$SIGN_UPDATE" --ed-key-file - -p "$WORK/f.zip" < "$WORK/k1.key")
    check "sign_update-Signatur verifiziert" edv "$PUB1" "$SIG" "$WORK/f.zip"
    check "falscher Schlüssel: nicht verifiziert" bash -c '! "$1" verify "$2" "$3" "$4" 2>/dev/null' _ "$WORK/ed" "$PUB2" "$SIG" "$WORK/f.zip"
    cp "$WORK/f.zip" "$WORK/g.zip"; printf 'x' >> "$WORK/g.zip"
    check "geänderte Datei: nicht verifiziert" bash -c '! "$1" verify "$2" "$3" "$4" 2>/dev/null' _ "$WORK/ed" "$PUB1" "$SIG" "$WORK/g.zip"
    check "Signatur passt zu make-appcast" bash -c 'scripts/make-appcast.sh --version 1.2.3 --build 1 --url "$1" --length 1 --signature "$2" >/dev/null' _ "$URL" "$SIG"
fi

# --- ci-release.sh appcast ---------------------------------------------------------
VERSION=$(tr -d '[:space:]' < VERSION)
fake_release() { # fake_release <ordner> <öffentlicher Schlüssel in der App>
    local d=$1
    mkdir -p "$d/dist" "$d/DiskRings.app/Contents"
    head -c 300000 /dev/urandom > "$d/dist/DiskRings-$VERSION.zip"
    (cd "$d/dist" && shasum -a 256 "DiskRings-$VERSION.zip" > SHA256SUMS)
    cat > "$d/DiskRings.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>321</string>
<key>SUPublicEDKey</key><string>$2</string>
</dict></plist>
PLIST
}
appcast() { # appcast <ordner> <öffentlicher Schlüssel (Repo-Datei)> [env…] → Ausgabe in <ordner>/out
    local d=$1 pub=$2; shift 2
    printf '%s\n' "$pub" > "$d/pub.txt"
    env -u GITHUB_ACTIONS -u SPARKLE_ED_PRIVATE_KEY -u DISKRINGS_SPARKLE_ACCOUNT \
        DISKRINGS_DIST="$d/dist" DISKRINGS_APP="$d/DiskRings.app" DISKRINGS_UPDATE_KEY_FILE="$d/pub.txt" \
        DISKRINGS_SPARKLE_ARCHIVE="${DISKRINGS_SPARKLE_ARCHIVE:-$WORK/sparkle/download/Sparkle-$SPARKLE_VERSION.tar.xz}" \
        "$@" scripts/ci-release.sh appcast > "$d/out" 2>&1
}

if [ -n "$SIGN_UPDATE" ]; then
    echo "== ci-release.sh appcast"
    K1=$(tr -d '[:space:]' < "$WORK/k1.key")
    E=$WORK/e1; fake_release "$E" "$PUB1"
    if appcast "$E" "$PUB1" SPARKLE_ED_PRIVATE_KEY="$K1" DISKRINGS_REQUIRE_APPCAST=true; then
        ok "appcast erzeugt"
        A=$E/dist/appcast.xml
        check "appcast.xml wohlgeformt" xmllint --noout "$A"
        check "Build-Nummer aus der App" test "$(xpath "$A" "string($NS/*[local-name()='version'])")" = 321
        check "Version aus VERSION" test "$(xpath "$A" "string($NS/*[local-name()='shortVersionString'])")" = "$VERSION"
        check "URL auf das Release-Asset" test "$(xpath "$A" "string($NS/enclosure/@url)")" = \
            "https://github.com/brokoskokoli/diskrings/releases/download/v$VERSION/DiskRings-$VERSION.zip"
        check "Länge = ZIP-Größe" test "$(xpath "$A" "string($NS/enclosure/@length)")" = "$(stat -f %z "$E/dist/DiskRings-$VERSION.zip")"
        S=$(xpath "$A" "string($NS/enclosure/@*[local-name()='edSignature'])")
        check "Signatur im Appcast verifiziert gegen die App" edv "$PUB1" "$S" "$E/dist/DiskRings-$VERSION.zip"
        check "SHA256SUMS enthält appcast.xml" bash -c 'cd "$1" && shasum -a 256 -c SHA256SUMS >/dev/null && grep -q " appcast.xml$" SHA256SUMS' _ "$E/dist"
        check "privater Schlüssel nicht in der Ausgabe" hasnt "$E/out" "$K1"
        check "privater Schlüssel nicht im Appcast" hasnt "$A" "$K1"
        if [ -f "dev/release-notes/$VERSION.en.txt" ]; then
            check "Release-Notes aus dev/release-notes" test "$(xpath "$A" "string($NS/description)")" = "$(cat "dev/release-notes/$VERSION.en.txt")"
        fi
        # Zweiter Lauf: appcast.xml steht nur einmal in SHA256SUMS.
        appcast "$E" "$PUB1" SPARKLE_ED_PRIVATE_KEY="$K1" || true
        check "SHA256SUMS ohne doppelten Eintrag" test "$(grep -c ' appcast.xml$' "$E/dist/SHA256SUMS")" = 1
    else
        cat "$E/out"; bad "appcast erzeugt"
    fi

    E=$WORK/e2; fake_release "$E" "$PUB1"
    if appcast "$E" "$PUB1" DISKRINGS_REQUIRE_APPCAST=false; then
        check "ohne Schlüssel, nicht Pflicht: Warnung, kein Appcast" test ! -e "$E/dist/appcast.xml"
        check "Warnung ausgegeben" has "$E/out" "Kein appcast.xml"
    else
        cat "$E/out"; bad "ohne Schlüssel, nicht Pflicht: Exit 0"
    fi
    if appcast "$E" "$PUB1" DISKRINGS_REQUIRE_APPCAST=true; then bad "ohne Schlüssel, Pflicht: Abbruch"; else ok "ohne Schlüssel, Pflicht: Abbruch"; fi
    if appcast "$E" "" SPARKLE_ED_PRIVATE_KEY="$K1" DISKRINGS_REQUIRE_APPCAST=true; then
        bad "ohne öffentlichen Schlüssel, Pflicht: Abbruch"
    else ok "ohne öffentlichen Schlüssel, Pflicht: Abbruch"; fi

    E=$WORK/e3; fake_release "$E" "$PUB2"
    K2=$(tr -d '[:space:]' < "$WORK/k2.key")
    if appcast "$E" "$PUB2" SPARKLE_ED_PRIVATE_KEY="$K1"; then
        bad "Secret passt nicht zum öffentlichen Schlüssel: Abbruch"
    else
        ok "Secret passt nicht zum öffentlichen Schlüssel: Abbruch"
        check "kein Appcast bei falschem Schlüssel" test ! -e "$E/dist/appcast.xml"
        check "Meldung nennt das Schlüsselpaar" has "$E/out" "anderen Schlüsselpaar"
    fi
    E=$WORK/e4; fake_release "$E" "$PUB2"
    if appcast "$E" "$PUB1" SPARKLE_ED_PRIVATE_KEY="$K1"; then
        bad "App hat anderen Schlüssel als die Repo-Datei: Abbruch"
    else ok "App hat anderen Schlüssel als die Repo-Datei: Abbruch"; fi
    E=$WORK/e5; fake_release "$E" "$PUB2"
    if appcast "$E" "$PUB2" SPARKLE_ED_PRIVATE_KEY="kein base64!"; then
        bad "ungültiges Secret: Abbruch"
    else ok "ungültiges Secret: Abbruch"; fi
    if appcast "$E" "$PUB2" SPARKLE_ED_PRIVATE_KEY="$K2" DISKRINGS_SPARKLE_ARCHIVE="$WORK/fake.tar.xz"; then
        bad "falsches Sparkle-Archiv: Abbruch"
    else ok "falsches Sparkle-Archiv: Abbruch"; fi
fi

# --- ci-release.sh preflight -------------------------------------------------------
echo "== ci-release.sh preflight (Sparkle)"
P8=$(printf -- '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n' | base64)
preflight() { # preflight <öffentlicher Schlüssel> <dry_run> [env…]
    local pub=$1 dry=$2; shift 2
    printf '%s\n' "$pub" > "$WORK/pf-pub.txt"
    env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u SPARKLE_ED_PRIVATE_KEY \
        GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_TYPE=tag GITHUB_REF_NAME="v$VERSION" DRY_RUN="$dry" \
        MACOS_CERTIFICATE_P12_BASE64=AAAA MACOS_CERTIFICATE_PASSWORD=x NOTARY_API_KEY_P8_BASE64="$P8" \
        NOTARY_API_KEY_ID=ABCDEFGHIJ NOTARY_API_ISSUER_ID=12345678-1234-1234-1234-123456789abc \
        DISKRINGS_UPDATE_KEY_FILE="$WORK/pf-pub.txt" "$@" scripts/ci-release.sh preflight > "$WORK/pf.out" 2>&1
}
K1=$(tr -d '[:space:]' < "$WORK/k1.key")
if preflight "" true; then
    ok "Trockenlauf ohne Sparkle-Schlüssel: weiter"
    check "Trockenlauf: Warnung" has "$WORK/pf.out" "Automatische Updates nicht eingerichtet"
else cat "$WORK/pf.out"; bad "Trockenlauf ohne Sparkle-Schlüssel: weiter"; fi
if preflight "" false; then bad "Veröffentlichen ohne Sparkle-Schlüssel: Abbruch"
else ok "Veröffentlichen ohne Sparkle-Schlüssel: Abbruch"; fi
if preflight "$PUB1" false; then bad "Veröffentlichen ohne Secret: Abbruch"; else ok "Veröffentlichen ohne Secret: Abbruch"; fi
if preflight "" false SPARKLE_ED_PRIVATE_KEY="$K1"; then bad "Veröffentlichen ohne öffentlichen Schlüssel: Abbruch"
else ok "Veröffentlichen ohne öffentlichen Schlüssel: Abbruch"; fi
if preflight "$PUB1" false SPARKLE_ED_PRIVATE_KEY="$K1"; then ok "Veröffentlichen mit beiden Schlüsseln: weiter"
else cat "$WORK/pf.out"; bad "Veröffentlichen mit beiden Schlüsseln: weiter"; fi
check "Secret nicht in der Ausgabe" hasnt "$WORK/pf.out" "$K1"
if preflight "AAAA" true SPARKLE_ED_PRIVATE_KEY="$K1"; then bad "ungültiger öffentlicher Schlüssel: Abbruch"
else ok "ungültiger öffentlicher Schlüssel: Abbruch"; fi
if preflight "$PUB1" true SPARKLE_ED_PRIVATE_KEY="%%%"; then bad "ungültiges Secret: Abbruch"
else ok "ungültiges Secret: Abbruch"; fi

# --- Schlüsselformat streng, Schlüssel nie in der Ausgabe -------------------------------
echo "== privater Schlüssel: strenges Format, nie in der Ausgabe"
b64() { python3 -I -c 'import base64,os,sys; n=int(sys.argv[1]); print(base64.b64encode(os.urandom(n)).decode())' "$1"; }
K32=$(b64 32); K96=$(b64 96)
URLSAFE=$(python3 -I -c 'import base64; print(base64.urlsafe_b64encode(bytes([0xfb,0xff]*16)).decode())')
BADKEYS=("$URLSAFE" "${K32}AB" "${K32%=}" "$(b64 33)" "$(b64 64)" "$(b64 95)" "$(b64 31)" "${K32:0:20} ${K32:20}x")
BADNAMES=("URL-safe-Alphabet" "Zeichen nach =" "fehlendes Padding" "33 Byte" "64 Byte" "95 Byte" "31 Byte" "Leerzeichen und Rest")
for i in "${!BADKEYS[@]}"; do
    if preflight "$PUB1" true SPARKLE_ED_PRIVATE_KEY="${BADKEYS[$i]}"; then
        bad "Vorprüfung lehnt ab: ${BADNAMES[$i]}"
    else
        ok "Vorprüfung lehnt ab: ${BADNAMES[$i]}"
    fi
    check "Vorprüfung gibt den Schlüssel nicht aus: ${BADNAMES[$i]}" hasnt "$WORK/pf.out" "${BADKEYS[$i]}"
done
if preflight "$PUB1" true SPARKLE_ED_PRIVATE_KEY="$K96"; then ok "Vorprüfung nimmt 96-Byte-Schlüssel (altes Format)"
else cat "$WORK/pf.out"; bad "Vorprüfung nimmt 96-Byte-Schlüssel (altes Format)"; fi
if preflight "$PUB1" true SPARKLE_ED_PRIVATE_KEY="$K32"$'\n'; then ok "Vorprüfung: Zeilenumbruch am Ende egal"
else bad "Vorprüfung: Zeilenumbruch am Ende egal"; fi

# Attrappe von sign_update, die (wie das echte bei kaputtem base64) den Schlüssel nach stderr schreibt.
cat > "$WORK/leaky-sign_update" <<'SH'
#!/bin/bash
key=$(cat)
echo "ERROR! Failed to decode base64 encoded key data from: $key" >&2
echo "noch eine Zeile mit $key" >&2
exit 1
SH
chmod +x "$WORK/leaky-sign_update"
E=$WORK/e6; fake_release "$E" "$PUB1"
if appcast "$E" "$PUB1" SPARKLE_ED_PRIVATE_KEY="$K32" DISKRINGS_SIGN_UPDATE="$WORK/leaky-sign_update"; then
    bad "sign_update schlägt fehl: Abbruch"
else
    ok "sign_update schlägt fehl: Abbruch"
    check "stderr von sign_update nicht ausgegeben (kein Schlüssel)" hasnt "$E/out" "$K32"
    check "allgemeine Fehlermeldung" has "$E/out" "sign_update fehlgeschlagen"
fi
for i in "${!BADKEYS[@]}"; do
    E=$WORK/e7-$i; fake_release "$E" "$PUB1"
    if appcast "$E" "$PUB1" SPARKLE_ED_PRIVATE_KEY="${BADKEYS[$i]}" DISKRINGS_SIGN_UPDATE="$WORK/leaky-sign_update"; then
        bad "appcast lehnt ab: ${BADNAMES[$i]}"
    else ok "appcast lehnt ab: ${BADNAMES[$i]}"; fi
    check "appcast gibt den Schlüssel nicht aus: ${BADNAMES[$i]}" hasnt "$E/out" "${BADKEYS[$i]}"
done
E=$WORK/e8; fake_release "$E" "$PUB1"
if appcast "$E" "$PUB1" SPARKLE_ED_PRIVATE_KEY="$K32" DISKRINGS_SIGN_UPDATE="$WORK/leaky-sign_update" GITHUB_ACTIONS=true; then
    bad "DISKRINGS_SIGN_UPDATE in der CI abgelehnt"
else
    check "DISKRINGS_SIGN_UPDATE in der CI abgelehnt" has "$E/out" "DISKRINGS_SIGN_UPDATE"
fi

# --- setup-release-secrets.sh --sparkle ------------------------------------------------
echo "== setup-release-secrets.sh --sparkle (Attrappen)"
M=$WORK/mock; mkdir -p "$M/bin" "$M/state"
cat > "$M/bin/generate_keys" <<'SH'
#!/bin/bash
# Attrappe von Sparkles generate_keys: Schlüssel liegt in $MOCK_STATE/seed-<konto>.
set -euo pipefail
account=ed25519 mode=gen out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --account) account=$2; shift 2 ;;
        -p) mode=print; shift ;;
        -x) mode=export; out=$2; shift 2 ;;
        *) echo "unbekannt: $1" >&2; exit 64 ;;
    esac
done
seed="$MOCK_STATE/seed-$account"
case "$mode" in
    print) [ -f "$seed" ] || exit 1; "$MOCK_ED" public-key < "$seed" ;;
    export) [ -f "$seed" ] || exit 1; cp "$seed" "$out" ;;
    gen) [ -f "$seed" ] || head -c 32 /dev/urandom | base64 > "$seed"
         echo "A key has been generated and saved in your keychain."; "$MOCK_ED" public-key < "$seed" ;;
esac
SH
cat > "$M/bin/gh" <<'SH'
#!/bin/bash
# Attrappe von gh: nur "secret set NAME …", Inhalt von stdin nach $MOCK_STATE/secret-NAME.
set -euo pipefail
echo "$*" >> "$MOCK_STATE/gh.log"
[ "$1 $2" = "secret set" ] || exit 1
cat > "$MOCK_STATE/secret-$3"
SH
chmod +x "$M/bin/generate_keys" "$M/bin/gh"
setup_run() { # setup_run <antworten> <öffentliche Schlüsseldatei> → $M/out, Rückgabe des Laufs
    local answers=$1 pubfile=$2
    MOCK_STATE="$M/state" MOCK_ED="$WORK/ed" PATH="$M/bin:$PATH" DISKRINGS_UPDATE_KEY_FILE="$pubfile" \
        bash -c '
            set -euo pipefail
            source scripts/setup-release-secrets.sh
            WORK=$(mktemp -d "$1/setup.XXXXXX"); chmod 700 "$WORK"
            echo "$WORK" > "$1/setup-work"
            trap cleanup EXIT
            REPO=test/repo; SECRET_SCOPE=(--env release); MODE=sparkle
            SPARKLE_BIN="$1/mock/bin"
            step_sparkle_key
            step_sparkle_export
            step_sparkle_secret
        ' _ "$WORK" <<<"$answers" > "$M/out" 2>&1
}
PUBFILE=$WORK/repo-pub.txt
if setup_run $'j\nj\nj' "$PUBFILE"; then
    ok "neuer Schlüssel: Durchlauf"
    SEED=$(cat "$M/state/seed-diskrings")
    check "Konto diskrings" test -f "$M/state/seed-diskrings"
    check "Secret = exportierter privater Schlüssel" test "$(cat "$M/state/secret-SPARKLE_ED_PRIVATE_KEY")" = "$(tr -d '[:space:]' <<<"$SEED")"
    check "gh secret set im Environment release" grep -qx "secret set SPARKLE_ED_PRIVATE_KEY --repo test/repo --env release" "$M/state/gh.log"
    check "öffentlicher Schlüssel geschrieben" test "$(cat "$PUBFILE")" = "$("$WORK/ed" public-key < "$M/state/seed-diskrings")"
    check "privater Schlüssel nicht ausgegeben" hasnt "$M/out" "$(tr -d '[:space:]' <<<"$SEED")"
    check "temporäres Verzeichnis gelöscht" test ! -e "$(cat "$WORK/setup-work")"
else
    cat "$M/out"; bad "neuer Schlüssel: Durchlauf"
fi
# Vorhandener Schlüssel im Schlüsselbund, gleicher in der Repo-Datei: ohne Rückfrage zum Überschreiben.
rm -f "$M/state/secret-SPARKLE_ED_PRIVATE_KEY"
if setup_run $'j\nj' "$PUBFILE"; then
    ok "vorhandener Schlüssel: Durchlauf"
    check "Secret erneut gesetzt" test -s "$M/state/secret-SPARKLE_ED_PRIVATE_KEY"
else cat "$M/out"; bad "vorhandener Schlüssel: Durchlauf"; fi
# Repo-Datei hat einen anderen Schlüssel: Ablehnen der Rückfrage bricht ab, Datei bleibt.
printf '%s\n' "$PUB2" > "$PUBFILE"
rm -f "$M/state/secret-SPARKLE_ED_PRIVATE_KEY"
if setup_run $'j\nn' "$PUBFILE"; then bad "anderer Schlüssel in der Repo-Datei: Abbruch"
else
    ok "anderer Schlüssel in der Repo-Datei: Abbruch"
    check "Repo-Datei unverändert" test "$(cat "$PUBFILE")" = "$PUB2"
    check "kein Secret gesetzt" test ! -e "$M/state/secret-SPARKLE_ED_PRIVATE_KEY"
    check "Warnung zum Schlüsselwechsel" has "$M/out" "ANDEREN Schlüssel"
fi
# Exportierter Schlüssel passt nicht zum öffentlichen (z. B. falsches Konto): Abbruch ohne Secret.
printf '%s\n' "" > "$PUBFILE"
cp "$WORK/k2.key" "$M/state/seed-other"
sed -i '' 's|export) \[ -f "$seed" \] \|\| exit 1; cp "$seed" "$out" ;;|export) cp "$MOCK_STATE/seed-other" "$out" ;;|' "$M/bin/generate_keys"
if setup_run $'j\nj' "$PUBFILE"; then bad "Export passt nicht: Abbruch"
else
    ok "Export passt nicht: Abbruch"
    check "kein Secret bei falschem Export" test ! -e "$M/state/secret-SPARKLE_ED_PRIVATE_KEY"
fi

echo
echo "Ergebnis: $PASS ok, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
