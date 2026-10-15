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
    if (!face && !hand && note) {
      ctx.fillStyle = k.text; ctx.font = '13px system-ui, sans-serif'; ctx.textAlign = 'center';
      const lines = []; let cur = '';
      for (const word of note.split(' ')) {
        if (cur && ctx.measureText(`${cur} ${word}`).width > this.w - 24) { lines.push(cur); cur = word; } else cur = cur ? `${cur} ${word}` : word;
      }
      lines.push(cur);
      lines.forEach((l, i) => ctx.fillText(l, this.w / 2, this.h / 2 + (i - (lines.length - 1) / 2) * 18));
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
