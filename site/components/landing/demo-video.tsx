import { demo } from '@/lib/demo'

/* The landing page's demo video, from lib/demo.ts. Renders nothing until a
   URL is set there. preload="none" keeps the page from fetching the video
   until someone presses play. */
export function DemoVideo() {
  if (!demo.src) return null

  return (
    <figure className="mx-auto mt-14 w-full max-w-[720px]">
      <video
        className="aspect-video w-full rounded-xl border border-border bg-card"
        controls
        preload="none"
        playsInline
        poster={demo.poster ?? undefined}
        aria-label={demo.title}
      >
        <source src={demo.src} />
        {demo.captions ? (
          <track kind="captions" src={demo.captions} srcLang={demo.captionsLang} label="Captions" default />
        ) : null}
        <a href={demo.src}>Download the video</a>
      </video>
    </figure>
  )
}
