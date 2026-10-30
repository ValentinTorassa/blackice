// The mark in CSS 3D: a glass scope with bright corners, and the process it holds glowing at the
// centre. At the isometric angle the cube lines up with the flat logo.
const FACES = ['front', 'back', 'right', 'left', 'top', 'bottom'];

export default function CubeMark() {
  return (
    <div className="cube-stage" aria-hidden="true">
      <div className="cube">
        {FACES.map((f) => (
          <span key={f} className={`face f-${f}`} />
        ))}
        <span className="cube-core" />
      </div>
      <div className="cube-floor" />
    </div>
  );
}
