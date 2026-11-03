#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Xcode build phase: no network access, one static archive for the current platform/architectures.
set -euo pipefail
project_root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
mupdf_source="$project_root/Vendor/mupdf"
if [[ "$project_root" == *[[:space:]]* ]]; then
  echo 'error: MuPDF Makefiles require this checkout path to contain no whitespace.' >&2
  exit 1
fi
expected=da5f5eb890d7b3fb76903160b5f7f48ba1301492
if [[ ! -d "$mupdf_source/include" ]] || [[ "$(git -C "$mupdf_source" rev-parse HEAD)" != "$expected" ]]; then
  echo 'error: MuPDF sources missing or incorrect. Run bash scripts/fetch-mupdf.sh first.' >&2
  exit 1
fi
if [[ ! -f "$project_root/PaperStudio/Legal/MuPDFNotices/manifest.json" ]]; then
  echo 'error: MuPDF legal notices missing. Run bash scripts/fetch-mupdf.sh first.' >&2
  exit 1
fi
case "${PLATFORM_NAME:-}" in
  iphoneos) sdk=iphoneos; suffix="" ;;
  iphonesimulator) sdk=iphonesimulator; suffix=-simulator ;;
  *) echo 'error: This build phase supports iOS device and simulator only.' >&2; exit 1 ;;
esac
sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
minimum="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
build_root="$project_root/build/mupdf/$sdk"
destination="${BUILT_PRODUCTS_DIR:?}/MuPDF"
mkdir -p "$destination"
archives=()
for architecture in ${ARCHS:?}; do
  case "$architecture" in arm64|x86_64) ;; *) echo "error: Unsupported architecture $architecture" >&2; exit 1 ;; esac
  slice="$build_root/$architecture"
  target="$architecture-apple-ios$minimum$suffix"
  flags="-target $target -isysroot \"$sdk_path\" -fPIC"
  signature="$(printf '%s\n' "$expected" "$flags" "$(xcrun --sdk "$sdk" clang --version)" 'mujs=no' | shasum -a 256 | cut -d ' ' -f 1)"
  if [[ -d "$slice" && ( ! -f "$slice/.build-signature" || "$(cat "$slice/.build-signature")" != "$signature" ) ]]; then
    # This directory contains only this script's generated per-architecture objects.
    rm -rf "$slice"
  fi
  mkdir -p "$slice"
  # Never use host/Homebrew libraries in an iOS cross compilation.
  make -C "$mupdf_source" -j3 OUT="$slice" OS=Darwin build=release \
    CC="xcrun --sdk $sdk clang" CXX="xcrun --sdk $sdk clang++" \
    AR="xcrun --sdk $sdk ar" RANLIB="xcrun --sdk $sdk ranlib" \
    HAVE_LIBCRYPTO=no HAVE_GLUT=no HAVE_X11=no HAVE_CURL=no USE_SYSTEM_CURL=no \
    USE_SYSTEM_LIBS=no USE_TESSERACT=no USE_ZXINGCPP=no mujs=no \
    XCFLAGS="$flags" libs
  xcrun libtool -static -o "$slice/libPaperMuPDF.a" "$slice/libmupdf.a" "$slice/libmupdf-third.a"
  printf '%s\n' "$signature" > "$slice/.build-signature"
  archives+=("$slice/libPaperMuPDF.a")
done
if [[ ${#archives[@]} == 1 ]]; then
  cp "${archives[0]}" "$destination/libPaperMuPDF.a"
else
  xcrun lipo -create "${archives[@]}" -output "$destination/libPaperMuPDF.a"
fi
