# Developing Stow

Building, testing and reviewing Stow from source. How the app works inside is in
[ARCHITECTURE.md](ARCHITECTURE.md); what is left to build is in [ROADMAP.md](ROADMAP.md).

## Requirements

- macOS 26 or later (uses Liquid Glass APIs directly — no fallbacks)
- Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & run

```bash
scripts/fetch-7zip.sh   # pinned 7-Zip 26.04, checksum-verified, into Vendor/ (gitignored)
xcodegen generate
xcodebuild -project Stow.xcodeproj -scheme Stow -derivedDataPath build build
open build/Build/Products/Debug/Stow.app
```

Tests (Swift Testing): `xcodebuild -project Stow.xcodeproj -scheme Stow -derivedDataPath build test`

Encrypted/split/verified packing stress (#38): after the setup above, run
`scripts/stress-encrypted-split.sh [rounds]` (default 20, maximum 100). Each round creates through
the sandboxed engine, verifies, reopens and extracts the numbered 7Z parts, checks wrong-password
refusal and payload/source integrity, and rejects failed, skipped or missing tests. Logs and
result bundles are retained in the printed `build/packing-stress.*` directory.

After each build, `scripts/register-extensions.sh` registers that build's Quick Look and Finder
extensions (ad-hoc signatures change every build, and several worktrees may hold a Stow.app).

`Stow.xcodeproj` is generated — edit `project.yml`, not the project.

## Design review screenshots

```bash
scripts/snapshot.sh <scene> [light|dark]   # → snapshots/
```

Scenes: `editing`, `readonly`, `welcome`, `grid`, `list`, `fonts`, `search`, `search-open`, `activity`, `pack`, `draft-empty`, `draft`, `draft-save` (the new-archive draft and its Save sheet), `tray`, `quicklook`
(`-StowPreview encrypted|slow`), `associations`, `integration` (`-StowRepair YES`), `batch`,
`conflict`, `conflict-folder`, `signature-warning`, `replace-app`, `extract-options`, `install-options`,
`packing`, `packed`, `packrun`, `checkup`, `install-preparing`, `install-done`, `open-unreadable`, Details and archive notices (`details-clean`, `details-planned`,
`details-more`, `details-notices-open`, `details-folder`, `details-multi`, `details-edited`, `details-app`,
`details-app-signed`, `details-long`; `-StowNoticesOpen YES` opens the notice card in any scene, `-StowArchiveInfoOpen YES` the title menu's Archive Info popover), `source-access`, `source-access-file` (both take `-StowSourcePath <file>` or
`-StowSourceName <name>`), `source-access-unsaved`, `browser-opening` and `glance-opening` (an archive still opening). Browsing scenes take `-StowOpen <path>`
(`-StowOpenPreferred YES` routes it as Finder does, into the window Settings › Glance picks) plus the flags listed in
`App/Browser/BrowseDemo.swift`.
`open -StowOpen <path> -StowRun extractAll|install|fonts|installer` runs a real step
(`-StowInstallFolder`/`-StowExtractFolder` point it at scratch folders); with a locked screen,
`-StowSnapshotMode view` draws the view tree instead of the composited window.
Display preferences can't be turned on by a launch argument, so any scene takes debug-only overrides:
`-StowReduceTransparency YES` (Stow's solid fallbacks for glass), `-StowIncreaseContrast YES` (Stow's
own borders and colours) and `-StowReduceMotion YES` (Stow's fades in place of movement). None reaches
system controls, the accent's high-contrast variant or AppKit's own window animations: an app can't take
the system's settings itself, so the real switches still need a pass by hand.

Motion is reviewed in frame bursts: `-StowBurst <transition>` plays one transition, by click and as after a
key press, and writes a contact sheet of frames at fixed offsets (`App/DemoBurst.swift` lists the
transitions; `-StowBurstCrop x,y,w,h` crops, in points). `scripts/motion-bursts.sh <dir> [transition…]`
captures each one light and dark, plain and with each override.

Test fixtures are rebuilt with `scripts/make-fixtures.sh` (disk images) and
`scripts/make-browse-fixtures.sh [--big]` (browsing, 100k entries).
Use `scripts/make-fixtures.sh --compatibility-only` for the self-generated realistic installer:
8 KiB Finder store leaves, a multi-resolution root TIFF, a regular Applications bookmark and a
named ICNS companion. The private real-image corpus runner and coverage are described in
[the DMG compatibility report](Handoff/dmg-corpus-compatibility-2026-11-08.md).

## Settings keys

Settings keys (UserDefaults; the resettable list and defaults are in `SettingsKeys`):

| Key | Default | Values |
| --- | --- | --- |
| `extract.allFolder` | `automatic` | `automatic`, `always` |
| `extract.afterExtractAll` / `install.afterInstall` | `keep` | `keep`, `trash`, `ask` |
| `extract.closeWindowAfter` | `false` | |
| `extract.folderConflict` | `ask` | `ask`, `merge`, `keepBoth` |
| `extract.fileConflict` | `ask` | `ask`, `replace`, `keepBoth`, `skip` |
| `extract.skipSystemFiles` | `true` | |
| `install.removeQuarantine` | `false` | |
| `general.appearance` | `system` | `system`, `light`, `dark` |
| `browse.defaultView` | `grid` | `grid`, `list`, `columns` |
| `browse.hoverPreviews` | `true` | |
| `password.showByDefault` | `false` | |
| `glance.colourfulControls` | `false` | Red Close, yellow Pin and green Open in Full Window controls |
| `PackAudience` | `windows` | `windows`, `mac`, `linux`, `web` |
| `PackLevel.<audience>` | `5` (Balanced) | One compression level per audience |
| `PackVolumeSize` | `0` | `0`, `100000000`, `700000000`, `4000000000` bytes |
| `PackVerify` / `PackCPUCores` | `false` / `0` | 0 cores means all |
| `FinderMenuOnExternalDrives` | `false` | |
| `tray.enabled` | `false` for fresh installs | Existing effective Tray availability is migrated once; reset does not remigrate |
| `tray.menuBarIcon` / `tray.showWhileDragging` | `true` / `true` | Subordinate to the master switch; no idle timer |
| `SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` | `true` / `false` | Sparkle's own keys (General › Updates); reset falls back to Info.plist |

## Layout

| Path | What |
| --- | --- |
| `README.md` | What Stow is, how to install it, where everything else lives |
| `DEVELOPING.md` | This file: building, testing, design-review screenshots, fixtures, settings keys |
| `ARCHITECTURE.md` | The archive engine, Finder integration, sandbox decisions, installing, updates |
| `DESIGN.md` | Design language: principles, vocabulary, color, type, motion values |
| `PARITY.md` | Feature-by-feature comparison with ArcZip 1.1.1 and what is left to build |
| `App/Model` | Value types: archive listing, Checkup findings, Actions (`NextStep`), packing rules |
| `App/Engine` | Engine client (XPC), staged extraction, conflict-aware placement, destination picker |
| `App/Install` | App/font/package installers, folder grants, prompts, archive aftercare |
| `App/Batch` | Batch extraction queue and its progress stack |
| `App/Options` | Extraction and install settings views |
| `App/Updates` | Sparkle updater, when it may run (`UpdatePolicy`), installs that wait for running tasks |
| `Engine` | `StowEngine.xpc`: sandboxed service that drives `7zz` |
| `Shared` | Compiled into both: XPC contract, 7-Zip driver and parser, path containment |
| `App/Design` | Tokens (space, radius, motion), flow layout, thumbnails |
| `App/Browser` | Main window: title menu and Checkup, floating navigation and search, grid/list/columns, Details and Archive Info, floating archive controls and the Actions stack, hover preview |
| `App/Pack` | The Pack sentence and its compatibility report |
| `App/Tray` | Floating drop shelf |
| `App/Integration` | Finder/Services actions, folder grants, File Types, login item, Dock, repair |
| `Preview`, `QuickLook` | Quick Look extension and its view (also compiled into the app for review) |
| `FinderSync`, `Handoff` | Finder context-menu extension and the one-time token hand-off |
| `App/Welcome` | Empty state / drop target |
| `website/` | Marketing site, deployed with the rendered docs to GitHub Pages (`scripts/build-site.py`, `.github/workflows/pages.yml`) |
| `ROADMAP.md` | Follow-up plan: remaining features, design polish, release work, and tests not yet run |
| `RELEASING.md` | Signed, notarized release builds and the Sparkle appcast: secrets, `scripts/package.sh`, `scripts/generate-appcast.sh`, the Release workflow |
| `.claude/skills` | Project-level agent skills (design engineering, Apple design, Swift) — MIT, © Emil Kowalski |
