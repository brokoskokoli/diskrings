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

## Offene Punkte
- Kalter Cache (nach Neustart) ist nicht gemessen; die Zahlen oben sind Bestwerte.
- Die Spitze beim Baum-Aufbau (etwa 106 Byte pro Knoten) ließe sich durch eine Permutation an Ort und Stelle statt eines zweiten Knoten-Arrays noch um etwa ein Drittel senken.

## Sunburst-Layout und Hit-Test (M3)

Test `Sunburst-Performance` (`ZoomAndNavigationTests.swift`), synthetischer Baum mit 2 000 000 Knoten (`DemoTree.large`), 10 Ringe, bester von mehreren Läufen. Debug-Build (`swift test`), also eher pessimistisch:

| Messung | Ergebnis | Ziel |
|---|---:|---:|
| Layout, Schwelle 0,5°, Modus belegt | 1,3 ms (616 Arcs) | < 50 ms |
| Layout, Modus logisch | 2,7 ms | < 50 ms |
| Layout ohne Schwelle (ungünstigster Fall, bis zur Obergrenze) | 16 ms (10 563 Arcs) | < 50 ms |
| Hit-Test | 0,9 µs pro Punkt | < 1 ms |
| Farben für alle Arcs | 0,2 ms | – |

Die Laufzeit hängt im Wesentlichen von der Zahl der Arcs ab, nicht von der Baumgröße. Das Zeichnen im `Canvas` ist nicht automatisiert gemessen.
