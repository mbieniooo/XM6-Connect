#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/XM6-Connect.app"
DEST="$HOME/Applications/XM6-Connect.app"

# Do not touch an installed identity, data, or launchd service until the candidate
# has passed its gates. A failed build used to delete the only working migration.
bash "$ROOT/scripts/run_tests.sh"
bash "$ROOT/scripts/build_app.sh"

AGENT_LABEL="io.github.mbieniooo.xm6connect.agent"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOGIN_PLIST="$HOME/Library/LaunchAgents/io.github.mbieniooo.xm6connect.login.plist"
PLIST_DIR="$(mktemp -d -t xm6connect-plists)"
trap 'rm -rf "$PLIST_DIR"' EXIT
"$APP/Contents/MacOS/XM6Connect" --print-agent-plist "$DEST" > "$PLIST_DIR/agent.plist"
"$APP/Contents/MacOS/XM6Connect" --print-login-plist "$DEST" > "$PLIST_DIR/login.plist"
[[ "$(plutil -extract Label raw -o - "$PLIST_DIR/agent.plist")" == "io.github.mbieniooo.xm6connect.agent" ]] || { echo "error: generated agent plist is wrong" >&2; exit 1; }
[[ "$(plutil -extract ProgramArguments raw -o - "$PLIST_DIR/agent.plist")" == "1" ]] || { echo "error: generated agent plist is wrong" >&2; exit 1; }
[[ "$(plutil -extract ProgramArguments.0 raw -o - "$PLIST_DIR/agent.plist")" == "$DEST/Contents/MacOS/XM6ConnectAgent" ]] || { echo "error: generated agent plist is wrong" >&2; exit 1; }
[[ "$(plutil -extract Label raw -o - "$PLIST_DIR/login.plist")" == "io.github.mbieniooo.xm6connect.login" ]] || { echo "error: generated login plist is wrong" >&2; exit 1; }
[[ "$(plutil -extract ProgramArguments raw -o - "$PLIST_DIR/login.plist")" == "3" ]] || { echo "error: generated login plist is wrong" >&2; exit 1; }
[[ "$(plutil -extract ProgramArguments.0 raw -o - "$PLIST_DIR/login.plist")" == "/usr/bin/open" ]] || { echo "error: generated login plist is wrong" >&2; exit 1; }
[[ "$(plutil -extract ProgramArguments.1 raw -o - "$PLIST_DIR/login.plist")" == "-g" ]] || { echo "error: generated login plist is wrong" >&2; exit 1; }
[[ "$(plutil -extract ProgramArguments.2 raw -o - "$PLIST_DIR/login.plist")" == "$DEST" ]] || { echo "error: generated login plist is wrong" >&2; exit 1; }
plutil -lint "$PLIST_DIR/agent.plist"
plutil -lint "$PLIST_DIR/login.plist"

pkill -x XM6Connect 2>/dev/null || true
for _ in {1..20}; do
  pgrep -x XM6Connect >/dev/null || break
  sleep 0.1
done

# Boot the agent OUT before replacing the bundle it runs from: replacing it while
# launchd KeepAlive is live produces an EX_CONFIG spawn failure in the gap and a
# throttled service afterwards.
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
pkill -x XM6ConnectAgent 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$DEST"
# A macOS upgrade rebuilds the pluginkit database and silently drops app extensions
# outside /Applications. A macOS upgrade can remove the widget and the
# Control Center control were gone from the gallery while the bundle, its signature
# and lsregister were all still fine; `pluginkit -a` is what brought them back.
pluginkit -a "$DEST/Contents/PlugIns/XM6ConnectWidget.appex" || true
# A running widget extension keeps executing the binary it was launched from. Stop it
# so WidgetKit relaunches it from the bundle just installed.
pkill -x XM6ConnectWidget 2>/dev/null || true

# Classic user LaunchAgent for boot persistence. SMAppService silently refuses
# ad-hoc-signed apps (config accepted, never surfaced or bootstrapped —
# so the plist is installed and bootstrapped here.
mkdir -p "$HOME/Library/LaunchAgents"
mv -f "$PLIST_DIR/agent.plist" "$AGENT_PLIST"
mv -f "$PLIST_DIR/login.plist" "$LOGIN_PLIST"
if ! launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"; then
  echo "error: launchctl bootstrap failed for $AGENT_PLIST" >&2
  exit 1
fi
if ! launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null; then
  echo "error: launchd did not load $AGENT_LABEL after bootstrap" >&2
  exit 1
fi

open "$DEST"
