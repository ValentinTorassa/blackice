# shellcheck shell=bash disable=SC2034,SC2154 # sourced by ../run.sh, which sets repo and notes and reads these
# fx, with the hook `blackice agent connect fx` writes (AgentInstructions.hookArguments in
# macos/Sources/BlackiceCore/AgentInstructions.swift) and the repository's copy of the blackice
# skill and the owner's notes in `--system`, where the daemon puts the copy inside blackice (a
# test checks that the two stay in step). The event on stdin is the whole prompt.
#
#   AGENT_HOME=dir   fx's HOME, with its own sign-in and rules (integrations/fx/README.md), as in
#                    the hook, which also sets FX_DISABLE_KEYCHAIN=1. Default: your own HOME and
#                    fx sign-in.
#   MODEL=id         default anthropic/claude-haiku-5.5, as in the hook (`fx models` lists them)
agent_bin_name=fx
agent_configure() {
  local prompt
  system_prompt prompt "$repo/integrations/fx/skills/blackice/SKILL.md"
  agent_args=("ask" "--system" "$prompt" "--no-save" "--no-color" "--model" "${MODEL:-anthropic/claude-haiku-5.5}")
  if [ -n "${AGENT_HOME:-}" ]; then agent_env=("HOME=$AGENT_HOME" "FX_DISABLE_KEYCHAIN=1"); fi
}
