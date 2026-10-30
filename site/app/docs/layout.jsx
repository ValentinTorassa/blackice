import { Nav, Footer } from '../../components/Chrome';
import DocsSidebar from '../../components/DocsSidebar';
import { DOCS, GROUPS } from '../../content/docs';

export default function DocsLayout({ children }) {
  const groups = GROUPS.map((name) => ({
    name,
    pages: DOCS.filter((d) => d.group === name).map(({ slug, title }) => ({ slug, title })),
  }));

  return (
    <>
      <Nav />
      <div className="container docs">
        <aside className="docs-aside">
          <DocsSidebar groups={groups} />
        </aside>
        <main id="main" className="docs-main">{children}</main>
      </div>
      <Footer />
    </>
  );
}
