/* The demo video on the landing page. It is hosted outside the repository
   (Vercel Blob); set `src` to its URL to show it. While `src` is null the
   page and its markdown twin leave the video out entirely. `poster` is an
   image URL shown before playback, and `captions` a WebVTT URL in
   `captionsLang`. */
export type DemoVideo = {
  src: string | null
  poster: string | null
  captions: string | null
  captionsLang: string
  title: string
}

export const demo: DemoVideo = {
  src: null,
  poster: null,
  captions: null,
  captionsLang: 'en',
  title: 'blackice demo',
}
