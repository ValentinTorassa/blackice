import { IconTerminal, IconNested, IconPolicy, IconChip, IconGlobe } from './Icons';

// The v0 enforcement path as designed, drawn as a stack of planes in CSS 3D.
const LAYERS = [
  { key: 'process', name: 'Process', Icon: IconTerminal, text: 'fx, a test runner or an install, and every process they start.' },
  { key: 'scope', name: 'Task scope', Icon: IconNested, text: 'Created before exec. Child processes inherit it and cannot leave it.' },
  { key: 'policy', name: 'Policy', Icon: IconPolicy, text: 'A strict JSON file, loaded once: a mode, allowed names, subnets and ports.' },
  {
    key: 'enforce',
    name: 'Enforcement',
    Icon: IconChip,
    text: 'Linux: eBPF on the task\'s cgroup. macOS: the built-in sandbox. Both let the command reach only a local proxy, which checks every name and address. A denied connection stops here.',
  },
  { key: 'net', name: 'Network', Icon: IconGlobe, text: 'Only destinations the policy names get through. Every decision writes a receipt.' },
];

const pos = (x, y, extra) => ({ '--x': `${x}px`, '--y': `${y}px`, ...extra });

export default function Layers() {
  return (
    <div className="layers">
      <div className="layers-stage" aria-hidden="true">
        <div className="layers-3d">
          {LAYERS.map((l, i) => (
            <div className={`plane plane-${l.key}`} style={{ '--i': i }} key={l.key}>
              <span className="plane-label">
                0{i + 1} · {l.name}
              </span>
            </div>
          ))}
          <span className="beam-v" style={pos(64, 150)} />
          <span className="beam-v" style={pos(162, 72)} />
          <span className="beam-v beam-v-deny" style={pos(150, 168)} />
          <span className="pkt pkt-allow" style={pos(64, 150, { '--d': '0s' })} />
          <span className="pkt pkt-allow" style={pos(162, 72, { '--d': '1.9s' })} />
          <span className="pkt pkt-deny" style={pos(150, 168, { '--d': '3.8s' })} />
          <span className="ring" style={pos(150, 168)} />
          <span className="pkt-tag pkt-tag-allow" style={pos(64, 150)}>allowed_by_rule</span>
          <span className="pkt-tag pkt-tag-deny" style={pos(150, 168)}>no_matching_rule</span>
        </div>
      </div>
      <ol className="layers-list">
        {LAYERS.map(({ key, name, Icon, text }, i) => (
          <li key={key} className={key === 'enforce' ? 'is-enforce' : undefined}>
            <span className="layer-icon">
              <Icon size={16} />
            </span>
            <div>
              <p className="layer-name">
                <span className="mono faint">0{i + 1}</span>
                {name}
              </p>
              <p className="layer-text">{text}</p>
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}
