# P5-14: Codex answering real connections with 0.4.7, and the notes it misread

**Claim.** With the published 0.4.7 in ask mode, Codex 0.166.0, connected with `blackice agent connect codex`,
answered 80 real connections on a Mac in an hour, every one before its deadline: 53 approved and 27 denied, at a
median of 6.2 s (p90 16.9 s). Of six test connections it approved the Yarn registry and a university page the
owner's notes allow and denied a paste site and a file-sharing site, but it denied `curl` to fonts.gstatic.com, which
0.4.7's instructions approve, because it read the owner's notes as the whole list of what a tool may reach. The
instructions now say the notes only add to them. With the owner's notes Codex then decided 31 of the eval's 33
cases as expected, against 33 for Claude Code and fx without them; it still reads the notes as a list of what is
allowed now and then. Phase 4.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi, Tailscale
running with its DNS on.

**Build.** Blackice.app 0.4.7, build 28, as published (P5-13). Codex 0.166.0 (Homebrew cask, `codex`, team
2DC432GLL2), signed in with ChatGPT in its own home, `~/.config/blackice/agent/.codex`, with `gpt-6-luna` and low
reasoning effort, as `agent connect` writes the hook.

**Configuration.** The owner's file (P5-10), with the Codex hook `agent connect` added at line 173 and `answers =
"codex"`, and the owner's notes in `[agent]`. Among them: "Homebrew node running my coding tools, reaching api.z.ai,
api.anthropic.com and registry.npmjs.org", a line for `curl`, `gh` and `git` to GitHub, Vercel and AWS, and one for
"Claude Code and curl reading documentation, papers and university course pages over HTTPS". No rule covers `curl`
to the hosts below.

**Run.** 6 November 2026, from a Claude Code session on the Mac. The owner ran `blackice agent connect codex` in
Terminal (the ChatGPT sign-in, the questions and Touch ID); Codex's first hook ran at 15:40 UTC. At 15:56 UTC six
`curl` fetches ran at once, to registry.yarnpkg.com, fonts.gstatic.com, crypto.stanford.edu, valentorassa.com,
paste.ee and transfer.sh. At 16:43 UTC `blackice mode ask --agent claude-code` (Touch ID) put Claude Code back.

**Result.**

1. From 15:40 to 16:43 UTC Codex ran 80 hooks: 53 approve, 27 deny, none without an answer and none killed. Hook time
   at the median 6.2 s, p90 16.9 s, longest 31.4 s. Claude Code's median over the day before was 3.8 s (P5-10).
2. The six fetches: registry.yarnpkg.com approved (HTTP 200 after 9.4 s), crypto.stanford.edu approved (HTTP 200 after
   11.9 s), paste.ee and transfer.sh denied, and valentorassa.com went through in 0.5 s with no event, under an
   approval given earlier that day. fonts.gstatic.com was denied in 6.8 s, with this reason: "curl → fonts.gstatic.com:
   the host is a public asset CDN used for fetched assets, but the owner's notes don't cover curl reaching it."
3. The same mistake in the eval, with the owner's notes as `notes.md` (`NOTES=…`): Codex denied a Homebrew `node` to
   fonts.googleapis.com in 3 of 4 runs, "not covered by the owner's node guidance". Without notes it approved it.
4. Other denials worth a look: `gh` and `curl` to productionresultssaN.blob.core.windows.net, where GitHub keeps
   Actions logs, and a uv-managed `python3.14` in `~/.local/share/uv` to AWS's sign-in host, "at a nonstandard path".

Decided by: Codex (every verdict above), the extension (holding each connection until the answer).

**What changed after.** The four instructions now say that the notes add to them: a connection step 4 approves stays
approved when the notes do not mention it or name other hosts for the same tool, with an example, and step 4 says that
something the notes leave out is no reason to deny. They also name the toolchain folders (`~/.local/bin`, uv's
Pythons, `~/.cargo/bin` and others) as ordinary places to run from and add GitHub Actions' log storage to the source
hosts. With the owner's notes, Codex then decided the four shaky cases as expected in 12 of 12 runs. The full eval,
now 33 cases, came out 31 of 33 for Codex with the notes (it denied Chrome to clients2.google.com, "the notes don't
authorize Chrome's traffic", in 3 of 3 runs, and gave no answer line once), and 33 of 33 for Claude Code and for fx.
A fixed line on top of `notes.md` saying the same did not help (4 of 15 wrong), so blackice does not add one.

**Limits.**

- `gpt-6-luna` with low effort varies between runs: with the notes rule but before its example, the four shaky cases
  still failed in 2 of 12 runs; medium effort did not fix the notes case either (2 of 3 still denied).
- The 80 hooks are one hour of one Mac; the test fetches were six.
- Not covered: opencode as the answerer on the Mac, and Codex in block-all.

**Date.** 6 November 2026.
