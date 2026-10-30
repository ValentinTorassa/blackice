#!/bin/bash
# Tests parsing and evidence classification only. Never starts the app/window.
set -euo pipefail
PROBE_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Run probe tests on macOS with Command Line Tools.' >&2
    exit 1
fi
if [[ $# -gt 1 ]]; then echo 'usage: macos/test-probe.sh [output-directory]' >&2; exit 1; fi
PROBE_TEST_DIR="${1:-$PROBE_SOURCE_DIR/build/probe-tests}"
mkdir -p "$PROBE_TEST_DIR/module-cache"
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macosx13.0" -swift-version 5 -warnings-as-errors \
    -module-cache-path "$PROBE_TEST_DIR/module-cache" \
    "$PROBE_SOURCE_DIR/Probe/ProbeModel.swift" "$PROBE_SOURCE_DIR/ProbeTests/main.swift" \
    -framework Foundation -o "$PROBE_TEST_DIR/probe-tests"
"$PROBE_TEST_DIR/probe-tests"
