# Phase 0: activation day

What to do once the Apple Developer Program membership is active: create the certificate, App IDs and profiles,
sign Blackice.app, and run the phase 0 check. *Done when* a small binary signed with our Team ID is blocked under
block-all while the system `curl` still works.

**What has been tested so far.** The filter's decisions are unit-tested with fake flows (`macos/test.sh`), and
`DRY=1 macos/scripts/sign.sh` builds and signs the app ad hoc, locally and in CI. Nothing below has run with a
Developer ID yet: the extension has never been activated, and the system-facing code (extension activation, the
filter preference, Touch ID, the NetworkExtension glue) has only been compiled. Where this page names a portal or
System Settings label from memory, it says so.

You need: a Mac with Apple silicon (the build is arm64 only), the Command Line Tools, an admin account, and this
repository at `~/Documents/Github/Personal/blackice` on `main`.

## Steps

1. **Find the Team ID.** Sign in at [developer.apple.com/account](https://developer.apple.com/account). Under
   Membership details, note the Team ID: 10 upper-case letters and digits. The commands below call it `TEAM_ID`.

2. **Make a certificate signing request in Keychain Access.**
   1. Open Keychain Access (search for it in Spotlight).
   2. In the menu bar: Keychain Access > Certificate Assistant > Request a Certificate From a Certificate
      Authority…
   3. User Email Address: your Apple Account email. Common Name: your name. CA Email Address: leave empty.
      Request is: Saved to disk. Continue, and save `CertificateSigningRequest.certSigningRequest`.

   This also creates the certificate's private key in your login keychain. It stays on this Mac.

3. **Create the Developer ID Application certificate.**
   1. In the account, open Certificates, Identifiers & Profiles > Certificates and click +.
   2. Under Software, choose **Developer ID Application**. Continue.
   3. If asked for a profile type, choose the G2 Sub-CA option (label from memory).
   4. Upload the CSR from step 2, continue, and download the `.cer` file.
   5. Double-click the `.cer` file to add it to the login keychain, then check:

      ```console
      $ security find-identity -v -p codesigning
      ```

      One line should read `"Developer ID Application: <your name> (TEAM_ID)"`.

4. **Register two App IDs.** Identifiers > + > App IDs > App. For each, choose an explicit Bundle ID:

   | Description | Bundle ID | Capabilities |
   |---|---|---|
   | blackice | `com.valentorassa.blackice` | Network Extensions, System Extension |
   | blackice filter | `com.valentorassa.blackice.filter` | Network Extensions |

   If the portal shows options under Network Extensions, choose Content Filter. (Not sure the portal shows any;
   the content filter value itself comes from the entitlements file.) Continue, then Register.

5. **Create two Developer ID provisioning profiles.** Profiles > +. Under Distribution choose **Developer ID**,
   then:
   1. App ID `com.valentorassa.blackice`, the certificate from step 3, name `blackice Developer ID`. Generate,
      then download.
   2. The same for `com.valentorassa.blackice.filter`, named `blackice filter Developer ID`.

   Keep both files outside the repository, for example in `~/blackice-signing/`. (The repository ignores
   `*.provisionprofile` in any case.) `sign.sh` checks each profile's team, App ID, content filter entitlement and
   expiry, and that it names your certificate.

6. **Store notarization credentials.** macOS activates a Developer ID system extension only from a notarized app,
   even a local build that was never downloaded. Without notarization, `blackice start` fails with
   `OSSystemExtensionErrorDomain 8: code signature invalid`, and `sysextd` logs that the extension does not satisfy
   its code requirement (2 November 2026, macOS 27.0.1).
   1. At [account.apple.com](https://account.apple.com), under Sign-In and Security > App-Specific Passwords,
      create one named `notarytool`.
   2. Run this and paste that password at the prompt:

      ```console
      $ xcrun notarytool store-credentials blackice-notary --apple-id <your Apple Account email> --team-id TEAM_ID
      ```

7. **Build and sign.**

   ```console
   $ cd ~/Documents/Github/Personal/blackice
   $ macos/scripts/sign.sh TEAM_ID ~/blackice-signing/<app profile>.provisionprofile \
         ~/blackice-signing/<filter profile>.provisionprofile blackice-notary
   ```

   Without `blackice-notary` the app is not notarized and the extension will not activate. When macOS asks whether
   `codesign` may use the key, type your login password and choose Always Allow. The script builds into
   `macos/build/sign-<time>/`, signs the extension and then the app with the hardened runtime and a secure timestamp,
   verifies both, then notarizes and staples the app. It ends with the path of `Blackice.app` and the next command.

8. **Run the phase 0 check.**

   ```console
   $ macos/scripts/phase0-test.sh TEAM_ID macos/build/sign-<time>/Blackice.app
   ```

   It signs a small probe as `com.valentorassa.blackice.probe` with your Developer ID and checks that it reaches
   pypi.org. Then it installs the app in `/Applications` and starts blackice in accept-all with one rule: the
   system `curl` may reach pypi.org. It runs the probe and `curl` in accept-all, then in block-all, prints the
   filter's log and rolls back. What you approve, in order:
   1. `codesign` using the key for the probe: Always Allow, as in step 7.
   2. Touch ID for `blackice: start filtering (mode accept-all, 1 allow rule, 0 hooks, generation 1)`.
   3. The extension. macOS reports that it was blocked. Open System Settings > General > Login Items &
      Extensions > Network Extensions and turn on Blackice. On some versions this is in Privacy & Security
      instead, as an Allow button. Labels from memory; they vary by macOS version. `blackice start` waits up to
      10 minutes for this.
   4. "Blackice" would like to filter network content: Allow.
   5. Touch ID for block-all, then Touch ID to switch back to accept-all.
   6. Touch ID for `blackice stop` during the rollback (skipped with `KEEP=1`).

   While block-all is on, for a few seconds, apps without a rule lose the network. If the script stops in that
   window, it switches back to accept-all on its way out.

   Expected: four `PASS` lines. In the log, the probe's connection shows as `flow drop no_rule`, `curl`'s as
   `flow allow rule_line_4` or `flow allow rule_line_4;server_name`, and DNS as `flow allow system_resolver`.
   Since 5 November 2026 each line also names the app in the clear (`app=apple/com.apple.curl`); the
   host and the rest are private in unified logging and show as `<private>`.

9. **Record the result** in `docs/plan.md` under phase 0: the date, the macOS version and the four result lines.
   If something fails, keep the script's output, the log lines and `systemextensionsctl list`.

## Rebuilding

`phase0-test.sh` reuses an installed `/Applications/Blackice.app` of the same build (same CDHash), so a run that
stopped while macOS waited for approval can be retried after allowing the extension. It refuses any other build, so
roll back before installing a new one. macOS replaces an installed extension only with the same or a higher `CFBundleVersion`. To install a
new build over a running one without stopping it, raise the number:
`BUILD_NUMBER=2 macos/scripts/sign.sh …`.

## Rollback

```console
$ macos/scripts/phase0-test.sh --rollback
```

This runs `blackice stop` (Touch ID), which disables and removes blackice's filter configuration and deactivates
the extension, then deletes `/Applications/Blackice.app`. `systemextensionsctl list` may show the extension as
waiting to uninstall until the next restart.

If `blackice stop` fails:

1. Run it directly to see its message: `/Applications/Blackice.app/Contents/MacOS/blackice stop`. It needs no
   network.
2. In System Settings > Network, open the filters section and remove blackice's content filter (label from
   memory; it is near VPN).
3. In System Settings > General > Login Items & Extensions > Network Extensions, turn Blackice off.
4. Move `/Applications/Blackice.app` to the Trash. macOS should offer to remove its extension; not tested.
5. Restart, then check that `systemextensionsctl list` no longer shows `com.valentorassa.blackice.filter` as
   `activated enabled`.

A restart alone does not turn the filter off: macOS keeps a saved content filter enabled across restarts. Only
apps without a rule are affected in block-all, and `blackice stop` works without the network.
