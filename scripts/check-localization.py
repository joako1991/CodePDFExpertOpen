#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Validate localization files, including escape syntax and format placeholders."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
catalogs = {}
for language in ("en", "es", "fr"):
    entries = {}
    file = root / f"Localization/{language}.lproj/Localizable.strings"
    for number, line in enumerate(file.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("/*"):
            continue
        match = re.fullmatch(r'("(?:[^"\\]|\\.)*") = ("(?:[^"\\]|\\.)*");', line)
        assert match, f"Invalid strings syntax: {file}:{number}"
        key, value = map(json.loads, match.groups())
        assert key not in entries, f"Duplicate key: {key}"
        assert value, f"Empty translation: {language}: {key}"
        placeholders = lambda text: re.findall(r"%(?:\d+\$)?(?:lld|ld|d|f|@)", text)
        assert placeholders(key) == placeholders(value), f"Format mismatch: {language}: {key}"
        entries[key] = value
    catalogs[language] = entries
assert catalogs["en"].keys() == catalogs["es"].keys() == catalogs["fr"].keys()
assert len(catalogs["en"]) >= 234
assert catalogs["en"]["Souligner"] == "Underline"
assert catalogs["es"]["Souligner"] == "Subrayar"
print(f"Localization OK: {len(catalogs['en'])} matching entries for English, Spanish and French")
