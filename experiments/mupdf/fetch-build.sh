#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
study_dir="$(cd "$(dirname "$0")" && pwd)"
mupdf_source="${MUPDF_STUDY_SOURCE:-/tmp/paperstudio-mupdf-study/mupdf}"
mupdf_commit=da5f5eb890d7b3fb76903160b5f7f48ba1301492
if [[ ! -e "$mupdf_source" ]]; then
  mkdir -p "$(dirname "$mupdf_source")"
  git clone --depth 1 --branch 1.28.6 https://github.com/ArtifexSoftware/mupdf.git "$mupdf_source"
fi
actual=$(git -C "$mupdf_source" rev-parse HEAD)
if [[ "$actual" != "$mupdf_commit" ]]; then
  echo "Existing source has a different revision; preserving it and refusing to reset: $mupdf_source" >&2
  exit 1
fi
if [[ -n "$(git -C "$mupdf_source" status --porcelain --untracked-files=normal)" ]]; then
  echo "Existing source or submodules contain local changes; preserving them and refusing to update." >&2
  exit 1
fi
git -C "$mupdf_source" submodule update --init --depth 1 --jobs 3 \
  thirdparty/freetype thirdparty/gumbo-parser thirdparty/harfbuzz \
  thirdparty/jbig2dec thirdparty/libjpeg thirdparty/lcms2 thirdparty/mujs \
  thirdparty/openjpeg thirdparty/zlib thirdparty/brotli thirdparty/cmark-gfm thirdparty/extract
# Build the command-line target, not graphical viewers, OCR or barcode engines.
# Keep upstream artifact/TLS verification and compiler diagnostics enabled.
make -C "$mupdf_source" -j3 build=release HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no \
  USE_SYSTEM_CURL=no USE_TESSERACT=no USE_ZXINGCPP=no tools
cd "$study_dir/../.."
python3 experiments/mupdf/run-study.py --source "$mupdf_source" --output build/mupdf-study
