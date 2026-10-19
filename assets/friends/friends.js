// The notification tiles on the table: placed like they were thrown, and they can be picked up and flung. Pointer drag with momentum, spin from the
// throw, bounce off the table's edges; arrow keys give a push. Tiles with `sample: true` stay hidden unless the page address has ?samples=1.
import { MESSAGES } from './messages.js';
import { track } from '../../analytics.js';

const root = document.getElementById('friends');
const showSamples = new URLSearchParams(location.search).get('samples') === '1';
const items = MESSAGES.filter((m) => showSamples || !m.sample);

if (!root || !items.length) {
  root?.remove();
} else {
  const table = root.querySelector('.table');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  // the generic contact avatar iOS shows with no photo: head and shoulders on grey. Never a real person's picture.
  const PERSON = '<svg viewBox="0 0 52 52" aria-hidden="true"><circle cx="26" cy="20" r="9" fill="#e9e9ee"/><path d="M8 46c1.500-10 9-14 18-14s16.500 4 18 14c-5 5-11 7-18 7s-13-2-18-7z" fill="#e9e9ee"/></svg>';
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // the same scatter every visit: a small seeded generator
  let seed = 7;
  const rnd = () => { seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };

  let z = items.length;
  const tiles = items.map((m, i) => {
    const el = document.createElement('article');
    el.className = 'imsg'; el.tabIndex = 0; el.setAttribute('role', 'group'); el.setAttribute('aria-label', `${m.from}: ${m.text}`);
    el.innerHTML = `<span class="avatar">${PERSON}</span><div><div class="top"><span class="from">${esc(m.from)}</span><time>${esc(m.time || 'now')}</time></div><p class="body">${esc(m.text)}</p></div>`;
    table.append(el);
    const base = (rnd() - 0.5) * 16;
    return { el, x: 0, y: 0, vx: 0, vy: 0, rot: base, base, vr: 0, w: 0, h: 0, held: null, z: i + 1 };
  });

  // The table is where they land, not a fence: a tile can hang off its edges and be dragged or thrown a good way past them (up to 45% of its width
  // sideways and 70 px up or down), so it stays grabbable and on the page.
  const overX = (t) => t.w * 0.45, OVER_Y = 70;
  // ...but never past the edge of the window itself
  const minX = (t) => Math.max(-overX(t), 8 - table.getBoundingClientRect().left);
  const maxX = (t) => Math.min(table.clientWidth - t.w + overX(t), document.documentElement.clientWidth - 8 - table.getBoundingClientRect().left - t.w);
  const minY = () => -OVER_Y, maxY = (t) => table.clientHeight - t.h + OVER_Y;
  const clampX = (t, x) => Math.min(Math.max(x, minX(t)), maxX(t));
  const clampY = (t, y) => Math.min(Math.max(y, minY()), maxY(t));
  const paint = (t) => { t.el.style.transform = `translate3d(${t.x.toFixed(1)}px, ${t.y.toFixed(1)}px, 0) rotate(${t.rot.toFixed(2)}deg)`; t.el.style.zIndex = t.z; };

  /** Scatter the tiles across the table in loose rows. On a narrow table they overlap more, like a pile. */
  function layout() {
    const W = table.clientWidth;
    for (const t of tiles) { t.w = t.el.offsetWidth; t.h = t.el.offsetHeight; }
    const cols = Math.max(1, Math.floor(W / (tiles[0].w * 0.92)));
    const rows = Math.ceil(tiles.length / cols);
    // each row is as tall as its tallest tile (a little overlapped), so a long text never lands on the row below it
    const rowTop = [0];
    for (let r = 0; r < rows; r++) rowTop.push(rowTop[r] + Math.max(...tiles.slice(r * cols, r * cols + cols).map((t) => t.h)) * 0.9);
    table.style.height = `${Math.max(Math.round(rowTop[rows] + 70), W < 560 ? 0 : 520)}px`;
    const H = table.clientHeight, cellW = (W - tiles[0].w) / Math.max(cols - 1, 1), top = Math.max((H - rowTop[rows]) / 2, 8);
    seed = 7;
    tiles.forEach((t, i) => {
      const c = i % cols, r = Math.floor(i / cols), offset = r % 2 ? cellW * 0.35 : 0;
      // the outer columns start part-way off the table, as if thrown a little too hard
      const hang = cols === 1 ? (i % 2 ? 1 : -1) * t.w * 0.1 : c === 0 ? -t.w * 0.22 : c === cols - 1 ? t.w * 0.22 : 0;
      t.x = clampX(t, (cols === 1 ? (W - t.w) / 2 : c * cellW + offset) + hang + (rnd() - 0.5) * 30);
      t.y = clampY(t, top + rowTop[r] + (rnd() - 0.5) * 24 + (r === rows - 1 ? 34 : 0));
      t.vx = t.vy = t.vr = 0; paint(t);
    });
  }

  // ---- motion: after a throw the tile keeps going, slows with friction, spins down, and bounces off the edges ----
  let raf = 0, last = 0;
  const FRICTION = 2.4, SPIN_FRICTION = 3, BOUNCE = 0.5, MAX_V = 3200;
  function frame(now) {
    const dt = Math.min((now - last) / 1000, 0.05); last = now;
    let moving = false;
    for (const t of tiles) {
      if (t.held) continue;
      if (Math.hypot(t.vx, t.vy) < 6 && Math.abs(t.vr) < 1.5) { t.vx = t.vy = t.vr = 0; continue; }
      t.x += t.vx * dt; t.y += t.vy * dt; t.rot += t.vr * dt;
      const f = Math.exp(-FRICTION * dt), g = Math.exp(-SPIN_FRICTION * dt);
      t.vx *= f; t.vy *= f; t.vr *= g;
      const x0 = minX(t), x1 = maxX(t), y0 = minY(), y1 = maxY(t);
      if (t.x < x0) { t.x = x0; t.vx = Math.abs(t.vx) * BOUNCE; t.vr *= -0.6; } else if (t.x > x1) { t.x = x1; t.vx = -Math.abs(t.vx) * BOUNCE; t.vr *= -0.6; }
      if (t.y < y0) { t.y = y0; t.vy = Math.abs(t.vy) * BOUNCE; } else if (t.y > y1) { t.y = y1; t.vy = -Math.abs(t.vy) * BOUNCE; }
      paint(t); moving = true;
    }
    raf = moving ? requestAnimationFrame(frame) : 0;
  }
  const kick = () => { if (!raf) { last = performance.now(); raf = requestAnimationFrame(frame); } };

  // ---- picking up and throwing ----
  for (const t of tiles) {
    const el = t.el;
    el.addEventListener('pointerdown', (e) => {
      if (e.button > 0) return;
      track('contacts_played');
      el.setPointerCapture(e.pointerId);
      const r = table.getBoundingClientRect();
      t.held = { dx: e.clientX - r.left - t.x, dy: e.clientY - r.top - t.y, trail: [{ t: e.timeStamp, x: t.x, y: t.y }] };
      t.vx = t.vy = t.vr = 0; t.z = ++z; el.classList.add('held'); paint(t);
    });
    el.addEventListener('pointermove', (e) => {
      if (!t.held) return;
      const r = table.getBoundingClientRect(), h = t.held;
      t.x = clampX(t, e.clientX - r.left - h.dx); t.y = clampY(t, e.clientY - r.top - h.dy);
      h.trail.push({ t: e.timeStamp, x: t.x, y: t.y }); while (h.trail.length > 2 && e.timeStamp - h.trail[0].t > 90) h.trail.shift();
      // lean into the drag; it settles back when let go
      const a = h.trail[0], dt = Math.max(e.timeStamp - a.t, 1) / 1000;
      t.rot += (t.base + Math.max(-14, Math.min(14, ((t.x - a.x) / dt) * 0.012)) - t.rot) * 0.15;
      paint(t);
    });
    const release = (e) => {
      const h = t.held; if (!h) return;
      t.held = null; el.classList.remove('held');
      const a = h.trail[0], b = h.trail[h.trail.length - 1], dt = (b.t - a.t) / 1000;
      if (!reduce && dt > 0.01 && e.timeStamp - b.t < 120) {
        t.vx = Math.max(-MAX_V, Math.min(MAX_V, (b.x - a.x) / dt)); t.vy = Math.max(-MAX_V, Math.min(MAX_V, (b.y - a.y) / dt));
        t.vr = Math.max(-260, Math.min(260, t.vx * 0.06));
        kick();
      }
    };
    el.addEventListener('pointerup', release); el.addEventListener('pointercancel', release);
    el.addEventListener('keydown', (e) => {
      const d = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
      if (!d) return;
      e.preventDefault(); t.z = ++z;
      if (reduce) { t.x = clampX(t, t.x + d[0] * 40); t.y = clampY(t, t.y + d[1] * 40); paint(t); } else { t.vx += d[0] * 700; t.vy += d[1] * 700; t.vr += d[0] * 40; kick(); }
    });
  }

  // longer texts start on top of the pile, so the most to read is not the most buried
  [...tiles].sort((a, b) => a.el.textContent.length - b.el.textContent.length).forEach((t, i) => { t.z = i + 1; });
  z = tiles.length;
  root.hidden = false;
  layout();
  let width = table.clientWidth;
  new ResizeObserver(() => { if (table.clientWidth !== width) { width = table.clientWidth; layout(); } }).observe(table);
  document.fonts?.ready.then(layout);   // tile heights change once the page fonts arrive
}
