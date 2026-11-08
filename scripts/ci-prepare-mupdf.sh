#!/usr/bin/env bash
# Expose setup diagnostics as Actions annotations when logs require authentication.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
if [[ "${GITHUB_ACTIONS:-}" == true && -d Vendor/mupdf ]]; then
  cached_changes=$(git -C Vendor/mupdf status --porcelain --untracked-files=normal 2>&1)
  cached_status=$?
  if [[ "$cached_status" != 0 || -n "$cached_changes" ]]; then
    echo "::warning title=MuPDF cache::Restored dependency cache is not pristine; preserving it and fetching clean sources."
    printf '%s\n' "$cached_changes" | python3 -c 'import sys; [print("::warning title=Cached dependency change::" + line.rstrip().replace("%", "%25")) for line in sys.stdin]'
    # Only the ephemeral CI workspace is repaired. Local checkouts keep the fetch script's protection.
    mv Vendor/mupdf build/rejected-mupdf-cache
    if [[ -d build/mupdf ]]; then mv build/mupdf build/rejected-mupdf-objects; fi
  fi
fi
bash scripts/fetch-mupdf.sh > build/mupdf-setup.log 2>&1
setup_status=$?
cat build/mupdf-setup.log
if [[ "$setup_status" != 0 && "${GITHUB_ACTIONS:-}" == true ]]; then
  python3 - <<'PY'
from pathlib import Path
for line in Path('build/mupdf-setup.log').read_text(errors='replace').splitlines()[-30:]:
    escaped = line.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print(f'::error title=MuPDF preparation::{escaped}')
PY
fi
exit "$setup_status"
