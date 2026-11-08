# Zstd-coded 7Z compatibility fixtures

Generated for #316 on 2026-11-06 from this synthetic UTF-8 payload:

```python
("Stow Zstd-in-7Z verification — 中文\n" * 500).encode()
```

The uncompressed file is `payload.txt`, 20,000 bytes, SHA-256
`478007740bc18d4c4194865ad9944f46e82904030c69fda4a5e20a9ff145926a`.
No user data or real password is included.

- `plain.7z` and `encrypted.7z`: py7zr 1.1.4 with `FILTER_ZSTD`, followed by
  `FILTER_CRYPTO_AES256_SHA256` for encryption and header encryption enabled.
  Synthetic password: `stow-fixture-only`.
- `delta-zstd.7z`, `split-zstd.7z.*`, `encrypted-split-zstd.7z.*`:
  [7-Zip-zstd](https://github.com/mcmilk/7-Zip-zstd/tree/bc1fb8a66d4ef549b6ac9bbc1bd660fecd2a572f)
  at `bc1fb8a66d4ef549b6ac9bbc1bd660fecd2a572f`, compiled locally for arm64 solely
  as an independent fixture producer. Creation flags respectively:
  `-m0=Delta:1 -m1=ZSTD`; `-m0=ZSTD -v100b`;
  `-m0=ZSTD -pfixture-only -mhe=on -v100b`.

Each producing implementation extracted its output and matched the payload exactly.
At the 2026-11-06 stock-engine baseline, official 7-Zip 26.04 listed all five cases with the
correct password but could not read/test/extract their payload (`Unsupported Method`, status 2).
PR #319 originally pinned that safe failure; its passing tests did not establish decoder parity.
The decoder acceptance below supersedes those expectations. The alternate fixture-producing
engine is not bundled with Stow.

## Decoder acceptance added for #316 — 2026-11-07

The known-gap text above records the stock 26.04 baseline. Stow now builds official 26.04
source with a small decoder-only registration patch; the test suite replaces safe-failure
expectations with exact-byte verification, preview and selected/all extraction acceptance.
No 7-Zip-zstd fork binary or Python package is shipped.

`scripts/make-zstd7z-fixtures.py` (Python 3.14+ `compression.zstd`, py7zr 1.1.4) rebuilds
these additional synthetic cases from the existing `plain.7z` seed:

- `solid-multifile.7z`: one Zstd folder, `payload.txt`, `nested/bytes.bin` (nine repetitions
  of bytes 0…255, 2,304 bytes), and empty `empty.txt`.
- `nonsolid-multifile.7z`: payload and binary in separate folders/blocks via py7zr append.
  Both multi-file archives were independently extracted by py7zr and compared exactly.
- `properties-current.7z` and `properties-legacy3.7z`: same compressed frame with current
  zero flags byte or legacy three-byte version/level metadata. Original seed has five bytes.
- `properties-unknown-flags.7z`, `properties-unknown-length.7z`: unsupported flags/length,
  intentionally rejected before decoding. Header CRCs are recalculated.
- `over-window.7z`: frame window descriptor changed to 1 GiB, valid/recomputed 7Z header.
  Rejected before window allocation by the registered decoder's 512 MiB per-window policy.
- `crc-mismatch.7z`: correct data frame, deliberately incorrect 7Z entry checksum.
- `truncated-stream.7z`: compressed frame shortened, with packed size and header CRC updated.
- `frame-checksum.7z` / `frame-checksum-mismatch.7z`: reference Zstd frame with checksum,
  and its corrupted final checksum byte; 7Z entry bytes/CRC remain unchanged.
- `cancellation.7z`: **2 GiB** of synthetic zeroes compressed to approximately 64 KiB. Used
  only for cancellation after engine progress starts; never fully extracted by the tests.
  The generator reads a temporary sparse file, and removes it afterwards.

Negative tests verify failure and no destination publication, never decoder acceptance.
No real credentials or user files are included. See the [implementation/evidence handoff](../../../Handoff/zstd-7z-decoder-316.md) for
resource bounds, source/license distribution and remaining release acceptance limits.

`SHA256SUMS` records every committed archive/volume's SHA-256 (verify from this directory
with `shasum -a 256 -c SHA256SUMS`). Regeneration may change producer timestamps in container
headers, so review/update the manifest after deliberately rebuilding fixtures. Payload byte
expectations stay fixed. Header rewrites recalculate the start-header CRC, next-header CRC,
packed sizes and offsets; negative failures target the intended coder/data rather than an
accidentally damaged outer header. The CRC-mismatch case changes the declared data CRC only.
