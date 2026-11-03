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

const BLOB = 'https://wvrrnw987csns1in.public.blob.vercel-storage.com/blackice'

/* One minute: fx asks blackice about three connections on macOS. The
   captions are burned into the picture, so there is no separate track. */
export const demo: DemoVideo = {
  src: `${BLOB}/blackice-demo-en.mp4`,
  poster: `${BLOB}/blackice-demo-en-poster.jpg`,
  captions: null,
  captionsLang: 'en',
  title: 'blackice demo',
}
