# Stow architecture

How Stow reads archives, talks to Finder and installs things while staying sandboxed, and why it is
built that way. Build and test instructions are in [DEVELOPING.md](DEVELOPING.md).

## Archive engine

All archive parsing happens in `StowEngine.xpc`, a sandboxed XPC service that runs an official-source
`7zz` build with a small Stow decoder-registration patch (LGPL — see `THIRD_PARTY_NOTICES.md`) as a child process inheriting its sandbox.

- **Contract** (`Shared/EngineContract.swift`): versioned; requests and replies are JSON. No paths
  cross the boundary — Stow sends the archive as an open, read-only `FileHandle` (7zz reads it as
  fd 3), so the engine needs no access to people's files at all.
- **Listing:** `7zz l -slt`, parsed into `ArchiveListing`, mapped into `Archive` with names shown
  where they would actually be written, plus listing-time Checkup findings.
- **Embedded ZIP compatibility:** after an unrecognized-input failure, listing, extraction and
  verification retry with explicit ZIP scanning bounded by the prepared file size (`-tzip:s<size>b`).
  Recognized damaged archives and password errors are not retried. Checkup retains prefix/tail
  warnings; ZIPs with surrounding data are read-only so Save cannot discard unrelated bytes (#207).
- **Extraction:** the engine extracts into its *own* container (the only place it can write) with
  `-bsp1` progress, removes links that point outside and device files, then streams the folder to
  Stow over a pipe as an Apple Archive. Stow unpacks it into private staging on the destination
  volume, audits it again, and publishes with an exclusive rename. FSKit exFAT uses an exclusive,
  cancellable copy when that rename is unsupported; partial output is visible during copying.
  Rollback removes unchanged owned output and reports locations it cannot safely clean up.
- **Containment** (`Shared/PathContainment.swift`): `../`, absolute paths and outside-pointing
  links are kept inside the destination; tests pin the rules to the bundled 7-Zip build.

## Finder, Quick Look and Services

- **Quick Look** (`QuickLook/`, view in `Preview/`): Space on any type Stow registers shows the file
  tree, sizes, format, encryption and a one-line Checkup, with *Open in Stow*. List only, 3 s
  timeout, fallbacks for encrypted names and slow listings. Quick Look extensions may not launch
  processes and can't reach the app's XPC services, so the extension carries its own copy of
  `StowEngine.xpc` and sends it the file as a handle, exactly like the app does.
- **Finder menu** (`FinderSync/`): Extract Here, Extract To…, Open in Stow, Compress with Stow…;
  external drives are opt-in.
- **Services**: Stow: Extract Here, Extract To…, Quick Compress, Compress…, and Send to Stow.
- **File types**: Settings › File Types sets Stow as the default per type, remembers the previous
  app and switches back. macOS confirms each change in its own dialog.
- **Login item & residency**: `SMAppService` remains opt-in. Enable Tray to keep a menu-bar resident
  after normal windows close; with Tray disabled and no pending work, Stow exits.

### The Finder → Stow hand-off

The Finder extension never opens files. It posts the selection (action + paths) under a random
128-bit token and opens `stow://handoff/<token>`; Stow takes the request once and refuses unknown,
reused or older-than-60-s tokens and any other URL shape. No path ever travels in a URL, so a web
page that opens `stow://…` can't make Stow do anything. The mailbox is a private named pasteboard:
an App Group container would be the textbook choice, but macOS refuses group containers to builds
without a Team ID (ad-hoc builds get `EPERM`), while named pasteboards work between any sandboxed
processes and `releaseGlobally()` makes them single-use. A Team-signed release could move the
mailbox into a group container without touching the token rules (`HandoffMailbox`).

### Sandbox and Finder actions: why Stow asks once per folder

Extract Here and Quick Compress write next to the original, which a sandboxed app can't do by
default. Options considered:

| Approach | Verdict |
| --- | --- |
| Full Disk Access as a default prerequisite | Rejected: broader privacy access than archive actions need; it does not remove sandbox restrictions |
| Remove the main app sandbox | Not chosen: retain scoped access and the separate sandboxed engine |
| Access granted through the extension | Not available: the Finder Sync extension is sandboxed too and receives paths, not file access it could hand on |
| Temporary-exception entitlements for home or `/` | Rejected: the same as no sandbox for people's files |
| **One-time folder grant** | **Chosen** |

The first time an action needs a folder Stow can't write in, Stow shows an Open panel already
pointing at that folder and says why ("Choose Allow to let Stow extract … here — and next time,
anything in this folder"). Allow grants that folder and everything inside, kept as a
security-scoped bookmark; picking a different folder uses it once and remembers nothing.
Settings › Finder & Permissions lists every grant with Forget. Services and opened documents already
normally give Stow read access to the files themselves. When an archive open is denied (including
files passed from another app), Stow offers the system picker at its source folder. Select that
folder to remember access, or select only the original archive. Folder access includes read/write
access to files and subfolders; Stow verifies the archive is readable before saving the grant and
continuing the open. If access is still denied, it explains how to open an exported copy.
Remove forgets the saved folder bookmark; existing file grants or macOS permissions may remain.
See the [source-access plan](Handoff/source-file-access-plan.md) and its separate native acceptance.

## Installing from a sandbox

Stow stays sandboxed (user-selected files only) and asks for the narrowest access each install needs:

- **Where installs go.** The first install into /Applications, ~/Library/Fonts or a disk image's
  "drag here" folder opens an Open panel already showing that folder; choosing **Allow** grants that
  one folder, kept as an app-scoped security-scoped bookmark (`App/Install/FolderAccess.swift`,
  entitlement `files.bookmarks.app-scope`). Settings › Installing can forget a grant. No helper
  tool, no Full Disk Access. Accounts that can't write to /Applications are told so.
- **Why staging lives in the destination.** macOS marks files a sandboxed app writes into its own
  container as "created by a sandboxed app" (quarantine flag `0x0080`), and Gatekeeper then refuses
  to run them. Stow therefore stages each extraction in a hidden `.stow-staging-…` folder inside the
  folder you chose (entitlement `files.user-selected.executable`), audits it there and publishes
  without replacing existing names. Installer packages are unpacked the same way beside the archive.
- **Gatekeeper still runs.** Before installing, Stow checks the app's code signature and
  notarization (`App/Model/CodeSignature.swift`) and asks before installing anything unsigned,
  ad-hoc signed, not notarized, broken or signed with an unknown certificate. Files written into a
  folder you chose aren't quarantined by the sandbox, so — like Archive Utility — Stow carries a
  downloaded archive's quarantine over to what it installs or extracts (through Launch Services'
  quarantine properties; a raw `setxattr` is refused, and the flag is applied after the final move,
  which would drop it). macOS then checks those apps on first launch. Not carrying it over is an
  opt-in setting ("Remove the quarantine flag").
- **Disk images are never mounted.** The engine reads HFS+, APFS and ISO images directly, so a DMG
  is browsed read-only with nothing attached to detach.

## Extract commands

In Browser and Glance, File › Extract (⌘E) extracts the selection. File › Extract All
(⇧⌘E) extracts the whole archive without clearing the selection, even when Glance's
selection Actions hide the Extract All button. Extract All waits until listing or a
running step finishes and is unavailable when another window or a sheet is active.

## First run and Settings

A skippable Welcome to Stow checklist introduces archives, file types, the Finder
extension and Tray (⌥⌘T). Skip or Get Started finishes it; Help › Welcome to Stow reopens it.
Resetting preferences keeps first-run completion remembered.

Stow has a Settings window (⌘,): a sidebar of General, Extraction, Installing, Packing, Actions,
Glance, Previews, Passwords, File Types, Finder & Permissions, Advanced and Licenses pages, beside one
scrolling page. Tray has its own settings page and master enable switch. The host lives in `App/Settings` and reuses the extraction and
installing forms in `App/Options`. Advanced can clean preview caches and reset preferences. The keys and their defaults are listed in
[DEVELOPING.md](DEVELOPING.md#settings-keys).

## Updates

Stow updates itself with [Sparkle](https://sparkle-project.org) 2 (Stow › Check for
Updates…, and General › Updates in Settings). The feed is the `appcast.xml` on the latest
*published* GitHub release, and each update DMG is EdDSA-signed with Stow's own key (public half
`SUPublicEDKey` in `project.yml`) as well as Developer ID–signed and notarized. Stow stays
sandboxed and without network access: Sparkle's downloader service fetches the feed and the update,
and its installer service replaces the app; a restart into an update waits until extracting,
packing or opening finishes (`App/Updates`). Debug, ad-hoc, test and `-Stow…` demo runs never
start Sparkle, so they never touch the network or show an update prompt.

## New archives and the sample

Welcome and File > New Archive (Command-N) open an unsaved archive draft. Add/remove sources,
then Save configures and creates a real archive using the same engine as quick Pack. Tray and
ordinary-file drops retain the quick Pack path. Closing a changed draft offers Save/Discard/Cancel.

Production Release bundles omit `Resources/Sample`. Debug builds copy those deterministic
fixtures for tests and `scripts/snapshot.sh`; the source assets and licenses remain in the repository.
Help > Download Sample Archive (also in Welcome to Stow) is an explicit browser download of the genuine ZIP pinned to revision
`33d533e7a74c0f6c862ce49a8d0fc72e93a71e90`; Help > Sample Credits and Licenses opens its source
and license directory. Open the downloaded ZIP normally. No sample is fetched at launch, no
network entitlement is added, and a missing fixture never becomes a fabricated production archive.
