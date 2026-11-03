#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mupdf_source="$project_root/Vendor/mupdf"
mupdf_commit=da5f5eb890d7b3fb76903160b5f7f48ba1301492
if [[ ! -e "$mupdf_source" ]]; then
  mkdir -p "$project_root/Vendor"
  git clone --depth 1 --branch 1.28.6 https://github.com/ArtifexSoftware/mupdf.git "$mupdf_source"
fi
if [[ "$(git -C "$mupdf_source" rev-parse HEAD)" != "$mupdf_commit" ]]; then
  echo 'Vendor/mupdf has a different revision. It has been preserved; no reset will be performed.' >&2
  exit 1
fi
if [[ -n "$(git -C "$mupdf_source" status --porcelain --untracked-files=normal)" ]]; then
  echo 'MuPDF or its submodules have local changes. Preserve/review them before refreshing dependencies.' >&2
  exit 1
fi
git -C "$mupdf_source" submodule update --init --depth 1 --jobs 3 \
  thirdparty/freetype thirdparty/gumbo-parser thirdparty/harfbuzz \
  thirdparty/jbig2dec thirdparty/libjpeg thirdparty/lcms2 thirdparty/mujs \
  thirdparty/openjpeg thirdparty/zlib thirdparty/brotli thirdparty/cmark-gfm thirdparty/extract
python3 "$project_root/scripts/prepare-mupdf-notices.py"
echo 'MuPDF 1.28.6 sources and legal notices prepared. Open PaperStudio.xcodeproj on macOS.'
