# Sandboxed archive performance baseline (#329)

The opt-in test measures the app's sandboxed XPC engine. Packing includes gathering, creation
and publication. Listing measures the first and the immediate repeat after packing. The OS file
cache can already contain the archive on its first listing. Extraction includes sandbox
extraction, auditing, transfer, staging and publication. ZIP uses the balanced compression
level and one requested worker thread. The test verifies the selected payload and the published
file count and sizes before reporting measurements.

```sh
scripts/fetch-7zip.sh
scripts/make-benchmark-corpus.sh
xcodegen generate
xcodebuild -project Stow.xcodeproj -scheme Stow \
  -derivedDataPath /tmp/stow-archive-benchmark -parallel-testing-enabled NO \
  -only-testing:StowTests/ArchivePerformanceTests \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG STOW_ARCHIVE_BENCHMARK' test
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

## Media, design, fonts, app bundle and cross-volume results

The benchmark now also uses the Harbor sample's published design assets and fonts, a generated
20-second 1080p H.264/AAC MP4, and a small generated Mach-O app bundle. The fixture script copies
project-owned assets and the existing sample fonts locally. It generates the video and app from
test inputs. The generated fixture directory is ignored. The harness compares every extracted
file's bytes with its source.

Run the corpus generator before generating the Xcode project. The generator requires FFmpeg
with libx264 and the macOS Swift toolchain.

```sh
scripts/fetch-7zip.sh
scripts/make-benchmark-corpus.sh
xcodegen generate
build=/private/tmp/Stow-329-build
xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG STOW_ARCHIVE_BENCHMARK' build-for-testing
scripts/sample-archive-benchmark.py --build "$build" \
  --staging "$HOME/Library/Containers/app.stow.Stow.Engine/Data/tmp/StowEngineStaging" \
  -- xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build" -parallel-testing-enabled NO \
  -only-testing:StowTests/ArchivePerformanceTests test-without-building
```

For cross-volume measurement, attach an APFS disk image at the test app's temporary directory
under StowBenchmarkVolume and create the marker .stow-benchmark-volume at its root. The test
checks that source and destination have distinct device IDs before running. This uses the real
Tray Collection and archive paths. The image is backed by the same physical SSD.

```sh
mountpoint="$HOME/Library/Containers/app.stow.Stow/Data/tmp/StowBenchmarkVolume"
mkdir -p "$mountpoint"
hdiutil create -size 128m -fs APFS -volname StowBenchmark /private/tmp/stow-329-benchmark.dmg
hdiutil attach -nobrowse -noautoopen -mountpoint "$mountpoint" /private/tmp/stow-329-benchmark.dmg
touch "$mountpoint/.stow-benchmark-volume"
# Run the same benchmark, then detach the image.
hdiutil detach "$mountpoint"
```

A run on 2026-11-21 used the Apple M4 Mac mini (Mac16,10, 16 GiB, macOS 27.3 build 26C5047e)
with an internal APFS SSD, the arm64 debug app from main ac9bdf3 plus the expanded benchmark,
bundled 7-Zip 26.04 with Stow's patch, and FFmpeg 9.0.2. Times are elapsed milliseconds.

| Fixture | Files | Input bytes | Archive bytes | Pack | First list | Repeat list | Selected | All |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Small files ZIP | 1,000 | 22,890 | 170,816 | 181 | 46 | 54 | 11 | 408 |
| H.264/AAC ZIP | 1 | 41,514,888 | 41,515,174 | 720 | 32 | 21 | 63 | 64 |
| Design and fonts ZIP | 17 | 2,275,218 | 2,129,113 | 69 | 11 | 9 | 15 | 27 |
| App bundle ZIP | 2 | 51,076 | 2,832 | 12 | 8 | 7 | 12 | 14 |
| Media, design, fonts and app, encrypted three-part ZIP | 20 | 43,841,182 | 43,649,211 | 867 | 49 | 39 | 42 | 115 |
| Small files ZIP on APFS image | 1,000 | 22,890 | 170,816 | 199 | 56 | 41 | 11 | 1,624 |

Across three successful runs, Tray Collect for 1,000 files took 111–116 ms on the source
volume and 1,427–1,528 ms on the image. Both paths copied the same files. The image also produced a macOS temporary-directory
permission diagnostic while the byte-verified archive workflows completed.

The sampler queries RSS in KiB for the app, XPC process and their descendants, including 7zz.
It samples allocated KiB for the engine staging root with du. Polling sleeps 25 ms between
measurements, plus the time to query processes and allocations. Combined RSS can count shared
pages more than once and short peaks may fall between samples. Engine staging measurements
cover the entire run and are sensitive to other engines using the same staging root.
Application-side temporary allocation and the incremental cost of count-based splitting
remain unmeasured. Cancellation measures from cancelling the active Pack task after its first
reported progress until it returns. The test also checks that no archive was published. Across
the three runs, sampled peak combined RSS was 346,512–440,880 KiB, sampled peak allocated
engine staging was 78,660–126,160 KiB from a zero-block baseline, and cancellation took 3–9 ms.

True cold launch through the first rendered listing, candidate engine comparisons,
and the remaining compatibility corpus entries are still open.

## Physical cross-device result

After building the opt-in harness, run
`scripts/check-archive-benchmark-volume.swift /Volumes/DataHouse /private/tmp/Stow-329-build`
from the checkout. The launcher creates a unique fixture directory on the specified volume
and passes its implicit bookmark to the sandboxed test host. The test validates its marker
and checks that its device ID differs from the source. After checking every copied and extracted
file against the original, the test removes its outputs. The launcher verifies that only the
marker remains, then removes the fixture directory.

One run on 2026-11-21 targeted the external DataHouse USB SSD formatted as APFS. The source
and benchmark build were on the Mac's internal PCIe APFS SSD. Tray Collect copied the 1,000
files in 221 ms. Packing the same 22,890-byte corpus took 185 ms and produced a 170,816-byte
ZIP. First and repeated listings took 43 ms each. Selected extraction took 12 ms and full
extraction took 290 ms. All payload and cleanup checks passed.

The source and newly written archive may be in macOS's file cache. The test performs regular
transactional publication and does not measure flushed-to-device durability or sustained
physical throughput. Whole-benchmark sampled peaks were 404,192 KiB combined RSS and
81,088 KiB allocated in engine staging. The sampler covers all phases, including preceding
local runs. It does not measure an isolated physical-device phase, app-side temporary
allocation, or filesystem-cache memory. Repeat this measurement before comparing devices.
