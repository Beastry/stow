# System Quick Look renderer failure and preview request lifetime

## Scope and ownership

The user reported a tiny Word document spinning in Quick Look inside the currently opened
archive, slower previews than ArcZip, and unblurred folder icons underneath the Browser title.
Codex owns the preview configuration, cancellation, cache lifetime and tests. Claude Code owns
the title-bar material, visual hierarchy and motion. The title-bar brief below is a requested
correction, not visual approval or a claim that Claude Code has started reviewing it.

## Observed reproduction

- Host: macOS 27.3 (26C5035r). Installed Stow: 0.1.8 (758). ArcZip: 1.2.2 (349).
- Local archive: `1749285900(1).zip`, 70,460,225 bytes, 407 files.
- Entry: `FPGAkeshe/FPGA课程设计题目.docx`, 13,674 bytes (12,001 compressed). It is DOCX,
  distinct from the 61.9 MB `课程设计报告.doc` beside it. User document contents were not committed.
- Stow's grid and Details thumbnail rendered the document. The file existed in the preview
  cache before Space opened Quick Look. The full panel spun for an extended period and
  eventually showed a thumbnail/name/size card instead of the document body.
- Logs at the request showed WebKit WebContent/GPU process launch failures and repeated
  `Invalid connection identifier (web process failed to launch)` messages in Stow.
- ArcZip displayed the same document as readable HTML in its Quick Look panel in the initial
  observation, within the roughly six-second automation call. This is an observation, not a
  controlled cold-cache benchmark of either product's entire preview pipeline.

## Confirmed cause and correction

The main app lacked `com.apple.security.network.client`. Office/HTML Quick Look renders using
WebKit in the host process, whose child processes failed to launch with that sandbox setup on
this host. Thumbnail generation uses a different path, explaining why Details still worked.

A minimal AppKit/QLPreviewPanel probe bundled the same document in two separate app identities.
Both were sandboxed and had identical code; the only entitlement difference was network-client
access. The baseline reproduced the spinner. The variant with network-client access displayed
the document body within the roughly four-second app-launch/observation call.

The correction adds that entitlement to Stow's UI host and changes the release verifier from
rejecting it to requiring it. The verifier also rejects client/server network entitlements on
every bundled archive engine and its 7-Zip child. Sparkle still downloads through its own
service. This is a real expansion of the UI host's capabilities: system Office/HTML preview
resources may use the network. Do not describe the whole app as unable to access the network.
The archive parser and its child retain their existing separate sandbox and network restrictions.

An isolated copy of the corrected Debug Stow used `app.stow.PreviewQA`, without Finder/Quick Look
plugins, document associations or App Group access. Opening the original ZIP, selecting the
same DOCX and activating Quick Look displayed the actual document table/text within the
roughly two-second observation call. `/Applications/Stow.app` was not replaced and installed
extensions were not re-registered. This establishes the fix on this host; it does not establish
acceptance on every supported macOS version or a notarized release.

## Other preview findings

Fixed alongside the configuration:

- Thumbnail requests previously awaited the system generator without a deadline or explicit
  cancellation forwarding. A generator that did not complete could leave Details spinning.
  Requests now return after ten seconds, cancel system work on timeout/view cancellation,
  ignore late callbacks, and avoid marking a cancelled tile as a permanent thumbnail failure.
- Quick Look pinned freshly extracted files but omitted files already present in the cache.
  Those files could be evicted while the panel was using them. Both routes now pin files,
  and close/reload/end-control consistently release their pins.

Remaining performance work, distinct from the reproduced Office renderer failure:

- `SevenZip.Prepared` copies the whole descriptor-backed archive into an engine-private file
  for each ZIP extraction. Selecting an uncached tiny entry can therefore read the entire ZIP.
  Thumbnail batching limits the number of trips but does not reuse that archive snapshot.
  Preserve descriptor-only source authorization and the parser sandbox when optimizing this;
  consider a bounded engine-owned snapshot keyed to source identity and invalidated on change.
- A local timing probe copied the original ZIP and extracted only this DOCX with the bundled
  7-Zip. Warm runs: copy 40.3/36.7 ms; extraction 12.7/10.0 ms. First run: copy 82.6 ms;
  first executable launch/extraction 1,790.4 ms. These omit XPC, auditing, transfer and rendering,
  and do not support attributing a minute-long spinner to ZIP decompression.
- Details/hover rich previews regenerate their result when views are recreated; they share the
  extracted file cache but do not share the grid's rendered thumbnail cache at all sizes.
  Reuse completed renders and deduplicate same-file/same-size work before expanding prefetch.
- Shared extraction tasks outlive individual cancelled consumers. A future request scheduler
  should prioritize explicit previews, track remaining consumers, and cancel obsolete work
  without breaking another viewer or an encrypted-file retry.

## Markdown reproduction on released 0.1.9

The earlier preview correction remained uncommitted in the preview-performance checkout and
was omitted from the 0.1.9 release integration. This branch carries it into the release line.
The title-bar correction shipped separately in #373; its older pending visual brief is superseded.
No visual or motion change is included here. Functional ownership remains with Codex; any future
visual changes remain subject to Claude Code review.

The user reproduced the same failure with a 46,709-byte ZIP containing 87 members and Markdown
entries of 828–5,932 bytes. Reading the Markdown bytes directly took less than one millisecond;
the installed 0.1.9 cache already contained the extracted files while Quick Look was stalled.
Logs showed repeated WebKit process crashes / launch failures. Private document contents and
absolute source paths are intentionally not included in this repository.

Two isolated QA copies of the installed 0.1.9 app used different bundle identities, no document
associations, extensions, App Group or broad debug filesystem exception. They had identical
code and differed only in the main app's network-client entitlement. With the same original ZIP
and 2,994-byte Markdown entry selected, the baseline was still spinning after 20.9 seconds.
The network-client variant displayed the actual formatted body during a 2.52-second
click-and-observe call. These are observation bounds, not precise renderer benchmarks.

## Validation

- Build succeeded; 34 targeted Swift Testing tests passed in five suites: thumbnail lifecycle,
  preview cache, Quick Look panel items, encrypted archives and updates.
- Added regression cases cover a stalled thumbnail provider, cancellation without a callback,
  late completion, successful completion, cancellation before starting, and cached files
  surviving eviction while Quick Look holds them and becoming evictable after close.
- Simplified Chinese check: 0 of 1,344 strings missing translations; no new user-facing strings.
- The release verifier's changed configuration/entitlement block rejects installed 0.1.8 for
  the missing entitlement and accepts the corrected build; shell syntax and plist parsing pass.
  A full signed/notarized package verification is not claimed.
- Native verification used AX activation/tree inspection and screenshots. It was not VoiceOver
  testing. This does not change the deferred scope or status of #93.

Apple API references: [thumbnail cancellation](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/cancel(_:)),
[thumbnail generation](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/generatebestrepresentation(for:completion:)),
[Quick Look panel](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel).
