#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Expose compiler/test diagnostics in the public Actions job summary, without API auth."""
import os
import re
from pathlib import Path

log = Path("build/xcodebuild.log")
lines = log.read_text(errors="replace").splitlines() if log.exists() else ["No Xcode build log was produced."]
diagnostics = [line for line in lines if re.search(r"error:|fatal error:|Testing failed:|Test Case.*failed|BUILD FAILED|TEST FAILED|Unable to find a destination", line)]
summary = "## Xcode build and test diagnostics\n\n```text\n"
summary += "\n".join(diagnostics[:80] or ["No compiler error lines found; inspect the final output below."])
summary += "\n```\n\n### Final output\n\n```text\n" + "\n".join(lines[-45:]) + "\n```\n"
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
        output.write(summary)
print(summary)
