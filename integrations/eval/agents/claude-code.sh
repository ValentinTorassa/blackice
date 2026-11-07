# shellcheck shell=bash disable=SC2034,SC2154 # sourced by ../run.sh, which sets repo and notes and reads these
# Claude Code in print mode, with the hook `blackice agent connect claude-code` writes
# (AgentInstructions.hookArguments in macos/Sources/BlackiceCore/AgentInstructions.swift) and the
# repository's copy of its instructions and the owner's notes on the command line, where the
# daemon puts the copy inside blackice (a test checks that the two stay in step).
#
#   CLAUDE_CONFIG_DIR=dir   the Claude Code configuration whose sign-in it uses. Default:
#                           $AGENT_HOME/.claude, the one agent connect signs in.
#   AGENT_HOME=dir          default ~/.config/blackice/agent
#   MODEL=name              default haiku, as in the hook
#
# HOME stays yours, as the daemon sets it: Claude Code keeps its sign-in in the login keychain,
# and macOS finds that keychain through HOME.
agent_bin_name=claude
agent_configure() {
  local config=${CLAUDE_CONFIG_DIR:-${AGENT_HOME:-$HOME/.config/blackice/agent}/.claude}
  local instructions section
  instructions_text instructions "$repo/integrations/claude-code/blackice/instructions.md"
  agent_args=("--system-prompt" "$instructions")
  if [ -n "${notes:-}" ]; then
    notes_section section
    agent_args+=("--append-system-prompt" "$section")
  fi
  agent_args+=("-p" "--restricted" "--safe-mode" "--tools" "" "--strict-mcp-config" "--no-session-persistence"
               "--permission-prompts" "none" "--model" "${MODEL:-haiku}" "--max-turns" "3" "--output-format" "text"
               "Decide the pending blackice connection. Its event is the JSON object in this message, which blackice sent on stdin.")
  agent_env=("CLAUDE_CONFIG_DIR=$config" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")
}
