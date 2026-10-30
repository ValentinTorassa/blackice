#!/bin/bash
# Short real Linux take. Run only after the owner installs the matching reviewed helper.
# Usage: bash src/linux/recording.sh BLACKICE_ABSOLUTE_PATH CLI_SHA256 HELPER_SHA256
set -euo pipefail
[[ $# -eq 3 && $1 == /* && $2 =~ ^[0-9a-f]{64}$ && $3 =~ ^[0-9a-f]{64}$ ]] || {
    echo 'Usage: recording.sh BLACKICE_ABSOLUTE_PATH CLI_SHA256 HELPER_SHA256' >&2
    exit 2
}
blackice=$1
expected_cli=$2
expected_helper=$3
helper=/usr/local/libexec/blackice-linux-helper
[[ -r "$blackice" && -r "$helper" ]] || { echo 'NOT RUN: missing launcher or installed helper.' >&2; exit 2; }
cli_hash=$(/usr/bin/sha256sum "$blackice")
helper_hash=$(/usr/bin/sha256sum "$helper")
[[ ${cli_hash%% *} == "$expected_cli" && ${helper_hash%% *} == "$expected_helper" ]] || {
    echo 'NOT RUN: launcher/helper hash differs from the selected reviewed build.' >&2
    exit 2
}
printf 'blackice SHA-256: %s\n' "${cli_hash%% *}"
shot_dir=$(/usr/bin/mktemp -d /tmp/bi-shot-XXXXXX)
export XDG_STATE_HOME="$shot_dir/state"
/usr/bin/mkdir -m 0700 "$XDG_STATE_HOME"
cd "$shot_dir"
/usr/bin/cat > agent.json <<'JSON'
{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["example.com"]}}
JSON
/usr/bin/cat > probe.sh <<'SH'
set -u
printf 'example.com through the proxy:\n'
allowed=$(/usr/bin/curl -sS --connect-timeout 4 --max-time 6 -o /dev/null -w '%{http_code}' https://example.com)
allowed_status=$?
printf 'HTTP %s\n\n' "$allowed"
printf 'github.com through the proxy:\n'
refused=$(/usr/bin/curl -sS --connect-timeout 3 --max-time 4 -o /dev/null -w '%{http_connect}' https://github.com)
refused_status=$?
printf 'CONNECT %s; curl exit %s\n\n' "$refused" "$refused_status"
printf '1.1.1.1 directly, bypassing the proxy:\n'
/usr/bin/curl -sS --noproxy '*' --connect-timeout 3 --max-time 4 -o /dev/null https://1.1.1.1
direct_status=$?
printf 'curl exit %s\n' "$direct_status"
[[ $allowed_status -eq 0 && $allowed =~ ^[23][0-9][0-9]$ && $refused_status -ne 0 && $refused == 403 && $direct_status -eq 7 ]]
SH
echo '$ blackice run --policy agent.json -- bash probe.sh'
"$blackice" run --policy "$shot_dir/agent.json" -- /bin/bash "$shot_dir/probe.sh" 2>&1 | /usr/bin/tee "$shot_dir/take.log"
receipt=$(/usr/bin/python3 -I - "$XDG_STATE_HOME" <<'PY'
import json, sys
from pathlib import Path
logs = list(Path(sys.argv[1]).glob('blackice/scopes/*/receipts.jsonl'))
assert len(logs) == 1, logs
rows = [json.loads(line) for line in logs[0].read_text().splitlines()]
assert rows[-1]['event'] == 'scope_end', rows
assert any(r.get('point') == 'proxy' and r.get('host') == 'example.com' and r.get('verdict') == 'allow' for r in rows), rows
assert any(r.get('point') == 'proxy' and r.get('host') == 'github.com' and r.get('verdict') == 'deny' for r in rows), rows
assert any(r.get('event') == 'kernel_drop' and r.get('point') == 'kernel' and r.get('ip') == '1.1.1.1' and r.get('port') == 443 for r in rows), rows
print(logs[0])
PY
)
echo '$ tail -n 6 receipts.jsonl'
/usr/bin/tail -n 6 "$receipt"
printf '\nSaved actual output and receipts: %s\n' "$shot_dir"
