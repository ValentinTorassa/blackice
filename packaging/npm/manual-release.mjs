#!/usr/bin/env node
// Manual first release only. Preparation never publishes or reads binaries from a local build.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { platforms, prepare, readRegular, releaseManifest } from './prepare.mjs';
import { pack } from './pack.mjs';

export const version = '0.1.0';
export const tag = `v${version}`;
export const repository = 'ValentinTorassa/blackice';
export const names = [...platforms.map(p => `@legios/blackice-${p.id}`), '@legios/blackice'];
const registry = '--registry=https://registry.npmjs.org';
const scopeRegistry = '--@legios:registry=https://registry.npmjs.org';
const binaries = [...platforms.map(p => `blackice-${version}-${p.target}`), `blackice-linux-helper-${version}-x86_64-linux`];
const assets = ['SHA256SUMS', ...binaries];
const json = value => `${JSON.stringify(value, null, 2)}\n`;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const integrity = bytes => `sha512-${createHash('sha512').update(bytes).digest('base64')}`;
const load = path => JSON.parse(readRegular(path, 2 * 1024 * 1024));
const write = (path, value) => writeFileSync(path, value, { flag: 'wx', mode: 0o600 });

function command(program, args, options = {}) {
  const result = spawnSync(program, args, { timeout: 180000, maxBuffer: 128 * 1024 * 1024, ...options });
  if (result.error || result.status !== 0) throw new Error(`${program} failed: ${result.error?.message || result.stderr?.toString()}`);
  return result.stdout;
}

export function checkOwner(account, roster) {
  assert.ok(typeof account === 'string' && account.length > 0 && roster && !Array.isArray(roster) &&
    Object.hasOwn(roster, account) && roster[account] === 'owner',
  'Not a verified owner of legios. Stop and contact the release lead; do not switch scopes.');
}

export function checkMaintainer(account, maintainers) {
  // npm view cleans person objects into "name <email> (url)" even with --json.
  const nameOf = person => typeof person === 'string'
    ? /^([^\s<>()]+)(?: <[^<>\r\n]+>)?(?: \([^()\r\n]+\))?$/.exec(person)?.[1]
    : person?.name;
  assert.ok(typeof account === 'string' && account.length > 0 && Array.isArray(maintainers) &&
    maintainers.some(person => nameOf(person) === account),
  'Authenticated publisher is not a package maintainer.');
}

function draft(release) {
  assert.equal(release.tag_name, tag);
  assert.equal(release.draft, true, '0.1.0 must still be a draft release during preparation.');
  assert.equal(release.prerelease, false);
  assert.ok(Number.isSafeInteger(release.id) && release.id > 0);
  assert.deepEqual(release.assets.map(a => a.name).sort(), [...assets].sort(), 'Unexpected draft asset set.');
}

function attestation(run, file, commit) {
  return run('gh', ['attestation', 'verify', file, '--repo', repository,
    '--signer-workflow', `${repository}/.github/workflows/release.yml`,
    '--source-ref', `refs/tags/${tag}`, '--source-digest', commit,
    '--deny-self-hosted-runners', '--format', 'json']);
}

function offlineEnvironment(root) {
  for (const name of ['user.npmrc', 'global.npmrc']) write(join(root, name), '');
  return { PATH: process.env.PATH, NPM_CONFIG_USERCONFIG: join(root, 'user.npmrc'),
    NPM_CONFIG_GLOBALCONFIG: join(root, 'global.npmrc'), NPM_CONFIG_CACHE: join(root, 'npm-cache'),
    NPM_CONFIG_PROVENANCE: 'false', npm_config_provenance: 'false' };
}

// Exposed separately so tests can simulate GitHub failures without contacting any service.
export function downloadDraft(root, { run = command } = {}) {
  root = resolve(root);
  const api = path => JSON.parse(run('gh', ['api', `repos/${repository}/${path}`]).toString());
  const release = api(`releases/tags/${tag}`);
  draft(release);
  const commit = api(`commits/${tag}`).sha;
  assert.match(commit, /^[0-9a-f]{40}$/);
  assert.equal(run('git', ['rev-parse', 'HEAD']).toString().trim(), commit, 'Run from the release tag checkout.');
  run('git', ['diff', '--exit-code', 'HEAD', '--', 'packaging/npm', 'LICENSE']);
  assert.equal(api(`compare/${commit}...main`).merge_base_commit.sha, commit, 'Tagged commit is not on main.');
  mkdirSync(dirname(root), { recursive: true });
  mkdirSync(root, { mode: 0o700 }); // A fresh output is required; no reuse or local-release input.
  const directory = join(root, 'assets');
  const logs = join(root, 'attestations');
  mkdirSync(directory); mkdirSync(logs);
  run('gh', ['release', 'download', tag, '--repo', repository, '--dir', directory]);
  assert.deepEqual(readdirSync(directory).sort(), [...assets].sort());
  const snapshots = Object.fromEntries(assets.map(name => [name, hash(readRegular(join(directory, name)))]));
  write(join(logs, 'SHA256SUMS.json'), attestation(run, join(directory, 'SHA256SUMS'), commit));
  const manifest = releaseManifest(directory, version);
  assert.deepEqual([...manifest.sums.keys()].sort(), [...binaries].sort());
  write(join(root, 'checksums.log'), run('sha256sum', ['-c', 'SHA256SUMS'], { cwd: directory }));
  for (const name of binaries) write(join(logs, `${name}.json`), attestation(run, join(directory, name), commit));
  for (const name of assets) assert.equal(hash(readRegular(join(directory, name))), snapshots[name], 'Asset changed during verification.');
  assert.equal(api(`commits/${tag}`).sha, commit, 'Tag changed during verification.');
  const after = api(`releases/tags/${tag}`);
  draft(after);
  assert.equal(after.id, release.id);
  const identities = r => r.assets.map(a => [a.name, a.id]).sort((a, b) => a[0].localeCompare(b[0]));
  assert.deepEqual(identities(after), identities(release), 'Draft assets changed during verification.');
  const record = { source: 'github-draft-release', repository, tag, commit, release_id: release.id,
    draft_at_verification: true, checksums_verified: true, attestations_verified: true,
    verified_assets: snapshots };
  write(join(root, 'verified-release.json'), json(record));
  return record;
}

export function prepareManual(root, { run = command, preparePackages = prepare, packPackages = pack } = {}) {
  root = resolve(root);
  downloadDraft(root, { run }); // Every checksum and attestation must pass before packing begins.
  preparePackages({ releaseDir: join(root, 'assets'), outDir: join(root, 'packages'),
    version, scope: '@legios', name: '@legios/blackice' });
  packPackages({ preparedDir: join(root, 'packages'), outDir: join(root, 'tarballs'), env: offlineEnvironment(root) });
  validatePrepared(root, { run });
  return root;
}

export function validatePrepared(root, { run = command } = {}) {
  root = resolve(root);
  const record = load(join(root, 'verified-release.json'));
  assert.equal(record.source, 'github-draft-release');
  assert.equal(record.repository, repository); assert.equal(record.tag, tag);
  assert.match(record.commit, /^[0-9a-f]{40}$/);
  assert.equal(record.draft_at_verification, true);
  assert.equal(record.checksums_verified, true); assert.equal(record.attestations_verified, true);
  assert.deepEqual(Object.keys(record.verified_assets).sort(), [...assets].sort());
  for (const name of assets) {
    assert.equal(hash(readRegular(join(root, 'assets', name))), record.verified_assets[name], 'Verified asset changed.');
    assert.ok(readRegular(join(root, 'attestations', `${name}.json`), 8 * 1024 * 1024).length > 0);
  }
  const manifest = releaseManifest(join(root, 'assets'), version);
  const packs = load(join(root, 'tarballs', 'packs.json'));
  assert.deepEqual(packs.map(p => p.name), names, 'Wrong publication identities/order.');
  for (const p of packs) {
    assert.equal(p.version, version);
    assert.equal(p.filename, `${p.name.slice(1).replace('/', '-')}-${version}.tgz`);
    assert.equal(p.path, join(root, 'tarballs', p.filename));
    const bytes = readRegular(p.path);
    assert.equal(hash(bytes), p.sha256); assert.equal(integrity(bytes), p.integrity);
    const platform = platforms.find(target => p.name === `@legios/blackice-${target.id}`);
    if (platform) checkPlatformArchive(p.path, `blackice-${version}-${platform.target}`, manifest, run);
  }
  assert.equal(readRegular(join(root, 'tarballs', 'publish-order.txt')).toString(), `${packs.map(p => p.path).join('\n')}\n`);
  const main = JSON.parse(run('tar', ['-xOf', packs.at(-1).path, 'package/package.json']).toString());
  assert.equal(main.name, '@legios/blackice'); assert.equal(main.version, version);
  assert.deepEqual(main.bin, { blackice: 'bin/blackice.cjs' });
  assert.deepEqual(main.optionalDependencies, Object.fromEntries(names.slice(0, 4).map(name => [name, version])));
  return { packs, manifest };
}

function checkPlatformArchive(archive, asset, manifest, run) {
  const entries = run('tar', ['-tzf', archive]).toString().trimEnd().split('\n').sort();
  assert.deepEqual(entries, ['LICENSE', 'README.md', 'package.json', 'bin/blackice'].map(s => `package/${s}`).sort());
  const binary = run('tar', ['-xOf', archive, 'package/bin/blackice']);
  const digest = hash(binary);
  assert.equal(digest, manifest.sums.get(asset), 'Package binary differs from the attested release.');
  return digest;
}

// Called after each publish; security can repeat verify-all using the same verified output directory.
export function verifyPublished(root, name, account, { run = command } = {}) {
  root = resolve(root);
  const { packs, manifest } = validatePrepared(root, { run });
  const p = packs.find(p => p.name === name);
  assert.ok(p && names.includes(name), 'Unknown package.');
  const ref = `${name}@${version}`;
  const integrityResult = JSON.parse(run('npm', ['view', ref, 'dist.integrity', '--json', registry, scopeRegistry]).toString());
  // npm versions differ on whether one scalar field is wrapped in a one-item array.
  if (Array.isArray(integrityResult)) assert.equal(integrityResult.length, 1, 'Ambiguous registry integrity.');
  const actualIntegrity = Array.isArray(integrityResult) ? integrityResult[0] : integrityResult;
  assert.equal(actualIntegrity, p.integrity, 'Registry integrity differs from the prepared tarball.');
  const maintainers = JSON.parse(run('npm', ['view', ref, 'maintainers', '--json', registry, scopeRegistry]).toString());
  checkMaintainer(account, maintainers);
  const report = { name, version, integrity: actualIntegrity, maintainer: account, verified_at: new Date().toISOString() };
  const platform = platforms.find(p => name === `@legios/blackice-${p.id}`);
  const checks = join(root, 'registry-checks');
  mkdirSync(checks, { recursive: true, mode: 0o700 });
  if (platform) {
    const download = mkdtempSync(join(checks, `${platform.id}-`));
    const result = JSON.parse(run('npm', ['pack', ref, '--ignore-scripts', '--json', registry, scopeRegistry,
      '--pack-destination', download, '--cache', join(download, 'cache')], { cwd: download }).toString());
    assert.ok(Array.isArray(result) && result.length === 1);
    assert.equal(result[0].filename, p.filename);
    const archive = join(download, p.filename);
    assert.equal(integrity(readRegular(archive)), p.integrity, 'Downloaded archive has different bytes.');
    const asset = `blackice-${version}-${platform.target}`;
    Object.assign(report, { asset, binary_sha256: checkPlatformArchive(archive, asset, manifest, run), archive });
  }
  write(join(checks, `${name.slice(1).replace('/', '-')}-${Date.now()}.json`), json(report));
  return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [mode, ...args] = process.argv.slice(2);
    if (mode === 'owner' && args.length === 1) {
      checkOwner(args[0], JSON.parse(readFileSync(0, 'utf8')));
      console.log('Authenticated account owns legios.');
    } else if (mode === 'prepare' && args.length === 1) {
      console.log(prepareManual(args[0]));
    } else if (mode === 'ready' && args.length === 1) {
      validatePrepared(args[0]); console.log('Verified release inputs and exact tarball bytes match.');
    } else if (mode === 'verify' && args.length === 3) {
      console.log(json(verifyPublished(args[0], args[1], args[2])));
    } else if (mode === 'verify-all' && args.length === 2) {
      for (const name of names) console.log(json(verifyPublished(args[0], name, args[1])));
    } else throw new Error('Expected owner ACCOUNT | prepare NEW_DIR | ready DIR | verify DIR PACKAGE ACCOUNT | verify-all DIR ACCOUNT');
  } catch (error) {
    console.error(`blackice manual release: ${error.message}`);
    process.exitCode = 1;
  }
}
