#!/bin/bash
# fx's eval is integrations/eval now, the same cases for every decider:
#
#   AGENT_HOME="$HOME/.config/blackice/agent" integrations/eval/run.sh --agent fx [path/to/fx]
#
# This runs it, for the commands written before.
exec "$(cd "$(dirname "$0")/../../eval" && pwd)/run.sh" --agent fx "$@"
