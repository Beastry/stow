# Bounded Zstd-in-7Z decoder — #316

## Scope and architecture

The stock official 7-Zip 26.04 binary reproducibly lists but cannot decode the supplied
Zstd-in-7Z fixtures. Its source already includes Igor Pavlov's Zstd decoder for standalone
`.zst`; adding a decoder-only registration for method `04F71101` makes all five original
fixtures decode to the exact expected 20,000 bytes. This includes Delta, AES encryption,
numbered split archives and encrypted split archives. Listing alone was never acceptance.

The selected implementation builds one engine from the pinned official source plus
`scripts/patches/7zip/zstd-7z-decoder.patch`. There is no secondary parser, automatic fallback,
external codec lookup or new runtime library. A full 7-Zip-zstd fork would add unrelated
codecs/encryption and additional maintenance; an external plugin does not work with the
standalone `7zz` variant. Waiting for upstream registration would leave this confirmed gap.
The minimal patch is explicit maintenance debt: rebase/review it with every upstream update.

The factory registers a decoder and **no encoder**. Zstd-in-7Z creation is not added. Existing
Pack/save formats retain their current encoding paths. The binary banner identifies the
modified build as `26.04-stow-zstd1`. This is not the official unmodified macOS executable.

## Bounds and compatibility

Only the registered 7Z decoder sets `CZstdDecState.windowSizeLimit` to 512 MiB. The C decoder
checks the advertised window before allocation; oversized windows fail with Unsupported Method.
The chosen bound admits reference Zstd's regular window sizes while avoiding the upstream
64-bit allowance of up to 2 TiB for this newly exposed coder. It is a **per-window** bound,
not a total-process memory limit: cyclic buffering adds block-alignment/output slack, input
buffering is 512 KiB per decoder, and archive coder graphs/other codecs retain upstream costs.
No new total archive-size or process-memory guarantee is claimed.

Standalone `.zst`/`.tar.zst` uses the unchanged default constructor and no new window bound.
`ZstdDecState_Clear` uses `memset(..., sizeof(*p))`, so the added field defaults to zero.
Both shipping direct users, ZstdDecoder and SquashfsHandler, call Clear before decoding.

Known properties are the current single zero flags byte and legacy 3/5-byte version/level
metadata. Their historical metadata is ignored, as in the producing implementation; actual
Zstd frame metadata controls decoding. Unknown single-byte flags and other lengths fail.
Reference: [producer decoder source](https://github.com/mcmilk/7-Zip-zstd/blob/bc1fb8a66d4ef549b6ac9bbc1bd660fecd2a572f/CPP/7zip/Compress/ZstdDecoder.cpp).
The official decoder retains finish-size checks, 7Z CRC checks and Zstd frame hash checking.

The child process keeps the same signed path, inherited App Sandbox, descriptor staging,
password-on-stdin and cancellation via SIGTERM. XPC protocols, extraction staging, containment
checks and exclusive destination publication remain in place. Cancellation tests wait for
active engine progress, cancel a 2 GiB synthetic expansion and verify no published output.

## Reproduction and distribution

```sh
scripts/fetch-7zip.sh
xcodegen generate
xcodebuild -project Stow.xcodeproj -scheme Stow -derivedDataPath build build
xcodebuild -project Stow.xcodeproj -scheme Stow -derivedDataPath build test
scripts/check-localizations.sh zh-Hans
SIGN_IDENTITY=- OUT_DIR=build/zstd-316-release scripts/package.sh
```

Source release: `https://github.com/ip7z/7zip/releases/download/26.04/7z2604-src.tar.xz`,
SHA-256 `9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6`.
The fetch wrapper verifies it, normalizes only patched files, applies the patch and builds
arm64/x86_64 with upstream macOS makefiles, then combines with lipo. Recipe/patch hashes
invalidate local and CI caches. Compiler/SDK changes can change binary bytes; this is a
reproducible source/build process, not a bit-identical compiler-independent binary claim.

Each engine copy, including Quick Look's nested XPC, ships the license plus complete modified
corresponding source archive. That archive includes `DOC/copying.txt` (LGPL 2.1), other upstream
licenses, all source/makefiles, the patch and a runnable **offline** `build-stow-7zip.sh`:
extract it on macOS with Xcode command-line tools, run `zsh ./build-stow-7zip.sh`; no network or
Stow checkout is needed. The download wrapper also ships solely for provenance. Package
verification checks required source members as well as both engine copies, signatures,
sandbox entitlements and Universal 2. The existing signing executable identity/path stays
unchanged; no Finder/Quick Look registration is performed during validation.

## Ownership and acceptance limits

Codex owns codec correctness, resource/cancellation/security behavior and tests. There is no
new UI or motion. Claude Code retains visual/motion ownership; no visual review is claimed.
Full VoiceOver acceptance/#93 remains deferred under AGENTS.md.

Exact-byte acceptance covers both producers' original ordinary/Delta/encrypted/split cases,
current and legacy properties, solid and non-solid multiple entries including empty and binary
content, preview, selected/all extraction and verification. Invalid property, over-window,
entry CRC, frame checksum and truncation cases must fail without publication. Wrong passwords
retain typed failures. Existing archive tests retain ZIP/7Z/TAR/Zstd baseline coverage.

No Developer ID/notarization, Gatekeeper acceptance, clean account or physical Finder extension
installation is claimed by an ad-hoc package. Release collaborators must perform those checks
with their normal signed artifacts. No native ArcZip or VoiceOver testing is claimed here.

## Recorded local results — 2026-11-07

- `xcodebuild ... build` and `build-for-testing`: passed.
- Focused decoder suite: all 21 expanded cases passed, including add/rename/delete Save for
  solid and non-solid Zstd inputs. Reopened verification and previews matched preserved and
  added bytes. Unchanged retained items do not require a new Zstd encoder; newly encoded items
  follow the existing engine edit plan. No blanket guarantee for every third-party coder graph
  or experimental future properties is claimed.
- Final `xcodebuild ... test`: **770 tests / 115 suites, 0 failed, 0 skipped**, 116.694 seconds.
  Existing standalone Zstandard streams and normal archive/mutation suites passed.
- Localization: **0 of 1,291** strings missing Simplified Chinese; no new product strings.
- Both actual engine slices ran under native arm64 and Rosetta x86_64: eight exact-byte cases
  and all six invalid-input cases passed in an independently offline-rebuilt executable.
  Explicit `a -t7z -m0=ZSTD` remained unsupported (exit 2), as the factory has no encoder.
- Corresponding source archive extracted into an unrelated temporary folder and
  `zsh ./build-stow-7zip.sh` succeeded offline. Both packaged archives SHA-256-match the
  verified Vendor archive. No object files are distributed in it.
- Ad-hoc Release archive, DMG generation and `verify-app-bundle.sh --mode adhoc` passed:
  **12 Mach-O binaries Universal 2, 0 verification problems**, both source/license resource
  copies, inherited sandbox entitlements, strict signatures, `hdiutil verify` and DMG layout.
- The package command's subsequent fresh-Welcome snapshot smoke **did not pass locally**:
  app exited 0 with no fresh PNG. Repeated with no test host/other Stow instance; adding a
  3-second delay and layout logging yielded `focus: none`. The unchanged parent checkout's
  existing Debug app fails the same smoke and prints the same layout result in this context.
  This is recorded as a baseline/local launch-smoke limitation, not successful native launch
  acceptance. No snapshot/UI behavior or strict smoke gate was weakened. Fresh CI/release
  launch validation remains required, along with Developer ID/notarization acceptance.

Positive split cases compare every input part byte-for-byte after verification, preview and
selected/all extraction. Invalid cases verify empty final destinations. Cancellation now
requires an observed progress fraction strictly between zero and one before cancelling; an
initial 0% callback is not counted as active decoder evidence. No original or user volume was
changed and no Finder/Quick Look extensions were registered.
