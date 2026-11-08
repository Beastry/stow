# Physical exFAT verification — 2026-11-07

Status: **reproduced a placement failure; acceptance remains open**. Codex owns the functional investigation; Claude Code retains visual and motion ownership. No visual review is claimed.

## Volume and isolation

`diskutil info /Volumes/videos` identified external USB exFAT `disk10s2`, UUID `F99C8692-C138-3330-96BA-691D8F914791`, mounted read/write with 108.7 GB free. Recheck identity before any future write: device numbers and mount points may change. The user authorized this physical disk test. All writes were confined to the newly created `/Volumes/videos/Stow-317-test-20261107-44F36A2F-A1FC-46AA-A20A-29E60C703BDA`; no pre-existing volume content was changed. The directory was empty after testing. No format, repair, repartition, unmount or filesystem setting change was performed.

## Native Stow reproduction

A sandboxed debug Stow app opened `/tmp/Stow-317-fixture.zip` through the native Open panel. The small Finder-style ZIP was made with `ditto -c -k --sequesterRsrc --keepParent` from task-created files: `Docs/readme.txt` (`hello`), `Docs/.gitignore` (`hidden`), `Docs/.DS_Store` (`helper`), `Demo.app/Contents/Resources/desktop.ini` (`resource`), and `Thumbs.db` (`thumb`). SHA-256 of the source archive: `e99b014f8708ee8adc55dacfb0b2617b1a02f6f167edc195969c0bf3c0ade62c`.

Using Extract All, the native destination picker selected the task directory, granting the sandbox access. Stow displayed “There isn’t enough space on ‘videos’”, claiming zero bytes free for an 11-byte extraction. Copy Details recorded the underlying failure: `Couldn’t move “stow-317-fixture” into place: Operation not supported. [app.stow.engine 8]`. The destination was empty afterwards. This is AX inspection and activation, not VoiceOver testing. It proves a sandboxed native extraction attempt on the physical volume, not successful extraction or the rest of the acceptance matrix.

The test-host attempt without a native folder grant failed with Cocoa 513 / EPERM when creating the destination. Its subsequent modal picker was not exposed in the accessible test-host window and was interrupted; it produced no extraction result. Logs: `/tmp/stow-exfat-317-test.log` and `/tmp/stow-exfat-317-test3.log` (local, ephemeral).

## Filesystem and diagnosis

In the disposable directory, `renamex_np(..., RENAME_EXCL)` returned errno 45 (`ENOTSUP`) for both a regular file and a directory. Plain `rename` and `FileManager.moveItem` to an absent name succeeded for both. The latter observation does not prove race-safe no-clobber behavior. `Placement` uses exclusive rename for publication, and `TrayExport.copy` uses it too; Tray export was not exercised end to end on this volume.

Foundation reported `volumeAvailableCapacityForImportantUsage = 0` but `volumeAvailableCapacity = 108717539328`; the disk-full heuristic therefore masked the placement error. The accompanying change falls back to ordinary capacity when the important-usage value is zero or unavailable. Explicit ENOSPC remains authoritative. Focused `FailureTests` passed 12 tests; log `/tmp/stow-exfat-317-failure-tests.log`.

## Remaining work

A safe fallback must not use an existence check followed by plain rename: that can overwrite a racing writer. One possible design reserves a final file with exclusive creation or a directory with `mkdir`, copies only into the exclusively owned object, checks cancellation, and verifies object identity before rollback. Unlike rename, this exposes incomplete output during copy; crash cleanup, concurrent changes, metadata, symlinks, replacement and rollback failures require explicit design and tests. Do not claim atomic publication for such a fallback. An alternative filesystem-supported atomic exclusive primitive would be preferable if proven.

Repeat the full physical acceptance matrix after a safe implementation: exact bytes and source hash preservation, regular/Unicode/hidden paths, AppleDouble restoration, app resources, explicit helpers and selected folders, case/name conflicts, Keep Both/Skip, cancellation and staging cleanup, plus APFS-owned Tray export with conflicts and cancellation. Native UI, sandboxed engine, raw filesystem probes and VoiceOver are distinct evidence. Full build/test/localization checks are still required before integration.
