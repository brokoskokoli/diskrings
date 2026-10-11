#!/bin/bash
# Schreibt den Sparkle-Appcast (appcast.xml) für genau eine Version nach stdout.
#
#   scripts/make-appcast.sh --version 0.3.0 --build 140 \
#       --url https://github.com/brokoskokoli/diskrings/releases/download/v0.3.0/DiskRings-0.3.0.zip \
#       --length 12345678 --signature <EdDSA-Signatur, base64> \
#       [--min-system 14.0] [--notes-file dev/release-notes/0.3.0.en.txt] \
#       [--notes-url https://github.com/brokoskokoli/diskrings/releases/tag/v0.3.0] \
#       [--date "Sun, 11 Oct 2026 12:00:00 +0000"]
#
# Ein Eintrag (<item>): sparkle:version = CFBundleVersion (Build-Nummer, damit
# vergleicht Sparkle), sparkle:shortVersionString = VERSION, minimumSystemVersion,
# enclosure mit URL, Länge und sparkle:edSignature (von sign_update). Optional
# Release-Notes als reiner Text (<description sparkle:format="plain-text">) und
# ein Link auf die Release-Seite (sparkle:fullReleaseNotesLink, öffnet im Browser).
# Alle Werte werden für XML maskiert (& < > " '). Ungültige Eingaben brechen
# mit Exit-Code 2 ab, ohne etwas auszugeben. Tests: scripts/test-make-appcast.sh.
# Aufgerufen von scripts/ci-release.sh appcast (Release-Workflow, dev/RELEASING.md).
set -euo pipefail

die() { echo "make-appcast: $*" >&2; exit 2; }

VERSION='' BUILD='' URL='' LENGTH='' SIGNATURE='' MIN_SYSTEM=14.0 NOTES_FILE='' NOTES_URL='' DATE=''
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die "Wert fehlt für $1"
    case "$1" in
        --version) VERSION=$2 ;;
        --build) BUILD=$2 ;;
        --url) URL=$2 ;;
        --length) LENGTH=$2 ;;
        --signature) SIGNATURE=$2 ;;
        --min-system) MIN_SYSTEM=$2 ;;
        --notes-file) NOTES_FILE=$2 ;;
        --notes-url) NOTES_URL=$2 ;;
        --date) DATE=$2 ;;
        *) die "Unbekannte Option: $1" ;;
    esac
    shift 2
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "--version ungültig: '$VERSION'"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || die "--build muss eine positive ganze Zahl sein: '$BUILD'"
[[ "$URL" =~ ^https://[^[:space:]/]+/[^[:space:]]+$ ]] || die "--url muss eine https-Adresse sein: '$URL'"
[[ "$LENGTH" =~ ^[1-9][0-9]*$ ]] || die "--length muss eine positive ganze Zahl sein: '$LENGTH'"
# EdDSA (Ed25519): 64 Byte Signatur = 88 Zeichen base64.
[[ "$SIGNATURE" =~ ^[A-Za-z0-9+/]{86}==$ ]] || die "--signature ist keine Ed25519-Signatur (base64, 64 Byte)"
[[ "$MIN_SYSTEM" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "--min-system ungültig: '$MIN_SYSTEM'"
if [ -n "$NOTES_URL" ]; then
    [[ "$NOTES_URL" =~ ^https://[^[:space:]/]+/[^[:space:]]*$ ]] || die "--notes-url muss eine https-Adresse sein"
fi
NOTES=
if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || die "--notes-file nicht gefunden: $NOTES_FILE"
    NOTES=$(cat "$NOTES_FILE")
fi
if [ -z "$DATE" ]; then DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000'); fi
[[ "$DATE" =~ ^[A-Z][a-z]{2},\ [0-9]{2}\ [A-Z][a-z]{2}\ [0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]] \
    || die "--date ist kein RFC-822-Datum: '$DATE'"

# Maskiert Text für XML-Inhalt und Attribute (auch Anführungszeichen).
xml_escape() {
    local s=$1
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    s=${s//\"/&quot;}
    s=${s//\'/&apos;}
    printf '%s' "$s"
}

{
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '  <channel>'
    echo '    <title>DiskRings</title>'
    echo '    <link>https://github.com/brokoskokoli/diskrings</link>'
    echo '    <description>Updates for DiskRings</description>'
    echo '    <language>en</language>'
    echo '    <item>'
    echo "      <title>$(xml_escape "DiskRings $VERSION")</title>"
    echo "      <pubDate>$(xml_escape "$DATE")</pubDate>"
    echo "      <sparkle:version>$(xml_escape "$BUILD")</sparkle:version>"
    echo "      <sparkle:shortVersionString>$(xml_escape "$VERSION")</sparkle:shortVersionString>"
    echo "      <sparkle:minimumSystemVersion>$(xml_escape "$MIN_SYSTEM")</sparkle:minimumSystemVersion>"
    if [ -n "$NOTES_URL" ]; then
        echo "      <sparkle:fullReleaseNotesLink>$(xml_escape "$NOTES_URL")</sparkle:fullReleaseNotesLink>"
    fi
    if [ -n "$NOTES" ]; then
        echo "      <description sparkle:format=\"plain-text\">$(xml_escape "$NOTES")</description>"
    fi
    echo "      <enclosure url=\"$(xml_escape "$URL")\" length=\"$(xml_escape "$LENGTH")\" type=\"application/octet-stream\" sparkle:edSignature=\"$(xml_escape "$SIGNATURE")\"/>"
    echo '    </item>'
    echo '  </channel>'
    echo '</rss>'
}
