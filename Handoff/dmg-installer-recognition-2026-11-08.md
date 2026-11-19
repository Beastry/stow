# DMG installer recognition — PikPak comparison

**Historical brief, archived 2026-11-18.** Current implementation and later user decisions are
recorded in [DESIGN.md](../DESIGN.md) and the [current handoff](ui-motion-claude-code.md).
The dated observations and proposals below are retained as evidence; they do not override those
current documents or establish present implementation status.

Published implementation issue: [#344](https://github.com/Beastry/stow/issues/344).
The issue is self-contained for Claude Code's review on a separate development machine;
the original DMG still needs to be provided there. Publication does not dispatch a session.

## Report and observed behavior

The user reported that `/Volumes/DataHouse/PortalDown/PikPak_Mac_AppleSilicon.dmg`
opened as ordinary archive content instead of exposing the installation workflow, and
asked whether the existing fixtures were too simple.

Native inspection on 2026-11-08 compared ArcZip 1.2.2 (349) with installed Stow build
691. ArcZip was already displaying this image: its disk-image view showed PikPak.app,
Applications pointing to `/Applications`, the authored background and icon positions,
and an Install Application action marked Pro. The installation action was not executed;
this establishes recognition and presentation, not successful installation or its trigger.

Opening the same file from Stow's Recent list showed only `PikPak-v2.7.1.2480` and
Extract All. Entering that folder exposed PikPak.app alongside `.background`, the volume
icon, Applications and HFS bookkeeping folders. These were AX-assisted observations,
not VoiceOver acceptance tests.

## Root cause and functional correction

The image is a zlib-compressed UDIF containing HFS+. Bundled 7-Zip 26.04 successfully
lists the app and the Applications symlink under the volume `PikPak-v2.7.1.2480`.
The failure is in `DiskImageLayout`: it previously required the sole root's filename
extension to be empty. The version suffix therefore prevented volume-root recognition.
That also prevented installer-extra filtering, drop-target recognition and automatic
selection of the sole installable application.

Volume detection now excludes actual macOS package/bundle directories using the same
classification as browser navigation, instead of rejecting all dotted names. Explicit
non-directory or symbolic-link roots are not accepted as volume wrappers. Stored paths
remain intact for extraction. Opening only offers an action; it never installs or runs
downloaded software automatically. Existing destination grants, signature prompts,
quarantine handling and cancellation remain in the installation path.

## Fixture coverage

The existing HFS+ and APFS images already exercised real signed-app extraction, but both
used the simple volume name `Fixture Tool`; their payload is a tiny ad-hoc-signed app,
placeholder background/icon data and an Applications symlink. They did not exercise a
versioned volume name or real Finder artwork/layout.

- Added a small generated HFS+ fixture with volume `Fixture Tool-v2.7.1.2480`, exercised
  through sandboxed XPC listing, Browser selection, install-action selection, installation
  to a temporary destination, signature assessment and extraction filtering.
- Added model coverage for dotted versions, Chinese names, domain-style names and sole
  top-level packages that must not be treated as volume wrappers.
- The third-party PikPak binary is a local validation input, not a repository fixture.

Future fixture expansion should cover a signed app with versioned framework symlinks,
multiple apps, package installers, custom install targets, valid `.DS_Store` and artwork,
and images whose content is data rather than an installer. Each fixture should assert
observable behavior; larger file size alone would not have caught this bug.

## Confirmed product direction and ownership

Codex / Grok Bot owns recognition, extraction, installation safety, state and tests.
Claude Code owns layout, materials, hierarchy, icon treatment and motion. No Claude Code
review, acceptance or assignment is claimed.

After the initial diagnosis, the user explicitly asked for an experience closer to the
original DMG installation window, as ArcZip presents it. Restoring authored presentation
is now required product scope. The earlier description of that work as optional is
superseded. The volume-recognition fix is complete locally; authored presentation and
drag-to-install are not implemented by that fix.

The user confirmed the outcome, not a specific Stow composition or animation. Preserve
the author's content while Claude Code chooses how it fits within Stow's Browser.
No automatic mounting is needed for this direction.

### Functional experience to deliver

1. Opening an image with usable authored icon-view metadata shows its installation
   canvas: background, app icons, labels, relative positions and install destinations.
   The metadata belongs to the volume contents, not an extra version-named folder that
   the person must enter. List/column browsing remains available.
2. Use the app's actual bundle icon when available. Decode the icon resource without
   extracting the entire app merely to draw it. A failed icon decode keeps a usable
   named app control with a fallback icon.
3. Applications is a visible destination with its real target, rather than an ordinary
   13-byte extracted file. Dropping an eligible app onto it enters the same Installer
   path as Install App. Both preserve destination authorization, signature checks,
   replacement/running-app handling, quarantine, cancellation and aftercare.
4. Dragging or selecting alone installs nothing. Keep a keyboard-accessible Install App
   action; drag cannot be the only route. Do not launch the downloaded application as
   a side effect of opening the image or selecting its icon.
5. Keep the authored relationship between artwork and interactive icons when the window
   changes size. Images must not stretch independently of the icon coordinate system.
   Do not copy the creator's absolute screen location or resize/move the host window
   from untrusted metadata. Claude Code chooses fitting, scrolling and minimum sizing.
6. Entries without valid positions remain reachable alongside the canvas. Multiple
   apps must require an unambiguous choice. Data-only images continue to work as data.
   Missing/corrupt metadata falls back to ordinary browsing with available install actions;
   it must never prevent listing or extraction.
7. Separate presentation assets from extracted content. Backgrounds and install links
   can be visible as artwork/targets without entering ordinary Extract All results.
   A background load must not silently enable extraction of filesystem bookkeeping.

### Native reference evidence and measured input

Further ArcZip inspection confirmed that choosing List View replaces the authored canvas
with rows, and returning to Icon View restores the disk-image view. The app and Applications
are selectable items and Details changes with selection. Items without positions appear
in an Other Items area. Installation completion, drag/drop behavior, Pro access and
animation timing have not been validated; the desired Stow drag behavior above is a
functional proposal supporting the user's confirmed outcome, not a claim about ArcZip.

Read-only extraction and the repository's pinned DSStore reader recovered these values
from the supplied PikPak image, without mounting it:

| Source | Value | Implementation consequence |
| --- | --- | --- |
| `bwsp.WindowBounds` | `{{100, 100}, {600, 402}}` | Preserve size information separately from the creator's screen origin |
| `icvp.iconSize` / `textSize` | 128 / 12 | Authored size hints, subject to readable host presentation |
| `Iloc` for PikPak.app | (148, 160) | Left app position in authored coordinates |
| `Iloc` for Applications | (452, 160) | Right target position in the same coordinates |
| `icvp.backgroundType` | 2 | Picture background |
| `icvp.backgroundImageAlias` | 314-byte Carbon Alias | Parse the archive-relative resource reference; do not resolve it against the host filesystem |
| Referenced background | `.background/dmg-bg@2x.png`, 1200 × 700 pixels | Account for the Retina asset; raw pixels are not layout points |
| `Info.plist.CFBundleIconFile` | `electron.icns`, present under `Contents/Resources` | The real app icon is available without unpacking the executable/frameworks |

The alias contains both `/.background/dmg-bg@2x.png` and the original
`/Volumes/PikPak-v2.7.1.2480` volume path. String inspection establishes those bytes;
it is not a production alias parser. An exact archive-entry match must determine which
resource is loaded. Do not resolve aliases through Finder, mount volumes, access network
paths or search unrelated local files.

### Implementation dependencies

- `DSStore` is already a dependency. Its reader exposes typed property-list records,
  `Iloc` coordinates and window settings. `DiskImageChrome` currently uses it to write
  layouts; reading layouts is a separate capability from authoring picture aliases.
- Add a presentation model separate from `Archive.entries` and extraction filtering.
  Preserve source paths in `ArchiveSource.listing` for metadata/assets hidden from normal
  browsing. Loading these files needs explicit helper-file handling: the preview cache's
  default extraction path is not sufficient for all hidden metadata.
- Add bounded, cancellable metadata and asset reads through the existing engine. Validate
  record counts, coordinates, sizes, referenced paths and decoded image dimensions. A bad
  metadata asset falls back locally; it does not become an archive-open error. Switching
  archives or closing Browser cancels loading and prevents stale artwork publication.
- Resolve Carbon Alias references only to verified entries in the same archive/volume.
  Unsupported aliases fall back cleanly. Load bundle icons from declared icon resources;
  do not choose an arbitrary first `.icns` when Info.plist declares another icon.
- `PreviewService.wantsThumbnail` currently excludes folders/packages, so the app icon needs
  a dedicated resource-loading path. Do not extract hundreds of megabytes on initial display.
- Claude Code implements the canvas and visible destination treatment on top of these
  models. Route both drops and explicit commands through the existing install coordinator,
  with named controls, basic keyboard access and system display/motion preferences.

### Acceptance and fixture expansion

Use the supplied PikPak image for visual comparison and a redistributable generated fixture
with valid artwork, `.DS_Store`, a real declared app icon and an Applications symlink for CI.
The current three-byte background placeholder is not visual-fidelity evidence.

Acceptance covers authored artwork/positions, Retina sizing, smaller windows, list/icon
round trips, keyboard installation, drag/drop cancellation, destination permission denial,
replacement and signature prompts, multiple apps, unpositioned files, data-only images,
missing assets, malformed metadata, out-of-volume aliases and rapid archive switching.
Signed app fixtures should include nested helpers and versioned framework symlinks so the
install tests check preservation of realistic bundle structure. Dedicated VoiceOver
acceptance remains deferred under AGENTS.md; AX checks must be labeled separately.

## Validation

- Source baseline: `3e7d998` plus the local changes described above.
- Localization export: all 1,067 strings have Simplified Chinese translations.
- All new layout cases and the three real-image install/extract cases passed.
- The supplied PikPak app was extracted with bundled 7-Zip into a temporary directory.
  `codesign --verify --deep --strict` passed, including nested apps/frameworks. This is
  extraction/signature evidence, not a sandboxed install or Gatekeeper launch test.
  PikPak itself was not launched and `/Applications` was not modified.
- The initial incremental test host stalled in dyld before tests started. A fresh derived
  data directory resolved it: 569 tests passed, zero failures or skips; the xcresult
  assertion script also passed. Result bundle:
  `/tmp/stow-dmg-validation-20261108/Logs/Test/Test-Stow-2026.11.08_15-47-46--1000.xcresult`.
- Native AX/screenshot validation of that exact temporary build opened the supplied image
  from Recent directly into the volume, selected PikPak.app, hid installer extras and
  exposed `Install App: PikPak.app`. Installation was not invoked for the real app.
  The temporary build uses this checkout's older Browser presentation; this check is
  functional evidence, not a comparison of latest-main visual design.
- The installed Stow and registered Finder/Quick Look extensions were not replaced.
