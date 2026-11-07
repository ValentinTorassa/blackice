# shellcheck shell=bash disable=SC2034,SC2154 # sourced by ../run.sh, which sets repo and notes and reads these
# Codex (`codex exec`), with the hook `blackice agent connect codex` writes
# (AgentInstructions.hookArguments in macos/Sources/BlackiceCore/AgentInstructions.swift) and the
# repository's copy of its instructions and the owner's notes in `-c developer_instructions`,
# where the daemon puts the copy inside blackice (a test checks that the two stay in step).
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
  local prompt
  system_prompt prompt "$repo/integrations/codex/instructions.md"
  agent_args=("exec" "-c" "developer_instructions=$(toml_string "$prompt")"
              "--strict-config" "--skip-git-repo-check" "--ephemeral" "--ignore-user-config" "--ignore-rules"
              "--color" "never" "-m" "${MODEL:-gpt-6-luna}"
              "-c" 'model_reasoning_effort="low"'
              "-c" "project_doc_max_bytes=0"
              "-c" "skills.include_instructions=false"
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
              "Decide the pending blackice connection. Its event is the JSON object in the <stdin> block below.")
  agent_env=("CODEX_HOME=$home")
}
