#!/usr/bin/env node
import { createHash } from 'node:crypto';
import {
  chmodSync, closeSync, constants, fstatSync, lstatSync, mkdirSync, mkdtempSync, openSync,
  readSync, realpathSync, renameSync, rmSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const here = dirname(fileURLToPath(import.meta.url));
export const platforms = [
  { id: 'darwin-arm64', os: 'darwin', cpu: 'arm64', target: 'aarch64-macos' },
  { id: 'darwin-x64', os: 'darwin', cpu: 'x64', target: 'x86_64-macos' },
  { id: 'linux-x64', os: 'linux', cpu: 'x64', target: 'x86_64-linux' },
  { id: 'linux-arm64', os: 'linux', cpu: 'arm64', target: 'aarch64-linux' },
];
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

function readRegular(file, limit = 128 * 1024 * 1024) {
  const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > limit) throw new Error(`not a bounded regular file: ${file}`);
    const bytes = Buffer.alloc(stat.size + 1);
    let size = 0;
    while (size < bytes.length) {
      const count = readSync(fd, bytes, size, bytes.length - size, null);
      if (count === 0) break;
      size += count;
    }
    if (size !== stat.size) throw new Error(`file changed size during read: ${file}`);
    return bytes.subarray(0, size);
  } finally {
    closeSync(fd);
  }
}

function checksums(bytes, expected) {
  const lines = new TextDecoder('utf-8', { fatal: true }).decode(bytes).split(/\r?\n/);
  if (lines.at(-1) === '') lines.pop();
  const sums = new Map();
  for (const line of lines) {
    const match = /^([a-fA-F0-9]{64}) [ *]([a-zA-Z0-9][a-zA-Z0-9._-]*)$/.exec(line);
    if (!match || !expected.includes(match[2])) throw new Error('unexpected SHA256SUMS entry');
    if (sums.has(match[2])) throw new Error(`duplicate SHA256SUMS entry: ${match[2]}`);
    sums.set(match[2], match[1].toLowerCase());
  }
  for (const name of expected) {
    if (!sums.has(name)) throw new Error(`missing SHA256SUMS entry: ${name}`);
  }
  return sums;
}

function write(file, bytes, mode = 0o644) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, bytes, { flag: 'wx', mode });
  chmodSync(file, mode);
}
const json = value => `${JSON.stringify(value, null, 2)}\n`;

export function prepare({ releaseDir, outDir, version = '0.1.0', scope = '@blackice', name = 'blackice' }) {
  if (!releaseDir || !outDir) throw new Error('--release-dir and --out-dir are required');
  if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(version) || version.length > 40) {
    throw new Error('version must be a stable x.y.z version');
  }
  if (!/^@[a-z0-9][a-z0-9._-]*$/.test(scope) || scope.length > 180) throw new Error('invalid npm scope');
  if (!/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(name) || name.length > 214) {
    throw new Error('invalid main package name');
  }
  if (platforms.some(p => name === `${scope}/${p.id}`)) throw new Error('main and platform names collide');
  const source = realpathSync(releaseDir);
  const output = resolve(outDir);
  if (output === source || output.startsWith(`${source}${sep}`)) throw new Error('output must be outside release-dir');
  try {
    lstatSync(output);
    throw new Error('output already exists; choose a new output directory');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const assets = platforms.map(p => `blackice-${version}-${p.target}`);
  assets.push(...platforms.filter(p => p.os === 'linux').map(p => `blackice-linux-helper-${version}-${p.target}`));
  assets.push('linux-setup.sh', 'linux-teardown.sh');
  const manifestBytes = readRegular(join(source, 'SHA256SUMS'), 64 * 1024);
  const sums = checksums(manifestBytes, assets);
  const snapshots = new Map();
  // Validate every input before producing packages. Copy the same checked bytes, not a second read.
  for (const asset of assets) {
    const bytes = readRegular(join(source, asset));
    if (digest(bytes) !== sums.get(asset)) throw new Error(`SHA-256 mismatch: ${asset}`);
    snapshots.set(asset, bytes);
  }
  const license = readRegular(join(here, '..', '..', 'LICENSE'));
  const main = JSON.parse(readRegular(join(here, 'blackice', 'package.json')));
  delete main.private;
  main.name = name;
  main.version = version;
  main.optionalDependencies = Object.fromEntries(platforms.map(p => [`${scope}/${p.id}`, version]));
  const result = {
    version, scope, name, releaseTag: `v${version}`, verification: 'sha256-only',
    checksumsSha256: digest(manifestBytes), packages: [],
  };
  mkdirSync(dirname(output), { recursive: true });
  const staging = mkdtempSync(join(dirname(output), '.blackice-npm-'));
  try {
    for (const platform of platforms) {
      const pkg = JSON.parse(readRegular(join(here, 'platforms', platform.id, 'package.json')));
      delete pkg.private;
      pkg.name = `${scope}/${platform.id}`;
      pkg.version = version;
      const mappings = [[`blackice-${version}-${platform.target}`, 'bin/blackice']];
      let readme = `# ${pkg.name}\n\nNative blackice ${version} for ${platform.os}/${platform.cpu}. Installed by ${name}'s optional dependencies. No JavaScript or install scripts.\n`;
      if (platform.os === 'linux') {
        const helper = `blackice-linux-helper-${version}-${platform.target}`;
        mappings.push(
          [helper, 'linux-setup/zig-out/bin/blackice-linux-helper'],
          ['linux-setup.sh', 'linux-setup/scripts/linux-setup.sh'],
          ['linux-teardown.sh', 'linux-setup/scripts/linux-teardown.sh'],
        );
        write(join(staging, platform.id, 'linux-setup', 'SHA256SUMS'), manifestBytes);
        readme += `\n## Manual Linux setup\n\nThe setup bundle is data. Verify release provenance and read the scripts before running them. Set package_dir to this installed platform package's absolute directory. Then run, as an explicit operator action:\n\n\`\`\`sh\nsudo bash "$package_dir/linux-setup/scripts/linux-setup.sh" "$USER" "${sums.get(helper)}"\n\`\`\`\n\nSetup is per user and must be repeated after reboot. Teardown stops blackice scopes and removes the installed helper:\n\n\`\`\`sh\nsudo bash "$package_dir/linux-setup/scripts/linux-teardown.sh"\n\`\`\`\n\nThe scripts and helper are unchanged release bytes. The directory layout preserves the script's ../zig-out/bin lookup. SHA256SUMS is the original release manifest; its names are release asset names, not these installed paths. Verify each installed file's hash against the corresponding release name below. No capabilities are applied to npm-managed files.\n`;
      }
      readme += '\n| Release asset | Installed path | SHA-256 |\n| --- | --- | --- |\n';
      for (const [asset, destination] of mappings) {
        write(join(staging, platform.id, destination), snapshots.get(asset), destination === 'bin/blackice' ? 0o755 : 0o644);
        readme += `| ${asset} | ${destination} | ${sums.get(asset)} |\n`;
      }
      write(join(staging, platform.id, 'package.json'), json(pkg));
      write(join(staging, platform.id, 'README.md'), readme);
      write(join(staging, platform.id, 'LICENSE'), license);
      result.packages.push({ directory: platform.id, name: pkg.name, version, assets: mappings.map(([asset, path]) => ({ asset, path, sha256: sums.get(asset) })) });
    }
    write(join(staging, 'blackice', 'package.json'), json(main));
    write(join(staging, 'blackice', 'bin', 'blackice.cjs'), readRegular(join(here, 'blackice', 'bin', 'blackice.cjs')), 0o755);
    write(join(staging, 'blackice', 'LICENSE'), license);
    const readme = readRegular(join(here, 'blackice', 'README.md')).toString('utf8');
    write(join(staging, 'blackice', 'README.md'), readme.replaceAll('{{NAME}}', name).replaceAll('{{VERSION}}', version));
    // The order is intentional: all platform versions must exist before the main package is published.
    result.packages.push({ directory: 'blackice', name, version, assets: [] });
    write(join(staging, 'manifest.json'), json(result));
    renameSync(staging, output);
  } catch (error) {
    rmSync(staging, { recursive: true, force: true });
    throw error;
  }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const { values } = parseArgs({ options: {
      'release-dir': { type: 'string' }, 'out-dir': { type: 'string' },
      version: { type: 'string', default: '0.1.0' }, scope: { type: 'string', default: '@blackice' },
      name: { type: 'string', default: 'blackice' },
    } });
    const result = prepare({ releaseDir: values['release-dir'], outDir: values['out-dir'], ...values });
    console.log(json(result));
  } catch (error) {
    console.error(`blackice npm preparation: ${error.message}`);
    process.exitCode = 1;
  }
}
