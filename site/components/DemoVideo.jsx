'use client';

import { useRef, useState } from 'react';

// The demo, with a voice-over in one or two languages. The video files are not in the repository: a deployment adds
// them to public/demo/ before the build (see page.jsx).
export default function DemoVideo({ sources, poster }) {
  const [lang, setLang] = useState(sources[0].lang);
  const pending = useRef(null);
  const ref = useRef(null);
  const current = sources.find((s) => s.lang === lang) || sources[0];

  // Both languages share one cut, so a switch keeps the position and the play state.
  function choose(next) {
    if (next === lang) return;
    const v = ref.current;
    pending.current = v ? { t: v.currentTime, play: !v.paused } : null;
    setLang(next);
  }

  function onLoaded(e) {
    const p = pending.current;
    if (!p) return;
    pending.current = null;
    e.currentTarget.currentTime = p.t;
    if (p.play) e.currentTarget.play().catch(() => {});
  }

  return (
    <figure className="frame demo">
      <figcaption className="frame-bar">
        <span className="frame-title">demo · v0</span>
        {sources.length > 1 ? (
          <span className="demo-langs" role="group" aria-label="Voice-over language">
            {sources.map((s) => (
              <button
                key={s.lang}
                type="button"
                className="demo-lang"
                aria-pressed={s.lang === lang}
                onClick={() => choose(s.lang)}
              >
                {s.label}
              </button>
            ))}
          </span>
        ) : null}
      </figcaption>
      <video
        key={current.src}
        ref={ref}
        className="demo-video"
        src={current.src}
        poster={poster || undefined}
        controls
        preload="metadata"
        playsInline
        onLoadedMetadata={onLoaded}
      />
    </figure>
  );
}
