#!/usr/bin/env python3
"""Reject unaccounted legacy branding and validate the canonical asset inventory."""
import hashlib
import json
import pathlib
import plistlib
import re
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
ALLOWLIST = ROOT / "Branding/legacy-reference-allowlist.json"
LEGACY = re.compile(r"boring", re.IGNORECASE)
errors = []
exceptions = json.loads(ALLOWLIST.read_text())["files"]
raw = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
files = sorted(set(raw.decode().split("\0")) - {""})
checked = 0
for name in files:
    path = ROOT / name
    if not path.is_file() or path == ALLOWLIST:
        continue
    checked += 1
    if LEGACY.search(name):
        errors.append(f"Legacy filename: {name}")
    data = path.read_bytes()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        continue
    hits = len(LEGACY.findall(text))
    exception = exceptions.get(name)
    if hits and not exception:
        errors.append(f"Unaccounted legacy references: {name} ({hits})")
    if exception and (exception["sha256"] != hashlib.sha256(data).hexdigest() or exception["references"] != hits):
        errors.append(f"Legacy exception changed; review its exact contents: {name}")
    if path.suffix in (".json", ".xcstrings"):
        try:
            json.loads(text)
        except ValueError as error:
            errors.append(f"Invalid JSON: {name}: {error}")
    if path.suffix in (".plist", ".entitlements"):
        try:
            plistlib.loads(data)
        except Exception as error:
            errors.append(f"Invalid plist: {name}: {error}")
    if path.suffix == ".xcscheme":
        try:
            ET.fromstring(text)
        except ET.ParseError as error:
            errors.append(f"Invalid scheme: {name}: {error}")
for name in exceptions:
    if not (ROOT / name).is_file():
        errors.append(f"Missing exception file: {name}")

manifest = json.loads((ROOT / "Branding/manifest.json").read_text())
inventoried = set()
for asset in manifest["assets"]:
    name = asset.get("path")
    if not name:
        if not asset.get("source_url"):
            errors.append("Asset has neither path nor source URL")
        continue
    inventoried.add(name)
    path = ROOT / name
    if not path.is_file():
        errors.append(f"Missing branding asset: {name}")
        continue
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != asset["sha256"]:
        errors.append(f"Branding asset changed without inventory update: {name}")
    if path.suffix == ".png":
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            errors.append(f"Invalid PNG: {name}")
            continue
        width, height = struct.unpack(">II", data[16:24])
        if asset.get("dimensions") != [width, height]:
            errors.append(f"Incorrect dimensions in inventory: {name}")
        if asset.get("asset") == "AppIcon":
            expected = int(asset["size"].split("x")[0]) * int(asset["scale"][0])
            if width != expected or height != expected:
                errors.append(f"Wrong app icon dimensions: {name}")
for catalog in [ROOT / "Branding/Assets.xcassets", ROOT / "callaNotch/Assets.xcassets"]:
    for path in catalog.rglob("Contents.json"):
        content = json.loads(path.read_text())
        for image in content.get("images", []):
            if "filename" in image and not (path.parent / image["filename"]).is_file():
                errors.append(f"Missing catalog resource: {path.relative_to(ROOT)}: {image['filename']}")
for path in (ROOT / "Branding").rglob("*"):
    if path.is_file() and path.suffix in (".png", ".svg", ".m4a", ".tiff"):
        name = str(path.relative_to(ROOT))
        if name not in inventoried and path.name != "contact-sheet.png":
            errors.append(f"Branding file missing from inventory: {name}")
project = ROOT / "callaNotch.xcodeproj/project.pbxproj"
subprocess.run(["plutil", "-lint", "-s", str(project)], check=True)
project_text = project.read_text()
if "Branding/Assets.xcassets" not in project_text:
    errors.append("Canonical branding catalog is missing from Xcode")
if "welcome.m4a" in project_text or "UpstreamWordmark" in project_text:
    errors.append("Archived branding must not be shipped")
info = plistlib.loads((ROOT / "callaNotch/Info.plist").read_bytes())
if "SUFeedURL" in info or "SUPublicEDKey" in info:
    errors.append("Automatic updates require a separately reviewed owned feed")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Branding audit passed: {checked} files; {len(manifest['assets'])} inventoried assets; {len(exceptions)} explicit legacy exceptions.")
