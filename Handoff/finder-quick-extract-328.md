# Finder quick extraction: native follow-up for #328

Date: 2026-11-17 (Pacific/Honolulu). macOS 27.3 (26C5035r), Apple silicon.

## Build and scope

The initial pass used source `a704dd5` (the tree merged by #359). The correction below
is based on main `5bb4a06`. Both were exercised as an isolated, sandboxed, ad-hoc
`Stow QA328.app` (`app.stow.QuickExtractQA328`). Its Finder/Quick Look plugins and
URL-scheme declaration were removed; updates stayed disabled. The installed,
Developer ID-signed Stow 0.1.7 (715) predates this feature and was not replaced.

Only task-created fixtures in one local APFS directory and one directory on a
physical USB exFAT drive were used. Finder's Get Info selected the QA application
for a disposable file; that file-specific association was copied to the other
fixtures. No Change All action or global default-handler change was made.

Finder item opens used CUA's `clickCount: 2`; Open With was selected in Finder's
context/File menu. These were actual Finder document events, not `open -a`, a
sender override, or a call to the application's debug extraction scene. OSLog
recorded `Open from com.apple.finder`, followed by quick extraction. The cold-start
case began with no QA process and launched a new process through Finder.

These are CUA/AX-assisted native checks, not human physical-input or VoiceOver
acceptance. Their limits are recorded below.

## Completed checks

| Case | Observed result |
| --- | --- |
| Fresh settings, quick extraction off | Finder opens the ZIP in Browser; no extracted directory |
| Quick extraction on, Finder item open | Extracts beside the ZIP on APFS and physical exFAT; Finder selects the output |
| Finder Open With | The same quick-extraction behavior on APFS and exFAT |
| First destination authorization | The panel names the task directory; Cancel leaves no output and the original unchanged; allowing that directory permits retry |
| Cold start on exFAT | A new QA process receives Finder's event and extracts using the remembered task-directory grant |
| Explicit Open Archive | Browses an exFAT ZIP while quick extraction is enabled; no output |
| Finder opens an archive already in Browser | Returns to that Browser session; no output |
| DMG exception | Finder opens the fixture in Browser while quick extraction is enabled; no extraction or installation |

## Defect found and corrected

With Same-name folder set to Ask, repeating a Finder extraction silently produced
a numbered directory. `SystemActions.extract` passed `Extraction.run` its default
options, bypassing the configured conflict policy and other extraction settings.
This also affected the existing Finder/Services extraction routes.

The request now snapshots `Extraction.Options.current` with one `ConflictPolicy`
shared across its archives, matching the queue's conflict-answer lifetime. It
uses the existing prompt and placement implementation; no visual treatment changed.

Native checks of the corrected build on the physical exFAT drive:

- Ask displays the existing folder-conflict prompt.
- Stop leaves the original sentinel intact, creates no numbered output, and
  removes staging.
- Keep Both produces the correctly numbered directory with exact payload bytes;
  the original sentinel stays intact.
- A single Finder request containing two colliding ZIPs prompts once when
  Do the same for other folders is selected. Both numbered outputs contain the
  exact expected bytes, and both original directories remain unchanged.

Independent verification checked all 21 fixture archive hashes, all five original
sentinels, and all payload bytes in eleven output directories. Three of those
directories came from diagnostic Shift attempts and are **not** Shift acceptance.
The other eight are successful extraction/placement cases. Browse-only controls
created no output, and no staging directories remained.

The corrected source passed 926 tests with zero failures or skips, all 1,344 strings
have Simplified Chinese translations, and generated plists were unchanged.

## Remaining acceptance and cleanup

- **Physical Shift override remains unverified.** CUA combination attempts produced
  extraction, but did not establish that the OS modifier state stayed active until
  the document event arrived. A modifier-only hold was rejected by the tool. No
  Shift pass or product failure is inferred from those attempts. The routing unit
  tests pass; physical input, including cold-launch key-release timing, remains #38.
- Current signed/notarized release installation, registered extension handoff,
  Quick Look, and clean-account acceptance remain #38/#32. The isolated QA pass
  does not establish those results.
- Finder extraction still has no general in-progress cancel control; that existing
  gap is distinct from the tested authorization Cancel and conflict Stop paths.
- Dedicated VoiceOver acceptance remains deferred under #93.

Both QA folder grants were forgotten, quick extraction was switched off in the QA
preferences, and the QA application was quit. Task-owned fixture/output directories
and the QA app are removed after integrity verification; production settings and
the installed application are preserved. Local manifests and diagnostic logs remain
under the ignored `build/native-328/` directory.

Codex owns the functional correction, integrity checks and state review. Claude
Code retains visual design and motion ownership; no new visual approval is claimed.
