#!/bin/bash
# Writes Sources/BlackiceCore/AgentInstructionsText.swift from the instruction files in
# integrations/, so that each agent's instructions ship inside blackice (AgentInstructions.swift).
# Run it after changing one of those files: AgentInstructionsTests fails until the two agree.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
out=Sources/BlackiceCore/AgentInstructionsText.swift

# NAME FILE: a raw string literal with the file's exact text, its last line break included.
literal() {
    local name=$1 file=../$2
    if grep -q -e '"""##' -e '\\##' "$file"; then echo "$2 holds \"\"\"## or \\##, which the literal cannot" >&2; exit 1; fi
    printf '    /// %s\n    static let %s = ##"""\n' "$2" "$name"
    cat "$file"
    printf '\n"""##\n'
}

{
    printf '%s\n' "// Written by macos/scripts/agent-instructions.sh from integrations/. Do not edit: change the file" \
        "// there and run the script again. AgentInstructionsTests checks that the two agree." "" \
        "enum AgentInstructionsText {"
    literal fx integrations/fx/skills/blackice/SKILL.md
    echo
    literal claudeCode integrations/claude-code/blackice/instructions.md
    echo
    literal codex integrations/codex/instructions.md
    echo "}"
} > "$out.tmp"
mv "$out.tmp" "$out"
echo "wrote macos/$out"
