import assert from 'node:assert/strict'
import test from 'node:test'

import { gatekeeperProblems, parseChecksum, releaseAssets, signatureProblems } from '../lib/release.mjs'

test('release assets follow package.sh names and the v<version> tag', () => {
  assert.deepEqual(releaseAssets('0.1.0'), {
    version: '0.1.0',
    zipName: 'Blackice-0.1.0.zip',
    zipUrl: 'https://github.com/ValentinTorassa/blackice/releases/download/v0.1.0/Blackice-0.1.0.zip',
    checksumName: 'Blackice-0.1.0.zip.sha256',
    checksumUrl: 'https://github.com/ValentinTorassa/blackice/releases/download/v0.1.0/Blackice-0.1.0.zip.sha256',
  })
  assert.equal(releaseAssets('12.0.3').zipName, 'Blackice-12.0.3.zip')
})

test('release assets refuse anything but a plain version', () => {
  for (const bad of ['', '0.1', '0.1.0-beta.1', 'v0.1.0', '01.1.0', '0.1.0/../x', '0.1.0 ', undefined, 1]) {
    assert.throws(() => releaseAssets(bad), /not a release version/, String(bad))
  }
})

const hash = 'ab'.repeat(32)

test('checksum: shasum -a 256 output', () => {
  assert.equal(parseChecksum(`${hash}  Blackice-0.1.0.zip\n`, 'Blackice-0.1.0.zip'), hash)
  assert.equal(parseChecksum(`${hash.toUpperCase()}  Blackice-0.1.0.zip`, 'Blackice-0.1.0.zip'), hash)
  assert.equal(parseChecksum(`${hash} *Blackice-0.1.0.zip\r\n`, 'Blackice-0.1.0.zip'), hash)
  assert.equal(parseChecksum(`\n${hash}  Blackice-0.1.0.zip\n\n`, 'Blackice-0.1.0.zip'), hash)
})

test('checksum: refuses other files, other formats and several lines', () => {
  assert.throws(() => parseChecksum(`${hash}  Other-0.1.0.zip\n`, 'Blackice-0.1.0.zip'), /names Other-0.1.0.zip/)
  assert.throws(() => parseChecksum(`${hash.slice(1)}  Blackice-0.1.0.zip\n`, 'Blackice-0.1.0.zip'), /SHA-256 line/)
  assert.throws(() => parseChecksum(`${hash}Blackice-0.1.0.zip\n`, 'Blackice-0.1.0.zip'), /SHA-256 line/)
  assert.throws(() => parseChecksum(`${'g'.repeat(64)}  Blackice-0.1.0.zip\n`, 'Blackice-0.1.0.zip'), /SHA-256 line/)
  assert.throws(
    () => parseChecksum(`${hash}  Blackice-0.1.0.zip\n${hash}  Blackice-0.1.0.zip\n`, 'Blackice-0.1.0.zip'),
    /one line; it holds 2/,
  )
  assert.throws(() => parseChecksum('', 'Blackice-0.1.0.zip'), /one line; it holds 0/)
  assert.throws(() => parseChecksum('<html>Not Found</html>', 'Blackice-0.1.0.zip'), /SHA-256 line/)
})

// The shape of `codesign -dvv /Applications/Blackice.app` for build 4, with the certificate's name replaced.
const signed = `Executable=/Applications/Blackice.app/Contents/MacOS/blackice
Identifier=com.valentorassa.blackice
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=3397 flags=0x10000(runtime) hashes=95+7 location=embedded
Signature size=9073
Authority=Developer ID Application: Example Name (M294LK997M)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=3 Nov 2026 at 11:04:13
Notarization Ticket=stapled
Info.plist entries=12
TeamIdentifier=M294LK997M
Runtime Version=14.0.0
`

test('signature: blackice signed with the team Developer ID passes', () => {
  assert.deepEqual(signatureProblems(signed), [])
})

test('signature: another identifier, team or certificate fails', () => {
  assert.match(signatureProblems(signed.replace('Identifier=com.valentorassa.blackice', 'Identifier=com.example.app')).join(), /signed as com.example.app/)
  assert.match(
    signatureProblems(signed.replace('TeamIdentifier=M294LK997M', 'TeamIdentifier=ABCDE12345')).join(),
    /team ABCDE12345, not M294LK997M/,
  )
  assert.match(
    signatureProblems(signed.replace('Developer ID Application: Example Name (M294LK997M)', 'Developer ID Application: Someone (ABCDE12345)')).join(),
    /Developer ID Application certificate of team M294LK997M/,
  )
  assert.match(
    signatureProblems(signed.replace('Authority=Developer ID Application: Example Name (M294LK997M)', 'Authority=Apple Development: Example Name (M294LK997M)')).join(),
    /Developer ID Application certificate/,
  )
  const adhoc = 'Executable=/x/Blackice.app/Contents/MacOS/blackice\nIdentifier=com.valentorassa.blackice\nSignature=adhoc\nTeamIdentifier=not set\n'
  assert.equal(signatureProblems(adhoc).length, 2)
  assert.equal(signatureProblems('').length, 3)
})

const accepted = `/tmp/x/Blackice.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: Example Name (M294LK997M)
`

test('gatekeeper: accepted as a notarized Developer ID app passes', () => {
  assert.deepEqual(gatekeeperProblems(accepted), [])
})

test('gatekeeper: rejected, not notarized or another origin fails', () => {
  assert.match(gatekeeperProblems(accepted.replace('accepted', 'rejected')).join(), /does not accept/)
  assert.match(gatekeeperProblems(accepted.replace('Notarized Developer ID', 'Developer ID')).join(), /notarized/)
  assert.match(gatekeeperProblems(accepted.replace('(M294LK997M)', '(ABCDE12345)')).join(), /another origin/)
  assert.equal(gatekeeperProblems('/tmp/x/Blackice.app: rejected\nsource=no usable signature\n').length, 2)
})
