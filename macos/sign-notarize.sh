#!/bin/bash
# Manual release operation. Requires an enrolled team and security-reviewed inputs.
# Not called by build.sh or test.sh. Never installs or activates the extension.
set -euo pipefail
SIGNING_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3 -I "$SIGNING_SOURCE_DIR/Signing/sign_notarize.py" "$@"
