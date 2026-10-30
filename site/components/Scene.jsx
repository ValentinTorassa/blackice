'use client';

import { useEffect, useRef, useState } from 'react';

// Illustration only: simulated traffic, not product output.
const WHITE = 0xffffff;
const RED = 0xe5484d;
const GRAY = 0x6f6f6f;

export default function Scene() {
  const wrapRef = useRef(null);
  const labelsRef = useRef(null);
  const [mode, setMode] = useState('loading'); // loading | webgl | fallback

  useEffect(() => {
    let disposed = false;
    let cleanup = () => {};

    (async () => {
      const THREE = await import('three');
      if (disposed || !wrapRef.current) return;

      let renderer;
      try {
        renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'low-power' });
      } catch {
        setMode('fallback');
        return;
      }
      setMode('webgl');

      const wrap = wrapRef.current;
      const labelsEl = labelsRef.current;
      const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

      renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
      renderer.setClearColor(0x000000, 0);
      renderer.domElement.className = 'scene-canvas';
      renderer.domElement.setAttribute('aria-hidden', 'true');
      wrap.prepend(renderer.domElement);

      const scene = new THREE.Scene();
      scene.fog = new THREE.Fog(0x000000, 20, 60);
      const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 200);
      const target = new THREE.Vector3(0, 1.9, -0.3);
      const tmp = new THREE.Vector3();
      const look = new THREE.Vector3();

      const disposables = [];
      const track = (x) => (disposables.push(x), x);

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

      // Ground.
      const grid = new THREE.GridHelper(24, 48, 0x1c1c1c, 0x0f0f0f);
      grid.material.transparent = true;
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
        const mat = track(new THREE.PointsMaterial({ color: 0x8a8a8a, size: 0.05, transparent: true, opacity: 0.55, depthWrite: false }));
        const points = new THREE.Points(geo, mat);
        scene.add(points);
        return points;
      })();

      // Scopes.
      const scopes = [];
      function addScope({ size, pos, color, opacity, dashed, fill }) {
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
        if (fill) {
          const m = new THREE.Mesh(geo, track(new THREE.MeshBasicMaterial({ color, transparent: true, opacity: fill, depthWrite: false })));
          m.position.copy(line.position);
          scene.add(m);
        }
        const box = new THREE.Box3(
          new THREE.Vector3(pos[0] - w / 2, pos[1] - h / 2, pos[2] - d / 2),
          new THREE.Vector3(pos[0] + w / 2, pos[1] + h / 2, pos[2] + d / 2),
        );
        const scope = { line, mat, box, base: new THREE.Color(color), baseOpacity: opacity, flash: 0 };
        scopes.push(scope);
        return scope;
      }

      addScope({ size: [12, 3.4, 8], pos: [0, 1.7, 0], color: WHITE, opacity: 0.16, fill: 0.008 });
      const appA = addScope({ size: [2.4, 1.0, 1.8], pos: [-3.7, 0.5, 2.0], color: GRAY, opacity: 0.8, dashed: true });
      const appB = addScope({ size: [2.4, 1.0, 1.8], pos: [-3.7, 0.5, -1.7], color: GRAY, opacity: 0.8, dashed: true });
      addScope({ size: [4.4, 2.0, 4.6], pos: [1.9, 1.0, 0], color: WHITE, opacity: 0.85, fill: 0.02 });
      // Light pooled on the floor under the task scope.
      const pool = new THREE.Mesh(
        track(new THREE.PlaneGeometry(7.5, 7.5)),
        track(new THREE.MeshBasicMaterial({ map: glowTex, color: WHITE, transparent: true, opacity: 0.16, blending: THREE.AdditiveBlending, depthWrite: false })),
      );
      pool.rotation.x = -Math.PI / 2;
      pool.position.set(1.9, 0.004, 0);
      scene.add(pool);
      const toolA = addScope({ size: [1.5, 1.1, 1.5], pos: [1.0, 0.56, -1.05], color: WHITE, opacity: 0.5, fill: 0.03 });
      const toolB = addScope({ size: [1.5, 1.1, 1.5], pos: [2.8, 0.56, 1.05], color: WHITE, opacity: 0.5, fill: 0.03 });

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

      // Processes.
      const nodeGeo = track(new THREE.SphereGeometry(0.07, 16, 16));
      const nodeMat = track(new THREE.MeshBasicMaterial({ color: WHITE }));
      const appNodeMat = track(new THREE.MeshBasicMaterial({ color: 0x8a8a8a }));
      function node(scope, mat, glowOpacity) {
        const c = new THREE.Vector3();
        scope.box.getCenter(c);
        const m = new THREE.Mesh(nodeGeo, mat);
        m.position.copy(c);
        scene.add(m);
        const g = glow(WHITE, 0.9, glowOpacity);
        g.position.copy(c);
        scene.add(g);
        return c;
      }
      const nToolA = node(toolA, nodeMat, 0.55);
      const nToolB = node(toolB, nodeMat, 0.55);
      const nAppA = node(appA, appNodeMat, 0.2);
      const nAppB = node(appB, appNodeMat, 0.2);

      // Destinations outside the host ceiling, each on a stem down to the ground.
      const dests = {
        registry: new THREE.Vector3(7.3, 4.3, -2.7),
        github: new THREE.Vector3(6.5, 4.9, 3.0),
        paste: new THREE.Vector3(-0.8, 5.2, -5.5),
        tracker: new THREE.Vector3(-7.3, 4.0, 2.6),
      };
      const destGeo = track(new THREE.OctahedronGeometry(0.16, 0));
      const destAllowMat = track(new THREE.MeshBasicMaterial({ color: WHITE, wireframe: true }));
      const destDenyMat = track(new THREE.MeshBasicMaterial({ color: 0x5a5a5a, wireframe: true }));
      const stemMat = track(new THREE.LineDashedMaterial({ color: 0x2c2c2c, dashSize: 0.1, gapSize: 0.12 }));
      const groundRingGeo = track(new THREE.RingGeometry(0.2, 0.235, 40));
      const groundRingMat = track(new THREE.MeshBasicMaterial({ color: 0x3a3a3a, side: THREE.DoubleSide }));
      const destMeshes = [];
      for (const [k, v] of Object.entries(dests)) {
        const denied = k === 'paste' || k === 'tracker';
        const m = new THREE.Mesh(destGeo, denied ? destDenyMat : destAllowMat);
        m.position.copy(v);
        scene.add(m);
        destMeshes.push(m);
        const g = glow(WHITE, denied ? 0.7 : 1.2, denied ? 0.1 : 0.35);
        g.position.copy(v);
        scene.add(g);
        const stem = new THREE.Line(track(new THREE.BufferGeometry().setFromPoints([v, new THREE.Vector3(v.x, 0, v.z)])), stemMat);
        stem.computeLineDistances();
        scene.add(stem);
        const ring = new THREE.Mesh(groundRingGeo, groundRingMat);
        ring.rotation.x = -Math.PI / 2;
        ring.position.set(v.x, 0.01, v.z);
        scene.add(ring);
      }

      // Faint guides for allowed routes.
      const guideMat = track(new THREE.LineDashedMaterial({ color: 0x2a2a2a, dashSize: 0.12, gapSize: 0.14 }));
      for (const [a, b] of [[nToolA, dests.registry], [nToolB, dests.github], [nAppA, dests.github]]) {
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
      const routes = [
        { from: nToolA, to: dests.registry, weight: 3 },
        { from: nToolB, to: dests.github, weight: 3 },
        { from: nToolB, to: dests.paste, deniedBy: toolB, weight: 2 },
        { from: nToolA, to: dests.paste, deniedBy: toolA, weight: 1 },
        { from: nAppA, to: dests.github, weight: 2 },
        { from: nAppB, to: dests.tracker, deniedBy: appB, weight: 1.5 },
      ].map((r) => ({ ...r, stop: r.deniedBy ? exitPoint(r.from, r.to, r.deniedBy) : null }));
      const totalWeight = routes.reduce((s, r) => s + r.weight, 0);
      function pickRoute() {
        let x = Math.random() * totalWeight;
        for (const r of routes) if ((x -= r.weight) <= 0) return r;
        return routes[0];
      }

      const packetGeo = track(new THREE.SphereGeometry(0.05, 12, 12));
      const hexGeo = track(new THREE.RingGeometry(0.1, 0.13, 6));
      const packets = [];
      const effects = [];

      function spawn() {
        const r = pickRoute();
        const end = r.stop || r.to;
        const mat = new THREE.MeshBasicMaterial({ color: WHITE, transparent: true, opacity: 1 });
        const mesh = new THREE.Mesh(packetGeo, mat);
        mesh.add(glow(WHITE, 0.55, 0.75));
        const trailGeo = new THREE.BufferGeometry().setFromPoints([r.from.clone(), r.from.clone()]);
        const trailMat = new THREE.LineBasicMaterial({ color: WHITE, transparent: true, opacity: r.stop ? 0.35 : 0.6 });
        const trail = new THREE.Line(trailGeo, trailMat);
        scene.add(mesh, trail);
        packets.push({ r, end, t: 0, dur: Math.max(0.6, r.from.distanceTo(end) / 4.2), mesh, mat, trail, trailGeo, trailMat });
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

      function denyAt(p, scope) {
        const mat = new THREE.MeshBasicMaterial({ color: RED, transparent: true, opacity: 0.95, side: THREE.DoubleSide, depthWrite: false });
        const hex = new THREE.Mesh(hexGeo, mat);
        hex.position.copy(p);
        const n = faceNormal(p, scope.box);
        if (n) hex.lookAt(look.copy(p).add(n));
        scene.add(hex);
        effects.push({ kind: 'ripple', obj: hex, mat, aligned: !!n, age: 0, life: 0.9 });
        const flash = oneOffGlow(RED, 0.6, 0.9);
        flash.position.copy(p);
        scene.add(flash);
        effects.push({ kind: 'flash', obj: flash, mat: flash.material, age: 0, life: 0.5, from: 0.6, to: 1.8, peak: 0.9 });
        scope.flash = 1;
      }

      function arriveAt(p) {
        const pulse = oneOffGlow(WHITE, 0.4, 0.8);
        pulse.position.copy(p);
        scene.add(pulse);
        effects.push({ kind: 'flash', obj: pulse, mat: pulse.material, age: 0, life: 0.6, from: 0.4, to: 2.0, peak: 0.8 });
      }

      function removePacket(i) {
        const p = packets[i];
        scene.remove(p.mesh, p.trail);
        p.mat.dispose();
        p.trailGeo.dispose();
        p.trailMat.dispose();
        packets.splice(i, 1);
      }

      const tail = new THREE.Vector3();
      const red = new THREE.Color(RED);
      let spawnClock = 0;
      let scanClock = 0;

      function step(dt) {
        spawnClock += dt;
        while (spawnClock > 0.32) {
          spawnClock -= 0.32;
          spawn();
        }
        for (let i = packets.length - 1; i >= 0; i--) {
          const p = packets[i];
          p.t += dt / p.dur;
          const t = Math.min(p.t, 1);
          tmp.lerpVectors(p.r.from, p.end, t);
          tail.lerpVectors(p.r.from, p.end, Math.max(0, t - 0.22));
          p.mesh.position.copy(tmp);
          const pos = p.trailGeo.attributes.position;
          pos.setXYZ(0, tail.x, tail.y, tail.z);
          pos.setXYZ(1, tmp.x, tmp.y, tmp.z);
          pos.needsUpdate = true;
          if (p.t >= 1) {
            if (p.r.stop) denyAt(p.end, p.r.deniedBy);
            else arriveAt(p.end);
            removePacket(i);
          }
        }
        for (let i = effects.length - 1; i >= 0; i--) {
          const f = effects[i];
          f.age += dt;
          const k = Math.min(1, f.age / f.life);
          if (f.kind === 'ripple') {
            f.obj.scale.setScalar(1 + k * 6);
            f.mat.opacity = 0.95 * (1 - k);
            if (!f.aligned) f.obj.quaternion.copy(camera.quaternion);
          } else {
            f.obj.scale.setScalar(f.from + (f.to - f.from) * k);
            f.mat.opacity = f.peak * (1 - k);
          }
          if (k >= 1) {
            scene.remove(f.obj);
            f.mat.dispose();
            effects.splice(i, 1);
          }
        }
        for (const s of scopes) {
          if (s.flash > 0) s.flash = Math.max(0, s.flash - dt * 2.2);
          s.mat.color.copy(s.base).lerp(red, s.flash * 0.85);
          s.mat.opacity = s.baseOpacity + (1 - s.baseOpacity) * s.flash * 0.6;
        }
        scanClock += dt;
        const sk = (scanClock % 4.5) / 4.5;
        const fade = Math.sin(Math.PI * sk);
        scan.position.y = scanEdges.position.y = 0.02 + sk * 1.96;
        scanMat.opacity = 0.045 * fade;
        scanLineMat.opacity = 0.4 * fade;
        for (const m of destMeshes) m.rotation.y += dt * 0.6;
        dust.rotation.y += dt * 0.008;
      }

      // Labels projected from 3D anchors and kept inside the frame.
      const anchors = labelsEl
        ? [
            ['host', new THREE.Vector3(-5.6, 3.5, -4)],
            ['app', new THREE.Vector3(-3.7, 1.15, 2.9)],
            ['task', new THREE.Vector3(1.6, -0.15, 2.6)],
            ['allow', dests.registry.clone().add(new THREE.Vector3(0, 0.38, 0))],
            ['deny', dests.paste.clone().add(new THREE.Vector3(0, 0.38, 0))],
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
        for (const a of [BASE - SWAY - 0.07, BASE - SWAY / 2, BASE, BASE + SWAY / 2, BASE + SWAY + 0.07]) {
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
        camera.aspect = width / height;
        camera.updateProjectionMatrix();
        fitDistance();
        measureLabels();
      }
      document.fonts?.ready.then(() => {
        if (!disposed) measureLabels();
      });

      let pointerX = 0;
      let pointerY = 0;
      function onPointer(e) {
        const r = wrap.getBoundingClientRect();
        pointerX = ((e.clientX - r.left) / r.width - 0.5) * 2;
        pointerY = ((e.clientY - r.top) / r.height - 0.5) * 2;
      }
      if (!reduced) wrap.addEventListener('pointermove', onPointer);

      let elapsed = 0;
      let intro = reduced ? 1 : 0;
      function placeCamera() {
        const e = 1 - Math.pow(1 - intro, 3);
        const a = BASE + Math.sin(elapsed * 0.12) * SWAY + pointerX * 0.06 - (1 - e) * 0.55;
        placeAt(a, dist * (1 + 0.45 * (1 - e)));
        camera.position.y -= pointerY * 0.5;
        camera.lookAt(target);
      }

      function render() {
        placeCamera();
        renderer.render(scene, camera);
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
        while (packets.length) removePacket(packets.length - 1);
        for (const f of effects) f.mat.dispose();
        for (const d of disposables) d.dispose?.();
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
      aria-label="Illustration: a host policy plane holds two app scopes and one task scope with two nested tool scopes. Allowed connections leave the host toward registry and API destinations; a denied connection stops at the boundary of the scope that denies it."
    >
      {mode === 'fallback' ? <SceneFallback /> : null}
      <div className="scene-labels" ref={labelsRef} aria-hidden="true">
        <span data-anchor="host" className="tag">host</span>
        <span data-anchor="app" className="tag">app scope</span>
        <span data-anchor="task" className="tag tag-strong">task scope</span>
        <span data-anchor="allow" className="tag tag-strong">registry.npmjs.org</span>
        <span data-anchor="deny" className="tag tag-deny">paste.example</span>
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
