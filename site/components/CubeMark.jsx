// A glass scope with a solid scope resting inside it, in CSS 3D.
const FACES = ['front', 'back', 'right', 'left', 'top', 'bottom'];

export default function CubeMark() {
  return (
    <div className="cube-stage" aria-hidden="true">
      <div className="cube">
        {FACES.map((f) => (
          <span key={f} className={`face f-${f}`} />
        ))}
        <div className="cube-inner">
          {FACES.map((f) => (
            <span key={f} className={`face f-${f}`} />
          ))}
        </div>
      </div>
      <div className="cube-floor" />
    </div>
  );
}
