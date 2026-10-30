import { Logo } from '../../components/Chrome';
import { SITE } from '../../content/site';

// Rendered at 1280x640 and captured as public/og.png.
export const metadata = { title: 'Social card', robots: { index: false } };

export default function OgCard() {
  return (
    <div className="og">
      <div className="og-top">
        <Logo size={36} />
        <span>{SITE.name}</span>
      </div>
      <h1 className="og-title">{SITE.headline}</h1>
      <code className="og-cmd">$ {SITE.command}</code>
      <style>{`
        .og { position: relative; width: 1280px; height: 640px; overflow: hidden; padding: 80px 88px; display: flex; flex-direction: column; gap: 36px; background: #000;
          background-image: linear-gradient(#111 1px, transparent 1px), linear-gradient(90deg, #111 1px, transparent 1px); background-size: 64px 64px; }
        .og::after { content: ''; position: absolute; inset: 0; background: radial-gradient(70% 90% at 30% 40%, transparent, #000 75%); }
        .og > * { position: relative; z-index: 1; }
        .og-top { display: flex; align-items: center; gap: 14px; font-size: 32px; font-weight: 600; letter-spacing: -0.03em; color: #ededed; }
        .og-title { margin: 28px 0 0; font-size: 96px; line-height: 1; letter-spacing: -0.055em; font-weight: 600; max-width: 13ch; color: #ededed; }
        .og-cmd { margin-top: auto; align-self: flex-start; font-family: var(--font-mono); font-size: 24px; color: #a1a1a1; padding: 14px 22px; border: 1px solid #262626; border-radius: 10px; background: #0a0a0a; }
      `}</style>
    </div>
  );
}
