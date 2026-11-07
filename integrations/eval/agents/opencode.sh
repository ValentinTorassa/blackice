# shellcheck shell=bash disable=SC2034,SC2154 # sourced by ../run.sh, which sets repo and notes and reads these
# opencode (`opencode run`), with the hook `blackice agent connect opencode` writes
# (AgentInstructions.hookArguments and CLI.openCodeEnvironment in macos/Sources/) and the
# repository's copy of its instructions and the owner's notes in OPENCODE_CONFIG_CONTENT, where the
# daemon puts the copy inside blackice (a test checks that the two stay in step).
#
#   OPENCODE_HOME=dir   the HOME whose opencode sign-in it uses. Default: $AGENT_HOME/.opencode,
#                       the one agent connect signs in. Yours is your own HOME.
#   AGENT_HOME=dir      default ~/.config/blackice/agent
#   MODEL=provider/name default openai/gpt-6-luna, as in the hook for OpenAI
#
# agent_configuration_folder: XDG_CONFIG_HOME is a new private folder for each event, with an empty
# opencode/ in it, as the daemon makes it: opencode stops when it cannot create its configuration
# folder, as in /var/empty.
agent_bin_name=opencode
agent_configure() {
  local home=${OPENCODE_HOME:-${AGENT_HOME:-$HOME/.config/blackice/agent}/.opencode}
  local prompt
  system_prompt prompt "$repo/integrations/opencode/instructions.md"
  agent_args=("run" "--standalone" "--agent" "blackice" "--model" "${MODEL:-openai/gpt-6-luna}"
              "Decide whether to approve the pending blackice connection. Its event is the JSON object in this message, which blackice sent on stdin.")
  agent_env=("HOME=$home" "OPENCODE_CONFIG_CONTENT=$(opencode_configuration "$prompt")"
             "OPENCODE_DISABLE_PROJECT_CONFIG=1" "OPENCODE_DISABLE_CLAUDE_CODE=1"
             "OPENCODE_DISABLE_AUTOUPDATE=1" "OPENCODE_DISABLE_MODELS_FETCH=1")
  agent_configuration_folder=1
}
