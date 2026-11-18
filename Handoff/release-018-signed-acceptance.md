# Stow 0.1.8: physical Shift and signed exFAT follow-up

Date: 2026-11-18 (Pacific/Honolulu). Apple silicon, macOS 27.3 (26C5035r).
Release acceptance is tracked in [#38](https://github.com/Beastry/stow/issues/38);
the exFAT defect and subsequent signed repair acceptance are tracked in
[#362](https://github.com/Beastry/stow/issues/362).

## Physical Shift

The Developer ID-signed, notarized candidate 0.1.8 (756), source `b7a57e1`, was
installed through Finder replacement at `/Applications/Stow.app`. Bundle,
signature, stapling, Gatekeeper and Universal 2 verification reported zero
problems. Both extension registrations pointed to that installation. This is
current-account installation evidence, not a clean-account or full extension
runtime acceptance pass.

The user held physical Shift while double-clicking a disposable local ZIP in
Finder. Warm opening showed that exact archive in Browser. After Stow was quit
and the process was confirmed absent, a second local ZIP opened in Browser with
a new process. Independent inspection confirmed unchanged source SHA-256 hashes
and no extracted directory in both cases.

For the cold test, a read-only diagnostic recorded only whether Shift was down,
using AppKit, combined session and hardware state. All three agreed: Shift was
down from 10:35:57.751 to 10:36:10.851 UTC; Finder's document event arrived at
10:35:59.800 UTC. The diagnostic was stopped after the test.

This establishes holding Shift until the archive Browser appears. It does not
establish an override when the key is released immediately after the Finder
gesture, before the cold-start document event arrives. An earlier exFAT attempt
entered extraction and showed the error below; its precise modifier-release
state was not recorded. That attempt is not evidence of a held-Shift defect.
The Shift routing implementation is unchanged by the exFAT repair.

## Signed exFAT defect

The same installed candidate failed ordinary Finder extraction of two small ZIPs
and explicit Browser Extract All of another ZIP on a physical USB exFAT volume.
EXT-199 named the output directory and its `._` companion as locations to review;
both were absent after rollback, and all source archives stayed unchanged.

Raw and sandboxed publication probes, isolated Debug and optimized Release QA
apps, and a local Apple Development-signed probe succeeded. A signed diagnostic
0.1.8 (757), source `d94aba6`, also succeeded through the documented command-line
real-extraction entry, including the exact native-failing fixture. Those results
did not establish an optimization-only or signature-only cause. Their outputs
contained system-added provenance metadata.

Installing the signed diagnostic and reproducing through Finder located the
failure immediately after paired-output creation and its first `fsync`:
`fstatat` could no longer observe the initially empty companion reservation and
returned `ENOENT`. Publication refused this state before copying payload bytes.
The temporary diagnostic code is excluded from the repair branch.

The repair records whether this initial reservation was consumed. A companion
that was initially observed must remain unchanged; a consumed companion must
remain absent until Stow's metadata copy. An unexpected companion causes refusal
and conservative rollback. Initial exclusive reservation still refuses existing
companions. Metadata copy and byte-for-byte source-attribute verification remain
in place, and generated companions are still recorded for rollback.

Regression coverage exercises actual exclusive copying with a simulated
filesystem consumption boundary: files and nested directories, metadata and
source preservation, rollback, cancellation, pre-existing companion collisions,
and a foreign companion appearing after the expected absence. Physical signed
artifact results are recorded in #362 for the exact build used.

## Scope and cleanup

All drive writes are confined to new task directories, after verifying the USB
volume's identity. Original archive hashes and output bytes are independently
checked. Local manifests, modifier intervals, native event logs, diagnostic
artifacts and verification reports are retained in ignored
`build/release-018-acceptance/`. Test grants, recents, applications and files are
removed after acceptance while preserving the user's prior settings and grants.

Codex owns functional correctness, recovery, security and tests. Claude Code
retains visual design and motion ownership; no redesign or new visual approval
is claimed. This is human-assisted physical input plus CUA/AX-assisted functional
testing, not VoiceOver testing. #93 remains deferred; the wider matrix in #38,
including clean-account and hardware/environment coverage, is not completed by
these bounded checks.
