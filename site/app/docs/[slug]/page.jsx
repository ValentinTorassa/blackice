import DocPage, { docMeta } from '../../../components/DocPage';
import { DOCS } from '../../../content/docs';

export const dynamicParams = false;

export function generateStaticParams() {
  return DOCS.filter((d) => d.slug).map((d) => ({ slug: d.slug }));
}

export async function generateMetadata({ params }) {
  const { slug } = await params;
  return docMeta(slug);
}

export default async function Doc({ params }) {
  const { slug } = await params;
  return <DocPage slug={slug} />;
}
