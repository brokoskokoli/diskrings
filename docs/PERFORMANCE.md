# Performance der Scan-Engine

Ziel laut SPEC (1, 4.2): 1–2 Mio. Dateien in unter 60 s, unter 150 MB RAM für den Baum bei 2 Mio. Dateien.

## Messumgebung
- Apple M3 Pro (5 Performance- und 6 Effizienzkerne), 18 GB RAM, interne SSD (APFS)
- macOS 27.0.1 (26A434), Swift 6.4, Release-Build (`swift build -c release`)
- Messung: `/usr/bin/time -l .build/release/diskrings-cli scan <pfad> --top 0`, Phasen mit `DISKRINGS_DEBUG_MEM=1`
- Ohne Festplattenvollzugriff für das Terminal (daher die nicht lesbaren Ordner)
- Dateisystem-Cache warm (`purge` braucht root); jeweils zwei Läufe hintereinander
- Stand: 09.10.2026, Commit nach „Standard-Worker-Anzahl: alle Kerne, höchstens 8“

## Ergebnisse (Standard: 8 Worker)

| Scan | Dateien | Ordner | Knoten | Dauer | Baum im Speicher | Spitze (peak footprint) | max. RSS |
|---|---:|---:|---:|---:|---:|---:|---:|
| `~` | 2 456 848 | 425 343 | 2 882 191 | 9,7 s / 9,9 s | 168,9 MB | 311 MB | 315 MB |
| `/` | 3 501 040 | 717 252 | 4 218 292 | 13,9 s / 14,7 s | 245,4 MB | 448 MB | 452 MB |
| `~/Projects` | 1 301 548 | 213 575 | 1 515 123 | 5,2 s | 87,0 MB | 161 MB | – |
| `/usr/share` | 19 267 | 888 | 20 155 | 0,1 s | 1,1 MB | 6 MB | – |

- „Baum im Speicher“ = Knoten-Array (40 Byte pro Knoten) plus Namenspuffer (`ScanTree.memoryFootprint`). Pro Knoten sind das rund 58 Byte, davon etwa 18 Byte Name.
- Hochgerechnet auf 2 Mio. Dateien (mit ca. 15 % Ordnern also etwa 2,35 Mio. Knoten): rund 138 MB für den Baum. **Ziel erreicht**, aber knapp.
- Geschwindigkeit: etwa 290 000 Einträge pro Sekunde. **Ziel klar erreicht** (2,9 Mio. Einträge in 10 s statt 60 s).
- Die Zeit verbringt der Prozess fast vollständig im Kernel (`sys` 34–58 s gegenüber `user` 1–2 s bei 8 Threads).

### Speicher nach Phasen (`DISKRINGS_DEBUG_MEM=1`)

| Scan | nach dem Lesen | nach dem Zusammenführen | fertiger Baum | Spitze |
|---|---:|---:|---:|---:|
| `~` | 158 MB | 160 MB | 183 MB | 311 MB |
| `/` | 226 MB | 228 MB | 262 MB | 448 MB |

Die Spitze entsteht beim Baum-Aufbau: Dann existieren gleichzeitig der unsortierte Rohbaum (36 Byte pro Knoten plus Namen), 16 Byte Hilfsdaten pro Knoten und das fertige Knoten-Array (40 Byte). Danach wird alles außer dem Baum sofort an das System zurückgegeben (siehe „mmap-Puffer“ in docs/DECISIONS.md). Mit normalen Swift-Arrays lag die Spitze beim Scan von `~` bei 567 MB, und nach dem Scan von `~/Projects` blieb der Prozess bei 314 MB statt 93 MB.

### Abgleich mit `du`

| Scan | DiskRings | `du -sk` | Abweichung |
|---|---:|---:|---:|
| `~` | 288 576 540 KiB | 288 578 416 KiB | 0,0007 % |
| `/usr/share` | 256 396 KiB | 256 396 KiB | 0 |

`du -sk ~` brauchte dafür 65 s, DiskRings 13 s (5 Worker) bzw. 10 s (8 Worker). Die kleine Abweichung bei `~` entsteht, weil sich das Home-Verzeichnis zwischen den beiden Läufen ändert.

### Volume-Bilanz beim Scan von `/`
- Scan-Summe 373,7 GB + „Nicht zugeordnet“ 64,4 GB = 438,1 GB = belegt laut Volume. `/System/Volumes/Data` wurde nicht betreten, `/Users`, `/Applications` usw. erscheinen über die Firmlinks unter `/`.
- Nicht betretene Einhängepunkte: `/System/Volumes/{Data,Hardware,Preboot,Update,VM,iSCPreboot,xarts}`, `/Volumes/Recovery`, `/dev`, `/nix`.

## Worker-Anzahl (`~`, warmer Cache)

| Worker | Dauer |
|---:|---:|
| 1 | 62 s |
| 2 | 31,2 s |
| 5 (Performance-Kerne) | 12,8 s / 13,3 s / 13,6 s |
| 8 | 9,8 s / 10,3 s / 10,3 s |
| 11 (alle Kerne) | 11,5 s |

Beim Scan von `/`: 5 Worker 18,5 s, 8 Worker 14,1 s. Deshalb ist der Standard „alle Kerne, höchstens 8“ (Abweichung von der Spec, siehe DECISIONS.md).

## Speicherspitze: Baumaufbau an Ort und Stelle (Befund K8)

Messung wie oben (`/usr/bin/time -l … scan ~ --top 0`, 8 Worker, warmer Cache, 09.10.2026), je zwei Läufe:

| Stand | Knoten | nach dem Lesen | zusammengeführt | fertiger Baum | Spitze (peak footprint) | max. RSS |
|---|---:|---:|---:|---:|---:|---:|
| vorher (Rohbaum + zweites Knoten-Array) | 2 887 413 | 160 MB | 159 MB | 183 MB | 310,5 MB / 310,7 MB | 315 MB |
| nachher (Permutation an Ort und Stelle) | 2 887 711 | 161 MB | 185 MB | 185 MB | 239,7 MB / 238,7 MB | 244 MB |

- Der Assembler schreibt direkt in das endgültige Knoten-Array (40 Byte pro Knoten), statt erst einen Rohbaum in Spaltenform (36 Byte) anzulegen. Der Builder braucht daneben nur noch 16 Byte Hilfsdaten pro Knoten und ordnet die Knoten per Zyklen-Permutation um.
- Spitze jetzt etwa 83 Byte pro Knoten (vorher 108). Der Rest der Spitze: Knoten-Array 40 + Namen (mmap) 18 + Hilfsdaten 16 + am Ende die Namenskopie in Baum-Reihenfolge 18 Byte.
- Die Scandauer ist unverändert (10,4 s / 10,6 s; die Schwankung zwischen Läufen liegt bei ±1 s).

## Live-Snapshots bis Tiefe 6 (Befund K7)

Gemessen mit `DISKRINGS_DEBUG_SNAPSHOT=1 diskrings-cli scan ~ --top 0 --live --live-depth K` (Snapshot alle 250 ms):

| Tiefe | Knoten im Snapshot | Kopie unter dem Lock | Aufbau | Scandauer |
|---:|---:|---:|---:|---:|
| ohne Snapshots | – | – | – | 9,4–11,2 s |
| 3 | 5 312 | 0,04–0,07 ms | 0,5–0,7 ms | 10,3–10,6 s |
| 6 | 103 851 | 0,3–1,9 ms | 6–11 ms | 10,6–11,0 s |

- Bei Tiefe 6 kostet ein Snapshot etwa 10 ms auf dem Koordinator-Thread (rund 4 % eines Kerns bei 4 Snapshots pro Sekunde). Die Worker warten nur während der Kopie unter dem Lock (unter 2 ms). Ein messbarer Einfluss auf die Scandauer ist nicht erkennbar (innerhalb der Schwankung).
- Ein Snapshot dieser Größe belegt rund 6 MB. Standard ist deshalb jetzt `snapshotDepth = 6`, passend zu den 6 Standardringen.

## Teil-Rescan, Snapshots und Vergleich (M6-Kern)

| Messung | Debug-Build | Release-Build |
|---|---:|---:|
| Teil-Rescan einhängen (300 Dateien in einen Baum mit 2 010 101 Knoten, ohne den Scan) | 3,8 ms | 3,3 ms |
| Vergleich 2 010 101 gegen 2 010 101 synthetische Knoten (`SnapshotDiff`) | 5,4 s | 0,34 s |
| „Größte Veränderungen“ und Wachstumsbaum dazu (1 Mio. Knoten im Wachstumsbaum) | 5,1 s | 0,24 s |

- Ziele: Einhängen unter 100 ms (SPEC 3.8 / Befund S7), Vergleich unter 2 s (SPEC 3.9). Beide erreicht; die Performance-Tests laufen in `scripts/check.sh` zusätzlich im Release-Build mit der strengen Grenze.
- Das Einhängen kostet fast nur die Kopie von Knoten-Array und Namenspuffer in die neue Baum-Version (copy-on-write, siehe DECISIONS.md).

**Snapshot von `~`** (`diskrings-cli snapshot save ~`, 2 888 607 Knoten, 297,8 GB):

| Mindestgröße | gespeicherte Knoten | Dateigröße | Speichern |
|---:|---:|---:|---:|
| 1 MB (Standard) | 440 962 | 5,8 MB | 0,2 s |
| 0 (alles) | 2 888 607 | 35,9 MB | 1,2 s |

- SPEC 3.9 erwartet 5–15 MB für 2 Mio. Dateien: erreicht. Spitze des Prozesses beim Speichern: 259 MB (Scan-Spitze plus gefilterter Baum und Kompressionspuffer).
- `diskrings-cli diff <snapshot>` gegen einen frischen Scan von `~`: 0,1 s für den Vergleich (440 963 Einträge, kleine Dateien zählen nur über die Ordnersumme).

## Offene Punkte
- Kalter Cache (nach Neustart) ist nicht gemessen; die Zahlen oben sind Bestwerte.
