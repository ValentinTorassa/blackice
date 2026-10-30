#!/usr/bin/env bash
# blackice L0 fallback end to end: an unmodified fx runs entirely inside one task scope and reaches its model
# only through the scope's relay.
#
# THE MODEL IS SCRIPTED. blackice-test/scripted (src/relay/fake_model.zig) is a test model on loopback that
# answers with fixed shell commands and then a summary that says it is scripted. It is not a real model,
# and nothing here is a demo of one. The relay gets a SYNTHETIC key from a file on stdin; no provider is
# contacted and no credential is read.
#
#   fake model (outside, 127.0.0.1:<port>)  <-  relay (outside, synthetic key)  <-  fx (inside the scope)
#
# Inside the scope a small sh wrapper writes $HOME/.fx/settings.json in an isolated HOME (provider base_url =
# $BLACKICE_RELAY_URL, auth bearer from env BLACKICE_RELAY_TOKEN) and then execs `fx ask`. fx runs the
# scripted commands with its shell tool, so they run inside the scope too.
#
# Usage: FX=/path/to/fx scripts/e2e/fx-l0.sh
#   FX          fx v0.0.16 binary (required)
#   BLACKICE    blackice binary (default: zig-out/bin/blackice)
#   FAKE_MODEL  a built fake_model binary (default: built here with zig from src/relay/fake_model.zig)
#   E2E_DIR     an empty working directory to use (default: a new one under $TMPDIR)
set -u
. "$(dirname "$0")/lib.sh"

MODEL=blackice-test/scripted
SCRIPTED_NOTICE="MODEL: $MODEL is a SCRIPTED TEST MODEL (src/relay/fake_model.zig), not a real model. Synthetic key, no provider."

command -v python3 > /dev/null || die "python3 is needed (receipt and log checks)"
[ -n "${FX:-}" ] && [ -x "$FX" ] || die "set FX=/path/to/fx (fx v0.0.16)"
e2e_blackice
FX=$(cd "$(dirname "$FX")" && pwd -P)/$(basename "$FX")
e2e_workdir
e2e_policy

case "$(uname -s)" in
    Darwin) echo "== macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), SIP: $(csrutil status 2> /dev/null | sed 's/.*: //')" ;;
    Linux) . /etc/os-release 2> /dev/null; echo "== Linux $(uname -r) ($(uname -m)), ${PRETTY_NAME:-unknown distribution}" ;;
    *) die "this script is for Linux and macOS" ;;
esac
echo "== $("$B" version); fx $("$FX" --version 2>&1 | head -1)"
echo "== $SCRIPTED_NOTICE"
echo "== work dir $W"

# The backend must start a scope here; otherwise nothing below means anything.
scoped probe -- /bin/true
[ "$RC" -eq 0 ] && [ -n "$SID" ] || die "blackice run could not start a scope here (exit $RC); see $ERR"

# The scripted model, outside the scope.
if [ -n "${FAKE_MODEL:-}" ]; then
    [ -x "$FAKE_MODEL" ] || die "FAKE_MODEL=$FAKE_MODEL is not executable"
else
    command -v zig > /dev/null || die "zig is needed to build the scripted model (or set FAKE_MODEL)"
    FAKE_MODEL="$W/fake-model"
    zig build-exe -O ReleaseSafe --cache-dir "$W/.zig-cache" -femit-bin="$FAKE_MODEL" \
        "$E2E_REPO/src/relay/fake_model.zig" > "$W/out/fake-model-build.txt" 2>&1 ||
        { cat "$W/out/fake-model-build.txt"; die "could not build the scripted model"; }
fi
"$FAKE_MODEL" 0 --log "$W/model.log" \
    --step "curl -sS -m 5 --noproxy '*' -o /dev/null https://example.com; echo \"direct curl_exit=\$?\"" \
    --step "curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.com; echo \" via-proxy curl_exit=\$?\"" \
    --step "curl -sS -m 10 -o /dev/null https://github.com; echo \"denied curl_exit=\$?\"" \
    --step "echo \"scope=\$BLACKICE_SCOPE key_in_env=\$(env | grep -c sk-synthetic)\"" \
    > /dev/null 2> "$W/out/fake-model.err" < /dev/null &
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2> /dev/null' EXIT
FAKE_PORT=
for _ in $(seq 1 50); do
    FAKE_PORT=$(sed -n 's|^scripted test model on http://127.0.0.1:\([0-9]*\)/v1.*|\1|p' "$W/out/fake-model.err")
    [ -n "$FAKE_PORT" ] && break
    sleep 0.1
done
[ -n "$FAKE_PORT" ] || { cat "$W/out/fake-model.err"; die "the scripted model did not start"; }
echo "== scripted model on 127.0.0.1:$FAKE_PORT"

# The synthetic relay key, read by blackice from stdin.
SYNTHETIC_KEY=sk-synthetic-not-a-real-key-0000
(umask 077 && printf '%s\n' "$SYNTHETIC_KEY" > "$W/synthetic.key")

# The wrapper that runs inside the scope.
cat > "$W/fx-l0-wrapper.sh" <<'SH'
#!/bin/sh
# Inside the scope: an isolated HOME whose fx settings point at this scope's relay, then fx itself.
set -eu
fx="$1"
shift
export HOME="$PWD/fx-home"
umask 077
mkdir -p "$HOME/.fx"
cat > "$HOME/.fx/settings.json" <<JSON
{
  "providers": {
    "relay": {
      "protocol": "openai-chat-completions",
      "base_url": "$BLACKICE_RELAY_URL",
      "auth": { "type": "bearer", "env": "BLACKICE_RELAY_TOKEN" }
    }
  },
  "permission_mode": "yolo",
  "yolo_acknowledged": true
}
JSON
export FX_PROVIDER=relay FX_MODEL=blackice-test/scripted
exec "$fx" ask "$@"
SH
cp "$FX" "$W/fx" && chmod 700 "$W/fx"

OUT="$W/out/fx.out"
ERR="$W/out/fx.err"
echo
echo "\$ blackice run --policy agent.json --relay --model $MODEL --upstream http://127.0.0.1:$FAKE_PORT/v1 \\"
echo "    -- /bin/sh fx-l0-wrapper.sh ./fx 'Run the network probe.'   < synthetic.key"
"$B" run --policy "$POLICY" --relay --model "$MODEL" --upstream "http://127.0.0.1:$FAKE_PORT/v1" \
    -- /bin/sh "$W/fx-l0-wrapper.sh" "$W/fx" "Run the network probe." < "$W/synthetic.key" > "$OUT" 2> "$ERR"
RC=$?
sed 's/^/  | /' "$OUT" | head -60
grep -v '^blackice: scope ' "$ERR" | sed 's/^/  ! /' | head -20
echo "  [exit $RC]"
scope_of "$ERR" || true

echo
echo "== the scripted model's view (tool results fx sent back)"
python3 -I - "$W/model.log" > "$W/out/model-view.txt" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("calls=%d" % len(calls))
print("auth_on_every_call=%s" % all(c.get("has_authorization") for c in calls))
for r in (calls[-1].get("tool_results", []) if calls else []):
    print("result: " + r.replace("\n", " | ")[:300])
PY
sed 's/^/  /' "$W/out/model-view.txt"
echo

check "blackice run exit 0 (fx finished)" test "$RC" -eq 0
check "fx printed the scripted model's final answer" grep -q 'SCRIPTED TEST MODEL (not a real model)' "$OUT"
model_calls() { sed -n 's/^calls=//p' "$W/out/model-view.txt"; }
check "the model was called for every step and the answer (at least 5 calls)" test "$(model_calls)" -ge 5
check "every call reached the model with the relay's key" grep -q '^auth_on_every_call=True$' "$W/out/model-view.txt"
check "inside: a direct connection that bypasses the proxy fails" grep -Eq 'direct curl_exit=[1-9]' "$W/out/model-view.txt"
check "inside: example.com through the proxy: HTTP 200" grep -q '200 via-proxy curl_exit=0' "$W/out/model-view.txt"
check "inside: github.com refused by the proxy (curl exit 56)" grep -q 'denied curl_exit=56' "$W/out/model-view.txt"
check "inside: the key is not in fx's environment" grep -q 'key_in_env=0' "$W/out/model-view.txt"

relay_allowed() { rq "$RCPT" point=relay event=relay_call verdict=allow reason=model_allowed rule="$MODEL"; }
check "receipts: one relay call allowed for $MODEL per model call" test "$(relay_allowed)" -eq "$(model_calls)"
check "receipts: no call refused for a bad relay token" test "$(rq "$RCPT" reason=bad_relay_token)" -eq 0
check "receipts: example.com allowed by the proxy" has_receipt "$RCPT" point=proxy verdict=allow host=example.com
check "receipts: github.com refused by the proxy" has_receipt "$RCPT" point=proxy verdict=deny host=github.com
check "the scope's last receipt is scope_end" ends_with_scope_end "$RCPT"
key_nowhere() { ! grep -rqF "$SYNTHETIC_KEY" "$XDG_STATE_HOME" "$W/fx-home" "$OUT" "$ERR" "$W/model.log" 2> /dev/null; }
check "the synthetic key is in no receipt, fx file, fx output or model log" key_nowhere

show_receipts
echo
echo "== $SCRIPTED_NOTICE"
summary
