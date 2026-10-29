#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MIN_MACOS=26.0
# Never pin an SDK version. xcrun names the SDK shipped by the active toolchain.
SDK="$(xcrun --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
CODESIGN="$(xcrun --find codesign)"
# macOS ties the Bluetooth permission to the signature, so ad-hoc builds are asked again
# after every rebuild; a stable identity avoids that.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "signing identity: $CODESIGN_IDENTITY"
APP="$ROOT/dist/XM6-Connect.app"
WIDGET="$APP/Contents/PlugIns/XM6ConnectWidget.appex"
AGENT="$APP/Contents/MacOS/XM6ConnectAgent"

[[ -d "$SDK" ]] || { echo "error: no macOS SDK found at $SDK" >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS"
cp "$ROOT/Sources/XM6ConnectApp/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/XM6ConnectWidget/Info.plist" "$WIDGET/Contents/Info.plist"
for plist in "$APP/Contents/Info.plist" "$WIDGET/Contents/Info.plist"; do
  version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"
  [[ "$version" == "$MIN_MACOS" ]] || { echo "error: $plist LSMinimumSystemVersion is $version, expected $MIN_MACOS" >&2; exit 1; }
done
cp -R "$ROOT/THIRD_PARTY/"* "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
if [[ -f "$ROOT/Resources/XM6Connect.icns" ]]; then
  cp "$ROOT/Resources/XM6Connect.icns" "$APP/Contents/Resources/XM6Connect.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string XM6Connect.icns' "$APP/Contents/Info.plist" 2>/dev/null || true
fi
plutil -lint "$APP/Contents/Info.plist" "$WIDGET/Contents/Info.plist"

COMMON=( -sdk "$SDK" -target "arm64-apple-macos$MIN_MACOS" -swift-version 5 )
"$SWIFTC" "${COMMON[@]}" -framework AppKit \
  -framework SwiftUI \
  "$ROOT/Sources/SonyHeadphonesKit/Models/EqualizerPreset.swift" \
  "$ROOT/Sources/SonyHeadphonesKit/Models/ListeningMode.swift" \
  "$ROOT/Sources/XM6ConnectApp/PopoverModel.swift" \
  "$ROOT/Sources/XM6ConnectApp/AgentLifecycle.swift" \
  "$ROOT/Sources/XM6ConnectApp/AppDelegate.swift" \
  "$ROOT/Sources/XM6ConnectApp/PopoverView.swift" \
  "$ROOT/Sources/XM6ConnectApp/XM6ConnectApp.swift" -o "$APP/Contents/MacOS/XM6Connect"

# Build the resident daemon with SwiftPM so its shared core and IOBluetooth
# linkage stay identical to the tested executable target.
swift build -c release --product XM6ConnectAgent
cp "$ROOT/.build/release/XM6ConnectAgent" "$AGENT"
chmod 755 "$AGENT"
# An app extension MUST enter through NSExtensionMain, not a plain main: that entry
# point is what establishes the extension context ExtensionFoundation reads. Without
# it the process dies at bootstrap with "Unrecognized extension type", chronod's
# descriptor query fails, and the widget/control never appear in the gallery even
# though pluginkit happily lists them (Apple's own widget
# appexes import _NSExtensionMain, ours did not). Xcode sets this for appex targets.
"$SWIFTC" "${COMMON[@]}" -parse-as-library \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -framework AppIntents -framework CoreFoundation -framework SwiftUI -framework WidgetKit \
  "$ROOT/Sources/SonyHeadphonesKit/Models/EqualizerPreset.swift" \
  "$ROOT/Sources/XM6ConnectWidget/WidgetLogic.swift" \
  "$ROOT/Sources/XM6ConnectWidget/XM6ConnectDesktopWidget.swift" \
  -o "$WIDGET/Contents/MacOS/XM6ConnectWidget"

# Fail the build rather than ship an extension that cannot bootstrap. This exact
# regression shipped once: pluginkit listed the extension, so it LOOKED registered,
# while every load crashed and neither the widget nor the Control Center control
# could ever appear.
# Read the symbols once and classify the two failures separately. The old form
# (`nm ... | grep -q`) reported "missing entry point" whenever `nm` ITSELF failed, so a
# transient read of the just-linked binary looked like a hard defect — it fired twice on
# binaries that provably contained _NSExtensionMain, and a plain rebuild "fixed" it.
# The guard must distinguish a symbol-read failure from a missing entry point.
if ! WIDGET_SYMS="$(nm -m "$WIDGET/Contents/MacOS/XM6ConnectWidget" 2>&1)"; then
  echo "error: could not read widget symbols (nm failed): $WIDGET_SYMS" >&2
  exit 1
fi
case "$WIDGET_SYMS" in
  *_NSExtensionMain*) ;;
  *)
    echo "error: widget extension is missing the NSExtensionMain entry point" >&2
    exit 1
    ;;
esac

# The extension requires the sandbox entitlement for pkd discovery on this
# machine.  The host is intentionally not sandboxed so L4 can reach the agent.
# The resident agent is a separate Mach-O in Contents/MacOS; signing the app bundle does
# not re-sign it, so without this it keeps an ad-hoc signature whose cdhash changes on every
# build. It is the process that actually touches Bluetooth, so it must be stable too.
"$CODESIGN" --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$AGENT"
"$CODESIGN" --force --sign "$CODESIGN_IDENTITY" --timestamp=none \
  --entitlements "$ROOT/Sources/XM6ConnectWidget/entitlements.plist" "$WIDGET"
# Keep this assertion next to signing: without the sandbox entitlement pluginkit
# does not list this extension on the CLT-only test machine.
if ! "$CODESIGN" -d --entitlements :- "$WIDGET" 2>/dev/null \
  | grep -q '<key>com.apple.security.app-sandbox</key><true/>'; then
  echo "error: widget extension is missing com.apple.security.app-sandbox" >&2
  exit 1
fi
"$CODESIGN" --force --sign "$CODESIGN_IDENTITY" --timestamp=none \
  --entitlements "$ROOT/Sources/XM6ConnectApp/entitlements.plist" "$APP"
SIGNED_WIDGET_ENTITLEMENTS="$(mktemp -t xm6connect-widget-entitlements)"
SIGNED_HOST_ENTITLEMENTS="$(mktemp -t xm6connect-host-entitlements)"
trap 'rm -f "$SIGNED_WIDGET_ENTITLEMENTS" "$SIGNED_HOST_ENTITLEMENTS"' EXIT
"$CODESIGN" -d --entitlements :- "$WIDGET" 2>&1 | sed -n '/<?xml/,$p' >"$SIGNED_WIDGET_ENTITLEMENTS"
"$CODESIGN" -d --entitlements :- "$APP" 2>&1 | sed -n '/<?xml/,$p' >"$SIGNED_HOST_ENTITLEMENTS"
WIDGET_READ_ONLY_PATH="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.files.home-relative-path.read-only:0' "$SIGNED_WIDGET_ENTITLEMENTS" 2>/dev/null || true)"
WIDGET_SECOND_READ_ONLY_PATH="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.files.home-relative-path.read-only:1' "$SIGNED_WIDGET_ENTITLEMENTS" 2>/dev/null || true)"
if [[ "$WIDGET_READ_ONLY_PATH" != "/Library/Application Support/XM6Connect/" || -n "$WIDGET_SECOND_READ_ONLY_PATH" ]]; then
  echo "error: widget extension must carry exactly one read-only XM6Connect support-directory exception" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$SIGNED_WIDGET_ENTITLEMENTS" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$SIGNED_HOST_ENTITLEMENTS" >/dev/null 2>&1; then
  echo "error: signed widget and host must not carry com.apple.security.application-groups" >&2
  exit 1
fi
"$CODESIGN" --verify --deep --strict "$APP"
echo "Build complete: $APP"
