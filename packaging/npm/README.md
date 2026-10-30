# npm distribution preparation

This directory prepares version **0.1.0** using a main launcher package and four optional platform packages. It does not publish, reserve names, log in to npm, build binaries, or change a privileged installation. The checked-in package manifests are private templates; prepare the output before packing.

| Output directory | Default package | Platform | Payload beyond metadata, README and license |
| --- | --- | --- | --- |
| `blackice/` | `blackice` | Node.js 22+ | 32-line launcher |
| `darwin-arm64/` | `@blackice/darwin-arm64` | macOS arm64 | `bin/blackice` |
| `darwin-x64/` | `@blackice/darwin-x64` | macOS x64 | `bin/blackice` |
| `linux-x64/` | `@blackice/linux-x64` | Linux x64 | `bin/blackice` and Linux setup data |
| `linux-arm64/` | `@blackice/linux-arm64` | Linux arm64 | `bin/blackice` and Linux setup data |

The main package has no regular dependencies. Its four optional dependencies use exact matching versions. Each platform package declares `os` and `cpu`. There are no lifecycle scripts, registry fallback, PATH fallback, or runtime downloads. Node's architecture selects the binary; use a matching Node installation on the target machine.

## Release input and preparation

The input is a local directory containing these eight raw release assets and `SHA256SUMS`:

```text
blackice-0.1.0-aarch64-macos
blackice-0.1.0-x86_64-macos
blackice-0.1.0-x86_64-linux
blackice-0.1.0-aarch64-linux
blackice-linux-helper-0.1.0-x86_64-linux
blackice-linux-helper-0.1.0-aarch64-linux
linux-setup.sh
linux-teardown.sh
SHA256SUMS
```

Verify release attestations before preparing a public package. The preparer checks integrity, not provenance: its output manifest explicitly records `verification: "sha256-only"`. A locally produced checksum file does not establish release identity. For local packaging tests, use clearly labeled local fixtures rather than presenting them as attested releases.

From the repository root:

```sh
node packaging/npm/prepare.mjs \
  --release-dir /absolute/path/to/verified-release \
  --out-dir out/npm-0.1.0 \
  --version 0.1.0 --scope @blackice --name blackice
```

`--version`, `--scope` and `--name` default to the values shown. A different scope and main name can be supplied without changing the command name `blackice`. Name availability, organization creation and trusted-publisher configuration remain operator work.

The output directory must not exist. All eight assets must have exactly one checksum entry; missing, duplicate, unexpected or path-bearing entries are rejected. Inputs must be bounded regular files, not symlinks. The preparer hashes each input and copies that same in-memory snapshot, then moves the completed output into place. It preserves asset bytes and sets explicit file permissions. `manifest.json` maps source assets to package paths and lists platform packages before the main package.

## Linux setup data

The helper and scripts are shipped as non-executable data:

```text
linux-setup/
  SHA256SUMS
  scripts/linux-setup.sh
  scripts/linux-teardown.sh
  zig-out/bin/blackice-linux-helper
```

This preserves the reviewed setup script's `../zig-out/bin/blackice-linux-helper` lookup without changing it. `SHA256SUMS` is the original release manifest; filenames in it refer to release assets. Each generated platform README maps those names to installed paths, records their hashes, and shows the explicit operator setup command with the matching helper digest. Setup installs a verified copy outside npm's tree; package installation applies no capabilities and runs no sudo. Verify the scripts and helper's provenance before any root operation.

## Validation and packing

```sh
node --test packaging/npm/test.mjs
```

The suite checks refusal of altered input and malformed checksums, version/scope changes, exact package contents, launcher arguments and I/O, missing packages, exit statuses and signal exits. It runs `npm pack --dry-run --ignore-scripts --offline --json` for all five packages, then installs local tarballs offline with scripts disabled and runs the installed launcher. Test executables are synthetic fixtures, not native enforcement evidence.

For prepared release packages, run this from each of the five output directories:

```sh
npm pack --dry-run --ignore-scripts --offline --json
npm pack --ignore-scripts --offline --json
```

Inspect the file lists and verify extracted binary bytes against the release checksums. To exercise a real local binary, prepare a local build fixture, install or link its matching platform package next to the launcher, and run `blackice version`. Record the actual binary hash and version; packaging metadata alone does not establish either.

The launcher uses `spawnSync` with inherited stdio and no shell. It mirrors numeric exit status and re-emits a child's termination signal. Terminal signals reach both processes through their shared foreground process group. Because synchronous spawning blocks JavaScript signal handlers, a signal addressed only to the launcher PID is not forwarded while its child runs. Use a supervisor that signals the process group or invoke the native binary directly; immediate PID-only forwarding would require an asynchronous launcher. See [Node's synchronous child-process contract](https://nodejs.org/api/child_process.html#child_processspawnsynccommand-args-options).

## Publishing-job contract

Security owns `.github/` and the publishing workflow. Before enabling it:

1. Configure all five package identities for the exact repository, workflow filename and protected `npm` environment. The operator controls the name/org and initial package setup. Explicitly allow direct `npm publish` for each trusted publisher if that is the chosen route.
2. Use a GitHub-hosted runner with pinned actions, Node and npm. [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/) requires Node 22.14.0+ and npm 11.5.1+. Give only the publish job `id-token: write`; use OIDC with no npm token and no fallback credential.
3. On the operator-approved published release, validate the stable tag and expected source commit. Download the assets, verify the manifest and each file's [GitHub attestation](https://cli.github.com/manual/gh_attestation_verify) against the release workflow, source repository, tag and commit, then run the preparer. The manifest checksum alone is insufficient. Check the native version against the release version.
4. Dry-run and pack all five packages with scripts disabled. Publish the four platform tarballs first and the main tarball last, using `npm publish --provenance --access public --ignore-scripts`. Keep exact versions aligned. This directory has no publish command or workflow that can run automatically.

Release-binary attestations establish where the native bytes came from; npm provenance establishes where their package was assembled. Both checks matter. The job must not turn this preparation branch, an unverified local fixture, or a missing platform upload into a public main-package release.
