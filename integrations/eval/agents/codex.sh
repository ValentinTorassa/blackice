# shellcheck shell=bash disable=SC2034,SC2154 # sourced by ../run.sh, which sets repo and reads these
# Codex (`codex exec`), with the hook `blackice agent connect codex` writes (CLI.codexArguments in
# macos/Sources/BlackiceCLI/AgentConnect.swift; a test checks that the two stay in step), with the
# repository's copy of its instructions put in each event's directory, where the daemon writes
# the copy inside blackice.
#
#   CODEX_HOME=dir   the Codex home whose sign-in it uses. Default: $AGENT_HOME/.codex, the one
#                    agent connect signs in; ~/.codex is your own.
#   AGENT_HOME=dir   default ~/.config/blackice/agent
#   MODEL=name       default gpt-6-luna, as in the hook
#
# HOME stays yours, as the daemon sets it.
agent_bin_name=codex
agent_configure() {
  local home=${CODEX_HOME:-${AGENT_HOME:-$HOME/.config/blackice/agent}/.codex}
  agent_args=("exec" "--strict-config" "--skip-git-repo-check" "--ephemeral" "--ignore-user-config" "--ignore-rules"
              "--color" "never" "-m" "${MODEL:-gpt-6-luna}"
              "-c" 'model_reasoning_effort="low"'
              "-c" 'model_instructions_file="instructions.md"'
              "-c" "project_doc_max_bytes=0"
              "-c" 'default_permissions="blackice"'
              "-c" 'permissions.blackice.filesystem={":minimal"="read",":workspace_roots"="read"}'
              "-c" 'approval_policy="never"'
              "-c" "allow_login_shell=false"
              "-c" 'web_search="disabled"'
              "-c" "analytics.enabled=false"
              "-c" "feedback.enabled=false"
              "-c" 'history.persistence="none"'
              "--disable" "hooks" "--disable" "plugins" "--disable" "apps" "--disable" "multi_agent"
              "--disable" "image_generation" "--disable" "browser_use" "--disable" "computer_use"
              "Decide the pending blackice connection described in event.json.")
  agent_files=("$repo/integrations/codex/instructions.md:instructions.md")
  agent_env=("CODEX_HOME=$home")
  # codex exec adds what comes on stdin to its prompt: the event reaches it only as a file.
  agent_stdin=none
}
