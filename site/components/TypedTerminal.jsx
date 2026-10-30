'use client';

import { useEffect, useRef, useState } from 'react';
import { IconReplay } from './Icons';

// The full session renders on the server and for reduced motion.
// Otherwise it types itself out the first time it scrolls into view.
export default function TypedTerminal({ lines, title, badge }) {
  const ref = useRef(null);
  const [pos, setPos] = useState({ line: lines.length, chars: 0 });
  const [running, setRunning] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return undefined;
    if (el.getBoundingClientRect().top < window.innerHeight * 0.9) return undefined;
    setPos({ line: 0, chars: 0 });
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setRunning(true);
          io.disconnect();
        }
      },
      { threshold: 0.35 },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => {
    if (!running) return undefined;
    if (pos.line >= lines.length) {
      setRunning(false);
      return undefined;
    }
    const [kind, text] = lines[pos.line];
    const typing = kind === 'cmd' && pos.chars < text.length;
    const t = setTimeout(
      () => setPos((p) => (typing ? { ...p, chars: p.chars + 1 } : { line: p.line + 1, chars: 0 })),
      typing ? 14 + Math.random() * 28 : kind === 'cmd' ? 420 : 260,
    );
    return () => clearTimeout(t);
  }, [running, pos, lines]);

  function replay() {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    setPos({ line: 0, chars: 0 });
    setRunning(true);
  }

  const shown = lines.slice(0, pos.line);
  const current = pos.line < lines.length ? lines[pos.line] : null;
  const done = !current;
  const allowed = shown.filter(([k]) => k === 'ok').length;
  const denied = shown.filter(([k]) => k === 'deny').length;
  const armed = shown.some(([k, text]) => k === 'out' && text.includes('armed'));

  return (
    <figure className="terminal" ref={ref}>
      <figcaption>
        <span className="dots" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
        <span className="term-title">{title}</span>
        <span className="term-badge">{badge}</span>
        <button type="button" className="term-replay" onClick={replay} aria-label="Replay the session">
          <IconReplay size={14} />
        </button>
      </figcaption>
      <pre aria-hidden="true" style={{ minHeight: `calc(${lines.length + 1} * 1.85em + 40px)` }}>
        {shown.map((l, i) => (
          <Line key={i} l={l} />
        ))}
        {current && current[0] === 'cmd' ? (
          <span className="line line-cmd">
            <span className="ps1">$ </span>
            {current[1].slice(0, pos.chars)}
            <span className="cursor" />
          </span>
        ) : null}
        {done ? (
          <span className="line line-cmd">
            <span className="ps1">$ </span>
            <span className="cursor" />
          </span>
        ) : null}
      </pre>
      <pre className="sr-only">
        {lines.map((l, i) => (
          <Line key={i} l={l} />
        ))}
      </pre>
      <div className="term-status" aria-hidden="true">
        <span>
          <i className={`sd${armed ? '' : ' sd-idle'}`} />
          {armed ? 'scope s-7f3a91c2 · armed' : 'no scope'}
        </span>
        <span>
          {allowed} allowed · <span className={denied ? 'deny-count' : undefined}>{denied} denied</span>
        </span>
      </div>
    </figure>
  );
}

function Line({ l: [kind, text, note] }) {
  return (
    <span className={`line line-${kind}`}>
      {kind === 'cmd' ? <span className="ps1">$ </span> : null}
      {text}
      {note ? <span className="comment">{`  # ${note}`}</span> : null}
      {'\n'}
    </span>
  );
}
