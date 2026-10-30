# npm distribution

Version **0.1.0** uses a launcher package and four optional platform packages. `prepare.mjs` and `pack.mjs` only prepare and audit local tarballs. The separate `publish-manual-0.1.0.sh` is an operator-run publication script: it uses the operator's npm login and OTP prompts. No script builds native binaries or changes a privileged installation. The checked-in manifests are private templates, not publishable packages.

| Output directory | Default package | Platform | Payload beyond metadata, README and license |
| --- | --- | --- | --- |
| `blackice/` | `@legios/blackice` | Node.js 22+ | 33-line launcher; command `blackice` |
| `darwin-arm64/` | `@legios/blackice-darwin-arm64` | macOS arm64 | `bin/blackice` |
| `darwin-x64/` | `@legios/blackice-darwin-x64` | macOS x64 | `bin/blackice` |
| `linux-x64/` | `@legios/blackice-linux-x64` | Linux x64 | `bin/blackice` |
| `linux-arm64/` | `@legios/blackice-linux-arm64` | Linux arm64 | `bin/blackice` |

Every archive has exactly four files. **No npm package contains a Linux helper, setup/teardown script or setup bundle.** Linux arm64 supplies the CLI only; task scopes on that CPU remain unsupported until a reviewed helper and runtime evidence exist.

The launcher has no regular dependencies. Its optional dependencies use exact matching versions, and its generated `blackicePlatforms` map selects the complete package name for each OS/CPU. Platform manifests declare `os` and `cpu`. There are no lifecycle scripts, registry fallback, PATH fallback or runtime downloads. npm fetches packages normally during installation; package code performs no additional downloads or setup. Node's architecture selects the binary, so use a matching Node installation.

## Release input and preparation

The four raw CLI assets and `SHA256SUMS` are required:

```text
blackice-0.1.0-aarch64-macos
blackice-0.1.0-x86_64-macos
blackice-0.1.0-x86_64-linux
blackice-0.1.0-aarch64-linux
SHA256SUMS
```

The full release also contains `blackice-linux-helper-0.1.0-x86_64-linux`, which may appear in the manifest but is never read or copied into npm. The preparer also accepts a CLI-only manifest. Setup/teardown scripts and an ARM helper are not release assets and are rejected as manifest entries. Scripts come from the tag checkout. An absent ARM helper does not block CLI packaging.

Verify release attestations before preparing public packages. The preparer checks CLI integrity, not provenance: its output records `verification: "sha256-only"`. A locally produced checksum file does not establish release identity. Label local fixtures as test inputs, not attested releases.

The lower-level packaging interface below supports offline tests and the later publication workflow. **For the manual 0.1.0 publish, use the script under [Manual first publish](#manual-first-publish-010): it downloads and verifies the draft's assets itself and accepts no local-build input.** From the repository root:

```sh
node packaging/npm/prepare.mjs \
  --release-dir /absolute/path/to/verified-release \
  --out-dir out/npm-0.1.0 \
  --version 0.1.0 --scope @legios --name @legios/blackice

node packaging/npm/pack.mjs \
  --prepared-dir out/npm-0.1.0 \
  --out-dir out/npm-tarballs-0.1.0
```

`--version`, `--scope` and `--name` default to the values shown. The preparer supports an explicitly selected scope and main name while keeping the command name `blackice`; platform packages retain the `blackice-<platform>` prefix. Changing `--scope` alone does not change the launcher name. The release workflow requires `NPM_SCOPE=@legios` and `NPM_PACKAGE_NAME=@legios/blackice`, and refuses different values. The operator must own the `legios` organization; if that check fails, stop and ask the release lead. Never switch scopes automatically.

After publication, the install command is `npm install --global --ignore-scripts @legios/blackice@0.1.0`. The launcher tarball is `legios-blackice-0.1.0.tgz` and remains last in `publish-order.txt`.

Both output directories must be new. Required checksums must occur exactly once; duplicate, unknown, path-bearing and missing CLI entries are rejected. Versions must be stable `X.Y.Z`. Inputs must be bounded regular files, not symlinks. The preparer hashes each CLI and copies that same in-memory snapshot, preserving its bytes with explicit executable permissions, then atomically moves the completed output into place. `manifest.json` records source asset hashes and platform-first package order.

The packer checks exact identities, versions, platform selectors, dependency pins, the launcher map and the four-file allowlist. It runs `npm pack --dry-run --ignore-scripts --offline --json` and `npm pack` with the same flags for all packages. It verifies archive entries, extracted bytes and npm integrity hashes. Only after all five archives pass does it write `packs.json` and `publish-order.txt`. Partial output on failure is not publishable; start again with a fresh directory.

## Manual Linux setup

npm installation does not establish the Linux enforcement boundary. On Linux x86_64, check out the matching tag and use the Zig version it requires. Verify the release's `SHA256SUMS` attestation and downloaded files, build the helper in the checkout, and compare its SHA-256 with the manifest's `blackice-linux-helper-0.1.0-x86_64-linux` entry. Only after that match should the checkout's setup script run with that digest as its second argument. Review [docs/linux.md](../../docs/linux.md) and the checkout's scripts first.

The following block uses a fresh checkout and stops on any failed check. It performs an explicit operator setup; npm installation never executes it. Linux arm64 remains CLI-only and must not use this x86_64 procedure.

```sh
(
  set -eu
  test "$(uname -s)" = Linux
  test "$(uname -m)" = x86_64
  git clone --branch v0.1.0 --depth 1 https://github.com/ValentinTorassa/blackice.git blackice-v0.1.0
  cd blackice-v0.1.0
  release_dir="$PWD/out/release-v0.1.0"
  mkdir -p "$release_dir"
  gh release download v0.1.0 --repo ValentinTorassa/blackice --dir "$release_dir"
  (
    cd "$release_dir"
    gh attestation verify SHA256SUMS --repo ValentinTorassa/blackice --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml --source-ref refs/tags/v0.1.0 --source-digest "$(git rev-parse HEAD)" --deny-self-hosted-runners
    sha256sum -c SHA256SUMS
  )
  zig build -Doptimize=ReleaseSafe
  helper_sha256="$(awk '$2 == "blackice-linux-helper-0.1.0-x86_64-linux" { print $1 }' "$release_dir/SHA256SUMS")"
  test "${#helper_sha256}" -eq 64
  printf '%s  zig-out/bin/blackice-linux-helper\n' "$helper_sha256" | sha256sum -c -
  sudo ./scripts/linux-setup.sh "$USER" "$helper_sha256"
)
```

The release contains four CLIs, the x86_64 helper and `SHA256SUMS`. Scripts are neither flat release assets nor separately attested: their integrity comes from the tag checkout. The root-install digest comes from the independently verified manifest, never from npm metadata. These are instructions for the corresponding published release, not a claim that version 0.1.0 is already available.

## Validation and launcher behavior

```sh
node --test packaging/npm/test.mjs
node --test packaging/npm/manual-release.test.mjs
```

The suite checks changed bytes and malformed checksums, CLI-only releases, configurable scope/name/version, exact archive contents, launcher arguments and I/O, missing packages, numeric exits and signal exits. It exercises the production packer on all five packages, then installs local tarballs offline with scripts disabled and runs the installed launcher. Synthetic test executables do not establish native enforcement.

To exercise a real local binary, prepare a clearly labeled local build fixture, install its matching platform and launcher tarballs offline, and run `blackice version` plus a harmless command. Record the actual binary hash, source commit and reported version. Packaging metadata alone does not establish any of them.

The launcher uses `spawnSync` with inherited stdio and no shell. It mirrors numeric exit status and re-emits the child's termination signal. Terminal signals reach both processes through their shared foreground process group. Because synchronous spawning blocks JavaScript signal handlers, a signal addressed only to the launcher PID is not forwarded while its child runs. Use a supervisor that signals the process group or invoke the native binary directly; immediate PID-only forwarding would require an asynchronous launcher. See [Node's synchronous child-process contract](https://nodejs.org/api/child_process.html#child_processspawnsynccommand-args-options).

## Manual first publish (0.1.0)

Version **0.1.0 has no npm provenance statement**. The native release files have GitHub build attestations, which the preparation step verifies; those do not attest to the assembly or manual publication of the npm packages. The OIDC workflow explicitly skips `v0.1.0`.

The operator runs this only after security clears the release and the `v0.1.0` **draft** exists. Use the matching tag checkout with unchanged packaging files and license, Node.js 22+, npm, `tar`, `sha256sum`, and a GitHub CLI supporting the attestation flags below. Authenticate to npm beforehand if necessary; the script's first check will otherwise stop.

```sh
bash packaging/npm/publish-manual-0.1.0.sh out/npm-manual-0.1.0
```

The output directory must not exist. The script:

1. Runs `npm whoami` and `npm org ls legios --json`, requiring the authenticated account's role to be `owner`. A failed check stops with a message to contact the release lead; there is no scope fallback.
2. Reminds the operator to set account 2FA to **authorization and writes** and asks for confirmation. npm handles login and OTP prompts; the script never accepts an OTP argument or records one. It rechecks ownership after login. See [npm's 2FA publishing requirements](https://docs.npmjs.com/requiring-2fa-for-package-publishing-and-settings-modification/).
3. Downloads the exact six assets from the draft, requires the tag's commit to be on `main` and match the checkout, verifies `SHA256SUMS` with `gh attestation verify`, runs `sha256sum -c SHA256SUMS`, and verifies every binary/helper attestation. Every verification binds the repository, `release.yml`, `refs/tags/v0.1.0`, the source commit, and `--deny-self-hosted-runners`. It checks that the tag and draft asset identities have not changed before preparing any package. No locally built binary is accepted by this path.
4. Packs the four platform packages and `@legios/blackice`, keeping the four optional dependencies pinned to **exactly `0.1.0`**. It checks archive bytes and all platform binaries against the attested checksums before publication.
5. Publishes platforms first and launcher last using `npm publish <tarball> --access public --ignore-scripts`, with provenance disabled. After each publish it queries `npm view <package>@0.1.0 dist.integrity` and `maintainers`, compares integrity with the prepared archive, and requires the authenticated account to appear as a maintainer. For every platform it also runs `npm pack <package>@0.1.0 --ignore-scripts`, checks the downloaded archive, and compares the binary inside with `SHA256SUMS`. A failed publish or repeated verification failure stops before the next package.

Reports are under the output's `registry-checks/`; the attestation logs and original draft assets remain beside them. Security can repeat all five integrity/maintainer checks and the four registry-download binary checks independently:

```sh
node packaging/npm/manual-release.mjs verify-all out/npm-manual-0.1.0 YOUR_NPM_USERNAME
```

The checks prove byte equality and the reported maintainer identity, not npm provenance. Local tests simulate service responses and never log in or publish. A partial publication needs operator reconciliation; immutable versions must not be overwritten, and this script must not be blindly rerun after a partial publish.

## Before 0.1.1: trusted publishing follow-up

This is a written follow-up, **not an action performed by the 0.1.0 script**:

1. Configure [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/) on **all five packages**, bound to repository `ValentinTorassa/blackice`, workflow **npm-publish.yml**, and environment **npm**.
2. Set each package's publishing access to **require 2FA and disallow tokens**. Keep the operator's account 2FA enabled for authorization and writes.
3. Set repository variables `NPM_SCOPE=@legios` and `NPM_PACKAGE_NAME=@legios/blackice`. Require the owner's review for the GitHub **npm** environment and restrict its deployment refs to approved release tags.
4. Have security verify those settings before `0.1.1`. The later workflow uses OIDC and provenance on a GitHub-hosted runner, with no npm token or login fallback. Its preparation still verifies the native assets against [GitHub attestations](https://cli.github.com/manual/gh_attestation_verify) and checksums before packing.
