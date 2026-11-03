# Evidence

Each file here records one real run on a Mac, made by the people building blackice; none is an independent test.
The README, the docs and the site describe something as working only when an entry here records it. Unit tests,
dry runs and code that compiles are not evidence of that kind and get no entry.

## Naming

`P<phase>-<nn>-<what>-macos.md`: the phase in [`docs/plan.md`](../docs/plan.md) whose check the run bears on, a
two-digit number within that phase, and what the run shows, for example `P0-01-team-signed-probe-blocked-macos.md`.
The scheme follows blackice-poc's `P0-xx` entries, where the prefix named a checkpoint of its v0. Add the file after
the run, never before it.

## What an entry records

- **Claim**: one or two sentences, and the phase check it bears on.
- **Platform**: Mac model, macOS version and build, architecture, and whether System Integrity Protection is on.
- **Build**: the app's version and build number, the commit if it was recorded, and how it was signed.
- **Configuration**: the `blackice.toml` used, inline.
- **Run**: what was run, in order, and who did what.
- **Result**: what happened, and which part decided: the extension, the daemon, a hook or a person.
- **Log lines**: the lines from the filter's unified log, the daemon's event log and the run's output that show it.
- **Recording**: a link, if there is one.
- **Limits**: what the run does not show.
- **Date**.

## Copying from the logs

- Never copy an event token. The event log keeps up to 2 KiB of each hook's stderr, and an agent that prints the
  commands it runs prints the token with them (`--token '…'`). Copy the fields an entry needs and leave `stderr` out.
- Replace home directories with `~`, and leave out apps, hosts and paths that are not part of the run.
- The filter logs each flow's app and host as `<private>`; only the verdict and the reason are public. The event log
  has the app and host, so an entry ties the two together through the event ID and the times.
- Failed runs get their own entries too, named for what failed.

## Entries

| Entry | Phase | What it shows |
|---|---|---|
| [P0-01](P0-01-team-signed-probe-blocked-macos.md) | 0 | In block-all a binary signed with our Team ID and named by no rule is refused, and `curl` with a rule still reaches its host. |
| [P2-01](P2-01-ask-mode-fx-hook-macos.md) | 2, 3, 4 | Ask mode with fx deciding through the hook: two approvals, one denial, one connection dropped at the deadline. |
| [P4-01](P4-01-fx-decides-ten-connections-macos.md) | 4 | fx decides ten connections in a row with nobody at the keyboard; nine match the expected answer. |

Not recorded yet: the fault tests of phase 5 (`macos/scripts/fault-test.sh`, to be run at the Mac, then recorded as
`P5-01-faults-macos.md`) and an install from a notarized package by following [`docs/install.md`](../docs/install.md).
