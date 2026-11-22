#!/bin/zsh
# Project artwork and OFL fonts, deterministic test-pattern video, and a generated arm64 app.
set -euo pipefail
cd "${0:a:h}/.."
corpus=Tests/Fixtures/BenchmarkCorpus
mkdir -p "$corpus/Media" "$corpus/Design" "$corpus/Apps/Benchmark.app/Contents/MacOS"
sample="Resources/Sample/Harbor Rebrand Handoff"
cp -R "$sample/Fonts" "$sample/Screens" "$sample/Specs" "$sample/Logo" "$corpus/Design/"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=1920x1080:rate=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 20 \
  -c:v libx264 -threads 2 -preset fast -b:v 16M -minrate 16M -maxrate 16M -bufsize 32M \
  -x264-params nal-hrd=cbr -pix_fmt yuv420p -c:a aac -b:a 192k "$corpus/Media/Clip.mp4"
cat > "$corpus/Apps/Benchmark.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>app.stow.BenchmarkFixture</string>
    <key>CFBundleExecutable</key><string>Benchmark</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
printf '%s\n' 'print("Stow benchmark fixture")' | \
  xcrun swiftc -O -target arm64-apple-macos26.0 - -o "$corpus/Apps/Benchmark.app/Contents/MacOS/Benchmark"
