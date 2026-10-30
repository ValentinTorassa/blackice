// The demo videos are not in the repository or the build: they are served from a Vercel Blob store. The walkthrough
// is one English cut with the subtitles in the picture. The fx demo has two cuts, one with English captions and one
// with Spanish captions. Each block shows once its URL is set, and the language flags in the nav once both cuts of
// the fx demo are.
const BLOB = {
  walkthrough: { src: '', poster: '' },
  fx: {
    en: { src: '', poster: '' },
    es: { src: '', poster: '' },
  },
};

export const WALKTHROUGH = BLOB.walkthrough.src ? BLOB.walkthrough : null;

export const DEMO = [
  { lang: 'en', label: 'English', ...BLOB.fx.en },
  { lang: 'es', label: 'Español', ...BLOB.fx.es },
].filter((s) => s.src);
