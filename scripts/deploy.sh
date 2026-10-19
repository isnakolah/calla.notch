#!/usr/bin/env bash
#
# deploy.sh — build callaNotch and install it to /Applications.
#
# Deploys DEBUG by default. Debug uses persistent local `Calla Local Signing`
# identity for app and XPC helper, keeping TCC grants stable across local
# rebuilds. Current private Release builds use that same local identity and
# disable hardened runtime: it cannot load Calla's locally signed OpenSSL
# framework under library validation. Restore Developer ID signing and hardened
# runtime together before any external distribution.
#
# Usage:
#   scripts/deploy.sh                 # build Debug, install, relaunch
#   scripts/deploy.sh --config Release
#   scripts/deploy.sh --no-launch     # install but don't relaunch
#   scripts/deploy.sh --skip-build    # reuse the last build product
#   scripts/deploy.sh --allow-signing-change
#                                  # replace app even if TCC identity changes
#
set -euo pipefail

CONFIG="Debug"
LAUNCH=1
BUILD=1
ALLOW_SIGNING_CHANGE=0
STAGING_DIR=""

cleanup() {
  [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]] && rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    --skip-build) BUILD=0; shift ;;
    --allow-signing-change) ALLOW_SIGNING_CHANGE=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="callaNotch"
APP_NAME="calla.notch.app"
DEST="/Applications/$APP_NAME"
HELPER_RELATIVE_PATH="Contents/XPCServices/CallaNotchXPCHelper.xpc"
CALLA_ENGINE_RELATIVE_PATH="Contents/XPCServices/CallaEngine.xpc"
APP_BUNDLE_ID="org.calla.notch"
HELPER_BUNDLE_ID="org.calla.notch.CallaNotchXPCHelper"
CALLA_ENGINE_BUNDLE_ID="org.calla.notch.CallaEngine"

bundle_identifier() {
  codesign -d --verbose=2 "$1" 2>&1 | sed -n 's/^Identifier=//p'
}

designated_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

verify_signed_bundle() {
  local bundle="$1"
  local expected_identifier="$2"
  local actual_identifier

  codesign --verify --deep --strict "$bundle"
  actual_identifier="$(bundle_identifier "$bundle")"
  if [[ "$actual_identifier" != "$expected_identifier" ]]; then
    echo "✗ Unexpected bundle identifier for $bundle: $actual_identifier" >&2
    exit 1
  fi
}

verify_tcc_identity() {
  local source="$1"
  local installed="$2"
  local source_requirement installed_requirement

  source_requirement="$(designated_requirement "$source")"
  installed_requirement="$(designated_requirement "$installed")"
  if [[ -z "$source_requirement" || -z "$installed_requirement" ]]; then
    echo "✗ Could not read code-signing designated requirement" >&2
    exit 1
  fi
  if [[ "$source_requirement" != "$installed_requirement" && "$ALLOW_SIGNING_CHANGE" != 1 ]]; then
    cat >&2 <<EOF
✗ Signing identity changed. Refusing deployment because macOS privacy grants,
  including Calendar and Accessibility, are tied to this designated requirement.
  Rebuild with the existing signing identity, or rerun with --allow-signing-change
  only if reauthorizing those permissions is intended.
EOF
    exit 1
  fi
}

echo "▸ Config: $CONFIG"

if [[ "$BUILD" == 1 ]]; then
  echo "▸ Building $SCHEME ($CONFIG)…"
  BUILD_LOG="$(mktemp -t callaNotch-build.XXXXXX)"
  if ! xcodebuild -project callaNotch.xcodeproj -scheme "$SCHEME" \
    -configuration "$CONFIG" build >"$BUILD_LOG" 2>&1; then
    grep -nE "error:|BUILD FAILED" "$BUILD_LOG" >&2 || tail -80 "$BUILD_LOG" >&2
    rm -f "$BUILD_LOG"
    exit 1
  fi
  grep -m1 "BUILD SUCCEEDED" "$BUILD_LOG" || true
  rm -f "$BUILD_LOG"
fi

# Locate the built .app in DerivedData. Multiple DerivedData directories can
# coexist — including ones belonging to *other checkouts* of this project, whose
# products may be newer but unsigned. Match on the recorded WorkspacePath so we
# only ever deploy a product built from this working copy.
SRC=""
for derived_dir in "$HOME/Library/Developer/Xcode/DerivedData"/callaNotch-*; do
  [[ -d "$derived_dir" ]] || continue
  workspace_path="$(plutil -extract WorkspacePath raw -o - "$derived_dir/info.plist" 2>/dev/null || true)"
  [[ "$workspace_path" == "$PROJECT_DIR/callaNotch.xcodeproj" ]] || continue
  candidate="$derived_dir/Build/Products/$CONFIG/$APP_NAME"
  [[ -d "$candidate" ]] || continue
  if [[ -z "$SRC" || "$candidate" -nt "$SRC" ]]; then
    SRC="$candidate"
  fi
done
if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "✗ Could not find built $APP_NAME for $CONFIG" >&2
  exit 1
fi
echo "▸ Source: $SRC"

verify_signed_bundle "$SRC" "$APP_BUNDLE_ID"
verify_signed_bundle "$SRC/$HELPER_RELATIVE_PATH" "$HELPER_BUNDLE_ID"
verify_signed_bundle "$SRC/$CALLA_ENGINE_RELATIVE_PATH" "$CALLA_ENGINE_BUNDLE_ID"
for required_resource in Calla/scripts Calla/Gateway; do
  [[ -d "$SRC/Contents/Resources/$required_resource" ]] || { echo "✗ Missing embedded Calla resource: $required_resource" >&2; exit 1; }
done
for required_file in \
  Contents/Resources/Calla/scripts/gateway-update.sh \
  Contents/Resources/Calla/Gateway/calla-gateway.tar.gz \
  Contents/XPCServices/CallaEngine.xpc/Contents/Resources/CallaRuntime/CallaCallHost.app/Contents/MacOS/CallaCallHost \
  Contents/XPCServices/CallaEngine.xpc/Contents/Resources/CallaRuntime/CallaCallHost.app/Contents/Info.plist; do
  [[ -x "$SRC/$required_file" || -f "$SRC/$required_file" ]] || { echo "✗ Missing embedded Calla file: $required_file" >&2; exit 1; }
done
# Tutor was removed. A stale incremental build must not ship its host.
for stale_file in \
  Contents/XPCServices/CallaEngine.xpc/Contents/Resources/CallaRuntime/CallaTutorHost.app \
  Contents/XPCServices/CallaEngine.xpc/Contents/Resources/CallaRuntime/CallaTutorHost \
  Contents/XPCServices/CallaEngine.xpc/Contents/Resources/CallaRuntime/CallaOverlayHelper; do
  [[ ! -e "$SRC/$stale_file" ]] || { echo "✗ Removed Tutor component still in build: $stale_file" >&2; exit 1; }
done
tar -tzf "$SRC/Contents/Resources/Calla/Gateway/calla-gateway.tar.gz" | grep -qx 'release/manifest.json' \
  || { echo "✗ Embedded Calla Gateway archive lacks release manifest" >&2; exit 1; }
for forbidden_file in \
  Contents/Resources/Calla/openclaw \
  Contents/Resources/Calla/packs \
  Contents/Resources/Calla/agent-workspace \
  Contents/Resources/Calla/scripts/calla-node-host.sh \
  Contents/Resources/Calla/scripts/bootstrap-calla-mac.sh \
  Contents/Resources/Calla/scripts/setup-macos.sh \
  Contents/XPCServices/CallaEngine.xpc/Contents/Resources/CallaRuntime/scripts/bootstrap-calla-mac.sh; do
  [[ ! -e "$SRC/$forbidden_file" ]] || { echo "✗ Retired Tutor bootstrap leaked into Calla: $forbidden_file" >&2; exit 1; }
done

if [[ -d "$DEST" ]]; then
  verify_signed_bundle "$DEST" "$APP_BUNDLE_ID"
  verify_signed_bundle "$DEST/$HELPER_RELATIVE_PATH" "$HELPER_BUNDLE_ID"
  verify_tcc_identity "$SRC" "$DEST"
  verify_tcc_identity "$SRC/$HELPER_RELATIVE_PATH" "$DEST/$HELPER_RELATIVE_PATH"
  if [[ -d "$DEST/$CALLA_ENGINE_RELATIVE_PATH" ]]; then
    verify_signed_bundle "$DEST/$CALLA_ENGINE_RELATIVE_PATH" "$CALLA_ENGINE_BUNDLE_ID"
    verify_tcc_identity "$SRC/$CALLA_ENGINE_RELATIVE_PATH" "$DEST/$CALLA_ENGINE_RELATIVE_PATH"
  else
    echo "▸ Existing Calla install predates Calla engine; adding new XPC service."
  fi
fi

echo "▸ Quitting running app…"
osascript -e 'quit app id "org.calla.notch"' 2>/dev/null || true
sleep 1
pkill -f "$DEST" 2>/dev/null || true
sleep 1

echo "▸ Installing to ${DEST}…"
STAGING_DIR="$(mktemp -d /Applications/.callaNotch-deploy.XXXXXX)"
STAGED_APP="$STAGING_DIR/$APP_NAME"
BACKUP_APP="$STAGING_DIR/previous-$APP_NAME"
ditto "$SRC" "$STAGED_APP"
verify_signed_bundle "$STAGED_APP" "$APP_BUNDLE_ID"
verify_signed_bundle "$STAGED_APP/$HELPER_RELATIVE_PATH" "$HELPER_BUNDLE_ID"
verify_signed_bundle "$STAGED_APP/$CALLA_ENGINE_RELATIVE_PATH" "$CALLA_ENGINE_BUNDLE_ID"

if [[ -d "$DEST" ]]; then
  mv "$DEST" "$BACKUP_APP"
fi
if ! mv "$STAGED_APP" "$DEST"; then
  [[ -d "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$DEST"
  echo "✗ Install failed; restored previous app bundle." >&2
  exit 1
fi

[[ -d "$DEST/Contents/XPCServices/CallaNotchXPCHelper.xpc" ]] \
  && echo "  ✓ XPC helper embedded" \
  || echo "  ⚠ XPC helper NOT found"
[[ -d "$DEST/Contents/XPCServices/CallaEngine.xpc" ]] \
  && echo "  ✓ Calla engine embedded" \
  || { echo "  ✗ Calla engine NOT found" >&2; exit 1; }

# Prepare Quiz device-only Keychain material from ordinary signed Engine
# process. The embedded Engine also joins the app's security session so normal
# first launch can request Keychain approval without requiring this script.
QUIZ_KEY_PREPARER="$DEST/$CALLA_ENGINE_RELATIVE_PATH/Contents/MacOS/CallaEngine"
# Migration must precede every key preparer or runtime launch: otherwise a
# fresh key could make retained history unreadable.
if ! "$QUIZ_KEY_PREPARER" --migrate-branding; then
  echo "  ✗ Existing data could not be migrated; original data is preserved." >&2
  exit 1
fi
if ! "$QUIZ_KEY_PREPARER" --prepare-quiz-key; then
  echo "  ✗ Quiz encryption key preparation failed" >&2
  exit 1
fi
echo "  ✓ Quiz encryption key ready"

# Calla owns local TutorHost launch labels; OpenClaw stays on Gateway. Runtime
# install disables/removes known local node jobs after new bundle is verified.
echo "▸ Installing calla.notch local runtime…"
CALLA_RUNTIME_LAUNCH="$LAUNCH" /bin/bash "$PROJECT_DIR/scripts/calla/runtime-install.sh"

if [[ "$LAUNCH" == 1 ]]; then
  echo "▸ Launching…"
  open -a "$DEST"
  for _ in {1..15}; do
    if pgrep -f "$DEST/Contents/MacOS/callaNotch" >/dev/null; then
      echo "  ✓ running"
      break
    fi
    sleep 1
  done
  if ! pgrep -f "$DEST/Contents/MacOS/callaNotch" >/dev/null; then
    echo "  ✗ not running — check ~/Library/Logs/DiagnosticReports/callaNotch-*.ips" >&2
    exit 1
  fi
fi

echo "✓ Deployed."
