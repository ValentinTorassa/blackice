# Homebrew formula preparation

This directory prepares a binary formula for the future
ValentinTorassa/homebrew-blackice tap. It does not create that repository or
publish a release. The template is not an installable formula until rendered
with the checksums of a reviewed release.

From this checkout, with Python 3 available:

~~~sh
scripts/release/brew-formula.sh 1.2.3 /path/to/reviewed/SHA256SUMS > /tmp/blackice.rb
~~~

Review the output before copying it to Formula/blackice.rb in the tap that the
owner creates. The intended install command after publication is:

~~~sh
brew install valentintorassa/blackice/blackice
~~~

The version must be X.Y.Z with no leading v, prerelease or build metadata,
matching the release workflow's vX.Y.Z tags. URLs use the tag vVERSION in
ValentinTorassa/blackice. The renderer reads local files and writes only stdout;
it never downloads, builds, installs, tags, pushes or publishes.

## Required release files

SHA256SUMS must contain exactly one entry for each of:

~~~text
blackice-VERSION-aarch64-macos
blackice-VERSION-x86_64-macos
blackice-VERSION-aarch64-linux
blackice-VERSION-x86_64-linux
blackice-linux-helper-VERSION-x86_64-linux
linux-setup.sh
linux-teardown.sh
~~~

Use the usual sha256sum format: 64 hexadecimal digits, a space, a space or
asterisk, then a bare filename. Extra distinct entries are permitted. Missing,
duplicate, malformed and path-containing entries fail before any formula is
printed. SHA256SUMS must not include itself. Its resource digest is computed
from the exact supplied bytes, including line endings; every other digest
comes from an entry in that file.

The renderer validates syntax and completeness, not provenance or review.
Use the authenticated release manifest and the security-reviewed helper and
setup script. Never substitute a development hash or a checksum from an
unreviewed download to make a release formula render.

## Linux setup contract

On Linux x86_64, the formula copies the versioned helper, linux-setup.sh,
linux-teardown.sh and the unchanged SHA256SUMS into
share/blackice/linux-setup/, all mode 0644. It preserves filenames so the bundle
still matches the manifest. Only the launcher goes into bin/ as blackice, with
mode 0755 explicitly set because its Homebrew cleanup is disabled.

Linux arm64 ships only the CLI until an arm64 Linux run verifies task scopes.
It downloads and installs no helper, setup scripts or manifest bundle. An arm64
helper checksum is not required, and even if present in SHA256SUMS it is not
used to select or distribute a helper.

The x86_64 caveats identify the privileged helper as a separate setup step and
link to docs/linux.md at the release tag. They print these verification commands
with the actual installed paths before any privileged operation is considered:

~~~sh
gh attestation verify "<setup-directory>/blackice-linux-helper-VERSION-x86_64-linux" --repo ValentinTorassa/blackice --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml
gh attestation verify "<setup-directory>/linux-setup.sh" --repo ValentinTorassa/blackice --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml
gh attestation verify "<setup-directory>/linux-teardown.sh" --repo ValentinTorassa/blackice --signer-workflow ValentinTorassa/blackice/.github/workflows/release.yml
~~~

There is no sudo command in the caveats. The reviewed linux-setup.sh accepts
exactly two arguments and reads the helper from ../zig-out/bin; it cannot use
this bundle directly. A future helper-path interface must be implemented,
security-reviewed and pinned before a setup command can be added. If that
command is added later, these three attestation checks must remain before it.
Packaging does not change the privileged script or bypass its checks.

There is no postinstall, service or package-manager sudo/setcap call. An upgrade
only replaces the unprivileged files; the owner reviews and repeats setup to
replace the separately installed privileged helper. Teardown also remains a
manual, reviewed operation.

The macOS formula contains only the CLI; it does not ship or activate the
unsigned Network Extension app filter.

## Validation

~~~sh
python3 packaging/homebrew/test_renderer.py
bash -n scripts/release/brew-formula.sh
ruby -c /tmp/blackice.rb
brew style /tmp/blackice.rb
~~~

Run the Homebrew checks only where their tooling is already installed. Disable
auto-update and analytics for preparation; do not install gems, tap repositories
or the formula just to run these checks. Current Homebrew requires a formula
name for audit, so after the owner creates and populates the tap, run:

~~~sh
brew audit --strict --formula valentintorassa/blackice/blackice
~~~

Online audits and brew test remain release gates with published assets and a
separate authorized install. The formula's test block runs blackice version
without starting a scope. Synthetic manifests can validate rendering and
platform selection, but do not establish release provenance or runtime support.

After an authorized release install, compare the installed launcher's bytes
and Linux bundle against the release checksums on each OS/architecture.
skip_clean preserves the shipped executable and setup data during Homebrew
cleaning; the release installation check still needs to verify the final bytes.

References: [Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
(platform blocks, resource staging and nounzip), and
[checksum requirements](https://docs.brew.sh/Checksum-Requirements).
