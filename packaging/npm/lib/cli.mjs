// The `blackice` command of the npm package: `install` is its own, and every other command goes to
// the blackice inside /Applications/Blackice.app, run by its full path.

import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'

import { INSTALL_GUIDE, INSTALLED_BINARY } from './release.mjs'

export const usage = `usage: npx blackice install [--force]
       npx blackice <command> [options]

  install [--force]   Download Blackice.app from the GitHub release for this package's version,
                      check the zip's SHA-256, the app's signature (team M294LK997M),
                      Gatekeeper's assessment (notarized) and the app's version, and put it
                      in /Applications. --force replaces an installed Blackice.app, unless it
                      has a higher build.
  <command>           Anything else runs ${INSTALLED_BINARY}
                      with the same arguments, for example \`npx blackice help\`.

Install guide: ${INSTALL_GUIDE}`

/**
 * What the arguments ask for: `{ command: 'usage' }`, `{ command: 'install', force }`, or
 * `{ command: 'forward', args }`. Throws on options `install` does not know.
 */
export function parseArgs(argv) {
  if (argv.length === 0) return { command: 'usage' }
  const [first, ...rest] = argv
  if (first !== 'install') return { command: 'forward', args: [...argv] }
  let force = false
  for (const arg of rest) {
    if (arg === '--force') force = true
    else if (arg === '--help' || arg === '-h') return { command: 'usage' }
    else throw new UsageError(`install: unknown argument ${JSON.stringify(arg)}`)
  }
  return { command: 'install', force }
}

export class UsageError extends Error {}

export function packageVersion() {
  return JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version
}

/** Runs Blackice.app's blackice and returns its exit status. */
export function forward(args, { binary = INSTALLED_BINARY, spawn = spawnSync, exists = existsSync } = {}) {
  if (!exists(binary)) {
    process.stderr.write(`blackice: ${binary} is not there. Run \`npx blackice install\` first.\n`)
    return 69
  }
  const result = spawn(binary, args, { stdio: 'inherit' })
  if (result.error) {
    process.stderr.write(`blackice: could not run ${binary}: ${result.error.message}\n`)
    return 69
  }
  if (result.signal) return 128 + (signalNumbers[result.signal] ?? 1)
  return result.status ?? 1
}

const signalNumbers = { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGKILL: 9, SIGTERM: 15 }

export async function main(argv) {
  let parsed
  try {
    parsed = parseArgs(argv)
  } catch (error) {
    if (!(error instanceof UsageError)) throw error
    process.stderr.write(`blackice: ${error.message}\n\n${usage}\n`)
    return 64
  }
  switch (parsed.command) {
    case 'usage':
      process.stdout.write(`${usage}\n`)
      return 0
    case 'forward':
      return forward(parsed.args)
    case 'install': {
      const { install, InstallError } = await import('./install.mjs')
      try {
        await install({ version: packageVersion(), force: parsed.force })
        return 0
      } catch (error) {
        process.stderr.write(`blackice install: ${error instanceof InstallError ? error.message : error.stack ?? error}\n`)
        return 1
      }
    }
  }
}
