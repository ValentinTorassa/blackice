export const SITE = {
  name: 'blackice',
  headline: 'Network permissions for apps and tasks.',
  description:
    'A native, headless network policy for macOS and Linux. It attaches before a task starts, every child process inherits it, and a process inside cannot grant itself more access.',
  repo: 'https://github.com/ValentinTorassa/blackice',
  author: 'Valen Torassa',
  command: 'blackice run --policy policy.json -- fx',
};
