import Link from 'next/link';
import { Nav, Footer } from '../components/Chrome';
import { LogoFull, IconArrowRight, IconBook } from '../components/Icons';
import { highlight } from '../content/highlight';

export const metadata = { title: 'Not found' };

export default function NotFound() {
  return (
    <>
      <Nav />
      <main id="main" className="notfound">
        <div className="hero-bg" aria-hidden="true" />
        <div className="container notfound-inner">
          <div className="notfound-art" aria-hidden="true">
            <LogoFull size={128} guides />
          </div>
          <p className="eyebrow">404</p>
          <h1 className="notfound-title">No matching rule.</h1>
          <p className="sub">There is no page at this address.</p>
          <code className="notfound-receipt">
            {highlight('{"point":"proxy","verdict":"deny","reason":"no_matching_rule","host":"this page"}')}
          </code>
          <div className="actions">
            <Link className="btn btn-primary" href="/">
              Home
              <IconArrowRight size={14} />
            </Link>
            <Link className="btn btn-secondary" href="/docs/">
              <IconBook size={16} />
              Docs
            </Link>
          </div>
        </div>
      </main>
      <Footer />
    </>
  );
}
