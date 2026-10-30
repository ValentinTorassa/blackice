// Monoline icons on a 24px grid. They inherit color from the text.
function Svg({ size = 18, children, ...rest }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...rest}
    >
      {children}
    </svg>
  );
}

// The mark: the six corners of a scope boundary on an isometric grid, with the process it holds
// at the centre. The corners are shaded like the faces of a cube lit from above.
const CORNERS_SM = [
  'M8.796 3.85 12 2 15.204 3.85 15.204 5.871 12 4.021 8.796 5.871Z',
  'M17.456 5.15 20.66 7 20.66 10.7 18.91 9.69 18.91 8.01 17.456 7.171Z',
  'M20.66 13.3 20.66 17 17.456 18.85 17.456 16.829 18.91 15.99 18.91 14.31Z',
  'M15.204 20.15 12 22 8.796 20.15 8.796 18.129 12 19.979 15.204 18.129Z',
  'M6.544 18.85 3.34 17 3.34 13.3 5.09 14.31 5.09 15.99 6.544 16.829Z',
  'M3.34 10.7 3.34 7 6.544 5.15 6.544 7.171 5.09 8.01 5.09 9.69Z',
];
const CORNERS = [
  'M8.969 3.75 12 2 15.031 3.75 15.031 5.078 12 3.328 8.969 5.078Z',
  'M17.629 5.25 20.66 7 20.66 10.5 19.51 9.836 19.51 7.664 17.629 6.578Z',
  'M20.66 13.5 20.66 17 17.629 18.75 17.629 17.422 19.51 16.336 19.51 14.164Z',
  'M15.031 20.25 12 22 8.969 20.25 8.969 18.922 12 20.672 15.031 18.922Z',
  'M6.371 18.75 3.34 17 3.34 13.5 4.49 14.164 4.49 16.336 6.371 17.422Z',
  'M3.34 10.5 3.34 7 6.371 5.25 6.371 6.578 4.49 7.664 4.49 9.836Z',
];
const SHADE_SM = [1, 0.55, 0.8, 1, 0.55, 0.8];
const SHADE = [1, 0.45, 0.75, 1, 0.45, 0.75];
// The open stretches of the boundary between the corners, for the dashed guide at large sizes.
const GAPS =
  'M15.194 4.508 16.892 5.488M20.085 11.02 20.085 12.98M16.892 18.512 15.194 19.492' +
  'M8.806 19.492 7.108 18.512M3.915 12.98 3.915 11.02M7.108 5.488 8.806 4.508';

export function Logo({ size = 22, className }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" className={className}>
      {CORNERS_SM.map((d, i) => (
        <path key={i} d={d} fill="currentColor" fillOpacity={SHADE_SM[i]} />
      ))}
      <circle cx="12" cy="12" r="1.7" fill="currentColor" />
    </svg>
  );
}

// Large sizes: slimmer corners. With `guides`, a dashed boundary joins them and a ring marks the
// process. `line` is the guide width in screen pixels at any size.
export function LogoFull({ size = 160, line = 1, guides = false, className }) {
  const u = 24 / size;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" className={className}>
      {guides ? (
        <g fill="none" stroke="currentColor" strokeWidth={line * u} strokeLinecap="round">
          <path d={GAPS} strokeDasharray={`${0.01 * u} ${7 * u}`} strokeWidth={line * 1.6 * u} strokeOpacity="0.55" />
          <circle cx="12" cy="12" r="2.7" strokeOpacity="0.3" />
        </g>
      ) : null}
      {CORNERS.map((d, i) => (
        <path key={i} d={d} fill="currentColor" fillOpacity={SHADE[i]} />
      ))}
      <circle cx="12" cy="12" r="1" fill="currentColor" />
    </svg>
  );
}

// The name, set in Geist.
export function Wordmark({ className = '' }) {
  return <span className={`wordmark ${className}`}>blackice</span>;
}

export const IconCube = (p) => (
  <Svg {...p}>
    <path d="M12 3 20 7.5v9L12 21l-8-4.5v-9z" />
    <path d="M4 7.5 12 12l8-4.5M12 12v9" />
  </Svg>
);

export const IconNested = (p) => (
  <Svg {...p}>
    <rect x="3" y="3" width="18" height="18" rx="3" />
    <rect x="7.5" y="7.5" width="9" height="9" rx="1.5" />
  </Svg>
);

export const IconPolicy = (p) => (
  <Svg {...p}>
    <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
    <path d="M14 3v5h5M9 13h6M9 17h4" />
  </Svg>
);

export const IconReceipt = (p) => (
  <Svg {...p}>
    <path d="M6 3h12v18l-2-1.4-2 1.4-2-1.4-2 1.4-2-1.4L6 21z" />
    <path d="M9 8h6M9 12h6M9 16h3" />
  </Svg>
);

export const IconTerminal = (p) => (
  <Svg {...p}>
    <rect x="3" y="4" width="18" height="16" rx="2.5" />
    <path d="m7.5 9.5 3 2.5-3 2.5M12.5 15h4" />
  </Svg>
);

export const IconArrowInto = (p) => (
  <Svg {...p}>
    <path d="M4 12v6a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6" />
    <path d="M12 3v11m-4-4 4 4 4-4" />
  </Svg>
);

export const IconNarrow = (p) => (
  <Svg {...p}>
    <path d="M3 12h6m-3-3 3 3-3 3M21 12h-6m3-3-3 3 3 3M12 4v16" />
  </Svg>
);

export const IconWrap = (p) => (
  <Svg {...p}>
    <path d="M8 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h2M16 4h2a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-2" />
    <path d="m9.5 10 2 2-2 2M13 14h2" />
  </Svg>
);

export const IconLines = (p) => (
  <Svg {...p}>
    <path d="M4 6h16M4 10h16M4 14h10M4 18h7" />
  </Svg>
);

export const IconClock = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 7.5V12l3 2" />
  </Svg>
);

export const IconChip = (p) => (
  <Svg {...p}>
    <rect x="6" y="6" width="12" height="12" rx="2" />
    <path d="M9.5 9.5h5v5h-5zM9 2.5V6m6-3.5V6M9 18v3.5m6-3.5v3.5M2.5 9H6m-3.5 6H6M18 9h3.5M18 15h3.5" />
  </Svg>
);

export const IconGlobe = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M3.5 12h17M12 3.5c2.4 2.4 3.5 5.2 3.5 8.5s-1.1 6.1-3.5 8.5c-2.4-2.4-3.5-5.2-3.5-8.5s1.1-6.1 3.5-8.5" />
  </Svg>
);

export const IconCommand = (p) => (
  <Svg {...p}>
    <path d="M9 9V6.5A2.5 2.5 0 1 0 6.5 9H9zm0 0h6m-6 0v6m6-6V6.5A2.5 2.5 0 1 1 17.5 9H15zm0 0v6m0 0h-6m6 0v2.5a2.5 2.5 0 1 0 2.5-2.5H15zm-6 0v2.5A2.5 2.5 0 1 1 6.5 15H9z" />
  </Svg>
);

export const IconPenguin = (p) => (
  <Svg {...p}>
    <path d="M12 3c-2.4 0-3.9 2-3.9 4.6 0 1.2.2 2.1-.6 3.4-1 1.6-2.2 3.1-2.2 5.2C5.3 18.7 8 20.5 12 20.5s6.7-1.8 6.7-4.3c0-2.1-1.2-3.6-2.2-5.2-.8-1.3-.6-2.2-.6-3.4C15.9 5 14.4 3 12 3z" />
    <path d="M9.4 14.6c0-1.9 1.2-3.3 2.6-3.3s2.6 1.4 2.6 3.3-1.2 3.6-2.6 3.6-2.6-1.7-2.6-3.6z" />
    <path d="M10.4 7.2h.01M13.6 7.2h.01M11 9h2l-1 1z" strokeWidth="1.8" />
  </Svg>
);

export const IconScale = (p) => (
  <Svg {...p}>
    <path d="M12 4v16M8 20h8M5 7h14M5 7l-2.5 6a2.5 2.5 0 0 0 5 0zM19 7l-2.5 6a2.5 2.5 0 0 0 5 0z" />
  </Svg>
);

export const IconInfo = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 11v5M12 8h.01" />
  </Svg>
);

export const IconBook = (p) => (
  <Svg {...p}>
    <path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5zM4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5" />
  </Svg>
);

export const IconCompass = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="m15.5 8.5-2 5-5 2 2-5z" />
  </Svg>
);

export const IconFlag = (p) => (
  <Svg {...p}>
    <path d="M5 21V4m0 0h11l-1.5 4L16 12H5" />
  </Svg>
);

export const IconArrowRight = (p) => (
  <Svg {...p}>
    <path d="M5 12h14m-5-5 5 5-5 5" />
  </Svg>
);

export const IconCheck = (p) => (
  <Svg {...p}>
    <path d="m5 12.5 4.5 4.5L19 7.5" />
  </Svg>
);

export const IconCopy = (p) => (
  <Svg {...p}>
    <rect x="8" y="8" width="12" height="12" rx="2" />
    <path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" />
  </Svg>
);

export const IconReplay = (p) => (
  <Svg {...p}>
    <path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 4v4h4" />
  </Svg>
);

export const IconLayers = (p) => (
  <Svg {...p}>
    <path d="m12 3.5 8.5 4.75L12 13 3.5 8.25z" />
    <path d="m3.5 12.25 8.5 4.75 8.5-4.75M3.5 16.25 12 21l8.5-4.75" />
  </Svg>
);

export const IconGitHub = ({ size = 18 }) => (
  <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true" fill="currentColor">
    <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
  </svg>
);
