# ArcZip 1.2.2–1.2.5 adoption assessment — 2026-11-18

Recommendation: prioritize search-state restoration, separate archives for multiple inputs,
and a complete import-conflict workflow. Add collapsible Finder previews next. Benchmark ZIP
performance and validate cloud output before changing engine or staging architecture.

## Evidence and baseline

- Read the live [official changelog](https://arczip.app/changelog/?lang=zh) on November 18,
  2026 (Pacific/Honolulu). The vendor lists 1.2.2 (349), November 6; 1.2.3 (366), November 9;
  1.2.4 (377), November 12; and 1.2.5 (384), November 13. Release dates use the vendor's
  displayed calendar; its publication timezone is unknown.
- Compared against upstream main **31a0a166facac350a3a1f938eb18375cbd0e882a**, confirmed by
  `git ls-remote origin refs/heads/main`. The active checkout is an older branch with unrelated
  working changes. Source inspection used an isolated `git archive` snapshot of main.
- Read current issue states, merged PR descriptions, source, tests and prior acceptance reports.
  No new native ArcZip/Stow interaction, benchmark, physical-volume test or VoiceOver test was
  performed. Vendor performance statements are not comparative Stow measurements. Source support
  does not establish installed-release acceptance.
- This updates the overlap with the [November 6 assessment](arczip-update-gap-assessment-2026-11-06.md).
  Its then-missing features must not be carried forward without rechecking main.
- The user subsequently authorized deciding and filing the roadmap scope on November 18.
  The disposition below records the resulting issues; approval is for planning, without an
  implementation assignment or delivery commitment. Codex / Grok Bot owns functional behavior,
  state, security, errors, cancellation, tests and accessibility semantics. Claude Code owns
  visual design and motion. No Claude review or implementation is claimed.

## Approved roadmap disposition

The existing [Stow Roadmap Project](https://github.com/orgs/Beastry/projects/1) remains the
single status/priority interface. All eight new issues start in Backlog, without assignees:

| Priority | Issue |
| --- | --- |
| P1 | [#365 — Search history restoration](https://github.com/Beastry/stow/issues/365) |
| P1 | [#366 — Separate archives per input](https://github.com/Beastry/stow/issues/366) |
| P1 | [#367 — Transactional import conflict handling](https://github.com/Beastry/stow/issues/367) |
| P1 | [#368 — iCloud output and destination-mutation validation](https://github.com/Beastry/stow/issues/368) |
| P2 | [#369 — Collapsible Finder Quick Look folders](https://github.com/Beastry/stow/issues/369) |
| P2 | [#370 — Independent Glance icon/list preference](https://github.com/Beastry/stow/issues/370) |
| P2 | [#371 — Ordinary naming for a lone size-split volume](https://github.com/Beastry/stow/issues/371) |
| P2 | [#372 — Reciprocal Shift Finder open override](https://github.com/Beastry/stow/issues/372) |

Existing #329 holds the expanded ZIP performance/content-aware packing and compatibility/JAR
corpus scope. #38 item 13 links the cloud-output subset to #368 without completing its checkbox.
#39 indexes the approved scope. The Project README and #39's obsolete environment-blocked exFAT
description are updated to retain current completion evidence. Completed count-based splitting,
Tray export and exFAT work are not duplicated. This disposition supersedes the recommendation-only
status of the original review; the source-inspection and native-validation limits still apply.

## Release themes

| Release | Relevant vendor additions and improvements |
| --- | --- |
| [1.2.2](https://arczip.app/changelog/?lang=zh#release-1-2-2-349) | Count-based volumes, Box Save To, compression tuning, exFAT repair. |
| [1.2.3](https://arczip.app/changelog/?lang=zh#release-1-2-3-366) | Parallel ZIP extraction, Shift open override, expandable Finder preview, filesystem/metadata compatibility. |
| [1.2.4](https://arczip.app/changelog/?lang=zh#release-1-2-4-377) | Separate archives per input, Mini icons, batch packing controls, temporary-output reliability. |
| [1.2.5](https://arczip.app/changelog/?lang=zh#release-1-2-5-384) | JAR editing, import conflicts, search history, split-output naming, installation/resource cleanup. |

## Recommended functional work

P1 means next functional wave; P2 means useful follow-up. Effort is relative scope, not a time
estimate: S = localized, M = several components, L = engine/lifecycle work. No new P0 defect was
reproduced in this review.

| Priority / effort | Capability | Current Stow evidence | Recommended observable outcome |
| --- | --- | --- | --- |
| **P1 / M** | Search navigation that preserves the task | `ContentViews.swift` already offers **Show in Enclosing Folder** in the context menu. `BrowserModel.Location` stores archive levels and folder only; `apply` clears the query. Back/Forward reconstruct selection from navigation instead of restoring the prior search selection and scroll state. | Search → reveal a match → Back restores query, selected match and reading position; Forward returns to the revealed folder. A direct reveal control is an optional discoverability improvement, not a missing underlying command. Preserve per-window ownership, nested-search behavior and cancellation; tolerate renamed/deleted entries when resolving saved state. |
| **P1 / M–L** | One archive per selected input | `PackController` runs one pack at a time; `PackRequest` and Quick Compress combine inputs into one output. The batch queue is for extraction. | Add an explicit separate-output mode using existing format/password/verification settings. Each input gets its own safe name and independent result. Support per-item cancellation/retry, and retain completed outputs when the batch stops. Start with a reliable queue; introduce bounded concurrency only with a shared CPU/memory/I/O budget. A fixed four-worker limit is not a Stow requirement. Keep the current combined-output default. |
| **P1 / M** | Unified same-name import decisions | `EditSession.add` auto-numbers conflicts and groups the addition for Undo; `replace` is a separate single-target command. This is partial coverage, not absence of replacement or Undo. | One batch prompt offers Replace / Keep Both / Cancel, with Keep Both as the safe default. Define folder replacement explicitly so stale descendants do not survive unintentionally; distinguish it from merging. Preflight the complete import, stage it transactionally, and make the accepted import one undoable operation. Preserve original archive bytes until Save. Change-marker color belongs to Claude Code. |
| **P2 / M** | Collapsible folders in Finder Quick Look | `ArchivePreviewModel` eagerly flattens all directories into at most 1,500 rows; `ArchivePreview` renders static rows without expansion state. | Expand/collapse without leaving the preview. Apply the visible-row limit after expansion so one deep subtree does not hide unrelated root entries. Reset state on archive changes, cancel stale loads, and preserve keyboard names/focus. Listing remains read-only; do not promise thumbnail support that this surface does not have. |
| **P2 / M** | Optional icon view in Glance | Ordinary archive contents use `GlanceList`; the authored DMG installer canvas is a separate existing surface. Glance has no independent icon/list default. | Offer list/icons only if it improves image-heavy quick browsing. Share selection/navigation/drag behavior with Browser while saving the Glance default independently. A temporary view switch must not change other windows or defaults. Keep Glance compact and keep the authored DMG experience intact. Claude Code chooses controls and composition. |
| **P2 / S** | Plain filename for one size-limited part | Creation forwards 7-Zip's produced filenames; there is no normalization of a lone `.001` in the inspected route. | If a size cap produces one part, consider publishing an ordinary `.zip`/`.7z`. Make displayed compatibility text, verification entry point, collision naming and aftercare membership agree. Keep explicit count-based output semantics separate, including tiny archives that yield fewer parts. |

Suggested order: search restoration → separate-output queue → import conflicts → collapsible
Quick Look. The two smaller view/naming improvements can follow concrete user demand.

## Validate and benchmark, rather than copy an implementation

**ZIP throughput and content-aware packing — extend [#329](https://github.com/Beastry/stow/issues/329).**
The inspected extraction path still uses the sandboxed 7-Zip engine and streamed, audited output;
no second native parallel ZIP extractor was found. Creation passes the selected compression plan
to 7-Zip rather than sampling content in Stow. Measure cold/warm open and extraction, selected
extraction, elapsed packing time, output size, peak memory, temporary disk use and cancellation
latency. Include many small files, apps/fonts, large stored media, mixed design files and split/
encrypted inputs. Only add a fast path after demonstrating a useful benefit with the existing
containment, filename, metadata, cancellation and rollback guarantees. A fallback must not
publish twice or silently reinterpret unsafe input. Do not infer the competitor's algorithm.

**iCloud output and destination mutation — focused P1 validation under #38/#329.**
Placeholder-download tests cover opening, not successful cloud output. Extraction currently
prefers staging inside the chosen destination; packing uses a replacement directory; edit saving
checks device identity and can use sibling staging. There is no uniform cloud-output policy in
the inspected paths. Validate save/extract/edit/Tray export with cloud-backed Desktop/Documents,
provider delays, cancellation, name collisions, hidden-state preservation and a destination that
changes during work. Do not move all staging outside the chosen location blindly: `Extraction`
documents a sandbox executable-provenance reason for destination-side staging. Any change must
retain runnable app/package output and honest cross-volume publication/rollback semantics.

**Compatibility corpus — extend existing coverage.**
Use targeted fixtures for sparse TAR entries, unsupported timestamps/modes, empty archives,
helper-only results, long names, old ZIP encodings, metadata/name collisions, destination aliases
and write-only directories. Separate payload failure from a nonessential attribute-restoration
warning. Retain original sources after incomplete output. These are validation opportunities;
a competitor fix is not evidence that Stow has the same defect.

## Already covered, partial, or deliberately different

- **Count-based ZIP/7Z volumes:** implemented by [#358](https://github.com/Beastry/stow/pull/358)
  / #322 with final-byte splitting and encrypted round-trip tests. Not a new backlog feature.
- **Tray Save To:** implemented by #315 and subsequently reviewed. Existing temporary results
  can be exported without rebuilding the collection. Do not duplicate the workflow.
- **exFAT:** common publication and physical acceptance are documented in the
  [repair report](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/Handoff/exfat-publication-repair-2026-11-07.md). Current main additionally includes
  [#363](https://github.com/Beastry/stow/pull/363), repairing consumed empty metadata reservations
  in installed Developer ID builds. Keep new edge cases in regression coverage; do not label
  exFAT support broadly missing or claim this review reran acceptance.
- **JAR:** registered already, and `EditableFormat` accepts actual ZIP listings without a `.jar`
  exclusion. Treat this as a compatibility/documentation task: verify add/replace/delete/rename,
  nested dependencies and duplicate directory records, preserve the JAR filename, and add a
  clear signed-JAR warning if absent. No dedicated JAR editing acceptance or signature-warning
  path was found. Do not promise re-signing or Java-reference repair, or call generic ZIP
  capability complete JAR acceptance.
- **Shift open override:** #328 already implements optional Finder quick extraction, with Shift
  forcing browsing while it is enabled. It does not invert the disabled setting into extraction.
  The reverse direction is a small optional improvement, with routing/help tests and disk-image/
  installer exceptions; it is not a wholly missing quick-extraction feature.
- **DMG/ISO resource cleanup:** Stow reads images without mounting, so there is no equivalent
  mount to detach. Audit engine/cache lifetime where useful; do not introduce mounts for parity.
- **Installing over a running app:** Stow explicitly refuses it. Keep that clear policy unless
  a separately justified workflow changes it. Profile large-app preparation and improve actual
  stage-specific errors without copying running-app replacement merely for parity.
- **Progress always-on-top switch:** ordinary packing/extraction progress is embedded in Stow's
  own surfaces. A new global floating progress window preference has little value here.
- **License recovery and numeric/selection animations:** licensing does not apply to free/open-
  source Stow. Visual/motion polish is Claude Code's area, subject to existing system preferences.

## Pinned implementation references

All links refer to the inspected main commit, rather than the older active checkout:

- [Search/history](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/App/Browser/BrowserModel.swift),
  [existing reveal command](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/App/Browser/ContentViews.swift).
- [Packing lifecycle](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/App/Pack/PackController.swift),
  [creation/splitting](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/Shared/SevenZip%2BCreate.swift).
- [Import/Undo](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/App/Browser/EditSession.swift),
  [editable-format guards](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/Shared/ArchiveEditing.swift).
- [Quick Look model](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/Preview/ArchivePreviewModel.swift),
  [Glance surface](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/App/Glance/GlanceView.swift).
- [Extraction/staging](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/App/Engine/Extraction.swift),
  [safe publication](https://github.com/Beastry/stow/blob/31a0a166facac350a3a1f938eb18375cbd0e882a/App/Engine/ExclusivePublication.swift).

No product code changed. No build or runtime tests were needed for this research-only addition.
New functional controls require Simplified Chinese translations and basic keyboard/focus support;
full VoiceOver acceptance remains deferred under AGENTS.md, and #93 remains open.
