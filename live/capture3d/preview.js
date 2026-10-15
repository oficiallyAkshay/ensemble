// The replay panel on the capture page: plays a recorded take on the 3D hand and draws its detected events under it.
// It uses only the scene module's public API (EnsembleScene.loadCapture, mount with a capture option), feature-detected, so the
// page still works, timeline and all, while an older scene module without replay is in place.

import { detectEvents, judge } from './events.js';

const $ = (id) => document.getElementById(id);
const SCENE_OF = { rest: 'rest', dictate: 'dictate', send: 'send', scroll: 'scroll', look: 'look' };

export function replaySupported() {
  const S = window.EnsembleScene;
  return !!(S && typeof S.mount === 'function' && typeof S.loadCapture === 'function' && window.THREE);
}

export function createPreview({ onKeep, onRetake, aspect = () => 16 / 9 }) {
  const stage = $('pv-stage'), note = $('pv-note'), tl = $('pv-timeline'), head = $('pv-head'), checks = $('pv-checks');
  let handle = null, cur = null, raf = 0, t0 = 0, duration = 1;

  function drawTimeline(ev) {
    tl.innerHTML = '';
    duration = Math.max(ev.durationMs, 1);
    const add = (cls, s, e, label) => {
      const el = document.createElement('i');
      el.className = 'pv-ev ' + cls; el.title = label;
      el.style.left = (s / duration) * 100 + '%'; el.style.width = Math.max(((e - s) / duration) * 100, 0.8) + '%';
      tl.append(el);
    };
    ev.pinches.forEach((p, i) => add('pinch', p.start, p.end, `Pinch ${i + 1}`));
    ev.holds.forEach((h) => add('hold', h.start, h.end, 'Thumbs-up'));
    if (ev.scroll) add('scroll', ev.scroll.start, ev.scroll.end, 'Pinch and drag');
    const ph = document.createElement('b'); ph.className = 'pv-playhead'; ph.id = 'pv-playhead'; tl.append(ph);
  }

  function tick() {
    raf = requestAnimationFrame(tick);
    const ph = $('pv-playhead'); if (!ph) return;
    ph.style.left = ((((performance.now() - t0) % duration) / duration) * 100) + '%';
  }

  function show(id, title, frames) {
    cur = id;
    const ev = detectEvents(frames, { aspect: aspect() });
    head.textContent = `${title}, replayed in a loop`;
    drawTimeline(ev);
    checks.innerHTML = '';
    for (const c of judge(id, ev)) {
      const li = document.createElement('li'); li.className = c.ok ? 'ok' : 'bad'; li.textContent = c.text; checks.append(li);
    }
    $('pv').hidden = false;
    t0 = performance.now(); cancelAnimationFrame(raf); tick();
    mountScene(id, frames);
    return ev;
  }

  function mountScene(id, frames) {
    if (handle) { handle.destroy(); handle = null; }
    stage.innerHTML = '';
    if (!replaySupported()) { note.hidden = false; note.textContent = 'Preview needs the updated scene module.'; return; }
    note.hidden = true;
    const json = { version: 1, fps: fpsOf(frames), aspect: aspect(), takes: { [id]: frames } };
    try { window.EnsembleScene.loadCapture(json); } catch (e) { console.error(e); note.hidden = false; note.textContent = 'The preview could not read this take.'; return; }
    try {
      handle = window.EnsembleScene.mount(stage, { scene: SCENE_OF[id] || id, capture: json, reducedMotion: false, onFrame() {} });
    } catch (e) { console.error(e); note.hidden = false; note.textContent = 'The 3D preview could not start.'; }
  }

  function hide() { cur = null; cancelAnimationFrame(raf); if (handle) { handle.destroy(); handle = null; } stage.innerHTML = ''; $('pv').hidden = true; }

  $('pv-keep').addEventListener('click', () => { if (cur) onKeep(cur); });
  $('pv-retake').addEventListener('click', () => { if (cur) onRetake(cur); });
  return { show, hide, get current() { return cur; } };
}

function fpsOf(frames) {
  return frames.length > 1 ? Math.round(((frames.length - 1) / (frames[frames.length - 1].t - frames[0].t)) * 1000 * 10) / 10 : 0;
}
