#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

swift build -c debug
# The test harness imports XM6ConnectAgentCore; these two explicit builds keep both public
# executable entry points covered even if SwiftPM's default build selection changes.
swift build -c debug --target XM6ConnectAgent
swift build -c debug --target xm6ctl
.build/debug/KitTests
