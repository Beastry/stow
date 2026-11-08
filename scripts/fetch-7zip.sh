#!/bin/zsh
# Builds official pinned 7-Zip + Stow's bounded, decoder-only Zstd-in-7Z registration.
# The separate LGPL executable, license and complete corresponding source ship in the XPC.
set -euo pipefail
cd "${0:a:h}/.."

version=26.04
archive=7z2604-src.tar.xz
sha256=9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6
url=https://github.com/ip7z/7zip/releases/download/$version/$archive
patch=scripts/patches/7zip/zstd-7z-decoder.patch
# Recipe and patch changes invalidate both local reuse and CI caches.
recipe=$(cat scripts/fetch-7zip.sh scripts/build-7zip-source.sh "$patch" | shasum -a 256 | cut -d' ' -f1)
dest=Vendor/7zip
if [[ -x $dest/7zz && -f $dest/7-Zip-Stow-Source.tar.xz && "$(cat $dest/VERSION 2>/dev/null)" == "$version-$recipe" ]]; then
  echo "7-Zip $version + Stow decoder already in $dest"; exit 0
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
curl --fail --location --silent --show-error --output "$work/$archive" "$url"
echo "$sha256  $work/$archive" | shasum -a 256 --check --status \
  || { echo "error: checksum mismatch for $archive" >&2; exit 1; }
mkdir -p "$work/source" "$work/output"
tar -xJf "$work/$archive" -C "$work/source"
chmod -R u+w "$work/source"
# The official release uses CRLF. Normalize only the patched files before applying.
for file in C/7zVersion.h C/ZstdDec.h C/ZstdDec.c CPP/7zip/Compress/ZstdDecoder.h CPP/7zip/Compress/ZstdDecoder.cpp; do
  perl -pi -e 's/\r$//' "$work/source/$file"
done
patch -d "$work/source" -p1 < "$patch"
# Keep source distribution complete and marked as modified, including the build recipe/patch.
cp scripts/fetch-7zip.sh "$patch" "$work/source/"
cp scripts/build-7zip-source.sh "$work/source/build-stow-7zip.sh"
cat > "$work/source/STOW-MODIFICATIONS.txt" <<EOF
Stow modification, 2026-11-07, official 7-Zip $version source SHA-256 $sha256.
Decoder-only 7Z method 04F71101 registration, known property lengths, 512 MiB window cap.
Standalone .zst decoding is unchanged. No Zstd 7Z encoder is provided.
Offline rebuild on macOS with Xcode command line tools: zsh ./build-stow-7zip.sh
This builds both slices and writes ./7zz. It requires no network or Stow repository.
The included patch documents all source edits. Archive excludes generated objects only.
fetch-7zip.sh records provenance but is the repository download/patch wrapper, not the offline recipe.
EOF
# Archive before building so no generated objects are included.
tar -cJf "$work/output/7-Zip-Stow-Source.tar.xz" -C "$work/source" .
cp "$work/source/DOC/License.txt" "$work/output/License.txt"
if ! scripts/build-7zip-source.sh "$work/source" "$work/output/7zz" > "$work/build.log" 2>&1; then
  tail -80 "$work/build.log" >&2
  exit 1
fi
archs=$(lipo -archs "$work/output/7zz")
echo "$version-$recipe" > "$work/output/VERSION"
# Do not destroy a working engine until the complete replacement has built successfully.
mkdir -p "$dest"
cp "$work/output/"* "$dest/"
echo "7-Zip $version + Stow decoder → $dest/7zz ($archs)"
