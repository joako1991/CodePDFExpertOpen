#!/usr/bin/env bash
# Expose setup diagnostics as Actions annotations when logs require authentication.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
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
