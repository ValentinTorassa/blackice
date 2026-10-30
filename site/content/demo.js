// The demo videos are not in the repository or the build: they are served from a Vercel Blob store, one cut with
// English captions and one with Spanish captions. Each URL stays empty until its file is uploaded. The demo section
// shows once a URL is set, and the language flags in the nav once both are.
const BLOB = {
  en: { src: '', poster: '' },
  es: { src: '', poster: '' },
};

export const DEMO = [
  { lang: 'en', label: 'English', ...BLOB.en },
  { lang: 'es', label: 'Español', ...BLOB.es },
].filter((s) => s.src);
