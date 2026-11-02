import { seeAlso } from '@/lib/landing-content'

const internalNavLinks = seeAlso.filter((link) => link.href.startsWith('/'))

/* Pre-hydration active-link styling. The bootstrap script sets
   data-site-nav-active on <html> before first paint, and CSS cannot compare
   that value against each link's own label, so there is one literal class
   per label. They must be literals for Tailwind to detect them. */
export const preHydrationActiveClass: Record<string, string> = {
  docs: "[html[data-site-nav-active='docs']_&]:text-foreground",
  cli: "[html[data-site-nav-active='cli']_&]:text-foreground",
}

export function activeSiteNavLabel(pathname: string): string | undefined {
  return internalNavLinks.reduce<(typeof internalNavLinks)[number] | undefined>((best, link) => {
    const matches = pathname === link.href || pathname.startsWith(`${link.href}/`)
    if (!matches) return best
    return !best || link.href.length > best.href.length ? link : best
  }, undefined)?.label
}

/* Runs before the first paint so the server-rendered, route-neutral header
   can show the current link while React hydrates the shared shell. */
export const siteNavBootstrapScript = `(()=>{const p=window.location.pathname,l=${JSON.stringify(internalNavLinks)};let a;for(const n of l){if(p!==n.href&&!p.startsWith(n.href+'/'))continue;if(!a||n.href.length>a.href.length)a=n}if(a)document.documentElement.dataset.siteNavActive=a.label})()`
