'use client';

import { useEffect, useState } from 'react';
import { IconLines } from './Icons';

// "On this page", built from the page's section headings, with the current one highlighted.
const headingText = (h) => {
  const c = h.cloneNode(true);
  c.querySelectorAll('.h-hash').forEach((n) => n.remove());
  return c.textContent.trim();
};

export default function DocToc() {
  const [items, setItems] = useState([]);
  const [active, setActive] = useState(null);

  useEffect(() => {
    const heads = [...document.querySelectorAll('.doc-body h2[id]')];
    setItems(heads.map((h) => ({ id: h.id, text: headingText(h) })));
    if (!heads.length) return undefined;
    let raf = 0;
    const update = () => {
      raf = 0;
      let current = heads[0].id;
      for (const h of heads) if (h.getBoundingClientRect().top < 140) current = h.id;
      setActive(current);
    };
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(update);
    };
    update();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => {
      window.removeEventListener('scroll', onScroll);
      if (raf) cancelAnimationFrame(raf);
    };
  }, []);

  if (items.length < 2) return null;
  return (
    <nav className="toc" aria-label="On this page">
      <p className="toc-title">
        <IconLines size={14} />
        On this page
      </p>
      <ul>
        {items.map((it) => (
          <li key={it.id}>
            <a href={`#${it.id}`} className={active === it.id ? 'active' : undefined}>
              {it.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}
