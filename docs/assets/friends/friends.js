// The notification tiles on the table: placed like they were thrown, and they can be picked up and flung. Pointer drag with momentum, spin from the
// throw, bounce off the table's edges; arrow keys give a push. Tiles with `sample: true` stay hidden unless the page address has ?samples=1.
import { MESSAGES } from './messages.js';

const root = document.getElementById('friends');
const showSamples = new URLSearchParams(location.search).get('samples') === '1';
const items = MESSAGES.filter((m) => showSamples || !m.sample);

if (!root || !items.length) {
  root?.remove();
} else {
  const table = root.querySelector('.table');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const BUBBLE = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3C6.5 3 2 6.6 2 11.1c0 2.5 1.4 4.7 3.6 6.2-.2 1.2-.9 2.400-1.800 3.300 1.900-.1 3.500-.9 4.700-1.800 1.100.3 2.300.5 3.500.5 5.500 0 10-3.600 10-8.100S17.500 3 12 3z"/></svg>';
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // the same scatter every visit: a small seeded generator
  let seed = 7;
  const rnd = () => { seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };

  let z = items.length;
  const tiles = items.map((m, i) => {
    const el = document.createElement('article');
    el.className = 'imsg'; el.tabIndex = 0; el.setAttribute('role', 'group'); el.setAttribute('aria-label', `${m.from}: ${m.text}`);
    el.innerHTML = `<span class="app">${BUBBLE}</span><div><div class="top"><span class="from">${esc(m.from)}</span><time>${esc(m.time || 'now')}</time></div><p class="body">${esc(m.text)}</p></div>`;
    table.append(el);
    const base = (rnd() - 0.5) * 16;
    return { el, x: 0, y: 0, vx: 0, vy: 0, rot: base, base, vr: 0, w: 0, h: 0, held: null, z: i + 1 };
  });

  const clampX = (t, x) => Math.min(Math.max(x, 0), Math.max(table.clientWidth - t.w, 0));
  const clampY = (t, y) => Math.min(Math.max(y, 0), Math.max(table.clientHeight - t.h, 0));
  const paint = (t) => { t.el.style.transform = `translate3d(${t.x.toFixed(1)}px, ${t.y.toFixed(1)}px, 0) rotate(${t.rot.toFixed(2)}deg)`; t.el.style.zIndex = t.z; };

  /** Scatter the tiles across the table in loose rows. On a narrow table they overlap more, like a pile. */
  function layout() {
    const W = table.clientWidth;
    for (const t of tiles) { t.w = t.el.offsetWidth; t.h = t.el.offsetHeight; }
    const cols = Math.max(1, Math.floor(W / (tiles[0].w * 0.92)));
    const rows = Math.ceil(tiles.length / cols);
    const rowH = Math.max(...tiles.map((t) => t.h)) * 0.86;
    if (W < 560) table.style.height = `${Math.round(rows * rowH + 120)}px`; else table.style.height = '';
    const H = table.clientHeight, cellW = (W - tiles[0].w) / Math.max(cols - 1, 1), top = Math.max((H - ((rows - 1) * rowH + tiles[0].h)) / 2, 8);
    seed = 7;
    tiles.forEach((t, i) => {
      const c = i % cols, r = Math.floor(i / cols), offset = r % 2 ? cellW * 0.35 : 0;
      t.x = clampX(t, (cols === 1 ? (W - t.w) / 2 : c * cellW + offset) + (rnd() - 0.5) * 36);
      t.y = clampY(t, top + r * rowH + (rnd() - 0.5) * 30);
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
      const mx = Math.max(table.clientWidth - t.w, 0), my = Math.max(table.clientHeight - t.h, 0);
      if (t.x < 0) { t.x = 0; t.vx = Math.abs(t.vx) * BOUNCE; t.vr *= -0.6; } else if (t.x > mx) { t.x = mx; t.vx = -Math.abs(t.vx) * BOUNCE; t.vr *= -0.6; }
      if (t.y < 0) { t.y = 0; t.vy = Math.abs(t.vy) * BOUNCE; } else if (t.y > my) { t.y = my; t.vy = -Math.abs(t.vy) * BOUNCE; }
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

  root.hidden = false;
  layout();
  let width = table.clientWidth;
  new ResizeObserver(() => { if (table.clientWidth !== width) { width = table.clientWidth; layout(); } }).observe(table);
  document.fonts?.ready.then(layout);   // tile heights change once the page fonts arrive
}
