# Tray, creation and entry points — 2026-11-04

**Historical brief, archived 2026-11-18.** Current implementation and later user decisions are
recorded in [DESIGN.md](../DESIGN.md) and the [current handoff](ui-motion-claude-code.md).
The dated observations and proposals below are retained as evidence; they do not override those
current documents or establish present implementation status.

Published plan: [#286](https://github.com/Beastry/stow/issues/286).

## Outcome and scope
Research and implementation plan requested by the user on **2026-11-04 (Pacific/Honolulu)**. This issue coordinates eight bounded tasks: reliable Tray dismissal, a master switch, optional residency, a status menu, Welcome entry points, a real new-archive draft workflow, production sample packaging, and an explicit Search close control. This is a plan and native comparison, not an implementation/release claim.

## Confirmed direction versus recommendations
**Confirmed by the user:** investigate the intermittent two-click Tray dismissal; add a Tray master switch while retaining outside-click/application-switch dismissal **without an idle timer**; compare ArcZip's lifecycle and Box; plan a clean Tray mode and routes to full UI; improve Welcome creation/Settings entry points; remove production sample payloads in favor of on-demand access; compare actual creation workflows; add a visible Search close button.

**Implementation recommendations from this research:** use the existing app process with explicit normal/Tray-only lifecycle states before considering a separate helper; exit when Tray is disabled and all work/windows are safely finished; new installs opt into Tray while existing installs retain availability; use an editable new-archive draft for New/Create while retaining quick Pack for gathered inputs; initially offer the sample via an explicit browser download to preserve the main app's no-network boundary. These are implementation briefs, not claims that the user approved every default or visual composition. Claude Code may replace presentation proposals while preserving functional contracts.

## Evidence baseline and correction
- Installed **Stow 0.1.4 (611)** and **ArcZip 1.2.1 (336)**; source audited at main `33d533e7a74c0f6c862ce49a8d0fc72e93a71e90`.
- The task's initial checkout `3e7d998` was behind release. Its 30-second timer code was not current. The initial diagnosis based on that checkout is explicitly superseded: [#283](https://github.com/Beastry/stow/issues/283)/#284 already implemented outside dismissal and retired idle timing. The reported two-click defect is a follow-up, not proof that dismissal is absent.
- Native observations used CUA/AX and read-only process/window inspection. They are not VoiceOver testing. An attempted cross-app desktop click failed with `noWindowsAvailable`; no successful reproduction or fixed root cause is claimed for the two-click defect.

## ArcZip comparison
| Area | Observed reference | Stow consequence |
| --- | --- | --- |
| Box settings | Dedicated ArcZip Box page; Enable ArcZip Box on; inactivity range 1–6 seconds, current value 3; help says pin keeps open and dragging/processing pause countdown | Add master enable and dedicated settings; user explicitly chose **not** to copy the timer |
| Last window close with Box enabled | File > Close removed main window; **same PID 90367** changed activation policy from regular (0) to accessory (1), remained running, and was reused when reopening UI. Archive XPC PID 90370 remained at later snapshot | Box-only appearance is not process exit. No evidence of a replacement standalone Box app; implement optional Tray-only presentation first |
| Box disabled lifecycle | Not tested in this run | Do not describe disabled-Box termination as verified reference behavior |
| Welcome | Open Archive, Create Archive and Settings controls activated/inspected | Expose actual work and Settings; sample is secondary |
| Create Archive | Opens empty Untitled Archive.zip draft. Add Files stages a task-owned text file; Save opens configuration with name/destination/purpose/format/compression/password/advanced options. Cancelling returns to populated draft; closing asks Save/Discard/Cancel | Existing quick Pack is insufficient as the complete new-archive experience; add a draft workflow sharing packing internals |
| Stow quick Pack | Command-N → source chooser → Pack sentence/options → destination chooser. Cancelling destination retains Pack choices; cancelling Pack returns to Welcome | Keep quick Pack for existing collections, improve New/Create separately |
| Search close | User screenshot shows trailing ×. Native ArcZip Close Search collapses an empty expanded field to the magnifier; query entry is Pro-gated in this installation | Explicit close is distinct from Stow's current query-clear/refocus action |
| Sample payload | Installed Stow ~45 MiB; Sample folder ~6.8 MiB, including ~3.3 MiB ZIP plus expanded assets | Remove production sample assets; measure final packaged savings separately |

Only an agent-created 37-byte fixture was added to the test draft; it was discarded without saving. No user archive was edited. No final compression, ArcZip protected-option verification, new physical drag acceptance or resource-performance benchmark is claimed. No application/extension installation or preference changes were made in this research. ArcZip's earlier [#282](https://github.com/Beastry/stow/issues/282) reference observations remain historical evidence, not updated timing measurements here.

## Delivery order and owners
1. **Codex / Grok Bot:** diagnose and fix the outside-click defect independently; do not mask it with timing or remove owned-surface protection.
2. **Codex / Grok Bot**, with **Claude Code** settings treatment: define the Tray master preference/migration, then lifecycle and menu routes. Menu scaffolding can proceed in parallel but must integrate with the same lifecycle coordinator.
3. **Codex / Grok Bot:** implement draft model/security/packing integration. **Claude Code:** design empty/populated draft and creation configuration, then Welcome entry presentation. Welcome Create must land with a valid draft route, not a temporary contradictory New command.
4. **Codex / Grok Bot** handles production sample resource separation/browser routing; coordinate asset publication with the existing release collaborator. **Claude Code** handles secondary-entry copy. Existing [#69](https://github.com/Beastry/stow/issues/69) remains media production, not this packaging implementation.
5. Search close is an independent small functional control by **Codex / Grok Bot**, followed by **Claude Code** visual/motion review.

No unknown GitHub user is assigned, and publishing this task allocation does not dispatch an agent session or claim work has started. Functional owners preserve security, cancellation, errors, tests and accessibility semantics; Claude Code owns all visual design/motion. Dedicated VoiceOver acceptance stays deferred under [#93](https://github.com/Beastry/stow/issues/93). Native signed integration checks remain in [#38](https://github.com/Beastry/stow/issues/38); release ownership stays in [#32](https://github.com/Beastry/stow/issues/32).

## Current direction and historical work
The outside-click/Keep Open contract from [#282](https://github.com/Beastry/stow/issues/282)/#283 remains current. The user reconfirmed no idle timer in this chat. [#282](https://github.com/Beastry/stow/issues/282) stays closed; new defects belong in the new dismissal issue. [#153](https://github.com/Beastry/stow/issues/153)'s existing Pack implementation remains useful and completed; the draft workflow adds capability rather than declaring that prior work nonexistent. [#242](https://github.com/Beastry/stow/issues/242)'s trailing toolbar and leftward search expansion remain current. Welcome's primary Try the Sample placement and production bundling are superseded by the new tasks; the sample must still be a genuine ZIP, preserving [#91](https://github.com/Beastry/stow/issues/91)'s integrity intent.

Architecture references: Apple's [last-window termination delegate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminateafterlastwindowclosed(_:)) still invokes the normal termination decision and can be called while NSPanel instances remain; [activation policy](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum) controls app presentation; [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) handles login registration separately. Do not equate absence of a Dock icon with absence of a process or automatic resource reduction.

## Work packages
| Task | Primary functional owner | Visual/motion owner | Order |
| --- | --- | --- | --- |
| [#287](https://github.com/Beastry/stow/issues/287) — One-click outside dismissal | Codex / Grok Bot | Claude Code if motion changes | First; independent defect |
| [#288](https://github.com/Beastry/stow/issues/288) — Master switch and dedicated Tray settings | Codex / Grok Bot | Claude Code | Before residency integration |
| [#289](https://github.com/Beastry/stow/issues/289) — Optional residency and full-UI lifecycle | Codex / Grok Bot | Claude Code for affected UI | After master setting |
| [#290](https://github.com/Beastry/stow/issues/290) — Status-item context menu | Codex / Grok Bot | Claude Code | Integrate settings/lifecycle/create routes |
| [#291](https://github.com/Beastry/stow/issues/291) — Welcome Create/Settings entry points | Codex / Grok Bot routing; Claude Code design lead | Claude Code | Design now; Create ships with draft route |
| [#292](https://github.com/Beastry/stow/issues/292) — Release sample removal and explicit download | Codex / Grok Bot; release collaborator for asset hosting | Claude Code for copy | Independent packaging work |
| [#293](https://github.com/Beastry/stow/issues/293) — Editable new-archive draft workflow | Codex / Grok Bot | Claude Code | Before shared New/Create entry points |
| [#294](https://github.com/Beastry/stow/issues/294) — Explicit Close Search | Codex / Grok Bot | Claude Code | Independent small improvement |

Each task contains its own observable acceptance criteria and links back here. No automatic implementation or release is dispatched by these issues.
