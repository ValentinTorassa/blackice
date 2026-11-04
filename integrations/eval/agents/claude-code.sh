# Claude Code in print mode, with the hook line that `blackice agent connect claude-code` writes
# (CLI.claudeCodeHook in macos/Sources/BlackiceCLI/AgentConnect.swift: keep the two in step), and
# the repository's copy of its instructions.
#
#   CLAUDE_CONFIG_DIR=dir   the Claude Code configuration whose sign-in it uses. Default:
#                           $AGENT_HOME/.claude, the one agent connect signs in.
#   AGENT_HOME=dir          default ~/.config/blackice/agent
#   MODEL=name              default sonnet, as in the hook
#
# HOME stays yours, as the daemon sets it: Claude Code keeps its sign-in in the login keychain,
# and macOS finds that keychain through HOME.
agent_bin_name=claude
agent_configure() {
  local config=${CLAUDE_CONFIG_DIR:-${AGENT_HOME:-$HOME/.config/blackice/agent}/.claude}
  agent_run="CLAUDE_CONFIG_DIR=\"$config\" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \"$bin\" -p --restricted --safe-mode"
  agent_run+=" --tools Read --strict-mcp-config --no-session-persistence --permission-prompts none"
  agent_run+=" --model ${MODEL:-sonnet} --max-turns 3 --output-format text"
  agent_run+=" --system-prompt-file \"$repo/integrations/claude-code/blackice/instructions.md\""
  agent_run+=" \"Decide the pending blackice connection in event.json.\" </dev/null"
}
