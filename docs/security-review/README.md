# Security review

How changes to blackice are reviewed for security, and the rules the CI follows.

## Pull requests

Every pull request gets a security review before it is merged. Findings are posted as review comments, never
as an approval. Each finding has a severity and a concrete fix:

| Severity | Meaning |
|---|---|
| Critical | A confined command reaches the network freely, or gains root, with no special conditions. |
| High | The scope or the integrity of its receipts can be bypassed with ordinary user actions. |
| Medium | A bypass that needs specific conditions (network type, policy shape, a missing check elsewhere), or a loss of defense in depth. |
| Low | Hardening, privacy or robustness problems that do not bypass the scope. |
| Nit | Style or tooling. |

A finding that is not fixed before a recorded run is listed under the limits of that run's evidence entry.

Privileged code (the Linux helper and `scripts/linux-setup.sh` / `scripts/linux-teardown.sh`) is reviewed
before anyone runs it with sudo.

## CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`, on `ubuntu-latest` (x86_64) and
`macos-latest` (arm64): `zig fmt --check` (Linux only), `zig build`, `zig build test`, and a cross-build for the
other OS.

Rules for every workflow in this repository:

- The token is read-only (`permissions: contents: read`), and checkout does not keep it (`persist-credentials: false`).
- No secrets and no `pull_request_target`.
- Actions are pinned to full commit SHAs, with the tag in a comment.
- Values from the event (titles, branch names, bodies) never go straight into a `run:` script. Steps read them
  through `env:`.
- Zig is pinned by version and by the sha256 of each platform's tarball, copied from
  <https://ziglang.org/download/index.json>. The tarball comes from a shuffled pick of Zig's
  [community mirrors](https://ziglang.org/download/community-mirrors/), with ziglang.org as the last resort, and
  is used only if its sha256 matches. Zig recommends a minisign check for mirror downloads; a pinned sha256 is
  stricter, because it fixes the exact bytes of a known release.

### Updating Zig

1. Copy the new version's `shasum` for `x86_64-linux` and `aarch64-macos` from `index.json`.
2. Change `ZIG_VERSION` and both `zig_sha256` values in one commit, and say in the commit message where the
   values came from.
3. Update `minimum_zig_version` in `build.zig.zon` if it changes.

### Updating an action

Get the commit of the new tag (`gh api repos/<owner>/<repo>/git/ref/tags/<tag>`; if the object is an annotated
tag, follow it to its commit), replace the SHA and update the tag in the comment.
