// `npx blackice install`: downloads the release zip and its checksum from GitHub, checks them,
// checks the unpacked app's signature and Gatekeeper's assessment, and copies the app to
// /Applications. Uses only Node's own modules and the macOS tools in /usr/bin and /usr/sbin.

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createWriteStream, existsSync } from 'node:fs'
import { mkdtemp, readdir, rm } from 'node:fs/promises'
import { get } from 'node:https'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pipeline } from 'node:stream/promises'

import {
  APP_NAME,
  INSTALL_GUIDE,
  INSTALLED_APP,
  gatekeeperProblems,
  parseChecksum,
  releaseAssets,
  signatureProblems,
} from './release.mjs'

const DITTO = '/usr/bin/ditto'
const CODESIGN = '/usr/bin/codesign'
const SPCTL = '/usr/sbin/spctl'
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
  return { status: result.status, output: `${result.stdout ?? ''}${result.stderr ?? ''}` }
}

function check(condition, message) {
  if (!condition) throw new InstallError(message)
}

/** The checks of docs/install.md's step 1, on the unpacked app. */
export function verifyApp(app, log = () => {}) {
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
    '  2. Write ~/.config/blackice/blackice.toml and run `blackice start`. The first time, macOS holds the',
    '     extension until you allow it in System Settings > General > Login Items & Extensions >',
    '     Network Extensions.',
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
 * Installs the release `version`. Refuses to replace an installed Blackice.app unless `force`.
 * Never activates the extension or loads the daemon; it prints how to.
 */
export async function install({ version, force = false, log = console.log, platform = process.platform, arch = process.arch }) {
  check(platform === 'darwin', 'blackice runs on macOS only')
  check(arch === 'arm64', 'the blackice build is for Apple silicon (arm64) only')
  const assets = releaseAssets(version)
  const installed = existsSync(INSTALLED_APP)
  check(
    !installed || force,
    `${INSTALLED_APP} is already there. To replace it, run \`npx blackice install --force\`; ` +
      'after replacing it, run `blackice start` and restart the Mac.',
  )
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
    verifyApp(app, log)

    if (installed) {
      log(`Removing the installed ${INSTALLED_APP}`)
      try {
        await rm(INSTALLED_APP, { recursive: true })
      } catch (error) {
        throw new InstallError(
          `could not remove ${INSTALLED_APP} (${error.code ?? error.message}). Replacing an app needs App Management ` +
            'for your terminal: System Settings > Privacy & Security > App Management.',
        )
      }
    }
    const copy = run(DITTO, [app, INSTALLED_APP])
    check(copy.status === 0, `ditto could not copy ${APP_NAME} to /Applications:\n${copy.output.trim()}`)
    log(nextSteps(version, installed))
  } finally {
    await rm(work, { recursive: true, force: true })
  }
}
