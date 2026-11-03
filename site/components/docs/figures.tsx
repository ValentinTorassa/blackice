import type { ReactNode } from 'react'

import { figureLabel, figureText } from '@/lib/figures'

/* Diagrams for the docs. Static SVG drawn with the f-* classes in
   globals.css; they show the planned design and nothing in them runs. */

type Tone = 'ok' | 'no' | 'mute' | 'warn'
const tones: Tone[] = ['ok', 'no', 'mute', 'warn']

function Defs({ p }: { p: string }) {
  return (
    <defs>
      {tones.map((t) => (
        <marker
          key={t}
          id={`${p}-${t}`}
          viewBox="0 0 10 10"
          refX="9"
          refY="5"
          markerWidth="7"
          markerHeight="7"
          orient="auto-start-reverse"
        >
          <path d="M0,0 L10,5 L0,10 z" className={`f-${t}-fill`} />
        </marker>
      ))}
    </defs>
  )
}

function Box({ x, y, w, h, title, sub, tone }: { x: number; y: number; w: number; h: number; title: string; sub?: string; tone?: 'key' | 'warn' }) {
  const ty = sub ? y + h / 2 - 3 : y + h / 2 + 4
  return (
    <g>
      <rect x={x} y={y} width={w} height={h} rx="8" className={tone ? `f-box f-box-${tone}` : 'f-box'} />
      <text x={x + 12} y={ty} className="f-t">
        {title}
      </text>
      {sub ? (
        <text x={x + 12} y={ty + 16} className="f-s">
          {sub}
        </text>
      ) : null}
    </g>
  )
}

function Line({ p, d, tone = 'mute', end = true }: { p: string; d: string; tone?: Tone; end?: boolean }) {
  return <path d={d} className={`f-line f-line-${tone}`} markerEnd={end ? `url(#${p}-${tone})` : undefined} />
}

function Cross({ x, y }: { x: number; y: number }) {
  return (
    <g className="f-cross">
      <circle cx={x} cy={y} r="7" />
      <path d={`M${x - 3} ${y - 3} L${x + 3} ${y + 3} M${x + 3} ${y - 3} L${x - 3} ${y + 3}`} />
    </g>
  )
}

function T({ x, y, c = 'f-lbl', anchor, children }: { x: number; y: number; c?: string; anchor?: 'middle' | 'end'; children: ReactNode }) {
  return (
    <text x={x} y={y} className={c} textAnchor={anchor}>
      {children}
    </text>
  )
}

function Fig({ n, name, viewBox, children }: { n?: number; name: keyof typeof figureText; viewBox: string; children: ReactNode }) {
  return (
    <figure>
      <div className="overflow-x-auto rounded-xl border border-border bg-card p-5">
        <svg viewBox={viewBox} role="img" aria-label={figureLabel[name]} className="block h-auto w-full min-w-[600px] font-mono">
          {children}
        </svg>
      </div>
      <figcaption className="mt-3 text-sm text-muted-foreground">
        {n ? <b className="mr-2 font-mono text-xs font-normal text-foreground">Figure {n}</b> : null}
        {figureText[name]}
      </figcaption>
    </figure>
  )
}

// One connection in ask mode, as a sequence diagram.
export function FigAsk({ n }: { n?: number }) {
  const p = 'fa'
  const lanes: [string, number][] = [
    ['app', 80],
    ['extension', 270],
    ['daemon', 450],
    ['hook: fx', 630],
  ]
  const msg = (y: number, x1: number, x2: number, label: string, tone: Tone = 'mute') => (
    <g key={`${y}-${label}`}>
      <Line p={p} tone={tone} d={`M${x1} ${y} L${x2 + (x2 > x1 ? -2 : 2)} ${y}`} />
      <T x={(x1 + x2) / 2} y={y - 7} anchor="middle" c={tone === 'mute' ? 'f-lbl' : `f-lbl f-txt-${tone}`}>
        {label}
      </T>
    </g>
  )
  const note = (x: number, y: number, w: number, text: string) => (
    <g key={`${y}-${text}`}>
      <rect x={x} y={y} width={w} height="24" rx="6" className="f-box" />
      <T x={x + 10} y={y + 16} c="f-s">
        {text}
      </T>
    </g>
  )
  return (
    <Fig n={n} name="FigAsk" viewBox="0 0 720 440">
      <Defs p={p} />
      {lanes.map(([name, x]) => (
        <g key={name}>
          <rect x={x - 60} y="10" width="120" height="32" rx="8" className={name === 'extension' ? 'f-box f-box-key' : 'f-box'} />
          <T x={x} y={31} c="f-t" anchor="middle">
            {name}
          </T>
          <line x1={x} y1="42" x2={x} y2="428" className="f-life" />
        </g>
      ))}
      {msg(74, 80, 270, 'connect example.com:443')}
      {note(280, 90, 170, 'no rule matches: pause')}
      {msg(146, 270, 450, 'event over XPC', 'warn')}
      {msg(186, 450, 630, 'run hook with the event')}
      {note(490, 202, 130, 'agent decides')}
      {msg(256, 630, 270, 'blackice approve … --host example.com --for 1h', 'ok')}
      {note(280, 272, 150, 'resume: allow')}
      {msg(326, 270, 80, 'connection proceeds', 'ok')}
      <line x1="12" y1="352" x2="708" y2="352" className="f-life" />
      <T x={708} y={346} c="f-lbl f-txt-warn" anchor="end">
        or, with no answer in N seconds
      </T>
      <Line p={p} tone="no" d="M270 392 L100 392" end={false} />
      <Cross x={92} y={392} />
      <T x={185} y={385} c="f-lbl f-txt-no" anchor="middle">
        dropped
      </T>
    </Fig>
  )
}

// The parts and where each one runs.
export function FigArchitecture({ n }: { n?: number }) {
  const p = 'fr'
  return (
    <Fig n={n} name="FigArchitecture" viewBox="0 0 720 316">
      <Defs p={p} />
      <Box x={10} y={96} w={130} h={50} title="apps" sub="browsers, agents" />
      <rect x="196" y="30" width="270" height="262" rx="12" className="f-scope" />
      <T x={212} y={52} c="f-h">
        Blackice.app
      </T>
      <T x={212} y={70} c="f-s">
        no UI, in /Applications
      </T>
      <Box x={216} y={88} w={230} h={64} title="network extension" sub="rules, approvals, paused flows" tone="key" />
      <Box x={216} y={212} w={230} h={56} title="blackice CLI" sub="start, mode, approve, pending" />
      <Line p={p} d="M140 121 L214 121" />
      <T x={168} y={113} anchor="middle">
        flows
      </T>

      <Box x={520} y={60} w={190} h={52} title="blackice daemon" sub="LaunchAgent, runs hooks" />
      <Box x={556} y={136} w={154} h={40} title="blackice.toml" sub="mode, hooks, rules" />
      <Box x={520} y={208} w={190} h={52} title="hook: fx" sub="the agent decides" tone="warn" />

      <Line p={p} tone="warn" d="M446 100 L518 100" />
      <T x={482} y={93} c="f-lbl f-txt-warn" anchor="middle">
        events
      </T>
      <line x1="633" y1="136" x2="633" y2="112" className="f-life" />
      <Line p={p} d="M532 112 L532 206" />
      <Line p={p} tone="ok" d="M520 244 L448 244" />
      <T x={484} y={236} c="f-lbl f-txt-ok" anchor="middle">
        approve
      </T>
      <Line p={p} tone="ok" d="M330 212 L330 154" />
      <T x={338} y={188} c="f-lbl f-txt-ok">
        XPC + token
      </T>
    </Fig>
  )
}
