#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Exercise the exact production C bridge against real MuPDF, without Apple SDKs."""
import argparse
import json
import subprocess
import sys
import unittest
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tests/native"))
from fixtures import pdf_fixture

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, required=True)
args = parser.parse_args()
source = args.source.resolve()
output = root / "build/native-engine-tests"
output.mkdir(parents=True, exist_ok=True)
mutool = source / "build/release/mutool"
binary = output / "engine"

def run(*command):
    result = subprocess.run(list(map(str, command)), capture_output=True)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stderr.decode(errors='replace')}")
    return result.stdout

if run("git", "-C", source, "rev-parse", "HEAD").decode().strip() != "da5f5eb890d7b3fb76903160b5f7f48ba1301492":
    sys.exit("Expected pinned MuPDF 1.28.6 source")
for name, path in [("engine", root / "Native/PSPDFEngine.c"), ("driver", root / "tests/native/driver.c")]:
    run("cc", "-std=c11", "-Wall", "-Wextra", "-DFZ_ENABLE_JS=0", "-DFZ_ENABLE_BARCODE=0", "-I", source / "include", "-I", root / "Native", "-c", path, "-o", output / f"{name}.o")
run("c++", output / "engine.o", output / "driver.o", source / "build/release/libmupdf.a", source / "build/release/libmupdf-third.a", "-lm", "-pthread", "-o", binary)

class NativeEngineTests(unittest.TestCase):
    def setUp(self):
        self.folder = output / self.id().split(".")[-1]
        self.folder.mkdir(exist_ok=True)
        self.original = self.folder / "input.pdf"
        pdf_fixture(self.original)
        self.target = self.folder / "output.pdf"
        self.target.unlink(missing_ok=True)

    def invoke(self, op=1, page=0, region=(45, 730, 300, 762), text="Replacement", size=12, image="", password="", succeed=True):
        result = subprocess.run([str(binary), str(self.original), str(self.target), str(op), str(page),
                                 *map(str, region), text, str(size), str(image), password], capture_output=True)
        if succeed: self.assertEqual(result.returncode, 0, result.stderr.decode())
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.target.exists())
        return result

    def extracted(self): return run(mutool, "draw", "-q", "-F", "txt", self.target).decode()

    def replacement_image(self):
        image = self.folder / "blue.ppm"
        image.write_bytes(b"P6\n4 4\n255\n" + bytes([0, 0, 255]) * 16)
        return image

    def render_pixel(self, page, x, y):
        image = self.folder / f"page-{page}.ppm"
        run(mutool, "draw", "-q", "-F", "ppm", "-r", "72", "-o", image, self.target, page)
        with image.open("rb") as file:
            self.assertEqual(file.readline().strip(), b"P6")
            width, height = map(int, file.readline().split())
            self.assertEqual(file.readline().strip(), b"255")
            pixels = file.read()
        self.assertEqual(len(pixels), width * height * 3)
        offset = (y * width + x) * 3
        return tuple(pixels[offset:offset + 3])

    def test_text_is_replaced_as_content(self):
        before = self.original.read_bytes()
        self.invoke()
        text = self.extracted()
        self.assertIn("Replacement", text)
        self.assertNotIn("ORIGINAL_SECRET", text)
        self.assertIn("KEEP_LINE", text)
        self.assertEqual(before, self.original.read_bytes())

    def test_text_works_with_rotated_crop_box(self):
        pdf_fixture(self.original, rotated=True)
        self.invoke()
        self.assertIn("Replacement", self.extracted())
        self.assertNotIn("ORIGINAL_SECRET", self.extracted())

    def test_unicode_and_pdf_special_characters_are_safe(self):
        self.invoke(text="Été (0.1) \\ test")
        self.assertIn("Été (0.1) \\ test", self.extracted())

    def test_oversized_text_is_rejected(self): self.invoke(text="X" * 500, succeed=False)
    def test_multiline_text_is_rejected(self): self.invoke(text="one\ntwo", succeed=False)
    def test_invalid_page_is_rejected(self): self.invoke(page=10, succeed=False)
    def test_nonfinite_coordinates_are_rejected(self): self.invoke(region=(float("nan"), 0, 1, 1), succeed=False)
    def test_unknown_operation_is_rejected(self): self.invoke(op=100, succeed=False)

    def test_image_replaces_one_occurrence_on_one_page(self):
        self.invoke(op=2, region=(90, 580, 90, 580), image=self.replacement_image())
        self.assertEqual(self.render_pixel(1, 90, 262), (0, 0, 255))
        self.assertEqual(self.render_pixel(1, 190, 262), (255, 0, 0))
        self.assertEqual(self.render_pixel(2, 90, 262), (255, 0, 0))

    def test_nested_form_image_replacement(self):
        pdf_fixture(self.original, nested=True)
        self.invoke(op=2, region=(90, 580, 90, 580), image=self.replacement_image())
        self.assertEqual(self.render_pixel(1, 90, 262), (0, 0, 255))
        self.assertEqual(self.render_pixel(2, 90, 262), (255, 0, 0))

    def test_missing_image_target_fails(self):
        self.invoke(op=2, region=(400, 400, 400, 400), image=self.replacement_image(), succeed=False)

    def test_inserted_image_is_a_visible_stamp_and_preserves_text(self):
        self.invoke(op=4, region=(350, 400, 430, 480), image=self.replacement_image())
        self.assertEqual(self.render_pixel(1,390,402),(0,0,255))
        self.assertIn("ORIGINAL_SECRET",self.extracted())
        self.assertEqual(self.render_pixel(2,390,402),(255,255,255))

    def test_image_insertion_rejects_empty_image_or_rectangle(self):
        self.invoke(op=4,region=(350,400,430,480),succeed=False)
        self.invoke(op=4,region=(0,0,0,0),image=self.replacement_image(),succeed=False)

    def test_redaction_removes_text_from_pdf_content_and_draws_black(self):
        self.invoke(op=5)
        self.assertNotIn("ORIGINAL_SECRET",self.extracted())
        self.assertIn("KEEP_LINE",self.extracted())
        self.assertEqual(self.render_pixel(1,100,95),(0,0,0))
        clean=self.folder / "decompressed.pdf"
        run(mutool,"clean","-d",self.target,clean)
        self.assertNotIn(b"ORIGINAL_SECRET",clean.read_bytes())

    def test_redaction_handles_rotated_cropped_page(self):
        pdf_fixture(self.original,rotated=True)
        self.invoke(op=5)
        self.assertNotIn("ORIGINAL_SECRET",self.extracted())
        self.assertIn("KEEP_LINE",self.extracted())

    def test_redaction_of_image_does_not_change_another_occurrence(self):
        self.invoke(op=5,region=(50,540,130,620))
        self.assertEqual(self.render_pixel(1,90,262),(0,0,0))
        self.assertEqual(self.render_pixel(1,190,262),(255,0,0))
        self.assertEqual(self.render_pixel(2,90,262),(255,0,0))

    def test_docx_is_valid_and_contains_text(self):
        self.invoke(op=3)
        with zipfile.ZipFile(self.target) as archive:
            text = "".join(ElementTree.fromstring(archive.read("word/document.xml")).itertext())
        self.assertIn("ORIGINAL_SECRET", text)
        self.assertIn("KEEP_LINE", text)

    def test_malformed_input_fails_without_output(self):
        self.original.write_bytes(b"invalid pdf")
        self.invoke(succeed=False)

    def encrypt(self, permissions="-4"):
        target = self.folder / "protected.pdf"
        run(mutool, "clean", "-E", "aes-256", "-O", "owner", "-U", "secret", "-P", permissions, self.original, target)
        self.original = target

    def test_password_is_preserved_after_edit(self):
        self.encrypt()
        self.invoke(password="secret")
        locked = subprocess.run([str(mutool), "draw", "-q", "-F", "txt", str(self.target)], capture_output=True)
        self.assertNotEqual(locked.returncode, 0)
        unlocked = run(mutool, "draw", "-q", "-p", "secret", "-F", "txt", self.target).decode()
        self.assertIn("Replacement", unlocked)
        self.assertNotIn("ORIGINAL_SECRET", unlocked)

    def test_wrong_password_fails(self):
        self.encrypt()
        self.invoke(password="wrong", succeed=False)

    def test_edit_permission_is_enforced(self):
        self.encrypt(permissions="4")
        self.invoke(password="secret", succeed=False)

suite = unittest.defaultTestLoader.loadTestsFromTestCase(NativeEngineTests)
result = unittest.TextTestRunner(verbosity=2).run(suite)
report = {"at": datetime.now(timezone.utc).isoformat(), "tests_run": result.testsRun,
          "failures": len(result.failures), "errors": len(result.errors), "skipped": len(result.skipped),
          "scope": "Production C bridge on Linux, not Xcode/iPadOS", "success": result.wasSuccessful() and result.testsRun >= 21}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["success"] else 1)
