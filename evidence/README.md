# Evidence

Each file here records one real run of one checkpoint, made by the people building blackice on their own
machines; none is an independent test. A capability is listed as working only when it has an entry.

## Naming

Name the file after the checkpoint, what it shows and the platform, for example `P0-02-real-deny-linux.md`. The
site reads the `P0-xx` prefix to mark that checkpoint as recorded, so add the file only after the run.

## What an entry records

- **Claim**: one sentence, and the checkpoint it covers.
- **Platform**: OS, kernel or macOS version, architecture, and on macOS whether SIP is on.
- **Build**: commit hash and Zig version.
- **Policy**: the policy file used, inline or linked.
- **Run**: the exact commands.
- **Result**: what happened, and where it was enforced (kernel, proxy or resolver).
- **Receipts**: the receipt lines, or a link to them.
- **Recording**: a link, if there is one.
- **Limits**: what the run does not show.
- **Date**.

## Failed runs and raw data

Failed runs are kept too, in their own files: [`linux-020f389-startup-failure.md`](linux-020f389-startup-failure.md)
and [`linux-c962271-containment-failure.md`](linux-c962271-containment-failure.md) record the two Linux runs before
the passing one. Raw receipts and receiver logs for a run can go under `data/`.

## Older builds

Some macOS entries name a `claude/run` build. Those commits were squashed into main as 727a5db by
[#1](https://github.com/ValentinTorassa/blackice/pull/1), and they can still be fetched with
`git fetch origin pull/7/head`. The fx patch that P0-07 names, `claude/fx-hook` at 08e34f3, can be fetched with
`git fetch origin pull/9/head`. It has the same sha256 as `integrations/fx/fx-v0.0.16-blackice-hook.patch` on
main.
