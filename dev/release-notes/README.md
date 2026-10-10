# Release Notes für den Mac App Store

„Neu in dieser Version“ (What's New) je Sprache, als reine Textdateien. Der Workflow **App Store Upload** liest sie, wenn `submit_for_review` angehakt ist, und setzt sie per App Store Connect API in die Version (siehe [../APPSTORE.md](../APPSTORE.md), „Einreichen per Workflow“).

## Dateien

| Datei | Sprache in App Store Connect |
|---|---|
| `<VERSION>.en.txt` | en-US (Englisch, USA) |
| `<VERSION>.de.txt` | de-DE (Deutsch) |

`<VERSION>` ist genau der Inhalt der Datei `VERSION` im Repo, z. B. `0.3.0.en.txt`. Beide Dateien sind Pflicht, sobald `submit_for_review` an ist; die Vorprüfung des Workflows bricht sonst vor dem Bauen ab.

## Regeln

- Reiner Text (UTF-8), kein Markdown; Zeilenumbrüche bleiben erhalten. Aufzählungen mit `•` oder `-` am Zeilenanfang.
- Höchstens **4000 Zeichen** (Apple-Grenze, gezählt in Zeichen, nicht Bytes). Leerraum am Dateiende wird entfernt.
- Nicht leer; keine Platzhalter `<…>` aus der Vorlage (die Prüfung lehnt sie ab).
- Für Nutzer geschrieben: was ist neu, was ist besser, was ist behoben. Keine internen Details, keine Namen anderer Apps, keine Preise.
- Die Datei gehört in denselben Commit wie die Erhöhung von `VERSION` (der Workflow läuft auf dem Tag und liest die Dateien von dort).

## Neue Version

```sh
v=$(cat VERSION)
cp dev/release-notes/TEMPLATE.en.txt dev/release-notes/$v.en.txt
cp dev/release-notes/TEMPLATE.de.txt dev/release-notes/$v.de.txt
# Texte schreiben, dann prüfen:
scripts/asc-submit.sh check-notes
```

Bei der allerersten Version einer App lässt Apple „Neu in dieser Version“ nicht zu; der Workflow überspringt den Text dann mit einer Warnung und reicht trotzdem ein.
