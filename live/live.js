// The live stage: four mock Claude sessions driven by head and hands (camera) or by the mouse (fallback).
// Wiring only; the rules live in logic.js (ported from the Mac app), the models in tracker.js, the skeleton in sees.js.

import {
  GestureMachine, FocusTracker, FOCUS, sessionAt, HeadPointer, FrameScheduler, PointerHand, islandMode, wordsTyped,
  observationFromHand, handFromLandmarks,
} from './logic.js';
import { SESSIONS } from './content.js';
import { SeesPanel } from './sees.js';
import { Trackers, unsupportedReason, TOTAL_BYTES } from './tracker.js';

const $ = (id) => document.getElementById(id);
const el = {
  app: $('app'), stage: $('stage'), island: $('island'), gate: $('gate'), gateMsg: $('gate-message'), goCamera: $('go-camera'),
  goMouse: $('go-mouse'), progress: $('progress'), bar: $('bar'), progressLabel: $('progress-label'), coach: $('coach'),
  prompt: $('prompt'), ticks: $('ticks'), done: $('done'), rail: $('rail'), finish: $('finish'), keep: $('keep'), stop: $('stop'), recentre: $('recentre'),
  sink: $('sink'), sees: $('sees'),
  rHead: $('r-head'), rHand: $('r-hand'), rGesture: $('r-gesture'), rSpeed: $('r-speed'), sizeNote: $('size-note'),
};
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const now = () => performance.now() / 1000;

// ---- panes ----------------------------------------------------------------------------------------------

const MODES = [['Edit automatically', 'Opus 5.5'], ['Ask before edits', 'Sonnet 5.5'], ['Plan mode', 'Opus 5.5'], ['Edit automatically', 'Sonnet 5.5']];
el.rail.innerHTML = '<h3>Code sessions</h3>';
const panes = SESSIONS.map((s, k) => {
  const root = document.createElement('article');
  root.className = 'ls-pane'; root.dataset.id = s.id;
  root.innerHTML = `<div class="ls-pane-head"><span>${esc(s.name)}</span><small>${esc(s.branch)}</small></div>
    <div class="ls-transcript" tabindex="-1"></div>
    <div class="ls-composer"><span class="ls-mic"></span><span class="draft"></span></div>
    <p class="ls-meta">${esc(MODES[k][0])} &middot; ${esc(MODES[k][1])}</p>`;
  el.stage.append(root);
  const item = document.createElement('div');
  item.className = 'ls-rail-item'; item.innerHTML = `<i></i>${esc(s.name)}`;
  el.rail.append(item);
  const pane = {
    id: s.id, name: s.name, el: root, railEl: item, transcript: root.querySelector('.ls-transcript'), draftEl: root.querySelector('.draft'),
    draft: '', prompts: s.prompts, promptIdx: 0, typed: 0, streams: 0, frame: { x: 0, y: 0, w: 0, h: 0 },
    get words() { return this.prompts[this.promptIdx % this.prompts.length].say.split(' '); },
    get reply() { return this.prompts[this.promptIdx % this.prompts.length].reply; },
  };
  for (const [who, text] of s.transcript) addLine(pane, who, text);
  return pane;
});

function addLine(pane, who, text) {
  const p = document.createElement(who === 'code' ? 'pre' : 'p');
  p.className = `ls-line ${who}`; p.textContent = text;
  pane.transcript.append(p);
  return p;
}

const stick = (pane) => { pane.transcript.scrollTop = pane.transcript.scrollHeight; };

/** A mock Claude reply streaming into a session: tool lines and code appear whole, prose types word by word. */
function streamReply(pane, items) {
  pane.streams += 1; pane.railEl.firstChild.className = 'working';
  let k = 0;
  const next = () => {
    if (k >= items.length) { if (--pane.streams === 0) pane.railEl.firstChild.className = ''; return; }
    const [who, text] = items[k++];
    if (who !== 'claude') { addLine(pane, who, text); stick(pane); setTimeout(next, 550); return; }
    const line = addLine(pane, 'claude', ''); line.classList.add('streaming');
    const words = text.split(' '); let n = 0;
    const tick = () => {
      line.textContent = words.slice(0, ++n).join(' '); stick(pane);
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
  step: -1, scrolled: 0,
  stream: null, video: null, abort: null, vfc: 0, raf: 0, lastVideoTime: -1,
};
S.machine.sendHold = 0.75;
const trackers = new Trackers();
const sees = new SeesPanel(el.sees);
const cameraCapable = !matchMedia('(pointer: coarse)').matches || matchMedia('(hover: hover)').matches;
const phone = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) || (!cameraCapable && Math.min(screen.width, screen.height) < 900);

// ---- gate and modes -------------------------------------------------------------------------------------

function setState(state) { el.app.dataset.state = state; }

function showGate(message, { camera = !phone, mouseLabel = 'Use mouse instead' } = {}) {
  if (S.mode === 'camera') { S.tracking = false; }
  S.mode = 'none'; el.app.dataset.mode = 'none';
  el.gate.hidden = false; el.progress.hidden = true; el.finish.hidden = true;
  el.gateMsg.hidden = !message; el.gateMsg.textContent = message || '';
  el.goCamera.hidden = !camera; el.goCamera.disabled = false; el.goCamera.textContent = trackers.face ? 'Turn camera back on' : 'Turn on camera';
  el.goMouse.hidden = false; el.goMouse.disabled = false; el.goMouse.textContent = phone ? 'Try it with touch' : mouseLabel;
  setState('gate');
}

function enterMouse(note) {
  stopCamera();
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
  if (S.step < 0) startTutorial(); else renderCoach();
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
  stopCamera(); S.machine.reset(); endDictation('lost');
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
  const p = S.head.push({ t, yaw: f.yaw, pitch: f.pitch, offset: f.offset });
  S.headText = p ? `yaw ${(f.yaw * 57.3).toFixed(0)}  pitch ${(f.pitch * 57.3).toFixed(0)} deg` : `centring ${Math.round(S.head.centringProgress * 100)}%`;
  if (!p) return;
  const r = el.stage.getBoundingClientRect();
  focusAt({ x: r.left + p.x * r.width, y: r.top + p.y * r.height }, t);
}

function onHand(h, t) {
  let obs;
  if (h) {
    const hand = handFromLandmarks(h.landmarks);
    obs = observationFromHand(hand, t, h.gesture === 'Thumb_Up' && h.score >= 0.6);
    S.handSeen = { points: h.landmarks, t, closed: false };
    S.gestureText = obs.pose || (h.gesture && h.gesture !== 'None' ? h.gesture.replace('_', ' ') : 'none');
    S.handText = obs.pinch !== null ? `pinch ${obs.pinch.toFixed(2)} palms` : 'seen';
    S.lastObsPinch = obs.pinch;
  } else {
    obs = observationFromHand(null, t);
    if (S.handSeen && t - S.handSeen.t > 0.3) S.handSeen = null;
    S.handText = 'no hand'; S.gestureText = 'none';
  }
  feed(obs);
  if (S.handSeen) S.handSeen.closed = S.machine.pinchHeld;
}

function feed(obs) {
  for (const i of S.machine.push(obs)) intent(i);
}

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
    el.island.querySelector('.ls-island-hint').textContent = hint;
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
  for (const p of panes) p.railEl.classList.toggle('focused', p === target);
  if (t - lastSees > 0.033) { lastSees = t; drawSees(t); }
  if (t - lastText > 0.15) { lastText = t; drawText(); }
  requestAnimationFrame(render);
}

function drawSees(t) {
  const face = S.faceSeen && t - S.faceSeen.t < 0.5 ? S.faceSeen : null;
  const hand = S.handSeen && t - S.handSeen.t < 0.35 ? S.handSeen : null;
  sees.draw({ face, hand, note: S.mode === 'camera' ? (S.head.centring && face ? 'Hold still for a second' : 'No face or hand found yet') : S.seesNote });
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
el.recentre.addEventListener('click', () => { S.head.recentre(); S.focus.forgetAll(); });
el.stop.addEventListener('click', () => {
  if (S.mode === 'camera') { S.resumeOnShow = false; stopCamera(); S.machine.reset(); endDictation('stopped'); S.mode = 'none'; showGate('The camera is off.'); }
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
requestAnimationFrame(render);

window.__live = {
  get mode() { return S.mode; }, done: () => ({ ...DONE }), get delegate() { return trackers.delegate; },
  stats: () => ({ face: trackers.summary('face'), hand: trackers.summary('hand'), warmed: !trackers.warming, frames: { ...S.frames }, delegate: trackers.delegate, handHz: S.scheduler.handHz, faceHz: S.scheduler.faceHz }),
  focus: () => S.focus.target?.id ?? null,
  draft: (id) => panes.find((p) => p.id === id)?.draft ?? null,
  talking: () => S.machine.talking,
};
