"""Structural checks available on Linux. This is not a Swift build or test runner."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
project = (root / "PaperStudio.xcodeproj/project.pbxproj").read_text()
definitions = re.findall(r"^([A-F0-9]{24}) = \{", project, re.M)
assert len(definitions) == len(set(definitions)), "Duplicate project object IDs"
references = set(re.findall(r"\b[A-F0-9]{24}\b", project))
assert references == set(definitions), f"Unresolved object references: {references - set(definitions)}"
for folder in ("PaperStudio", "PaperStudioTests"):
    for source in (root / folder).glob("*.swift"):
        assert f"path = {source.name};" in project, f"Source missing from project: {source}"
scheme = ET.parse(root / "PaperStudio.xcodeproj/xcshareddata/xcschemes/PaperStudio.xcscheme")
for ref in scheme.iter("BuildableReference"):
    assert ref.attrib["BlueprintIdentifier"] in definitions
assert len(list(scheme.iter("TestableReference"))) == 1
tests = (root / "PaperStudioTests/PaperStudioTests.swift").read_text()
test_count = len(re.findall(r"func test\w+\(", tests))
assert test_count >= 34, "Expected regression test methods are missing"
assert "TARGETED_DEVICE_FAMILY = 2;" in project
assert "IPHONEOS_DEPLOYMENT_TARGET = 17.0;" in project
assert "INFOPLIST_KEY_NSCameraUsageDescription" in project
assert "Native/PSPDFEngine.c" in project
assert "SWIFT_OBJC_BRIDGING_HEADER" in project
assert '"-lPaperMuPDF"' in project
assert "Build MuPDF 1.28.6" in project
assert "MARKETING_VERSION = 0.1;" in project
assert "PaperStudio/Legal" in project
assert "PBXVariantGroup" in project
for language in ["en", "es", "fr"]:
    assert f"Localization/{language}.lproj/Localizable.strings" in project
print(f"Structure OK: {len(definitions)} project objects, shared scheme, {test_count} test methods.")
print("Swift compilation and XCTest execution require Xcode on macOS; neither ran here.")
