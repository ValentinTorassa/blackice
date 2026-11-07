# shellcheck shell=bash
# How the daemon passes an agent its instructions and the owner's notes (AgentInstructions.launch
# in macos/Sources/BlackiceCore/AgentInstructions.swift), for run.sh and the agents/ files. A test
# in macos/ runs each agents/ file and checks that it builds the same arguments and environment.

# read_text NAME FILE: the file's exact text, its last line break included, into the variable NAME.
read_text() {
  IFS= read -r -d '' "$1" < "$2" || true
}

# The helpers set the variable they are given by name, so their own are named _text_* to keep
# clear of the caller's.

# instructions_text NAME FILE: the instructions in FILE, without a `---` front matter block and the
# blank lines after it (fx's skill has one), into NAME.
instructions_text() {
  local _text_instructions
  read_text _text_instructions "$2"
  if [[ $_text_instructions == ---$'\n'* ]]; then
    _text_instructions=${_text_instructions#---$'\n'*$'\n'---$'\n'}
    while [[ $_text_instructions == $'\n'* ]]; do _text_instructions=${_text_instructions#$'\n'}; done
  fi
  printf -v "$1" '%s' "$_text_instructions"
}

# notes_section NAME: the owner's notes ($notes, from NOTES=file) as the agent gets them, into NAME.
notes_section() {
  local _text_section="## The owner's notes"$'\n\n'"$notes"
  [[ $_text_section == *$'\n' ]] || _text_section+=$'\n'
  printf -v "$1" '%s' "$_text_section"
}

# system_prompt NAME FILE: the instructions in FILE, then the notes when there are any, into NAME.
system_prompt() {
  local _text_prompt _text_notes
  instructions_text _text_prompt "$2"
  if [ -n "${notes:-}" ]; then
    notes_section _text_notes
    _text_prompt+=$'\n'"$_text_notes"
  fi
  printf -v "$1" '%s' "$_text_prompt"
}

# toml_string TEXT: TEXT as a TOML basic string, as Codex reads the value of `-c`.
toml_string() {
  python3 -I -c '
import sys
out = ["\""]
for ch in sys.argv[1]:
    code = ord(ch)
    if ch == "\"": out.append("\\\"")
    elif ch == "\\": out.append("\\\\")
    elif ch == "\n": out.append("\\n")
    elif ch == "\t": out.append("\\t")
    elif ch == "\r": out.append("\\r")
    elif code < 0x20 or code == 0x7F: out.append("\\u%04X" % code)
    else: out.append(ch)
out.append("\"")
sys.stdout.write("".join(out))
' "$1"
}

# opencode_configuration PROMPT: the configuration opencode gets in OPENCODE_CONFIG_CONTENT, an
# agent named blackice whose whole system prompt is PROMPT, with no tool at all.
opencode_configuration() {
  python3 -I -c '
import json, sys
prompt = sys.argv[1].replace("{env:", "{ env:").replace("{file:", "{ file:")
tools = ["*", "read", "bash", "edit", "glob", "grep", "task", "todowrite", "skill", "lsp", "question",
         "webfetch", "websearch", "external_directory", "doom_loop"]
rules = {tool: "deny" for tool in tools}
config = {"agent": {"blackice": {"mode": "primary", "prompt": prompt, "steps": 4, "permission": rules}},
          "autoupdate": False, "permission": rules, "share": "disabled"}
sys.stdout.write(json.dumps(config, ensure_ascii=False, separators=(",", ":")))
' "$1"
}
