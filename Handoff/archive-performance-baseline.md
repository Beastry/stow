# Sandboxed archive performance baseline (#329)

The opt-in test measures the app's sandboxed XPC engine. Packing includes gathering, creation
and publication. Listing measures the first and the immediate repeat after packing. The OS file
cache can already contain the archive on its first listing. Extraction includes sandbox
extraction, auditing, transfer, staging and publication. ZIP uses the balanced compression
level and one requested worker thread. The test verifies the selected payload and the published
file count and sizes before reporting measurements.

```sh
scripts/fetch-7zip.sh
xcodegen generate
TEST_RUNNER_STOW_ARCHIVE_BENCHMARK=1 xcodebuild -project Stow.xcodeproj -scheme Stow \
  -derivedDataPath /tmp/stow-archive-benchmark -parallel-testing-enabled NO \
  -only-testing:StowTests/ArchivePerformanceTests test
```

Search for `STOW_BENCHMARK` in the output. The test creates and removes its fixture and
output directories inside the test host's temporary storage. Each run uses deterministic
fixtures. The mixed corpus includes four 2 MiB high-entropy blobs and 16 small repetitive
vector-like text files. The same mixed corpus is packed as plain ZIP, password-protected ZIP
and three-part ZIP. The other corpus has 1,000 small text files.

One run on 2026-11-21 used a 10-core Apple M4 Mac mini with 16 GB memory, macOS 27.3,
and APFS SSD storage for the build and temporary data. The Stow debug app and bundled engine
were built from parent commit `27e8b0f` plus this benchmark. The engine used bundled 7-Zip
26.04 with Stow's decoder patch.

| Fixture | Files | Input bytes | Archive bytes | Pack ms | First list ms | Repeat list ms | Selected ms | All ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Mixed ZIP | 20 | 9,895,936 | 8,396,358 | 356 | 15 | 10 | 16 | 27 |
| Small files ZIP | 1,000 | 22,890 | 170,816 | 182 | 40 | 41 | 10 | 349 |
| Mixed encrypted ZIP | 20 | 9,895,936 | 8,397,358 | 221 | 13 | 11 | 17 | 33 |
| Mixed three-part ZIP | 20 | 9,895,936 | 8,396,358 | 251 | 19 | 18 | 29 | 36 |

The first packing run includes XPC service startup and verification. These are single-run
observations. Repeat the run before comparing timings across configurations.

Pending measurements include a true cold launch and open through first rendered contents,
peak memory, peak temporary allocation including count-based split staging, cancellation
latency, and Tray or cross-volume publication. The corpus still needs real video, image,
font, app bundle and design files. Candidate engines and compression policies will need
separate, paired measurements with the same corpora.
