/* Ensemble onboarding tour: shared 3D scene module.
 * Needs three.js r128 globals (THREE, THREE.GLTFLoader, THREE.CCDIKSolver).
 * Hand model: WebXR generic hand (MIT), loaded from opts.handUrl (default 'assets/hand.glb').
 *
 *   window.EnsembleScene.mount(el, { scene, reducedMotion, onFrame, handUrl }) -> { setScene, destroy }
 *   window.EnsembleScene._seek(name, t)   debug: freeze a frame on the last mounted instance
 */
(function () {
  'use strict';

  var ACCENT = 0x5aa0ff;
  var LINE = 0x8ea6c8;      // outline colour for the desk objects
  var LINE_DIM = 0x42536f;
  var BG_TOP = new THREE.Color(0x04070c);
  var BG_HORIZON = new THREE.Color(0x14233b);
  var WOOD_FILL = new THREE.Color(0xc98a4b);
  var WOOD_RIM = new THREE.Color(0xffd29a);

  var DURATIONS = { welcome: 8, look: 8, calibrate: 12, dictate: 6.4, send: 5.2, scroll: 5.6 };
  var STATIC_T = { welcome: 0.8, look: 0.8, calibrate: 3.0, dictate: 0.66, send: 1.5, scroll: 2.3 };
  var HAND_SCENES = { dictate: 1, send: 1, scroll: 1 };

  function clamp(x, a, b) { return Math.max(a, Math.min(b, x)); }
  function smooth(x) { x = clamp(x, 0, 1); return x * x * (3 - 2 * x); }
  function lerp(a, b, k) { return a + (b - a) * k; }
  var D2R = Math.PI / 180;
  var HAND_SCALE = 12.5;   // scene units per metre of rig hand

  // ------------------------------------------------------------------
  // Stage: sky gradient, fading grid floor
  // ------------------------------------------------------------------
  function buildStage(scene, disposables) {
    var skyMat = new THREE.ShaderMaterial({
      side: THREE.BackSide, depthWrite: false, fog: false,
      uniforms: { uTop: { value: BG_TOP }, uHor: { value: BG_HORIZON } },
      vertexShader: 'varying vec3 vP; void main(){ vP = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }',
      fragmentShader: [
        'uniform vec3 uTop; uniform vec3 uHor; varying vec3 vP;',
        'void main(){',
        '  float y = normalize(vP).y;',
        '  vec3 c = mix(uHor, uTop, smoothstep(0.0, 0.42, y));',
        '  c = mix(c, uTop * 0.9, smoothstep(0.0, -0.25, y));',
        '  gl_FragColor = vec4(c, 1.0);',
        '}'
      ].join('\n')
    });
    var sky = new THREE.Mesh(new THREE.SphereGeometry(300, 24, 16), skyMat);
    sky.renderOrder = -10;
    scene.add(sky);
    disposables.push(skyMat, sky.geometry);

    var gridMat = new THREE.ShaderMaterial({
      transparent: true, depthWrite: false,
      uniforms: {
        uCam: { value: new THREE.Vector3() },
        uCol: { value: new THREE.Color(0x5b7fb3) },
        uMajor: { value: new THREE.Color(0x8fb2e6) }
      },
      extensions: { derivatives: true },
      vertexShader: 'varying vec3 vW; void main(){ vec4 w = modelMatrix * vec4(position,1.0); vW = w.xyz; gl_Position = projectionMatrix * viewMatrix * w; }',
      fragmentShader: [
        'uniform vec3 uCam; uniform vec3 uCol; uniform vec3 uMajor; varying vec3 vW;',
        'float grid(vec2 p, float s){ vec2 q = p / s; vec2 g = abs(fract(q - 0.5) - 0.5) / max(fwidth(q), vec2(1e-4)); return 1.0 - min(min(g.x, g.y), 1.0); }',
        'void main(){',
        '  float d = length(vW.xz - uCam.xz);',
        '  float fade = 1.0 - smoothstep(8.0, 85.0, d);',
        '  float minor = grid(vW.xz, 1.0);',
        '  float major = grid(vW.xz, 5.0);',
        '  float a = (minor * 0.34 + major * 0.55) * fade;',
        '  vec3 c = mix(uCol, uMajor, major);',
        '  gl_FragColor = vec4(c, a);',
        '}'
      ].join('\n')
    });
    var floor = new THREE.Mesh(new THREE.PlaneGeometry(600, 600), gridMat);
    floor.rotation.x = -Math.PI / 2;
    floor.renderOrder = -5;
    scene.add(floor);
    disposables.push(gridMat, floor.geometry);
    return { gridMat: gridMat };
  }

  // ------------------------------------------------------------------
  // Outlined-fill material: translucent body, crisp fresnel rim.
  // Works for plain and skinned meshes.
  // ------------------------------------------------------------------
  function rimMaterial(fill, rim, opacity, skinned, edge) {
    var vsHead = skinned
      ? '#include <common>\n#include <skinning_pars_vertex>\n'
      : '';
    var vsBody = skinned
      ? [
        '#include <skinbase_vertex>',
        '#include <beginnormal_vertex>',
        '#include <skinnormal_vertex>',
        '#include <begin_vertex>',
        '#include <skinning_vertex>'
      ].join('\n')
      : 'vec3 objectNormal = normal; vec3 transformed = position;';
    return new THREE.ShaderMaterial({
      skinning: !!skinned,
      transparent: true, depthWrite: false, side: THREE.FrontSide,
      uniforms: {
        uFill: { value: fill.clone() }, uRim: { value: rim.clone() },
        uOp: { value: opacity }, uEdge: { value: edge || 0.52 }, uGrain: { value: 0.0 }, uFadeLen: { value: 0.0 }
      },
      vertexShader: vsHead + [
        'varying vec3 vN; varying vec3 vV; varying vec3 vP;',
        'void main(){',
        vsBody,
        '  vP = position;',
        '  vec4 mv = modelViewMatrix * vec4(transformed, 1.0);',
        '  vN = normalize(normalMatrix * objectNormal);',
        '  vV = -mv.xyz;',
        '  gl_Position = projectionMatrix * mv;',
        '}'
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uFill; uniform vec3 uRim; uniform float uOp; uniform float uEdge; uniform float uGrain; uniform float uFadeLen;',
        'varying vec3 vN; varying vec3 vV; varying vec3 vP;',
        'void main(){',
        '  vec3 n = normalize(vN); vec3 v = normalize(vV);',
        '  float f = 1.0 - abs(dot(n, v));',
        '  float rim = smoothstep(uEdge, uEdge + 0.07, f);',
        '  float glow = smoothstep(0.15, 0.9, f) * 0.35;',
        '  float lit = 0.62 + 0.38 * clamp(dot(n, normalize(vec3(0.35, 0.65, 0.7))), 0.0, 1.0);',
        '  float gr = sin(vP.z * 330.0 + sin(vP.y * 70.0) * 1.6 + sin(vP.x * 110.0 + vP.y * 30.0) * 1.1);',
        '  float grain = smoothstep(0.35, 1.0, gr) * uGrain;',
        '  vec3 c = uFill * lit * (1.0 - 0.28 * grain) + uRim * glow;',
        '  c = mix(c, uRim, rim);',
        '  float a = clamp(uOp + glow * 0.25, 0.0, 1.0);',
        '  a = mix(a, 0.96, rim);',
        '  if (uFadeLen > 0.0) a *= 1.0 - smoothstep(0.0, uFadeLen, vP.y);',
        '  gl_FragColor = vec4(c, a);',
        '}'
      ].join('\n')
    });
  }

  function lineMat(color, opacity) {
    return new THREE.LineBasicMaterial({ color: color, transparent: opacity < 1, opacity: opacity === undefined ? 1 : opacity });
  }

  function circlePts(r, n, plane) {
    var pts = [];
    for (var i = 0; i <= n; i++) {
      var a = (i / n) * Math.PI * 2, c = Math.cos(a) * r, s = Math.sin(a) * r;
      pts.push(plane === 'xz' ? new THREE.Vector3(c, 0, s) : plane === 'yz' ? new THREE.Vector3(0, c, s) : new THREE.Vector3(c, s, 0));
    }
    return pts;
  }

  // flat frame (rect outline with real thickness) in the XY plane
  function frameGeometry(w, h, t) {
    var s = new THREE.Shape();
    s.moveTo(-w / 2, -h / 2); s.lineTo(w / 2, -h / 2); s.lineTo(w / 2, h / 2); s.lineTo(-w / 2, h / 2); s.lineTo(-w / 2, -h / 2);
    var hole = new THREE.Path();
    hole.moveTo(-w / 2 + t, -h / 2 + t); hole.lineTo(-w / 2 + t, h / 2 - t); hole.lineTo(w / 2 - t, h / 2 - t); hole.lineTo(w / 2 - t, -h / 2 + t); hole.lineTo(-w / 2 + t, -h / 2 + t);
    s.holes.push(hole);
    return new THREE.ShapeGeometry(s);
  }

  // ------------------------------------------------------------------
  // Desk: head, two monitors, four session panes
  // ------------------------------------------------------------------
  function buildDesk(scene, disposables) {
    var root = new THREE.Group();
    scene.add(root);
    function track(o) { disposables.push(o); return o; }

    var HEAD_POS = new THREE.Vector3(0.1, 1.6, 0.7);

    // --- head ---
    var neck = new THREE.Group();
    neck.position.copy(HEAD_POS);
    root.add(neck);
    var rig = new THREE.Group();   // yaw / pitch
    rig.rotation.order = 'YXZ';
    rig.scale.setScalar(1.22);
    neck.add(rig);

    var skullGeo = track(new THREE.SphereGeometry(0.42, 40, 28));
    var skullMat = track(rimMaterial(new THREE.Color(0x1b2638), new THREE.Color(0xa9c2e6), 0.5, false, 0.72));
    var skull = new THREE.Mesh(skullGeo, skullMat);
    skull.scale.set(0.9, 1.1, 1.0);
    rig.add(skull);

    var lm = track(lineMat(0x7f9cc4, 0.55));
    [-0.3, 0.0, 0.3].forEach(function (yy) {
      var rr = Math.sqrt(1 - Math.pow(yy / 0.462, 2)) * 0.42;
      var g = track(new THREE.BufferGeometry().setFromPoints(circlePts(rr, 48, 'xz')));
      var l = new THREE.Line(g, lm);
      l.scale.set(0.9, 1, 1.0);
      l.position.y = yy;
      rig.add(l);
    });
    var mer = track(new THREE.BufferGeometry().setFromPoints(circlePts(0.42, 56, 'yz')));
    var merL = new THREE.Line(mer, lm); merL.scale.set(1, 1.1, 1.0); rig.add(merL);

    var noseMat = track(rimMaterial(new THREE.Color(0x24334d), new THREE.Color(0xd3e3ff), 0.85, false, 0.45));
    var noseGeo = track(new THREE.ConeGeometry(0.1, 0.28, 4));
    var nose = new THREE.Mesh(noseGeo, noseMat);
    nose.rotation.x = -Math.PI / 2 - 0.12;   // tip toward -z
    nose.position.set(0, -0.03, -0.52);
    rig.add(nose);

    var earGeo = track(new THREE.SphereGeometry(0.1, 14, 10));
    [-1, 1].forEach(function (sx) {
      var ear = new THREE.Mesh(earGeo, noseMat);
      ear.scale.set(0.35, 1.0, 0.7);
      ear.position.set(sx * 0.4, -0.02, 0.03);
      rig.add(ear);
    });
    // brow marker so facing reads even at a distance
    var browGeo = track(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(-0.2, 0.1, -0.4), new THREE.Vector3(-0.1, 0.14, -0.42), new THREE.Vector3(0.1, 0.14, -0.42), new THREE.Vector3(0.2, 0.1, -0.4)]));
    rig.add(new THREE.Line(browGeo, track(lineMat(0xbcd2f0, 0.9))));

    var gazeMat = track(new THREE.LineBasicMaterial({ color: ACCENT, transparent: true, opacity: 0.55 }));
    var gaze = new THREE.Line(track(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0, 0, -0.62), new THREE.Vector3(0, 0, -2.4)])), gazeMat);
    rig.add(gaze);
    // neck + shoulders (static)
    var lineM = track(lineMat(LINE, 0.9));
    var neckPts = [];
    [-1, 1].forEach(function (sx) { neckPts.push(new THREE.Vector3(sx * 0.17, -0.42, 0.03), new THREE.Vector3(sx * 0.2, -0.78, 0.05)); });
    neck.add(new THREE.LineSegments(track(new THREE.BufferGeometry().setFromPoints(neckPts)), lineM));
    var sh = new THREE.Line(track(new THREE.BufferGeometry().setFromPoints(circlePts(0.62, 48, 'xz'))), lineM);
    sh.scale.set(1.0, 1, 0.55); sh.position.set(0, -0.78, 0.05); neck.add(sh);

    // --- monitors ---
    var floorY = 0;
    function makeMonitor(w, h, pos, yaw) {
      var g = new THREE.Group();
      g.position.copy(pos);
      g.rotation.y = yaw;
      root.add(g);
      var boxGeo = track(new THREE.BoxGeometry(w + 0.1, h + 0.1, 0.07));
      var body = new THREE.Mesh(boxGeo, track(new THREE.MeshBasicMaterial({ color: 0x0a1018, transparent: true, opacity: 0.92 })));
      g.add(body);
      var edges = new THREE.LineSegments(track(new THREE.EdgesGeometry(boxGeo)), track(lineMat(LINE, 1)));
      g.add(edges);
      var screen = new THREE.Mesh(track(new THREE.PlaneGeometry(w, h)), track(new THREE.MeshBasicMaterial({ color: 0x0f1a2b })));
      screen.position.z = 0.037;
      g.add(screen);
      var sf = new THREE.Mesh(track(frameGeometry(w, h, 0.012)), track(new THREE.MeshBasicMaterial({ color: LINE_DIM })));
      sf.position.z = 0.04;
      g.add(sf);
      // stand: pole to the floor and a base
      var yc = pos.y;
      var stand = [new THREE.Vector3(0, -h / 2 - 0.05, -0.06), new THREE.Vector3(0, -yc + 0.02, -0.12),
      new THREE.Vector3(-0.045, -h / 2 - 0.05, -0.06), new THREE.Vector3(-0.045, -yc + 0.02, -0.12),
      new THREE.Vector3(0.045, -h / 2 - 0.05, -0.06), new THREE.Vector3(0.045, -yc + 0.02, -0.12)];
      g.add(new THREE.LineSegments(track(new THREE.BufferGeometry().setFromPoints(stand)), track(lineMat(LINE_DIM, 1))));
      var bw = Math.min(w, 0.9) * 0.45;
      var base = [new THREE.Vector3(-bw, -yc + 0.02, -0.4), new THREE.Vector3(bw, -yc + 0.02, -0.4), new THREE.Vector3(bw, -yc + 0.02, 0.1), new THREE.Vector3(-bw, -yc + 0.02, 0.1), new THREE.Vector3(-bw, -yc + 0.02, -0.4)];
      g.add(new THREE.Line(track(new THREE.BufferGeometry().setFromPoints(base)), track(lineMat(LINE_DIM, 1))));
      g.updateMatrixWorld(true);
      return { group: g, w: w, h: h };
    }
    var MAIN_W = 2.7, MAIN_H = 1.52;
    var main = makeMonitor(MAIN_W, MAIN_H, new THREE.Vector3(0.45, 1.58, -2.3), 0);
    var PORT_W = 1.08, PORT_H = 1.92;
    var port = makeMonitor(PORT_W, PORT_H, new THREE.Vector3(-1.95, 1.63, -1.85), 30 * D2R);

    // --- panes ---
    var panes = [];
    function makePane(mon, cx, cy, w, h) {
      var g = new THREE.Group();
      g.position.set(cx, cy, 0.045);
      mon.group.add(g);
      var dimFrame = new THREE.Mesh(track(frameGeometry(w, h, 0.012)), track(new THREE.MeshBasicMaterial({ color: 0x3a4b66, transparent: true, opacity: 1 })));
      g.add(dimFrame);
      var hiFrame = new THREE.Mesh(track(frameGeometry(w + 0.012, h + 0.012, 0.03)), track(new THREE.MeshBasicMaterial({ color: ACCENT, transparent: true, opacity: 0 })));
      hiFrame.position.z = 0.004;
      g.add(hiFrame);
      var hiFill = new THREE.Mesh(track(new THREE.PlaneGeometry(w, h)), track(new THREE.MeshBasicMaterial({ color: ACCENT, transparent: true, opacity: 0, depthWrite: false })));
      hiFill.position.z = -0.002;
      g.add(hiFill);
      // title bar + text lines
      var pts = [];
      var top = h / 2 - 0.09;
      pts.push(new THREE.Vector3(-w / 2 + 0.05, top, 0), new THREE.Vector3(-w / 2 + 0.05 + w * 0.32, top, 0));
      var rows = Math.floor((h - 0.3) / 0.11);
      for (var i = 0; i < rows; i++) {
        var yy = top - 0.14 - i * 0.11;
        var len = (0.35 + 0.55 * ((i * 37 % 7) / 7)) * (w - 0.14);
        pts.push(new THREE.Vector3(-w / 2 + 0.07, yy, 0), new THREE.Vector3(-w / 2 + 0.07 + len, yy, 0));
      }
      var textMat = track(lineMat(0x5d7394, 0.85));
      g.add(new THREE.LineSegments(track(new THREE.BufferGeometry().setFromPoints(pts)), textMat));
      return { group: g, dimFrame: dimFrame, hiFrame: hiFrame, hiFill: hiFill, textMat: textMat, hl: 0 };
    }
    var pm = 0.04;
    var pw = (MAIN_W - pm * 3) / 2, ph = MAIN_H - pm * 2;
    panes.push(makePane(main, -MAIN_W / 2 + pm + pw / 2, 0, pw, ph));            // 0: main left
    panes.push(makePane(main, MAIN_W / 2 - pm - pw / 2, 0, pw, ph));             // 1: main right
    var qw = PORT_W - pm * 2, qh = (PORT_H - pm * 3) / 2;
    panes.push(makePane(port, 0, PORT_H / 2 - pm - qh / 2, qw, qh));             // 2: portrait top
    panes.push(makePane(port, 0, -PORT_H / 2 + pm + qh / 2, qw, qh));            // 3: portrait bottom
    root.updateMatrixWorld(true);

    function paneCentre(i) { return panes[i].group.getWorldPosition(new THREE.Vector3()); }

    // Calibration points exactly as the app places them: centre, left, right, top, bottom,
    // each inset 8% of the screen width / height from its edge. u, v: -1..1 across the inset area.
    var CAL_INSET = 0.08;
    function screenLocal(mon, u, v) {
      return new THREE.Vector3(u * (mon.w / 2 - CAL_INSET * mon.w), v * (mon.h / 2 - CAL_INSET * mon.h), 0.07);
    }
    function screenPoint(mon, u, v) { return mon.group.localToWorld(screenLocal(mon, u, v)); }

    // one marker per point, parented to its monitor so it lies flat on the glass
    var CAL_S = 0.72;   // marker scale: ring outer radius ~0.16, close to the 8% inset on both screens
    var calDots = [];
    function makeCalDot(mon, u, v) {
      var g = new THREE.Group();
      g.position.copy(screenLocal(mon, u, v));
      g.scale.setScalar(CAL_S);
      g.visible = false;
      mon.group.add(g);
      var disc = new THREE.Mesh(track(new THREE.CircleGeometry(0.095, 28)), track(new THREE.MeshBasicMaterial({ color: ACCENT, transparent: true, opacity: 0.3, depthWrite: false })));
      g.add(disc);
      var base = new THREE.Mesh(track(new THREE.RingGeometry(0.19, 0.205, 64)), track(new THREE.MeshBasicMaterial({ color: ACCENT, transparent: true, opacity: 0.1, depthWrite: false })));
      g.add(base);
      var fillGeo = track(new THREE.RingGeometry(0.175, 0.225, 64, 1, 0, Math.PI * 2));
      var fill = new THREE.Mesh(fillGeo, track(new THREE.MeshBasicMaterial({ color: 0xbfe0ff, transparent: true, opacity: 1, depthWrite: false })));
      fill.position.z = 0.002;
      g.add(fill);
      fillGeo.setDrawRange(0, 0);
      return { group: g, disc: disc, base: base, fill: fill, fillGeo: fillGeo };
    }
    // state: 0 dim (waiting), 1 active (prog 0..1 fills the ring), 2 done
    function setCalDot(d, state, prog, pulse) {
      if (state === 1) {
        d.disc.material.opacity = 1; d.disc.material.color.setHex(ACCENT);
        d.base.material.opacity = 0.34;
        d.fill.visible = true;
        d.fillGeo.setDrawRange(0, Math.max(0, Math.round(prog * 64)) * 6);
        d.disc.scale.setScalar(pulse);
      } else {
        d.disc.material.opacity = state === 2 ? 0.6 : 0.3;
        d.disc.material.color.setHex(ACCENT);
        d.base.material.opacity = state === 2 ? 0.3 : 0.14;
        d.fill.visible = false;
        d.disc.scale.setScalar(1);
      }
    }

    function aimHead(target, k) {
      var d = target.clone().sub(HEAD_POS);
      var yaw = Math.atan2(-d.x, -d.z);
      var pitch = Math.atan2(d.y, Math.sqrt(d.x * d.x + d.z * d.z));
      return { yaw: yaw, pitch: pitch * (k === undefined ? 0.8 : k) };
    }

    var HEAD_ORDER = [
      { t: 0.0, p: 1 }, { t: 1.4, p: 1 }, { t: 2.0, p: 0 }, { t: 3.4, p: 0 },
      { t: 4.0, p: 2 }, { t: 5.4, p: 2 }, { t: 6.0, p: 3 }, { t: 7.4, p: 3 }, { t: 8.0, p: 1 }
    ];
    var aimCache = null;
    function paneAims() {
      if (!aimCache) aimCache = [0, 1, 2, 3].map(function (i) { return aimHead(paneCentre(i)); });
      return aimCache;
    }
    function setPaneHighlights(vals, dim) {
      for (var i = 0; i < 4; i++) {
        var p = panes[i], v = vals[i];
        p.hiFrame.material.opacity = v;
        p.hiFill.material.opacity = 0.13 * v;
        p.dimFrame.material.opacity = 1 - 0.85 * v;
        p.textMat.opacity = (dim ? 0.35 : 0.55) + 0.4 * v;
        p.textMat.color.setHex(v > 0.5 ? 0x8fbcff : 0x5d7394);
      }
    }

    function lookAt(t) {
      var aims = paneAims();
      var a = null;
      for (var i = 0; i < HEAD_ORDER.length - 1; i++) {
        var A = HEAD_ORDER[i], B = HEAD_ORDER[i + 1];
        if (t >= A.t && t <= B.t) { a = { A: A, B: B, k: B.t > A.t ? smooth((t - A.t) / (B.t - A.t)) : 1 }; break; }
      }
      if (!a) a = { A: HEAD_ORDER[0], B: HEAD_ORDER[0], k: 0 };
      var from = aims[a.A.p], to = aims[a.B.p];
      var hl = [0, 0, 0, 0];
      if (a.A.p === a.B.p) hl[a.A.p] = 1;
      else {
        hl[a.A.p] = 1 - smooth(clamp((a.k - 0.25) / 0.5, 0, 1));
        hl[a.B.p] = smooth(clamp((a.k - 0.4) / 0.5, 0, 1));
      }
      // subtle settle wobble while holding
      var wob = Math.sin(t * 2.3) * 0.012;
      return { yaw: lerp(from.yaw, to.yaw, a.k) + wob, pitch: lerp(from.pitch, to.pitch, a.k), hl: hl };
    }

    var CAL = [];
    var CAL_ORDER = [[0, 0], [-1, 0], [1, 0], [0, 1], [0, -1]];   // centre, left, right, top, bottom
    [main, port].forEach(function (mon) {   // main screen first, then the portrait screen to its left
      CAL_ORDER.forEach(function (uv) { CAL.push({ mon: mon, u: uv[0], v: uv[1] }); });
    });
    CAL.forEach(function (c) { calDots.push(makeCalDot(c.mon, c.u, c.v)); });
    root.updateMatrixWorld(true);
    var calPos = null;
    function calPoints() {
      if (!calPos) calPos = CAL.map(function (c) { return { p: screenPoint(c.mon, c.u, c.v) }; });
      return calPos;
    }

    function update(name, t) {
      var st = { dot: -1, progress: 0 };
      var isCal = name === 'calibrate';
      calDots.forEach(function (d) { d.group.visible = isCal; });
      panes.forEach(function (p) { p.group.visible = !isCal; });   // calibration shows the points only, no sessions
      if (isCal) {
        var pts = calPoints();
        var slot = DURATIONS.calibrate / pts.length;   // 1.2 s
        var idx = clamp(Math.floor(t / slot), 0, pts.length - 1);
        var lt = t - idx * slot;
        var prev = pts[(idx + pts.length - 1) % pts.length];
        var cur = pts[idx];
        var mv = smooth(lt / 0.34);
        var pos = idx === 0 && t < slot ? cur.p.clone() : prev.p.clone().lerp(cur.p, mv);
        var prog = clamp((lt - 0.36) / 0.62, 0, 1);
        var pulse = prog >= 1 ? 1 + 0.18 * Math.sin((lt - 0.98) * 18) * clamp((1.15 - lt) * 6, 0, 1) : 1;
        for (var ci = 0; ci < calDots.length; ci++) {
          setCalDot(calDots[ci], ci === idx ? 1 : ci < idx ? 2 : 0, ci === idx ? prog : 0, ci === idx ? pulse : 1);
        }
        var aim = aimHead(pos.clone(), 0.9);
        rig.rotation.y = aim.yaw; rig.rotation.x = aim.pitch;
        setPaneHighlights([0, 0, 0, 0], true);
        st.dot = idx; st.progress = prog;
      } else {
        var r = lookAt(t % 8);
        rig.rotation.y = r.yaw; rig.rotation.x = r.pitch;
        setPaneHighlights(r.hl, false);
      }
      return st;
    }

    return { root: root, update: update };
  }

  // ------------------------------------------------------------------
  // Gesture stage: one monitor, flat to the viewer, lit by a drawn Claude desktop session
  // ------------------------------------------------------------------
  var SCR = { W: 8.6, H: 4.8375, cx: 1.2, cy: 3.35, z: -9.0 };
  var DRAFT_TEXT = 'Log each retry with its attempt number.';
  var SANS = '-apple-system, "SF Pro Text", "Segoe UI", system-ui, Helvetica, Arial, sans-serif';
  var MONO = 'ui-monospace, "SF Mono", Menlo, Consolas, monospace';
  var C = {
    bg: '#1f1e1d', side: '#181716', pane: '#262624', line: '#3a3935', text: '#eeece6', dim: '#a09e96', faint: '#6f6d66',
    bubble: '#3a3935', code: '#171716', orange: '#d97757', blue: '#5aa0ff'
  };

  function makeScreen() {
    var W = 1280, H = 720, S = 1.5;
    var cv = document.createElement('canvas');
    cv.width = W * S; cv.height = H * S;
    var ctx = cv.getContext('2d');
    var tex = new THREE.CanvasTexture(cv);
    tex.minFilter = THREE.LinearFilter; tex.magFilter = THREE.LinearFilter; tex.generateMipmaps = false;

    function rr(x, y, w, h, r) {
      ctx.beginPath();
      ctx.moveTo(x + r, y); ctx.lineTo(x + w - r, y); ctx.arcTo(x + w, y, x + w, y + r, r);
      ctx.lineTo(x + w, y + h - r); ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
      ctx.lineTo(x + r, y + h); ctx.arcTo(x, y + h, x, y + h - r, r);
      ctx.lineTo(x, y + r); ctx.arcTo(x, y, x + r, y, r); ctx.closePath();
    }
    function wrap(text, maxW, font) {
      ctx.font = font;
      var words = text.split(' '), lines = [], cur = '';
      words.forEach(function (w) {
        var tryL = cur ? cur + ' ' + w : w;
        if (ctx.measureText(tryL).width > maxW && cur) { lines.push(cur); cur = w; } else cur = tryL;
      });
      if (cur) lines.push(cur);
      return lines;
    }
    var F = '21px ' + SANS, LH = 31;
    var CODE = [
      ['async function', ' drain', '(q: Queue) {'],
      ['  for', ' (let n = 0; n < 5; n++) {', ''],
      ['    try', ' { return await q.flush(); }', ''],
      ['    catch', ' { await sleep(2 ** n * 100); }', ''],
      ['  }', '', ''],
      ['}', '', '']
    ];
    var X0 = 296, X1 = 1236;   // conversation column

    // returns [{kind,h,draw(y)}]
    function userBubble(text) {
      var lines = wrap(text, 520, F), w = 0;
      lines.forEach(function (l) { w = Math.max(w, ctx.measureText(l).width); });
      var bw = w + 40, bh = lines.length * LH + 26;
      return { h: bh, draw: function (y, a) {
        ctx.globalAlpha = a === undefined ? 1 : a;
        ctx.fillStyle = C.bubble; rr(X1 - bw, y, bw, bh, 18); ctx.fill();
        ctx.fillStyle = C.text; ctx.font = F; ctx.textBaseline = 'alphabetic';
        lines.forEach(function (l, i) { ctx.fillText(l, X1 - bw + 20, y + 13 + 22 + i * LH - 3); });
        ctx.globalAlpha = 1;
      } };
    }
    function asst(text) {
      var lines = wrap(text, 880, F);
      return { h: lines.length * LH + 4, draw: function (y) {
        ctx.fillStyle = C.orange; ctx.font = '600 24px ' + SANS; ctx.fillText('✻', X0 - 30, y + 22);
        ctx.fillStyle = C.text; ctx.font = F;
        lines.forEach(function (l, i) { ctx.fillText(l, X0, y + 22 + i * LH); });
      } };
    }
    function tool(label, arg) {
      return { h: 44, draw: function (y) {
        ctx.fillStyle = '#2d2c2a'; rr(X0, y, 430, 40, 10); ctx.fill();
        ctx.strokeStyle = C.line; ctx.lineWidth = 1; ctx.stroke();
        ctx.fillStyle = C.dim; ctx.font = '600 17px ' + SANS; ctx.fillText(label, X0 + 16, y + 26);
        ctx.fillStyle = C.text; ctx.font = '17px ' + MONO; ctx.fillText(arg, X0 + 16 + ctx.measureText(label).width + 22, y + 26);
      } };
    }
    function code() {
      var h = CODE.length * 27 + 44;
      return { h: h, draw: function (y) {
        ctx.fillStyle = C.code; rr(X0, y, 760, h, 14); ctx.fill();
        ctx.strokeStyle = C.line; ctx.lineWidth = 1; ctx.stroke();
        ctx.fillStyle = C.faint; ctx.font = '600 14px ' + SANS; ctx.fillText('sync.ts', X0 + 20, y + 26);
        ctx.font = '18px ' + MONO;
        CODE.forEach(function (ln, i) {
          var x = X0 + 20, yy = y + 56 + i * 27;
          ctx.fillStyle = '#e8a47e'; ctx.fillText(ln[0], x, yy); x += ctx.measureText(ln[0]).width;
          ctx.fillStyle = ln[1].indexOf(' drain') === 0 ? '#8ec0ff' : '#d9d7cf'; ctx.fillText(ln[1], x, yy); x += ctx.measureText(ln[1]).width;
          ctx.fillStyle = '#d9d7cf'; ctx.fillText(ln[2], x, yy);
        });
      } };
    }
    var shortList = [
      userBubble('The sync job drops events when the queue is full. Can you add retries with backoff?'),
      asst('On it. I read the worker and wrapped the flush call in a retry loop.'),
      code(),
      asst('Done: up to 5 attempts, waiting 100 ms and doubling each time. The sync tests still pass.')
    ];
    var longList = shortList.concat([
      userBubble('Log each retry with its attempt number.'),
      asst('Added a debug line in the catch block. It prints the attempt and the wait.'),
      tool('Edit', 'src/worker/sync.ts   +3 −1'),
      asst('All 14 tests pass. Want a metric for the final failure as well?')
    ]);
    var newBubble = userBubble(DRAFT_TEXT);
    var GAP = 24;
    function total(list) { var h = 0; list.forEach(function (m) { h += m.h + GAP; }); return h - GAP; }

    var CONV_T = 116, CONV_B = 584;

    function capsule(st, t) {
      var mode = 'ready';
      if (st.gesture === 'dictate') mode = st.listening ? 'listen' : 'ready';
      else if (st.gesture === 'send') mode = st.sent ? 'sent' : (st.hold > 0 ? 'hold' : 'ready');
      else if (st.gesture === 'scroll') mode = st.scroll > 0.02 ? 'scroll' : 'ready';
      var label = { ready: 'Ready', listen: 'Listening', hold: 'Hold to send', sent: 'Sent', scroll: 'Scrolling' }[mode];
      var w = { ready: 150, listen: 252, hold: 300, sent: 150, scroll: 190 }[mode], h = 42, x = 640 - w / 2, y = 4;
      ctx.fillStyle = '#000'; rr(x, y, w, h, 21); ctx.fill();
      ctx.strokeStyle = 'rgba(255,255,255,0.16)'; ctx.lineWidth = 1.2; ctx.stroke();
      var dot = { ready: '#6f6d66', listen: C.orange, hold: C.blue, sent: '#58c27d', scroll: C.blue }[mode];
      ctx.fillStyle = dot; ctx.beginPath(); ctx.arc(x + 25, y + h / 2, 6, 0, 6.2832); ctx.fill();
      if (mode === 'listen') { ctx.fillStyle = dot; ctx.globalAlpha = 0.25; ctx.beginPath(); ctx.arc(x + 25, y + h / 2, 6 + 4 * (0.5 + 0.5 * Math.sin(t * 7)), 0, 6.2832); ctx.fill(); ctx.globalAlpha = 1; }
      ctx.fillStyle = '#fff'; ctx.font = '600 19px ' + SANS; ctx.textBaseline = 'alphabetic';
      ctx.fillText(label, x + 44, y + h / 2 + 7);
      if (mode === 'listen') {
        for (var i = 0; i < 6; i++) {
          var a = 0.5 + 0.5 * Math.sin(t * 9 + i * 1.7) * Math.sin(t * 4.3 + i * 0.9);
          var bh = 6 + 18 * Math.abs(a);
          ctx.fillStyle = C.orange; rr(x + 156 + i * 14, y + h / 2 - bh / 2, 7, bh, 3.5); ctx.fill();
        }
      } else if (mode === 'hold') {
        var bx = x + 168, bw = 112;
        ctx.fillStyle = 'rgba(255,255,255,0.16)'; rr(bx, y + h / 2 - 4, bw, 8, 4); ctx.fill();
        ctx.fillStyle = C.blue; rr(bx, y + h / 2 - 4, Math.max(8, bw * st.hold), 8, 4); ctx.fill();
      } else if (mode === 'sent') {
        ctx.strokeStyle = dot; ctx.lineWidth = 0;
      }
    }

    function draw(st, name, t) {
      var ev = eventsFor(name);
      ctx.setTransform(S, 0, 0, S, 0, 0);
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = C.bg; ctx.fillRect(0, 0, W, H);
      // menu bar
      ctx.fillStyle = '#121110'; ctx.fillRect(0, 0, W, 30);
      ctx.fillStyle = C.dim; ctx.font = '600 15px ' + SANS; ctx.fillText('Claude', 22, 21);
      ctx.font = '15px ' + SANS; ctx.fillStyle = C.faint;
      ['File', 'Edit', 'View', 'Window', 'Help'].forEach(function (m, i) { ctx.fillText(m, 100 + i * 62, 21); });
      ctx.textAlign = 'right'; ctx.fillText('Tue 9:41', W - 22, 21); ctx.textAlign = 'left';
      // sidebar
      ctx.fillStyle = C.side; ctx.fillRect(0, 30, 232, H - 30);
      [['#ff5f57', 0], ['#febc2e', 1], ['#28c840', 2]].forEach(function (d) { ctx.fillStyle = d[0]; ctx.beginPath(); ctx.arc(24 + d[1] * 22, 56, 6, 0, 6.2832); ctx.fill(); });
      ctx.fillStyle = C.text; ctx.font = '600 18px ' + SANS; ctx.fillText('Code', 22, 106);
      ctx.fillStyle = C.faint; ctx.font = '600 13px ' + SANS; ctx.fillText('SESSIONS', 22, 146);
      var sess = [['ensemble-tour', 1], ['billing-fix', 0], ['docs-cleanup', 0], ['eval-harness', 0]];
      sess.forEach(function (s, i) {
        var y = 160 + i * 52;
        if (s[1]) { ctx.fillStyle = '#2b2a28'; rr(10, y, 212, 44, 10); ctx.fill(); }
        ctx.fillStyle = s[1] ? C.orange : '#4b4a45'; ctx.beginPath(); ctx.arc(30, y + 22, 5, 0, 6.2832); ctx.fill();
        ctx.fillStyle = s[1] ? C.text : C.dim; ctx.font = '17px ' + SANS; ctx.fillText(s[0], 46, y + 28);
      });
      // main pane
      var PX = 246, PY = 42, PW = W - PX - 10, PH = H - PY - 10;
      ctx.fillStyle = C.pane; rr(PX, PY, PW, PH, 16); ctx.fill();
      // header
      ctx.fillStyle = C.text; ctx.font = '600 21px ' + SANS; ctx.fillText('ensemble-tour', PX + 30, PY + 46);
      ctx.fillStyle = '#34332f'; rr(PX + 190, PY + 26, 192, 32, 16); ctx.fill();
      ctx.fillStyle = C.dim; ctx.font = '15px ' + MONO; ctx.fillText('feature/onboarding', PX + 206, PY + 48);
      ctx.fillStyle = C.faint; ctx.font = '16px ' + SANS; ctx.textAlign = 'right'; ctx.fillText('Local  ·  Opus', PX + PW - 28, PY + 46); ctx.textAlign = 'left';
      ctx.strokeStyle = C.line; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(PX, PY + 74); ctx.lineTo(PX + PW, PY + 74); ctx.stroke();

      // conversation (clipped)
      ctx.save();
      ctx.beginPath(); ctx.rect(PX + 4, CONV_T - 8, PW - 8, CONV_B - CONV_T + 8); ctx.clip();
      var list, y0;
      var sendK = 0, sendA = 0, push = 0;
      if (name === 'scroll') {
        list = longList;
        var maxS = Math.max(0, total(list) - (CONV_B - CONV_T));
        y0 = CONV_T - Math.min(maxS, 250) * st.scroll;
      } else {
        list = shortList;
        var showNew = name === 'send' && t >= ev.sentAt;
        if (showNew) {
          sendK = sstep((t - ev.sentAt) / 0.55);
          push = sendK * (newBubble.h + GAP) * (1 - sstep((t - ev.pushOff) / 0.5));
        }
        y0 = CONV_B - total(list) - push;
        if (name === 'send' && showNew) sendA = 1;
      }
      var y = y0;
      list.forEach(function (m) { m.draw(y); y += m.h + GAP; });
      if (name === 'send' && sendA) {
        // the draft travels up from the message box to the end of the conversation
        var finalY = CONV_B - newBubble.h;
        var startY = 640 - newBubble.h / 2;
        var yy = startY + (finalY - startY) * sendK;
        var fade = t > ev.fadeAt ? 1 - sstep((t - ev.fadeAt) / 0.4) : 1;
        ctx.restore(); ctx.save();
        ctx.beginPath(); ctx.rect(PX + 4, CONV_T - 8, PW - 8, 700); ctx.clip();
        newBubble.draw(yy, fade);
      }
      ctx.restore();

      // composer
      var CX0 = PX + 30, CY0 = 596, CW = PW - 60, CH = 100;
      ctx.fillStyle = '#30302d'; rr(CX0, CY0, CW, CH, 18); ctx.fill();
      ctx.strokeStyle = '#4a4944'; ctx.lineWidth = 1.5; ctx.stroke();
      var text = '', caret = false, textA = 1;
      if (name === 'dictate') {
        var words = DRAFT_TEXT.split(' '), n = Math.round(st.draft * words.length);
        text = words.slice(0, n).join(' ');
        // words clear at the loop end so the cycle restarts empty
        if (t > ev.clearAt) text = '';
        caret = st.listening && Math.floor(t * 2.4) % 2 === 0;
      } else if (name === 'send') {
        if (t < ev.sentAt || t > ev.textBack) text = DRAFT_TEXT;
        if (t > ev.textBack) textA = sstep((t - ev.textBack) / 0.35);
      }
      ctx.font = F; ctx.textBaseline = 'alphabetic';
      if (text) {
        ctx.globalAlpha = textA; ctx.fillStyle = C.text; ctx.fillText(text, CX0 + 26, CY0 + 44); ctx.globalAlpha = 1;
        if (caret) { var cw = ctx.measureText(text).width; ctx.fillStyle = C.orange; ctx.fillRect(CX0 + 28 + cw, CY0 + 24, 2.5, 26); }
      } else {
        if (caret) { ctx.fillStyle = C.orange; ctx.fillRect(CX0 + 28, CY0 + 24, 2.5, 26); }
        ctx.fillStyle = C.faint; ctx.fillText(caret || st.listening ? '' : 'Reply to Claude…', CX0 + 26, CY0 + 44);
      }
      ctx.fillStyle = C.faint; ctx.font = '16px ' + SANS; ctx.fillText('Plan mode   ·   Opus   ·   Auto-accept off', CX0 + 26, CY0 + 82);
      var sendOn = !!text;
      ctx.fillStyle = sendOn ? C.orange : '#4a4944'; ctx.beginPath(); ctx.arc(CX0 + CW - 38, CY0 + CH / 2, 21, 0, 6.2832); ctx.fill();
      ctx.strokeStyle = '#1f1e1d'; ctx.lineWidth = 3; ctx.lineCap = 'round'; ctx.beginPath();
      ctx.moveTo(CX0 + CW - 38, CY0 + CH / 2 + 8); ctx.lineTo(CX0 + CW - 38, CY0 + CH / 2 - 8);
      ctx.moveTo(CX0 + CW - 46, CY0 + CH / 2 - 1); ctx.lineTo(CX0 + CW - 38, CY0 + CH / 2 - 9); ctx.lineTo(CX0 + CW - 30, CY0 + CH / 2 - 1); ctx.stroke();

      // Ensemble focus: blue outline only, never filled
      ctx.strokeStyle = C.blue; ctx.lineWidth = 4; rr(PX - 2, PY - 2, PW + 4, PH + 4, 18); ctx.stroke();
      capsule(st, t);
      tex.needsUpdate = true;
    }
    return { tex: tex, draw: draw, canvas: cv };
  }

  function buildGestureStage(scene, disposables) {
    var g = new THREE.Group();
    scene.add(g);
    function track(o) { disposables.push(o); return o; }
    var w = SCR.W, h = SCR.H;
    var mon = new THREE.Group();
    mon.position.set(SCR.cx, SCR.cy, SCR.z);
    g.add(mon);
    var boxGeo = track(new THREE.BoxGeometry(w + 0.34, h + 0.34, 0.2));
    mon.add(new THREE.Mesh(boxGeo, track(new THREE.MeshBasicMaterial({ color: 0x0a1018 }))));
    mon.add(new THREE.LineSegments(track(new THREE.EdgesGeometry(boxGeo)), track(lineMat(0x9db5d8, 1))));
    var screen = makeScreen();
    var sm = new THREE.Mesh(track(new THREE.PlaneGeometry(w, h)), track(new THREE.MeshBasicMaterial({ map: screen.tex })));
    sm.position.z = 0.102;
    mon.add(sm);
    disposables.push(screen.tex);
    var sf = new THREE.Mesh(track(frameGeometry(w + 0.03, h + 0.03, 0.03)), track(new THREE.MeshBasicMaterial({ color: 0x5c7298 })));
    sf.position.z = 0.104; mon.add(sf);
    // stand and base, floor level
    var yb = -SCR.cy + 0.02;
    var stand = [];
    [-0.12, 0, 0.12].forEach(function (dx) { stand.push(new THREE.Vector3(dx, -h / 2 - 0.17, -0.12), new THREE.Vector3(dx, yb, -0.3)); });
    mon.add(new THREE.LineSegments(track(new THREE.BufferGeometry().setFromPoints(stand)), track(lineMat(0x6f84a6, 1))));
    g.visible = false;
    return { group: g, screen: screen };
  }

  // ------------------------------------------------------------------
  // Hand: rigged WebXR generic hand, FK curls + CCD IK for the pinch
  // ------------------------------------------------------------------
  var FINGERS = ['index-finger', 'middle-finger', 'ring-finger', 'pinky-finger'];
  var FKEY = ['index', 'middle', 'ring', 'pinky'];
  var SEGS = ['metacarpal', 'phalanx-proximal', 'phalanx-intermediate', 'phalanx-distal', 'tip'];

  function boneName(finger, i) {
    if (finger === 'thumb') return ['thumb-metacarpal', 'thumb-phalanx-proximal', 'thumb-phalanx-distal', 'thumb-tip'][i];
    return finger + '-' + SEGS[i];
  }

  function orthoBasisQuat(f, pn) {
    // armature: x = back of hand (-pn), y = -finger direction, z = lateral (pinky side)
    var F = f.clone().normalize();
    var P = pn.clone().sub(F.clone().multiplyScalar(pn.dot(F))).normalize();
    var X = P.clone().negate(), Y = F.clone().negate(), Z = new THREE.Vector3().crossVectors(X, Y);
    var m = new THREE.Matrix4().makeBasis(X, Y, Z);
    return new THREE.Quaternion().setFromRotationMatrix(m);
  }

  function buildHand(scene, gltf, disposables) {
    var model = gltf.scene;
    model.updateMatrixWorld(true);
    var bones = {}, skinned = null;
    model.traverse(function (o) {
      if (o.isBone) bones[o.name] = o;
      if (o.isSkinnedMesh) skinned = o;
    });
    var armature = skinned.parent;
    var W = {}, P = {};
    Object.keys(bones).forEach(function (n) {
      W[n] = bones[n].getWorldQuaternion(new THREE.Quaternion());
      P[n] = bones[n].getWorldPosition(new THREE.Vector3());
    });
    // The glTF hands ship a flat bone list. Rebuild the finger hierarchy so rotations propagate.
    var wrist = bones['wrist'];
    var chains = {};
    ['thumb'].concat(FINGERS).forEach(function (f) {
      var n = f === 'thumb' ? 4 : 5, list = [];
      for (var i = 0; i < n; i++) list.push(bones[boneName(f, i)]);
      chains[f] = list;
    });
    Object.keys(chains).forEach(function (f) {
      var list = chains[f];
      for (var i = 0; i < list.length; i++) {
        var parent = i === 0 ? wrist : list[i - 1];
        parent.attach(list[i]);
      }
    });

    // IK targets: dummy bones glued to the index tip, added to the skeleton so CCDIKSolver can read them
    var oldSk = skinned.skeleton;
    var allBones = oldSk.bones.slice();
    var inv = oldSk.boneInverses.map(function (m) { return m.clone(); });
    var targetBone = new THREE.Bone();
    targetBone.name = 'pinch-target';
    chains['index-finger'][4].add(targetBone);
    allBones.push(targetBone); inv.push(new THREE.Matrix4());
    var sk = new THREE.Skeleton(allBones, inv);
    skinned.bind(sk, skinned.bindMatrix);
    var idxOf = {};
    allBones.forEach(function (b, i) { idxOf[b.name] = i; });

    // tune the target so the thumb pad lands on the index pad (rest-frame offset, expressed in tip-local space)
    var tipW = W['index-finger-tip'];
    var palmN = new THREE.Vector3(-1, 0, 0), radial = new THREE.Vector3(0, 0, -1);
    var off = palmN.clone().multiplyScalar(0.0105).add(radial.clone().multiplyScalar(0.0046));
    targetBone.position.copy(off.applyQuaternion(tipW.clone().invert()));

    var solver = new THREE.CCDIKSolver(skinned, [{
      target: idxOf['pinch-target'],
      effector: idxOf['thumb-tip'],
      links: [
        { index: idxOf['thumb-phalanx-distal'] },
        { index: idxOf['thumb-phalanx-proximal'] },
        { index: idxOf['thumb-metacarpal'] }
      ],
      iteration: 1
    }]);

    // materials: translucent wood with a clean rim, plus joint rings
    var fillMat = rimMaterial(WOOD_FILL, WOOD_RIM, 0.46, true, 0.84);
    fillMat.uniforms.uGrain.value = 1.0;
    fillMat.stencilWrite = true; fillMat.stencilRef = 1; fillMat.stencilFunc = THREE.AlwaysStencilFunc; fillMat.stencilZPass = THREE.ReplaceStencilOp;
    skinned.material = fillMat;
    skinned.frustumCulled = false;
    skinned.renderOrder = 2;
    var hullMesh = null;
    disposables.push(fillMat);

    // stencil-free outer hull: back faces pushed out along the normal, drawn behind the fill
    var hullMat = new THREE.ShaderMaterial({
      skinning: true, side: THREE.BackSide, transparent: true, depthWrite: false,
      uniforms: { uCol: { value: WOOD_RIM.clone() }, uW: { value: 0.0014 } },
      stencilWrite: true, stencilRef: 1, stencilFunc: THREE.NotEqualStencilFunc, stencilFail: THREE.KeepStencilOp, stencilZFail: THREE.KeepStencilOp, stencilZPass: THREE.KeepStencilOp,
      vertexShader: '#include <common>\n#include <skinning_pars_vertex>\nuniform float uW;\nvoid main(){\n#include <skinbase_vertex>\n#include <beginnormal_vertex>\n#include <skinnormal_vertex>\n#include <begin_vertex>\n#include <skinning_vertex>\n transformed += normalize(objectNormal) * uW;\n gl_Position = projectionMatrix * modelViewMatrix * vec4(transformed,1.0);\n}',
      fragmentShader: 'uniform vec3 uCol; void main(){ gl_FragColor = vec4(uCol, 1.0); }'
    });
    disposables.push(hullMat);
    hullMesh = new THREE.SkinnedMesh(skinned.geometry, hullMat);
    hullMesh.frustumCulled = false;
    hullMesh.renderOrder = 3;
    armature.add(hullMesh);
    hullMesh.bind(sk, skinned.bindMatrix);

    var jointMat = new THREE.LineBasicMaterial({ color: 0xffe2b8, transparent: true, opacity: 0.8 });
    var boneMat = new THREE.LineBasicMaterial({ color: 0xffc98a, transparent: true, opacity: 0.55 });
    disposables.push(jointMat, boneMat);
    var radii = { thumb: 0.0085, 'index-finger': 0.0075, 'middle-finger': 0.0078, 'ring-finger': 0.0072, 'pinky-finger': 0.0062 };
    Object.keys(chains).forEach(function (f) {
      var list = chains[f];
      for (var i = 0; i < list.length - 1; i++) {
        var b = list[i], c = list[i + 1];
        var dir = c.position.clone();
        var len = dir.length();
        dir.normalize();
        var u = Math.abs(dir.x) < 0.9 ? new THREE.Vector3(1, 0, 0) : new THREE.Vector3(0, 1, 0);
        var a1 = new THREE.Vector3().crossVectors(dir, u).normalize();
        var a2 = new THREE.Vector3().crossVectors(dir, a1).normalize();
        if (i > 0) {   // ring at the joint
          var pts = [], rr = radii[f] * (1 - i * 0.06);
          for (var k = 0; k <= 28; k++) {
            var ang = (k / 28) * Math.PI * 2;
            pts.push(a1.clone().multiplyScalar(Math.cos(ang) * rr).add(a2.clone().multiplyScalar(Math.sin(ang) * rr)));
          }
          var g = new THREE.BufferGeometry().setFromPoints(pts);
          disposables.push(g);
          var ring = new THREE.Line(g, jointMat);
          b.add(ring);
        }
        var bg = new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0, 0, 0), c.position.clone()]);
        disposables.push(bg);
        b.add(new THREE.Line(bg, boneMat));
      }
    });

    // short forearm so the wrist is not cut off flat
    var mc = chains['middle-finger'][0].position.clone();   // wrist -> middle metacarpal, in wrist space
    var fdir = mc.clone().normalize().negate();
    var armGeo = new THREE.CylinderGeometry(0.046, 0.031, 0.42, 24, 1, true);
    armGeo.translate(0, 0.21, 0);
    var armMat = rimMaterial(WOOD_FILL, WOOD_RIM, 0.3, false, 0.8);
    armMat.uniforms.uGrain.value = 1.0; armMat.uniforms.uFadeLen.value = 0.42;
    var arm = new THREE.Mesh(armGeo, armMat);
    arm.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), fdir);
    arm.position.copy(fdir.clone().multiplyScalar(0.004));
    arm.renderOrder = 1;
    wrist.add(arm);
    disposables.push(armGeo, armMat);

    // hierarchy for posing
    var wristQ = W['wrist'];
    var pivot = new THREE.Group();
    pivot.add(model);
    model.position.copy(P['wrist']).negate();
    var scale = HAND_SCALE;
    pivot.scale.setScalar(scale);
    scene.add(pivot);

    var hand = {
      pivot: pivot, model: model, bones: bones, chains: chains, W: W, P: P, solver: solver,
      skinned: skinned, scale: scale, tmp: new THREE.Quaternion()
    };
    // pre-computed thumb swing for the thumbs-up
    var d0 = P['thumb-tip'].clone().sub(P['thumb-metacarpal']).normalize();
    hand.limits = [58 * D2R, 62 * D2R, 75 * D2R];
    hand.thumbDir0 = d0;
    hand.thumbUpDir = new THREE.Vector3(0.12, -0.34, -0.93).normalize();
    hand.qSwing = new THREE.Quaternion().setFromUnitVectors(d0, hand.thumbUpDir);

    // --- data for retargeting recorded motion ---
    // rest local rotation and child direction of every chained bone
    hand.restLocal = {}; hand.childDir = {};
    Object.keys(chains).forEach(function (f) {
      var list = chains[f];
      for (var i = 0; i < list.length; i++) {
        var pq = i === 0 ? W['wrist'] : W[list[i - 1].name];
        hand.restLocal[list[i].name] = pq.clone().invert().multiply(W[list[i].name]);
        hand.childDir[list[i].name] = i < list.length - 1 ? list[i + 1].position.clone().normalize() : null;
      }
    });
    // palm frame at rest: F wrist -> knuckle line midpoint, L index -> pinky, N toward the palm (-x in this rig)
    var idxP = P['index-finger-phalanx-proximal'], pnkP = P['pinky-finger-phalanx-proximal'], wP = P['wrist'];
    var Fr = idxP.clone().add(pnkP).multiplyScalar(0.5).sub(wP).normalize();
    var L0 = pnkP.clone().sub(idxP);
    var FxL = new THREE.Vector3().crossVectors(Fr, L0).normalize();
    hand.chirality = FxL.dot(new THREE.Vector3(-1, 0, 0)) >= 0 ? 1 : -1;   // +1: right hand (F x L points to the palm)
    var Nr = FxL.clone().multiplyScalar(hand.chirality);
    var Lr = new THREE.Vector3().crossVectors(Nr, Fr).multiplyScalar(hand.chirality);
    hand.rigF = Fr; hand.rigL = Lr; hand.rigN = Nr;
    hand.rigQ = frameQuat(Fr, Nr);
    hand.palmSize = P['middle-finger-phalanx-proximal'].distanceTo(wP);   // metres, wrist -> middle knuckle
    return hand;
  }

  // rotation taking the frame (x = F, y = N, z = F x N) to the world
  function frameQuat(F, N) {
    var X = new THREE.Vector3().crossVectors(F, N);
    return new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().makeBasis(F, N, X));
  }

  var AX_CURL = new THREE.Vector3(0, 0, -1);   // curl toward the palm (palm faces -x, fingers point -y)
  var AX_SPREAD = new THREE.Vector3(1, 0, 0);  // spread about the palm normal
  var qA = new THREE.Quaternion(), qB = new THREE.Quaternion(), qC = new THREE.Quaternion();

  // resting curvature (mcp, pip, dip) and full-fist angles per finger, degrees; hard joint limits below
  var BASE_ANG = [[12, 20, 9], [16, 24, 11], [20, 28, 13], [24, 32, 15]];
  var FULL_ANG = [[88, 102, 62], [88, 102, 64], [90, 104, 66], [90, 104, 66]];
  var LIM_ANG = [96, 112, 80];

  function poseHand(hand, p) {
    var W = hand.W, ch = hand.chains;
    hand.pivot.quaternion.copy(p.q);
    hand.pivot.position.set(p.x, p.y, p.z);
    hand.model.updateMatrixWorld(true);
    var wristQ = W['wrist'];
    hand.bones['wrist'].quaternion.copy(wristQ);
    var curls = [p.ci, p.cm, p.cr, p.cp];
    var spreadSign = [0.5, 0.12, -0.35, -1.0];
    for (var fi = 0; fi < 4; fi++) {
      var list = ch[FINGERS[fi]];
      var c = clamp(curls[fi], 0, 1.04), b = BASE_ANG[fi], fu = FULL_ANG[fi];
      var a1 = Math.min(b[0] + c * (fu[0] - b[0]), LIM_ANG[0]);
      var a2 = Math.min(b[1] + c * (fu[1] - b[1]), LIM_ANG[1]);
      var a3 = Math.min(b[2] + c * (fu[2] - b[2]), LIM_ANG[2]);
      var ang = [fi * 1.2 * (0.4 + c) * D2R, a1 * D2R, a2 * D2R, a3 * D2R, a3 * D2R];
      var cum = 0;
      var parentPose = wristQ;
      for (var i = 0; i < list.length; i++) {
        cum += ang[i];
        var bw = W[list[i].name];
        qA.setFromAxisAngle(AX_CURL, cum);
        qB.setFromAxisAngle(AX_SPREAD, p.spread * spreadSign[fi] * 11 * D2R * (i >= 1 ? 1 : 0));
        qC.copy(qB).multiply(qA).multiply(bw);   // world pose of this joint
        list[i].quaternion.copy(parentPose).invert().multiply(qC);
        parentPose = qC.clone();
      }
    }
    // thumb: rigid swing (thumbs-up) + a little flex
    var tl = ch['thumb'];
    var sw = new THREE.Quaternion().slerp(hand.qSwing, p.swing);
    var tpose = wristQ;
    var flex = [0, p.tflex * 8 * D2R, p.tflex * 14 * D2R, 0];
    var tcum = 0;
    if (!hand.thumbFlexAxis) hand.thumbFlexAxis = new THREE.Vector3(0.3, 0.2, -0.93).normalize();
    for (var j = 0; j < tl.length; j++) {
      tcum += flex[j];
      var tw = W[tl[j].name];
      qA.setFromAxisAngle(hand.thumbFlexAxis, tcum);
      qC.copy(sw).multiply(qA).multiply(tw);
      tl[j].quaternion.copy(tpose).invert().multiply(qC);
      tpose = qC.clone();
    }
    hand.model.updateMatrixWorld(true);
    // pinch via IK: thumb tip chases the index tip pad; weight blends FK thumb -> IK thumb
    if (p.pinch > 0.001) pinchIK(hand, p.pinch);
  }

  // the thumb chases the index pad (CCD IK, joint-limited); weight 0..1 blends from the current FK thumb
  function pinchIK(hand, weight) {
    var names = ['thumb-metacarpal', 'thumb-phalanx-proximal', 'thumb-phalanx-distal'];
    var maxA = [hand.limits[0], hand.limits[1], hand.limits[2]];
    var fk = names.map(function (n) { return hand.bones[n].quaternion.clone(); });
    for (var it = 0; it < 16; it++) {
      hand.solver.update();
      for (var m = 0; m < names.length; m++) {
        var bq = hand.bones[names[m]].quaternion;
        var an = bq.angleTo(fk[m]);
        if (an > maxA[m]) bq.copy(fk[m]).slerp(bq, maxA[m] / an);
      }
      hand.bones[names[0]].updateMatrixWorld(true);
    }
    var k = clamp(weight, 0, 1);
    for (var n2 = 0; n2 < names.length; n2++) {
      var ik = hand.bones[names[n2]].quaternion.clone();
      hand.bones[names[n2]].quaternion.copy(fk[n2]).slerp(ik, k);
    }
    hand.model.updateMatrixWorld(true);
  }

  // ------------------------------------------------------------------
  // Motion: keyed channels (smootherstep between keys) -> critically damped follower -> baked loop table.
  // ------------------------------------------------------------------
  function sstep(x) { x = clamp(x, 0, 1); return x * x * x * (x * (x * 6 - 15) + 10); }
  function keyed(keys, t) {
    if (t <= keys[0][0]) return keys[0][1];
    for (var i = 0; i < keys.length - 1; i++) {
      var a = keys[i], b = keys[i + 1];
      if (t <= b[0]) return b[0] > a[0] ? lerp(a[1], b[1], sstep((t - a[0]) / (b[0] - a[0]))) : b[1];
    }
    return keys[keys.length - 1][1];
  }
  function shiftKeys(keys, d) { return keys.map(function (k) { return [k[0] + d, k[1]]; }); }
  function scaleKeys(keys, s) { return keys.map(function (k) { return [k[0], k[1] * s]; }); }
  // pinch envelope: close, hold, open (seconds); extra = [start, close, hold, open] overrides
  function pinchKeys(D, starts, close, hold, open) {
    var k = [[0, 0]];
    starts.forEach(function (s) { k.push([s, 0], [s + close, 1], [s + close + hold, 1], [s + close + hold + open, 0]); });
    k.push([D, 0]);
    return k;
  }

  var HZ = 120;
  function bake(D, spec) {
    var names = Object.keys(spec), n = Math.round(D * HZ), dt = 1 / HZ;
    var st = {}, table = [];
    names.forEach(function (nm) { var c = spec[nm]; st[nm] = { x: keyed(c.k, D), v: 0 }; });
    for (var pass = 0; pass < 3; pass++) {
      for (var i = 0; i < n; i++) {
        var t = i * dt, row = {};
        names.forEach(function (nm) {
          var c = spec[nm], s = st[nm], tgt = keyed(c.k, t);
          if (!c.w) { s.x = tgt; s.v = 0; }
          else {
            var steps = 2, h = dt / steps;
            for (var q = 0; q < steps; q++) {
              var a = c.w * c.w * (tgt - s.x) - 2 * c.w * s.v;
              s.v += a * h; s.x += s.v * h;
            }
          }
          row[nm] = s.x;
        });
        if (pass === 2) table.push(row);
      }
    }
    return { D: D, n: n, names: names, rows: table };
  }
  function sampleTable(tb, t) {
    var f = ((t % tb.D) + tb.D) % tb.D * HZ, i = Math.floor(f), k = f - i;
    var a = tb.rows[i % tb.n], b = tb.rows[(i + 1) % tb.n], o = {};
    for (var j = 0; j < tb.names.length; j++) { var nm = tb.names[j]; o[nm] = a[nm] + (b[nm] - a[nm]) * k; }
    return o;
  }

  // ---- orientation bases (world: x right, y up, z toward the viewer; screen is at -z) ----
  function basis(f, pn) { return orthoBasisQuat(new THREE.Vector3(f[0], f[1], f[2]), new THREE.Vector3(pn[0], pn[1], pn[2])); }
  var AXY = new THREE.Vector3(0, 1, 0), AXX = new THREE.Vector3(1, 0, 0), AXZ = new THREE.Vector3(0, 0, 1);
  var qE1 = new THREE.Quaternion(), qE2 = new THREE.Quaternion(), qE3 = new THREE.Quaternion();
  function orient(qa, qb, k, pitch, yaw, roll) {
    var q = new THREE.Quaternion().copy(qa).slerp(qb, k);
    qE1.setFromAxisAngle(AXX, pitch); qE2.setFromAxisAngle(AXY, yaw); qE3.setFromAxisAngle(AXZ, roll);
    return qE2.multiply(qE1).multiply(qE3).multiply(q);
  }

  var G = {};   // per-gesture tuning, filled below
  // raised hand, palm toward the screen, back of the hand toward the viewer, fingers leaning forward
  G.Q_UP = basis([0.0, 0.94, -0.34], [0.0, -0.34, -0.94]);
  G.Q_UP2 = G.Q_UP;
  // forearm forward, palm facing left (inward), thumb up (send)
  G.Q_REST_S = basis([0.0, 0.30, -0.95], [-0.45, -0.75, -0.2]);
  G.Q_THUMB = basis([-0.04, 0.10, -0.99], [-1.0, 0.0, 0.0]);
  // finger cascade offset (s) per finger for the curls
  var CASCADE = 0.04;

  var DUR = { dictate: 6.4, send: 5.2, scroll: 5.6 };

  function specDictate() {
    var D = DUR.dictate;
    var pk = pinchKeys(D, [0.50, 1.07, 4.30, 4.87], 0.12, 0.10, 0.15);
    var dips = [[0, 0]];
    [0.50, 1.07, 4.30, 4.87].forEach(function (s) { dips.push([s, 0], [s + 0.10, 1], [s + 0.30, 0]); });
    dips.push([D, 0]);
    return {
      pinch: { k: pk }, pinchM: { k: shiftKeys(pk, 0.025) }, pinchR: { k: shiftKeys(pk, 0.05) }, pinchP: { k: shiftKeys(pk, 0.075) },
      dip: { k: dips, w: 0 },
      lw: { k: [[0, 0], [1.50, 0], [2.10, 1], [3.60, 1], [4.10, 0], [D, 0]], w: 12 },
      lift: { k: [[0, 0], [4.00, 0], [4.25, 1], [5.45, 1], [5.95, 0], [D, 0]], w: 12 }
    };
  }
  function specSend() {
    var D = DUR.send;
    var up = [[0, 0], [0.60, 0], [0.95, 1], [1.95, 1], [2.45, 0], [D, 0]];
    var o = { orient: { k: up, w: 14 }, swing: { k: [[0, 0], [0.72, 0], [0.97, 1], [1.95, 1], [2.35, 0], [D, 0]], w: 22 } };
    ['ci', 'cm', 'cr', 'cp'].forEach(function (nm, i) {
      o[nm] = { k: [[0, 0], [0.60 + i * CASCADE, 0], [0.60 + i * CASCADE + 0.24, 1], [1.95 + i * 0.03, 1], [2.40 + i * 0.03, 0], [D, 0]], w: 24 };
    });
    o.hold = { k: [[0, 0], [0.95, 0], [1.05, 1], [1.62, 1], [1.72, 0], [D, 0]], w: 0 };
    return o;
  }
  var SCROLL_RISE = 1.15;
  function specScroll() {
    var D = DUR.scroll;
    var pk = [[0, 0], [0.50, 0], [0.62, 1], [4.10, 1], [4.28, 0], [D, 0]];
    var mv = [[0, 0], [0.95, 0], [2.15, 1], [2.55, 1], [3.75, 0], [D, 0]];
    return {
      pinch: { k: pk }, pinchM: { k: shiftKeys(pk, 0.025) }, pinchR: { k: shiftKeys(pk, 0.05) }, pinchP: { k: shiftKeys(pk, 0.075) },
      mv: { k: mv, w: 15 },
      tilt: { k: mv, w: 7 }
    };
  }
  var TABLES = {};
  function tableFor(name) {
    if (!TABLES[name]) TABLES[name] = bake(DUR[name], name === 'dictate' ? specDictate() : name === 'send' ? specSend() : specScroll());
    return TABLES[name];
  }

  function HAND_HOME_V(n) { var h = HAND_HOME[n]; return new THREE.Vector3(h[0], h[1], h[2]); }
  var HAND_HOME = { dictate: [2.9, 2.5, -3.2], send: [3.0, 2.5, -3.2], scroll: [2.9, 2.35, -3.2] };

  function breathe(D, t, amp) {
    var w = 2 * Math.PI * t / D;
    return { y: Math.sin(w * 2) * 0.03 * amp, x: Math.sin(w * 3 + 1.0) * 0.018 * amp, roll: Math.sin(w * 2 + 0.5) * 0.02 * amp, pitch: Math.sin(w * 3 + 2.0) * 0.012 * amp };
  }

  function handPose(name, t) {
    var D = DUR[name], s = sampleTable(tableFor(name), t), h = HAND_HOME[name];
    var b = breathe(D, t, 1);
    var p = { x: h[0] + b.x, y: h[1] + b.y, z: h[2], spread: 0.55, swing: 0, tflex: 0, pinch: 0.14, ci: 0.1, cm: 0.12, cr: 0.16, cp: 0.2 };
    var pitch = b.pitch, yaw = 0.5, roll = b.roll, qa = G.Q_UP, qb = G.Q_UP, ok = 0;
    if (name === 'dictate') {
      var rl = s.lw;
      p.y += -0.30 * s.lw + 0.12 * s.lift - 0.05 * s.dip;
      p.z += 0.05 * s.lw;
      pitch += 0.07 * s.lw - 0.05 * s.lift - 0.07 * s.dip;
      roll += 0.05 * s.lw;
      p.spread = 0.6 + 0.35 * rl;
      p.ci = 0.1 + 0.08 * rl * (1 - s.pinch) + 0.42 * s.pinch; p.cm = 0.12 + 0.12 * rl + 0.2 * s.pinchM; p.cr = 0.16 + 0.12 * rl + 0.3 * s.pinchR; p.cp = 0.2 + 0.12 * rl + 0.38 * s.pinchP;
      p.pinch = 0.12 + 0.88 * s.pinch - 0.06 * rl * (1 - s.pinch);
    } else if (name === 'scroll') {
      p.y += SCROLL_RISE * s.mv;
      p.z -= 0.15 * s.mv;
      pitch += -0.02 + 0.10 * s.tilt - 0.0;
      yaw += -0.05 * s.tilt;
      roll += 0.07 * s.tilt;
      p.ci = 0.1 + 0.42 * s.pinch; p.cm = 0.12 + 0.2 * s.pinchM; p.cr = 0.16 + 0.3 * s.pinchR; p.cp = 0.2 + 0.38 * s.pinchP;
      p.pinch = 0.12 + 0.88 * s.pinch;
      p.spread = 0.6 - 0.2 * s.pinch;
    } else {
      qa = G.Q_REST_S; qb = G.Q_THUMB; ok = s.orient;
      p.ci = 0.12 + 0.88 * s.ci; p.cm = 0.14 + 0.86 * s.cm; p.cr = 0.18 + 0.82 * s.cr; p.cp = 0.2 + 0.8 * s.cp;
      p.swing = s.swing; p.pinch = 0.3 * (1 - s.swing);
      p.spread = 0.55 * (1 - s.orient);
      p.y += 0.12 * s.orient;
      var tr = s.hold;
      p.y += Math.sin(t * 61) * 0.004 * tr; p.x += Math.sin(t * 47 + 1) * 0.003 * tr; roll += Math.sin(t * 53 + 2) * 0.006 * tr;
      p.tflex = 0.0;
    }
    if (window.__qo && name !== 'send') { qa = qb = basis(window.__qo.f, window.__qo.pn); }
    if (window.__ovr) for (var ok2 in window.__ovr) p[ok2] = window.__ovr[ok2];
    p.q = orient(qa, qb, ok, pitch, yaw, roll);
    return p;
  }

  // ------------------------------------------------------------------
  // state handed to onFrame (contract unchanged) and the screen
  // ------------------------------------------------------------------
  // ------------------------------------------------------------------
  // Recorded motion. A capture file (MediaPipe hand landmarks, 4 takes) is cleaned, smoothed,
  // trimmed to its gesture, looped, and baked once into per-frame tracks at CAP_HZ:
  //   dirs  15 bone directions as components in the person's palm frame (a along F, b along L, c along N)
  //   q     the palm frame in the scene (rotation of the frame x = F, y = N, z = F x N)
  //   pos   wrist position in metres, scene axes, relative to the start of the loop
  //   pd    thumb tip to index tip distance (m)     tu  thumbs-up score 0..1
  // Only directions are used on the rig, so the rig's own bone lengths are kept.
  // Scene axes: x right, y up, z toward the viewer. The camera looks along +z of the capture
  // (x right, y down), so a landmark (x, y, z) becomes (-x, -y, z) in the scene.
  // ------------------------------------------------------------------
  var CAP_HZ = 60;
  var CAP_MAX_GAP = 0.15;     // s: dropouts shorter than this are filled by interpolation
  var CAP_XFADE = 0.3;        // s: the loop end crossfades into the loop start
  var PINCH_ON = 0.025, PINCH_OFF = 0.031;   // m: thumb tip to index tip counts as a contact below this
  var CAP_NAMES = ['dictate', 'send', 'scroll'];
  // landmark pairs (from, to) for the 15 retargeted bones: thumb CMC>MCP>IP>TIP, then 4 fingers MCP>PIP>DIP>TIP
  var BONE_PAIRS = [[1, 2], [2, 3], [3, 4], [5, 6], [6, 7], [7, 8], [9, 10], [10, 11], [11, 12], [13, 14], [14, 15], [15, 16], [17, 18], [18, 19], [19, 20]];
  var LM_RIG = ['wrist', 'thumb-metacarpal', 'thumb-phalanx-proximal', 'thumb-phalanx-distal', 'thumb-tip'];
  FINGERS.forEach(function (f) { ['phalanx-proximal', 'phalanx-intermediate', 'phalanx-distal', 'tip'].forEach(function (sg) { LM_RIG.push(f + '-' + sg); }); });
  var CAP_LENIENT = false;    // loadCapture(json, { lenient: true }): accept a shorter scroll pinch (0.4 s) and a 2 cm rise
  var CAPTURE = null;         // { takes, report, handSize, chir }
  var CAP_ON = true;

  function vsub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
  function vdot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
  function vcross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
  function vlen(a) { return Math.sqrt(vdot(a, a)); }
  function vnorm(a) { var l = vlen(a) || 1; return [a[0] / l, a[1] / l, a[2] / l]; }
  function lmv(lm, k, i) { var o = k * 63 + i * 3; return [lm[o], lm[o + 1], lm[o + 2]]; }

  // One Euro filter (Casiez et al.) over a vector; step() returns the filtered state
  function OneEuro(dim, minCutoff, beta, dCutoff) {
    this.dim = dim; this.mc = minCutoff; this.beta = beta; this.dc = dCutoff;
    this.x = null; this.dx = new Float64Array(dim);
  }
  OneEuro.prototype.step = function (v, dt) {
    var i, n = this.dim;
    var al = function (c) { return 1 / (1 + (1 / (2 * Math.PI * c)) / dt); };
    if (!this.x) { this.x = Float64Array.from(v); return this.x; }
    var ad = al(this.dc), sp = 0;
    for (i = 0; i < n; i++) { var d = (v[i] - this.x[i]) / dt; this.dx[i] += ad * (d - this.dx[i]); sp += this.dx[i] * this.dx[i]; }
    var ax = al(this.mc + this.beta * Math.sqrt(sp));
    for (i = 0; i < n; i++) this.x[i] += ax * (v[i] - this.x[i]);
    return this.x;
  };

  // frames -> one clean run resampled to CAP_HZ. Drops frames with no hand, fills short gaps, keeps the longest run.
  function prepTake(frames, cfg) {
    var v = [], votes = { Left: 0, Right: 0 }, srcFrames = (frames || []).length;
    (frames || []).forEach(function (f) {
      if (!f || !f.world || f.world.length < 21 || !isFinite(f.t)) return;
      if (typeof f.score === 'number' && f.score < 0.3) return;
      var lm = new Float64Array(63), ok = true, i;
      for (i = 0; i < 21; i++) {
        var p = f.world[i];
        if (!p || !isFinite(p[0]) || !isFinite(p[1]) || !isFinite(p[2])) { ok = false; break; }
        lm[i * 3] = -p[0]; lm[i * 3 + 1] = -p[1]; lm[i * 3 + 2] = p[2];
      }
      if (!ok) return;
      var im = null;
      if (f.image && f.image.length >= 21) {
        im = new Float64Array(8);
        [0, 5, 9, 17].forEach(function (k, j) { var q = f.image[k]; im[j * 2] = q ? +q[0] : NaN; im[j * 2 + 1] = q ? +q[1] : NaN; });
        for (i = 0; i < 8; i++) if (!isFinite(im[i])) { im = null; break; }
      }
      v.push({ t: f.t / 1000, lm: lm, im: im, g: f.gesture || '' });
      var hl = f.hand || f.handedness; if (hl === 'Left' || hl === 'Right') votes[hl]++;
    });
    if (v.length < 8) return null;
    v.sort(function (a, b) { return a.t - b.t; });
    var runs = [], cur = [v[0]], i;
    for (i = 1; i < v.length; i++) {
      if (v[i].t - v[i - 1].t > CAP_MAX_GAP) { runs.push(cur); cur = []; }
      cur.push(v[i]);
    }
    runs.push(cur);
    var run = runs.reduce(function (a, b) { return (b[b.length - 1].t - b[0].t) > (a[a.length - 1].t - a[0].t) ? b : a; });
    if (run.length < 8) return null;
    var dts = []; for (i = 1; i < run.length; i++) dts.push(run[i].t - run[i - 1].t);
    dts.sort(function (a, b) { return a - b; });
    var medDt = dts[dts.length >> 1] || 1 / 30;
    var filled = 0; for (i = 1; i < run.length; i++) if (run[i].t - run[i - 1].t > 1.6 * medDt) filled++;
    var t0 = run[0].t, t1 = run[run.length - 1].t, n = Math.floor((t1 - t0) * CAP_HZ) + 1;
    var lm2 = new Float64Array(n * 63), im2 = new Float64Array(n * 8), label = new Array(n), hasImg = true, j = 0;
    for (var k = 0; k < n; k++) {
      var g = t0 + k / CAP_HZ;
      while (j < run.length - 2 && run[j + 1].t <= g) j++;
      var A = run[j], B = run[Math.min(j + 1, run.length - 1)];
      var al = B.t > A.t ? clamp((g - A.t) / (B.t - A.t), 0, 1) : 0;
      for (i = 0; i < 63; i++) lm2[k * 63 + i] = A.lm[i] + (B.lm[i] - A.lm[i]) * al;
      if (A.im && B.im) for (i = 0; i < 8; i++) im2[k * 8 + i] = A.im[i] + (B.im[i] - A.im[i]) * al; else hasImg = false;
      label[k] = al < 0.5 ? A.g : B.g;
    }
    // jitter of the raw run (rms of the second difference / sqrt 6), for the filter strength
    // measured on the relaxed first and last half second of the take only (motion would read as noise)
    var s2 = 0, c2 = 0;
    for (i = 1; i < run.length - 1; i++) {
      if (run[i].t - t0 > 0.5 && t1 - run[i].t > 0.5) continue;
      if (run[i + 1].t - run[i - 1].t > 3.2 * medDt) continue;
      for (var e = 0; e < 63; e++) { var dd = run[i + 1].lm[e] - 2 * run[i].lm[e] + run[i - 1].lm[e]; s2 += dd * dd; c2++; }
    }
    return {
      n: n, t0: t0, lm: lm2, im: im2, hasImg: hasImg, label: label,
      right: votes.Right >= votes.Left, votes: votes, srcFrames: srcFrames, validFrames: v.length, filledGaps: filled,
      droppedFrames: srcFrames - v.length, jitter: c2 ? Math.sqrt(s2 / c2 / 6) : 0
    };
  }

  function smoothstepE(a, b, x) { return smooth((x - a) / (b - a)); }

  // per-frame geometry: palm frame, bone directions in it, pinch distance, thumbs-up score, wrist position
  function analyzeTake(P, chir, cfg) {
    var n = P.n, dirs = new Float64Array(n * 45), q = new Float64Array(n * 4), pd = new Float64Array(n),
      tu = new Float64Array(n), pos = new Float64Array(n * 3), geo = 0, gc = 0;
    var Fp = [0, -1, 0], Np = [0, 0, -1], mq = new THREE.Quaternion(), mF = new THREE.Vector3(), mN = new THREE.Vector3();
    var fh = 1 / (2 * Math.tan(cfg.vfov * D2R / 2));
    for (var k = 0; k < n; k++) {
      var lm = P.lm, L = function (i) { return lmv(lm, k, i); };
      var w0 = L(0), m5 = L(5), m17 = L(17);
      var mid = [(m5[0] + m17[0]) / 2, (m5[1] + m17[1]) / 2, (m5[2] + m17[2]) / 2];
      var F = vnorm(vsub(mid, w0)), L0 = vsub(m17, m5);
      var FxL = vcross(F, L0), fl = vlen(FxL);
      if (fl < 1e-9) { F = Fp; FxL = vcross(F, [1, 0, 0]); }
      FxL = vnorm(FxL);
      var N = [FxL[0] * chir, FxL[1] * chir, FxL[2] * chir];
      var Lb = vcross(N, F); Lb = [Lb[0] * chir, Lb[1] * chir, Lb[2] * chir];
      Fp = F; Np = N;
      geo += FxL[2] * -1; gc++;   // palm toward the camera (scene -z) is positive for a right-handed frame
      for (var b = 0; b < 15; b++) {
        var d = vnorm(vsub(L(BONE_PAIRS[b][1]), L(BONE_PAIRS[b][0])));
        dirs[k * 45 + b * 3] = vdot(d, F); dirs[k * 45 + b * 3 + 1] = vdot(d, Lb); dirs[k * 45 + b * 3 + 2] = vdot(d, N);
      }
      mF.set(F[0], F[1], F[2]); mN.set(N[0], N[1], N[2]);
      mq.copy(frameQuat(mF, mN));
      q[k * 4] = mq.x; q[k * 4 + 1] = mq.y; q[k * 4 + 2] = mq.z; q[k * 4 + 3] = mq.w;
      pd[k] = vlen(vsub(L(4), L(8)));
      // thumbs-up: thumb extended and the four fingers curled into the palm
      var tl = vlen(vsub(L(2), L(1))) + vlen(vsub(L(3), L(2))) + vlen(vsub(L(4), L(3)));
      var palm = vlen(vsub(L(9), w0)) || 0.09;
      var ext = smoothstepE(0.84, 0.94, vlen(vsub(L(4), L(1))) / tl) * smoothstepE(0.65, 1.0, vlen(vsub(L(4), L(5))) / palm);
      var curl = 0;
      [[5, 8], [9, 12], [13, 16], [17, 20]].forEach(function (pr) {
        curl += 1 - smoothstepE(1.15, 1.65, vlen(vsub(L(pr[1]), w0)) / (vlen(vsub(L(pr[0]), w0)) || 1));
      });
      tu[k] = Math.max(ext * smoothstepE(0.55, 0.85, curl / 4), P.label[k] === 'Thumb_Up' ? 1 : 0);
      // wrist position from the image: metres per image-height unit at the hand's depth, from in-plane palm sizes
      if (P.hasImg) {
        var im = P.im, o = k * 8, asp = cfg.aspect, sw = 0, si = 0;
        [[0, 2], [1, 3], [0, 1], [0, 3]].forEach(function (pr) {
          var wa = L([0, 5, 9, 17][pr[0]]), wb = L([0, 5, 9, 17][pr[1]]);
          sw += Math.hypot(wa[0] - wb[0], wa[1] - wb[1]);
          si += Math.hypot((im[o + pr[0] * 2] - im[o + pr[1] * 2]) * asp, im[o + pr[0] * 2 + 1] - im[o + pr[1] * 2 + 1]);
        });
        var r = si > 1e-6 ? sw / si : 0;
        pos[k * 3] = -(im[o] - 0.5) * asp * r;
        pos[k * 3 + 1] = -(im[o + 1] - 0.5) * r;
        pos[k * 3 + 2] = fh * r;
      }
    }
    return { dirs: dirs, q: q, pd: pd, tu: tu, pos: pos, palmFacing: gc ? geo / gc : 0 };
  }

  // One Euro per joint direction, the palm frame, the wrist position and the event scalars
  function smoothTrack(A, n, jitter) {
    var dt = 1 / CAP_HZ, noisy = clamp((jitter - 0.001) / 0.005, 0, 1);
    var mc = lerp(3.0, 0.8, noisy);
    var fd = [], b, k, i;
    for (b = 0; b < 15; b++) fd.push(new OneEuro(3, mc, 3.0, 1.5));
    var fq = new OneEuro(4, mc, 1.0, 1.0), fp = new OneEuro(3, lerp(1.4, 0.8, noisy), 8, 1.0),
      fpd = new OneEuro(1, lerp(4.0, 2.5, noisy), 20, 1.0), ftu = new OneEuro(1, 2.0, 1.0, 1.0);
    var prevQ = null, tmp = new Float64Array(3), out = {
      dirs: new Float64Array(n * 45), q: new Float64Array(n * 4), pos: new Float64Array(n * 3), pd: new Float64Array(n), tu: new Float64Array(n)
    };
    for (k = 0; k < n; k++) {
      for (b = 0; b < 15; b++) {
        for (i = 0; i < 3; i++) tmp[i] = A.dirs[k * 45 + b * 3 + i];
        var y = fd[b].step(tmp, dt), l = Math.hypot(y[0], y[1], y[2]) || 1;
        for (i = 0; i < 3; i++) out.dirs[k * 45 + b * 3 + i] = y[i] / l;
      }
      var qq = [A.q[k * 4], A.q[k * 4 + 1], A.q[k * 4 + 2], A.q[k * 4 + 3]];
      if (prevQ && qq[0] * prevQ[0] + qq[1] * prevQ[1] + qq[2] * prevQ[2] + qq[3] * prevQ[3] < 0) qq = qq.map(function (x) { return -x; });
      prevQ = qq;
      var yq = fq.step(qq, dt), lq = Math.hypot(yq[0], yq[1], yq[2], yq[3]) || 1;
      for (i = 0; i < 4; i++) out.q[k * 4 + i] = yq[i] / lq;
      var yp = fp.step([A.pos[k * 3], A.pos[k * 3 + 1], A.pos[k * 3 + 2]], dt);
      for (i = 0; i < 3; i++) out.pos[k * 3 + i] = yp[i];
      out.pd[k] = fpd.step([A.pd[k]], dt)[0];
      out.tu[k] = ftu.step([A.tu[k]], dt)[0];
    }
    return out;
  }

  // [a, b] seconds where the series is above (or below) `on`, with hysteresis `off`
  function runsOf(arr, n, on, off, below, minDur) {
    var out = [], inside = false, a = 0, i;
    for (i = 0; i < n; i++) {
      var x = arr[i];
      if (!inside) { if (below ? x < on : x > on) { inside = true; a = i; } }
      else if (below ? x > off : x < off) { inside = false; out.push([a / CAP_HZ, i / CAP_HZ]); }
    }
    if (inside) out.push([a / CAP_HZ, n / CAP_HZ]);
    var merged = [];
    out.forEach(function (r) {
      var l = merged[merged.length - 1];
      if (l && r[0] - l[1] < 0.08) l[1] = r[1]; else merged.push(r.slice());
    });
    return merged.filter(function (r) { return r[1] - r[0] >= minDur; });
  }
  function longest(runs) { return runs.reduce(function (a, b) { return !a || (b[1] - b[0]) > (a[1] - a[0]) ? b : a; }, null); }

  // raw event structure of a (smoothed) series: contacts, thumbs-up holds
  function rawEvents(S, n) {
    return { contacts: runsOf(S.pd, n, PINCH_ON, PINCH_OFF, true, 0.03), thumbs: runsOf(S.tu, n, 0.5, 0.35, false, 0.2) };
  }

  // screen events for one gesture, from the final looped series (times in loop seconds)
  function gestureEvents(name, S, n, D) {
    var ev = rawEvents(S, n), e = null;
    if (name === 'dictate') {
      var groups = [];
      ev.contacts.forEach(function (c) {
        var g = groups[groups.length - 1];
        if (g && c[0] - g[g.length - 1][1] < 0.8) g.push(c); else groups.push([c]);
      });
      var toggles = groups.map(function (g) { return g[g.length - 1][1] + 0.1; });
      var listen = [];
      for (var i = 0; i < toggles.length; i += 2) listen.push([toggles[i], i + 1 < toggles.length ? toggles[i + 1] : D - 0.4]);
      if (!listen.length) return { fail: 'no double pinch found (contacts: ' + ev.contacts.length + ')' };
      var d0 = listen[0][0] + 0.32, d1 = Math.max(Math.min(d0 + 2.2, listen[0][1] - 0.3), d0 + 0.8);
      e = { listen: listen, draft0: d0, draft1: d1, clearAt: D - 0.35, contacts: ev.contacts, staticT: ev.contacts[0][0] + 0.04 };
    } else if (name === 'send') {
      var h = longest(ev.thumbs.filter(function (r) { return r[1] - r[0] >= 0.5; }));
      if (!h) return { fail: 'no thumbs-up hold found' };
      var G = clamp(0.85 * (h[1] - h[0]), 0.3, 0.75), sentAt = h[0] + G;
      e = { holdFrom: h[0], sentAt: sentAt, sentOff: Math.min(sentAt + 2.5, D - 0.8), fadeAt: D - 0.7, pushOff: D - 0.5, textBack: D - 0.4, thumbs: ev.thumbs, staticT: sentAt - 0.2 };
      if (e.sentOff <= sentAt + 0.3) return { fail: 'hold too late in the take to show Sent' };
    } else {
      var p = longest(ev.contacts.filter(function (c) { return c[1] - c[0] >= (CAP_LENIENT ? 0.4 : 0.8); }));
      if (!p) return { fail: 'no held pinch found for scroll' };
      var y0 = 0, i0 = Math.round(p[0] * CAP_HZ), peak = 0, tp = p[0];
      for (var k = 0; k < 4; k++) y0 += S.pos[clamp(i0 + k, 0, n - 1) * 3 + 1] / 4;
      for (var j = i0; j < Math.min(n, Math.round(p[1] * CAP_HZ)); j++) { var dy = S.pos[j * 3 + 1] - y0; if (dy > peak) { peak = dy; tp = j / CAP_HZ; } }
      if (peak < (CAP_LENIENT ? 0.02 : 0.03)) return { fail: 'wrist rise during the pinch is only ' + (peak * 100).toFixed(1) + ' cm' };
      var sc = new Float32Array(n);
      for (var m = 0; m < n; m++) {
        var tt = m / CAP_HZ, gate = tt < p[0] ? 0 : tt <= p[1] ? 1 : 1 - clamp((tt - p[1]) / 0.2, 0, 1);
        sc[m] = clamp((S.pos[m * 3 + 1] - y0) / peak, 0, 1) * gate;
      }
      e = { contacts: ev.contacts, pinch: p, riseCm: peak * 100, staticT: tp };
      e._scroll = sc;
    }
    return { ev: e };
  }

  function nlerpDirs(a, b, w, out, o) {
    for (var q = 0; q < 15; q++) {
      var x = a[q * 3] + (b[q * 3] - a[q * 3]) * w, y = a[q * 3 + 1] + (b[q * 3 + 1] - a[q * 3 + 1]) * w, z = a[q * 3 + 2] + (b[q * 3 + 2] - a[q * 3 + 2]) * w;
      var l = Math.hypot(x, y, z) || 1;
      out[o + q * 3] = x / l; out[o + q * 3 + 1] = y / l; out[o + q * 3 + 2] = z / l;
    }
  }

  // bake one take: clean, analyse, smooth, trim to the gesture, loop with a crossfade, extract events
  function bakeTake(name, frames, cfg, raw) {
    var P = prepTake(frames, cfg);
    if (!P) return { ok: false, reason: 'fewer than 8 usable frames' };
    var chir = cfg.chir !== null ? cfg.chir : (P.right ? 1 : -1);
    var A = analyzeTake(P, chir, cfg), n = P.n;
    var info = { frames: P.srcFrames, usable: P.validFrames, dropped: P.droppedFrames, gapsFilled: P.filledGaps, seconds: +(n / CAP_HZ).toFixed(2), jitterMm: +(P.jitter * 1000).toFixed(2), palmFacing: +A.palmFacing.toFixed(2) };
    var S = raw ? A : smoothTrack(A, n, cfg.jitter);
    if (raw) {   // exact retarget of the source frames, no smoothing, trim or loop (test harness)
      var rp = new Float32Array(n * 3), p0 = [S.pos[0], S.pos[1], S.pos[2]];
      for (var rk = 0; rk < n; rk++) for (var ri = 0; ri < 3; ri++) rp[rk * 3 + ri] = S.pos[rk * 3 + ri] - p0[ri];
      return { ok: true, raw: true, name: name, D: n / CAP_HZ, n: n, dirs: Float32Array.from(S.dirs), q: Float32Array.from(S.q), pos: rp, pd: Float32Array.from(S.pd), pw: new Float32Array(n), srcStart: P.t0, events: {}, info: info, chir: chir, handSize: P.handSize };
    }
    // trim window around the gesture, from the full smoothed series. [lo, hi] is the stretch of the take this
    // gesture may use (a second gesture in the same take is left out); a window wider than that repeats the edge frame.
    var ev = rawEvents(S, n), a, b, D0 = n / CAP_HZ, lo = 0, hi = D0;
    var rr2 = function (r) { return r.map(function (x) { return [+x[0].toFixed(2), +x[1].toFixed(2)]; }); };
    info.contactRuns = rr2(ev.contacts); info.thumbsUpRuns = rr2(ev.thumbs);
    var bound = function (runs, main) {
      runs.forEach(function (r) { if (r === main) return; if (r[1] <= main[0]) lo = Math.max(lo, r[1] + 0.3); else if (r[0] >= main[1]) hi = Math.min(hi, r[0] - 0.3); });
    };
    if (name === 'dictate') {
      if (!ev.contacts.length) return { ok: false, reason: 'no pinch contact below ' + PINCH_ON * 100 + ' cm', info: info };
      a = ev.contacts[0][0] - 0.5; b = ev.contacts[ev.contacts.length - 1][1] + 1.0;
    } else if (name === 'send') {
      // the hold with the most room around it, then the longest
      var best = null;
      ev.thumbs.forEach(function (h) { if (h[1] - h[0] >= 0.5 && (!best || (h[1] - h[0]) > (best[1] - best[0]))) best = h; });
      if (!best) return { ok: false, reason: 'no thumbs-up hold of at least 0.5 s', info: info };
      bound(ev.thumbs, best);
      a = best[0] - 1.0; b = Math.max(best[1] + 3.0, best[0] - 1.0 + 4.8);
    } else {
      var pr = longest(ev.contacts.filter(function (c) { return c[1] - c[0] >= (CAP_LENIENT ? 0.4 : 0.8); }));
      if (!pr) return { ok: false, reason: 'no pinch held for ' + (CAP_LENIENT ? 0.4 : 0.8) + ' s', info: info };
      a = pr[0] - 0.5; b = pr[1] + 1.2;
    }
    var i0 = Math.round(a * CAP_HZ), m = Math.round(b * CAP_HZ) - i0, X = Math.round(CAP_XFADE * CAP_HZ), L = m - X;
    var ilo = Math.max(0, Math.round(lo * CAP_HZ)), ihi = Math.min(n - 1, Math.round(hi * CAP_HZ));
    if (ihi - ilo < CAP_HZ * 1.5) return { ok: false, reason: 'only ' + ((ihi - ilo) / CAP_HZ).toFixed(1) + ' s of this take is usable for the gesture', info: info };
    info.padSeconds = +Math.max(0, (i0 < ilo ? ilo - i0 : 0) + (i0 + m > ihi ? i0 + m - ihi : 0)).toFixed(2) / CAP_HZ;
    var T = { dirs: new Float32Array(L * 45), q: new Float32Array(L * 4), pos: new Float32Array(L * 3), pd: new Float32Array(L), tu: new Float32Array(L) };
    var k, i, w, sx = function (j) { return clamp(j, ilo, ihi); };
    for (k = 0; k < L; k++) {
      var s1 = sx(i0 + k), s0 = sx(i0 + L + k);
      if (k < X) {
        w = smooth(k / X);
        nlerpDirs(S.dirs.subarray(s0 * 45, s0 * 45 + 45), S.dirs.subarray(s1 * 45, s1 * 45 + 45), w, T.dirs, k * 45);
        var sg = 0; for (i = 0; i < 4; i++) sg += S.q[s0 * 4 + i] * S.q[s1 * 4 + i];
        sg = sg < 0 ? -1 : 1;
        var ql = 0, qv = [];
        for (i = 0; i < 4; i++) { qv[i] = S.q[s0 * 4 + i] * sg * (1 - w) + S.q[s1 * 4 + i] * w; ql += qv[i] * qv[i]; }
        ql = Math.sqrt(ql) || 1;
        for (i = 0; i < 4; i++) T.q[k * 4 + i] = qv[i] / ql;
        for (i = 0; i < 3; i++) T.pos[k * 3 + i] = S.pos[s0 * 3 + i] * (1 - w) + S.pos[s1 * 3 + i] * w;
        T.pd[k] = S.pd[s0] * (1 - w) + S.pd[s1] * w; T.tu[k] = S.tu[s0] * (1 - w) + S.tu[s1] * w;
      } else {
        for (i = 0; i < 45; i++) T.dirs[k * 45 + i] = S.dirs[s1 * 45 + i];
        for (i = 0; i < 4; i++) T.q[k * 4 + i] = S.q[s1 * 4 + i];
        for (i = 0; i < 3; i++) T.pos[k * 3 + i] = S.pos[s1 * 3 + i];
        T.pd[k] = S.pd[s1]; T.tu[k] = S.tu[s1];
      }
    }
    // positions relative to the loop start (the first 0.2 s)
    var ref = [0, 0, 0], rn = Math.round(0.2 * CAP_HZ);
    for (k = 0; k < rn; k++) for (i = 0; i < 3; i++) ref[i] += T.pos[k * 3 + i] / rn;
    for (k = 0; k < L; k++) for (i = 0; i < 3; i++) T.pos[k * 3 + i] -= ref[i];
    var D = L / CAP_HZ, ge = gestureEvents(name, T, L, D);
    if (ge.fail) return { ok: false, reason: ge.fail, info: info };
    var pw = new Float32Array(L);
    for (k = 0; k < L; k++) pw[k] = 1 - smoothstepE(0.019, 0.034, T.pd[k]);   // contact weight for the thumb IK
    var evs = ge.ev, scroll = evs._scroll; delete evs._scroll;
    return {
      ok: true, name: name, D: D, n: L, dirs: T.dirs, q: T.q, pos: T.pos, pd: T.pd, pw: pw, scroll: scroll, events: evs,
      srcStart: P.t0 + i0 / CAP_HZ, trim: [+(a).toFixed(2), +(b).toFixed(2)], chir: chir, info: info
    };
  }

  function capTake(name) { return CAPTURE && CAP_ON && CAPTURE.takes[name] && CAPTURE.takes[name].ok ? CAPTURE.takes[name] : null; }

  function capIndex(tk, t) {
    var f = (((t % tk.D) + tk.D) % tk.D) * CAP_HZ, i = Math.floor(f);
    return { i0: i % tk.n, i1: (i + 1) % tk.n, k: f - i };
  }
  function capScalar(tk, arr, t) { var c = capIndex(tk, t); return arr[c.i0] + (arr[c.i1] - arr[c.i0]) * c.k; }
  var capOut = { q: new THREE.Quaternion(), qb: new THREE.Quaternion(), dirs: new Float32Array(45), pos: [0, 0, 0], pw: 0, pd: 0 };
  function capSample(tk, t) {
    var c = capIndex(tk, t), o = capOut, i, k = c.k;
    for (i = 0; i < 45; i++) o.dirs[i] = tk.dirs[c.i0 * 45 + i] + (tk.dirs[c.i1 * 45 + i] - tk.dirs[c.i0 * 45 + i]) * k;
    o.q.set(tk.q[c.i0 * 4], tk.q[c.i0 * 4 + 1], tk.q[c.i0 * 4 + 2], tk.q[c.i0 * 4 + 3]);
    o.qb.set(tk.q[c.i1 * 4], tk.q[c.i1 * 4 + 1], tk.q[c.i1 * 4 + 2], tk.q[c.i1 * 4 + 3]);
    if (o.q.dot(o.qb) < 0) { o.qb.x *= -1; o.qb.y *= -1; o.qb.z *= -1; o.qb.w *= -1; }
    o.q.x += (o.qb.x - o.q.x) * k; o.q.y += (o.qb.y - o.q.y) * k; o.q.z += (o.qb.z - o.q.z) * k; o.q.w += (o.qb.w - o.q.w) * k; o.q.normalize();
    for (i = 0; i < 3; i++) o.pos[i] = tk.pos[c.i0 * 3 + i] + (tk.pos[c.i1 * 3 + i] - tk.pos[c.i0 * 3 + i]) * k;
    o.pw = tk.pw[c.i0] + (tk.pw[c.i1] - tk.pw[c.i0]) * k;
    o.pd = tk.pd[c.i0] + (tk.pd[c.i1] - tk.pd[c.i0]) * k;
    return o;
  }

  // Load a capture file (object or JSON string). Returns a report; takes that fail fall back to the keyed animation.
  function loadCapture(json, opts) {
    opts = opts || {};
    CAP_LENIENT = !!opts.lenient;
    if (typeof json === 'string') json = JSON.parse(json);
    var report = { ok: false, takes: {}, warnings: [] };
    if (!json || !json.takes) { report.warnings.push('no takes in capture'); return report; }
    var cam = json.camera || {};
    var cfg = { aspect: json.aspect || cam.aspect || (cam.width && cam.height ? cam.width / cam.height : 0) || (json.width && json.height ? json.width / json.height : 16 / 9), vfov: json.vfov || cam.vfov || 45, chir: null, jitter: 0 };
    var mode = opts.chirality || json.chirality || 'label';
    // no rest take: the relaxed idle hand is the first and last half second of each take. It gives the
    // person's palm size and the sensor jitter (filter strength).
    var sizeOf = function (P) {
      var a = [], k, e = Math.round(0.5 * CAP_HZ);
      for (k = 0; k < P.n; k++) if (k < e || k >= P.n - e) a.push(vlen(vsub(lmv(P.lm, k, 9), lmv(P.lm, k, 0))));
      a.sort(function (x, y) { return x - y; });
      return a.length ? a[a.length >> 1] : 0;
    };
    var handSize = 0, sizes = [], jit = [];
    CAP_NAMES.forEach(function (nm) {
      var P = json.takes[nm] ? prepTake(json.takes[nm], cfg) : null;
      if (P) { sizes.push(sizeOf(P)); jit.push(P.jitter); }
    });
    sizes.sort(function (x, y) { return x - y; }); jit.sort(function (x, y) { return x - y; });
    if (sizes.length) { handSize = sizes[sizes.length >> 1]; cfg.jitter = jit[jit.length >> 1]; }
    else report.warnings.push('no usable take: filter strength and hand size use defaults');
    report.idle = { palmMm: Math.round(handSize * 1000), jitterMm: +(cfg.jitter * 1000).toFixed(2) };
    // handedness: the label's vote, unless overridden; checked against which way the palm faces the camera
    var votes = { Left: 0, Right: 0 };
    Object.keys(json.takes).forEach(function (nm) { (json.takes[nm] || []).forEach(function (f) { var hl = f && (f.hand || f.handedness); if (hl === 'Left' || hl === 'Right') votes[hl]++; }); });
    var chir = votes.Right >= votes.Left ? 1 : -1;
    if (mode === 'right') chir = 1; else if (mode === 'left') chir = -1;
    var facing = [];
    ['dictate', 'scroll'].forEach(function (nm) {
      var P = json.takes[nm] ? prepTake(json.takes[nm], cfg) : null;
      if (P) facing.push(analyzeTake(P, chir, cfg).palmFacing);
    });
    var fm = facing.length ? facing.reduce(function (a, b) { return a + b; }, 0) / facing.length : 0;
    if (mode === 'auto' && facing.length) { if (fm < 0) chir = -chir; }
    else if (facing.length && fm < -0.2) report.warnings.push('the dictate and scroll takes show the palm turned away from the camera under the "' + (chir > 0 ? 'Right' : 'Left') + '" label; if the labels came from a mirrored image, pass { chirality: "auto" }');
    cfg.chir = chir;
    report.chirality = chir > 0 ? 'Right' : 'Left'; report.palmFacing = +fm.toFixed(2);
    var takes = {};
    CAP_NAMES.forEach(function (nm) {
      if (!json.takes[nm] || !json.takes[nm].length) { report.takes[nm] = { ok: false, reason: 'take missing, keyed animation used' }; return; }
      var tk = bakeTake(nm, json.takes[nm], cfg, !!opts.raw);
      tk.handSize = handSize;
      takes[nm] = tk;
      report.takes[nm] = tk.ok ? { ok: true, loopSeconds: +tk.D.toFixed(2), trim: tk.trim, source: tk.info, events: summarize(tk.events) } : { ok: false, reason: tk.reason + ', keyed animation used', source: tk.info };
      if (!tk.ok) report.warnings.push(nm + ': ' + tk.reason);
    });
    report.ok = CAP_NAMES.some(function (nm) { return takes[nm] && takes[nm].ok; });
    CAPTURE = { takes: takes, report: report, handSize: handSize, chir: chir };
    CAP_ON = true;
    if (window.console && console.info) console.info('[EnsembleScene] capture loaded', report);
    return report;
  }
  function summarize(ev) {
    var o = {}, r = function (x) { return Math.round(x * 100) / 100; };
    Object.keys(ev).forEach(function (k) {
      var v = ev[k];
      if (typeof v === 'number') o[k] = r(v);
      else if (Array.isArray(v)) o[k] = v.map(function (x) { return Array.isArray(x) ? x.map(r) : r(x); });
    });
    return o;
  }

  // ------------------------------------------------------------------
  // Retarget one baked frame onto the rig: wrist from the palm frame, every finger bone swung in its
  // parent's space so its direction matches the recording. Bone lengths stay the rig's own.
  // ------------------------------------------------------------------
  var rtQ0 = new THREE.Quaternion(), rtQ = new THREE.Quaternion(), rtPQ = new THREE.Quaternion(), rtSw = new THREE.Quaternion(),
    rtCur = new THREE.Vector3(), rtD = new THREE.Vector3();
  function swingChain(hand, list, dirs) {
    // list._base: first of the 3-vectors for this chain; list._rigidFirst: the metacarpal follows the palm (no landmark for it)
    rtPQ.copy(hand.W['wrist']);
    for (var i = 0; i < list.length; i++) {
      var b = list[i], cd = hand.childDir[b.name];
      rtQ0.copy(rtPQ).multiply(hand.restLocal[b.name]);
      if (cd && !(list._rigidFirst && i === 0)) {
        var o = (list._base + (list._rigidFirst ? i - 1 : i)) * 3;
        rtD.set(0, 0, 0).addScaledVector(hand.rigF, dirs[o]).addScaledVector(hand.rigL, dirs[o + 1]).addScaledVector(hand.rigN, dirs[o + 2]).normalize();
        rtCur.copy(cd).applyQuaternion(rtQ0);
        rtSw.setFromUnitVectors(rtCur, rtD);
        rtQ.copy(rtSw).multiply(rtQ0);
      } else if (!cd && i > 0 && list._rigidFirst) {
        // leaf bone (no landmark): bend as far as the bone before it, so the fingertip follows the distal phalanx
        var pb = list[i - 1];
        rtQ.copy(hand.restLocal[pb.name]).invert().multiply(pb.quaternion);
        rtQ.premultiply(hand.restLocal[b.name]);
        b.quaternion.copy(rtQ);
        rtQ.copy(rtPQ).multiply(b.quaternion);
        rtPQ.copy(rtQ);
        continue;
      } else rtQ.copy(rtQ0);
      b.quaternion.copy(rtPQ).invert().multiply(rtQ);
      rtPQ.copy(rtQ);
    }
  }
  var rtR = new THREE.Quaternion(), rtInv = new THREE.Quaternion();
  function poseHandCapture(hand, tk, t, name) {
    var s = capSample(tk, t), ch = hand.chains;
    rtInv.copy(hand.rigQ).invert();
    rtR.copy(s.q).multiply(rtInv);                       // rest palm frame -> the recorded palm frame
    var kk = HAND_SCALE * clamp(tk.handSize ? hand.palmSize / tk.handSize : 1, 0.8, 1.25);   // metres of the person -> scene units
    var home = HAND_HOME[name];
    hand.pivot.quaternion.identity();
    hand.pivot.position.set(home[0] + s.pos[0] * kk, home[1] + s.pos[1] * kk, home[2] + s.pos[2] * kk);
    hand.bones['wrist'].quaternion.copy(rtR).multiply(hand.W['wrist']);
    var th = ch['thumb']; th._base = 0; th._rigidFirst = false;
    swingChain(hand, th, s.dirs);
    for (var fi = 0; fi < 4; fi++) { var l = ch[FINGERS[fi]]; l._base = 3 + fi * 3; l._rigidFirst = true; swingChain(hand, l, s.dirs); }
    hand.pivot.updateMatrixWorld(true);
    if (s.pw > 0.001 && tk.ikPinch !== false) pinchIK(hand, 0.5 * s.pw);   // half-way: the recorded thumb already reaches, this only closes a small gap
  }

  // Event times that drive the screen. Keyed defaults; a loaded capture replaces them per gesture.
  var KEYED_EVENTS = {
    dictate: { listen: [[1.38, 5.32]], draft0: 1.7, draft1: 3.9, clearAt: 6.05 },
    send: { holdFrom: 0.97, sentAt: 1.72, sentOff: 4.2, fadeAt: 4.5, pushOff: 4.7, textBack: 4.8 },
    scroll: {}
  };
  function eventsFor(name) {
    var tk = capTake(name);
    return tk ? tk.events : (KEYED_EVENTS[name] || {});
  }
  function durOf(name) {
    var tk = capTake(name);
    return tk ? tk.D : DURATIONS[name];
  }
  function staticTOf(name) {
    var tk = capTake(name);
    return tk && tk.events.staticT !== undefined ? tk.events.staticT : STATIC_T[name];
  }
  function stateFor(name, t) {
    var s = { listening: false, draft: 0, hold: 0, sent: false, scroll: 0 };
    var tk = capTake(name), e = eventsFor(name);
    if (name === 'dictate') {
      s.listening = e.listen.some(function (iv) { return t >= iv[0] && t < iv[1]; });
      s.draft = t < e.draft0 ? 0 : t > e.draft1 ? 1 : sstep((t - e.draft0) / (e.draft1 - e.draft0));
    } else if (name === 'send') {
      s.hold = t < e.holdFrom || t >= e.sentOff ? 0 : t >= e.sentAt ? 1 : (t - e.holdFrom) / (e.sentAt - e.holdFrom);
      s.sent = t >= e.sentAt && t < e.sentOff;
    } else if (name === 'scroll') {
      s.scroll = tk ? clamp(capScalar(tk, tk.scroll, t), 0, 1) : clamp(sampleTable(tableFor('scroll'), t).mv, 0, 1);
    }
    s.scene = name; s.gesture = name; s.t = t;
    return s;
  }

  // ------------------------------------------------------------------
  // mount
  // ------------------------------------------------------------------
  var lastInstance = null;

  function noop() { return { setScene: function () { }, destroy: function () { } }; }

  function mount(container, opts) {
    opts = opts || {};
    var reduced = !!opts.reducedMotion;
    var onFrame = typeof opts.onFrame === 'function' ? opts.onFrame : function () { };
    var handUrl = opts.handUrl || 'assets/hand.glb';
    var current = DURATIONS[opts.scene] ? opts.scene : 'welcome';
    if (opts.capture) { try { loadCapture(opts.capture, opts.captureOptions); } catch (e) { if (window.console) console.warn('[EnsembleScene] capture ignored', e); } }

    var renderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false, powerPreference: 'low-power' });
      if (!renderer.getContext()) throw new Error('no context');
    } catch (e) {
      var msg = document.createElement('p');
      msg.textContent = '3D preview needs WebGL, which this browser has turned off.';
      msg.style.cssText = 'margin:0;padding:24px;font:14px/1.4 system-ui,sans-serif;color:#9db0cc;text-align:center';
      container.appendChild(msg);
      return noop();
    }
    renderer.setClearColor(0x04070c, 1);
    container.appendChild(renderer.domElement);
    renderer.domElement.style.cssText = 'display:block;width:100%;height:100%';
    if (!container.style.position) container.style.position = 'relative';

    var scene = new THREE.Scene();
    var disposables = [];
    var stage = buildStage(scene, disposables);
    var desk = buildDesk(scene, disposables);
    var gstage = buildGestureStage(scene, disposables);
    var camera = new THREE.PerspectiveCamera(40, 1.6, 0.1, 500);
    var hand = null, handLoading = false, handFailed = false;

    var CAMS = {
      desk: { pos: new THREE.Vector3(1.2, 3.6, 4.3), look: new THREE.Vector3(-0.25, 1.45, -1.2), fov: 48 },
      hand: { pos: new THREE.Vector3(1.2, 4.0, 1.4), look: new THREE.Vector3(1.2, 3.3, -9.0), fov: 33 }
    };

    function loadHand() {
      if (hand || handLoading || handFailed) return;
      handLoading = true;
      var onHand = function (gltf) {
        handLoading = false;
        if (destroyed) return;
        try { hand = buildHand(scene, gltf, disposables); } catch (e) { handFailed = true; if (window.console) console.warn('[EnsembleScene] hand build failed', e); return; }
        hand.pivot.visible = !!HAND_SCENES[current];
        if (reduced) renderNow(); else if (frozen) frozenDirty = true;
      };
      var onFail = function (e) { handLoading = false; handFailed = true; if (window.console) console.warn('[EnsembleScene] hand load failed', e); };
      // An embedded copy (hand-data.js) avoids fetching a .glb where a host will not serve that type.
      if (window.ENSEMBLE_HAND_B64) {
        var bin = atob(window.ENSEMBLE_HAND_B64), buf = new Uint8Array(bin.length);
        for (var k = 0; k < bin.length; k++) buf[k] = bin.charCodeAt(k);
        new THREE.GLTFLoader().parse(buf.buffer, '', onHand, onFail);
      } else {
        new THREE.GLTFLoader().load(handUrl, onHand, undefined, onFail);
      }
    }

    var destroyed = false, raf = null, t0 = performance.now(), frozen = null, frozenDirty = false;

    function resize() {
      var w = container.clientWidth || 640, h = container.clientHeight || 400;
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      renderer.setPixelRatio(dpr);
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
    }
    resize();
    var ro = null;
    if (window.ResizeObserver) { ro = new ResizeObserver(resize); ro.observe(container); } else window.addEventListener('resize', resize);

    function renderFrame(name, t, drift) {
      var isHand = !!HAND_SCENES[name];
      var c = isHand ? (window.__camHand || CAMS.hand) : (window.__camDesk || CAMS.desk);
      var d = drift ? t : 0;
      var kind = isHand ? 1 : 0;
      camera.fov = c.fov;
      camera.position.set(c.pos.x + Math.sin(d * 0.35) * 0.18 * (isHand ? 0.7 : 1), c.pos.y + Math.sin(d * 0.27) * 0.06, c.pos.z + Math.cos(d * 0.3) * 0.08);
      camera.lookAt(c.look);
      camera.updateProjectionMatrix();
      stage.gridMat.uniforms.uCam.value.copy(camera.position);

      var extra = {};
      if (isHand) {
        loadHand();
        desk.root.visible = false;
        gstage.group.visible = true;
        var gst = stateFor(name, t);
        gstage.screen.draw(gst, name, t);
        if (hand) {
          hand.pivot.visible = true;
          var ctk = capTake(name);
          if (ctk) poseHandCapture(hand, ctk, t, name); else poseHand(hand, handPose(name, t));
        }
      } else {
        desk.root.visible = true;
        gstage.group.visible = false;
        if (hand) hand.pivot.visible = false;
        extra = desk.update(name, t);
      }
      renderer.render(scene, camera);
      var st = stateFor(name, t);
      if (extra.dot !== undefined) { st.dot = extra.dot; st.progress = extra.progress; }
      onFrame(st);
    }
    function renderNow() { renderFrame(frozen ? frozen.name : current, frozen ? frozen.t : (reduced ? staticTOf(current) : 0), false); }

    function loop() {
      if (destroyed) return;
      raf = requestAnimationFrame(loop);
      if (frozen) { if (frozenDirty) { frozenDirty = false; renderFrame(frozen.name, frozen.t, false); } return; }
      var el = (performance.now() - t0) / 1000;
      renderFrame(current, el % durOf(current), true);
    }

    if (HAND_SCENES[current]) loadHand();
    if (reduced) { renderNow(); } else { raf = requestAnimationFrame(loop); }

    var handle = {
      setScene: function (name) {
        if (!DURATIONS[name]) return;
        current = name; t0 = performance.now(); frozen = null;
        if (HAND_SCENES[name]) loadHand();
        if (reduced) renderNow();
      },
      destroy: function () {
        if (destroyed) return;
        destroyed = true;
        if (raf !== null) cancelAnimationFrame(raf);
        if (ro) ro.disconnect(); else window.removeEventListener('resize', resize);
        disposables.forEach(function (d) { if (d && d.dispose) d.dispose(); });
        renderer.dispose();
        if (renderer.domElement.parentNode) renderer.domElement.parentNode.removeChild(renderer.domElement);
        if (lastInstance === handle) lastInstance = null;
      },
      _seek: function (name, t) {
        if (!DURATIONS[name]) name = current;
        current = name;
        frozen = { name: name, t: t }; frozenDirty = true;
        if (HAND_SCENES[name]) loadHand();
        if (reduced) renderNow();
      },
      // ---- test harness: sample the keyed animation into MediaPipe-style landmarks ----
      _synthCapture: function (fps, pad, opts) {
        opts = opts || {};
        if (!hand) return null;
        var asp = 16 / 9, vfov = 45, fh = 1 / (2 * Math.tan(vfov * D2R / 2)), Z0 = 0.55;
        var out = { version: 1, fps: fps, camera: { width: 1280, height: 720 }, vfov: vfov, meta: { source: 'synthetic-keyed', pad: pad }, takes: {} };
        var seed = 7; function rnd() { seed = (seed * 16807) % 2147483647; return seed / 2147483647; }
        function gauss() { return Math.sqrt(-2 * Math.log(rnd() + 1e-9)) * Math.cos(2 * Math.PI * rnd()); }
        CAP_NAMES.forEach(function (name) {
          var isRest = false, D = isRest ? 2.0 : DUR[name], total = isRest ? D : D + 2 * pad, nF = Math.round(total * fps), frames = [];
          var home = HAND_HOME[isRest ? 'dictate' : name];
          for (var i = 0; i < nF; i++) {
            var tt = i / fps, kt = isRest ? 0 : clamp(tt - pad, 0, D);
            if (opts.noise && !isRest && rnd() < 0.05) { frames.push({ t: tt * 1000, handedness: null, world: null, image: null, gesture: null, score: 0 }); continue; }
            if (opts.noise && !isRest && name === 'send' && i >= 60 && i < 63) { frames.push({ t: tt * 1000, handedness: null, world: null, image: null, gesture: null, score: 0 }); continue; }
            poseHand(hand, handPose(isRest ? 'dictate' : name, kt));
            hand.pivot.updateMatrixWorld(true);
            var C = LM_RIG.map(function (bn) {
              var p = hand.bones[bn].getWorldPosition(new THREE.Vector3());
              // scene units -> camera frame (x right, y down, z away), hand at ~0.55 m
              return [-(p.x - home[0]) / HAND_SCALE, -(p.y - home[1]) / HAND_SCALE, Z0 + (p.z - home[2]) / HAND_SCALE];
            });
            var cen = [0, 0, 0]; [0, 5, 9, 13, 17].forEach(function (k) { for (var a = 0; a < 3; a++) cen[a] += C[k][a] / 5; });
            var ns = opts.noise ? 0.003 : 0, ni = opts.noise ? 0.002 : 0;
            frames.push({
              t: tt * 1000, handedness: hand.chirality > 0 ? 'Right' : 'Left',
              world: C.map(function (c) { return [c[0] - cen[0] + gauss() * ns, c[1] - cen[1] + gauss() * ns, c[2] - cen[2] + gauss() * ns]; }),
              image: C.map(function (c) { return [0.5 + fh * c[0] / (c[2] * asp) + gauss() * ni, 0.5 + fh * c[1] / c[2] + gauss() * ni]; }),
              gesture: 'None', score: 0.99
            });
          }
          out.takes[name] = frames;
        });
        return out;
      },
      // error of the retarget against the keyed pose it was sampled from (raw frames, then the full pipeline)
      _retargetTest: function (json, mode) {
        if (!hand) return null;
        var rep = loadCapture(json, { raw: mode === 'raw' });
        if (mode === 'noik') CAP_NAMES.forEach(function (n) { if (CAPTURE.takes[n]) CAPTURE.takes[n].ikPinch = false; });
        var pad = json.meta.pad, res = {}, chainNames = [];
        Object.keys(hand.chains).forEach(function (f) { hand.chains[f].forEach(function (b) { chainNames.push(b.name); }); });
        function snap() {
          hand.pivot.updateMatrixWorld(true);
          var o = { q: {}, d: {}, tip: {}, w: hand.bones['wrist'].getWorldPosition(new THREE.Vector3()), wq: hand.bones['wrist'].getWorldQuaternion(new THREE.Quaternion()) };
          chainNames.forEach(function (n) { o.q[n] = hand.bones[n].getWorldQuaternion(new THREE.Quaternion()); });
          Object.keys(hand.chains).forEach(function (f) {
            var l = hand.chains[f];
            for (var i = 0; i < l.length - 1; i++) o.d[l[i].name] = l[i + 1].getWorldPosition(new THREE.Vector3()).sub(l[i].getWorldPosition(new THREE.Vector3())).normalize();
            o.tip[f] = l[l.length - 1].getWorldPosition(new THREE.Vector3()).sub(o.w);
          });
          return o;
        }
        var DEG = 180 / Math.PI;
        CAP_NAMES.forEach(function (name) {
          var tk = CAPTURE.takes[name];
          if (!tk || !tk.ok) { res[name] = { ok: false, reason: tk && tk.reason }; return; }
          var D = DUR[name], pb = {}, errs = { dir: [], ori: [], wrist: [], tip: [], pos: [] }, step = mode === 'raw' ? 1 : 3;
          var base0 = null;
          // keyed reference at its time 0 for relative motion
          var tstart = clamp((tk.srcStart - json.takes[name][0].t / 1000) - pad, 0, D);
          poseHand(hand, handPose(name, tstart)); base0 = snap();
          var kbase = hand.pivot.position.clone();
          for (var i = 0; i < tk.n; i += step) {
            var tr = i / CAP_HZ, tk_ = mode === 'raw' ? (tk.srcStart + tr - json.takes[name][0].t / 1000) - pad : (tk.srcStart + tr - json.takes[name][0].t / 1000) - pad;
            if (tk_ < 0 || tk_ > D) continue;
            poseHand(hand, handPose(name, tk_)); var A = snap(); var kpos = hand.pivot.position.clone().sub(kbase);
            var tkp = tk; poseHandCapture(hand, tkp, tr, name); var B = snap(); var rpos = hand.pivot.position.clone().sub(HAND_HOME_V(name));
            var ds = [], os = [], ts = [];
            chainNames.forEach(function (n) { var e = A.q[n].angleTo(B.q[n]) * DEG; os.push(e); (pb[n] = pb[n] || []).push(e); });
            Object.keys(A.d).forEach(function (n) { ds.push(Math.acos(clamp(A.d[n].dot(B.d[n]), -1, 1)) * DEG); });
            Object.keys(A.tip).forEach(function (f) { ts.push(A.tip[f].distanceTo(B.tip[f]) / HAND_SCALE * 100); });
            errs.dir.push(Math.max.apply(null, ds)); (errs.series = errs.series || []).push([+tr.toFixed(2), +Math.max.apply(null, ds).toFixed(1), Object.keys(A.d)[ds.indexOf(Math.max.apply(null, ds))]]); errs.ori.push(Math.max.apply(null, os)); errs.wrist.push(A.wq.angleTo(B.wq) * DEG);
            errs.tip.push(Math.max.apply(null, ts)); errs.pos.push(kpos.clone().sub(rpos).length() / HAND_SCALE * 100);
          }
          function stat(a) { var s = a.slice().sort(function (x, y) { return x - y; }); return { mean: +(a.reduce(function (x, y) { return x + y; }, 0) / a.length).toFixed(2), p95: +s[Math.floor(s.length * 0.95)].toFixed(2), max: +s[s.length - 1].toFixed(2) }; }
          var pbm = {}; Object.keys(pb).forEach(function (n) { pbm[n] = +(pb[n].reduce(function (x, y) { return x + y; }, 0) / pb[n].length).toFixed(1); });
          res[name] = { series: errs.series, perBoneMeanOri: pbm, frames: errs.dir.length, maxDirDeg: stat(errs.dir), maxBoneOriDeg: stat(errs.ori), wristDeg: stat(errs.wrist), maxTipCm: stat(errs.tip), motionCm: stat(errs.pos) };
        });
        return { report: rep, errors: res };
      },
      _hand: function () { return hand; },
      _ready: function () { return !HAND_SCENES[current] || !!hand || handFailed; },
      _pinchGap: function () {
        if (!hand) return null;
        var a = hand.bones['thumb-tip'].getWorldPosition(new THREE.Vector3());
        var b = hand.bones['pinch-target'] ? null : null;
        var tb = null;
        hand.skinned.skeleton.bones.forEach(function (bb) { if (bb.name === 'pinch-target') tb = bb; });
        var c = tb.getWorldPosition(new THREE.Vector3());
        return a.distanceTo(c) / hand.scale;
      }
    };
    lastInstance = handle;
    return handle;
  }

  window.EnsembleScene = {
    mount: mount,
    loadCapture: loadCapture,
    clearCapture: function () { CAPTURE = null; },
    useCapture: function (on) { CAP_ON = !!on; },
    captureReport: function () { return CAPTURE ? CAPTURE.report : null; },
    _take: function (n) { return CAPTURE && CAPTURE.takes[n]; },
    _seek: function (name, t) { if (lastInstance) lastInstance._seek(name, t); },
    _last: function () { return lastInstance; }
  };
})();
