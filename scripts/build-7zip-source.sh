#!/bin/zsh
# Offline build of the already-patched corresponding source distributed with Stow.
# In the source archive this script is named build-stow-7zip.sh and needs no arguments.
set -euo pipefail
source_root=${1:-${0:a:h}}
output=${2:-$source_root/7zz}
for arch in arm64 x64; do
  (
    cd "$source_root/CPP/7zip/Bundles/Alone2"
    MACOSX_DEPLOYMENT_TARGET=14.0 make -f "../../../../C/var_mac_${arch}.mak" -f makefile.gcc -j8
  )
done
lipo -create "$source_root/CPP/7zip/Bundles/Alone2/b/m_arm64/7zz" \
  "$source_root/CPP/7zip/Bundles/Alone2/b/m_x64/7zz" -output "$output"
archs=$(lipo -archs "$output")
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] \
  || { echo "error: 7zz is not universal (has: $archs)" >&2; exit 1; }
chmod 755 "$output"
