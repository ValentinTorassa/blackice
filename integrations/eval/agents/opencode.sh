# shellcheck shell=bash disable=SC2034,SC2154 # sourced by ../run.sh, which sets repo and reads these
# opencode (`opencode run`), with the hook `blackice agent connect opencode` writes
# (CLI.openCodeArguments and CLI.openCodeEnvironment in macos/Sources/BlackiceCLI/AgentConnect.swift;
# a test checks that the two stay in step), with the repository's copy of its instructions put in
# each event's directory, where the daemon writes the copy inside blackice.
#
#   OPENCODE_HOME=dir   the HOME whose opencode sign-in it uses. Default: $AGENT_HOME/.opencode,
#                       the one agent connect signs in. Yours is your own HOME.
#   AGENT_HOME=dir      default ~/.config/blackice/agent
#   MODEL=provider/name default openai/gpt-6-luna, as in the hook for OpenAI
#
# XDG_CONFIG_HOME is `.`, the event's directory: opencode's global configuration folder is a new,
# empty one there, for each event.
agent_bin_name=opencode
agent_configure() {
  local home=${OPENCODE_HOME:-${AGENT_HOME:-$HOME/.config/blackice/agent}/.opencode}
  local rules='"*":"deny","read":"allow","bash":"deny","edit":"deny","glob":"deny","grep":"deny","task":"deny","todowrite":"deny","skill":"deny","lsp":"deny","question":"deny","webfetch":"deny","websearch":"deny","external_directory":"deny","doom_loop":"deny"'
  agent_args=("run" "--standalone" "--agent" "blackice" "--model" "${MODEL:-openai/gpt-6-luna}"
              "Decide whether to approve the pending blackice connection in event.json.")
  agent_files=("$repo/integrations/opencode/instructions.md:instructions.md")
  agent_env=("HOME=$home" "XDG_CONFIG_HOME=."
             "OPENCODE_CONFIG_CONTENT={\"agent\":{\"blackice\":{\"mode\":\"primary\",\"prompt\":\"{file:./instructions.md}\",\"steps\":4,\"permission\":{$rules}}},\"autoupdate\":false,\"permission\":{$rules},\"share\":\"disabled\"}"
             "OPENCODE_DISABLE_PROJECT_CONFIG=1" "OPENCODE_DISABLE_CLAUDE_CODE=1"
             "OPENCODE_DISABLE_AUTOUPDATE=1" "OPENCODE_DISABLE_MODELS_FETCH=1")
  # opencode run adds what comes on stdin to its message: the event reaches it only as a file.
  agent_stdin=none
}
