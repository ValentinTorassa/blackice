import fs from 'node:fs';
import path from 'node:path';

// The demo video is not in the repository. A deployment copies it into site/public/demo/ before the build; without
// it, the demo section and the language flags in the nav are left out.
export const DEMO = [
  { lang: 'en', label: 'English', src: '/demo/blackice-demo-en.mp4' },
  { lang: 'es', label: 'Español', src: '/demo/blackice-demo-es.mp4' },
].filter((s) => fs.existsSync(path.join(process.cwd(), 'public', s.src)));

export const DEMO_POSTER = fs.existsSync(path.join(process.cwd(), 'public', 'demo', 'poster.jpg'))
  ? '/demo/poster.jpg'
  : null;
