import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFile, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';
import { prepare, platforms } from './prepare.mjs';
import { checkMaintainer, checkOwner, names, prepareManual, validatePrepared, verifyPublished } from './manual-release.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const commit = 'a'.repeat(40);
const encode = value => Buffer.from(JSON.stringify(value));

function fixture(t, fault = '') {
  const base = mkdtempSync(join(tmpdir(), 'blackice-manual-test-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const root = join(base, 'out', 'verified');
  const files = Object.fromEntries(platforms.map(p => [`blackice-0.1.0-${p.target}`, Buffer.from(`synthetic ${p.id}, never execute or publish\n`)]));
  files['blackice-linux-helper-0.1.0-x86_64-linux'] = Buffer.from('synthetic helper, never execute');
  files.SHA256SUMS = Buffer.from(Object.entries(files).map(([name, bytes]) => `${digest(bytes)}  ${name}\n`).join(''));
  const calls = [];
  let releaseReads = 0, commitReads = 0;
  const f = { root, base, calls, fault, files };
  f.run = (program, args, options = {}) => {
    calls.push([program, ...args]);
    if (program === 'gh' && args[0] === 'api') {
      const route = args[1];
      if (route.endsWith('/releases/tags/v0.1.0')) {
        releaseReads++;
        const assets = Object.keys(files).map((name, i) => ({ name, id: i + 1 }));
        if (f.fault === 'asset-swap' && releaseReads > 1) assets[0].id += 100;
        if (f.fault === 'extra-asset') assets.push({ name: 'unexpected.sh', id: 100 });
        return encode({ id: 12, tag_name: f.fault === 'wrong-tag' ? 'v0.2.0' : 'v0.1.0',
          draft: f.fault !== 'not-draft', prerelease: false, assets });
      }
      if (route.endsWith('/commits/v0.1.0')) {
        return encode({ sha: f.fault === 'tag-moved' && commitReads++ > 0 ? 'b'.repeat(40) : commit });
      }
      if (route.includes('/compare/')) return encode({ merge_base_commit: { sha: f.fault === 'not-main' ? 'b'.repeat(40) : commit } });
    }
    if (program === 'git') {
      if (args[0] === 'rev-parse') return Buffer.from(commit + '\n');
      if (args[0] === 'diff') {
        if (f.fault === 'dirty-checkout') throw new Error('dirty checkout');
        return Buffer.alloc(0);
      }
    }
    if (program === 'gh' && args[0] === 'release') {
      const directory = args[args.indexOf('--dir') + 1];
      for (const [name, bytes] of Object.entries(files)) writeFileSync(join(directory, name), bytes);
      if (f.fault === 'checksum') writeFileSync(join(directory, 'blackice-0.1.0-aarch64-linux'), 'changed');
      return Buffer.alloc(0);
    }
    if (program === 'gh' && args[0] === 'attestation') {
      for (const [flag, value] of [['--repo', 'ValentinTorassa/blackice'],
        ['--signer-workflow', 'ValentinTorassa/blackice/.github/workflows/release.yml'],
        ['--source-ref', 'refs/tags/v0.1.0'], ['--source-digest', commit]]) {
        assert.equal(args[args.indexOf(flag) + 1], value);
      }
      assert.ok(args.includes('--deny-self-hosted-runners'));
      if (f.fault === 'attestation' && args[2].includes('helper')) throw new Error('invalid attestation');
      if (f.fault === 'changed-during-check' && args[2].includes('helper')) writeFileSync(args[2], 'changed while checking');
      return encode({ fixture_only: true });
    }
    if (program === 'npm' && args[0] === 'view') {
      assert.ok(args.includes('--registry=https://registry.npmjs.org') && args.includes('--@legios:registry=https://registry.npmjs.org'));
      const record = JSON.parse(readFileSync(join(root, 'tarballs/packs.json'))).find(p => `${p.name}@0.1.0` === args[1]);
      assert.ok(record);
      if (args[2] === 'dist.integrity') return encode(f.fault === 'registry-integrity' ? 'sha512-wrong' :
        f.fault === 'registry-integrity-many' ? [record.integrity, record.integrity] : [record.integrity]);
      if (args[2] === 'maintainers') return encode([`${f.fault === 'maintainer' ? 'someone-else' : 'test-owner'} <owner@example.invalid>`]);
    }
    if (program === 'npm' && args[0] === 'pack') {
      assert.ok(args.includes('--ignore-scripts') && args.includes('--registry=https://registry.npmjs.org') && args.includes('--@legios:registry=https://registry.npmjs.org'));
      const record = JSON.parse(readFileSync(join(root, 'tarballs/packs.json'))).find(p => `${p.name}@0.1.0` === args[1]);
      const path = join(args[args.indexOf('--pack-destination') + 1], record.filename);
      copyFileSync(record.path, path);
      if (f.fault === 'registry-tarball') writeFileSync(path, 'changed registry archive');
      return encode([{ filename: record.filename }]);
    }
    // The only real child commands allowed by this mock are local checksum/archive tools.
    assert.ok(['sha256sum', 'tar'].includes(program), `Unexpected external command: ${program} ${args}`);
    const result = spawnSync(program, args, { ...options, maxBuffer: 4 * 1024 * 1024 });
    if (result.status !== 0) throw new Error(`${program}: ${result.stderr}`);
    return result.stdout;
  };
  return f;
}

test('manual publication requires the authenticated account to own legios', () => {
  checkOwner('test-owner', { 'test-owner': 'owner' });
  for (const roster of [null, [], {}, { other: 'owner' }, { 'test-owner': 'developer' }]) {
    assert.throws(() => checkOwner('test-owner', roster), /Not a verified owner/);
  }
  assert.throws(() => checkOwner('', { '': 'owner' }));
});

test('maintainer identity handles npm person formatting without matching prefixes or email text', () => {
  for (const person of ['test-owner', 'test-owner <owner@example.invalid>',
    'test-owner <owner@example.invalid> (https://example.invalid)', { name: 'test-owner' }]) {
    checkMaintainer('test-owner', [person]);
  }
  for (const people of [null, [], ['test-owner-extra <owner@example.invalid>'],
    ['someone-else <test-owner>'], ['test-owner\n<owner@example.invalid>'], [{ name: 'other' }]]) {
    assert.throws(() => checkMaintainer('test-owner', people), /not a package maintainer/);
  }
});

test('installed npm view formats are checked against a local mock with no public registry access', async t => {
  const root = mkdtempSync(join(tmpdir(), 'blackice-npm-view-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const name of ['user.npmrc', 'global.npmrc']) writeFileSync(join(root, name), '');
  const people = [{ name: 'test-owner', email: 'owner@example.invalid' }];
  const server = createServer((_request, response) => {
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify({ name: '@legios/blackice', 'dist-tags': { latest: '0.1.0' },
      maintainers: people, versions: { '0.1.0': { name: '@legios/blackice', version: '0.1.0',
        maintainers: people, dist: { integrity: 'sha512-local-fixture' } } } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const local = `http://127.0.0.1:${server.address().port}`;
  const query = async field => {
    const { stdout } = await promisify(execFile)('npm', ['view', '@legios/blackice@0.1.0', field, '--json',
      `--registry=${local}`, `--@legios:registry=${local}`, `--userconfig=${join(root, 'user.npmrc')}`,
      `--globalconfig=${join(root, 'global.npmrc')}`, `--cache=${join(root, 'cache')}`],
    { cwd: root, env: { PATH: process.env.PATH }, timeout: 15000 });
    return JSON.parse(stdout);
  };
  const result = await query('dist.integrity');
  assert.deepEqual(Array.isArray(result) ? result : [result], ['sha512-local-fixture']);
  checkMaintainer('test-owner', await query('maintainers'));
});

test('every draft/checksum/attestation failure stops before preparation or packing', async t => {
  for (const fault of ['not-draft', 'wrong-tag', 'extra-asset', 'not-main', 'dirty-checkout',
    'checksum', 'attestation', 'changed-during-check', 'tag-moved', 'asset-swap']) {
    await t.test(fault, t => {
      const f = fixture(t, fault);
      let prepared = false, packed = false;
      assert.throws(() => prepareManual(f.root, { run: f.run,
        preparePackages: () => { prepared = true; }, packPackages: () => { packed = true; } }));
      assert.equal(prepared, false); assert.equal(packed, false);
      assert.ok(!f.calls.some(c => c[0] === 'npm'));
    });
  }
});

test('draft-only pipeline packs exact pins and checks all five registry identities plus four binaries', async t => {
  const f = fixture(t);
  prepareManual(f.root, { run: f.run, preparePackages: args => {
    assert.equal(f.calls.filter(c => c[0] === 'gh' && c[1] === 'attestation').length, 6);
    assert.ok(f.calls.some(c => c[0] === 'sha256sum' && c[1] === '-c'));
    return prepare(args);
  } });
  const main = JSON.parse(readFileSync(join(f.root, 'packages/blackice/package.json')));
  assert.deepEqual(main.optionalDependencies, Object.fromEntries(names.slice(0, 4).map(name => [name, '0.1.0'])));
  assert.equal(validatePrepared(f.root, { run: f.run }).packs.at(-1).name, '@legios/blackice');
  for (const name of names) {
    const report = verifyPublished(f.root, name, 'test-owner', { run: f.run });
    assert.equal(report.maintainer, 'test-owner');
    if (name !== '@legios/blackice') assert.equal(report.binary_sha256, digest(f.files[report.asset]));
  }
  assert.equal(f.calls.filter(c => c[0] === 'npm' && c[1] === 'view' && c[3] === 'dist.integrity').length, 5);
  assert.equal(f.calls.filter(c => c[0] === 'npm' && c[1] === 'view' && c[3] === 'maintainers').length, 5);
  assert.equal(f.calls.filter(c => c[0] === 'npm' && c[1] === 'pack').length, 4);
  assert.ok(readdirSync(join(f.root, 'registry-checks')).filter(n => n.endsWith('.json')).length === 5);
  for (const fault of ['registry-integrity', 'registry-integrity-many', 'maintainer', 'registry-tarball']) {
    await t.test(fault, () => {
      f.fault = fault;
      assert.throws(() => verifyPublished(f.root, names[0], 'test-owner', { run: f.run }));
    });
  }
  f.fault = '';
  const asset = join(f.root, 'assets/blackice-0.1.0-x86_64-linux');
  writeFileSync(asset, 'changed local asset');
  assert.throws(() => validatePrepared(f.root, { run: f.run }), /Verified asset changed/);
});

test('operator flow checks ownership first, uses OTP prompts, stops on failure and never requests provenance', async t => {
  const script = fileURLToPath(new URL('./publish-manual-0.1.0.sh', import.meta.url));
  const cases = ['success', 'identity', 'org', 'not-owner', 'declined-2fa', 'changed-owner', 'prepare', 'publish', 'verify'];
  for (const fault of cases) await t.test(fault, t => {
    const base = mkdtempSync(join(tmpdir(), 'blackice-operator-test-'));
    t.after(() => rmSync(base, { recursive: true, force: true }));
    const bin = join(base, 'bin'); mkdirSync(bin);
    const stub = `#!${process.execPath}
const fs=require('node:fs'), cp=require('node:child_process'), path=require('node:path');
const a=process.argv.slice(2), root=process.env.TEST_ROOT, fault=process.env.TEST_FAULT;
const log=(v)=>fs.appendFileSync(path.join(root,'calls.jsonl'),JSON.stringify(v)+'\\n');
if(path.basename(process.argv[1])==='npm') {
  log(['npm',...a]);
  if(a[0]==='whoami') { if(fault==='identity')process.exit(1); console.log('test-owner'); }
  else if(a[0]==='org') {
    if(fault==='org')process.exit(1);
    const denied=fault==='not-owner'||(fault==='changed-owner'&&fs.existsSync(path.join(root,'logged-in')));
    console.log(JSON.stringify({'test-owner':denied?'developer':'owner'}));
  } else if(a[0]==='login') fs.writeFileSync(path.join(root,'logged-in'),'');
  else if(a[0]==='publish') {
    if(!a.includes('--access')||a[a.indexOf('--access')+1]!=='public'||!a.includes('--ignore-scripts'))process.exit(9);
    if(!a.includes('--@legios:registry=https://registry.npmjs.org'))process.exit(9);
    if(a.some(v=>v.startsWith('--provenance'))||process.env.NPM_CONFIG_PROVENANCE!=='false'||process.env.npm_config_provenance!=='false')process.exit(9);
    if(!fs.existsSync(a[1]))process.exit(9);
    if(fault==='publish')process.exit(1);
  } else process.exit(9);
} else if(a[0]==='-e'||a[1]==='owner') {
  const r=cp.spawnSync(${JSON.stringify(process.execPath)},a,{stdio:'inherit'});process.exit(r.status??9);
} else {
  log(['node',...a.slice(1)]);
  if(a[1]==='prepare') {
    if(fault==='prepare')process.exit(1);
    fs.mkdirSync(path.join(a[2],'tarballs'),{recursive:true});
    for(const n of ${JSON.stringify(names)})fs.writeFileSync(path.join(a[2],'tarballs',n.slice(1).replace('/','-')+'-0.1.0.tgz'),'fixture');
  } else if(a[1]==='verify') { if(fault==='verify')process.exit(1); }
  else if(a[1]!=='ready') process.exit(9);
}
`;
    for (const name of ['npm', 'node']) writeFileSync(join(bin, name), stub, { mode: 0o755 });
    writeFileSync(join(bin, 'sleep'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    const result = spawnSync('bash', [script, join(base, 'verified')], {
      env: { PATH: `${bin}:${process.env.PATH}`, TEST_ROOT: base, TEST_FAULT: fault,
        NPM_CONFIG_PROVENANCE: 'true', npm_config_provenance: 'true' },
      input: fault === 'declined-2fa' ? 'no\n' : '2fa-ready\n', encoding: 'utf8', timeout: 30000,
    });
    assert.equal(result.status === 0, fault === 'success', result.stdout + result.stderr);
    const calls = readFileSync(join(base, 'calls.jsonl'), 'utf8').trimEnd().split('\n').map(JSON.parse);
    assert.deepEqual(calls[0].slice(0, 2), ['npm', 'whoami']);
    if (fault !== 'identity') assert.deepEqual(calls[1].slice(0, 4), ['npm', 'org', 'ls', 'legios']);
    const publishes = calls.filter(c => c[0] === 'npm' && c[1] === 'publish');
    assert.equal(publishes.length, fault === 'success' ? 5 : ['publish', 'verify'].includes(fault) ? 1 : 0);
    if (fault === 'success') {
      assert.ok(result.stdout.includes('authorization and writes'));
      assert.deepEqual(publishes.map(c => c[2].split('/').at(-1)), names.map(n => n.slice(1).replace('/', '-') + '-0.1.0.tgz'));
      for (let i = 0; i < calls.length; i++) if (calls[i][1] === 'publish') assert.equal(calls[i + 1][1], 'verify');
    }
  });
});
