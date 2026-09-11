#!/usr/bin/env bash
# Install only Boring-owned local Calla runtime labels. Legacy plists/data stay.
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/boringNotch/Calla"
SOCKET_DIRECTORY="$APP_SUPPORT"
APP="/Applications/boringNotch.app"
NODE_LABEL="theboringteam.boringnotch.calla-node"
RUNTIME_LABEL="theboringteam.boringnotch.calla-runtime"
AGENT_DIRECTORY="$HOME/Library/LaunchAgents"
LAUNCH_RUNTIME="${CALLA_RUNTIME_LAUNCH:-1}"
mkdir -p "$SOCKET_DIRECTORY" "$APP_SUPPORT/logs"
chmod 700 "$SOCKET_DIRECTORY" "$APP_SUPPORT/logs"
[[ -x "$APP/Contents/MacOS/boringNotch" ]] || { echo "Boring Notch is not installed at $APP" >&2; exit 78; }

mkdir -p "$AGENT_DIRECTORY"

# Engine is embedded XPC, launched and held by Boring app. This label restores
# Boring after login without reintroducing a separate visible TutorHost app.
cat >"$AGENT_DIRECTORY/$RUNTIME_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$RUNTIME_LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-gj</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$APP_SUPPORT/logs/runtime.log</string>
  <key>StandardErrorPath</key><string>$APP_SUPPORT/logs/runtime.log</string>
</dict></plist>
EOF
chmod 600 "$AGENT_DIRECTORY/$RUNTIME_LABEL.plist"

GUI_DOMAIN="gui/$(id -u)"

# Retire every known local OpenClaw node label. Disable before bootout because
# old node jobs used KeepAlive. Boring now uses Gateway-only OpenClaw over SSH.
for label in com.calla.tutor-host com.calla.openclaw-node-host "$NODE_LABEL"; do
  launchctl disable "$GUI_DOMAIN/$label" 2>/dev/null || true
  launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
done
rm -f "$AGENT_DIRECTORY/$NODE_LABEL.plist" "$AGENT_DIRECTORY/com.calla.openclaw-node-host.plist"

# Boring's own restore label must be explicitly enabled first: `bootstrap`
# against a label sitting in the disabled database succeeds and loads nothing,
# which would leave Boring not restoring after login with no error to show.
launchctl enable "$GUI_DOMAIN/$RUNTIME_LABEL" 2>/dev/null || true
launchctl bootout "$GUI_DOMAIN/$RUNTIME_LABEL" 2>/dev/null || true

if [[ "$LAUNCH_RUNTIME" == 1 ]]; then
  launchctl bootstrap "$GUI_DOMAIN" "$AGENT_DIRECTORY/$RUNTIME_LABEL.plist"
fi

echo "Boring Calla runtime installed: $APP_SUPPORT (Gateway-only OpenClaw)"
