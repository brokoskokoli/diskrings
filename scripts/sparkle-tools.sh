#!/bin/bash
# Gemeinsame Angaben zu den Sparkle-Werkzeugen (sign_update, generate_keys) für
# scripts/ci-release.sh und scripts/setup-release-secrets.sh, dazu die
# Sparkle-Schritte von scripts/make-app.sh (rpath, Signatur); nur zum Einbinden
# mit `source`.
#
# Die Werkzeuge kommen aus dem offiziellen Release-Archiv derselben Version wie
# die SwiftPM-Abhängigkeit (Package.swift, Package.resolved; der Abgleich steht
# in scripts/test-make-appcast.sh). SHA-256 = "digest" des Release-Assets bei
# GitHub, geprüft 10/2026 (Release vom 13.09.2026, Tag-Commit
# eef1a539a373c1f1a320624b1130fc5de7b2e100).
#
#   sparkle_fetch_tools <ordner> [werkzeug…]   # Standard: sign_update
#
# lädt das Archiv nach <ordner>/download (oder nimmt DISKRINGS_SPARKLE_ARCHIVE,
# eine schon geladene Datei), prüft die SHA-256-Summe und entpackt NUR die
# genannten Werkzeuge nach <ordner>/tools/bin. Rückgabe 0 oder 1 (mit Meldung
# auf stderr). Das Archiv ist bis zur Prüfung nicht vertrauenswürdig und wird
# vorher nicht entpackt.
SPARKLE_VERSION=2.10.0
SPARKLE_ARCHIVE_URL=https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz
SPARKLE_ARCHIVE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

sparkle_fetch_tools() {
    local dir=$1 archive sum tool
    shift
    [ "$#" -gt 0 ] || set -- sign_update
    mkdir -p "$dir/download" "$dir/tools"
    if [ -n "${DISKRINGS_SPARKLE_ARCHIVE:-}" ]; then
        archive=$DISKRINGS_SPARKLE_ARCHIVE
    else
        archive="$dir/download/Sparkle-$SPARKLE_VERSION.tar.xz"
        echo "==> Sparkle $SPARKLE_VERSION laden ($SPARKLE_ARCHIVE_URL)" >&2
        if ! curl -fsSL --retry 3 -o "$archive" "$SPARKLE_ARCHIVE_URL"; then
            echo "error: Download von $SPARKLE_ARCHIVE_URL fehlgeschlagen." >&2
            return 1
        fi
    fi
    if [ ! -f "$archive" ]; then
        echo "error: Sparkle-Archiv fehlt: $archive" >&2
        return 1
    fi
    sum=$(shasum -a 256 "$archive" | cut -d' ' -f1)
    if [ "$sum" != "$SPARKLE_ARCHIVE_SHA256" ]; then
        echo "error: Prüfsumme des Sparkle-Archivs stimmt nicht ($sum, erwartet $SPARKLE_ARCHIVE_SHA256)." >&2
        return 1
    fi
    for tool in "$@"; do
        if ! tar -xJf "$archive" -C "$dir/tools" "./bin/$tool" 2>/dev/null || [ ! -x "$dir/tools/bin/$tool" ]; then
            echo "error: $tool fehlt im Sparkle-Archiv oder lässt sich nicht entpacken." >&2
            return 1
        fi
    done
}

# --- Hilfen für scripts/make-app.sh (getestet in scripts/test-make-appcast.sh) ---

# rpaths eines (auch universellen) Binarys richten: alle rpaths in einen
# Build-Ordner (`*/.build/*`, z. B. SwiftPMs PackageFrameworks) entfernen und
# @executable_path/../Frameworks ergänzen, falls er fehlt. `otool -l` listet
# jeden rpath einmal pro Architektur, `install_name_tool -delete_rpath`
# entfernt ihn aber aus allen auf einmal; deshalb einmalige Liste und nur
# löschen, was noch da ist. Mehrfach aufrufbar.
#   sparkle_fix_rpaths <binary>
sparkle_fix_rpaths() {
    local exe=$1 rp
    _sparkle_rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u; }
    while IFS= read -r rp; do
        case "$rp" in
            */.build/*)
                if _sparkle_rpaths "$exe" | grep -qxF -- "$rp"; then
                    install_name_tool -delete_rpath "$rp" "$exe" || return 1
                fi ;;
        esac
    done < <(_sparkle_rpaths "$exe")
    if ! _sparkle_rpaths "$exe" | grep -qxF '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath @executable_path/../Frameworks "$exe" || return 1
    fi
}

# Sparkle.framework von innen nach außen signieren, wie Sparkle es für
# Developer-ID-Apps ohne Xcode beschreibt (kein --deep): Installer.xpc,
# Downloader.xpc (Entitlements beibehalten), Autoupdate, Updater.app, Framework.
# <befehl> ist z. B. codesign oder eine Funktion mit Zeitlimit; die übrigen
# Argumente gehen vor dem Pfad an ihn. Beim ersten Fehler Rückgabe mit dessen
# Code (z. B. 124 = Zeitüberschreitung), ohne das Skript zu beenden: Aufrufer
# unter `set -e` fangen ihn mit `|| rc=$?` ab.
#   sparkle_sign_framework <framework> <befehl> [argumente…]
sparkle_sign_framework() {
    local fw=$1 item rc=0
    shift
    [ -d "$fw" ] || return 0
    local v="$fw/Versions/B"
    for item in "$v/XPCServices/Installer.xpc" "$v/XPCServices/Downloader.xpc" "$v/Autoupdate" "$v/Updater.app" "$fw"; do
        [ -e "$item" ] || continue
        if [ "$(basename "$item")" = "Downloader.xpc" ]; then
            "$@" --preserve-metadata=entitlements "$item" || rc=$?
        else
            "$@" "$item" || rc=$?
        fi
        if [ "$rc" -ne 0 ]; then return "$rc"; fi
    done
}
