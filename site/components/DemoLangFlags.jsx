'use client';

import { useEffect, useState } from 'react';
import { DEMO_LANG_PICK, DEMO_LANG_STATE, Flag } from './Flags';

const CHOICES = [
  { lang: 'es', label: 'Demo en español' },
  { lang: 'en', label: 'Demo in English' },
];

// The two flags at the top of every page. Each one switches the demo's captions and scrolls to it; on a page
// without the demo, it opens the landing page's demo in that language (/?lang=es#demo).
export default function DemoLangFlags() {
  const [current, setCurrent] = useState(null);

  useEffect(() => {
    const pressed = document.querySelector('.demo-lang[aria-pressed="true"]');
    if (pressed) setCurrent(pressed.dataset.lang);
    const onState = (e) => setCurrent(e.detail);
    window.addEventListener(DEMO_LANG_STATE, onState);
    return () => window.removeEventListener(DEMO_LANG_STATE, onState);
  }, []);

  function pick(lang) {
    const demo = document.getElementById('demo');
    if (!demo) {
      window.location.href = `/?lang=${lang}#demo`;
      return;
    }
    window.dispatchEvent(new CustomEvent(DEMO_LANG_PICK, { detail: lang }));
    demo.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  return (
    <div className="flags" role="group" aria-label="Demo language">
      {CHOICES.map(({ lang, label }) => (
        <button
          key={lang}
          type="button"
          className="flag-btn"
          aria-pressed={current === lang}
          aria-label={label}
          title={label}
          onClick={() => pick(lang)}
        >
          <Flag lang={lang} />
        </button>
      ))}
    </div>
  );
}
