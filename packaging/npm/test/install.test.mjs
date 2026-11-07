import assert from 'node:assert/strict'
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { InstallError, placeApp } from '../lib/install.mjs'

// placeApp on fake bundles in a temporary folder, with cp for ditto, no codesign, and the build
// read from a file of the fake bundle instead of its Info.plist.

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

function writeApp(path, mark, build) {
  mkdirSync(join(path, 'Contents', 'MacOS'), { recursive: true })
  writeFileSync(join(path, 'Contents', 'mark'), mark)
  if (build) writeFileSync(join(path, 'Contents', 'build'), build)
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
/** The build `writeApp` gave the app at `path`, or undefined. */
function readBuild(path) {
  try {
    return readFileSync(join(path, 'Contents', 'build'), 'utf8')
  } catch {
    return undefined
  }
}

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
  assert.equal(placeApp(app, target, { force: true, copy, verify, readBuild, log: (line) => logged.push(line) }), true)
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
  assert.throws(() => placeApp(app, target, { force: true, copy: halfCopy, verify, readBuild }), /No space left on device/)
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
  assert.throws(() => placeApp(app, target, { force: true, copy, verify: unsigned, readBuild }), /does not verify/)
  assert.equal(mark(target), 'old')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})

test('an installed app that cannot be moved stays, with the App Management hint', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const rename = failingRename((from) => from === target)
  assert.throws(() => placeApp(app, target, { force: true, copy, verify, rename, readBuild }), /App Management/)
  assert.equal(mark(target), 'old')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})

test('when the new app cannot be moved in, the installed one is put back', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old')
  const rename = failingRename((from, to) => to === target && from.endsWith('/Blackice.app'))
  const logged = []
  assert.throws(
    () => placeApp(app, target, { force: true, copy, verify, rename, readBuild, log: (line) => logged.push(line) }),
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
  assert.throws(() => placeApp(app, target, { force: true, copy, verify, rename, readBuild }), (error) => {
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
  assert.equal(placeApp(app, target, { force: true, copy: interrupted, verify, readBuild }), true)
  assert.equal(mark(target), 'new')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
  assert.equal(process.listenerCount('SIGTERM'), listeners)
})

// Another install can finish while this one downloads and checks. Until 1.0.3 placeApp replaced
// whatever it found then: an app without --force, or a newer build.

test('an app put in place meanwhile is not replaced without --force', (t) => {
  const { applications, app, target } = box(t)
  // The other install finishes while this one copies.
  const meanwhile = (source, to) => {
    writeApp(target, 'other', '33')
    copy(source, to)
  }
  assert.throws(
    () => placeApp(app, target, { build: '33', version: '1.0.3', copy: meanwhile, verify, readBuild }),
    (error) => error instanceof InstallError && /is already there\. To replace it, run `npx blackice install --force`/.test(error.message),
  )
  assert.equal(mark(target), 'other')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})

test('a newer build installed meanwhile is not replaced by an older one, even with --force', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old', '30')
  const meanwhile = (source, to) => {
    rmSync(target, { recursive: true })
    writeApp(target, 'newer', '33')
    copy(source, to)
  }
  assert.throws(
    () => placeApp(app, target, { force: true, build: '32', version: '1.0.2', copy: meanwhile, verify, readBuild }),
    (error) => error instanceof InstallError && /is build 33, newer than build 32 of 1\.0\.2/.test(error.message),
  )
  assert.equal(mark(target), 'newer')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})

test('a newer build swapped in right before the rename is checked once aside, and put back', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old', '30')
  let swapped = false
  const rename = (from, to) => {
    if (from === target && !swapped) {
      swapped = true
      rmSync(target, { recursive: true })
      writeApp(target, 'newer', '33')
    }
    renameSync(from, to)
  }
  const logged = []
  assert.throws(
    () => placeApp(app, target, { force: true, build: '32', version: '1.0.2', copy, verify, rename, readBuild, log: (line) => logged.push(line) }),
    /is build 33, newer than build 32/,
  )
  assert.equal(mark(target), 'newer')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
  assert.match(logged.join('\n'), /Put the previous Blackice.app back/)
})

test('with --force, the same or a lower installed build is replaced', (t) => {
  const { applications, app, target } = box(t)
  writeApp(target, 'old', '32')
  assert.equal(placeApp(app, target, { force: true, build: '32', version: '1.0.2', copy, verify, readBuild }), true)
  assert.equal(mark(target), 'new')
  assert.deepEqual(readdirSync(applications), ['Blackice.app'])
})
