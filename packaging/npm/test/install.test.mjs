import assert from 'node:assert/strict'
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { InstallError, placeApp } from '../lib/install.mjs'

// placeApp on fake bundles in a temporary folder, with cp for ditto and no codesign.

function box(t) {
  const root = mkdtempSync(join(tmpdir(), 'blackice-place-'))
  t.after(() => {
    chmodSync(root, 0o755)
    for (const entry of readdirSync(root)) chmodSync(join(root, entry), 0o755)
    rmSync(root, { recursive: true, force: true })
  })
  const applications = join(root, 'Applications')
  mkdirSync(applications)
  const app = join(root, 'unpacked', 'Blackice.app')
  writeApp(app, 'new')
  return { root, applications, app, target: join(applications, 'Blackice.app') }
}

function writeApp(path, mark) {
  mkdirSync(join(path, 'Contents', 'MacOS'), { recursive: true })
  writeFileSync(join(path, 'Contents', 'mark'), mark)
}

/** The mark of the app at `path`, or 'none'. */
function mark(path) {
  try {
    return readFileSync(join(path, 'Contents', 'mark'), 'utf8')
  } catch {
    return 'none'
  }
}

const copy = (source, target) => cpSync(source, target, { recursive: true })
const verify = () => {}

/** A rename that throws EIO for the calls `fails` picks, and renames for the rest. */
function failingRename(fails) {
  return (from, to) => {
    if (fails(from, to)) throw Object.assign(new Error(`EIO: rename ${from} -> ${to}`), { code: 'EIO' })
    renameSync(from, to)
  }
}

test('a first install puts the app in place and leaves nothing else', (t) => {
  const { applications, app, target } = box(t)
  assert.equal(placeApp(app, target, { copy, verify }), false)
  assert.equal(mark(target), 'new')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})

test('an installed app is replaced, and removed once the new one is in place', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const logged = []
  assert.equal(placeApp(app, target, { copy, verify, log: (line) => logged.push(line) }), true)
  assert.equal(mark(target), 'new')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
  assert.match(logged.join('\n'), /Replacing the installed/)
})

test('a copy that fails halfway leaves the installed app and no folder', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const halfCopy = (source, to) => {
    mkdirSync(join(to, 'Contents'), { recursive: true })
    throw new InstallError('ditto could not copy Blackice.app: No space left on device')
  }
  assert.throws(() => placeApp(app, target, { copy: halfCopy, verify }), /No space left on device/)
  assert.equal(mark(target), 'old')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})

test('a copy that does not verify leaves the installed app', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const unsigned = (path) => {
    assert.match(path, /\.blackice-install-.+\/Blackice\.app$/)
    throw new InstallError('the copy does not verify')
  }
  assert.throws(() => placeApp(app, target, { copy, verify: unsigned }), /does not verify/)
  assert.equal(mark(target), 'old')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})

test('an installed app that cannot be moved stays, with the App Management hint', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const rename = failingRename((from) => from === target)
  assert.throws(() => placeApp(app, target, { copy, verify, rename }), /App Management/)
  assert.equal(mark(target), 'old')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})

test('when the new app cannot be moved in, the installed one is put back', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const rename = failingRename((from, to) => to === target && from.endsWith('/Blackice.app'))
  const logged = []
  assert.throws(
    () => placeApp(app, target, { copy, verify, rename, log: (line) => logged.push(line) }),
    (error) => error instanceof InstallError && /could not move the new Blackice.app/.test(error.message),
  )
  assert.equal(mark(target), 'old')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
  assert.match(logged.join('\n'), /Put the previous Blackice.app back/)
})

test('when the installed app cannot be put back either, it is kept and the error says where', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const rename = failingRename((from, to) => to === target)
  let message = ''
  assert.throws(() => placeApp(app, target, { copy, verify, rename }), (error) => {
    message = error.message
    return true
  })
  const kept = /The previous Blackice\.app is at (.+)\.$/.exec(message)?.[1]
  assert.ok(kept, message)
  assert.equal(mark(kept), 'old')
  assert.equal(mark(target), 'none')
  assert.equal(readdirSync(applications).length, 1)
})

test('a folder it cannot write to is left as it is', (t) => {
  const { applications, app, target } = box(t)
  chmodSync(applications, 0o555)
  assert.throws(() => placeApp(app, target, { copy, verify }), /could not write to/)
  assert.deepEqual(readdirSync(applications), [])
})

test('a SIGTERM while the app is placed does not stop it halfway', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const listeners = process.listenerCount('SIGTERM')
  const interrupted = (source, to) => {
    process.kill(process.pid, 'SIGTERM')
    copy(source, to)
  }
  assert.equal(placeApp(app, target, { copy: interrupted, verify }), true)
  assert.equal(mark(target), 'new')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
  assert.equal(process.listenerCount('SIGTERM'), listeners)
})
