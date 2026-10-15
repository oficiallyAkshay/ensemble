// The live stage: four mock Claude sessions driven by head and hands (camera) or by the mouse (fallback).
// Wiring only; the rules live in logic.js (ported from the Mac app), the models in tracker.js, the skeleton in sees.js.

import {
  GestureMachine, FocusTracker, FOCUS, sessionAt, HeadPointer, CentreStep, PinchAdapt, FrameScheduler, PointerHand, islandMode, wordsTyped,
  observationFromHand, handFromLandmarks,
} from './logic.js';
import { SESSIONS } from './content.js';
import { SeesPanel } from './sees.js';
import { Trackers, unsupportedReason, TOTAL_BYTES } from './tracker.js';

const $ = (id) => document.getElementById(id);
const el = {
  app: $('app'), stage: $('stage'), island: $('island'), gate: $('gate'), gateMsg: $('gate-message'), goCamera: $('go-camera'),
  goMouse: $('go-mouse'), progress: $('progress'), bar: $('bar'), progressLabel: $('progress-label'), coach: $('coach'),
  prompt: $('prompt'), ticks: $('ticks'), done: $('done'), finish: $('finish'), keep: $('keep'), stop: $('stop'), recentre: $('recentre'),
  sink: $('sink'), sees: $('sees'), hl: $('hl'), dot: $('dot'),
  centre: $('centre'), centreLine: $('centre-line'), centreCount: $('centre-count'), centreArc: $('centre-arc'), centreSkip: $('centre-skip'), rPinch: $('r-pinch'),
  rHead: $('r-head'), rHand: $('r-hand'), rGesture: $('r-gesture'), rSpeed: $('r-speed'), sizeNote: $('size-note'),
};
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const now = () => performance.now() / 1000;

// ---- panes ----------------------------------------------------------------------------------------------

const ICON = {
  terminal: '<path d="m4 6 5 4-5 4M11 15h6"/>', panel: '<rect x="3.5" y="4" width="13" height="12" rx="2.5"/><path d="M11.5 4v12"/>', globe: '<circle cx="10" cy="10" r="6.8"/><path d="M3.2 10h13.6M10 3.2c2.6 2.6 2.6 11 0 13.6M10 3.2c-2.6 2.6-2.6 11 0 13.6"/>',
  folder: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h3.2l1.6 1.8h6.2A1.5 1.5 0 0 1 17 8.3v6.2a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 3 14.500z"/>',
  more: '<circle cx="10" cy="4.5" r=".6"/><circle cx="10" cy="10" r=".6"/><circle cx="10" cy="15.5" r=".6"/>', close: '<path d="m5 5 10 10M15 5 5 15"/>',
  sidebar: '<rect x="3" y="4" width="14" height="12" rx="2.5"/><path d="M8 4v12"/>', back: '<path d="M16 10H4.500m4.500-4.500L4.500 10 9 14.500"/>', fwd: '<path d="M4 10h11.500M11 5.500 15.500 10 11 14.500"/>',
  chev: '<path d="m5 8 5 5 5-5"/>', plus: '<path d="M10 4v12M4 10h12"/>', rec: '<circle cx="10" cy="10" r="7"/><circle cx="10" cy="10" r="2.6" fill="currentColor"/>',
  mic: '<rect x="7.500" y="3" width="5" height="9" rx="2.500"/><path d="M4.500 10a5.500 5.500 0 0 0 11 0M10 15.500V17.500"/>',
};
/** Light inline formatting for Claude's text: **bold** and `code`, only once both marks are present. */
const fmt = (t) => esc(t).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/`(.+?)`/g, '<code>$1</code>');
const ic = (n, cls = '') => `<svg class="ic ${cls}" viewBox="0 0 20 20" aria-hidden="true">${ICON[n]}</svg>`;
const MODES = ['Opus 5.5', 'Sonnet 5.5', 'Opus 5.5', 'Sonnet 5.5'], EFFORT = ['Medium', 'High', 'Medium', 'Low'];
const panes = SESSIONS.map((s, k) => {
  const root = document.createElement('article');
  root.className = 'ls-pane'; root.dataset.id = s.id;
  root.innerHTML = `<header class="ls-ph">
      ${k === 0 ? `<span class="ls-lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="ls-nav x1">${ic('sidebar')}${ic('back')}${ic('fwd')}</span>` : ''}
      <button type="button" class="ls-title" tabindex="-1"><span>${esc(s.name)}</span>${ic('chev')}</button>
      <span class="ls-icons">${ic('terminal', 'x2')}${ic('panel', 'x2')}${ic('globe', 'x1')}${ic('folder')}${ic('more')}${ic('close')}</span>
    </header>
    <div class="ls-transcript" tabindex="-1"><div class="ls-working"><span class="gl"><i></i><i></i><i></i><i></i></span><span class="wl">Running a command</span></div></div>
    <div class="ls-composer">${ic('plus')}<span class="draft"></span>${ic('rec')}${ic('mic', 'mic')}</div>
    <div class="ls-foot"><span>Bypass permissions</span><span class="sp">${esc(MODES[k])}</span><span>${EFFORT[k]}</span><i class="ring"></i></div>`;
  el.stage.append(root);
  const pane = {
    id: s.id, name: s.name, el: root, transcript: root.querySelector('.ls-transcript'), draftEl: root.querySelector('.draft'), workEl: root.querySelector('.ls-working'),
    draft: '', prompts: s.prompts, promptIdx: 0, typed: 0, streams: 0, frame: { x: 0, y: 0, w: 0, h: 0 },
    get words() { return this.prompts[this.promptIdx % this.prompts.length].say.split(' '); },
    get reply() { return this.prompts[this.promptIdx % this.prompts.length].reply; },
  };
  for (const [who, text] of s.transcript) addLine(pane, who, text);
  return pane;
});


function addLine(pane, who, text) {
  let p;
  if (who === 'list') { p = document.createElement('ul'); p.className = 'ls-line list'; p.innerHTML = text.map((t) => `<li>${fmt(t)}</li>`).join(''); }
  else if (who === 'table') {
    p = document.createElement('div'); p.className = 'ls-line tablewrap';
    p.innerHTML = `<table><thead><tr>${text.head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${text.rows.map((r) => `<tr>${r.map((c) => `<td>${esc(c)}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
  } else {
    p = document.createElement(who === 'code' ? 'pre' : 'p');
    p.className = `ls-line ${who}`;
    if (who === 'claude') p.innerHTML = fmt(text); else p.textContent = text;
  }
  pane.transcript.insertBefore(p, pane.workEl);
  return p;
}

const stick = (pane) => { pane.transcript.scrollTop = pane.transcript.scrollHeight; };

/** A mock Claude reply streaming into a session: tool lines and code appear whole, prose types word by word. */
function streamReply(pane, items) {
  pane.streams += 1; pane.workEl.classList.add('on'); stick(pane);
  let k = 0;
  const next = () => {
    if (k >= items.length) { if (--pane.streams === 0) pane.workEl.classList.remove('on'); return; }
    const [who, text] = items[k++];
    if (who !== 'claude') { addLine(pane, who, text); stick(pane); setTimeout(next, 550); return; }
    const line = addLine(pane, 'claude', ''); line.classList.add('streaming');
    const words = text.split(' '); let n = 0;
    const tick = () => {
      line.innerHTML = fmt(words.slice(0, ++n).join(' ')); stick(pane);
      if (n < words.length) setTimeout(tick, 55); else { line.classList.remove('streaming'); setTimeout(next, 350); }
    };
    tick();
  };
  setTimeout(next, 700);
}

function setDraft(pane, text) {
  pane.draft = text; pane.draftEl.textContent = text;
}

function refreshFrames() {
  for (const p of panes) { const r = p.el.getBoundingClientRect(); p.frame = { x: r.left, y: r.top, w: r.width, h: r.height }; }
}

// ---- state ----------------------------------------------------------------------------------------------

const S = {
  mode: 'none',                 // none | camera | mouse
  tracking: false, busy: false, resumeOnShow: false,
  machine: new GestureMachine(), focus: new FocusTracker(), head: new HeadPointer(), scheduler: new FrameScheduler(),
  pointerHand: new PointerHand(), mouse: null,
  dict: null, banner: null, focusSince: 0, focusId: null,
  faceSeen: null, handSeen: null, headText: 'off', handText: 'off', gestureText: 'none', pointerDot: null,
  frames: { seen: 0, processed: 0, start: 0 },
  centring: false, centre: null, centreDoneAt: 0, adapt: new PinchAdapt(), pinchLog: { t: 0, closed: false },
  step: -1, scrolled: 0,
  stream: null, video: null, abort: null, vfc: 0, raf: 0, lastVideoTime: -1,
};
S.machine.sendHold = 0.75;
const trackers = new Trackers();
const sees = new SeesPanel(el.sees);
const cameraCapable = !matchMedia('(pointer: coarse)').matches || matchMedia('(hover: hover)').matches;
const DEBUG = new URLSearchParams(location.search).get('debug') === '1';
const phone = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) || (!cameraCapable && Math.min(screen.width, screen.height) < 900);

// ---- gate and modes -------------------------------------------------------------------------------------

function setState(state) { el.app.dataset.state = state; }

function showGate(message, { camera = !phone, mouseLabel = 'Use mouse instead' } = {}) {
  delete document.documentElement.dataset.go;   // a failed hand-over from the letter falls back to the full gate
  if (S.mode === 'camera') { S.tracking = false; }
  endCentring(null);
  S.mode = 'none'; el.app.dataset.mode = 'none';
  el.gate.hidden = false; el.progress.hidden = true; el.finish.hidden = true;
  el.gateMsg.hidden = !message; el.gateMsg.textContent = message || '';
  el.goCamera.hidden = !camera; el.goCamera.disabled = false; el.goCamera.textContent = trackers.face ? 'Turn camera back on' : 'Turn on camera';
  el.goMouse.hidden = false; el.goMouse.disabled = false; el.goMouse.textContent = phone ? 'Try it with touch' : mouseLabel;
  setState('gate');
}

function enterMouse(note) {
  stopCamera(); endCentring(null);
  S.mode = 'mouse'; S.machine.reset(); S.focus.forgetAll();
  el.gate.hidden = true; el.finish.hidden = true;
  el.stop.hidden = phone; el.stop.textContent = 'Use camera'; el.recentre.hidden = true;
  setState('running'); el.app.dataset.mode = 'mouse';
  if (S.step < 0) startTutorial(); else renderCoach();
  S.pointerDot = null; S.handSeen = null; S.faceSeen = null;
  S.headText = 'off'; S.handText = phone ? 'touch stands in' : 'mouse stands in'; S.gestureText = 'none';
  S.seesNote = note || (phone ? 'Camera off. Touch stands in for your hand.' : 'Camera off. The mouse stands in for your hand.');
}

function cameraErrorMessage(e) {
  const n = e?.name || '';
  if (n === 'NotAllowedError' || n === 'SecurityError') return 'Camera access was refused. Allow the camera for this site in your browser, or use the mouse instead.';
  if (n === 'NotFoundError' || n === 'DevicesNotFoundError') return 'No camera was found on this computer. You can use the mouse instead.';
  if (n === 'NotReadableError' || n === 'TrackStartError' || n === 'AbortError') return 'The camera is in use by another app, or could not start. Close the other app and try again, or use the mouse instead.';
  return `The camera could not start (${e?.message || n || 'unknown error'}). You can use the mouse instead.`;
}

async function openCamera() {
  const base = { audio: false };
  try {
    return await navigator.mediaDevices.getUserMedia({ ...base, video: { width: { ideal: 640 }, height: { ideal: 480 }, frameRate: { ideal: 30, max: 30 }, facingMode: 'user' } });
  } catch (e) {
    if (e?.name === 'OverconstrainedError' || e?.name === 'ConstraintNotSatisfiedError') return navigator.mediaDevices.getUserMedia({ ...base, video: true });
    throw e;
  }
}

async function startCamera() {
  const why = unsupportedReason();
  if (why) { showGate(why); return; }
  el.goCamera.disabled = true; el.goMouse.disabled = true;
  el.gateMsg.hidden = true; el.progress.hidden = false;
  el.progressLabel.textContent = 'Waiting for camera permission, loading the trackers in the meantime';
  el.bar.style.width = '0%';
  setState('loading');
  const abort = new AbortController(); S.abort = abort;
  const camP = openCamera();
  camP.catch(() => abort.abort());
  const needLoad = !trackers.face;
  const loadP = needLoad ? trackers.load({
    signal: abort.signal,
    onProgress: (f, label) => {
      el.bar.style.width = `${Math.round(f * 100)}%`;
      el.progressLabel.textContent = label || `Loading the trackers: ${Math.round(f * 100)}% of ${(TOTAL_BYTES / 1e6).toFixed(1)} MB`;
    },
  }) : Promise.resolve();
  const [cam, load] = await Promise.allSettled([camP, loadP]);
  if (cam.status === 'rejected') { showGate(cameraErrorMessage(cam.reason)); return; }
  if (load.status === 'rejected') {
    cam.value.getTracks().forEach((t) => t.stop());
    if (abort.signal.aborted) return;
    showGate(`The trackers could not load (${load.reason?.message || load.reason}). You can use the mouse instead.`);
    return;
  }
  try {
    await withTimeout(attachStream(cam.value), 10000, 'no picture');
    el.progressLabel.textContent = 'Warming up the trackers';
    await trackers.warmUp(S.video);
  } catch (e) {
    cam.value.getTracks().forEach((t) => t.stop());
    if (S.video) S.video.srcObject = null;
    showGate(e?.message === 'no picture' ? 'The camera started but sent no picture. Another app may be using it. Close it and try again, or use the mouse instead.' : cameraErrorMessage(e));
    return;
  }
  S.mode = 'camera'; S.machine.reset(); S.focus.forgetAll(); S.head.recentre(); S.scheduler = new FrameScheduler();
  S.frames = { seen: 0, processed: 0, start: now() };
  el.gate.hidden = true; el.progress.hidden = true; el.finish.hidden = true;
  el.stop.hidden = false; el.stop.textContent = 'Stop camera'; el.recentre.hidden = false;
  setState('running'); el.app.dataset.mode = 'camera';
  S.seesNote = 'Looking for your face';
  beginCentring();
  S.tracking = true; scheduleFrame();
}

function withTimeout(promise, ms, message) {
  return Promise.race([promise, new Promise((_, rej) => setTimeout(() => rej(new Error(message)), ms))]);
}

async function attachStream(stream) {
  if (!S.video) {
    const v = document.createElement('video');
    v.muted = true; v.playsInline = true; v.setAttribute('playsinline', ''); v.autoplay = true;
    el.sink.append(v); S.video = v;
  }
  S.stream = stream;
  S.video.srcObject = stream;
  stream.getVideoTracks()[0]?.addEventListener('ended', () => { if (S.stream === stream) cameraLost(); });
  await S.video.play();
  if (!S.video.videoWidth) await new Promise((res) => S.video.addEventListener('loadedmetadata', res, { once: true }));
  sees.aspect = S.video.videoWidth / S.video.videoHeight;
  S.machine.frameAspect = sees.aspect;
}

function stopCamera() {
  S.tracking = false;
  if (S.video) { try { S.video.cancelVideoFrameCallback?.(S.vfc); } catch { /* none */ } }
  cancelAnimationFrame(S.raf);
  S.stream?.getTracks().forEach((t) => t.stop());
  S.stream = null;
  if (S.video) S.video.srcObject = null;
  S.faceSeen = null; S.handSeen = null;
}

function cameraLost() {
  stopCamera(); S.machine.reset(); endDictation('lost'); endCentring(null);
  showGate('The camera stopped (it was unplugged or another app took it). You can turn it back on or use the mouse.');
}

// ---- the frame loop -------------------------------------------------------------------------------------

function scheduleFrame() {
  if (!S.tracking) return;
  if (S.video.requestVideoFrameCallback) S.vfc = S.video.requestVideoFrameCallback(onVideoFrame);
  else S.raf = requestAnimationFrame(onVideoFrame);
}

async function onVideoFrame() {
  if (!S.tracking) return;
  const v = S.video;
  S.frames.seen += 1;
  // Skip, never queue: a frame that arrives while the last one is still being read is dropped, and a repeat of the same picture is ignored.
  if (S.busy || v.readyState < 2 || v.currentTime === S.lastVideoTime) { scheduleFrame(); return; }
  S.lastVideoTime = v.currentTime;
  S.busy = true;
  try {
    const t = now(), plan = S.scheduler.plan(t);
    if (plan.face) {
      const f = await trackers.guarded(() => trackers.detectFace(v, t * 1000));
      S.scheduler.record('face', trackers.stats.face.last);
      onFace(f, t);
    }
    if (plan.hand) {
      const h = await trackers.guarded(() => trackers.detectHand(v, t * 1000));
      S.scheduler.record('hand', trackers.stats.hand.last);
      onHand(h, t);
    }
    if (plan.face || plan.hand) S.frames.processed += 1;
  } catch (e) {
    S.tracking = false;
    stopCamera();
    showGate(`Tracking stopped (${e?.message || e}). You can try the camera again or use the mouse.`);
    return;
  } finally {
    S.busy = false;
  }
  scheduleFrame();
}

function onFace(f, t) {
  if (!f) {
    if (S.faceSeen && t - S.faceSeen.t > 0.4) S.faceSeen = null;
    return;
  }
  S.faceSeen = { landmarks: f.landmarks, t };
  readHead(t, f.yaw, f.pitch, f.offset);
}

/** One head reading: it feeds the centring step first, then the pointer. The test hook feeds it too. */
function readHead(t, yaw, pitch, offset) {
  const f = { yaw, pitch, offset };
  if (S.centring) { S.centre.push(t, yaw, pitch); S.headText = 'centring'; return; }
  const p = S.head.push({ t, yaw, pitch, offset });
  S.headText = p ? `yaw ${(f.yaw * 57.3).toFixed(0)}  pitch ${(f.pitch * 57.3).toFixed(0)} deg` : `centring ${Math.round(S.head.centringProgress * 100)}%`;
  if (!p) return;
  const r = el.stage.getBoundingClientRect();
  S.nose = { x: r.left + p.x * r.width, y: r.top + p.y * r.height, t };
  focusAt({ x: r.left + p.x * r.width, y: r.top + p.y * r.height }, t);
}

function onHand(h, t) {
  if (S.centring || S.noHand) return;   // nothing acts until the centring step is done
  let obs;
  if (h) {
    const hand = handFromLandmarks(h.landmarks);
    obs = observationFromHand(hand, t, h.gesture === 'Thumb_Up' && h.score >= 0.6, { world: h.world, aspect: S.video ? S.video.videoWidth / S.video.videoHeight : 1 });
    if (obs.pinch !== null) { S.adapt.push(obs.pinch); S.machine.pinchClosed = S.adapt.closed; S.machine.pinchOpen = S.adapt.open; }
    S.handSeen = { points: h.landmarks, t, closed: false };
    S.gestureText = obs.pose || (h.gesture && h.gesture !== 'None' ? h.gesture.replace('_', ' ') : 'none');
    S.handText = obs.pinch !== null ? `pinch ${obs.pinch.toFixed(2)}` : 'seen';
    S.lastObsPinch = obs.pinch;
  } else {
    obs = observationFromHand(null, t);
    if (S.handSeen && t - S.handSeen.t > 0.3) S.handSeen = null;
    S.handText = 'no hand'; S.gestureText = 'none';
  }
  feed(obs);
  if (S.handSeen) S.handSeen.closed = S.machine.pinchHeld;
  showPinch(obs, t);
}

/** The live pinch value and a closed/open marker in the sees panel; with ?debug=1 also in the console. */
function showPinch(obs, t) {
  const v = obs.pinch, closed = S.machine.pinchHeld;
  el.rPinch.innerHTML = v === null ? '-' : `<i class="pm ${closed ? 'closed' : 'open'}"></i>${v.toFixed(2)} ${closed ? 'closed' : 'open'}`;
  if (!DEBUG || v === null) return;
  const a = S.adapt, line = () => `[pinch] ${v.toFixed(3)} ${closed ? 'CLOSED' : 'open'} src=${obs.pinchSource} closed<${a.closed.toFixed(2)} open>${a.open.toFixed(2)} dips=${a.dips.length}${a.ready ? ` low=${a.lowValue.toFixed(2)} high=${a.highValue.toFixed(2)}` : ''}`;
  if (closed !== S.pinchLog.closed) { console.log(line().replace('[pinch]', '[pinch] STATE CHANGE')); S.pinchLog.closed = closed; S.pinchLog.t = t; }
  else if (t - S.pinchLog.t > 0.5) { console.log(line()); S.pinchLog.t = t; }
}

function feed(obs) {
  for (const i of S.machine.push(obs)) intent(i);
}

// ---- centring: point your nose at the dot, hold still for 3, 2, 1 ----------------------------------------

function beginCentring() {
  S.centring = true; S.centre = new CentreStep(); S.centreDoneAt = 0;
  S.head.recentre(); S.focus.forgetAll(); S.machine.reset(); endDictation('lost');
  el.centre.hidden = false; el.centre.dataset.state = 'wait'; el.centre.classList.remove('leaving');
  el.coach.hidden = true;
  renderCentre(now());
}

/** `centre`: {yaw, pitch} to use it, 'auto' for the automatic first-second centre (Skip), or null when there is no step (mouse mode). */
function endCentring(centre) {
  const was = S.centring;
  S.centring = false; S.centre = null;
  if (centre && centre !== 'auto') S.head.setCentre(centre.yaw, centre.pitch);
  el.centre.classList.add('leaving');
  setTimeout(() => { if (!S.centring) { el.centre.hidden = true; el.centre.classList.remove('leaving'); } }, centre ? 450 : 0);
  if (!centre) el.centre.hidden = true;
  if (was && centre) { if (S.step < 0) startTutorial(); else renderCoach(); }
}

function renderCentre(t) {
  const c = S.centre; if (!c) return;
  c.tick(t);
  const state = c.done ? 'done' : c.lost ? 'wait' : 'count';
  if (el.centre.dataset.state !== state) el.centre.dataset.state = state;
  const line = state === 'done' ? 'Got it.' : state === 'wait' ? 'Find the camera' : 'Point your nose at the dot. Hold still.';
  if (el.centreLine.textContent !== line) el.centreLine.textContent = line;
  el.centreCount.textContent = state === 'done' ? '' : String(c.count);
  el.centreArc.style.strokeDashoffset = (326.7 * (1 - c.progress)).toFixed(1);
  if (c.done) endCentring(c.centre);
}

el.centreSkip.addEventListener('click', () => { if (S.centring) { S.head.recentre(); endCentring('auto'); } });

// ---- focus ----------------------------------------------------------------------------------------------

function focusAt(point, t) {
  refreshFrames();
  const current = S.focus.target;
  const under = sessionAt(point, panes, current);
  if (!under) return;   // between panes or outside: the current one stays, as the app keeps its target
  const prev = current, moved = S.focus.observe(under, t, S.machine.pinchHeld, S.machine.talking);
  if (moved && prev && S.machine.talking) {
    S.machine.abortTalk(); endDictation('switched');
    banner('info', 'Dictation paused', `Text kept in ${prev.name}`);
  }
}

// ---- intents --------------------------------------------------------------------------------------------

function intent(i) {
  if (i.type === 'talkBegan') beginDictation();
  else if (i.type === 'talkEnded') endDictation(i.reason);
  else if (i.type === 'sendRequested') send();
  else if (i.type === 'dragScroll') scrollFocused(i.handDy);
}

function beginDictation() {
  const pane = S.focus.target;
  if (!pane) { S.machine.abortTalk(); banner('info', 'No session in focus', 'Look at a session first'); return; }
  S.dict = { pane, start: now(), from: pane.typed };
  pane.el.classList.add('dictating');
  tick_('dictated');
}

function endDictation(reason) {
  const d = S.dict;
  if (!d) return;
  d.pane.el.classList.remove('dictating');
  S.dict = null;
  if (reason !== 'switched' && d.pane.draft && !S.sending) banner('stopped', 'Dictation stopped', `Text kept in ${d.pane.name}, thumbs-up to send`, d.pane.name);
}

function typeWords(t) {
  const d = S.dict;
  if (!d) return;
  const words = d.pane.words;
  const n = Math.min(words.length, d.from + wordsTyped(words.length, t - d.start));
  if (n !== d.pane.typed) { d.pane.typed = n; setDraft(d.pane, words.slice(0, n).join(' ')); }
}

function send() {
  const pane = S.focus.target;
  if (!pane || !pane.draft.trim()) { banner('info', 'Nothing to send', 'Dictate into a session first'); return; }
  S.sending = true; endDictation('sent'); S.sending = false;
  const reply = pane.reply;
  addLine(pane, 'you', pane.draft.trim());
  setDraft(pane, ''); pane.typed = 0; pane.promptIdx += 1;
  stick(pane);
  banner('sent', null, pane.name);
  streamReply(pane, reply);
  tick_('sent');
}

function scrollFocused(handDy) {
  const pane = S.focus.target;
  if (!pane) return;
  const before = pane.transcript.scrollTop;
  pane.transcript.scrollTop += handDy * 0.12;
  S.scrolled += Math.abs(pane.transcript.scrollTop - before);
  if (S.scrolled >= 120) tick_('scrolled');
}

function banner(style, title, body, name) {
  S.banner = { style, title, body, name, until: now() + (style === 'sent' ? 1.8 : 2.6) };
}

// ---- island ---------------------------------------------------------------------------------------------

let lastIsland = '';
function renderIsland(t) {
  if (S.banner && t > S.banner.until) S.banner = null;
  const m = S.machine, g = m.progress, cand = S.focus.candidate;
  const switching = m.talking && cand?.session ? cand.session : null;
  const mode = islandMode({ listening: m.talking, sessionSwitch: !!switching, gesture: g, banner: S.banner });
  const name = esc((S.dict?.pane ?? S.focus.target)?.name ?? 'a session');
  let l1 = '', l2 = '', hint = '';
  if (mode === 'dictating') { l1 = 'Claude dictation on'; l2 = `in <em>${name}</em>`; hint = 'double pinch to stop'; }
  else if (mode === 'switching') { l1 = `Activating <em>${esc(switching.name)}</em>`; l2 = 'Original message unsent'; hint = 'look back to stay'; }
  else if (mode === 'firstPinch') { l1 = g.action === 'stop' ? 'Pinch again to stop dictation' : 'Pinch again to dictate'; l2 = `in <em>${name}</em>`; }
  else if (mode === 'sendHold') { l1 = `Sending in <em>${esc(S.focus.target?.name ?? 'a session')}</em>`; hint = 'lower to cancel'; }
  else if (mode === 'banner') {
    const b = S.banner;
    if (b.style === 'sent') l1 = `Sent in <em>${esc(b.body)}</em>`;
    else if (b.style === 'stopped') { l1 = esc(b.title); l2 = `Text kept in <em>${esc(b.name)}</em>, thumbs-up to send`; }
    else { l1 = esc(b.title); l2 = esc(b.body); }
  }
  const key = `${mode}|${l1}|${l2}|${hint}`;
  if (key !== lastIsland) {
    lastIsland = key;
    el.island.dataset.mode = mode;
    el.island.dataset.style = S.banner?.style ?? '';
    el.island.querySelector('.l1').innerHTML = l1;
    el.island.querySelector('.l2').innerHTML = l2;
    el.island.querySelector('.ens-hint').textContent = hint;
    el.island.classList.remove('swap'); void el.island.offsetWidth; el.island.classList.add('swap');
  }
  const fill = mode === 'sendHold' ? g.progress : mode === 'switching' ? Math.min((t - cand.since) / FOCUS.listeningSwitchDwell, 1) : 0;
  el.island.style.setProperty('--fill', fill.toFixed(3));
}

// ---- coach: what to try next, ticked off as it happens, in any order ----------------------------------------

const DONE = { looked: false, dictated: false, sent: false, scrolled: false };
const HINTS = {
  looked: { camera: 'Look at one of the sessions. The blue outline follows your nose.', mouse: 'Move the mouse over one of the sessions.' },
  dictated: { camera: '<strong>Double pinch</strong> (thumb and index, twice, quickly) to dictate into the session you are looking at.', mouse: '<strong>Click twice</strong>, quickly, to dictate into the session under the mouse.' },
  sent: { camera: 'Hold a <strong>thumbs-up</strong> to send what was typed.', mouse: 'Press and hold still: that is the <strong>thumbs-up</strong>. It sends.' },
  scrolled: { camera: '<strong>Pinch and drag</strong> up or down to scroll the session you are looking at.', mouse: 'Press and <strong>drag</strong> up or down to scroll the session under the mouse.' },
};

function tick_(k) {
  if (DONE[k]) return;
  DONE[k] = true; renderCoach();
}

function renderCoach() {
  el.coach.hidden = false;
  for (const li of el.ticks.children) li.classList.toggle('done', DONE[li.dataset.k]);
  const next = Object.keys(DONE).find((k) => !DONE[k]);
  const m = S.mode === 'camera' ? 'camera' : 'mouse';
  el.prompt.innerHTML = next ? HINTS[next][m] : 'You have tried all four. Keep playing, or see the download.';
  el.done.hidden = !!next;
}

function startTutorial() { S.step = 0; renderCoach(); }

function finish() {
  if (S.mode === 'camera') { S.resumeOnShow = false; stopCamera(); S.machine.reset(); }
  el.finish.hidden = false; setState('finished');
  el.finish.querySelector('#download').focus({ preventScroll: true });
}

// ---- mouse and touch ------------------------------------------------------------------------------------

function mousePos(e) {
  const r = el.stage.getBoundingClientRect();
  return { x: e.clientX, y: e.clientY, nx: (e.clientX - r.left) / r.width, ny: (e.clientY - r.top) / r.height };
}

el.stage.addEventListener('pointerdown', (e) => {
  if (S.mode !== 'mouse' || e.button > 0) return;
  el.stage.setPointerCapture?.(e.pointerId);
  S.mouse = mousePos(e);
  S.pointerHand.down(e.timeStamp / 1000, S.mouse);
});
window.addEventListener('pointermove', (e) => {
  if (S.mode !== 'mouse') return;
  S.mouse = mousePos(e);
  S.pointerHand.move(S.mouse);
});
const release = (e) => { if (S.mode === 'mouse') S.pointerHand.up(e.timeStamp / 1000, mousePos(e)); };
window.addEventListener('pointerup', release);
window.addEventListener('pointercancel', release);

// ---- render loop (display rate) ---------------------------------------------------------------------------

let lastSees = 0, lastText = 0;
function render(ms) {
  const t = ms / 1000;
  if (S.mode === 'mouse') {
    if (S.mouse) {
      for (const o of S.pointerHand.frames(t)) feed(o);
      focusAt(S.mouse, t);
    }
  } else if (S.mode === 'camera') {
    for (const i of S.machine.tick(t)) intent(i);
  }
  typeWords(t);
  renderIsland(t);
  const target = S.focus.target;
  for (const p of panes) p.el.classList.toggle('focused', p === target);
  if ((target?.id ?? null) !== S.focusId) { S.focusId = target?.id ?? null; S.focusSince = t; }
  if (target && t - S.focusSince > 0.6) tick_('looked');
    renderOverlays(t, target);
  if (t - lastSees > 0.033) { lastSees = t; drawSees(t); }
  if (t - lastText > 0.15) { lastText = t; drawText(); }
  requestAnimationFrame(render);
}

let glide = null, lastGlide = 0, frameAt = 0;
function renderOverlays(t, target) {
  if (S.centring) renderCentre(t);
  // the blue outline follows the focused pane with a spring; it breathes while dictating
  if (t - frameAt > 0.5) { frameAt = t; refreshFrames(); }
  if (target && el.app.dataset.state === 'running' && !S.centring) {
    const f = target.frame, i = 4;
    el.hl.style.width = `${Math.max(f.w - 2 * i, 0)}px`; el.hl.style.height = `${Math.max(f.h - 2 * i, 0)}px`;
    el.hl.style.transform = `translate(${f.x + i}px, ${f.y + i}px)`;
    el.hl.classList.add('on');
    el.hl.classList.toggle('listening', S.machine.talking);
  } else el.hl.classList.remove('on', 'listening');
  // the glass-bead dot glides toward the nose point, with the app's own time constant
  const nose = S.mode === 'camera' && !S.centring && S.nose && t - S.nose.t < 0.5 ? S.nose : null;
  if (nose) {
    if (!glide) glide = { x: nose.x, y: nose.y };
    const dt = Math.min(Math.max(t - (lastGlide || t - 1 / 60), 0), 0.1), k = 1 - Math.exp(-dt / 0.05);
    glide.x += (nose.x - glide.x) * k; glide.y += (nose.y - glide.y) * k;
    el.dot.style.transform = `translate3d(${glide.x.toFixed(1)}px, ${glide.y.toFixed(1)}px, 0)`;
    el.dot.classList.add('on');
  } else { el.dot.classList.remove('on'); glide = null; }
  lastGlide = t;
  document.getElementById('app').classList.toggle('talking', S.machine.talking);
}

function drawSees(t) {
  const face = S.faceSeen && t - S.faceSeen.t < 0.5 ? S.faceSeen : null;
  const hand = S.handSeen && t - S.handSeen.t < 0.35 ? S.handSeen : null;
  sees.draw({ face, hand, note: S.mode === 'camera' ? (S.centring ? 'Point your nose at the dot' : S.head.centring && face ? 'Hold still for a second' : 'No face or hand found yet') : S.seesNote });
}

function drawText() {
  el.rHead.textContent = S.mode === 'camera' ? (S.faceSeen ? S.headText : 'no face') : 'off';
  el.rHand.textContent = S.handText;
  el.rGesture.textContent = S.gestureText;
  const f = trackers.stats.face, h = trackers.stats.hand;
  const secs = Math.max(now() - S.frames.start, 0.001);
  el.rSpeed.textContent = S.mode === 'camera' && f.n + h.n ? `${(S.frames.processed / secs).toFixed(0)} Hz, ${(f.sum / Math.max(f.n, 1)).toFixed(0)}+${(h.sum / Math.max(h.n, 1)).toFixed(0)} ms` : '-';
}

// ---- lifecycle ------------------------------------------------------------------------------------------

el.goCamera.addEventListener('click', () => startCamera());
el.goMouse.addEventListener('click', () => enterMouse());
el.done.addEventListener('click', finish);
{
  const box = document.querySelector('.ls-sees'), title = $('sees-title');
  const toggle = () => { box.classList.toggle('collapsed'); sees.resize(); };
  title.addEventListener('click', toggle);
  title.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } });
}
el.recentre.addEventListener('click', () => { if (S.mode === 'camera') beginCentring(); });
el.stop.addEventListener('click', () => {
  if (S.mode === 'camera') { S.resumeOnShow = false; stopCamera(); S.machine.reset(); endDictation('stopped'); endCentring(null); S.mode = 'none'; showGate('The camera is off.'); }
  else showGate(null);
});
el.keep.addEventListener('click', () => {
  el.finish.hidden = true;
  if (S.mode === 'mouse') setState('running'); else showGate('The camera is off.');
});

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (S.mode === 'camera' && S.tracking) { S.resumeOnShow = true; stopCamera(); S.machine.reset(); }
  } else if (S.resumeOnShow) {
    S.resumeOnShow = false;
    startCamera();
  }
});
addEventListener('pagehide', () => { stopCamera(); trackers.close(); S.abort?.abort(); });
addEventListener('resize', () => { sees.resize(); refreshFrames(); });
// Without a hidden-tab restart the gate would sit over a dead stage, so the first view is always the gate.

el.sizeNote.textContent = `${Math.round(TOTAL_BYTES / 1e6)} MB`;
if (phone) { el.goCamera.hidden = true; el.goMouse.textContent = 'Try it with touch'; el.gate.querySelector('.ls-lede').textContent = 'Four mock Claude sessions. Camera tracking needs a desktop browser, so here touch stands in for your hands: tap twice to dictate, press and hold to send, press and drag to scroll.'; }
refreshFrames();
for (const p of panes) stick(p);
addEventListener('load', () => { for (const p of panes) if (!p.streams && !p.typed) stick(p); });
requestAnimationFrame(render);
{
  // From the letter: the camera is already allowed (?go=1), or the visitor chose the mouse (?mouse=1). A direct visit still sees the gate.
  const q = new URLSearchParams(location.search);
  if (q.get('mouse') === '1') enterMouse();
  else if (q.get('go') === '1' && !phone) startCamera();
  else delete document.documentElement.dataset.go;
}

window.__live = {
  get mode() { return S.mode; }, done: () => ({ ...DONE }), get delegate() { return trackers.delegate; },
  stats: () => ({ face: trackers.summary('face'), hand: trackers.summary('hand'), warmed: !trackers.warming, frames: { ...S.frames }, delegate: trackers.delegate, handHz: S.scheduler.handHz, faceHz: S.scheduler.faceHz }),
  focus: () => S.focus.target?.id ?? null,
  draft: (id) => panes.find((p) => p.id === id)?.draft ?? null,
  talking: () => S.machine.talking,
  // test hooks: feed one synthetic head reading (radians) as if the face tracker had seen it; read the centring state
  suppressHand: () => { S.noHand = true; },
  feedHead: (yaw, pitch) => readHead(now(), yaw, pitch, null),
  centring: () => ({ active: S.centring, state: el.centre.dataset.state, count: S.centre?.count ?? null, progress: S.centre?.progress ?? null, line: el.centreLine.textContent }),
  centre: () => S.head.centre,
  feedPinch: (d) => { const t = now(), obs = { t, present: true, pose: null, palmCenter: { x: 0.5, y: 0.5 }, pinch: d, pinchSource: 'test' }; S.adapt.push(d); S.machine.pinchClosed = S.adapt.closed; S.machine.pinchOpen = S.adapt.open; feed(obs); showPinch(obs, t); },
  pinch: () => ({ closed: S.adapt.closed, open: S.adapt.open, dips: S.adapt.dips.length }),
};
