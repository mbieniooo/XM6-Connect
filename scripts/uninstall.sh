#!/usr/bin/env bash
set -euo pipefail
APP="$HOME/Applications/XM6-Connect.app"
if [[ -x "$APP/Contents/MacOS/XM6Connect" ]]; then
  "$APP/Contents/MacOS/XM6Connect" --unregister-agent || true
fi
pkill -x XM6Connect 2>/dev/null || true
for _ in {1..20}; do
  pgrep -x XM6Connect >/dev/null || break
  sleep 0.1
done
AGENT_LABEL="io.github.mbieniooo.xm6connect.agent"
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOGIN_LABEL="io.github.mbieniooo.xm6connect.login"
launchctl bootout "gui/$(id -u)/$LOGIN_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LOGIN_LABEL.plist"
pkill -x XM6ConnectAgent 2>/dev/null || true
pkill -x XM6ConnectWidget 2>/dev/null || true
rm -rf "$APP"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/Library/Application Support/XM6Connect"
else
  printf '%s\n' 'Kept ~/Library/Application Support/XM6Connect. Re-run with --purge to remove it.'
fi
