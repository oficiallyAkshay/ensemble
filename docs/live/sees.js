// "What Ensemble sees": the tracking skeleton on a plain background, never the camera picture.
// Face: a sparse wireframe (outline, eyes, nose bridge, a few dots). Hand: 21 points and their bones.
// Mirrored so it moves like a mirror. Colours come from CSS custom properties on the canvas.

import { HAND_BONES } from './logic.js';

const OVAL = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109];
const EYE_L = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466];
const EYE_R = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246];
const BRIDGE = [168, 6, 197, 195, 5, 4];
const EXTRA_DOTS = [61, 291, 1];

export const FACE_DOTS = [...new Set([...OVAL.filter((_, i) => i % 2 === 0), ...EYE_L.filter((_, i) => i % 4 === 0), ...EYE_R.filter((_, i) => i % 4 === 0), ...BRIDGE, ...EXTRA_DOTS])];

// A resting skeleton for when nothing is tracked (camera off, mouse mode, no face or hand found yet): the panel never sits empty.
// A face wireframe that sways a little and an open hand that pinches now and then, built from the same landmark ids the trackers
// give, so it is drawn by the same code as the real thing. Made up, not recorded: no data file ships for it.
const HAND_REST = [
  [0, 0], [-0.05, -0.04], [-0.09, -0.08], [-0.12, -0.11], [-0.14, -0.14],
  [-0.03, -0.10], [-0.035, -0.16], [-0.04, -0.20], [-0.045, -0.24],
  [0, -0.11], [0, -0.17], [0, -0.22], [0, -0.26],
  [0.03, -0.10], [0.035, -0.155], [0.04, -0.20], [0.045, -0.235],
  [0.06, -0.08], [0.07, -0.12], [0.08, -0.15], [0.09, -0.18],
];

export function idlePose(sec) {
  const lm = Array.from({ length: 468 }, () => ({ x: 0.5, y: 0.5 }));
  const yaw = Math.sin(sec * 0.8) * 0.025, pitch = Math.sin(sec * 0.55 + 1) * 0.012;
  const cx = 0.66 + yaw, cy = 0.31 + pitch, rx = 0.12, ry = 0.19;
  OVAL.forEach((id, i) => { const a = -Math.PI / 2 + (i * 2 * Math.PI) / OVAL.length; lm[id] = { x: cx + rx * Math.cos(a), y: cy + ry * Math.sin(a) }; });
  const eye = (ids, ex) => ids.forEach((id, i) => { const a = (i * 2 * Math.PI) / ids.length; lm[id] = { x: ex + 0.026 * Math.cos(a), y: cy - 0.04 + 0.012 * Math.sin(a) }; });
  eye(EYE_L, cx + 0.058 + yaw); eye(EYE_R, cx - 0.058 + yaw);
  BRIDGE.forEach((id, i) => { const k = i / (BRIDGE.length - 1); lm[id] = { x: cx + yaw * 1.6 * k, y: cy - 0.05 + 0.095 * k }; });
  lm[1] = { x: cx + yaw * 1.6, y: cy + 0.05 }; lm[61] = { x: cx - 0.04, y: cy + 0.12 }; lm[291] = { x: cx + 0.04, y: cy + 0.12 };
  // The hand: open, then the thumb tip meets the index tip for a moment.
  const pinch = Math.max(0, Math.min(1, (Math.sin(sec * 1.1) - 0.25) / 0.5));
  const hx = 0.27, hy = 0.74 + Math.sin(sec * 0.9) * 0.01;
  const points = HAND_REST.map(([dx, dy]) => ({ x: hx + dx, y: hy + dy }));
  for (const i of [2, 3, 4]) { const t = points[8]; points[i] = { x: points[i].x + (t.x - points[i].x) * pinch * (i / 4), y: points[i].y + (t.y - points[i].y) * pinch * (i / 4) }; }
  return { face: { landmarks: lm }, hand: { points, closed: pinch > 0.92 } };
}

function css(el, name, fallback) {
  const v = getComputedStyle(el).getPropertyValue(name).trim();
  return v || fallback;
}

export class SeesPanel {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.aspect = 4 / 3;
    this.colors = null;
    this.resize();
    // The panel starts hidden (display: none measures as 0 by 0), so the bitmap was made 1 px wide and stayed that way when the panel
    // appeared: a flat grey box with nothing drawn. Resize whenever the box really changes size.
    if (typeof ResizeObserver === 'function') new ResizeObserver(() => this.resize()).observe(canvas);
  }

  resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const r = this.canvas.getBoundingClientRect();
    this.w = Math.max(1, Math.round(r.width)); this.h = Math.max(1, Math.round(r.height));
    this.canvas.width = Math.round(this.w * dpr); this.canvas.height = Math.round(this.h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.colors = null;
  }

  palette() {
    if (!this.colors) {
      const c = this.canvas;
      this.colors = {
        bg: css(c, '--ls-sees-bg', '#0d0d10'), face: css(c, '--ls-sees-face', '#8e8e99'), ray: css(c, '--ls-sees-ray', '#5aa0ff'),
        hand: css(c, '--ls-sees-hand', '#d6d6dd'), joint: css(c, '--ls-sees-joint', '#ffffff'), pinch: css(c, '--ls-sees-pinch', '#5aa0ff'),
        text: css(c, '--ls-sees-text', '#6c6c78'),
      };
    }
    return this.colors;
  }

  /** Maps a normalised camera point to canvas pixels, mirrored, letterboxed to the camera's aspect. */
  project(p) {
    const boxW = Math.min(this.w, this.h * this.aspect), boxH = boxW / this.aspect;
    return { x: (this.w - boxW) / 2 + (1 - p.x) * boxW, y: (this.h - boxH) / 2 + p.y * boxH, s: boxW };
  }

  /** `face`: {landmarks}; `hand`: {points, closed, pinch}; either may be null. `note` is shown when nothing is tracked. */
  draw({ face, hand, note }) {
    const { ctx } = this, k = this.palette();
    ctx.clearRect(0, 0, this.w, this.h);
    ctx.fillStyle = k.bg; ctx.fillRect(0, 0, this.w, this.h);
    if (face) this.drawFace(face.landmarks, k);
    if (hand) this.drawHand(hand, k);
    if (!face && !hand) {
      const idle = idlePose(performance.now() / 1000);
      ctx.save(); ctx.globalAlpha = 0.55; this.drawFace(idle.face.landmarks, k); this.drawHand(idle.hand, k); ctx.restore();
    }
    if (!face && !hand && note) {
      ctx.fillStyle = k.text; ctx.font = '13px system-ui, sans-serif'; ctx.textAlign = 'center';
      const lines = []; let cur = '';
      for (const word of note.split(' ')) {
        if (cur && ctx.measureText(`${cur} ${word}`).width > this.w - 24) { lines.push(cur); cur = word; } else cur = cur ? `${cur} ${word}` : word;
      }
      lines.push(cur);
      lines.forEach((l, i) => ctx.fillText(l, this.w / 2, this.h - 10 - (lines.length - 1 - i) * 17));
      ctx.textAlign = 'start';
    }
  }

  line(ids, lm, close) {
    const { ctx } = this;
    ctx.beginPath();
    ids.forEach((id, i) => { const q = this.project(lm[id]); if (i) ctx.lineTo(q.x, q.y); else ctx.moveTo(q.x, q.y); });
    if (close) ctx.closePath();
    ctx.stroke();
  }

  drawFace(lm, k) {
    const { ctx } = this;
    ctx.lineWidth = 1.25; ctx.strokeStyle = k.face; ctx.lineJoin = 'round';
    this.line(OVAL, lm, true); this.line(EYE_L, lm, true); this.line(EYE_R, lm, true); this.line(BRIDGE, lm, false);
    ctx.fillStyle = k.face;
    for (const id of FACE_DOTS) { const q = this.project(lm[id]); ctx.beginPath(); ctx.arc(q.x, q.y, 1.8, 0, Math.PI * 2); ctx.fill(); }
    // Nose direction: from the middle of the face through the nose tip.
    const c = { x: (lm[234].x + lm[454].x + lm[10].x + lm[152].x) / 4, y: (lm[234].y + lm[454].y + lm[10].y + lm[152].y) / 4 };
    const tip = this.project(lm[4]), mid = this.project(c);
    const dx = tip.x - mid.x, dy = tip.y - mid.y, len = Math.hypot(dx, dy) || 1;
    const faceW = Math.abs(this.project(lm[454]).x - this.project(lm[234]).x);
    const reach = faceW * (0.55 + Math.min(len / faceW, 0.4) * 3);
    const ex = tip.x + (dx / len) * reach, ey = tip.y + (dy / len) * reach;
    ctx.strokeStyle = k.ray; ctx.fillStyle = k.ray; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(tip.x, tip.y); ctx.lineTo(ex, ey); ctx.stroke();
    ctx.beginPath(); ctx.arc(tip.x, tip.y, 3.2, 0, Math.PI * 2); ctx.fill();
    const a = Math.atan2(ey - tip.y, ex - tip.x);
    ctx.beginPath(); ctx.moveTo(ex, ey); ctx.lineTo(ex - 8 * Math.cos(a - 0.45), ey - 8 * Math.sin(a - 0.45)); ctx.lineTo(ex - 8 * Math.cos(a + 0.45), ey - 8 * Math.sin(a + 0.45)); ctx.closePath(); ctx.fill();
  }

  drawHand({ points, closed }, k) {
    const { ctx } = this;
    ctx.lineWidth = 1.6; ctx.strokeStyle = k.hand;
    for (const [a, b] of HAND_BONES) {
      const p = this.project(points[a]), q = this.project(points[b]);
      ctx.beginPath(); ctx.moveTo(p.x, p.y); ctx.lineTo(q.x, q.y); ctx.stroke();
    }
    points.forEach((pt, i) => {
      const q = this.project(pt), tip = i === 4 || i === 8;
      ctx.fillStyle = tip && closed ? k.pinch : tip ? k.joint : k.hand;
      ctx.beginPath(); ctx.arc(q.x, q.y, tip ? 4 : 2.6, 0, Math.PI * 2); ctx.fill();
    });
    if (closed) {
      const a = this.project(points[4]), b = this.project(points[8]);
      ctx.strokeStyle = k.pinch; ctx.lineWidth = 2.5; ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
    }
  }
}
