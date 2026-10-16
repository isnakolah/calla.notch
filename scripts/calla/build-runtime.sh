#!/usr/bin/env bash
# Build Boring's call runtime (CallaCallHost) into an XPC resource directory.
set -euo pipefail
trap 'echo "Calla runtime build failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# Xcode exposes its selected Metal toolchain to Run Script phases. Nested SPM
# builds need Swift compiler tools, not Metal's partial toolchain; otherwise
# CallaCallHost fails only when invoked from xcodebuild.
export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
unset TOOLCHAIN_DIR

swift_build() {
  if ! xcrun swift build "$@" >/dev/null; then
    # First pass stays quiet in ordinary Xcode builds. Repeat only on failure
    # so nested SPM diagnostics reach Xcode's build log.
    xcrun swift build "$@"
    return 1
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="${1:?usage: build-runtime.sh <resource-directory>}"
if [[ "${CALLA_COMPILE_ONLY:-0}" == "1" ]]; then
  echo "Calla runtime: skipped for compile-only source validation"
  exit 0
fi
CONFIGURATION="${CONFIGURATION:-Debug}"
SWIFT_CONFIGURATION="debug"
[[ "$CONFIGURATION" == "Release" ]] && SWIFT_CONFIGURATION="release"

# CI builds intentionally have no TCC-capable identity. They produce a compile
# artifact only: never install it, never claim its permissions, and never use
# it as a deployment payload. Installed builds still require real identity.
SIGN_CALLA_RUNTIME=1
if [[ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" || "${EXPANDED_CODE_SIGN_IDENTITY}" == "-" ]]; then
  if [[ "${CALLA_UNSIGNED_BUILD:-0}" == "1" ]]; then
    SIGN_CALLA_RUNTIME=0
    echo "Calla runtime: unsigned CI artifact (deployment-ineligible)"
  else
    echo "missing expanded Boring signing identity for embedded Calla runtime" >&2
    exit 78
  fi
fi

mkdir -p "$DESTINATION"
# Earlier builds staged a Tutor host, its overlay helper, lesson relays and
# Blender templates here. Incremental builds must not carry them forward.
/bin/rm -rf "$DESTINATION/CallaTutorHost.app" "$DESTINATION/CallaTutorHost" "$DESTINATION/CallaOverlayHelper" \
  "$DESTINATION/scripts" "$DESTINATION/assets"
# The live-call capture host. It ships under Boring's identity: TCC keys the
# microphone and screen-recording grants to the signature, and an ad-hoc one
# cannot hold either.
CALLHOST_PACKAGE="$ROOT/CallaCallHost"
if [[ -d "$CALLHOST_PACKAGE" ]]; then
  swift_build --package-path "$CALLHOST_PACKAGE" -c "$SWIFT_CONFIGURATION"
  CALLHOST_BIN="$(xcrun swift build --package-path "$CALLHOST_PACKAGE" -c "$SWIFT_CONFIGURATION" --show-bin-path)"
  if [[ -x "$CALLHOST_BIN/CallaCallHost" ]]; then
    CALLHOST_APP="$DESTINATION/CallaCallHost.app"
    /bin/rm -rf "$CALLHOST_APP"
    mkdir -p "$CALLHOST_APP/Contents/MacOS" "$CALLHOST_APP/Contents/Resources" "$CALLHOST_APP/Contents/Frameworks"
    ditto "$CALLHOST_BIN/CallaCallHost" "$CALLHOST_APP/Contents/MacOS/CallaCallHost"
    ditto "$ROOT/scripts/calla/CallaCallHost-Info.plist" "$CALLHOST_APP/Contents/Info.plist"
    # `Bundle.module` resolves against Bundle.main.resourceURL inside an app,
    # which is where the bundled Silero VAD model has to land.
    for bundle in "$CALLHOST_BIN"/*.bundle; do
      [[ -e "$bundle" ]] || continue
      ditto "$bundle" "$CALLHOST_APP/Contents/Resources/$(basename "$bundle")"
    done
    if [[ -d "$CALLHOST_BIN/whisper.framework" ]]; then
      ditto "$CALLHOST_BIN/whisper.framework" "$CALLHOST_APP/Contents/Frameworks/whisper.framework"
      install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$CALLHOST_APP/Contents/MacOS/CallaCallHost" 2>/dev/null || true
      # Strip headers and module maps before sealing. They are build-time only,
      # and something downstream removes them from an embedded framework — so a
      # signature that seals them verifies as "a sealed resource is missing or
      # invalid" against the enclosing engine bundle, not against this one.
      # Removing them first makes the seal match what actually ships.
      EMBEDDED_WHISPER="$CALLHOST_APP/Contents/Frameworks/whisper.framework"
      /bin/rm -rf "$EMBEDDED_WHISPER/Versions/A/Headers" "$EMBEDDED_WHISPER/Versions/A/Modules" \
        "$EMBEDDED_WHISPER/Headers" "$EMBEDDED_WHISPER/Modules" \
        "$EMBEDDED_WHISPER/Versions/A/_CodeSignature"
      if [[ "$SIGN_CALLA_RUNTIME" == "1" ]]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$EMBEDDED_WHISPER"
      fi
    fi
    chmod 700 "$CALLHOST_APP/Contents/MacOS/CallaCallHost"
    if [[ "$SIGN_CALLA_RUNTIME" == "1" ]]; then
      codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$CALLHOST_APP"
    fi
  else
    echo "missing CallaCallHost executable" >&2
    exit 78
  fi
fi

# This phase stages bytes into the engine's own Resources, which invalidates
# whatever seal covers that bundle. On a full build Xcode's implicit CodeSign
# step runs after every build phase and re-seals it anyway; but this phase is
# `alwaysOutOfDate`, so on an incremental build where Xcode considers the
# target up to date it runs and that CodeSign step does not. Re-seal here to
# cover that case, or the next deployment fails its own verification with
# "a sealed resource is missing or invalid".
#
# Pass --entitlements explicitly. A bare `codesign --force --sign` drops the
# entitlements Xcode applied, and whichever of the two signatures lands last
# must still carry them.
ENTITLEMENTS="$ROOT/BoringCallaEngine/BoringCallaEngine.entitlements"
if [[ "$SIGN_CALLA_RUNTIME" == "1" && -n "${CODESIGNING_FOLDER_PATH:-}" && -d "${CODESIGNING_FOLDER_PATH}" ]]; then
  if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
      --entitlements "$ENTITLEMENTS" "$CODESIGNING_FOLDER_PATH"
  else
    echo "missing engine entitlements at $ENTITLEMENTS" >&2
    exit 78
  fi
fi
