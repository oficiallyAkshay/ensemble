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
  // Site copy: a 'light' theme for white pages (transparent canvas, ink-and-indigo colours). The tour's own look is the default.
  var TH = { skullFill: 0x1b2638, skullRim: 0xa9c2e6, skullLine: 0x7f9cc4, noseFill: 0x24334d, noseRim: 0xd3e3ff, brow: 0xbcd2f0, joint: 0xffe2b8, bone: 0xffc98a };
  var TH_LIGHT = { skullFill: 0xe4e0fb, skullRim: 0x4636c8, skullLine: 0x5a4bd6, noseFill: 0xc9c2f5, noseRim: 0x2b1f8f, brow: 0x2b1f8f, joint: 0x2b1f8f, bone: 0x4636c8 };

  var DURATIONS = { welcome: 8, look: 8, calibrate: 12, dictate: 6.4, send: 5.2, scroll: 5.6 };
  var STATIC_T = { welcome: 0.8, look: 0.8, calibrate: 3.0, dictate: 0.65, send: 2.0, scroll: 2.2 };
  var HAND_SCENES = { dictate: 1, send: 1, scroll: 1 };

  function clamp(x, a, b) { return Math.max(a, Math.min(b, x)); }
  function smooth(x) { x = clamp(x, 0, 1); return x * x * (3 - 2 * x); }
  function lerp(a, b, k) { return a + (b - a) * k; }
  var D2R = Math.PI / 180;

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
    return { gridMat: gridMat, sky: sky, floor: floor };
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
    var skullMat = track(rimMaterial(new THREE.Color(TH.skullFill), new THREE.Color(TH.skullRim), 0.5, false, 0.72));
    var skull = new THREE.Mesh(skullGeo, skullMat);
    skull.scale.set(0.9, 1.1, 1.0);
    rig.add(skull);

    var lm = track(lineMat(TH.skullLine, 0.55));
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

    var noseMat = track(rimMaterial(new THREE.Color(TH.noseFill), new THREE.Color(TH.noseRim), 0.85, false, 0.45));
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
    rig.add(new THREE.Line(browGeo, track(lineMat(TH.brow, 0.9))));

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

    function screenPoint(mon, u, v) {  // u,v in -1..1 across the screen, inset
      var p = new THREE.Vector3(u * (mon.w / 2 - 0.2), v * (mon.h / 2 - 0.2), 0.07);
      return mon.group.localToWorld(p);
    }

    // calibration dot
    var dot = new THREE.Group();
    root.add(dot);
    var dotDisc = new THREE.Mesh(track(new THREE.CircleGeometry(0.095, 28)), track(new THREE.MeshBasicMaterial({ color: ACCENT })));
    dot.add(dotDisc);
    var ringBase = new THREE.Mesh(track(new THREE.RingGeometry(0.19, 0.205, 64)), track(new THREE.MeshBasicMaterial({ color: ACCENT, transparent: true, opacity: 0.28 })));
    dot.add(ringBase);
    var ringGeo = track(new THREE.RingGeometry(0.175, 0.225, 64, 1, 0, Math.PI * 2));
    var ringFill = new THREE.Mesh(ringGeo, track(new THREE.MeshBasicMaterial({ color: 0xbfe0ff })));
    ringFill.position.z = 0.002;
    dot.add(ringFill);
    var ringIdx = 64 * 6;
    dot.visible = false;

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
    [[0, 0], [-1, 0], [1, 0], [0, 1], [0, -1]].forEach(function (uv) { CAL.push({ mon: main, u: uv[0], v: uv[1] }); });
    [[0, 0], [-1, 0], [1, 0], [0, 1], [0, -1]].forEach(function (uv) { CAL.push({ mon: port, u: uv[0], v: uv[1] }); });
    var calPos = null;
    function calPoints() {
      if (!calPos) calPos = CAL.map(function (c) {
        return { p: screenPoint(c.mon, c.u, c.v), q: c.mon.group.getWorldQuaternion(new THREE.Quaternion()) };
      });
      return calPos;
    }

    function update(name, t) {
      var st = { dot: -1, progress: 0 };
      if (name === 'calibrate') {
        var pts = calPoints();
        var slot = DURATIONS.calibrate / pts.length;   // 1.2 s
        var idx = clamp(Math.floor(t / slot), 0, pts.length - 1);
        var lt = t - idx * slot;
        var prev = pts[(idx + pts.length - 1) % pts.length];
        var cur = pts[idx];
        var mv = smooth(lt / 0.34);
        var pos = idx === 0 && t < slot ? cur.p.clone() : prev.p.clone().lerp(cur.p, mv);
        var q = prev.q.clone().slerp(cur.q, mv);
        if (idx === 0) q = cur.q.clone();
        dot.visible = true;
        dot.position.copy(pos); dot.quaternion.copy(q);
        var prog = clamp((lt - 0.36) / 0.62, 0, 1);
        ringGeo.setDrawRange(0, Math.max(0, Math.round(prog * 64)) * 6);
        var pulse = prog >= 1 ? 1 + 0.18 * Math.sin((lt - 0.98) * 18) * clamp((1.15 - lt) * 6, 0, 1) : 1;
        dotDisc.scale.setScalar(pulse);
        var aim = aimHead(pos.clone(), 0.9);
        rig.rotation.y = aim.yaw; rig.rotation.x = aim.pitch;
        setPaneHighlights([0, 0, 0, 0], true);
        st.dot = idx; st.progress = prog;
      } else {
        dot.visible = false;
        var r = lookAt(t % 8);
        rig.rotation.y = r.yaw; rig.rotation.x = r.pitch;
        setPaneHighlights(r.hl, false);
        st.hl = r.hl;
      }
      return st;
    }

    return { root: root, update: update };
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

    var jointMat = new THREE.LineBasicMaterial({ color: TH.joint, transparent: true, opacity: 0.8 });
    var boneMat = new THREE.LineBasicMaterial({ color: TH.bone, transparent: true, opacity: 0.55 });
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
    var armGeo = new THREE.CylinderGeometry(0.033, 0.03, 0.16, 24, 1, true);
    armGeo.translate(0, 0.08, 0);
    var armMat = rimMaterial(WOOD_FILL, WOOD_RIM, 0.3, false, 0.8);
    armMat.uniforms.uGrain.value = 1.0; armMat.uniforms.uFadeLen.value = 0.16;
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
    var scale = 11.5;
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
    return hand;
  }

  var AX_CURL = new THREE.Vector3(0, 0, -1);   // curl toward the palm (palm faces -x, fingers point -y)
  var AX_SPREAD = new THREE.Vector3(1, 0, 0);  // spread about the palm normal
  var qA = new THREE.Quaternion(), qB = new THREE.Quaternion(), qC = new THREE.Quaternion(), qD = new THREE.Quaternion();

  function poseHand(hand, p) {
    var W = hand.W, ch = hand.chains;
    hand.pivot.quaternion.copy(orthoBasisQuat(p.f, p.pn));
    hand.pivot.position.set(p.x, p.y, p.z);
    hand.model.updateMatrixWorld(true);
    var wristQ = W['wrist'];
    hand.bones['wrist'].quaternion.copy(wristQ);
    var curls = [p.ci, p.cm, p.cr, p.cp];
    var spreadSign = [0.5, 0.12, -0.35, -1.0];
    for (var fi = 0; fi < 4; fi++) {
      var list = ch[FINGERS[fi]];
      var c = curls[fi];
      var tune = [1, 1, 1.08, 1.15][fi];
      var ang = [0, c * 82 * D2R * tune, c * 98 * D2R * tune, c * 62 * D2R * tune, c * 62 * D2R * tune];
      ang[0] = c * 4 * D2R * fi;   // slight cupping of ring/pinky metacarpals
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
    for (var j = 0; j < tl.length; j++) {
      tcum += flex[j];
      var tw = W[tl[j].name];
      qA.setFromAxisAngle(hand.thumbFlexAxis || (hand.thumbFlexAxis = new THREE.Vector3(0.3, 0.2, -0.93).normalize()), tcum);
      qC.copy(sw).multiply(qA).multiply(tw);
      tl[j].quaternion.copy(tpose).invert().multiply(qC);
      tpose = qC.clone();
    }
    hand.model.updateMatrixWorld(true);
    // pinch via IK: thumb tip chases the index tip pad
    if (p.pinch > 0.001) {
      var names = ['thumb-metacarpal', 'thumb-phalanx-proximal', 'thumb-phalanx-distal'];
      var maxA = [hand.limits[0], hand.limits[1], hand.limits[2]];
      var fk = names.map(function (n) { return hand.bones[n].quaternion.clone(); });
      for (var it = 0; it < 16; it++) {
        hand.solver.update();   // one CCD sweep (iteration: 1)
        for (var m = 0; m < names.length; m++) {
          var bq = hand.bones[names[m]].quaternion;
          var ang = bq.angleTo(fk[m]);
          if (ang > maxA[m]) bq.copy(fk[m]).slerp(bq, maxA[m] / ang);
        }
        hand.bones[names[0]].updateMatrixWorld(true);
      }
      var k = smooth(p.pinch);
      for (var n2 = 0; n2 < names.length; n2++) {
        var ik = hand.bones[names[n2]].quaternion.clone();
        hand.bones[names[n2]].quaternion.copy(fk[n2]).slerp(ik, k);
      }
      hand.model.updateMatrixWorld(true);
    }
  }

  // ---- hand keyframes ----
  function P0() {
    return {
      ci: 0.05, cm: 0.06, cr: 0.09, cp: 0.12, spread: 0.6, swing: 0, tflex: 0, pinch: 0,
      f: new THREE.Vector3(0.18, 0.95, -0.2), pn: new THREE.Vector3(0.5, 0.08, 0.85),
      x: 0, y: 0.7, z: 0
    };
  }
  function pose(over) {
    var p = P0();
    Object.keys(over || {}).forEach(function (k) { p[k] = (over[k] && over[k].isVector3) ? over[k].clone() : over[k]; });
    return p;
  }
  function lerpPose(a, b, k) {
    var o = {};
    Object.keys(a).forEach(function (key) {
      if (a[key].isVector3) o[key] = a[key].clone().lerp(b[key], k);
      else o[key] = lerp(a[key], b[key], k);
    });
    return o;
  }
  function sampleKeys(keys, t) {
    if (t <= keys[0].t) return lerpPose(keys[0].p, keys[0].p, 0);
    for (var i = 0; i < keys.length - 1; i++) {
      if (t <= keys[i + 1].t) {
        var s = keys[i + 1].t - keys[i].t;
        return lerpPose(keys[i].p, keys[i + 1].p, s > 0 ? smooth((t - keys[i].t) / s) : 1);
      }
    }
    return lerpPose(keys[keys.length - 1].p, keys[keys.length - 1].p, 0);
  }

  var V = function (x, y, z) { return new THREE.Vector3(x, y, z); };
  var OPEN = pose({});
  var PINCH = pose({ ci: 0.66, cm: 0.3, cr: 0.38, cp: 0.46, pinch: 1, spread: 0.5, f: V(0.1, 0.92, -0.05), pn: V(-0.6, 0.05, 0.8) });
  var READY = pose({ ci: 0.2, cm: 0.15, cr: 0.2, cp: 0.26, pinch: 0.0, spread: 0.55, pn: V(-0.2, 0.05, 0.95) });
  var FIST_UP = pose({
    ci: 1, cm: 1, cr: 1, cp: 1, swing: 1, spread: 0, tflex: 0,
    f: V(-0.75, 0.0, 0.66), pn: V(0.66, 0, 0.75), x: 0.2, y: 1.45, z: 0
  });
  // pn for the thumbs-up is re-derived so the thumb (hand -z) points world up: pn = f x l with l = down
  (function () {
    var f = FIST_UP.f.clone().normalize(), l = V(0, -1, 0);
    FIST_UP.pn = new THREE.Vector3().crossVectors(f, l).normalize();
  })();

  var HAND_KEYS = {
    dictate: [
      { t: 0.0, p: OPEN }, { t: 0.5, p: OPEN }, { t: 0.65, p: PINCH }, { t: 0.8, p: READY },
      { t: 0.95, p: PINCH }, { t: 1.15, p: OPEN }, { t: 4.3, p: OPEN }, { t: 4.45, p: PINCH },
      { t: 4.6, p: READY }, { t: 4.75, p: PINCH }, { t: 4.95, p: OPEN }, { t: 6.4, p: OPEN }
    ],
    send: [
      { t: 0.0, p: OPEN }, { t: 1.0, p: FIST_UP }, { t: 3.2, p: FIST_UP }, { t: 4.2, p: OPEN }, { t: 5.2, p: OPEN }
    ],
    scroll: [
      { t: 0.0, p: OPEN }, { t: 0.6, p: PINCH }, { t: 4.4, p: PINCH }, { t: 5.6, p: OPEN }
    ]
  };

  function smoothstep01(x) { return smooth(x); }
  var STATE = {
    dictate: function (t) {
      return { listening: t >= 1.05 && t < 4.85, draft: t < 1.3 ? 0 : t > 4.3 ? 1 : smoothstep01((t - 1.3) / 3.0), hold: 0, sent: false, scroll: 0 };
    },
    send: function (t) {
      return { listening: false, draft: 0, hold: t < 1.0 ? 0 : t > 1.75 ? 1 : smoothstep01((t - 1.0) / 0.75), sent: t >= 1.75 && t < 4.2, scroll: 0 };
    },
    scroll: function (t) {
      var s;
      if (t < 0.8) s = 0;
      else if (t < 2.0) s = smoothstep01((t - 0.8) / 1.2);
      else if (t < 2.6) s = 1;
      else if (t < 3.8) s = 1 - smoothstep01((t - 2.6) / 1.2);
      else s = 0;
      return { listening: false, draft: 0, hold: 0, sent: false, scroll: s };
    }
  };
  function stateFor(name, t) {
    var f = STATE[name];
    var s = f ? f(t) : { listening: false, draft: 0, hold: 0, sent: false, scroll: 0 };
    s.scene = name; s.gesture = name; s.t = t;
    return s;
  }

  function handPoseAt(name, t) {
    var p = sampleKeys(HAND_KEYS[name], t);
    var s = STATE[name](t);
    if (name === 'scroll') {
      p.y += -0.2 + s.scroll * 1.0;
      p.f.x += s.scroll * 0.08;
    }
    // idle life: slow sway, tiny finger tremor so the hand never looks frozen
    var sway = Math.sin(t * 1.7) * 0.035;
    p.f.x += sway; p.pn.z += Math.cos(t * 1.3) * 0.03;
    var wiggle = Math.sin(t * 3.1) * 0.03;
    p.ci += wiggle * 0.5; p.cm += Math.sin(t * 2.6 + 1) * 0.03; p.cr += Math.sin(t * 2.9 + 2) * 0.03; p.cp += Math.sin(t * 3.3 + 3) * 0.035;
    if (name === 'send') { p.y += Math.sin(t * 2) * 0.02; }
    return p;
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

    var light = opts.theme === 'light';
    if (light) {
      TH = TH_LIGHT; WOOD_FILL.setHex(0x7a5cff); WOOD_RIM.setHex(0x2b1f8f);
    }
    var renderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: light, powerPreference: 'low-power' });
      if (!renderer.getContext()) throw new Error('no context');
    } catch (e) {
      var msg = document.createElement('p');
      msg.textContent = '3D preview needs WebGL, which this browser has turned off.';
      msg.style.cssText = 'margin:0;padding:24px;font:14px/1.4 system-ui,sans-serif;color:#9db0cc;text-align:center';
      container.appendChild(msg);
      return noop();
    }
    renderer.setClearColor(light ? 0xffffff : 0x04070c, light ? 0 : 1);
    container.appendChild(renderer.domElement);
    renderer.domElement.style.cssText = 'display:block;width:100%;height:100%';
    if (!container.style.position) container.style.position = 'relative';

    var scene = new THREE.Scene();
    var disposables = [];
    var stage = buildStage(scene, disposables);
    if (light) { stage.sky.visible = false; stage.floor.visible = false; }
    var desk = buildDesk(scene, disposables);
    var camera = new THREE.PerspectiveCamera(40, 1.6, 0.1, 500);
    var hand = null, handLoading = false, handFailed = false;

    var CAMS = {
      desk: { pos: new THREE.Vector3(1.2, 3.6, 4.3), look: new THREE.Vector3(-0.25, 1.45, -1.2), fov: 48 },
      hand: { pos: new THREE.Vector3(4.4, 2.5, 3.4), look: new THREE.Vector3(0.0, 1.95, 0.0), fov: 36 }
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

    var destroyed = false, paused = false, pausedAt = 0, raf = null, t0 = performance.now(), frozen = null, frozenDirty = false;

    function resize() {
      var w = container.clientWidth || 640, h = container.clientHeight || 400;
      var dpr = Math.min(window.devicePixelRatio || 1, opts.maxDpr || 2);
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
      var c = isHand ? (opts.camHand || window.__camHand || CAMS.hand) : (opts.camDesk || window.__camDesk || CAMS.desk);
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
        if (hand) { hand.pivot.visible = true; poseHand(hand, handPoseAt(name, t)); }
      } else {
        desk.root.visible = true;
        if (hand) hand.pivot.visible = false;
        extra = desk.update(name, t);
      }
      renderer.render(scene, camera);
      var st = stateFor(name, t);
      if (extra.dot !== undefined) { st.dot = extra.dot; st.progress = extra.progress; }
      if (extra.hl) st.hl = extra.hl;
      onFrame(st);
    }
    function renderNow() { renderFrame(frozen ? frozen.name : current, frozen ? frozen.t : (reduced ? STATIC_T[current] : 0), false); }

    function loop() {
      if (destroyed || paused) return;
      raf = requestAnimationFrame(loop);
      if (frozen) { if (frozenDirty) { frozenDirty = false; renderFrame(frozen.name, frozen.t, false); } return; }
      var el = (performance.now() - t0) / 1000;
      renderFrame(current, el % DURATIONS[current], true);
    }

    if (HAND_SCENES[current]) loadHand();
    if (reduced) { renderNow(); } else { raf = requestAnimationFrame(loop); }

    var handle = {
      pause: function () { if (paused || destroyed) return; paused = true; pausedAt = performance.now(); if (raf !== null) cancelAnimationFrame(raf); raf = null; },
      resume: function () { if (!paused || destroyed) return; paused = false; t0 += performance.now() - pausedAt; if (!reduced && !frozen) raf = requestAnimationFrame(loop); },
      rerender: function () { renderNow(); },
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
        renderNow();   // site copy: draw (and report) the frozen frame right away, loop running or not
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

  // Site copy: when things happen inside each loop, in seconds, so a page can tie a screen to the hand. The values restate the key times above.
  var MARKS = {
    look: { duration: DURATIONS.look, order: HEAD_ORDER_MARK() },
    dictate: { duration: DURATIONS.dictate, pinch1: 0.65, pinch2: 0.95, listening: 1.05, typeFrom: 1.3, typeTo: 4.3, stop: 4.85 },
    send: { duration: DURATIONS.send, holdFrom: 1.0, sent: 1.75, release: 4.2 },
    scroll: { duration: DURATIONS.scroll, pinch: 0.6, dragFrom: 0.8, dragTo: 2.0, release: 4.4 }
  };
  function HEAD_ORDER_MARK() { return [{ t: 0.0, p: 1 }, { t: 2.0, p: 0 }, { t: 4.0, p: 2 }, { t: 6.0, p: 3 }, { t: 8.0, p: 1 }]; }

  window.EnsembleScene = {
    MARKS: MARKS,
    mount: mount,
    _seek: function (name, t) { if (lastInstance) lastInstance._seek(name, t); },
    _last: function () { return lastInstance; }
  };
})();
