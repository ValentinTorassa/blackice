# Installing blackice

> **Draft.** blackice is a proof of concept and has no release yet. Today you build it from source.
> Sections marked **After the first release** describe how releases will work; none of those files exist yet,
> and file names may still change before then.

blackice is one binary per platform, built with the Zig standard library only. It has no runtime dependencies
and nothing runs at install time. On Linux it also needs a small privileged helper, which the machine's owner
installs once with an explicit `sudo` command. On macOS nothing else is installed.

| Platform | Binary | Extra step |
|---|---|---|
| macOS 13 or later (minimum not final), Apple silicon and Intel | `blackice-aarch64-macos`, `blackice-x86_64-macos` | none |
| Linux x86_64 and aarch64, static | `blackice-x86_64-linux`, `blackice-aarch64-linux` | the helper, once ([below](#linux-the-helper)) |

The Linux backend needs unified cgroup v2, cgroup BPF socket hooks and Landlock ABI 6. Linux 6.12 is the
initial target. See [linux.md](linux.md) for the full list.

## Build from source (today)

You need git and Zig 0.17.0 exactly. Check the Zig download before you use it: ziglang.org publishes a sha256
for every file in [download/index.json](https://ziglang.org/download/index.json), plus a minisign signature
and the key to check it on the [download page](https://ziglang.org/download/).

```sh
git clone https://github.com/ValentinTorassa/blackice
cd blackice
zig build test        # unit tests
zig build release     # stripped release binaries in zig-out/release/
```

`zig build release` builds every target listed above with ReleaseSafe and stripped debug info. On one machine,
the same commit built with the same Zig has given the same bytes in different directories; the third
verification level below relies on that. Matching bytes across different machines is the goal, not yet shown
(see level 3). `-Dmacos-min=13.0` sets the oldest macOS the binaries start on (13.0 by default).

`zig build` alone gives a development build for this machine in `zig-out/bin/blackice`. It keeps debug
information, so its bytes depend on where you built it.

## Download (after the first release)

Each release on [the releases page](https://github.com/ValentinTorassa/blackice/releases) will carry:

| File | What it is |
|---|---|
| `blackice-<target>` | the binary for one target |
| `blackice-linux-helper-<arch>-linux` | the Linux helper, for the one-time setup |
| `linux-setup.sh`, `linux-teardown.sh` | the owner's setup and recovery scripts |
| `SHA256SUMS` | the sha256 of every file above |

Download with `curl`, not a browser. On macOS that also avoids the quarantine step ([below](#macos)).
For example, for vX.Y.Z on an Apple silicon Mac:

```sh
v=vX.Y.Z
base=https://github.com/ValentinTorassa/blackice/releases/download/$v
curl -fLO "$base/blackice-aarch64-macos"
curl -fLO "$base/SHA256SUMS"
```

## Verify before you run it (after the first release)

There are three levels. Each one checks more and asks you to trust less.

### 1. Checksum

```sh
grep ' blackice-aarch64-macos$' SHA256SUMS | shasum -a 256 -c -     # macOS
grep ' blackice-x86_64-linux$' SHA256SUMS | sha256sum -c -          # Linux
```

This catches a broken or truncated download. It does not protect you from someone who can change both the
binary and `SHA256SUMS`.

### 2. Provenance

Every file in a release has its own build provenance attestation. It is a Sigstore signature made by the
repository's release workflow and recorded in a public transparency log. With the
[GitHub CLI](https://cli.github.com/) (a version that has `gh attestation`):

```sh
gh attestation verify blackice-aarch64-macos \
  --repo ValentinTorassa/blackice \
  --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml \
  --source-ref refs/tags/vX.Y.Z \
  --deny-self-hosted-runners
```

This proves the file was built by blackice's release workflow on a GitHub-hosted runner from the tagged
commit. No one could have swapped it after the build, and no signing key exists that could leak. Run the same
command for `SHA256SUMS`, and on Linux for the helper and both scripts. To keep the attestation for later, `gh
attestation download blackice-aarch64-macos --repo ValentinTorassa/blackice` saves it as
`sha256-<digest>.jsonl`, and `--bundle` verifies against that file.

### 3. Rebuild it yourself

Levels 1 and 2 still trust GitHub and the release workflow. To trust neither, build the same tag yourself and
compare:

```sh
git clone --branch vX.Y.Z https://github.com/ValentinTorassa/blackice
cd blackice
git rev-parse HEAD                  # the commit the attestation names (see --format json in level 2)
zig build release                   # Zig 0.17.0, checked as above
shasum -a 256 zig-out/release/*     # Linux: sha256sum
```

Each hash must equal the one in `SHA256SUMS`. If the release notes give a `-Dmacos-min` other than the default,
pass the same value. The release workflow is planned to build every file twice, on a Linux runner and on a macOS
runner, and to fail unless both builds match. Until it does, a rebuild on another machine is expected, not
shown, to give the same bytes: every matching build so far came from one Linux machine. Please report a
mismatch.

## Install

Put the verified binary on your PATH. No root is needed:

```sh
mkdir -p ~/.local/bin
install -m 0755 blackice-aarch64-macos ~/.local/bin/blackice
blackice version
```

If another program will start blackice for you, for example an agent tool's launch hook, install it root-owned
instead and point that program at this path. A binary in your home directory can be replaced by anything that
runs as you outside a scope, such as the agent's own file-editing tools, and the next launch would then run
whatever was put there.

A root-owned file is only safe if every directory above it is root-owned and not writable by you as well.
Otherwise you can still rename or delete the file and put another one under the same name. So use a directory
of blackice's own, created root-owned, rather than a shared one: on an Intel Mac with Homebrew, `/usr/local/bin`
belongs to you, and on Apple silicon it may not exist.

```sh
# macOS (on Linux, use -g root and the blackice-<arch>-linux binary)
sudo install -d -m 0755 -o root -g wheel /usr/local/libexec/blackice
sudo install -m 0755 -o root -g wheel blackice-aarch64-macos /usr/local/libexec/blackice/blackice
ls -ld / /usr /usr/local /usr/local/libexec /usr/local/libexec/blackice
```

Check every line of the `ls`: owner root, and no `w` in the group or other columns. `install -d` sets the owner
and mode of the last directory only, so the parents need this check.

The policy file that program passes needs the same: put it in that directory (root-owned, mode 0644), or in
another directory whose whole chain is root-owned, and never inside the agent's workspace. A root-owned policy
in a directory you own can be replaced like the binary.

## macOS

Nothing else to install. The macOS backend uses Seatbelt through `/usr/bin/sandbox-exec`: no root, no kernel
or system extension, no entitlement.

**Quarantine.** A file downloaded with a browser gets the `com.apple.quarantine` attribute, and Gatekeeper
refuses to start a binary that is not notarized. blackice is not notarized yet, because that needs an Apple
Developer ID the project does not have. Downloads made with `curl` do not get the attribute. If you used a
browser, verify the file first (levels 1 and 2 at least), then remove the attribute from that file only:

```sh
xattr -d com.apple.quarantine ./blackice-aarch64-macos
```

Never remove the attribute from a file you have not verified.

App scopes (the Network Extension filter) are not part of any release until they can be signed and notarized.

## Linux: the helper

The kernel side of a Linux task scope is armed by `blackice-linux-helper`, a small static binary with four file
capabilities (`cap_bpf`, `cap_net_admin`, `cap_chown`, `cap_dac_override`). blackice itself and the commands
you run get no privileges. The owner installs the helper once with `linux-setup.sh`. Read the script before you
run it as root: it is short, uses absolute paths, and prints every step.

The setup takes the user who will run blackice and the sha256 of the helper you checked. It copies the helper to
a root-only staging file, refuses to continue if that copy's hash differs from the one you gave, and only then
sets the owner, mode and capabilities and checks them again. What it changes:

- `/usr/local/libexec/blackice-linux-helper`: root:<the user's group>, mode 0750, the four capabilities.
- `/etc/blackice-linux/namespaces`: the host namespace ids (root, 0644).
- `/sys/fs/cgroup/blackice`: the parent of the scope cgroups (root, 0700).

It does not touch firewall rules, sysctl, sudoers, services or packages. Cgroups do not survive a reboot, so
**run the setup again after each reboot** (same command, same hash).

### From a source checkout (today)

```sh
git rev-parse HEAD                     # the commit you reviewed
git status --short                     # must print nothing
bash scripts/linux-build-helper.sh     # as yourself, not root; prints the helper's sha256
```

Compare that hash with an independent build of the same commit, for example one made in another clone, or one a
reviewer published for that commit. The script pins the target and CPU (`-target <arch>-linux -mcpu=baseline`),
so the helper does not depend on the build machine's processor. Builds on two different machines have not been
compared yet. Then:

```sh
sudo bash scripts/linux-setup.sh "$USER" <sha256 of the helper>
sha256sum /usr/local/libexec/blackice-linux-helper   # the same hash
getcap /usr/local/libexec/blackice-linux-helper
```

Use `bash`, not `sh`: the scripts need Bash.

### From a release (after the first release)

1. Download the helper for your architecture, `linux-setup.sh`, `linux-teardown.sh` and `SHA256SUMS`.
2. Verify all four (levels 1 and 2). Level 3 for the helper is `bash scripts/linux-build-helper.sh` in a checkout
   of the tag, with the same caveat as above: matching hashes across machines are expected, not yet shown.
3. Read the helper's hash in `SHA256SUMS`, and pass that value yourself:

```sh
grep ' blackice-linux-helper-x86_64-linux$' SHA256SUMS
sudo bash linux-setup.sh "$USER" <that sha256> ./blackice-linux-helper-x86_64-linux
```

The third argument, the path of the downloaded helper, is planned for the first release. Today the script reads
the helper from a source checkout's `zig-out/bin/`.

No installer or package manager will ever run this step for you, and these docs will never ask you to pipe a
download into `sudo bash`.

### Undo

```sh
sudo bash scripts/linux-teardown.sh    # or the release's linux-teardown.sh
```

It stops new launches, ends blackice's scope cgroups and removes the helper and its configuration. It is safe to
repeat. See [linux.md](linux.md) for recovery details.

## Homebrew, npm and other installers

None exist yet. If one is added, it will install the same files as the release, verifiable the same way, and it
will not run the Linux setup for you.

## Uninstall

- Delete the `blackice` binary.
- Linux: run the teardown above.
- Scope state (receipts and policy copies) is under `$XDG_STATE_HOME/blackice/`, by default
  `~/.local/state/blackice/`. Delete it when you no longer need the receipts.
