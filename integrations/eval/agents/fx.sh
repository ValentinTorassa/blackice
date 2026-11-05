# shellcheck shell=bash disable=SC2034,SC2154 # sourced by ../run.sh, which sets repo and reads these
# fx with the blackice skill, with the hook `blackice agent connect fx` writes (AgentProfile.fx
# in macos/Sources/BlackiceCLI/AgentConnect.swift), with the repository's copy of the skill put in
# each event's directory, fx's workspace, where the daemon writes the copy inside blackice.
#
#   AGENT_HOME=dir   fx's HOME, with its own sign-in and rules (integrations/fx/README.md), as in
#                    the hook, which also sets FX_DISABLE_KEYCHAIN=1. Default: your own HOME and
#                    fx sign-in.
agent_bin_name=fx
agent_configure() {
  agent_files=("$repo/integrations/fx/skills/blackice/SKILL.md:skills/blackice/SKILL.md")
  agent_args=("ask" "--no-save" "--no-color" "Use the blackice skill to decide whether to approve the pending connection")
  if [ -n "${AGENT_HOME:-}" ]; then agent_env=("HOME=$AGENT_HOME" "FX_DISABLE_KEYCHAIN=1"); fi
}
