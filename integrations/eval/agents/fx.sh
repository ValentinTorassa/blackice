# fx with the blackice skill, as `blackice agent connect fx` runs it (CLI.fxHookRun in
# macos/Sources/BlackiceCLI/AgentConnect.swift), but with the repository's copy of the skill, put in
# each event's directory, which is fx's workspace.
#
#   AGENT_HOME=dir   fx's HOME, with its own sign-in and rules (integrations/fx/README.md), as in
#                    the hook. Default: your own HOME and fx sign-in.
#
# PATH starts with a stand-in for blackice, so a skill that still runs `blackice approve` or
# `deny` shows up as a failure: hooks answer on stdout.
agent_bin_name=fx
agent_configure() {
  agent_files=("$repo/integrations/fx/skills/blackice:skills/blackice")
  local home=''
  if [ -n "${AGENT_HOME:-}" ]; then home="FX_DISABLE_KEYCHAIN=1 HOME=\"$AGENT_HOME\" "; fi
  agent_run="${home}PATH=\"$stub_dir:/usr/bin:/bin:/usr/sbin:/sbin\" \"$bin\" ask --no-save --no-color"
  agent_run+=" \"Use the blackice skill to decide whether to approve the pending connection\" </dev/null"
}
