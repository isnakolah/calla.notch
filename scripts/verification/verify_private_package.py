#!/usr/bin/env python3
"""Build-machine checks; never shipped as a receiving-Mac dependency."""
import pathlib
import plistlib
import re
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
errors = []
engine_info = app / "Contents/XPCServices/CallaEngine.xpc/Contents/Info.plist"
if not engine_info.is_file() or plistlib.loads(engine_info.read_bytes()).get("XPCService", {}).get("JoinExistingSession") is not True:
    errors.append("Engine must join the app's security session for Keychain access")
count = 0
for path in app.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open("rb") as handle:
        magic = handle.read(4)
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        continue
    count += 1
    signature = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], capture_output=True)
    if signature.returncode:
        errors.append(f"Invalid native signature: {path.relative_to(app)}")
    arch = subprocess.run(["/usr/bin/lipo", "-verify_arch", "arm64", str(path)], capture_output=True)
    if arch.returncode:
        errors.append(f"No arm64 slice: {path.relative_to(app)}")
    linkage = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
    for line in linkage.splitlines()[1:]:
        # Universal files print another unindented filename/architecture header
        # before the second slice. It is not a load command.
        if not line.startswith("\t"):
            continue
        dependency = line.strip().split(" (compatibility version")[0]
        if dependency.startswith("/") and not dependency.startswith(("/System/Library/", "/usr/lib/")):
            errors.append(f"External dependency: {path.relative_to(app)} → {dependency}")
    commands = subprocess.check_output(["/usr/bin/otool", "-l", "-arch", "arm64", str(path)], text=True)
    for minimum in re.findall(r"\bminos\s+(\d+)\.(\d+)", commands):
        if tuple(map(int, minimum)) > (15, 0):
            errors.append(f"Requires macOS {'.'.join(minimum)}: {path.relative_to(app)}")
    for rpath in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", commands):
        if rpath.startswith("/") and not rpath.startswith(("/usr/lib/", "/System/Library/")):
            errors.append(f"External runtime search path: {path.relative_to(app)} → {rpath}")

required = [
    "Contents/Resources/Calla/Gateway/calla-gateway.tar.gz",
    "Contents/Resources/PrivateSetup/manifest.json",
    "Contents/Resources/PrivateSetup/archive-enrollment.json",
    "Contents/Helpers/tangit",
    "Contents/Resources/Tangit/Providers/codex/bin/codex",
    "Contents/Resources/Tangit/Providers/codex/codex-path/rg",
    "Contents/Resources/Tangit/Providers/claude/bin/claude",
    "Contents/Resources/Tangit/Providers/agy/bin/agy",
    "Contents/XPCServices/CallaEngine.xpc/Contents/Resources/CallaRuntime/CallaCallHost.app/Contents/MacOS/CallaCallHost",
]
# Tutor was removed; its host must not ride along from a stale build.
for removed in ("CallaTutorHost.app", "CallaOverlayHelper.app"):
    for path in app.rglob(removed):
        errors.append(f"Removed Tutor component still packaged: {path.relative_to(app)}")
for relative in required:
    if not (app / relative).is_file():
        errors.append(f"Missing resource: {relative}")
for path in app.rglob("*"):
    if path.suffix == ".command":
        errors.append(f"Unexpected command launcher in single-app package: {path.relative_to(app)}")
    if path.name in ("oauth_creds.json", "antigravity-oauth-token", "id_ed25519", "id_rsa") or path.suffix in (".p12", ".keychain-db"):
        errors.append(f"Private machine state in package: {path.relative_to(app)}")
if not count:
    errors.append("No Mach-O executables found")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Portable package structure verified: {count} Mach-O files with arm64 support, macOS 15 compatibility, and system/bundled linkage.")
