import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

import { UsageError, forward, packageVersion, parseArgs } from '../lib/cli.mjs'
import { install, nextSteps } from '../lib/install.mjs'

test('no arguments print the usage', () => {
  assert.deepEqual(parseArgs([]), { command: 'usage' })
})

test('install takes --force and --help, nothing else', () => {
  assert.deepEqual(parseArgs(['install']), { command: 'install', force: false })
  assert.deepEqual(parseArgs(['install', '--force']), { command: 'install', force: true })
  assert.deepEqual(parseArgs(['install', '--help']), { command: 'usage' })
  assert.deepEqual(parseArgs(['install', '-h']), { command: 'usage' })
  assert.throws(() => parseArgs(['install', '--forse']), UsageError)
  assert.throws(() => parseArgs(['install', '0.2.0']), /unknown argument "0.2.0"/)
})

test('every other command goes to Blackice.app unchanged', () => {
  assert.deepEqual(parseArgs(['status']), { command: 'forward', args: ['status'] })
  assert.deepEqual(parseArgs(['help']), { command: 'forward', args: ['help'] })
  assert.deepEqual(parseArgs(['--help']), { command: 'forward', args: ['--help'] })
  const approve = ['approve', '--app', 'com.apple.curl', '--host', 'pypi.org', '--for', '1h']
  assert.deepEqual(parseArgs(approve), { command: 'forward', args: approve })
  assert.deepEqual(parseArgs(['mode', 'install']), { command: 'forward', args: ['mode', 'install'] })
})

test('forward runs the app binary by its full path and returns its status', () => {
  const calls = []
  const status = forward(['pending'], {
    binary: '/Applications/Blackice.app/Contents/MacOS/blackice',
    exists: () => true,
    spawn: (file, args, options) => {
      calls.push({ file, args, stdio: options.stdio })
      return { status: 75 }
    },
  })
  assert.equal(status, 75)
  assert.deepEqual(calls, [{ file: '/Applications/Blackice.app/Contents/MacOS/blackice', args: ['pending'], stdio: 'inherit' }])
})

test('forward without the app says to install and returns 69', () => {
  const originalWrite = process.stderr.write
  let written = ''
  process.stderr.write = (text) => { written += text; return true }
  try {
    assert.equal(forward(['status'], { exists: () => false, spawn: () => assert.fail('must not run') }), 69)
  } finally {
    process.stderr.write = originalWrite
  }
  assert.match(written, /npx blackice install/)
})

test('forward maps a signal to 128 + its number', () => {
  assert.equal(forward([], { exists: () => true, spawn: () => ({ status: null, signal: 'SIGINT' }) }), 130)
})

test('install refuses other platforms and architectures before touching anything', async () => {
  await assert.rejects(install({ version: '0.1.0', platform: 'linux', arch: 'arm64', log: () => {} }), /macOS only/)
  await assert.rejects(install({ version: '0.1.0', platform: 'darwin', arch: 'x64', log: () => {} }), /arm64/)
})

test('next steps mention the restart only after a replacement', () => {
  assert.doesNotMatch(nextSteps('0.1.0', false), /restart the Mac/)
  assert.match(nextSteps('0.1.0', true), /restart the Mac/)
  assert.match(nextSteps('0.1.0', false), /symbolic link to it does not work/)
})

test('the package has no dependencies and no install scripts', () => {
  const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
  assert.equal(pkg.version, packageVersion())
  assert.equal(pkg.name, 'blackice')
  assert.deepEqual(pkg.os, ['darwin'])
  assert.deepEqual(pkg.bin, { blackice: 'bin/blackice.mjs' })
  for (const key of ['dependencies', 'optionalDependencies', 'peerDependencies', 'bundleDependencies']) {
    assert.equal(pkg[key], undefined, key)
  }
  for (const script of ['preinstall', 'install', 'postinstall', 'prepare']) {
    assert.equal(pkg.scripts?.[script], undefined, script)
  }
})
