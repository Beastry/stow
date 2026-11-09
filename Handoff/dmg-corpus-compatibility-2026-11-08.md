# Real DMG compatibility — 2026-11-08

Codex owns parsing, classification, source integrity, cancellation, installation routing and
regression tests. Claude Code retains visual design and motion, including layout and icon
treatment. This work does not redesign the installer canvas or claim Claude Code acceptance.

## Corpus and completed read-only checks

The local corpus contains **35 distinct DMGs, 5.346 GiB**, under the user's
`/Volumes/DataHouse/PortalDown`. All 35 passed `hdiutil imageinfo`, ordinary and stream-inclusive
listings, and pinned `7zz t -tdmg` container checksum tests. Images were not mounted, installed,
registered or launched; originals were not modified. Third-party payloads stay out of commits.

| Observed group | Images |
| --- | ---: |
| UDZO / HFS+ | 23 |
| UDZO / APFS | 7 |
| ULFO / APFS | 3 |
| ULFO / HFS+ | 2 |

All 25 HFS+ listings have a volume-directory prefix; all 10 APFS listings expose contents at the
root. Three images contain an EFI FAT32 partition before their HFS+ payload. Four APFS images
report trailing data while successfully listing. Streams include macOS attributes and resource
forks: 58,627 in total, with `.DS_Store:*` companions in seven images. Store lookup must distinguish
the regular store from its alternate streams.

Thirty images have `.DS_Store`. Five intentionally have none: Antigravity Tools, MiniMax Design,
OrcaTerm, Piebald and Stow 0.1.0. TauriTavern and 闪电说 declare plain backgrounds with icon
positions; absence of background art is expected for those two.

## Reproduced presentation failures and implementation

- **Large valid store leaves:** 14 stores allocate an 8192-byte leaf while retaining a 4096-byte
  DSDB page-size field. The original DSStore dependency rejected them as `invalidBTreeHeader`.
  The bounded library compatibility change accepts these allocations while retaining structural
  validation. OpenWhispr was the initial reproduction; Obsidian, Typeless, ChatGPT Installer and
  others independently reproduced it.
- **Legacy Finder records:** both ArcZip, both Bob 1.20 and both pap.er images use
  `BKGD`/`pict`/`icvo`/`icvt` rather than `icvp`. Stow now recovers their contained background
  aliases and authored icon/text sizes, with modern settings taking precedence.
- **Root background files:** ten images keep `.background.png` or `.background.tiff` directly
  beside the store. Exact `.background.<known raster extension>` files become presentation/helper
  items excluded from Extract All. Arbitrary hidden files remain content.
- **Finder alias destinations:** Steam and both Bob 1.20 images use regular Finder alias files
  for Applications; Bob 1.21 uses a localized HFS+ symlink. Bounded recognition of the finite
  Applications names reads cached bookmark directory/path properties only. It never resolves a
  destination, mounts a volume or follows a network share. Unrecognized files remain content.
  The reconstructed archive consistently records helper visibility, Extract All exclusion and
  install routing. Same-byte name/URL rebuilds retain validated destinations and completed
  findings; reload discards old classification before reading new bytes. Checksum completions
  belong to their captured source level/identity, so entering a nested archive or replacing the
  source cannot attach a verdict to different contents.
- **Named icon companions:** both ArcZip versions declare `CFBundleIconName=ArcZip`, with a
  listed `Resources/ArcZip.icns` and no `CFBundleIconFile`. The exact named `.icns` companion now
  follows an explicit icon file in precedence. No asset-catalog decoding or broad icon search is
  added.

Independent expected metadata covers every image: canvas/background presence, volume root,
positions, icon/text sizes and exact listed background/icon paths. These facts came from a separate
binary-store parser and plist inspection, rather than from Stow's loader output.

## Payload compatibility and validation

Six representative app bundles were extracted into disposable folders: AigcPanel, ArcZip 1.1.4,
Claude, OpenWhispr, Kimi and Steam. Every regular file was read in full and hashed; listed files
and internal links were checked. The first four retained valid strict Developer ID signatures.
Kimi and Steam initially lost 27 and one parent-relative internal links respectively because
7-Zip refused them, leaving placeholders. Restoring only proven contained links in a separate
diagnostic extraction made both original signatures pass strict verification. This establishes an
extraction compatibility defect. The full-corpus pass also exposed APFS links in MiniMax Design
and Peach whose stored bytes include one trailing NUL that is not part of the POSIX target.

The engine now verifies each refused link against a unique listed symlink and a bounded exact
read of its data fork. It accepts the single APFS terminator only when the explicit listed target
matches. Restoration requires initially empty, unchanged private staging; directory handles opened
without following symlinks; an owned empty regular placeholder with one hard link; and a relative
target resolving entirely within staging. Dependency order is supported, while absolute/escaping,
missing and cyclic targets remain rejected. Unicode case-fold collisions cannot authorize replacing
an ordinary file. Both existing containment audits still run, and no unsafe 7-Zip switch is enabled.
An independent patched-engine run preserved strict signatures for all four affected apps.

The complete application regression suite passed **860 tests, zero failures or skips**. The final
literal-path edge adds coverage for links whose paths start with `-` or `@`; the isolated engine
suite passes all 12 test functions. The vendored DSStore package passes all 170 upstream tests.
The committed realistic fixture exercises metadata, named icons, alias classification and extraction
exclusions through XPC. A generated signed app tests installation with parent-relative links through
both audits and checks that its seal survives.

Native Computer Use confirmed OpenWhispr's authored background, icon and Applications target in
both Browser and Glance; Steam's regular Finder alias and ArcZip's legacy layout/named icon also
render correctly. These were AX inspection/activation and screenshot observations, not VoiceOver
testing. No third-party app was installed or launched. The final **35/35-image XPC corpus run passed** in 153 seconds. All images passed listing,
root/installable/helper classification, independent layout/icon checks, bounded metadata byte hashes,
and complete payload staging. All 30 authored canvases and 28 picture backgrounds decoded as
expected. Of 34 app bundles, 33 retained valid strict nested signatures. Antigravity Tools has an
unsealed linker-ad-hoc signature in the original image (no CodeResources); independently extracting
the original produces the same -67056 status. Its baseline is recorded explicitly, and Stow's
signature warning is preserved. The remaining image carries an installer package; its payload was
staged, not executed. No payload links or other payload items were removed in the final corpus run.
Simplified Chinese localization and generated-plist checks also passed.

The corpus contains no encrypted images and only the four compression/filesystem combinations
above. It does not establish compatibility with every DMG, multi-volume image, older Carbon
Applications alias convention, or asset-catalog-only icon. Unsupported metadata keeps the ordinary
file browser and generic-icon fallback. Dedicated VoiceOver acceptance remains deferred under
#93; this report makes no VoiceOver claim. Signed Finder/Quick Look integration
requires the intended release app and the existing release-collaborator workflow.

Local evidence is under gitignored `build/dmg-corpus/`: `inventory/REPORT.md`,
`layout-audit/FINDINGS.md`, `layout-audit/expected-layouts.json`, the separate OpenWhispr audit,
and `payload-validation/REPORT.md`. The opt-in test wrapper is
[`scripts/check-dmg-corpus.sh`](../scripts/check-dmg-corpus.sh); run it only against an explicitly
provided local corpus. Local metadata and third-party images are not bundled with the tests.
