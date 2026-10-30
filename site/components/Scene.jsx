'use client';

import { useEffect, useRef, useState } from 'react';

// Illustration only: simulated traffic, not product output.
// Colors carry meaning: white for the task and its tools, blue for apps, gray for the host,
// green for traffic that was allowed, red for traffic that was denied.
const WHITE = 0xffffff;
const RED = 0xe5484d;
const GREEN = 0x4ade80;
const BLUE = 0x60a5fa;
const HOST = 0x9a9a9a;
const TRAIL = 12;

// Glass: a face glows more as it turns away from the viewer, and more toward its top.
const GLASS_VERT = /* glsl */ `
varying vec3 vN;
varying vec3 vV;
varying float vH;
void main() {
  vec4 wp = modelMatrix * vec4(position, 1.0);
  vN = normalize(mat3(modelMatrix) * normal);
  vV = normalize(cameraPosition - wp.xyz);
  vH = uv.y;
  gl_Position = projectionMatrix * viewMatrix * wp;
}`;
const GLASS_FRAG = /* glsl */ `
uniform vec3 uColor;
uniform vec3 uFlashColor;
uniform float uStrength;
uniform float uFlash;
varying vec3 vN;
varying vec3 vV;
varying float vH;
void main() {
  float f = pow(1.0 - abs(dot(normalize(vN), normalize(vV))), 2.0);
  float a = uStrength * (0.3 + 1.5 * f) * (0.5 + 0.5 * vH) * (1.0 + 3.0 * uFlash);
  gl_FragColor = vec4(mix(uColor, uFlashColor, uFlash) * a, 1.0);
}`;

// A boundary lighting up where a refused connection hits it: a hex field and a shock ring.
const SHIELD_VERT = /* glsl */ `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}`;
const SHIELD_FRAG = /* glsl */ `
uniform vec2 uSize;
uniform vec2 uHit;
uniform float uT;
uniform vec3 uColor;
varying vec2 vUv;
float hexEdge(vec2 p) {
  vec2 r = vec2(1.0, 1.7320508);
  vec2 h = r * 0.5;
  vec2 a = mod(p, r) - h;
  vec2 b = mod(p - h, r) - h;
  vec2 g = abs(dot(a, a) < dot(b, b) ? a : b);
  return 0.5 - max(dot(g, normalize(r)), g.x);
}
void main() {
  vec2 p = (vUv - 0.5) * uSize;
  float d = length(p - uHit);
  float edge = 1.0 - smoothstep(0.02, 0.07, hexEdge(p * 6.0));
  float ring = exp(-pow((d - uT * 1.6) * 6.0, 2.0));
  float core = exp(-d * 3.2);
  float fade = (1.0 - uT) * (1.0 - uT);
  float a = (edge * (ring * 1.5 + core * 1.1) + ring * 0.3 + core * 0.45) * fade;
  gl_FragColor = vec4(uColor * a, 1.0);
}`;

const loadPost = () =>
  Promise.all([
    import('three/examples/jsm/postprocessing/EffectComposer.js'),
    import('three/examples/jsm/postprocessing/RenderPass.js'),
    import('three/examples/jsm/postprocessing/UnrealBloomPass.js'),
    import('three/examples/jsm/postprocessing/OutputPass.js'),
  ]).catch(() => null);

export default function Scene() {
  const wrapRef = useRef(null);
  const labelsRef = useRef(null);
  const [mode, setMode] = useState('loading'); // loading | webgl | fallback

  useEffect(() => {
    let disposed = false;
    let cleanup = () => {};

    (async () => {
      const [THREE, post] = await Promise.all([import('three'), loadPost()]);
      if (disposed || !wrapRef.current) return;

      let renderer;
      try {
        renderer = new THREE.WebGLRenderer({ antialias: true });
      } catch {
        setMode('fallback');
        return;
      }
      setMode('webgl');

      const wrap = wrapRef.current;
      const labelsEl = labelsRef.current;
      const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);

      renderer.setPixelRatio(pixelRatio);
      renderer.setClearColor(0x000000, 1);
      renderer.domElement.className = 'scene-canvas';
      renderer.domElement.setAttribute('aria-hidden', 'true');
      wrap.prepend(renderer.domElement);

      const scene = new THREE.Scene();
      scene.fog = new THREE.Fog(0x000000, 20, 60);
      const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 200);
      const target = new THREE.Vector3(0, 1.9, -0.3);
      const tmp = new THREE.Vector3();
      const tmp2 = new THREE.Vector3();

      const disposables = [];
      const track = (x) => (disposables.push(x), x);

      // Bloom on everything bright. If post-processing is unavailable, the scene renders plainly.
      let composer = null;
      if (post) {
        try {
          const [{ EffectComposer }, { RenderPass }, { UnrealBloomPass }, { OutputPass }] = post;
          // Multisampling where pixels are large; on high-density screens the pixels do that job.
          const target2 = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, samples: pixelRatio >= 1.75 ? 0 : 4 });
          composer = new EffectComposer(renderer, target2);
          composer.setPixelRatio(pixelRatio);
          composer.addPass(new RenderPass(scene, camera));
          composer.addPass(new UnrealBloomPass(new THREE.Vector2(1, 1), 0.6, 0.42, 0.34));
          composer.addPass(new OutputPass());
        } catch {
          composer = null;
        }
      }

      // Soft round glow, drawn once and shared by every sprite.
      const glowTex = (() => {
        const c = document.createElement('canvas');
        c.width = c.height = 64;
        const g = c.getContext('2d');
        const grd = g.createRadialGradient(32, 32, 0, 32, 32, 32);
        grd.addColorStop(0, 'rgba(255,255,255,1)');
        grd.addColorStop(0.22, 'rgba(255,255,255,0.42)');
        grd.addColorStop(1, 'rgba(255,255,255,0)');
        g.fillStyle = grd;
        g.fillRect(0, 0, 64, 64);
        return track(new THREE.CanvasTexture(c));
      })();
      const sharedGlow = {};
      function glowMat(color, opacity) {
        const key = `${color}:${opacity}`;
        if (!sharedGlow[key]) {
          sharedGlow[key] = track(
            new THREE.SpriteMaterial({ map: glowTex, color, transparent: true, opacity, blending: THREE.AdditiveBlending, depthWrite: false, fog: false }),
          );
        }
        return sharedGlow[key];
      }
      function glow(color, size, opacity) {
        const s = new THREE.Sprite(glowMat(color, opacity));
        s.scale.setScalar(size);
        return s;
      }
      function oneOffGlow(color, size, opacity) {
        const m = new THREE.SpriteMaterial({ map: glowTex, color, transparent: true, opacity, blending: THREE.AdditiveBlending, depthWrite: false, fog: false });
        const s = new THREE.Sprite(m);
        s.scale.setScalar(size);
        return s;
      }

      // A glossy floor: dim mirrored copies below y = 0. Lines and meshes write depth, so the
      // dark veils under the floor fade them more the deeper they sit. Glows are drawn after the veils.
      const MIRROR = -3;
      const mirror = new THREE.Group();
      mirror.scale.y = -1;
      scene.add(mirror);
      function reflect(obj, amount) {
        const c = obj.clone();
        const m = track(obj.material.clone());
        m.transparent = true;
        m.opacity = (obj.material.opacity ?? 1) * amount;
        m.depthWrite = !obj.isSprite;
        c.material = m;
        c.renderOrder = obj.isSprite ? MIRROR + 1.5 : MIRROR;
        mirror.add(c);
        return c;
      }
      const veilGeo = track(new THREE.PlaneGeometry(90, 90));
      for (const [y, o] of [
        [-0.45, 0.35],
        [-1.2, 0.5],
        [-2.4, 0.7],
      ]) {
        const veil = new THREE.Mesh(veilGeo, track(new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: o, depthWrite: false })));
        veil.rotation.x = -Math.PI / 2;
        veil.position.y = y;
        veil.renderOrder = MIRROR + 1;
        scene.add(veil);
      }

      // Ground.
      const grid = new THREE.GridHelper(24, 48, 0x222222, 0x111111);
      grid.material.transparent = true;
      grid.material.opacity = 0.9;
      grid.renderOrder = MIRROR + 2;
      track(grid.geometry);
      track(grid.material);
      scene.add(grid);

      // Dust for depth.
      const dust = (() => {
        const n = 520;
        const pos = new Float32Array(n * 3);
        for (let i = 0; i < n; i++) {
          let x;
          let y;
          let z;
          do {
            x = (Math.random() - 0.5) * 34;
            y = Math.random() * 12 - 0.5;
            z = (Math.random() - 0.5) * 26;
          } while (Math.abs(x) < 7 && Math.abs(z) < 5 && y < 4);
          pos[i * 3] = x;
          pos[i * 3 + 1] = y;
          pos[i * 3 + 2] = z;
        }
        const geo = track(new THREE.BufferGeometry());
        geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
        const mat = track(new THREE.PointsMaterial({ color: 0x8a8a8a, size: 0.05, transparent: true, opacity: 0.5, depthWrite: false }));
        const points = new THREE.Points(geo, mat);
        scene.add(points);
        return points;
      })();

      // Scopes: edges, glass faces, and bright corners on the task scope, like the mark.
      function cornerGeo(box, len) {
        const pts = [];
        const { min, max } = box;
        for (const x of [min.x, max.x]) {
          for (const y of [min.y, max.y]) {
            for (const z of [min.z, max.z]) {
              const sx = x === min.x ? 1 : -1;
              const sy = y === min.y ? 1 : -1;
              const sz = z === min.z ? 1 : -1;
              pts.push(x, y, z, x + sx * len, y, z, x, y, z, x, y + sy * len, z, x, y, z, x, y, z + sz * len);
            }
          }
        }
        const g = track(new THREE.BufferGeometry());
        g.setAttribute('position', new THREE.Float32BufferAttribute(pts, 3));
        return g;
      }

      const scopes = [];
      function addScope({ size, pos, color, opacity, dashed, glass, corners, footprint }) {
        const [w, h, d] = size;
        const geo = track(new THREE.BoxGeometry(w, h, d));
        const edges = track(new THREE.EdgesGeometry(geo));
        const mat = track(
          dashed
            ? new THREE.LineDashedMaterial({ color, dashSize: 0.16, gapSize: 0.11, transparent: true, opacity })
            : new THREE.LineBasicMaterial({ color, transparent: true, opacity }),
        );
        const line = new THREE.LineSegments(edges, mat);
        if (dashed) line.computeLineDistances();
        line.position.set(pos[0], pos[1], pos[2]);
        scene.add(line);
        reflect(line, 0.32);
        let glassMat = null;
        if (glass) {
          glassMat = track(
            new THREE.ShaderMaterial({
              uniforms: {
                uColor: { value: new THREE.Color(color) },
                uFlashColor: { value: new THREE.Color(RED) },
                uStrength: { value: glass },
                uFlash: { value: 0 },
              },
              vertexShader: GLASS_VERT,
              fragmentShader: GLASS_FRAG,
              transparent: true,
              depthWrite: false,
              side: THREE.DoubleSide,
              blending: THREE.AdditiveBlending,
            }),
          );
          const m = new THREE.Mesh(geo, glassMat);
          m.position.copy(line.position);
          scene.add(m);
        }
        if (footprint) {
          // A faint footprint on the floor, so each scope reads as its own block.
          const f = new THREE.Mesh(
            track(new THREE.PlaneGeometry(w, d)),
            track(new THREE.MeshBasicMaterial({ color, transparent: true, opacity: footprint, blending: THREE.AdditiveBlending, depthWrite: false })),
          );
          f.rotation.x = -Math.PI / 2;
          f.position.set(pos[0], 0.003, pos[2]);
          scene.add(f);
        }
        const box = new THREE.Box3(
          new THREE.Vector3(pos[0] - w / 2, pos[1] - h / 2, pos[2] - d / 2),
          new THREE.Vector3(pos[0] + w / 2, pos[1] + h / 2, pos[2] + d / 2),
        );
        let cornerMat = null;
        if (corners) {
          cornerMat = track(new THREE.LineBasicMaterial({ color: WHITE, transparent: true, opacity: 1 }));
          const c = new THREE.LineSegments(cornerGeo(box, corners), cornerMat);
          scene.add(c);
          reflect(c, 0.32);
        }
        const scope = { line, mat, box, base: new THREE.Color(color), baseOpacity: opacity, flash: 0, glassMat, cornerMat };
        scopes.push(scope);
        return scope;
      }

      addScope({ size: [12, 3.4, 8], pos: [0, 1.7, 0], color: HOST, opacity: 0.24, glass: 0.006 });
      const appA = addScope({ size: [2.4, 1.0, 1.8], pos: [-3.7, 0.5, 2.0], color: BLUE, opacity: 0.85, dashed: true, glass: 0.035, footprint: 0.07 });
      const appB = addScope({ size: [2.4, 1.0, 1.8], pos: [-3.7, 0.5, -1.7], color: BLUE, opacity: 0.85, dashed: true, glass: 0.035, footprint: 0.07 });
      addScope({ size: [4.4, 2.0, 4.6], pos: [1.9, 1.0, 0], color: WHITE, opacity: 0.55, glass: 0.035, corners: 0.55, footprint: 0.03 });
      const toolA = addScope({ size: [1.5, 1.1, 1.5], pos: [1.0, 0.56, -1.05], color: WHITE, opacity: 0.55, glass: 0.04 });
      const toolB = addScope({ size: [1.5, 1.1, 1.5], pos: [2.8, 0.56, 1.05], color: WHITE, opacity: 0.55, glass: 0.04 });

      // Light pooled on the floor under the task scope.
      const pool = new THREE.Mesh(
        track(new THREE.PlaneGeometry(8, 8)),
        track(new THREE.MeshBasicMaterial({ map: glowTex, color: WHITE, transparent: true, opacity: 0.13, blending: THREE.AdditiveBlending, depthWrite: false })),
      );
      pool.rotation.x = -Math.PI / 2;
      pool.position.set(1.9, 0.004, 0);
      scene.add(pool);

      // A scan plane sweeping up through the task scope.
      const scanGeo = track(new THREE.PlaneGeometry(4.4, 4.6));
      const scanMat = track(new THREE.MeshBasicMaterial({ color: WHITE, transparent: true, opacity: 0, side: THREE.DoubleSide, depthWrite: false }));
      const scanLineMat = track(new THREE.LineBasicMaterial({ color: WHITE, transparent: true, opacity: 0 }));
      const scan = new THREE.Mesh(scanGeo, scanMat);
      const scanEdges = new THREE.LineSegments(track(new THREE.EdgesGeometry(scanGeo)), scanLineMat);
      for (const o of [scan, scanEdges]) {
        o.rotation.x = -Math.PI / 2;
        o.position.set(1.9, 0, 0);
        scene.add(o);
      }

      // Processes, each with a halo that breathes and flares when it sends.
      const nodeGeo = track(new THREE.SphereGeometry(0.07, 16, 16));
      const nodeMat = track(new THREE.MeshBasicMaterial({ color: WHITE }));
      const appNodeMat = track(new THREE.MeshBasicMaterial({ color: 0x93c5fd }));
      const nodes = [];
      function node(scope, mat, glowOpacity, glowColor = WHITE, size = 0.9) {
        const c = new THREE.Vector3();
        scope.box.getCenter(c);
        const m = new THREE.Mesh(nodeGeo, mat);
        m.position.copy(c);
        scene.add(m);
        reflect(m, 0.35);
        const g = glow(glowColor, size, glowOpacity);
        g.position.copy(c);
        scene.add(g);
        reflect(g, 0.3);
        nodes.push({ at: c, g, size, phase: Math.random() * 6.28, flare: 0 });
        return c;
      }
      const nToolA = node(toolA, nodeMat, 0.22, WHITE, 0.7);
      const nToolB = node(toolB, nodeMat, 0.22, WHITE, 0.7);
      const nAppA = node(appA, appNodeMat, 0.22, BLUE);
      const nAppB = node(appB, appNodeMat, 0.22, BLUE);

      // Destinations outside the host ceiling, each on a stem down to the ground.
      const dests = {
        registry: new THREE.Vector3(7.3, 4.3, -2.7),
        github: new THREE.Vector3(6.5, 4.9, 3.0),
        paste: new THREE.Vector3(-0.8, 5.2, -5.5),
        tracker: new THREE.Vector3(-7.3, 4.0, 2.6),
      };
      const destGeo = track(new THREE.OctahedronGeometry(0.16, 0));
      const destAllowMat = track(new THREE.MeshBasicMaterial({ color: GREEN, wireframe: true }));
      const destDenyMat = track(new THREE.MeshBasicMaterial({ color: RED, wireframe: true, transparent: true, opacity: 0.75 }));
      const stemAllowMat = track(new THREE.LineDashedMaterial({ color: 0x1d4a2c, dashSize: 0.1, gapSize: 0.12 }));
      const stemDenyMat = track(new THREE.LineDashedMaterial({ color: 0x4a1d20, dashSize: 0.1, gapSize: 0.12 }));
      const groundRingGeo = track(new THREE.RingGeometry(0.2, 0.235, 40));
      const groundAllowMat = track(new THREE.MeshBasicMaterial({ color: 0x24603a, side: THREE.DoubleSide }));
      const groundDenyMat = track(new THREE.MeshBasicMaterial({ color: 0x5e2427, side: THREE.DoubleSide }));
      const destObjs = new Map();
      for (const [k, v] of Object.entries(dests)) {
        const denied = k === 'paste' || k === 'tracker';
        const m = new THREE.Mesh(destGeo, denied ? destDenyMat : destAllowMat);
        m.position.copy(v);
        scene.add(m);
        const mm = reflect(m, 0.35);
        const g = glow(denied ? RED : GREEN, denied ? 0.8 : 1.2, denied ? 0.14 : 0.26);
        g.position.copy(v);
        scene.add(g);
        reflect(g, 0.3);
        const stem = new THREE.Line(track(new THREE.BufferGeometry().setFromPoints([v, new THREE.Vector3(v.x, 0, v.z)])), denied ? stemDenyMat : stemAllowMat);
        stem.computeLineDistances();
        scene.add(stem);
        reflect(stem, 0.5);
        const ring = new THREE.Mesh(groundRingGeo, denied ? groundDenyMat : groundAllowMat);
        ring.rotation.x = -Math.PI / 2;
        ring.position.set(v.x, 0.01, v.z);
        scene.add(ring);
        destObjs.set(v, { mesh: m, mirror: mm, pulse: 0 });
      }

      // Faint guides for allowed routes.
      const guideMat = track(new THREE.LineDashedMaterial({ color: 0x2c2c2c, dashSize: 0.12, gapSize: 0.14 }));
      for (const [a, b] of [
        [nToolA, dests.registry],
        [nToolB, dests.github],
        [nAppA, dests.github],
      ]) {
        const l = new THREE.Line(track(new THREE.BufferGeometry().setFromPoints([a, b])), guideMat);
        l.computeLineDistances();
        scene.add(l);
      }

      // Routes. A denied packet stops at the boundary of the innermost scope that denies it.
      const ray = new THREE.Ray();
      function exitPoint(from, to, scope) {
        ray.origin.copy(from);
        ray.direction.copy(to).sub(from).normalize();
        return ray.intersectBox(scope.box, new THREE.Vector3());
      }
      // An allowed packet turns green where it leaves its own scope, the point where it was checked.
      const routes = [
        { from: nToolA, to: dests.registry, inner: toolA, weight: 3 },
        { from: nToolB, to: dests.github, inner: toolB, weight: 3 },
        { from: nToolB, to: dests.paste, deniedBy: toolB, weight: 2 },
        { from: nToolA, to: dests.paste, deniedBy: toolA, weight: 1 },
        { from: nAppA, to: dests.github, inner: appA, weight: 2 },
        { from: nAppB, to: dests.tracker, deniedBy: appB, weight: 1.5 },
      ].map((r) => {
        const exit = r.inner ? exitPoint(r.from, r.to, r.inner) : null;
        return {
          ...r,
          stop: r.deniedBy ? exitPoint(r.from, r.to, r.deniedBy) : null,
          cross: exit ? r.from.distanceTo(exit) / r.from.distanceTo(r.to) : 0,
          node: nodes.find((n) => n.at === r.from),
        };
      });
      const totalWeight = routes.reduce((s, r) => s + r.weight, 0);
      function pickRoute() {
        let x = Math.random() * totalWeight;
        for (const r of routes) if ((x -= r.weight) <= 0) return r;
        return routes[0];
      }

      // Packets: a bright head and a comet tail that fades out, both mirrored in the floor.
      const packetGeo = track(new THREE.SphereGeometry(0.05, 12, 12));
      const packetMat = track(new THREE.MeshBasicMaterial({ color: WHITE }));
      const packetGreenMat = track(new THREE.MeshBasicMaterial({ color: GREEN }));
      const packetRedMat = track(new THREE.MeshBasicMaterial({ color: RED }));
      const trailMat = track(new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false }));
      const mirrorTrailMat = track(
        new THREE.LineBasicMaterial({ color: 0x555555, vertexColors: true, transparent: true, blending: THREE.AdditiveBlending }),
      );
      const mirrorHalo = (color) =>
        track(new THREE.SpriteMaterial({ map: glowTex, color, transparent: true, opacity: 0.22, blending: THREE.AdditiveBlending, depthWrite: false, fog: false }));
      const mirrorHaloMat = mirrorHalo(WHITE);
      const mirrorHaloGreen = mirrorHalo(GREEN);
      const mirrorHaloRed = mirrorHalo(RED);
      const cWhite = new THREE.Color(WHITE);
      const cGreen = new THREE.Color(GREEN);
      const cRed = new THREE.Color(RED);
      const cTmp = new THREE.Color();
      const ringGeo = track(new THREE.RingGeometry(0.24, 0.255, 48));
      const packets = [];
      const effects = [];

      function spawn() {
        const r = pickRoute();
        const end = r.stop || r.to;
        const mesh = new THREE.Mesh(packetGeo, packetMat);
        const halo = glow(WHITE, 0.38, 0.22);
        mesh.add(halo);
        const pos = new Float32Array(TRAIL * 3);
        const col = new Float32Array(TRAIL * 3);
        for (let i = 0; i < TRAIL; i++) pos.set([r.from.x, r.from.y, r.from.z], i * 3);
        const trailGeo = new THREE.BufferGeometry();
        trailGeo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
        trailGeo.setAttribute('color', new THREE.BufferAttribute(col, 3));
        const trail = new THREE.Line(trailGeo, trailMat);
        const mTrail = new THREE.Line(trailGeo, mirrorTrailMat);
        const mHalo = new THREE.Sprite(mirrorHaloMat);
        mHalo.scale.setScalar(0.5);
        for (const o of [trail, mTrail]) o.frustumCulled = false;
        mTrail.renderOrder = MIRROR;
        mHalo.renderOrder = MIRROR + 1.5;
        scene.add(mesh, trail);
        mirror.add(mTrail, mHalo);
        if (r.node) r.node.flare = 1;
        packets.push({ r, end, t: 0, dur: Math.max(0.6, r.from.distanceTo(end) / 4.2), mesh, halo, trail, trailGeo, mTrail, mHalo, tint: 'white' });
      }

      function faceNormal(p, box) {
        const e = 1e-3;
        if (Math.abs(p.x - box.min.x) < e) return new THREE.Vector3(-1, 0, 0);
        if (Math.abs(p.x - box.max.x) < e) return new THREE.Vector3(1, 0, 0);
        if (Math.abs(p.y - box.min.y) < e) return new THREE.Vector3(0, -1, 0);
        if (Math.abs(p.y - box.max.y) < e) return new THREE.Vector3(0, 1, 0);
        if (Math.abs(p.z - box.min.z) < e) return new THREE.Vector3(0, 0, -1);
        if (Math.abs(p.z - box.max.z) < e) return new THREE.Vector3(0, 0, 1);
        return null;
      }

      // The face of the scope that refused the packet lights up as a hex field.
      function shield(p, n, box) {
        const size = box.getSize(new THREE.Vector3());
        const center = box.getCenter(new THREE.Vector3());
        let w;
        let h;
        const rot = new THREE.Euler();
        if (n.x) {
          w = size.z;
          h = size.y;
          rot.y = n.x > 0 ? Math.PI / 2 : -Math.PI / 2;
        } else if (n.z) {
          w = size.x;
          h = size.y;
          rot.y = n.z > 0 ? 0 : Math.PI;
        } else {
          w = size.x;
          h = size.z;
          rot.x = n.y > 0 ? -Math.PI / 2 : Math.PI / 2;
        }
        const mat = new THREE.ShaderMaterial({
          uniforms: {
            uSize: { value: new THREE.Vector2(w, h) },
            uHit: { value: new THREE.Vector2() },
            uT: { value: 0 },
            uColor: { value: new THREE.Color(RED) },
          },
          vertexShader: SHIELD_VERT,
          fragmentShader: SHIELD_FRAG,
          transparent: true,
          depthWrite: false,
          side: THREE.DoubleSide,
          blending: THREE.AdditiveBlending,
        });
        const geo = new THREE.PlaneGeometry(w, h);
        const m = new THREE.Mesh(geo, mat);
        m.rotation.copy(rot);
        m.position.copy(center).addScaledVector(n, Math.abs(n.x) * size.x / 2 + Math.abs(n.y) * size.y / 2 + Math.abs(n.z) * size.z / 2 + 0.004);
        m.updateMatrixWorld();
        const local = m.worldToLocal(p.clone());
        mat.uniforms.uHit.value.set(local.x, local.y);
        scene.add(m);
        effects.push({ kind: 'shield', obj: m, mat, geo, age: 0, life: 1.15 });
      }

      function denyAt(p, scope) {
        const n = faceNormal(p, scope.box);
        if (n) shield(p, n, scope.box);
        const flash = oneOffGlow(RED, 0.6, 0.8);
        flash.position.copy(p);
        scene.add(flash);
        effects.push({ kind: 'flash', obj: flash, mat: flash.material, age: 0, life: 0.5, from: 0.6, to: 1.8, peak: 0.8 });
        scope.flash = 1;
      }

      function arriveAt(p, dest) {
        const pulse = oneOffGlow(GREEN, 0.4, 0.55);
        pulse.position.copy(p);
        scene.add(pulse);
        effects.push({ kind: 'flash', obj: pulse, mat: pulse.material, age: 0, life: 0.6, from: 0.4, to: 1.6, peak: 0.5 });
        const mat = new THREE.MeshBasicMaterial({ color: GREEN, transparent: true, opacity: 0.8, side: THREE.DoubleSide, depthWrite: false, blending: THREE.AdditiveBlending });
        const ring = new THREE.Mesh(ringGeo, mat);
        ring.position.copy(p);
        scene.add(ring);
        effects.push({ kind: 'ring', obj: ring, mat, age: 0, life: 0.9 });
        if (dest) dest.pulse = 1;
      }

      function removePacket(i) {
        const p = packets[i];
        scene.remove(p.mesh, p.trail);
        mirror.remove(p.mTrail, p.mHalo);
        p.trailGeo.dispose();
        packets.splice(i, 1);
      }

      const red = new THREE.Color(RED);
      const white = new THREE.Color(WHITE);
      let spawnClock = 0;
      let scanClock = 0;
      let elapsed = 0;

      function step(dt) {
        spawnClock += dt;
        while (spawnClock > 0.36) {
          spawnClock -= 0.36;
          spawn();
        }
        for (let i = packets.length - 1; i >= 0; i--) {
          const p = packets[i];
          p.t += dt / p.dur;
          const t = Math.min(p.t, 1);
          tmp.lerpVectors(p.r.from, p.end, t);
          p.mesh.position.copy(tmp);
          // Grow in as it leaves the process, so heads do not pile up on the node.
          p.mesh.scale.setScalar(Math.min(1, 0.2 + t * 8));
          p.mHalo.position.copy(tmp);
          const arr = p.trailGeo.attributes.position.array;
          const carr = p.trailGeo.attributes.color.array;
          for (let k = 0; k < TRAIL; k++) {
            const tt = Math.max(0, t - k * 0.022);
            tmp2.lerpVectors(p.r.from, p.end, tt);
            arr[k * 3] = tmp2.x;
            arr[k * 3 + 1] = tmp2.y;
            arr[k * 3 + 2] = tmp2.z;
            // White inside the scope; green once past the check, or reddening as it nears the wall that refuses it.
            if (p.r.stop) cTmp.copy(cWhite).lerp(cRed, Math.min(1, Math.max(0, (tt - 0.35) / 0.55)));
            else cTmp.copy(tt >= p.r.cross ? cGreen : cWhite);
            const fade = Math.pow(1 - k / (TRAIL - 1), 1.6);
            carr[k * 3] = cTmp.r * fade;
            carr[k * 3 + 1] = cTmp.g * fade;
            carr[k * 3 + 2] = cTmp.b * fade;
          }
          p.trailGeo.attributes.position.needsUpdate = true;
          p.trailGeo.attributes.color.needsUpdate = true;
          const tint = p.r.stop ? (t > 0.6 ? 'red' : 'white') : t >= p.r.cross ? 'green' : 'white';
          if (tint !== p.tint) {
            p.tint = tint;
            p.mesh.material = tint === 'green' ? packetGreenMat : tint === 'red' ? packetRedMat : packetMat;
            p.halo.material = tint === 'white' ? glowMat(WHITE, 0.22) : glowMat(tint === 'green' ? GREEN : RED, 0.34);
            p.mHalo.material = tint === 'green' ? mirrorHaloGreen : tint === 'red' ? mirrorHaloRed : mirrorHaloMat;
          }
          if (p.t >= 1) {
            if (p.r.stop) denyAt(p.end, p.r.deniedBy);
            else arriveAt(p.end, destObjs.get(p.r.to));
            removePacket(i);
          }
        }
        for (let i = effects.length - 1; i >= 0; i--) {
          const f = effects[i];
          f.age += dt;
          const k = Math.min(1, f.age / f.life);
          if (f.kind === 'shield') {
            f.mat.uniforms.uT.value = k;
          } else if (f.kind === 'ring') {
            f.obj.quaternion.copy(camera.quaternion);
            f.obj.scale.setScalar(1 + k * 2.4);
            f.mat.opacity = 0.6 * (1 - k) * (1 - k);
          } else {
            f.obj.scale.setScalar(f.from + (f.to - f.from) * k);
            f.mat.opacity = f.peak * (1 - k);
          }
          if (k >= 1) {
            scene.remove(f.obj);
            f.mat.dispose();
            f.geo?.dispose();
            effects.splice(i, 1);
          }
        }
        for (const s of scopes) {
          if (s.flash > 0) s.flash = Math.max(0, s.flash - dt * 2.2);
          s.mat.color.copy(s.base).lerp(red, s.flash * 0.85);
          s.mat.opacity = s.baseOpacity + (1 - s.baseOpacity) * s.flash * 0.6;
          if (s.glassMat) s.glassMat.uniforms.uFlash.value = s.flash;
          if (s.cornerMat) s.cornerMat.color.copy(white).lerp(red, s.flash * 0.85);
        }
        for (const n of nodes) {
          n.flare = Math.max(0, n.flare - dt * 3);
          n.g.scale.setScalar(n.size * (1 + 0.12 * Math.sin(elapsed * 2.1 + n.phase) + 0.6 * n.flare));
        }
        for (const d of destObjs.values()) {
          d.pulse = Math.max(0, d.pulse - dt * 2.5);
          d.mesh.rotation.y += dt * (0.6 + d.pulse * 6);
          d.mesh.scale.setScalar(1 + d.pulse * 0.7);
          d.mirror.rotation.y = d.mesh.rotation.y;
          d.mirror.scale.copy(d.mesh.scale);
        }
        scanClock += dt;
        const sk = (scanClock % 4.5) / 4.5;
        const fade = Math.sin(Math.PI * sk);
        scan.position.y = scanEdges.position.y = 0.02 + sk * 1.96;
        scanMat.opacity = 0.04 * fade;
        scanLineMat.opacity = 0.45 * fade;
        dust.rotation.y += dt * 0.008;
      }

      // Labels projected from 3D anchors and kept inside the frame.
      const anchors = labelsEl
        ? [
            ['host', new THREE.Vector3(-5.6, 3.5, -4)],
            ['app', new THREE.Vector3(-3.7, 1.25, 2.9)],
            ['task', new THREE.Vector3(1.6, -0.18, 2.6)],
            ['toolA', new THREE.Vector3(1.0, 1.36, -1.05)],
            ['toolB', new THREE.Vector3(2.8, 1.36, 1.05)],
            ['allow', dests.registry.clone().add(new THREE.Vector3(0, 0.42, 0))],
            ['allow2', dests.github.clone().add(new THREE.Vector3(0, 0.42, 0))],
            ['deny', dests.paste.clone().add(new THREE.Vector3(0, 0.42, 0))],
            ['deny2', dests.tracker.clone().add(new THREE.Vector3(0, 0.42, 0))],
          ].map(([key, v]) => ({ el: labelsEl.querySelector(`[data-anchor="${key}"]`), v, w: 0, h: 0 }))
        : [];
      function measureLabels() {
        for (const a of anchors) {
          if (!a.el) continue;
          a.w = a.el.offsetWidth;
          a.h = a.el.offsetHeight;
        }
      }

      // The camera sways around a base angle; its distance is fitted so the host
      // and every destination stay in frame at any aspect ratio.
      const BASE = 0.72;
      const SWAY = 0.28;
      const ELEV = 0.46;
      const keyPoints = [];
      for (const sx of [-6, 6]) for (const sy of [0, 3.4]) for (const sz of [-4, 4]) keyPoints.push(new THREE.Vector3(sx, sy, sz));
      keyPoints.push(...Object.values(dests));
      let dist = 22;

      function placeAt(a, d) {
        camera.position.set(Math.sin(a) * d, d * ELEV, Math.cos(a) * d);
        camera.lookAt(target);
        camera.updateMatrixWorld();
      }
      function fits(d) {
        for (const a of [BASE - SWAY - 0.11, BASE - SWAY / 2, BASE, BASE + SWAY / 2, BASE + SWAY + 0.11]) {
          placeAt(a, d);
          for (const p of keyPoints) {
            tmp.copy(p).project(camera);
            if (Math.abs(tmp.x) > 0.93 || Math.abs(tmp.y) > 0.86) return false;
          }
        }
        return true;
      }
      function fitDistance() {
        let lo = 6;
        let hi = 140;
        for (let i = 0; i < 24; i++) {
          const mid = (lo + hi) / 2;
          if (fits(mid)) hi = mid;
          else lo = mid;
        }
        dist = hi;
        scene.fog.near = dist * 0.85;
        scene.fog.far = dist * 2.3;
      }

      let width = 1;
      let height = 1;
      function resize() {
        const r = wrap.getBoundingClientRect();
        width = Math.max(1, r.width);
        height = Math.max(1, r.height);
        renderer.setSize(width, height, false);
        composer?.setSize(width, height);
        camera.aspect = width / height;
        camera.updateProjectionMatrix();
        fitDistance();
        measureLabels();
      }
      document.fonts?.ready.then(() => {
        if (!disposed) measureLabels();
      });

      // The camera leans toward the pointer, eased.
      let pointerX = 0;
      let pointerY = 0;
      let px = 0;
      let py = 0;
      function onPointer(e) {
        const r = wrap.getBoundingClientRect();
        pointerX = ((e.clientX - r.left) / r.width - 0.5) * 2;
        pointerY = ((e.clientY - r.top) / r.height - 0.5) * 2;
      }
      function onLeave() {
        pointerX = 0;
        pointerY = 0;
      }
      if (!reduced) {
        wrap.addEventListener('pointermove', onPointer);
        wrap.addEventListener('pointerleave', onLeave);
      }

      let intro = reduced ? 1 : 0;
      function placeCamera() {
        const e = 1 - Math.pow(1 - intro, 3);
        const a = BASE + Math.sin(elapsed * 0.12) * SWAY + px * 0.1 - (1 - e) * 0.55;
        placeAt(a, dist * (1 + 0.45 * (1 - e)));
        camera.position.y -= py * 0.7;
        camera.lookAt(target);
      }

      function render() {
        placeCamera();
        if (composer) composer.render();
        else renderer.render(scene, camera);
        for (const a of anchors) {
          if (!a.el) continue;
          tmp.copy(a.v).project(camera);
          const sx = (tmp.x * 0.5 + 0.5) * width;
          const sy = (-tmp.y * 0.5 + 0.5) * height;
          const x = Math.min(Math.max(sx - a.w / 2, 6), Math.max(6, width - a.w - 6));
          const y = Math.min(Math.max(sy - a.h / 2, 6), Math.max(6, height - a.h - 6));
          a.el.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`;
          a.el.style.opacity = tmp.z < 1 ? String(Math.min(1, intro * 1.5)) : '0';
        }
      }

      const ro = new ResizeObserver(() => {
        resize();
        if (reduced) render();
      });
      ro.observe(wrap);
      resize();

      let raf = 0;
      let last = 0;
      let visible = true;
      function frame(now) {
        raf = 0;
        const dt = last ? Math.min(0.05, (now - last) / 1000) : 0.016;
        last = now;
        elapsed += dt;
        intro = Math.min(1, intro + dt / 1.8);
        const ease = Math.min(1, dt * 3);
        px += (pointerX - px) * ease;
        py += (pointerY - py) * ease;
        step(dt);
        render();
        if (visible && !document.hidden) raf = requestAnimationFrame(frame);
      }
      function start() {
        if (reduced || raf) return;
        last = 0;
        raf = requestAnimationFrame(frame);
      }
      function stop() {
        if (raf) cancelAnimationFrame(raf);
        raf = 0;
      }

      const io = new IntersectionObserver(([entry]) => {
        visible = entry.isIntersecting;
        visible ? start() : stop();
      });
      io.observe(wrap);
      const onVis = () => (document.hidden ? stop() : start());
      document.addEventListener('visibilitychange', onVis);

      if (reduced) {
        for (let i = 0; i < 120; i++) step(1 / 30);
        render();
      } else {
        for (let i = 0; i < 40; i++) step(1 / 30);
        start();
      }

      cleanup = () => {
        stop();
        io.disconnect();
        ro.disconnect();
        document.removeEventListener('visibilitychange', onVis);
        wrap.removeEventListener('pointermove', onPointer);
        wrap.removeEventListener('pointerleave', onLeave);
        while (packets.length) removePacket(packets.length - 1);
        for (const f of effects) {
          f.mat.dispose();
          f.geo?.dispose();
        }
        for (const d of disposables) d.dispose?.();
        composer?.dispose();
        renderer.dispose();
        renderer.domElement.remove();
      };
    })();

    return () => {
      disposed = true;
      cleanup();
    };
  }, []);

  return (
    <div
      className="scene"
      ref={wrapRef}
      role="img"
      aria-label="Illustration: a host ceiling holds two app scopes and one task scope with two nested tool scopes, npm install and git fetch. Allowed connections turn green as they leave their scope and reach registry.npmjs.org and api.github.com; denied connections turn red and stop at the boundary of the scope that denies them."
    >
      {mode === 'fallback' ? <SceneFallback /> : null}
      <div className="scene-labels" ref={labelsRef} aria-hidden="true">
        <span data-anchor="host" className="tag">host ceiling</span>
        <span data-anchor="app" className="tag tag-app">app scope</span>
        <span data-anchor="task" className="tag tag-strong">task scope</span>
        <span data-anchor="toolA" className="tag tag-tool tag-minor">npm install</span>
        <span data-anchor="toolB" className="tag tag-tool tag-minor">git fetch</span>
        <span data-anchor="allow" className="tag tag-allow">registry.npmjs.org</span>
        <span data-anchor="allow2" className="tag tag-allow tag-minor">api.github.com</span>
        <span data-anchor="deny" className="tag tag-deny">paste.example</span>
        <span data-anchor="deny2" className="tag tag-deny tag-minor">tracker.example</span>
      </div>
    </div>
  );
}

function SceneFallback() {
  return (
    <svg className="scene-fallback" viewBox="0 0 640 360" aria-hidden="true">
      <rect x="40" y="70" width="560" height="250" rx="10" fill="none" stroke="#3a3a3a" />
      <text x="56" y="94" fill="#8f8f8f" fontSize="12" fontFamily="var(--mono)">host</text>
      <rect x="70" y="120" width="140" height="70" rx="6" fill="none" stroke="#8f8f8f" strokeDasharray="6 5" />
      <rect x="70" y="220" width="140" height="70" rx="6" fill="none" stroke="#8f8f8f" strokeDasharray="6 5" />
      <text x="82" y="140" fill="#8f8f8f" fontSize="11" fontFamily="var(--mono)">app scope</text>
      <rect x="290" y="110" width="270" height="190" rx="8" fill="rgba(255,255,255,0.02)" stroke="#ededed" />
      <text x="304" y="132" fill="#ededed" fontSize="12" fontFamily="var(--mono)">task scope</text>
      <rect x="315" y="160" width="100" height="100" rx="6" fill="rgba(255,255,255,0.03)" stroke="#8f8f8f" />
      <rect x="440" y="180" width="100" height="100" rx="6" fill="rgba(255,255,255,0.03)" stroke="#8f8f8f" />
      <line x1="365" y1="210" x2="610" y2="30" stroke="#ededed" strokeWidth="1.5" />
      <text x="520" y="24" fill="#ededed" fontSize="12" fontFamily="var(--mono)">allowed</text>
      <line x1="490" y1="230" x2="540" y2="200" stroke="#ededed" strokeWidth="1.5" />
      <circle cx="540" cy="200" r="7" fill="none" stroke="#e5484d" strokeWidth="2" />
      <text x="552" y="196" fill="#e5484d" fontSize="12" fontFamily="var(--mono)">denied</text>
    </svg>
  );
}
