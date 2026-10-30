'use client';

import { useEffect, useRef } from 'react';

// Cards marked .spot inside this group catch a soft light under the pointer.
// With tilt, they also lean a few degrees toward it.
export default function Spotlight({ className = '', tilt = false, children }) {
  const ref = useRef(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    const lean = tilt && !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    let raf = 0;
    let last = null;

    function apply() {
      raf = 0;
      if (!last) return;
      for (const card of el.querySelectorAll('.spot')) {
        const r = card.getBoundingClientRect();
        const x = last.clientX - r.left;
        const y = last.clientY - r.top;
        card.style.setProperty('--mx', `${x.toFixed(0)}px`);
        card.style.setProperty('--my', `${y.toFixed(0)}px`);
        if (lean) {
          const inside = x >= 0 && y >= 0 && x <= r.width && y <= r.height;
          card.style.setProperty('--rx', `${inside ? ((0.5 - y / r.height) * 5).toFixed(2) : 0}deg`);
          card.style.setProperty('--ry', `${inside ? ((x / r.width - 0.5) * 5).toFixed(2) : 0}deg`);
        }
      }
    }
    function onMove(e) {
      if (e.pointerType === 'touch') return;
      last = e;
      if (!raf) raf = requestAnimationFrame(apply);
    }
    function onLeave() {
      last = null;
      for (const card of el.querySelectorAll('.spot')) {
        card.style.setProperty('--rx', '0deg');
        card.style.setProperty('--ry', '0deg');
      }
    }

    el.addEventListener('pointermove', onMove);
    el.addEventListener('pointerleave', onLeave);
    return () => {
      el.removeEventListener('pointermove', onMove);
      el.removeEventListener('pointerleave', onLeave);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [tilt]);

  return (
    <div ref={ref} className={`spotlight ${className}`}>
      {children}
    </div>
  );
}
