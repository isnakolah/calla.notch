#!/bin/bash
# Build a private, locally signed Apple Silicon DMG. This never installs the
# app or contacts the Gateway. Xcode/Python are build-machine dependencies only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/private"
IDENTITY="Calla Local Signing"
VERSION=""
BUILD=""
SOURCE_APP=""
TANGIT_SOURCE="$ROOT/../tangit"
SETTINGS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?missing version}"; shift 2 ;;
    --build) BUILD="${2:?missing build}"; shift 2 ;;
    --identity) IDENTITY="${2:?missing identity}"; shift 2 ;;
    --app) SOURCE_APP="${2:?missing built app}"; shift 2 ;;
    --tangit-source) TANGIT_SOURCE="${2:?missing Tangit source}"; shift 2 ;;
    # A snapshot from About › Export settings. The installed app applies it once.
    --settings) SETTINGS="${2:?missing settings snapshot}"; shift 2 ;;
    -h|--help) echo "Usage: scripts/package-private.sh [--version X.Y.Z] [--build N] [--identity NAME] [--app PREBUILT.app] [--tangit-source DIRECTORY] [--settings SNAPSHOT.plist]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
if [[ -n "$SETTINGS" ]]; then
  plutil -lint -s "$SETTINGS" && [[ "$(plutil -extract format raw -o - "$SETTINGS" 2>/dev/null)" == 1 ]] \
    || { echo "Not a settings snapshot: $SETTINGS" >&2; exit 2; }
fi
if [[ -z "$VERSION" ]]; then VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$ROOT/boringNotch.xcodeproj/project.pbxproj" | head -1)"; fi
if [[ -z "$BUILD" ]]; then
  previous="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$ROOT/boringNotch.xcodeproj/project.pbxproj" | head -1)"
  if [[ -f "$OUT/last-build" ]]; then cached="$(cat "$OUT/last-build")"; [[ "$cached" =~ ^[0-9]+$ ]] && (( cached > previous )) && previous="$cached"; fi
  BUILD="$((previous + 1))"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || { echo "Use a numeric X.Y.Z version and numeric build." >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo "Run the private package build natively on Apple Silicon." >&2; exit 1; }
security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$IDENTITY\"" || { echo "Missing persistent signing identity: $IDENTITY" >&2; exit 1; }
echo "Building private Boring Notch $VERSION ($BUILD)"
echo "Build logs: $OUT"
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault xcrun swift build --package-path "$ROOT/Distribution" -c release --triple arm64-apple-macosx14.0 >"$OUT/setup-build.log" 2>&1 || { tail -70 "$OUT/setup-build.log" >&2; exit 1; }
BINARIES="$(TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault xcrun swift build --package-path "$ROOT/Distribution" -c release --triple arm64-apple-macosx14.0 --show-bin-path)"
if [[ -z "$SOURCE_APP" ]]; then
  cat >"$OUT/private-signing.xcconfig" <<CONFIG
CODE_SIGN_IDENTITY = $IDENTITY
CODE_SIGN_IDENTITY[sdk=macosx*] = $IDENTITY
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM =
CONFIG
  xcodebuild -project "$ROOT/boringNotch.xcodeproj" -scheme boringNotch -configuration Release \
    -derivedDataPath "$OUT/DerivedData" -destination 'generic/platform=macOS' \
    -xcconfig "$OUT/private-signing.xcconfig" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build >"$OUT/app-build.log" 2>&1 \
    || { rg -n 'error:|BUILD FAILED' "$OUT/app-build.log" >&2 || tail -80 "$OUT/app-build.log" >&2; exit 1; }
  SOURCE_APP="$OUT/DerivedData/Build/Products/Release/boringNotch.app"
fi
[[ -d "$SOURCE_APP" ]] || { echo "Built app missing: $SOURCE_APP" >&2; exit 1; }
STAGE="$(mktemp -d "$OUT/.package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Boring Notch.app"
ditto "$SOURCE_APP" "$APP"
PRIVATE="$APP/Contents/Resources/PrivateSetup"
rm -rf "$PRIVATE"
mkdir -p "$APP/Contents/Helpers" "$PRIVATE"
# Replace only this distribution-owned directory inside the temporary stage.
rm -rf "$APP/Contents/Resources/Tangit"
python3 "$ROOT/scripts/prepare-tangit.py" --source "$TANGIT_SOURCE" --output "$APP/Contents/Resources/Tangit"
mv "$APP/Contents/Resources/Tangit/tangit" "$APP/Contents/Helpers/"
mv "$APP/Contents/Resources/Tangit/Tangit-LICENSE.txt" "$PRIVATE/"
mv "$APP/Contents/Resources/Tangit/tangit-build.json" "$PRIVATE/"
mv "$APP/Contents/Resources/Tangit/Go-dependency-notices.txt" "$PRIVATE/"
ditto "$ROOT/Distribution/Licenses" "$PRIVATE/Licenses"
ditto "$BINARIES/boring-notch" "$APP/Contents/Helpers/boring-notch"
ditto "$BINARIES/calla-gateway" "$APP/Contents/Helpers/calla-gateway"
ditto "$ROOT/Distribution/START HERE.txt" "$PRIVATE/START HERE.txt"
[[ -z "$SETTINGS" ]] || install -m 0644 "$SETTINGS" "$PRIVATE/settings.plist"
python3 - "$ROOT" "$APP" "$VERSION" "$BUILD" <<'PY'
import json, pathlib, plistlib, subprocess, sys
root, app = map(pathlib.Path, sys.argv[1:3]); version, build = sys.argv[3:5]
manifest = json.loads((root / 'Distribution/dependencies.json').read_text())
manifest['tangit'] = json.loads((app / 'Contents/Resources/PrivateSetup/tangit-build.json').read_text())
manifest['graphicalSetup'] = True
manifest.update(schema=1, version=version, build=int(build), architecture='arm64', minimumOS='15.0',
                sourceRevision=subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
                dirtyWorkingTree=bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'], text=True)))
(app / 'Contents/Resources/PrivateSetup/manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
info = app / 'Contents/Info.plist'
data = plistlib.loads(info.read_bytes())
if data.get('BoringSetupProtocolVersion') != 1 or data.get('BoringSetupUIVersion') != 1:
    raise SystemExit('Built app does not implement private setup protocol v1; rebuild from current source.')
data.update(BoringPrivateDistribution=True, SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
            CFBundleShortVersionString=version, CFBundleVersion=build, LSMinimumSystemVersion='15.0')
data['CFBundleDisplayName'] = 'Boring Notch'
data['NSAppleEventsUsageDescription'] = 'Open Tangit in Terminal when you choose its profile wizard or launch button.'
data.pop('SUFeedURL', None); data.pop('SUPublicEDKey', None)
info.write_bytes(plistlib.dumps(data))
updater = app / 'Contents/Resources/Calla/scripts/gateway-update.sh'
updater.write_text('#!/bin/bash\nset -euo pipefail\n[[ "${1:-}" == --bundle || "${1:-}" == --staged ]] || exit 2\nhere="$(cd "$(dirname "$0")" && pwd)"\nexec "$here/../../../Helpers/calla-gateway" update "${2:?missing artifact}"\n')
updater.chmod(0o755)
PY
python3 - "$APP" <<'PY'
import os, pathlib, re, subprocess, sys
app=pathlib.Path(sys.argv[1])
# SwiftPM leaves a development-toolchain search path on its executables.
# Relocate that lookup to the enclosing app before re-signing the payload.
for name in ('CallaCallHost', 'boring-notch', 'calla-gateway'):
    for executable in app.rglob(name):
        if not executable.is_file() or executable.is_symlink():
            continue
        commands=subprocess.check_output(['otool','-l',str(executable)], text=True)
        paths=re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)
        for path in paths:
            if path.startswith('/Applications/Xcode') or '/Metal.xctoolchain/' in path:
                subprocess.run(['install_name_tool','-delete_rpath',path,str(executable)], check=True)
        relative='@executable_path/'+os.path.relpath(app/'Contents/Frameworks', executable.parent)
        if relative not in paths:
            subprocess.run(['install_name_tool','-add_rpath',relative,str(executable)], check=True)
PY
# macOS 15 provides the Swift runtime. Scan actual executables, not arbitrary
# debug support files inside third-party frameworks.
xcrun swift-stdlib-tool --copy --scan-executable "$APP/Contents/MacOS/boringNotch" \
  --scan-executable "$APP/Contents/Helpers/boring-notch" \
  --scan-executable "$APP/Contents/Helpers/calla-gateway" --platform macosx \
  --destination "$APP/Contents/Frameworks" --strip-bitcode --sign "$IDENTITY"
codesign --force --sign "$IDENTITY" --identifier theboringteam.boringnotch.setup "$APP/Contents/Helpers/boring-notch"
codesign --force --sign "$IDENTITY" --identifier theboringteam.boringnotch.gateway "$APP/Contents/Helpers/calla-gateway"
# Re-seal nested bundles before their parents, preserving existing identifiers
# and entitlements. Private signing deliberately does not enable hardened runtime.
python3 - "$APP" "$IDENTITY" <<'PY'
import pathlib, subprocess, sys
app=pathlib.Path(sys.argv[1]); identity=sys.argv[2]
objects=[p for p in app.rglob('*') if not p.is_symlink() and 'Providers' not in p.relative_to(app).parts and (p.suffix in ('.framework','.xpc','.app') and p.is_dir() or p.suffix=='.dylib' and p.is_file())]
# Keep providers' original signatures and runtime resource hashes. Tangit is
# compiled here and receives this package's persistent signing identity.
subprocess.run(['codesign','--force','--sign',identity,'--identifier','com.isnakolah.tangit',str(app/'Contents/Helpers/tangit')], check=True)
for path in app.rglob('*'):
    if not path.is_file() or path.is_symlink() or 'Providers' in path.relative_to(app).parts: continue
    # Bundle mains are signed with their enclosing bundle, after its children.
    if path.parent.name == 'MacOS' or any(p.suffix == '.framework' for p in path.parents): continue
    with path.open('rb') as stream: magic=stream.read(4)
    if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        subprocess.run(['codesign','--force','--sign',identity,'--preserve-metadata=identifier,entitlements',str(path)], check=True)
for path in sorted(objects, key=lambda p: len(p.parts), reverse=True):
    subprocess.run(['codesign','--force','--sign',identity,'--preserve-metadata=identifier,entitlements',str(path)], check=True)
PY
codesign --force --sign "$IDENTITY" --entitlements "$ROOT/boringNotch/boringNotch.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/Helpers/boring-notch" validate-package "$APP"
python3 "$ROOT/scripts/verification/verify_private_package.py" "$APP"
NAME="boringNotch-private-arm64-$VERSION-$BUILD"
IMAGE="$OUT/$NAME.dmg"
[[ ! -e "$IMAGE" ]] || { echo "Package already exists: $IMAGE. Use a higher build number." >&2; exit 1; }
hdiutil create -quiet -srcfolder "$STAGE" -volname 'Boring Notch Setup' -fs HFS+ -format UDZO "$IMAGE"
hdiutil verify -quiet "$IMAGE"
(cd "$OUT" && shasum -a 256 "$NAME.dmg") >"$IMAGE.sha256"
cp "$PRIVATE/manifest.json" "$OUT/$NAME.manifest.json"
printf '%s\n' "$BUILD" >"$OUT/last-build"
echo "Private installer ready: $IMAGE"
echo "Transfer the DMG to the other Mac; open Boring Notch.app."
