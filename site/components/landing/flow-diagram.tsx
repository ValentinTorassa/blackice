/* What happens to one new connection, as a decision tree with its two
   outcomes, drawn with the f-* classes in globals.css. Wide screens get the
   tree left to right; narrow screens get it top to bottom, because the wide
   drawing scaled down to a phone makes the labels unreadable. The "you or fx"
   box is dashed: the hook is optional. */

const label =
  'An app opens a connection and netshield checks your rules. If a rule matches, the connection is allowed. If not, it is paused and you or an agent such as fx decide: approve allows it, deny or no answer drops it.'

type Box = { x: number; y: number; w: number; title: string; sub?: string; tone?: 'key' | 'warn' }

const h = 52

function Marker({ id }: { id: string }) {
  return (
    <defs>
      <marker id={id} viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
        <path d="M0,0 L10,5 L0,10 z" className="f-mute-fill" />
      </marker>
    </defs>
  )
}

function Node({ x, y, w, title, sub, tone }: Box) {
  return (
    <g>
      <rect x={x} y={y} width={w} height={h} className={tone ? `f-box f-box-${tone}` : 'f-box'} />
      <text x={x + 14} y={sub ? y + 22 : y + h / 2 + 4} className="f-t">
        {title}
      </text>
      {sub ? (
        <text x={x + 14} y={y + 39} className="f-s">
          {sub}
        </text>
      ) : null}
    </g>
  )
}

function Edge({ d, marker }: { d: string; marker: string }) {
  return <path d={d} className="f-line f-line-mute" markerEnd={`url(#${marker})`} />
}

function Label({ x, y, anchor, children }: { x: number; y: number; anchor?: 'middle' | 'end'; children: string }) {
  return (
    <text x={x} y={y} textAnchor={anchor} className="f-lbl">
      {children}
    </text>
  )
}

/* Left to right: the rule path runs along the top, the paused path below. */
function Row() {
  const m = 'flow-row'
  const app: Box = { x: 1, y: 30, w: 150, title: 'app', sub: 'opens a connection' }
  const shield: Box = { x: 191, y: 30, w: 150, title: 'netshield', sub: 'checks your rules', tone: 'key' }
  const allowed: Box = { x: 599, y: 30, w: 120, title: 'allowed' }
  const decide: Box = { x: 319, y: 140, w: 150, title: 'you or fx', sub: 'approve or deny', tone: 'warn' }
  const dropped: Box = { x: 599, y: 140, w: 120, title: 'dropped' }
  return (
    <svg viewBox="0 0 720 200" role="img" aria-label={label} className="hidden h-auto w-full font-mono min-[641px]:block">
      <Marker id={m} />
      {[app, shield, allowed, decide, dropped].map((box) => (
        <Node key={box.title} {...box} />
      ))}
      <Edge marker={m} d="M151 56 H189" />
      <Edge marker={m} d="M341 46 H597" />
      <Label x={469} y={38} anchor="middle">
        a rule matches
      </Label>
      <Edge marker={m} d="M266 82 V166 H317" />
      <Label x={274} y={130}>
        no rule: paused
      </Label>
      <Edge marker={m} d="M469 154 H534 V68 H597" />
      <Label x={540} y={112}>
        approve
      </Label>
      <Edge marker={m} d="M469 178 H597" />
      <Label x={533} y={196} anchor="middle">
        deny or no answer
      </Label>
    </svg>
  )
}

/* Top to bottom: the paused path runs down the left, "allowed" sits right. */
function Column() {
  const m = 'flow-column'
  const app: Box = { x: 1, y: 1, w: 170, title: 'app', sub: 'opens a connection' }
  const shield: Box = { x: 1, y: 101, w: 170, title: 'netshield', sub: 'checks your rules', tone: 'key' }
  const allowed: Box = { x: 239, y: 101, w: 100, title: 'allowed' }
  const decide: Box = { x: 1, y: 211, w: 170, title: 'you or fx', sub: 'approve or deny', tone: 'warn' }
  const dropped: Box = { x: 1, y: 321, w: 170, title: 'dropped' }
  return (
    <svg viewBox="0 0 340 374" role="img" aria-label={label} className="block h-auto w-full font-mono min-[641px]:hidden">
      <Marker id={m} />
      {[app, shield, allowed, decide, dropped].map((box) => (
        <Node key={box.title} {...box} />
      ))}
      <Edge marker={m} d="M50 53 V99" />
      <Edge marker={m} d="M171 127 H237" />
      <Label x={205} y={119} anchor="middle">
        rule
      </Label>
      <Edge marker={m} d="M50 153 V209" />
      <Label x={58} y={185}>
        no rule: paused
      </Label>
      <Edge marker={m} d="M171 237 H289 V155" />
      <Label x={230} y={229} anchor="middle">
        approve
      </Label>
      <Edge marker={m} d="M50 263 V319" />
      <Label x={58} y={295}>
        deny or no answer
      </Label>
    </svg>
  )
}

export function FlowDiagram() {
  return (
    <figure className="mt-16">
      <Row />
      <Column />
    </figure>
  )
}
