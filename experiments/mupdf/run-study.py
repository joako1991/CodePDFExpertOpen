#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build the C probe and test real MuPDF output. No Apple APIs or app integration."""
import argparse
import hashlib
import json
import subprocess
import sys
import unittest
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree

COMMIT = "da5f5eb890d7b3fb76903160b5f7f48ba1301492"
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, required=True, help="MuPDF 1.28.6 source with built release libraries and mutool")
parser.add_argument("--output", type=Path, default=Path("build/mupdf-study"))
args = parser.parse_args()
source = args.source.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)


def run(*command, **kwargs):
    try:
        return subprocess.run([str(part) for part in command], check=True, capture_output=True, **kwargs)
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.stdout.decode(errors="replace"))
        sys.stderr.write(error.stderr.decode(errors="replace"))
        raise


actual = run("git", "-C", source, "rev-parse", "HEAD").stdout.decode().strip()
if actual != COMMIT:
    sys.exit(f"Expected MuPDF 1.28.6 commit {COMMIT}, found {actual}; refusing a different source revision")
run("git", "-C", source, "diff", "--exit-code", "--", "include", "source", "Makefile", "Makerules", "Makethird", "Makelists")
library = source / "build/release"
mutool = library / "mutool"
probe = output / "probe"
probe_source = Path(__file__).with_name("probe.c")
run("cc", "-std=c11", "-Wall", "-Wextra", "-I", source / "include", "-c", probe_source, "-o", output / "probe.o")
run("c++", output / "probe.o", library / "libmupdf.a", library / "libmupdf-third.a", "-lm", "-pthread", "-o", probe)


def fixture(path):
    """Two pages share the same resource dictionary and red image XObject."""
    def stream(data, entries=b""):
        return b"<< /Length %d %s >>\nstream\n" % (len(data), entries) + data + b"\nendstream"

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources 9 0 R /Contents 5 0 R >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources 9 0 R /Contents 6 0 R >>",
        stream(b"BT /F1 18 Tf 50 740 Td (ORIGINAL_SECRET) Tj ET\nBT /F1 18 Tf 50 680 Td (KEEP_LINE) Tj ET\nq 80 0 0 80 50 540 cm /Im0 Do Q\n"),
        stream(b"BT /F1 18 Tf 50 740 Td (SECOND_PAGE) Tj ET\nq 80 0 0 80 50 540 cm /Im0 Do Q\n"),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        stream(bytes([255, 0, 0]) * 16, b"/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8"),
        b"<< /Font << /F1 7 0 R >> /XObject << /Im0 8 0 R >> >>",
    ]
    data = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{index} 0 obj\n".encode() + obj + b"\nendobj\n"
    startxref = len(data)
    data += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    for offset in offsets[1:]:
        data += f"{offset:010d} 00000 n \n".encode()
    data += f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{startxref}\n%%EOF\n".encode()
    path.write_bytes(data)


def text(pdf):
    return run(mutool, "draw", "-q", "-F", "txt", pdf).stdout.decode()


def pixel(ppm, x, y):
    with ppm.open("rb") as image:
        if image.readline().strip() != b"P6":
            raise ValueError("Expected RGB PPM")
        line = image.readline()
        while line.startswith(b"#"):
            line = image.readline()
        width, height = map(int, line.split())
        if image.readline().strip() != b"255":
            raise ValueError("Expected 8-bit PPM")
        data = image.read()
        if len(data) != width * height * 3:
            raise ValueError("Truncated pixel data")
        start = (y * width + x) * 3
        return tuple(data[start:start + 3])


class MuPDFStudy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = output / "original.pdf"
        fixture(cls.original)
        cls.original_bytes = cls.original.read_bytes()
        for operation in ["redact", "replace-text", "replace-image"]:
            target = output / f"{operation}.pdf"
            target.unlink(missing_ok=True)  # Only generated study output, never user files.
            run(probe, cls.original, target, operation)
        run(mutool, "draw", "-q", "-F", "ppm", "-r", "72", "-o", output / "image-%d.ppm", output / "replace-image.pdf")

    def test_fixture_has_extractable_text_and_two_pages(self):
        content = text(self.original)
        self.assertIn("ORIGINAL_SECRET", content)
        self.assertIn("SECOND_PAGE", content)
        self.assertEqual(run(mutool, "show", self.original, "trailer/Root/Pages/Count").stdout.strip(), b"2")

    def test_redaction_removes_original_text(self):
        self.assertNotIn("ORIGINAL_SECRET", text(output / "redact.pdf"))

    def test_redaction_preserves_unaffected_selectable_text(self):
        content = text(output / "redact.pdf")
        self.assertIn("KEEP_LINE", content)
        self.assertIn("SECOND_PAGE", content)

    def test_redaction_writes_no_incremental_history(self):
        self.assertNotIn(b"/Prev", (output / "redact.pdf").read_bytes())

    def test_replacement_text_is_real_searchable_content(self):
        content = text(output / "replace-text.pdf")
        self.assertIn("REPLACEMENT_TEXT", content)
        self.assertNotIn("ORIGINAL_SECRET", content)
        self.assertIn("KEEP_LINE", content)

    def test_replacement_is_not_a_free_text_annotation(self):
        annots = run(mutool, "show", output / "replace-text.pdf", "pages/1/Annots").stdout.strip()
        self.assertIn(annots, [b"null", b"[ ]", b"[]"])

    def test_image_replacement_changes_first_page_pixels(self):
        self.assertEqual(pixel(output / "image-1.ppm", 90, 262), (0, 0, 255))

    def test_shared_image_on_second_page_stays_red(self):
        self.assertEqual(pixel(output / "image-2.ppm", 90, 262), (255, 0, 0))

    def test_original_file_is_unchanged(self):
        self.assertEqual(self.original.read_bytes(), self.original_bytes)

    def test_invalid_input_fails_without_producing_a_pdf(self):
        invalid = output / "invalid.pdf"
        invalid.write_text("not a pdf")
        target = output / "invalid-output.pdf"
        target.unlink(missing_ok=True)
        result = subprocess.run([str(probe), str(invalid), str(target), "replace-text"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())

    def test_docx_output_contains_document_text(self):
        target = output / "converted.docx"
        target.unlink(missing_ok=True)
        run(mutool, "convert", "-F", "docx", "-o", target, self.original)
        with zipfile.ZipFile(target) as archive:
            xml = ElementTree.fromstring(archive.read("word/document.xml"))
            content = "".join(xml.itertext())
        self.assertIn("ORIGINAL_SECRET", content)
        self.assertIn("KEEP_LINE", content)


suite = unittest.defaultTestLoader.loadTestsFromTestCase(MuPDFStudy)
result = unittest.TextTestRunner(verbosity=2).run(suite)
report = {
    "run_at_utc": datetime.now(timezone.utc).isoformat(),
    "source_commit": actual,
    "mutool_version": run(mutool, "-v").stderr.decode().strip(),
    "probe_source_sha256": hashlib.sha256(probe_source.read_bytes()).hexdigest(),
    "tests_run": result.testsRun,
    "failures": len(result.failures), "errors": len(result.errors), "skipped": len(result.skipped),
    "successful": result.wasSuccessful() and result.testsRun == 11,
    "platform_scope": "Linux native MuPDF study; not iPadOS integration or Xcode tests",
}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["successful"] else 1)
