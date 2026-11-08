# exFAT publication repair and physical acceptance

Status: implemented and physical acceptance passed on 2026-11-07 (Pacific/Honolulu). This supersedes the diagnostics-only scope in the [initial physical investigation](exfat-physical-verification-2026-11-07.md). The user subsequently authorized implementation with GPT-6.1 Sol subagents. Codex owns functional correctness, security, recovery and tests; Claude Code retains visual/motion ownership. No visual review or VoiceOver acceptance is claimed.

## Behavior

`ExclusivePublication` keeps exclusive rename as the fast path. Only `ENOTSUP` or cross-volume publication falls back to bounded copying with exclusive file/directory creation. Compatibility copying is limited to exFAT, APFS and HFS; unknown filesystems fail before creating output. It never uses an existence check followed by an overwriting rename.

The compatibility copy is **not atomic**: incomplete destination output is temporarily visible, and an app/process crash can leave it behind. Staging remains intact until the caller commits/disposes of it. Live cancellation/error rolls back only owned, unchanged objects, preserves foreign or modified output, and reports retained paths. POSIX has no inode-conditional unlink, so a malicious writer racing the final identity check/unlink is not absolutely excluded. Do not describe this as a guarantee against arbitrary concurrent hostile writers.

FSKit automatically generates AppleDouble companions. The publisher exclusively reserves destination companions, verifies file attributes byte-for-byte, and records the generated companions for recovery. It interprets a source companion only on exFAT after strict structural validation and corroboration with the paired file's live attributes. Unknown/malformed payloads remain literal files or fail safely on an unavoidable collision; there is no prefix-only suppression. Explicit root `._` selections copy their bytes. Symlinks and unrepresentable metadata fail safely on the copy path; native rename retains its existing symlink behavior.

Extraction placement, Tray collection/export and new archive/DMG placement use the common publisher. Split parts commit together; failure restores earlier parts and Trash backups. Replace requires a working Trash, so the original never moves into disposable staging. If Trash is unavailable, replacement fails without modifying the original. Restoring a Trash item opens its parent for search only, avoiding a sandbox-denied enumeration of the entire Trash. A restoration copy deliberately keeps the backup in Trash. Stop help now describes cleanup without promising unconditional deletion. All retained locations from publication and subsequent cleanup/restoration are combined in the visible error, with Simplified Chinese translations.

## Physical device and method

The authorized external USB SSD at `/Volumes/videos` was reverified as exFAT/FSKit with volume UUID `F99C8692-C138-3330-96BA-691D8F914791` before writes. Device numbering was `disk10s2`; future tests must reverify identity. The sandboxed test-host matrix used only the newly created `Stow-317-acceptance-f4b9bc77-6e75-46d5-8b41-eeb44b3c75ea` directory and task-created fixtures. Replacement exercised the system Trash for those synthetic originals. No pre-existing user file was changed, and no format, repair, repartition, unmount, or filesystem setting change was performed. Installed Stow and its registered extensions were left in place.

An opt-in local test displayed its own native window and `NSOpenPanel`. Computer Use selected only the disposable directory, granting the sandbox access. The test then called the production `ArchiveEngine`, `Extraction`, `Placement`, `TrayExport` and `ArchiveCreation` APIs. This is sandboxed production-path acceptance with native folder authorization, distinct from clicking every regular UI command. The manual test is excluded from the default suite; CI does not skip a physical test or assume an attached SSD. AX inspection/activation is not VoiceOver testing.

A separate ordinary-app smoke test opened the original `/tmp/Stow-317-fixture.zip`, clicked **Extract All**, and selected the disposable SSD folder through the native picker. Stow returned to its ready state with no failure; host verification confirmed `readme.txt` = `hello`, `.gitignore` = `hidden`, no staging folder, and the unchanged original archive SHA-256 `e99b014f8708ee8adc55dacfb0b2617b1a02f6f167edc195969c0bf3c0ade62c`.

The synthetic ZIP contained ordinary and Unicode paths, `.gitignore`, `.DS_Store`, `Thumbs.db`, an app resource, a package `desktop.ini`, and an AppleDouble record with a custom attribute and 32 KiB resource fork. The final run's source SHA-256 was `61f1adbc64456147dccfbf6918f620a390001f87f3a07c5530bbea287901bc4d`, checked unchanged after extraction. Packed OS metadata can make fixture bytes differ across regenerated runs.

| Physical check | Observed result |
| --- | --- |
| Default extraction | Exact bytes for ordinary/Unicode/hidden paths and app resources; copy fallback used |
| Mac metadata | Custom xattr and 32 KiB resource fork match exactly |
| Helper policy | Defaults filter helper names; explicit helper selections retain bytes; disabling filtering preserves package `desktop.ini` |
| Selected folder | Folder contents and explicitly selected helper descendants survive |
| Keep Both / Skip / Replace | Correct results; existing copies preserved or retained in Trash as appropriate |
| Case collision | Existing `CASE.TXT` preserved; new `case.txt` numbered to `case 2.txt` |
| Tray APFS to exFAT | Exact bytes, metadata-bearing tree, numbered conflicts and original preservation |
| Cancellation | Mid-copy Tray export removes owned partial output; multi-item placement removes earlier output; canceled replacement restores original bytes from Trash |
| Split archive creation | Sandboxed compression, verification and publication produce four ZIP volumes successfully |
| Staging/source preservation | No extraction staging remains; source archive and Tray payload unchanged |

The physical matrix passed. A preceding harness attempt failed only while recursively deleting the final exported app tree with sandboxed `FileManager.removeItem` (Cocoa 513 / EPERM). All product-path assertions had passed; this is recorded rather than counted as product cleanup acceptance. The same host-side Foundation cleanup succeeded. Final outputs were deliberately retained for host inspection and then removed only within the known disposable root. Successful staging cleanup and owned-output rollback were separately asserted. Private staging disposal after an already committed success remains best effort; do not claim crash cleanup or universal deletion support.

## Regression coverage and evidence

The normal suite adds 15 publisher tests and 10 caller test methods (18 caller parameter cases): metadata, explicit helpers, malformed AppleDouble, exclusive collisions, bounded cancellation, modified/foreign outputs, conflict choices, replacement restoration, split-part rollback, and simultaneous destination/staging cleanup failures. Raw physical probes also cover orphan companions and replacement of a companion during copying; both the foreign companion and paired file are retained/reported.

Local evidence is preserved under `build/review-evidence/317/`: `PhysicalExfatAcceptanceTests.swift`, `stow-317-physical-final.log`, `exfat-final-race-probe.swift`, and `stow-317-helper-physical.log`. These are local artifacts, not default test sources. The complete local suite passed **796 tests in 117 suites**, with zero failures/skips; the opt-in physical test passed separately. Simplified Chinese coverage passed with no missing translations. The CI minimum is raised to 796. The earlier zero-capacity diagnostic repair remains in #341. Full VoiceOver and dedicated screen-reader refinement remain deferred under #93.
