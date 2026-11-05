# shellcheck shell=bash disable=SC2034,SC2154 # sourced by ../run.sh, which sets repo and reads these
# Claude Code in print mode, with the hook `blackice agent connect claude-code` writes
# (CLI.claudeCodeArguments in macos/Sources/BlackiceCLI/AgentConnect.swift; a test checks that
# the two stay in step), with the repository's copy of its instructions put in each event's
# directory, where the daemon writes the copy inside blackice.
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
  agent_args=("-p" "--restricted" "--safe-mode" "--tools" "Read" "--strict-mcp-config" "--no-session-persistence"
              "--permission-prompts" "none" "--model" "${MODEL:-haiku}" "--max-turns" "3" "--output-format" "text"
              "--system-prompt-file" "instructions.md"
              "Decide the pending blackice connection in event.json.")
  agent_files=("$repo/integrations/claude-code/blackice/instructions.md:instructions.md")
  agent_env=("CLAUDE_CONFIG_DIR=$config" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")
  # claude -p adds what comes on stdin to its prompt: the event reaches it only through Read.
  agent_stdin=none
}
