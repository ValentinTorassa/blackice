export const SITE = {
  name: 'blackice',
  headline: 'Network permissions for apps and tasks.',
  description:
    'blackice decides which hosts a command, and every process it starts, can reach. Native and headless. v0: task scopes work on macOS and Debian 13 (x86_64).',
  repo: 'https://github.com/ValentinTorassa/blackice',
  author: 'Valen Torassa',
  authorUrl: 'https://valentorassa.com',
  command: 'blackice run --policy policy.json -- npm ci',
};

// The current release. The Install section on the landing page and the Install docs page read it.
const VERSION = '0.1.0';

export const RELEASE = {
  version: VERSION,
  url: `${SITE.repo}/releases/tag/v${VERSION}`,
  npm: 'npm install -g @legios/blackice',
  brew: 'brew install valentintorassa/tap/blackice',
  linuxSetup: `${SITE.repo}/blob/v${VERSION}/docs/linux.md#build-and-install`,
};
