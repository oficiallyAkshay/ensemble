// The Talk step's little Claude screen. The tour's 3D scenes (assets/3d) draw their own Claude window for the other steps; Talk has no hand
// and no tour scene, so this builds a small non-interactive copy of the demo's window (docs/live/pane.js, pane.css, ensemble.css) and runs it
// on its own clock: the sentence types in as it is spoken, with the waveform beside it, then the loop resets.

import { SESSIONS_BASE as SESSIONS } from '../../live/sessions.js';
import { buildPane } from '../../live/pane.js';

const LW = 600;                       // the window's width in demo pixels; the page scales the whole thing down
const TALK_LOOP = 7.2;
const byId = Object.fromEntries(SESSIONS.map((s) => [s.id, s]));
// the demo's typing pace (docs/live/logic.js wordsTyped), restated here so this does not pull in the whole gesture engine
const wordsTyped = (total, elapsed, perSecond = 3.2, startDelay = 0.6) => (elapsed < startDelay ? 0 : Math.min(total, 1 + Math.floor((elapsed - startDelay) * perSecond)));

const ISLAND = `<svg class="ens-mark" viewBox="0 0 16 18" aria-hidden="true"><circle cx="8" cy="6.2" r="2.3"/><circle cx="4.9" cy="11.8" r="2.3"/><circle cx="11.1" cy="11.8" r="2.3"/></svg>
  <span class="ens-glyph" aria-hidden="true"><svg class="g-mic" viewBox="0 0 26 18"><rect x="10" y="1.5" width="6" height="10" rx="3"/><path d="M7 8.5a6 6 0 0 0 12 0M13 14.5v2" fill="none"/></svg></span>
  <span class="ens-text"><b class="l1">Claude dictation on</b><span class="l2"></span></span><span class="ens-hint">double pinch to stop</span><i class="ens-edge" aria-hidden="true"></i>`;

/** Build the screen inside `host` (already in the page: it measures itself) and return its controller. */
export function createMini(host, kind, { wave = null } = {}) {
  host.textContent = '';
  const box = document.createElement('div'); box.className = 'mini'; box.style.width = `${LW}px`;
  const island = document.createElement('div'); island.className = 'ens-island mini-island'; island.dataset.mode = 'dictating'; island.innerHTML = ISLAND;
  const top = document.createElement('div'); top.className = 'mini-top'; top.append(island);
  const win = document.createElement('div'); win.className = 'mini-win';
  const stage = document.createElement('div'); stage.className = 'mini-stage';
  stage.style.cssText = 'grid-template-columns:repeat(2,minmax(0,1fr));grid-template-rows:400px';
  const hl = document.createElement('i'); hl.className = 'ens-highlight mini-hl on listening';
  win.append(stage, hl); box.append(top, win); host.append(box);
  const panes = ['api', 'landing'].map((id, k) => { const p = buildPane(byId[id], k); stage.append(p.el); return p; });
  const a = panes[0];
  island.querySelector('.l2').innerHTML = `in <em>${a.name}</em>`;
  const place = () => { hl.style.width = `${a.el.offsetWidth - 4}px`; hl.style.height = `${a.el.offsetHeight - 4}px`; hl.style.transform = `translate(${a.el.offsetLeft + 2}px, ${a.el.offsetTop + 2}px)`; };
  place(); a.el.classList.add('dictating');
  const toBottom = (p) => { p.transcript.scrollTop = p.transcript.scrollHeight; };
  panes.forEach(toBottom);

  const scaleToHost = () => { const s = host.clientWidth / LW || 1; box.style.transform = `scale(${s})`; host.style.height = `${box.offsetHeight * s}px`; };
  const ro = 'ResizeObserver' in window ? new ResizeObserver(scaleToHost) : null;
  if (ro) ro.observe(host); else addEventListener('resize', scaleToHost);
  scaleToHost();

  const show = (T) => {
    const n = a.words.length, typed = Math.min(n, wordsTyped(n, T)), text = a.words.slice(0, typed).join(' ');
    if (text !== a.draft) { a.draft = text; a.draftEl.textContent = text; }
    if (wave) [...wave.children].forEach((b, i) => { const lv = 0.32 + 0.68 * Math.abs(Math.sin((typed < n ? T : 0) * 5.2 + i * 1.15) * Math.cos(T * 2.3 + i)); b.style.setProperty('--h', `${Math.round(lv * 100)}%`); });
  };
  let raf = 0, t0 = 0, paused = true;
  return {
    kind, panes, island,
    /** Show the screen at second `st.t` of its loop. */
    update(st) { show(st.t); },
    /** A still end-state frame, for reduced motion. */
    still() { show(TALK_LOOP - 1); },
    start() { if (!paused) return; paused = false; t0 = performance.now(); const loop = () => { if (paused) return; show(((performance.now() - t0) / 1000) % TALK_LOOP); raf = requestAnimationFrame(loop); }; raf = requestAnimationFrame(loop); },
    pause() { paused = true; cancelAnimationFrame(raf); },
    destroy() { paused = true; cancelAnimationFrame(raf); if (ro) ro.disconnect(); host.textContent = ''; },
  };
}
