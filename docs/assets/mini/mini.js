// A small, non-interactive copy of the demo's Claude window for the letter page. It draws with the demo's own pane code and styles
// (docs/live/pane.js, pane.css, ensemble.css) and never takes input: the page feeds it a time (and the hand's state) and it shows what the
// gesture would have done. Everything is a pure function of the loop time, so a loop that restarts resets the screen by itself.

import { SESSIONS_BASE as SESSIONS } from '../../live/sessions.js';
import { buildPane, addLine, fmt, esc } from '../../live/pane.js';
// the demo's typing pace (docs/live/logic.js wordsTyped), restated here so the mini screens do not pull in the whole gesture engine
const wordsTyped = (total, elapsed, perSecond = 3.2, startDelay = 0.6) => (elapsed < startDelay ? 0 : Math.min(total, 1 + Math.floor((elapsed - startDelay) * perSecond)));

const LW_DEFAULT = 600;               // the window's width in demo pixels; the page scales the whole thing down
const byId = Object.fromEntries(SESSIONS.map((s) => [s.id, s]));
const LAYOUT = {                      // which sessions, how they are laid out, how tall a pane is
  look: { ids: ['api', 'landing', 'triage', 'research'], cols: 2, rows: 2, paneH: 232 },
  pinch: { ids: ['api', 'landing'], cols: 2, rows: 1, paneH: 400 },
  talk: { ids: ['api', 'landing'], cols: 2, rows: 1, paneH: 400 },
  send: { ids: ['api', 'landing'], cols: 2, rows: 1, paneH: 400 },
  scroll: { ids: ['api'], cols: 1, rows: 1, paneH: 380, w: 330 },
};
const TALK_LOOP = 7.2;

const ISLAND = `<svg class="ens-mark" viewBox="0 0 16 18" aria-hidden="true"><circle cx="8" cy="6.2" r="2.3"/><circle cx="4.9" cy="11.8" r="2.3"/><circle cx="11.1" cy="11.8" r="2.3"/></svg>
  <span class="ens-glyph" aria-hidden="true">
    <svg class="g-look" viewBox="0 0 26 18"><circle class="ring" cx="13" cy="9" r="6.5"/><circle class="pip" cx="13" cy="9" r="2.2"/></svg>
    <svg class="g-pinch" viewBox="0 0 26 18"><circle class="tip a" cx="9" cy="9" r="3.2"/><circle class="tip b" cx="17" cy="9" r="3.2"/></svg>
    <svg class="g-mic" viewBox="0 0 26 18"><rect x="10" y="1.5" width="6" height="10" rx="3"/><path d="M7 8.5a6 6 0 0 0 12 0M13 14.5v2" fill="none"/></svg>
    <svg class="g-send" viewBox="0 0 26 18"><path d="M5 9 21 3l-4 12-4-5z"/></svg>
    <svg class="g-check" viewBox="0 0 26 18"><path d="m6 9 4 4 9-9" fill="none"/></svg>
  </span>
  <span class="ens-text"><b class="l1"></b><span class="l2"></span></span><span class="ens-hint"></span><i class="ens-edge" aria-hidden="true"></i>`;

/** Build the mini inside `host` and return its controller. `host` must already be in the page (it measures itself). */
export function createMini(host, kind, { wave = null } = {}) {
  const lay = LAYOUT[kind]; const LW = lay.w || LW_DEFAULT;
  host.textContent = '';
  const box = document.createElement('div'); box.className = 'mini';
  const island = document.createElement('div'); island.className = 'ens-island mini-island'; island.dataset.mode = 'idle'; island.innerHTML = ISLAND;
  const win = document.createElement('div'); win.className = 'mini-win';
  const stage = document.createElement('div'); stage.className = 'mini-stage';
  stage.style.cssText = `grid-template-columns:repeat(${lay.cols},minmax(0,1fr));grid-template-rows:repeat(${lay.rows},${lay.paneH}px)`;
  const hl = document.createElement('i'); hl.className = 'ens-highlight mini-hl';
  const top = document.createElement('div'); top.className = 'mini-top'; top.append(island);
  win.append(stage, hl); box.append(top, win); host.append(box);
  box.style.width = `${LW}px`;

  const panes = lay.ids.map((id, k) => {
    const p = buildPane(byId[id], k);
    p.base = p.transcript.children.length - 1;        // lines that belong to the session itself (the last child is the "working" row)
    p.added = [];
    stage.append(p.el);
    return p;
  });
  const l1 = island.querySelector('.l1'), l2 = island.querySelector('.l2'), hint = island.querySelector('.ens-hint');

  const scaleToHost = () => {
    const s = host.clientWidth / LW || 1;
    box.style.transform = `scale(${s})`;
    host.style.height = `${box.offsetHeight * s}px`;
  };
  const ro = 'ResizeObserver' in window ? new ResizeObserver(scaleToHost) : null;
  if (ro) ro.observe(host); else addEventListener('resize', scaleToHost);
  scaleToHost();

  // ---- the small things the screen can show ----
  let islandKey = '', focusIdx = -1;
  const setIsland = (mode, a = '', b = '', h = '', style = '', fill = 0) => {
    const key = `${mode}|${a}|${b}|${h}|${style}`;
    if (key !== islandKey) {
      islandKey = key; island.dataset.mode = mode; island.dataset.style = style;
      l1.innerHTML = a; l2.innerHTML = b; hint.textContent = h;
      island.classList.remove('swap'); void island.offsetWidth; island.classList.add('swap');
    }
    island.style.setProperty('--fill', fill.toFixed(3));
  };
  const nm = (i) => `<em>${esc(panes[i].name)}</em>`;
  const setFocus = (i, listening = false) => {
    hl.classList.toggle('listening', listening);
    if (i === focusIdx) return;
    focusIdx = i;
    const r = panes[i].el;                              // pane geometry in demo pixels, relative to the window
    hl.style.width = `${r.offsetWidth - 4}px`; hl.style.height = `${r.offsetHeight - 4}px`;
    hl.style.transform = `translate(${r.offsetLeft + 2}px, ${r.offsetTop + 2}px)`;
    hl.classList.add('on');
  };
  const setDraft = (p, n) => {
    const words = p.words, text = words.slice(0, n).join(' ');
    if (text !== p.draft) { p.draft = text; p.draftEl.textContent = text; }
    p.typed = n;
  };
  const dictating = (p, on) => p.el.classList.toggle('dictating', on);
  const toBottom = (p) => { p.transcript.scrollTop = p.transcript.scrollHeight; };
  const clearAdded = (p) => { p.added.forEach((e) => e && e.remove()); p.added = []; p.workEl.classList.remove('on'); };

  // the reply to a send, as a function of seconds since the send: tool lines and code arrive whole, prose types in word by word
  const replyTimeline = (items) => {
    let t = 0.5; const out = [];
    for (const [who, text] of items) {
      if (who === 'claude') { const n = text.split(' ').length; out.push({ who, text, at: t + 0.4, n, dur: n / 7 }); t += 0.4 + n / 7 + 0.3; }
      else { out.push({ who, text, at: t }); t += 0.55; }
    }
    return out;
  };
  const showReply = (p, items, dt, final) => {
    const tl = replyTimeline(items);
    p.workEl.classList.toggle('on', !final && dt < tl[tl.length - 1].at + 0.6);
    tl.forEach((it, i) => {
      const visible = final || dt >= it.at;
      let el = p.added[i + 1];                         // added[0] is the sent bubble
      if (!visible) { if (el) { el.remove(); p.added[i + 1] = undefined; } return; }
      if (!el) { el = addLine(p, it.who, it.who === 'claude' ? '' : it.text); p.added[i + 1] = el; }
      if (it.who === 'claude') {
        const n = final ? it.n : Math.max(1, Math.min(it.n, Math.ceil((dt - it.at) * 7)));
        const html = fmt(it.text.split(' ').slice(0, n).join(' '));
        if (el.dataset.n !== String(n)) { el.dataset.n = String(n); el.innerHTML = html; el.classList.toggle('streaming', n < it.n); }
      }
    });
    toBottom(p);
  };

  let sentShown = false;
  const resetSend = (p) => { clearAdded(p); sentShown = false; };

  const wob = (t) => {                                  // the waveform beside the Talk step
    if (!wave) return;
    [...wave.children].forEach((b, i) => { const lv = 0.32 + 0.68 * Math.abs(Math.sin(t * 5.2 + i * 1.15) * Math.cos(t * 2.3 + i)); b.style.setProperty('--h', `${Math.round(lv * 100)}%`); });
  };

  // ---- one renderer per step; each is a pure function of the loop time ----
  const R = {
    look(st) {
      const hlv = st.hl || [0, 1, 0, 0];
      let best = 0; hlv.forEach((v, i) => { if (v > hlv[best]) best = i; });
      if (hlv[best] > 0.45) setFocus(best);
      setIsland('look', 'Looking at', nm(Math.max(focusIdx, 0)));
    },
    pinch(st) {
      const t = st.t, a = panes[0];
      setFocus(0, !!st.listening);
      const n = a.words.length;
      if (t < 0.65) { setIsland('look', 'Looking at', nm(0)); setDraft(a, 0); dictating(a, false); }
      else if (t < 1.05) { setIsland('firstPinch', 'Pinch again to dictate', `in ${nm(0)}`); setDraft(a, 0); dictating(a, false); }
      else if (st.listening) { setIsland('dictating', 'Claude dictation on', `in ${nm(0)}`, 'double pinch to stop'); setDraft(a, Math.ceil((st.draft || 0) * n)); dictating(a, true); }
      else { setIsland('banner', 'Dictation stopped', `Text kept in ${nm(0)}, thumbs-up to send`, '', 'stopped'); setDraft(a, n); dictating(a, false); }
    },
    talk(st) {
      const a = panes[0], T = st.t;
      setFocus(0, true); dictating(a, true);
      const n = a.words.length, typed = Math.min(n, wordsTyped(n, T));
      setIsland('dictating', 'Claude dictation on', `in ${nm(0)}`, 'double pinch to stop');
      setDraft(a, typed);
      wob(typed < n ? T : 0);
    },
    send(st, final) {
      const t = st.t, a = panes[0], n = a.words.length;
      setFocus(0); dictating(a, false);
      if (t < 1.75) {
        if (sentShown) resetSend(a);
        setDraft(a, n);
        if (t < 1.0) setIsland('look', 'Looking at', nm(0));
        else setIsland('sendHold', `Sending in ${nm(0)}`, '', 'lower to cancel', '', st.hold || 0);
        return;
      }
      if (!sentShown) {                                   // the hold completed: the draft jumps into the transcript
        setDraft(a, 0); a.draftEl.textContent = '';
        const bubble = addLine(a, 'you', a.words.join(' ')); a.added = [bubble]; sentShown = true;
      }
      const dt = t - 1.75;
      if (dt < 1.8 && !final) setIsland('banner', `Sent in ${nm(0)}`, '', '', 'sent');
      else if (final) setIsland('banner', `Sent in ${nm(0)}`, '', '', 'sent');
      else setIsland('idle');
      showReply(a, a.reply, dt, final);
    },
    scroll(st) {
      const a = panes[0];
      setFocus(0);
      setIsland('look', 'Looking at', nm(0));
      const max = a.transcript.scrollHeight - a.transcript.clientHeight;
      a.transcript.scrollTop = max * (0.22 + 0.5 * (st.scroll || 0));
    },
  };

  const settle = () => { if (kind === 'scroll') return; panes.forEach(toBottom); };
  settle();
  const resetAll = () => { sentShown = false; panes.forEach((p) => { clearAdded(p); setDraft(p, 0); dictating(p, false); }); settle(); focusIdx = -1; islandKey = ''; };
  resetAll();

  let raf = 0, t0 = 0, paused = true;
  return {
    kind, panes, island,
    /** Show the screen for this moment of the hand's loop: { t, listening, draft, hold, sent, scroll, hl } as the scene reports it. */
    update(st) { R[kind](st, false); },
    /** A still end-state frame, for reduced motion. */
    still() {
      const S = { look: { t: 1, hl: [1, 0, 0, 0] }, pinch: { t: 4.4, listening: true, draft: 1 }, talk: { t: TALK_LOOP - 1 }, send: { t: 4.6, hold: 1, sent: true }, scroll: { t: 2.3, scroll: 1 } }[kind];
      R[kind](S, true);
    },
    /** Steps with no hand scene run their own clock. */
    start() { if (!paused || kind !== 'talk') { paused = false; return; } paused = false; t0 = performance.now(); const loop = () => { if (paused) return; const T = ((performance.now() - t0) / 1000) % TALK_LOOP; R.talk({ t: T }); raf = requestAnimationFrame(loop); }; raf = requestAnimationFrame(loop); },
    pause() { paused = true; cancelAnimationFrame(raf); },
    reset() { resetAll(); },
    destroy() { paused = true; cancelAnimationFrame(raf); if (ro) ro.disconnect(); host.textContent = ''; },
  };
}
