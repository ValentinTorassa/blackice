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

The version has no leading v. X.Y.Z and SemVer prereleases such as 1.2.3-rc.1
are accepted; build metadata is not. URLs use the tag vVERSION in
ValentinTorassa/blackice. The renderer reads local files and writes only stdout;
it never downloads, builds, installs, tags, pushes or publishes.

## Required release files

SHA256SUMS must contain exactly one entry for each of:

~~~text
blackice-VERSION-aarch64-macos
blackice-VERSION-x86_64-macos
blackice-VERSION-aarch64-linux
blackice-VERSION-x86_64-linux
blackice-linux-helper-VERSION-aarch64-linux
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

The formula copies the architecture's versioned helper, linux-setup.sh,
linux-teardown.sh and the unchanged SHA256SUMS into
share/blackice/linux-setup/, all mode 0644. It preserves filenames so the bundle
still matches the manifest. Only the launcher goes into bin/ as blackice, with
mode 0755 explicitly set because its Homebrew cleanup is disabled.

The caveats print the actual installed setup path, the helper's manifest hash
and its explicit path:

~~~text
sudo bash "<setup-directory>/linux-setup.sh" "$USER" <reviewed-helper-sha256> "<setup-directory>/blackice-linux-helper-VERSION-TARGET"
~~~

Release integration gate: linux-setup.sh must accept
USER EXPECTED_SHA256 [HELPER_PATH], with the optional third argument selecting
this file while preserving root-owned staging and hash verification before
capabilities. The current two-argument checkout-only script is not compatible
with this bundle. Its owner must implement and security-review that change
before a release formula is used. Packaging does not change the privileged
script or bypass its checks.

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
