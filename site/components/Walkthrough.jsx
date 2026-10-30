// The narrated walkthrough: one English cut, subtitles in the picture, served from outside the build
// (content/demo.js). It has no language switch, so it stays out of the nav flags.
export default function Walkthrough({ src, poster }) {
  return (
    <figure className="frame demo">
      <figcaption className="frame-bar">
        <span className="frame-title">walkthrough · 4 min</span>
      </figcaption>
      <video className="demo-video" src={src} poster={poster || undefined} controls preload="metadata" playsInline />
    </figure>
  );
}
