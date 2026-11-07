// What a blackice release is and how its pieces are checked. Plain functions with no I/O, so the
// tests can run anywhere.

export const REPOSITORY = 'ValentinTorassa/blackice'
export const TEAM_ID = 'M294LK997M'
export const APP_IDENTIFIER = 'com.valentorassa.blackice'
export const APP_NAME = 'Blackice.app'
export const APPLICATIONS = '/Applications'
export const INSTALLED_APP = `${APPLICATIONS}/${APP_NAME}`
export const INSTALLED_BINARY = `${INSTALLED_APP}/Contents/MacOS/blackice`
export const INSTALL_GUIDE = `https://github.com/${REPOSITORY}/blob/main/docs/install.md`
/** The network extension inside the app, relative to the app. */
export const EXTENSION_PATH = 'Contents/Library/SystemExtensions/com.valentorassa.blackice.filter.systemextension'

const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/
const BUILD = /^[1-9]\d*$/

/** The release's zip and checksum file, as macos/scripts/package.sh names them, and their URLs. */
export function releaseAssets(version) {
  if (typeof version !== 'string' || !VERSION.test(version)) {
    throw new Error(`not a release version: ${JSON.stringify(version)}`)
  }
  const zipName = `Blackice-${version}.zip`
  const base = `https://github.com/${REPOSITORY}/releases/download/v${version}/`
  return {
    version,
    zipName,
    zipUrl: base + zipName,
    checksumName: `${zipName}.sha256`,
    checksumUrl: `${base}${zipName}.sha256`,
  }
}

/**
 * The SHA-256 in a checksum file written by `shasum -a 256 FILE`: one line, the hash, two spaces
 * (or a space and `*`) and the file name, which must be `expectedName`. Returns the hash in lower
 * case.
 */
export function parseChecksum(text, expectedName) {
  const lines = String(text).split(/\r?\n/).filter((line) => line.trim() !== '')
  if (lines.length !== 1) throw new Error(`the checksum file should hold one line; it holds ${lines.length}`)
  const match = /^([0-9a-fA-F]{64}) [ *](.+)$/.exec(lines[0])
  if (!match) throw new Error('the checksum file does not hold a SHA-256 line')
  if (match[2] !== expectedName) throw new Error(`the checksum file names ${match[2]}, not ${expectedName}`)
  return match[1].toLowerCase()
}

/** The fields `codesign -dvv` prints, first value of each key. */
function fields(text) {
  const map = new Map()
  for (const line of String(text).split(/\r?\n/)) {
    const at = line.indexOf('=')
    if (at > 0 && !map.has(line.slice(0, at))) map.set(line.slice(0, at), line.slice(at + 1).trim())
  }
  return map
}

/**
 * Problems with the signature `codesign -dvv` describes, compared with the expected identifier
 * and Team ID and a Developer ID Application certificate of that team. Empty when it matches.
 */
export function signatureProblems(text, { identifier = APP_IDENTIFIER, teamId = TEAM_ID } = {}) {
  const found = fields(text)
  const problems = []
  if (found.get('Identifier') !== identifier) {
    problems.push(`signed as ${found.get('Identifier') ?? 'nothing'}, not ${identifier}`)
  }
  if (found.get('TeamIdentifier') !== teamId) {
    problems.push(`signed by team ${found.get('TeamIdentifier') ?? 'none'}, not ${teamId}`)
  }
  const leaf = String(text).split(/\r?\n/).find((line) => line.startsWith('Authority='))
  if (!leaf || !leaf.startsWith('Authority=Developer ID Application:') || !leaf.endsWith(`(${teamId})`)) {
    problems.push(`not signed with a Developer ID Application certificate of team ${teamId}`)
  }
  return problems
}

/**
 * Problems with Gatekeeper's assessment, the output of `spctl --assess --type execute -vv APP`:
 * it must be accepted as a notarized Developer ID app of the expected team. Empty when it is.
 */
export function gatekeeperProblems(text, { teamId = TEAM_ID } = {}) {
  const output = String(text)
  const problems = []
  if (!/: accepted$/m.test(output)) problems.push('Gatekeeper does not accept the app')
  if (!/^source=Notarized Developer ID$/m.test(output)) problems.push('Gatekeeper does not see a notarized Developer ID app')
  const origin = /^origin=(.*)$/m.exec(output)?.[1]
  if (origin !== undefined && !origin.endsWith(`(${teamId})`)) problems.push(`Gatekeeper names another origin: ${origin}`)
  return problems
}

/**
 * Problems with the versions in the Info.plist of the app and of its extension, each
 * `{ version, build }` with CFBundleShortVersionString and CFBundleVersion, compared with the
 * release `version`: the app must be that version, with a build number that is a positive whole
 * number, and the extension the same version and build, as macos/scripts/package.sh builds them.
 * Empty when they match.
 */
export function versionProblems({ app, extension }, version) {
  const problems = []
  if (app.version !== version) problems.push(`the app is version ${app.version ?? 'none'}, not ${version}`)
  if (!BUILD.test(app.build ?? '')) problems.push(`the app's build number is ${app.build || 'missing'}, not a positive whole number`)
  if (extension.version !== app.version || extension.build !== app.build) {
    problems.push(`the network extension is version ${extension.version ?? 'none'}, build ${extension.build ?? 'none'}, not the app's`)
  }
  return problems
}

/**
 * Why this Mac's macOS, as `sw_vers -productVersion` prints it, cannot run blackice, or null. 14.4
 * is the first that starts a program only when its signature meets a launch requirement, which
 * is how the daemon starts hooks.
 */
export function macosProblem(productVersion) {
  const [major, minor = '0'] = String(productVersion ?? '').trim().split('.')
  const ok = /^\d+$/.test(major) && /^\d+$/.test(minor) && (Number(major) > 14 || (Number(major) === 14 && Number(minor) >= 4))
  return ok ? null : `blackice needs macOS 14.4 or later; this Mac has ${String(productVersion ?? '').trim() || 'an unknown version'}`
}

/**
 * Whether putting build `build` over an installed app of build `installedBuild` would go back to
 * an older build. False when either is not a whole number.
 */
export function isOlderBuild(build, installedBuild) {
  if (!/^\d+$/.test(build ?? '') || !/^\d+$/.test(installedBuild ?? '')) return false
  return BigInt(build) < BigInt(installedBuild)
}
