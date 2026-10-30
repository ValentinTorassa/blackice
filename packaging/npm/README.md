# npm distribution

Version **0.1.0** uses a launcher package and four optional platform packages. The scripts here prepare and audit local tarballs; they do not publish, reserve names, log in to npm, build binaries or change a privileged installation. The checked-in manifests are private templates, not publishable packages.

| Output directory | Default package | Platform | Payload beyond metadata, README and license |
| --- | --- | --- | --- |
| `blackice/` | `blackice` | Node.js 22+ | 33-line launcher |
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

The manifest may also list `linux-setup.sh`, `linux-teardown.sh` and `blackice-linux-helper-0.1.0-{x86_64-linux,aarch64-linux}` from the separate root setup. The preparer never reads or copies those payloads. The publish workflow verifies every asset listed in the full release manifest, including those outside npm. An absent ARM helper does not block CLI packaging.

Verify release attestations before preparing public packages. The preparer checks CLI integrity, not provenance: its output records `verification: "sha256-only"`. A locally produced checksum file does not establish release identity. Label local fixtures as test inputs, not attested releases.

From the repository root:

```sh
node packaging/npm/prepare.mjs \
  --release-dir /absolute/path/to/verified-release \
  --out-dir out/npm-0.1.0 \
  --version 0.1.0 --scope @legios --name blackice

node packaging/npm/pack.mjs \
  --prepared-dir out/npm-0.1.0 \
  --out-dir out/npm-tarballs-0.1.0
```

`--version`, `--scope` and `--name` default to the values shown. A different scope and main name leave the command name `blackice` unchanged; platform packages retain the `blackice-<platform>` prefix. The workflow requires explicit `NPM_SCOPE` and `NPM_PACKAGE_NAME` repository variables instead of relying on defaults. The operator must control all five identities and configure their trusted publishers before release.

Both output directories must be new. Required checksums must occur exactly once; duplicate, unknown, path-bearing and missing CLI entries are rejected. Versions must be stable `X.Y.Z`. Inputs must be bounded regular files, not symlinks. The preparer hashes each CLI and copies that same in-memory snapshot, preserving its bytes with explicit executable permissions, then atomically moves the completed output into place. `manifest.json` records source asset hashes and platform-first package order.

The packer checks exact identities, versions, platform selectors, dependency pins, the launcher map and the four-file allowlist. It runs `npm pack --dry-run --ignore-scripts --offline --json` and `npm pack` with the same flags for all packages. It verifies archive entries, extracted bytes and npm integrity hashes. Only after all five archives pass does it write `packs.json` and `publish-order.txt`. Partial output on failure is not publishable; start again with a fresh directory.

## Manual Linux setup

npm installation does not establish the Linux enforcement boundary. Obtain the reviewed helper and scripts separately from the matching GitHub release or its source checkout, and review the [Linux backend setup instructions](../../docs/linux.md). For x86_64, first verify the downloaded manifest and root setup assets against the release workflow and tag:

```sh
# Run in the directory containing the separately downloaded v0.1.0 release assets.
gh attestation verify SHA256SUMS --repo ValentinTorassa/blackice \
  --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml \
  --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners
sha256sum -c SHA256SUMS

gh attestation verify blackice-linux-helper-0.1.0-x86_64-linux \
  --repo ValentinTorassa/blackice \
  --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml \
  --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners
gh attestation verify linux-setup.sh --repo ValentinTorassa/blackice \
  --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml \
  --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners
gh attestation verify linux-teardown.sh --repo ValentinTorassa/blackice \
  --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml \
  --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners
```

Use the independently verified manifest's helper digest when following that separate setup procedure. Setup is an explicit operator action outside npm, using the reviewed checkout layout and architecture. Do not source a root-install digest from npm metadata. If no reviewed helper exists for the host CPU, installing a CLI package does not make task scopes supported. These are future release instructions, not a claim that version 0.1.0 is already published.

## Validation and launcher behavior

```sh
node --test packaging/npm/test.mjs
```

The suite checks changed bytes and malformed checksums, CLI-only releases, configurable scope/name/version, exact archive contents, launcher arguments and I/O, missing packages, numeric exits and signal exits. It exercises the production packer on all five packages, then installs local tarballs offline with scripts disabled and runs the installed launcher. Synthetic test executables do not establish native enforcement.

To exercise a real local binary, prepare a clearly labeled local build fixture, install its matching platform and launcher tarballs offline, and run `blackice version` plus a harmless command. Record the actual binary hash, source commit and reported version. Packaging metadata alone does not establish any of them.

The launcher uses `spawnSync` with inherited stdio and no shell. It mirrors numeric exit status and re-emits the child's termination signal. Terminal signals reach both processes through their shared foreground process group. Because synchronous spawning blocks JavaScript signal handlers, a signal addressed only to the launcher PID is not forwarded while its child runs. Use a supervisor that signals the process group or invoke the native binary directly; immediate PID-only forwarding would require an asynchronous launcher. See [Node's synchronous child-process contract](https://nodejs.org/api/child_process.html#child_processspawnsynccommand-args-options).

## Release-triggered publication

[npm-publish.yml](../../.github/workflows/npm-publish.yml) runs only on `release: published`, after the operator publishes a reviewed draft. It refuses prereleases and requires the release tag's commit to be on `main`. There is no dispatch, push or pull-request trigger. Security reviews changes to this workflow before use.

Required operator configuration:

1. Set repository variables `NPM_SCOPE=@legios` and `NPM_PACKAGE_NAME=blackice`, or explicitly approved alternatives whose identities the operator owns.
2. Create GitHub environment **npm**, require the operator's review, and restrict deployment refs to approved release tags. The YAML selects this environment; its protection rules are repository settings.
3. Configure each of the five npm packages' trusted publishers for repository `ValentinTorassa/blackice`, workflow filename **npm-publish.yml**, environment **npm**, with direct `npm publish` allowed. Initial package setup and ownership verification are operator work; this branch does neither.

The job uses only `contents: read` and `id-token: write`, SHA-pinned actions, Node 22.23.3 and npm 12.2.0. [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/) uses OIDC on a GitHub-hosted runner; there is no npm token, login or credential fallback. npm user/global configuration files and its cache are isolated for the job.

Before packing, the job downloads the tag's assets with `gh release download`, verifies the checksum manifest's attestation, validates its filenames, and runs `sha256sum -c SHA256SUMS`. It then verifies [GitHub attestations](https://cli.github.com/manual/gh_attestation_verify) for **every listed asset**, binding them to `release.yml`, the source repository, exact tag and checked-out commit, and refusing self-hosted build runners. Only then does it run the host CLI to require `blackice 0.1.0` (or the corresponding tag version).

After all five archives pass the packer's checks, the job publishes the four platform tarballs first and the launcher last with `npm publish --provenance --access public --ignore-scripts`. A failed platform publish stops before the launcher. npm versions are immutable; a partial publication needs operator reconciliation rather than an automatic overwrite or name change. Publishing is never part of the local tests.

Release attestations establish where the native bytes came from; npm provenance establishes where their packages were assembled. Local tests and mocked workflow checks do not verify live OIDC, registry ownership or release attestations. Those require the configured environment and a real reviewed release.
