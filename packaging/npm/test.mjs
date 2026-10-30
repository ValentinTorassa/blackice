import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import {
  chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync,
  symlinkSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';
import { platforms, prepare } from './prepare.mjs';

const host = `${process.platform}-${process.arch}`;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const load = file => JSON.parse(readFileSync(file, 'utf8'));
const packedInfo = output => {
  const parsed = JSON.parse(output);
  // npm 11 emits an array; npm 12 keys the result by package name.
  return Array.isArray(parsed) ? parsed[0] : Object.values(parsed)[0];
};
const fixtureBinary = `#!${process.execPath}
const fs = require('node:fs');
const [op, ...args] = process.argv.slice(2);
if (op === 'exit') process.exit(Number(args[0]));
else if (op === 'signal') process.kill(process.pid, args[0]);
else if (op === 'wait') { fs.writeFileSync(args[0], String(process.pid)); setInterval(() => {}, 1000); }
else {
  process.stdout.write(JSON.stringify({args: [op, ...args], stdin: fs.readFileSync(0, 'utf8'), cwd: process.cwd(), env: process.env.BLACKICE_NPM_TEST}));
  process.stderr.write('fixture-stderr\\n');
}
`;

function fixture(t, version = '0.1.0') {
  const root = mkdtempSync(join(tmpdir(), 'blackice-npm-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const releaseDir = join(root, 'release');
  const outDir = join(root, 'packages');
  mkdirSync(releaseDir);
  const assets = new Map();
  for (const p of platforms) {
    assets.set(`blackice-${version}-${p.target}`, Buffer.from(fixtureBinary));
    if (p.os === 'linux') assets.set(`blackice-linux-helper-${version}-${p.target}`, Buffer.from(`test-only helper ${p.target}\n`));
  }
  assets.set('linux-setup.sh', Buffer.from('#!/bin/bash\n# test-only setup data\nexit 0\n'));
  assets.set('linux-teardown.sh', Buffer.from('#!/bin/bash\n# test-only teardown data\nexit 0\n'));
  for (const [file, bytes] of assets) writeFileSync(join(releaseDir, file), bytes);
  writeFileSync(join(releaseDir, 'SHA256SUMS'), [...assets].map(([file, bytes]) => `${hash(bytes)}  ${file}\n`).join(''));
  return { root, releaseDir, outDir, version, assets };
}

function linkPlatform(f, scope = '@blackice', id = host) {
  const modules = join(f.outDir, 'blackice', 'node_modules', scope);
  mkdirSync(modules, { recursive: true });
  symlinkSync(join(f.outDir, id), join(modules, id), 'dir');
}

function launcher(f, args = [], options = {}) {
  return spawnSync(process.execPath, [join(f.outDir, 'blackice', 'bin', 'blackice.cjs'), ...args], {
    encoding: 'utf8', input: '', timeout: 5000, ...options,
  });
}

test('all five manifests, exact pins and unchanged release bytes', t => {
  const f = fixture(t);
  const report = prepare(f);
  assert.equal(report.verification, 'sha256-only');
  assert.equal(report.packages.length, 5);
  assert.equal(report.packages.at(-1).directory, 'blackice');
  for (const pkg of report.packages) {
    const dir = join(f.outDir, pkg.directory);
    const metadata = load(join(dir, 'package.json'));
    assert.equal(metadata.version, '0.1.0');
    assert.equal(metadata.name, pkg.name);
    for (const field of ['private', 'scripts', 'dependencies', 'devDependencies', 'peerDependencies']) {
      assert.equal(metadata[field], undefined, `${pkg.name}: ${field}`);
    }
    for (const item of pkg.assets) {
      assert.deepEqual(readFileSync(join(dir, item.path)), f.assets.get(item.asset));
      assert.equal(hash(readFileSync(join(dir, item.path))), item.sha256);
    }
    if (pkg.directory !== 'blackice') {
      const p = platforms.find(p => p.id === pkg.directory);
      assert.deepEqual(metadata.os, [p.os]);
      assert.deepEqual(metadata.cpu, [p.cpu]);
      assert.equal(statSync(join(dir, 'bin/blackice')).mode & 0o777, 0o755);
      if (p.os === 'linux') {
        const script = join(dir, 'linux-setup/scripts/linux-setup.sh');
        assert.ok(existsSync(join(dirname(script), '../zig-out/bin/blackice-linux-helper')));
        assert.equal(statSync(join(dir, 'linux-setup/zig-out/bin/blackice-linux-helper')).mode & 0o777, 0o644);
        assert.deepEqual(readFileSync(join(dir, 'linux-setup/SHA256SUMS')), readFileSync(join(f.releaseDir, 'SHA256SUMS')));
      }
    }
  }
  assert.deepEqual(load(join(f.outDir, 'blackice/package.json')).optionalDependencies,
    Object.fromEntries(platforms.map(p => [`@blackice/${p.id}`, '0.1.0'])));
});

test('scope, main name and version can change together without changing the command name', t => {
  const f = fixture(t, '1.2.3');
  prepare({ ...f, scope: '@example-native', name: '@example-native/cli' });
  const pkg = load(join(f.outDir, 'blackice/package.json'));
  assert.equal(pkg.name, '@example-native/cli');
  assert.equal(pkg.version, '1.2.3');
  assert.deepEqual(pkg.bin, { blackice: 'bin/blackice.cjs' });
  assert.deepEqual(Object.keys(pkg.optionalDependencies), platforms.map(p => `@example-native/${p.id}`));
  linkPlatform(f, '@example-native');
  assert.equal(launcher(f, ['exit', '19']).status, 19);
});

test('modified bytes, missing/duplicate/path checksum entries and symlinks refuse before output', async t => {
  for (const kind of ['bytes', 'missing', 'duplicate', 'path', 'symlink']) {
    await t.test(kind, t => {
      const f = fixture(t);
      const file = [...f.assets.keys()][0];
      const manifest = join(f.releaseDir, 'SHA256SUMS');
      if (kind === 'bytes') writeFileSync(join(f.releaseDir, file), 'modified');
      if (kind === 'missing') writeFileSync(manifest, readFileSync(manifest, 'utf8').split('\n').slice(1).join('\n'));
      if (kind === 'duplicate') writeFileSync(manifest, readFileSync(manifest, 'utf8') + `${hash(f.assets.get(file))}  ${file}\n`);
      if (kind === 'path') writeFileSync(manifest, readFileSync(manifest, 'utf8').replace(file, `../${file}`));
      if (kind === 'symlink') {
        const outside = join(f.root, 'outside');
        writeFileSync(outside, f.assets.get(file));
        rmSync(join(f.releaseDir, file));
        symlinkSync(outside, join(f.releaseDir, file));
      }
      assert.throws(() => prepare(f));
      assert.equal(existsSync(f.outDir), false);
    });
  }
});

test('invalid names/versions and an existing output are refused', t => {
  const f = fixture(t);
  for (const extra of [{ scope: '../escape' }, { name: 'Bad Name' }, { version: '01.2.3' }, { name: '@blackice/linux-x64' }]) {
    assert.throws(() => prepare({ ...f, ...extra }));
  }
  mkdirSync(f.outDir);
  const marker = join(f.outDir, 'keep');
  writeFileSync(marker, 'unchanged');
  assert.throws(() => prepare(f), /output already exists/);
  assert.equal(readFileSync(marker, 'utf8'), 'unchanged');
});

test('launcher preserves arguments, stdin/stdout/stderr, cwd, environment and exit status', t => {
  const f = fixture(t);
  prepare(f);
  linkPlatform(f);
  const args = ['echo', 'space value', '; touch NOT_EXECUTED', '$(not-a-command)', '--', 'ñ'];
  const result = launcher(f, args, { cwd: f.root, input: 'stdin\nvalue', env: { ...process.env, BLACKICE_NPM_TEST: 'synthetic-value' } });
  assert.equal(result.status, 0);
  assert.deepEqual(JSON.parse(result.stdout), { args, stdin: 'stdin\nvalue', cwd: f.root, env: 'synthetic-value' });
  assert.equal(result.stderr, 'fixture-stderr\n');
  assert.equal(existsSync(join(f.root, 'NOT_EXECUTED')), false);
  for (const status of [0, 7, 125, 127]) assert.equal(launcher(f, ['exit', String(status)]).status, status);
});

test('launcher refuses absent/mismatched packages and a non-executable binary', t => {
  const f = fixture(t);
  prepare(f);
  let result = launcher(f);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing .* optional dependencies/);
  linkPlatform(f);
  const file = join(f.outDir, host, 'package.json');
  const metadata = load(file);
  writeFileSync(file, JSON.stringify({ ...metadata, version: '9.9.9' }));
  result = launcher(f);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /expected .*0\.1\.0/);
  writeFileSync(file, JSON.stringify(metadata));
  chmodSync(join(f.outDir, host, 'bin/blackice'), 0o644);
  result = launcher(f);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /EACCES/);
});

test('launcher refuses unsupported operating systems', t => {
  const f = fixture(t);
  prepare(f);
  const code = `Object.defineProperty(process, 'platform', {value: 'win32'}); require(${JSON.stringify(join(f.outDir, 'blackice/bin/blackice.cjs'))});`;
  const result = spawnSync(process.execPath, ['-e', code], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported platform win32/);
});

test('child termination signals are re-emitted by the launcher', t => {
  const f = fixture(t);
  prepare(f);
  linkPlatform(f);
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
    const result = launcher(f, ['signal', signal]);
    assert.equal(result.status, null);
    assert.equal(result.signal, signal);
  }
});

test('foreground process-group termination reaches the binary and launcher', { timeout: 5000 }, async t => {
  const f = fixture(t);
  prepare(f);
  linkPlatform(f);
  const marker = join(f.root, 'child.pid');
  const child = spawn(process.execPath, [join(f.outDir, 'blackice/bin/blackice.cjs'), 'wait', marker], {
    stdio: 'ignore', detached: true,
  });
  const closed = once(child, 'close');
  t.after(() => {
    if (child.exitCode === null && child.signalCode === null) {
      try { process.kill(-child.pid, 'SIGKILL'); } catch {}
    }
  });
  for (let i = 0; i < 100 && !existsSync(marker); i++) await delay(20);
  assert.ok(existsSync(marker), 'binary must be running before the signal');
  process.kill(-child.pid, 'SIGTERM');
  const [status, signal] = await closed;
  assert.equal(status, null);
  assert.equal(signal, 'SIGTERM');
});

test('npm pack dry-run for all packages, then offline installation with scripts disabled', t => {
  const f = fixture(t);
  const report = prepare(f);
  const tarballs = join(f.root, 'tarballs');
  mkdirSync(tarballs);
  const userconfig = join(f.root, 'user.npmrc');
  const globalconfig = join(f.root, 'global.npmrc');
  writeFileSync(userconfig, '');
  writeFileSync(globalconfig, '');
  const env = { PATH: process.env.PATH, npm_config_userconfig: userconfig, npm_config_globalconfig: globalconfig, npm_config_cache: join(f.root, 'npm-cache') };
  const packs = new Map();
  for (const pkg of report.packages) {
    const cwd = join(f.outDir, pkg.directory);
    const options = { cwd, env, encoding: 'utf8', timeout: 30000 };
    const result = spawnSync('npm', ['pack', '--dry-run', '--ignore-scripts', '--offline', '--json'], options);
    assert.equal(result.status, 0, result.stderr);
    const packed = packedInfo(result.stdout);
    assert.equal(packed.name, pkg.name);
    const paths = packed.files.map(file => file.path).sort();
    const expected = ['LICENSE', 'README.md', 'package.json', ...pkg.assets.map(asset => asset.path)];
    if (pkg.directory === 'blackice') expected.push('bin/blackice.cjs');
    if (pkg.directory.startsWith('linux-')) expected.push('linux-setup/SHA256SUMS');
    assert.deepEqual(paths, expected.sort());
    t.diagnostic(`npm pack --dry-run ${pkg.name}@${pkg.version}: ${paths.length} files, no unexpected payload`);
    if (pkg.directory === host || pkg.directory === 'blackice') {
      const actual = spawnSync('npm', ['pack', '--ignore-scripts', '--offline', '--json', '--pack-destination', tarballs], options);
      assert.equal(actual.status, 0, actual.stderr);
      packs.set(pkg.directory, join(tarballs, packedInfo(actual.stdout).filename));
    }
  }
  const install = join(f.root, 'installed');
  const result = spawnSync('npm', ['install', '--prefix', install, '--ignore-scripts', '--offline', '--no-audit', '--no-fund', '--package-lock=false', packs.get(host), packs.get('blackice')], { env, encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, result.stderr);
  const run = spawnSync(join(install, 'node_modules/.bin/blackice'), ['exit', '23'], { encoding: 'utf8', timeout: 5000 });
  assert.equal(run.status, 23, run.stderr);
});
