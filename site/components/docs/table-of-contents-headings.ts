export type TableOfContentsHeading = {
  id: string
  text: string
  level: number
  element: HTMLElement
}

export function collectVisibleHeadings(article: ParentNode): TableOfContentsHeading[] {
  return Array.from(article.querySelectorAll<HTMLElement>('h2[id], h3[id]')).flatMap((element) => {
    if (element.getClientRects().length === 0) return []
    const text = element.textContent || ''
    if (!element.id || !text) return []
    return [{ id: element.id, text, level: Number.parseInt(element.tagName[1]), element }]
  })
}
