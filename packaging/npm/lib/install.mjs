// `npx blackice install`: downloads the release zip and its checksum from GitHub, checks them,
// checks the unpacked app's signature, Gatekeeper's assessment and version, and puts the app in
// /Applications. Uses only Node's own modules and the macOS tools in /usr/bin, /usr/sbin and
// /usr/libexec.

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createWriteStream, lstatSync, mkdtempSync, renameSync, rmSync } from 'node:fs'
import { mkdtemp, readdir, rm } from 'node:fs/promises'
import { get } from 'node:https'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { pipeline } from 'node:stream/promises'

import {
  APP_NAME,
  EXTENSION_PATH,
  INSTALL_GUIDE,
  INSTALLED_APP,
  gatekeeperProblems,
  isOlderBuild,
  parseChecksum,
  releaseAssets,
  signatureProblems,
  versionProblems,
} from './release.mjs'

const DITTO = '/usr/bin/ditto'
const CODESIGN = '/usr/bin/codesign'
const SPCTL = '/usr/sbin/spctl'
const PLIST_BUDDY = '/usr/libexec/PlistBuddy'
const MAX_ZIP_BYTES = 200 * 1024 * 1024
const MAX_CHECKSUM_BYTES = 4096
const MAX_REDIRECTS = 5
const TIMEOUT_MS = 60_000

export class InstallError extends Error {}

/** GETs `url` over HTTPS, following up to five redirects to other HTTPS URLs. */
function request(url, userAgent, redirects = MAX_REDIRECTS) {
  return new Promise((resolve, reject) => {
    if (new URL(url).protocol !== 'https:') {
      reject(new InstallError(`refusing to download over anything but HTTPS: ${url}`))
      return
    }
    const req = get(url, { headers: { 'User-Agent': userAgent, Accept: 'application/octet-stream' } }, (res) => {
      const status = res.statusCode ?? 0
      if ([301, 302, 303, 307, 308].includes(status) && res.headers.location) {
        res.resume()
        if (redirects === 0) {
          reject(new InstallError(`too many redirects for ${url}`))
          return
        }
        resolve(request(new URL(res.headers.location, url).toString(), userAgent, redirects - 1))
        return
      }
      if (status !== 200) {
        res.resume()
        reject(new InstallError(`${url} answered HTTP ${status}`))
        return
      }
      resolve(res)
    })
    req.setTimeout(TIMEOUT_MS, () => req.destroy(new InstallError(`no answer from ${url} in ${TIMEOUT_MS / 1000} s`)))
    req.on('error', reject)
  })
}

/** Streams `url` through `sink`, at most `maxBytes`, and returns the SHA-256 of what came. */
async function download(url, userAgent, maxBytes, sink) {
  const res = await request(url, userAgent)
  const hash = createHash('sha256')
  let size = 0
  await pipeline(
    res,
    async function* (source) {
      for await (const chunk of source) {
        size += chunk.length
        if (size > maxBytes) throw new InstallError(`${url} is larger than ${maxBytes} bytes`)
        hash.update(chunk)
        yield chunk
      }
    },
    sink,
  )
  return hash.digest('hex')
}

export async function downloadText(url, userAgent, maxBytes) {
  const chunks = []
  await download(url, userAgent, maxBytes, async function (source) {
    for await (const chunk of source) chunks.push(chunk)
  })
  return Buffer.concat(chunks).toString('utf8')
}

/** Runs a tool by its absolute path, never through a shell. */
function run(tool, args) {
  const result = spawnSync(tool, args, { encoding: 'utf8' })
  if (result.error) throw new InstallError(`could not run ${tool}: ${result.error.message}`)
  return { status: result.status, stdout: result.stdout ?? '', output: `${result.stdout ?? ''}${result.stderr ?? ''}` }
}

function check(condition, message) {
  if (!condition) throw new InstallError(message)
}

/** Whether anything, a dangling symbolic link included, is at `path`. */
function exists(path) {
  try {
    lstatSync(path)
    return true
  } catch {
    return false
  }
}

/** CFBundleShortVersionString and CFBundleVersion of `bundle`, each undefined when missing. */
function bundleVersion(bundle) {
  const value = (key) => {
    const result = run(PLIST_BUDDY, ['-c', `Print :${key}`, join(bundle, 'Contents/Info.plist')])
    return result.status === 0 ? result.stdout.trim() : undefined
  }
  return { version: value('CFBundleShortVersionString'), build: value('CFBundleVersion') }
}

/**
 * The checks of docs/install.md's step 1 on the unpacked app, and that it is release `version`.
 * Returns the app's build number.
 */
export function verifyApp(app, version, log = () => {}) {
  const verify = run(CODESIGN, ['--verify', '--strict', '--deep', '--verbose=2', app])
  check(verify.status === 0, `codesign --verify failed:\n${verify.output.trim()}`)
  log('  signature: valid, and satisfies its Designated Requirement')

  const details = run(CODESIGN, ['-dvv', app])
  check(details.status === 0, `codesign -dvv failed:\n${details.output.trim()}`)
  const signature = signatureProblems(details.output)
  check(signature.length === 0, `the signature is not blackice's: ${signature.join('; ')}`)
  log('  signed by: Developer ID Application, team M294LK997M')

  const assessment = run(SPCTL, ['--assess', '--type', 'execute', '-vv', app])
  check(assessment.status === 0, `Gatekeeper rejects the app:\n${assessment.output.trim()}`)
  const gatekeeper = gatekeeperProblems(assessment.output)
  check(gatekeeper.length === 0, gatekeeper.join('; '))
  log('  Gatekeeper: accepted, source=Notarized Developer ID')

  // The signature covers Info.plist, so these are the versions the release was signed with.
  // Another validly signed build under this zip's name, such as an older release, stops here.
  const versions = { app: bundleVersion(app), extension: bundleVersion(join(app, EXTENSION_PATH)) }
  const problems = versionProblems(versions, version)
  check(problems.length === 0, `the zip does not hold blackice ${version}: ${problems.join('; ')}`)
  log(`  version: ${version}, build ${versions.app.build}`)
  return versions.app.build
}

/** `ditto SOURCE TARGET`. */
function dittoCopy(source, target) {
  const copy = run(DITTO, [source, target])
  check(copy.status === 0, `ditto could not copy ${basename(source)} to ${dirname(target)}:\n${copy.output.trim()}`)
}

/** `codesign --verify --strict --deep` on the copy beside the installed app. */
function verifyCopy(copy) {
  const verify = run(CODESIGN, ['--verify', '--strict', '--deep', copy])
  check(verify.status === 0, `the copy of ${APP_NAME} in ${dirname(dirname(copy))} does not verify:\n${verify.output.trim()}`)
}

const SIGNALS = ['SIGINT', 'SIGTERM', 'SIGHUP']

/**
 * Puts the checked `app` at `target`. It copies the app into a new folder beside `target` and
 * checks the copy there. Then it renames the app already at `target`, if any, into that folder and
 * the copy to `target`. If anything fails after the installed app was renamed, it renames it back,
 * so a failure leaves the installed app in place. The folder, with the previous app, is removed
 * only once the new one is in place. Returns whether it replaced an app.
 *
 * Everything here is synchronous and runs with SIGINT, SIGTERM and SIGHUP caught, so no signal
 * stops it halfway; one that comes meanwhile is ignored. A Ctrl-C in the terminal still stops
 * ditto or codesign, and their step fails as any other. `copy`, `verify` and `rename` are there
 * for the tests.
 */
export function placeApp(app, target, { log = () => {}, copy = dittoCopy, verify = verifyCopy, rename = renameSync } = {}) {
  const ignore = () => {}
  for (const signal of SIGNALS) process.on(signal, ignore)
  try {
    let stage
    try {
      stage = mkdtempSync(join(dirname(target), '.blackice-install-'))
    } catch (error) {
      throw new InstallError(`could not write to ${dirname(target)} (${error.code ?? error.message}); it needs an admin account`)
    }
    const staged = join(stage, basename(target))
    const aside = join(stage, 'previous.app')
    let previous
    try {
      copy(app, staged)
      verify(staged)
      const replacing = exists(target)
      if (replacing) {
        log(`Replacing the installed ${target}`)
        try {
          rename(target, aside)
        } catch (error) {
          throw new InstallError(
            `could not move ${target} (${error.code ?? error.message}). Replacing an app needs App Management ` +
              'for your terminal: System Settings > Privacy & Security > App Management.',
          )
        }
        previous = aside
      }
      check(!exists(target), `something else is at ${target} now; left it as it is`)
      try {
        rename(staged, target)
      } catch (error) {
        throw new InstallError(`could not move the new ${APP_NAME} to ${target} (${error.code ?? error.message})`)
      }
      previous = undefined
      return replacing
    } catch (error) {
      if (previous) {
        if (!exists(target)) {
          try {
            rename(previous, target)
            previous = undefined
            log(`Put the previous ${APP_NAME} back at ${target}.`)
          } catch {}
        }
        if (previous) error.message += `\nThe previous ${APP_NAME} is at ${previous}.`
      }
      throw error
    } finally {
      // Kept when it still holds the previous app.
      if (!previous) {
        try {
          rmSync(stage, { recursive: true, force: true })
        } catch {
          log(`Could not remove ${stage}; move it to the Trash.`)
        }
      }
    }
  } finally {
    for (const signal of SIGNALS) process.off(signal, ignore)
  }
}

export function nextSteps(version, replaced) {
  const lines = [
    '',
    `Blackice.app ${version} is in /Applications.`,
    '',
    'Next:',
    '  1. Put the command on your PATH (a symbolic link to it does not work), for example in ~/.zshrc:',
    '       export PATH="/Applications/Blackice.app/Contents/MacOS:$PATH"',
    '     or keep running it as `npx blackice <command>`.',
    '  2. Run `blackice start`. The first time, it asks a few questions to write ~/.config/blackice/blackice.toml,',
    '     then opens System Settings so you can allow the extension.',
    '  3. `blackice agent install` loads the daemon that runs the hooks in ask mode.',
    '',
    'Before removing the app, run `blackice agent uninstall` and `blackice stop`.',
  ]
  if (replaced) {
    lines.push(
      '',
      'You replaced an installed copy: run `blackice start`, then restart the Mac, then run',
      '`blackice agent uninstall` and `blackice agent install` so that the daemon runs the new binary.',
    )
  }
  lines.push('', `Install guide: ${INSTALL_GUIDE}`)
  return lines.join('\n')
}

/**
 * Installs the release `version`. Refuses to replace an installed Blackice.app unless `force`, and
 * to replace one of a higher build at all. Never activates the extension or loads the daemon; it
 * prints how to.
 */
export async function install({ version, force = false, log = console.log, platform = process.platform, arch = process.arch }) {
  check(platform === 'darwin', 'blackice runs on macOS only')
  check(arch === 'arm64', 'the blackice build is for Apple silicon (arm64) only')
  const assets = releaseAssets(version)
  const installed = exists(INSTALLED_APP)
  check(
    !installed || force,
    `${INSTALLED_APP} is already there. To replace it, run \`npx blackice install --force\`; ` +
      'after replacing it, run `blackice start` and restart the Mac.',
  )
  const installedBuild = installed ? bundleVersion(INSTALLED_APP).build : undefined
  const userAgent = `blackice-npm/${version}`
  const work = await mkdtemp(join(tmpdir(), 'blackice-install-'))
  try {
    log(`Downloading ${assets.checksumUrl}`)
    const expected = parseChecksum(await downloadText(assets.checksumUrl, userAgent, MAX_CHECKSUM_BYTES), assets.zipName)
    log(`Downloading ${assets.zipUrl}`)
    const zip = join(work, assets.zipName)
    const actual = await download(assets.zipUrl, userAgent, MAX_ZIP_BYTES, createWriteStream(zip, { mode: 0o600 }))
    check(actual === expected, `${assets.zipName} has SHA-256 ${actual}, but ${assets.checksumName} says ${expected}`)
    log(`  SHA-256: ${actual}, as ${assets.checksumName} says`)

    const unpacked = join(work, 'unpacked')
    const unzip = run(DITTO, ['-x', '-k', zip, unpacked])
    check(unzip.status === 0, `ditto could not unpack ${assets.zipName}:\n${unzip.output.trim()}`)
    const entries = await readdir(unpacked)
    check(entries.length === 1 && entries[0] === APP_NAME, `the zip should hold only ${APP_NAME}; it holds: ${entries.join(', ')}`)
    const app = join(unpacked, APP_NAME)
    log(`Checking ${APP_NAME}`)
    const build = verifyApp(app, version, log)
    // macOS replaces an activated extension only with the same or a higher build, so an older
    // app over a newer one could not start.
    check(
      !isOlderBuild(build, installedBuild),
      `${INSTALLED_APP} is build ${installedBuild}, newer than build ${build} of ${version}. To go back to an older ` +
        `build, uninstall blackice first, as the install guide says: ${INSTALL_GUIDE}`,
    )

    const replaced = placeApp(app, INSTALLED_APP, { log })
    log(nextSteps(version, replaced))
  } finally {
    await rm(work, { recursive: true, force: true })
  }
}
