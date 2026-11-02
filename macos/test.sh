#!/bin/bash
# swift test with warnings as errors. The Swift Testing macro plugin is passed explicitly:
# the Command Line Tools' default build system (Swift 6.4) sometimes leaves it out of the
# test build, and the tests then fail to compile at random.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
PLUGINS="$(dirname -- "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
extra=()
if [[ -d "$PLUGINS" ]]; then extra=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS"); fi
exec swift test -Xswiftc -warnings-as-errors ${extra[@]+"${extra[@]}"} "$@"
