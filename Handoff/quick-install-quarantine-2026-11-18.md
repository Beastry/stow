# Quick Install: preserve quarantine without app translocation

## Confirmed request and observed failure

The user requested removal of ChatGPT Classic and a fix for Quick Install after the installed
ChatGPT could not update. ChatGPT Classic was moved to the user's Trash, and its remaining
`ChatGPTHelper` process was terminated after verifying its executable belonged to that copy.
The matching `com.openai.chat-helper` launch service was disabled and unloaded.

The remaining `/Applications/ChatGPT.app` was version 26.1111.71025 (28661), bundle identifier
`com.openai.codex`. Its main process ran from `AppTranslocation/.../d/ChatGPT.app`. The mount
table identified `/Applications/ChatGPT.app` as the original source and the translocation mount
as read-only. This was an installed app, not a running copy inside its distribution DMG.
Its quarantine attribute was `00c1;00000000;Stow;...`. Sparkle refused its update check.

The installer restored download quarantine after final placement but did not record deliberate
installation. The regression reproduced in the sandboxed test host for initial placement,
replacement and Keep Both: installed apps retained quarantine without the run-in-place state.

## Functional contract and implementation

- Keep download quarantine and Gatekeeper's launch assessment by default. Do not fix this by
  deleting quarantine or manufacturing user approval.
- After an explicit app install finishes quarantine handling, use Apple's public
  `fcopyfile` API with `COPYFILE_RUN_IN_PLACE` on the installed bundle directory. This sets the
  system's do-not-translocate state while retaining quarantine. See Apple's
  [copyfile documentation](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3)
  and [implementation](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.c).
- Use a no-follow directory descriptor and no data, general xattr or stat copy flags. Bundle
  contents, signatures, unrelated metadata and final permissions remain intact.
- Apply the same finalization to initial installs, Replace and Keep Both, including a refused
  request to remove quarantine. Ordinary extraction retains its existing quarantine policy.
- Surface preparation failure as an installation finding with Finder move instructions.
  Force `copyfile` quarantine-write failures to report failure instead of ignoring them.
- Do not automatically quit the app being installed or the current ChatGPT session.

Codex / Grok Bot owns these installation and security behaviors. Claude Code owns any visual
or motion treatment of the existing findings presentation; no Claude Code review is claimed.
No visual composition changes are included. Full VoiceOver acceptance remains deferred under
the current milestone; the existing controls and accessibility semantics are unchanged.

## Validation and remaining boundary

The added sandbox regression failed before the fix and passed after it. Additional coverage
checks exact quarantine flag preservation apart from the system's run-in-place bit, quarantine
history, unrelated xattrs, permissions, code signatures, idempotence, symlink/missing-path
refusal, ordinary extraction and the optional quarantine-removal path.

Full `xcodebuild ... build test` passed: 574 tests, zero failures and zero skips, confirmed by
`scripts/ci-assert-tests.sh`. `scripts/check-localizations.sh zh-Hans` passed for all 1,069 strings.
`xcodegen generate` produced no tracked plist changes, and `git diff --check` passed.

The same helper was applied to the installed ChatGPT. Its quarantine flags changed from
`00c1` to `01c1`, retaining its existing approval bits and quarantine event identifier. The system
copy API normalized the recorded agent name when run from the standalone repair process.
`codesign --verify --strict /Applications/ChatGPT.app` passed afterward.

The current ChatGPT process still uses its existing translocation mount until the user quits
and relaunches `/Applications/ChatGPT.app`. A real ChatGPT update/relaunch and first-launch
Gatekeeper behavior on a clean account are not claimed as tested. The installed signed Stow
and registered Finder/Quick Look extensions are not replaced by the debug build.
