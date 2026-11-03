import { CodeBlock } from '@/components/docs/code-block'
import { FastLink } from '@/components/fast-link'
import { DemoVideo } from '@/components/landing/demo-video'
import { FlowDiagram } from '@/components/landing/flow-diagram'
import { demo } from '@/lib/demo'
import { configExample, configIntro, details, hero, install, modes, status, steps } from '@/lib/landing-content'
import { release } from '@/lib/release'
import { site } from '@/lib/site-metadata'
import { homepageStructuredData } from '@/lib/structured-data'

/* Renders `inline code` inside the shared plain-text copy. */
function Inline({ text }: { text: string }) {
  return text.split(/(`[^`]+`)/g).map((part, index) =>
    part.startsWith('`') ? (
      <code key={index} className="text-foreground">
        {part.slice(1, -1)}
      </code>
    ) : (
      part
    ),
  )
}

const textLink =
  'text-foreground underline decoration-border-strong underline-offset-4 transition-colors hover:decoration-foreground'

function Section({ id, label, children }: { id: string; label: string; children: React.ReactNode }) {
  return (
    <section className="mt-20" aria-labelledby={id}>
      <h2 id={id} className="mb-6 border-t border-border pt-4 font-mono text-xs font-normal text-muted-foreground">
        {label}
      </h2>
      {children}
    </section>
  )
}

export default function Home() {
  return (
    <>
      {/* Identity for agents and crawlers, in the static HTML. */}
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(homepageStructuredData).replace(/</g, '\\u003c') }}
      />
      <main className="mx-auto w-full max-w-[768px] px-6">
        <section className="pt-24 text-center">
          <h1 className="font-pixel text-[clamp(24px,4.4vw,32px)] leading-[1.15] font-medium text-balance">
            {hero.headlineLines.map((line) => (
              <span key={line} className="min-[641px]:block">
                {line}{' '}
              </span>
            ))}
          </h1>
          <div className="mt-8 flex flex-wrap justify-center gap-x-6 gap-y-3 font-mono text-[13px]">
            <FastLink href="/docs" className={textLink}>
              read the docs
            </FastLink>
            <a href="#install" className="text-muted-foreground transition-colors hover:text-foreground">
              install
            </a>
            <a href={site.repo} className="text-muted-foreground transition-colors hover:text-foreground" target="_blank" rel="noreferrer">
              view on github
            </a>
          </div>
          <FlowDiagram />
        </section>

        <Section id="how-it-works" label="how it works">
          <ol className="max-w-[600px] [counter-reset:step]">
            {steps.map((step) => (
              <li
                key={step}
                className="relative pl-10 text-muted-foreground [counter-increment:step] not-first:mt-4 before:absolute before:top-[3px] before:left-0 before:font-mono before:text-xs before:text-faint before:content-[counter(step,decimal-leading-zero)]"
              >
                <Inline text={step} />
              </li>
            ))}
          </ol>
        </Section>

        <Section id="modes" label="modes">
          <dl className="grid max-w-[600px] gap-x-6 gap-y-1 min-[641px]:grid-cols-[112px_minmax(0,1fr)] min-[641px]:gap-y-3">
            {modes.map((mode) => (
              <div key={mode.name} className="contents">
                <dt>
                  <code className="text-foreground">{mode.name}</code>
                </dt>
                <dd className="text-muted-foreground max-[640px]:mb-3">{mode.body}</dd>
              </div>
            ))}
          </dl>
        </Section>

        <Section id="details" label="details">
          <div className="max-w-[600px] text-muted-foreground [&_p+p]:mt-4">
            {details.map((paragraph) => (
              <p key={paragraph}>
                <Inline text={paragraph} />
              </p>
            ))}
          </div>
        </Section>

        <Section id="configuration" label="configuration">
          <p className="mb-4 max-w-[600px] text-muted-foreground">
            <Inline text={configIntro} /> The{' '}
            <FastLink href="/docs/configuration" className={textLink}>
              configuration docs
            </FastLink>{' '}
            cover every key.
          </p>
          <CodeBlock code={configExample}>{configExample}</CodeBlock>
        </Section>

        <Section id="install" label={`install ${release.version}`}>
          <div className="max-w-[600px] text-muted-foreground [&_p+p]:mt-4">
            {status.map((paragraph) => (
              <p key={paragraph}>
                <Inline text={paragraph} />
              </p>
            ))}
            <p>
              Each run is recorded in the repository&apos;s{' '}
              <a href={release.evidence} className={textLink} target="_blank" rel="noreferrer">
                evidence
              </a>{' '}
              folder.
            </p>
          </div>
          <div className="mt-6">
            <CodeBlock code={install.brew}>{install.brew}</CodeBlock>
          </div>
          <div className="mt-4 max-w-[600px] text-muted-foreground [&_p+p]:mt-4">
            <p>
              Or download <code className="text-foreground">{release.zip}</code> and{' '}
              <code className="text-foreground">{release.checksum}</code> from the{' '}
              <a href={release.url} className={textLink} target="_blank" rel="noreferrer">
                GitHub release
              </a>
              , check them and move Blackice.app to <code className="text-foreground">/Applications</code>, as the{' '}
              <FastLink href="/docs/install" className={textLink}>
                install docs
              </FastLink>{' '}
              describe.
            </p>
            <p>
              <Inline text={install.next} />
            </p>
          </div>
        </Section>

        {demo.src ? (
          <Section id="demo" label="demo">
            <DemoVideo />
          </Section>
        ) : null}
      </main>
    </>
  )
}
