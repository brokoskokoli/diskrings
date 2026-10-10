# Architektur von DiskRings

Einstieg für Menschen und KI-Agenten: Wo liegt was, wie fließen die Daten, und welche Regeln dürfen nicht brechen. Anforderungen stehen in `SPEC.md`, Begründungen und Abweichungen in `dev/DECISIONS.md`, Messwerte in `dev/PERFORMANCE.md`. Wer Dateien hinzufügt, verschiebt oder eine Invariante ändert, hält dieses Dokument aktuell.

## Überblick

Swift Package ohne Xcode-Projekt, macOS 14, Swift 6 (Strict Concurrency):

| Target | Rolle | Tests |
|---|---|---|
| `DiskRingsCore` (Bibliothek) | gesamte Logik ohne UI, kein SwiftUI | `Tests/DiskRingsCoreTests` |
| `DiskRings` (App) | dünne SwiftUI/AppKit-Oberfläche | **kein Testziel** |
| `diskrings-cli` | Kommandozeile für Tests, Messungen, Debugging | keine eigenen |

`scripts/check.sh` baut, führt alle Tests aus und danach die Performance-Tests im Release-Build. Die Oberfläche wird visuell über `swift run DiskRings --render-snapshots <ordner>` geprüft (PNGs hell und dunkel, Optionen `--scan <pfad>`, `--compare-demo`, `--language <code>`). App-Store-Screenshots (2880 × 1800, nur Demo-Daten): `--store-screenshots <ordner> [--language <code>] [--appearance light|dark]`, siehe `dev/APPSTORE.md`.

Zwei Build-Varianten aus demselben Binary: `scripts/make-app.sh` (Developer ID, `build/DiskRings.app`) und `scripts/make-app.sh --appstore` (App Sandbox mit `Resources/DiskRings-AppStore.entitlements`, `build/appstore/DiskRings.app` und `build/DiskRings-<version>.pkg`). Die App erkennt die Sandbox zur Laufzeit (`AppEnvironment`), siehe SPEC 11 und `dev/APPSTORE.md`. Workflows: `ci.yml` (Build und Tests, Store-Variante ad hoc), `release.yml` (Tag `v*`: Developer ID, Notarisierung, GitHub Release; Logik in `scripts/ci-release.sh`, `scripts/release.sh`) und `appstore.yml` (von Hand auf einem Tag: Store-Variante signieren, validieren, zu App Store Connect hochladen, optional per API zur Prüfung einreichen; Logik in `scripts/ci-appstore.sh`, Einreichung in `scripts/asc-submit.sh` mit Token aus `scripts/asc-jwt.swift`, Tests mit Mock-Server in `scripts/test-asc-submit.sh`, Texte „Neu in dieser Version“ in `dev/release-notes/`).

## Modulkarte

### Core: Scan
- `ScanEngine.swift`: parallele Scan-Engine (Worker-Threads, gemeinsame Queue, lokale Puffer, Live-Skelett, deterministische Hardlink-Bereinigung, Baumaufbau); `scanBlocking`, `scan` (async), `events` (begrenzter Ereignis-Stream); Test-Hooks `ScanHooks`.
- `DirectoryReader.swift`: liest Verzeichnisse blockweise mit `getattrlistbulk`, öffnet ohne Symlinks zu folgen (`openat`, `O_NOFOLLOW`).
- `ScanTypes.swift`: `ScanOptions`, `ScanProgress`, `ScanEvent`, `ScanResult`, `ScanError`, `ScanCancellation`, `SystemInfo`.
- `ScanProgress+Make.swift`: öffentlicher Konstruktor für `ScanProgress` (Vorschaubilder).
- `ScanResult+Make.swift`: öffentlicher Konstruktor für `ScanResult` aus einem Baum ohne Scan (Vorschaubilder, Store-Screenshots).
- `ScanController.swift`: MainActor-Steuerung genau eines Scans für die App; Generationsnummer verwirft Ereignisse alter Scans; `drain()` für Tests.
- `ScanStall.swift`: `ScanStallDetector`, erkennt Stillstand (z. B. wartender TCC-Dialog) über Einträge und Herzschlag.
- `ScanSummary.swift`: Kennzahlen eines Scans ohne Baum; `updated(for:)` nach Änderungen.
- `PackageDetector.swift`: erkennt Pakete an der Endung (feste Liste).
- `VolumeInfo.swift`: Kennzahlen eingehängter Volumes, „Nicht zugeordnet“ (belegt − Scan-Summe).
- `ContainerVolumes.swift`: `ContainerVolume` (Name, Gerät, Rollen, belegt, Anzeigename), `ContainerVolumes` (eingehängte APFS-Volumes per `getmntinfo`/`getattrlist`, Container aus dem Gerätenamen, `others(…)` ohne die vom Scan abgedeckten Volumes), `APFSVolumeListing` und `DiskutilAPFSListing` (nicht eingehängte Volumes über `diskutil apfs list -plist`, Zeitlimit, nicht in der Sandbox).
- `VolumeBreakdown.swift`: `VolumeBreakdown` (rein: Ihre Daten, Systemdaten mit Teilen, löschbar, frei; Summe = altes „Nicht zugeordnet“), `RootSegments` (Segmente der Volume-Wurzel für das Layout).
- `FullDiskAccess.swift`: Erkennung des Festplattenvollzugriffs, Hinweis vor dem Scan; `status(in:)` liefert in der Sandbox immer `unknown`.

### Core: App-Store-Variante (Sandbox, SPEC 11)
- `AppEnvironment.swift`: `isSandboxed` (über `APP_SANDBOX_CONTAINER_ID`, übergebbar), `homeDirectory` (in der Sandbox der echte Home-Ordner statt des Containers).
- `FolderAccess.swift`: `FolderAccessStore` (Ordnerfreigaben: laden mit Erneuern/Verwerfen, `grant`, `covers`/`grantedAncestor`, `revoke` (beendet alle Leases der Freigabe), gezählte Leases `beginAccess`/`endAccess`/`isActive`, Abgleich auch über aufgelöste Pfade `resolvedPath`), Protokolle `SecurityScopedBookmarks` (echt: `SystemBookmarks`) und `GrantPersistence` (`UserDefaultsGrantPersistence`, `InMemoryGrantPersistence` für Vorschaubilder).
- `MappedBuffer.swift`: wachsender `mmap`-Puffer für Zwischenstände (gibt Speicher sofort zurück).
- `MemDebug.swift`: Speicher- und Snapshot-Messausgaben über `DISKRINGS_DEBUG_MEM` / `DISKRINGS_DEBUG_SNAPSHOT`.

### Core: Baummodell und Änderungen
- `Node.swift`: `Node` (40 Byte) und `NodeFlags`; `SizeMode` (belegt/logisch).
- `ScanTree.swift`: unveränderlicher Baum (Knoten-Array, Namenspuffer, Hardlink-Tabelle), Pfadsuche, `validate()`; `NodeRef` als leichter Lesezugriff.
- `TreeBuilder.swift`: `RawTree` (Rohbaum in Spaltenform), `HardlinkEntry`, `TreeBuilder` (Größen propagieren, sortieren, Permutation an Ort und Stelle in Breitensuche-Reihenfolge).
- `ScanTreeBuilder.swift`: baut Bäume im Speicher ohne Dateisystem (Tests, Vorschaubilder, synthetische Messungen).
- `TreeMutation.swift`: `TreeEdit` und `replacingSubtree`, `removingNode`, `compacted` (neue Baum-Version, `translate` für alte Indizes); intern `TreeMutator`.
- `TreeEditChain.swift`: mehrere Änderungen hintereinander (`removingNodes(atPaths:)`), durchgereichte Index-Übersetzung.
- `Rescan.swift`: `RescanResult`, `ScanEngine.rescanBlocking`/`rescan` (Engine-seitiger Teil-Rescan), `nearestExistingIndex`.
- `PartialRescan.swift`: `RescanQueue` (Regeln für parallele Teil-Rescans), `RescanMerge`, `PartialRescan` (Scan, Einhängen in den aktuellen Baum, Hinweistext, Fortschrittsschätzung).
- `TreeSearch.swift`: Namenssuche im Teilbaum (ohne Groß-/Kleinschreibung und Akzente).
- `DemoTree.swift`: deterministische Beispielbäume (Vorschauen, Performance-Tests); `home(scale:afterChanges:)` skaliert die Größen und liefert einen späteren Stand für den Vergleich.

### Core: Sunburst
- `SunburstLayout.swift`: `SunburstOptions`, `SunburstArc`, Layout ab Fokus (Arcs ringweise, je Ring nach Winkel sortiert, Sammel- und Restsegmente, Segmente der Volume-Wurzel: Systemdaten mit Teilen im zweiten Ring, löschbar, frei; Titel und Erklärungen).
- `SunburstGeometry.swift`: Ringradien, `SunburstHit`, `SunburstHitTester` (Polarkoordinaten + binäre Suche).
- `SunburstLabels.swift`: Platzierung der Beschriftungen.
- `Palette.swift`: `RGBColor`, Farbschemata „Ast“ und „Dateityp“, Hell/Dunkel, Kontrast der Beschriftung.
- `Palette+Volume.swift`: Farben der Volume-Segmente (Systemdaten, löschbar, frei), auch für die Belegungsbalken.
- `Palette+Delta.swift`: `DeltaScale` und Farben des Vergleichsmodus.
- `ZoomTransition.swift`: Zoom-Animation zwischen zwei Layouts (`ZoomTransform`, `DisplayArc`).
- `EditTransition.swift`: Animation nach Papierkorb, Teil-Rescan, Undo (Zuordnung über `translate`).
- `FocusHistory.swift`: Fokus, Zurück/Vor, Breadcrumb; Übertragung auf neue Bäume.
- `NodeSelection.swift`: Mehrfachauswahl mit Anker, oberste Knoten einer Auswahl.

### Core: Aktionen, Papierkorb, Schutz
- `NodeAction.swift`: Einträge des Kontextmenüs, `ActionShortcut`, `ActionContext`, `availability` (eine Prüfung für Menü, Hauptmenü und Kürzel).
- `NodeTargets.swift`: `NodeTargetSnapshot`/`CompareTargetSnapshot`: Ziele über Pfad und Art festhalten und vor dem Ausführen neu auflösen.
- `TrashService.swift`: `FileTrashing` (Protokoll, `FileManager` erfüllt es), `FileIdentity`, `TrashPlan`/`TrashPlanError`, `TrashConfirmation`, `TrashService` (`trash`, `restore`; in der Sandbox eigene Meldungen für Rechtefehler und `accessCheck` für ⌘Z), Ergebnis-Typen.
- `ProtectedPaths.swift`: Schutzliste, Normalisierung, Volume-Wurzeln, laufende App.
- `WindowLifecycle.swift`: Entscheidungen beim Schließen von Fenstern und beim Dock-Klick; Syntax von `--selftest-close`.

### Core: Snapshots und Vergleich
- `Snapshot.swift`: `SnapshotMetadata`, `SnapshotScanOptions`, `VolumeMetrics`, `Snapshot`, `SnapshotError`, `SnapshotFile` (Format `.drsnap`: JSON-Kopf + LZFSE-Nutzdaten, Prüfungen beim Laden).
- `SnapshotStore.swift`: Ablage unter `~/Library/Application Support/DiskRings/Snapshots/<volume-uuid>/`, `save` (atomar), `list`/`listAll`, `load`, `delete`, `rename`, `prune`; `SnapshotInfo`, `DamagedSnapshot`.
- `SnapshotRetention.swift`: `SnapshotRetention`, `SnapshotMatching` („Vergleichen mit…“), `SnapshotNaming`, `saveAndPrune`/`autoSave`.
- `SnapshotDiff.swift`: Vergleich zweier Snapshots (Vereinigungsbaum `entries`, Status, „Größte Veränderungen“, Wachstumsbaum, Warnungen).
- `CompareModel.swift`: Anzeigebäume des Vergleichsmodus, Sortierung, Hit-Test → Vergleichseintrag; `CompareHeadline`.
- `CompareActions.swift`: Aktionen im Vergleich (Abbildung auf den aktuellen Baum über Pfade), `CompareEntryMapping` (Zustand auf neu berechneten Vergleich übertragen).
- `CompareDemo.swift`: Beispielbaum für den Vergleich in einem übergebenen temporären Ordner.
- `GenerationGate.swift`: Generationszähler für Hintergrundergebnisse.
- `OutlineNavigation.swift`: Tastaturregeln für die Listen (↑/↓, →/←, Home/End, Bild auf/ab) auf dem Modell der sichtbaren Zeilen.
- `TextFormat.swift`: lokalisierte Trennzeichen und Formate (Doppelpunkt, „ · “, Grad).

### Core: Formatierung und Lokalisierung
- `ByteFormat.swift`: Größen, Anzahlen, Prozent, Dauern nach Locale.
- `Localization/L10n.swift`: `L()`, Sprachauflösung, Bundle-Wahl, Locale.
- `Localization/LanguageSetting.swift`: Sprachwahl über `AppleLanguages` der App.
- `Resources/<sprache>.lproj/`: `Localizable.strings`, `Localizable.stringsdict`, `InfoPlist.strings` für 14 Sprachen.

### App (`Sources/DiskRings`)
- `App/DiskRingsApp.swift`: Einstieg (`Entry`: `--render-snapshots`, `--compare-demo`, `--store-screenshots`, `--appearance`, `--language`; sonst normaler Start, `--scan <pfad>` scannt sofort), Szenen, `RootView`, Menübefehle `AppCommands`.
- `App/AppState.swift`: zentraler `@Observable`-Zustand auf dem MainActor: Scan, Baum, Layout, Fokus, Auswahl, Papierkorb/Undo, Teil-Rescans, Suche, Toasts; in der Sandbox Ordnerfreigaben (`ensureAccess`, `askForAccess`, `grantAccess`, `revokeAccess`, Lease auf die Scan-Wurzel bzw. die Wurzeln eines Snapshot-Vergleichs).
- `App/AppDelegate.swift`: Beenden mit dem letzten Fenster, Dock-Klick, Abbruch beim Schließen, Selbsttest `--selftest-close`.
- `App/FileActions.swift`: AppKit-Seite der Aktionen (Finder, Öffnen, Pfad kopieren), `QuickLookController`, `KeyboardMonitor` (Leertaste).
- `App/Preferences.swift`: Einstellungen in den UserDefaults.
- `App/SwipeNavigation.swift`: Wischgesten für Zurück/Vor.
- `Browser/BrowserView.swift`: Hauptansicht, Toolbar, Breadcrumb, Statusleiste.
- `Browser/DetailListView.swift`: Detailliste (Outline) neben dem Diagramm.
- `Browser/OutlineKeyboard.swift`: Fokus und Tastenbehandlung der Listen (nutzt `OutlineNavigation`).
- `Browser/NodeContextMenu.swift`: `ContextMenuTarget`, `ContextMenuRegistry` (erweiterbare Abschnitte), Menü-Views, `VolumeSegmentMenu` (nur Informationen für Systemdaten, löschbar, frei).
- `Browser/ActionViews.swift`: Papierkorb-Dialog, Info-Fenster, Toast, Suchfeld und Trefferliste.
- `Sunburst/SunburstView.swift`: Diagramm-View (Canvas, Hover, Klick, Tooltip, VoiceOver-Elemente).
- `Sunburst/SunburstRenderer.swift`: Zeichnen der Arcs in einen `GraphicsContext`.
- `Compare/CompareView.swift`: Vergleichsmodus (Leiste, Kopfzeile, Breadcrumb), `CompareModeSwitch`.
- `Compare/CompareSession.swift`: Zustand des Vergleichs, Start/Ende, Neuberechnung mit `compareRunGate`.
- `Compare/CompareSunburstView.swift`, `CompareListView.swift`: Diagramm und Liste/„Größte Veränderungen“ im Vergleich.
- `Compare/CompareContextMenu.swift`: Kontextmenü-Abschnitte im Vergleich, Neuberechnung nach Änderungen.
- `Compare/CompareToolbarButton.swift`: „Vergleichen mit…“-Popup.
- `Compare/CompareDemoRenderer.swift`: Vorschaubilder des Vergleichs (`--compare-demo`).
- `Snapshots/SnapshotLibrary.swift`: Snapshot-Einstellungen, Liste, Speichern/Umbenennen/Löschen im Hintergrund.
- `Snapshots/SnapshotsWindow.swift`: Fenster „Snapshots“, Namensdialog, Menübefehle.
- `Snapshots/SnapshotRenderer.swift`: `--render-snapshots` (Szenen als PNG).
- `Snapshots/StoreScreenshotRenderer.swift`: `--store-screenshots` (sechs App-Store-Szenen, 1440 × 900 pt bei Skalierung 2).
- `Start/StartView.swift`: Startbildschirm (Volumes, Ordnerwahl, Hinweis auf Festplattenvollzugriff bzw. in der Sandbox `SandboxAccessBanner`) und Scan-Ansicht mit Stillstands-Hinweis.
- `Settings/SettingsView.swift`, `Settings/LanguageSection.swift`: Einstellungen, Sprachwahl, Neustart; `FolderAccessSection` (nur Sandbox).
- `Support/Support.swift`: Farbumrechnung, Texte zu Arcs, Volumes, `VolumeUsageBar`/`VolumeUsageLegend` (gestapelter Belegungsbalken auf Startbildschirm und Statusleiste), `ViewState` (Ersatz für `@State`, siehe DECISIONS).

### CLI (`Sources/diskrings-cli/main.swift`)
- Eine Datei: `scan` (Summen, Aufteilung der Volume-Belegung bei Volume-Wurzeln, größte Ordner, `--json`, `--live`), `volumes`, `snapshot save|list`, `diff` (Snapshot gegen Snapshot oder frischen Scan). Ausgaben englisch, nicht lokalisiert; Ctrl-C bricht den Scan ab (Exit 130).

## Datenfluss

### Vollständiger Scan
1. `AppState.startScan` ruft `ScanController.start`; dieser liest `ScanEngine.events(...)` (Fortschritt, Live-Snapshots als vorläufige `ScanTree`s nur mit Ordnern, am Ende `.finished(ScanResult)`).
2. Der Controller reicht nur Ereignisse der aktuellen Generation an `AppState` weiter (`handler` auf dem MainActor). Ein neuer `start` oder `cancel` erhöht die Generation; gepufferte Ereignisse alter Scans verfallen.
3. `AppState.finish` übernimmt den Baum (`setTree`), liest die eingehängten anderen Volumes des Containers, berechnet `breakdown` (`VolumeBreakdown`), ergänzt im Hintergrund nicht eingehängte Volumes (`loadOtherVolumes`, Generationsprüfung über `containerGate`), hält nur eine `ScanSummary` (nicht das `ScanResult`) und speichert automatisch einen Snapshot (`SnapshotLibrary.didFinishScan`).
4. Views lesen `AppState`; das Layout (`SunburstLayout`) wird nur bei Fokuswechsel, neuem Baum oder Änderung neu berechnet.

### Änderungen am Baum
- Jede Änderung erzeugt eine **neue** `ScanTree`-Version (`TreeEdit`); der alte Baum bleibt gültig. `AppState.applyEdit(new, translate:)` führt Fokus, Historie, Auswahl, aufgeklappte Ordner und Suchtreffer per `translate` nach, startet die `EditTransition`, aktualisiert Summary und die Aufteilung der Belegung und plant die Neuberechnung eines laufenden Vergleichs.
- Neue Bäume ohne Änderungsbezug (Live-Snapshot → Endergebnis) überträgt `setTree` über Pfade.

### Teil-Rescan
1. `AppState.startPartialRescan(path:)` fragt `RescanQueue.request`: `.blockedByFullScan` (während eines vollständigen Scans), `.alreadyCovered` (derselbe Ordner oder ein Vorfahr läuft; der laufende Job wird als veraltet markiert), oder `.start(id, cancelling:)` (Vorfahr ersetzt laufende Jobs darunter, deren Tokens werden abgebrochen).
2. Ein eigener Thread liest mit `PartialRescan.scan` (Optionen des ursprünglichen Scans, Symlinks nur bei der Scan-Wurzel folgen).
3. Beim Eintreffen entscheidet `RescanQueue.finish(id)`: `.apply` → `PartialRescan.merge` in den **dann aktuellen** Baum, `applyEdit`; `.discard` → verwerfen (abgebrochen/ersetzt); `.rerun` → verwerfen und denselben Job (gleiche ID, Fortschritt bleibt) gegen den aktuellen Stand neu starten. Veraltet wird ein Job durch eine abgedeckte Anfrage oder durch `noteEdit(at:)` (Papierkorb, Zurücklegen darunter); mehrere Änderungen ergeben genau einen Neulauf.
4. Ein vollständiger Scan bricht alle Teil-Rescans ab (`cancelAll`).

### Papierkorb und Undo
1. Kontextmenü: `ContextMenuTarget` hält die Ziele zusätzlich als `NodeTargetSnapshot` (Pfad und Art, Scan-Wurzel). Vor dem Ausführen werden sie im aktuellen Baum neu aufgelöst (`resolve(in:)`); fehlt eines, hat es eine andere Art oder eine andere Wurzel, passiert nichts. Hauptmenü und Kürzel prüfen `NodeAction.availability` erneut in `AppState.perform`.
2. `AppState.requestTrash` frischt die Volume-Wurzeln auf und baut `TrashPlan.make` (siehe Invarianten), dann `checkingCurrentKinds`. `TrashConfirmation` entscheidet über den Dialog.
3. `TrashService.trash` prüft pro Element erneut: Schutzliste, Existenz, Einhängepunkt (`statfs`), aufgelöste Elternkette gegen Schutzliste und Scan-Wurzel; erst dann `trashItem`. Ergebnis: `TrashRecord` mit `FileIdentity` und aufgelöstem Elternordner.
4. `AppState` meldet `noteEdit` für jeden Pfad, entfernt die Knoten (`removingNodes(atPaths:)` → `applyEdit`) und liest einen Papierkorb im Baum still neu ein.
5. ⌘Z: `TrashService.restore` legt nur dasselbe Objekt (Identität) an einen unveränderten, nicht geschützten Ort zurück, überschreibt nie; danach Teil-Rescan des Elternordners.

### Ordnerfreigaben (nur Sandbox)
1. `AppState.init` lädt die Freigaben (`FolderAccessStore.load`). `requestScan`/`startScan` rufen `ensureAccess`: gedeckter Pfad → weiter; sonst Öffnen-Dialog auf dem Pfad (`askForAccess`), die gewählte URL wird über `grantAccess` (`SystemBookmarks.adopt` + `grant`) gespeichert. Drag & Drop und „Ordner auswählen …“ gehen ebenfalls über `grantAccess`.
2. `startScan` holt einen Lease auf die Freigabe der neuen Wurzel, bevor der alte endet (`rootLease`); freigegeben wird er bei Abbruch, Fehler und `backToStart`. Alle Dateizugriffe auf den Baum (Teil-Rescan, Papierkorb, ⌘Z, Finder, Quick Look) laufen unter diesem Lease.

### Snapshots und Vergleich
- Speichern: `SnapshotMetadata.current(for: ScanSummary, tree:)` + `SnapshotStore.save` (Mindestgröße, atomar über temporäre Datei), danach `prune`.
- Vergleich: `CompareSession` holt ein Token aus `compareRunGate`, berechnet `SnapshotDiff` und `CompareModel` in `Task.detached` und übernimmt das Ergebnis nur, wenn das Token noch aktuell ist. „Snapshot ↔ aktueller Scan“ nutzt `AppState.tree` und wird nach jeder Änderung neu berechnet (250-ms-Bündelung, Zustand über `CompareEntryMapping`).
- Aktionen im Vergleich bilden Einträge über den Pfad auf den aktuellen Baum ab (`CompareActions`, `CompareTargetSnapshot`).

## Invarianten – nicht brechen

1. **Core importiert kein SwiftUI** (auch kein AppKit). Core enthält nur Logik und Texte.
2. **Die App hat kein Testziel.** Logik in `Sources/DiskRings` ist per Definition ungetestet. Alles, was sich testen lässt (Regeln, Berechnungen, Entscheidungen), gehört nach Core; die App ruft es nur auf.
3. **`Node` ist genau 40 Byte** (`MemoryLayout<Node>.size == 40` und `.stride == 40`, Test in `ScanTreeTests`). Felder nicht umordnen oder ergänzen, ohne Speicherbudget (SPEC 4.2), Snapshot-Format (40 Byte je Knoten in `.drsnap`) und `dev/PERFORMANCE.md` zu prüfen.
4. **Reihenfolge im Knoten-Array:** `nodes[0]` ist die Wurzel; die Kinder eines Knotens liegen zusammenhängend ab `firstChild` und sind sortiert (belegt absteigend, dann logisch absteigend, dann Name nach UTF-8-Bytes aufsteigend); Eltern stehen immer vor ihren Kindern. Globale **Breitensuche-Reihenfolge gilt nur für frisch gebaute oder kompaktierte Bäume.** Nach `replacingSubtree`/`removingNode` gibt es **tote Knoten** (`.dead`, unerreichbar, `count` zählt sie, `liveCount` nicht) und hinten **angehängte** neue Knoten; Indizes können sich verschieben. Wer `nodes` linear durchläuft, überspringt `.dead`; alte Indizes immer über `TreeEdit.translate` bzw. `TreeEditChain.translate` übersetzen. Snapshots speichern nur kompaktierte Bäume.
5. **Hardlinks:** Pro `(Gerät, Inode)` zählt genau das lebende Vorkommen mit dem bytewise **kleinsten Pfad** mit echter Größe; alle anderen zählen mit 0 Byte und tragen `.hardlinkDuplicate`. Die Hardlink-Tabelle im `ScanTree` ist **streng aufsteigend nach Knotenindex sortiert** und enthält nur lebende Dateien. Teil-Rescans entfernen Einträge toter Knoten (auch den alten Eintrag des ersetzten Knotens selbst) und bereinigen betroffene Gruppen neu.
6. **`ScanTree.validate()` muss für jeden in Tests erzeugten Baum leer sein** (Erreichbarkeit, Sortierung, Summen, `deadCount`, Hardlink-Tabelle). Neue Baum-Operationen bekommen Tests, die `validate()` aufrufen.
7. **Asynchrone Ergebnisse nur mit Generationsprüfung übernehmen:** `GenerationGate` (`begin()` vor der Arbeit, `isCurrent(token)` vor dem Übernehmen, `invalidate()` bei Scanstart, Rückkehr zum Start, Vergleichsende), bzw. die Generation im `ScanController` und die Zähler für Suche und Vergleichs-Neuberechnung in `AppState`. Teil-Rescans laufen über `RescanQueue.finish`.
8. **Pfade vor jedem Schutzvergleich normalisieren** (`ProtectedPaths.normalize`): `.`/`..`, Mehrfach- und Endschrägstriche, `/System/Volumes/Data/…` → `/…` und `/System/Volumes/Data` → `/`, `/var|/etc|/tmp` → `/private/…`, ohne Groß-/Kleinschreibung, NFC/NFD-unabhängig. Geschützt sind auch Ordner, die einen geschützten Bereich enthalten.
9. **Papierkorb-Regeln** (`TrashPlan.make`, zusätzlich in `TrashService`): nie die Scan-Wurzel, nie tote Knoten, nie geschützte Pfade, nie Einhängepunkte oder Ordner, die einen enthalten; eine Verletzung sperrt die **ganze** Aktion. Größe gilt als **unsicher** (Dialog immer, kein „Nicht mehr fragen“), wenn im Teilbaum Einhängepunkte, Dataless- oder nicht lesbare Knoten liegen, der Baum unvollständig ist, ein Teil-Rescan darin oder darüber läuft oder die Art auf der Platte nicht mehr passt. „Nicht mehr fragen“ nur unter 1 GB (Maximum aus belegt und logisch). Tests für Papierkorb und Löschen laufen nur in temporären Verzeichnissen.
10. **Lokalisierung:** Alle sichtbaren Texte über `L("stabile.id", args…)`, Views bekommen fertige Strings (`Text(L(…))`). Jeder neue Schlüssel steht in **allen 14 Sprachen** (`Resources/*.lproj/Localizable.strings`, Pluralformen in `.stringsdict`) mit passenden Platzhaltern; keine deutschen Literale im Code (Diagnosen wie `precondition` ausgenommen). `LocalizationTests` prüft Vollständigkeit, verwaiste Schlüssel, Platzhalter und Pluralkategorien.
11. **Testprotokoll:** Tests verwenden nie die echte Snapshot-Ablage (`~/Library/Application Support/DiskRings`) und nie echte Nutzerdaten; Fixtures entstehen in temporären Ordnern (`Fixture`).
12. **Sandbox:** Kein Dateizugriff außerhalb von `ensureAccess`/Lease einbauen; neue Hinweise auf den Festplattenvollzugriff hinter `!state.isSandboxed` bzw. `FullDiskAccess.status(in:)`. Pfade des Home-Ordners immer über `AppEnvironment.homeDirectory`, nie `NSHomeDirectory()` (in der Sandbox der Container).
