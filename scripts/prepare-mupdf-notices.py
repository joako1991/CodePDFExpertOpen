#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Collect upstream notice files without changing their content or attribution."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
source = root / "Vendor/mupdf"
target = root / "PaperStudio/Legal/MuPDFNotices"
target.mkdir(parents=True, exist_ok=True)
records = []
for path in sorted(source.rglob("*")):
    relative = path.relative_to(source)
    if any(part in {".git", "build"} for part in relative.parts) or not path.is_file():
        continue
    if not (path.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "COPYRIGHT")) or path.suffix.lower() == ".license"):
        continue
    # Notice files are exposed as text in the app, retaining their full source-relative path.
    destination = target / (str(relative).replace("/", "__") + ".txt")
    contents = path.read_bytes()
    destination.write_bytes(contents)
    records.append({"source": str(relative), "file": destination.name, "sha256": hashlib.sha256(contents).hexdigest()})
if not any(record["source"] == "COPYING" for record in records):
    raise SystemExit("MuPDF COPYING is missing; dependency preparation is incomplete")
(target / "manifest.json").write_text(json.dumps(records, indent=2) + "\n")
print(f"Prepared {len(records)} upstream notices for the application bundle")
