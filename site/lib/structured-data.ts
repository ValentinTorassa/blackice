import { canonicalSiteUrl, site } from '@/lib/site-metadata'

/* JSON-LD identity for the homepage. Every value is already published in the
   repository: the name, license, platform, links, and author. */
export const homepageStructuredData = {
  '@context': 'https://schema.org',
  '@graph': [
    {
      '@type': 'SoftwareApplication',
      '@id': `${canonicalSiteUrl}/#software`,
      name: site.name,
      applicationCategory: 'DeveloperApplication',
      applicationSubCategory: 'Network Extension',
      description: site.description,
      url: canonicalSiteUrl,
      softwareHelp: `${canonicalSiteUrl}/docs`,
      codeRepository: site.repo,
      programmingLanguage: 'Swift',
      operatingSystem: 'macOS',
      license: 'https://www.apache.org/licenses/LICENSE-2.0',
      isAccessibleForFree: true,
      author: site.authors.map((_, index) => ({ '@id': `${canonicalSiteUrl}/#author-${index + 1}` })),
    },
    ...site.authors.map((author, index) => ({
      '@type': 'Person',
      '@id': `${canonicalSiteUrl}/#author-${index + 1}`,
      name: author.name,
      url: author.url,
    })),
    {
      '@type': 'WebSite',
      '@id': `${canonicalSiteUrl}/#website`,
      name: site.name,
      url: canonicalSiteUrl,
      description: site.headline,
    },
  ],
}
