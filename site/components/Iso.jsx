// Small isometric illustrations drawn from 3D coordinates, so every edge lines up.
const C = 0.8660254;
const iso = (x, y, z) => [(x - y) * C, (x + y) * 0.5 - z];
const pts = (list) => list.map(([x, y, z]) => iso(x, y, z).map((n) => n.toFixed(2)).join(',')).join(' ');
const seg = (a, b) => {
  const [x1, y1] = iso(...a);
  const [x2, y2] = iso(...b);
  return { x1: x1.toFixed(2), y1: y1.toFixed(2), x2: x2.toFixed(2), y2: y2.toFixed(2) };
};

function faces(x, y, z, w, d, h) {
  return {
    top: pts([[x, y, z + h], [x + w, y, z + h], [x + w, y + d, z + h], [x, y + d, z + h]]),
    right: pts([[x + w, y, z], [x + w, y + d, z], [x + w, y + d, z + h], [x + w, y, z + h]]),
    left: pts([[x, y + d, z], [x + w, y + d, z], [x + w, y + d, z + h], [x, y + d, z + h]]),
    hidden: [
      seg([x, y, z], [x + w, y, z]),
      seg([x, y, z], [x, y + d, z]),
      seg([x, y, z], [x, y, z + h]),
    ],
  };
}

function Box({ b, top, right, left, stroke = 0.9, dashedHidden = false }) {
  return (
    <g>
      {dashedHidden
        ? b.hidden.map((l, i) => <line key={i} {...l} className="iso-hidden" />)
        : null}
      <polygon points={b.left} className="iso-face" style={{ fillOpacity: left }} strokeOpacity={stroke} />
      <polygon points={b.right} className="iso-face" style={{ fillOpacity: right }} strokeOpacity={stroke} />
      <polygon points={b.top} className="iso-face" style={{ fillOpacity: top }} strokeOpacity={stroke} />
    </g>
  );
}

export function IsoScope() {
  const outer = faces(0, 0, 0, 84, 84, 52);
  const inner = faces(28, 28, 0, 30, 30, 24);
  const nested = faces(34, 34, 24, 16, 16, 12);
  return (
    <svg className="iso" viewBox="-86 -66 172 156" aria-hidden="true">
      {outer.hidden.map((l, i) => <line key={i} {...l} className="iso-hidden" />)}
      <Box b={inner} top={0.95} right={0.5} left={0.28} />
      <Box b={nested} top={0.95} right={0.5} left={0.28} />
      <Box b={outer} top={0.035} right={0.025} left={0.015} stroke={0.45} />
    </svg>
  );
}

export function IsoPolicy() {
  const sheet = faces(0, 0, 0, 72, 92, 3);
  const rows = [16, 32, 48, 64, 80];
  return (
    <svg className="iso" viewBox="-88 -14 156 104" aria-hidden="true">
      <Box b={sheet} top={0.05} right={0.35} left={0.2} stroke={0.6} />
      {rows.map((y, i) => {
        const deny = i === 3;
        const dot = iso(12, y, 3);
        const line = seg([20, y, 3], [deny ? 46 : 58 - (i % 2) * 10, y, 3]);
        return (
          <g key={y} className={deny ? 'iso-deny' : undefined}>
            <circle cx={dot[0].toFixed(2)} cy={dot[1].toFixed(2)} r="1.8" className="iso-dot" />
            <line {...line} className="iso-line" />
          </g>
        );
      })}
    </svg>
  );
}

export function IsoReceipt() {
  const slabs = [0, 12, 24].map((z) => faces(0, 0, z, 64, 44, 4));
  return (
    <svg className="iso" viewBox="-46 -40 108 100" aria-hidden="true">
      {slabs.map((b, i) => (
        <g key={i} style={{ opacity: 0.45 + i * 0.27 }}>
          <Box b={b} top={0.06} right={0.4} left={0.22} stroke={0.7} />
          {[12, 24].map((y) => (
            <line key={y} {...seg([10, y, i * 12 + 4], [i === 2 && y === 24 ? 34 : 52, y, i * 12 + 4])} className="iso-line" />
          ))}
        </g>
      ))}
      <circle cx={iso(46, 30, 28)[0].toFixed(2)} cy={iso(46, 30, 28)[1].toFixed(2)} r="2.4" className="iso-ok" />
    </svg>
  );
}
