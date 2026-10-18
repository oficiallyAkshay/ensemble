// The live stage: four mock Claude sessions driven by head and hands (camera) or by the mouse (fallback).
// Wiring only; the rules live in logic.js (ported from the Mac app), the models in tracker.js, the skeleton in sees.js.

import {
  GestureMachine, FocusTracker, FOCUS, sessionAt, HeadPointer, CentreStep, PinchAdapt, FrameScheduler, NoseGlide, PointerHand, islandMode, wordsTyped, showsScrollGlyph,
  observationFromHand, handFromLandmarks,
} from './logic.js';
import { SESSIONS } from './content.js';
import { esc, fmt, buildPane, addLine } from './pane.js';
import { SeesPanel } from './sees.js';
import { Trackers, unsupportedReason, TOTAL_BYTES } from './tracker.js';

const $ = (id) => document.getElementById(id);
const el = {
  app: $('app'), stage: $('stage'), island: $('island'), gate: $('gate'), gateMsg: $('gate-message'), goCamera: $('go-camera'),
  goMouse: $('go-mouse'), progress: $('progress'), bar: $('bar'), progressLabel: $('progress-label'),
  mac: $('mac'), claudeIcon: $('claude-icon'), mbApp: $('mb-app'), mbEns: $('mb-ens'), menu: $('ens-menu'), mpStatus: $('mp-status'), mpPower: $('mp-power'), mpCamera: $('mp-camera'),
  mpScreen: $('mp-screen'), mpDot: $('mp-dot'), mpHl: $('mp-hl'), mpReplay: $('mp-replay'), mpCalibrate: $('mp-calibrate'), mpQuit: $('mp-quit'), tip: $('tip'), tipText: $('tip-text'),
  meterText: $('meter-text'), meterBar: $('meter-bar'), hand: $('hand'), art: $('art'), handCap: $('hand-cap'),
  prompt: $('prompt'), steps: $('steps'), done: $('done'), finish: $('finish'), keep: $('keep'), stop: $('stop'), recentre: $('recentre'),
  sink: $('sink'), sees: $('sees'), hl: $('hl'), dot: $('dot'),
  centre: $('centre'), centreLine: $('centre-line'), centreCount: $('centre-count'), centreArc: $('centre-arc'), centreSkip: $('centre-skip'), rPinch: $('r-pinch'),
  rHead: $('r-head'), rHand: $('r-hand'), rGesture: $('r-gesture'), rSpeed: $('r-speed'), sizeNote: $('size-note'),
};
const now = () => performance.now() / 1000;

// ---- panes ----------------------------------------------------------------------------------------------

const panes = SESSIONS.map((s, k) => { const pane = buildPane(s, k); el.stage.append(pane.el); return pane; });

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
  glide: new NoseGlide(), dotMoves: 0, camera: null, centring: false, centre: null, centreDoneAt: 0, adapt: new PinchAdapt(), pinchLog: { t: 0, closed: false },
  step: -1, scrolled: 0, opened: false, preferred: null, showDot: true, showHl: true,
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
  openClaude();
  stopCamera(); endCentring(null);
  S.mode = 'mouse'; S.machine.reset(); S.focus.forgetAll();
  el.gate.hidden = true; el.finish.hidden = true;
  el.stop.hidden = phone; el.stop.textContent = 'Use camera'; el.recentre.hidden = true;
  setState('running'); el.app.dataset.mode = 'mouse';
  tick_('enabled'); DONE.centred = true;
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

/** Asks for a fast small picture: 60 fps if the camera can, never under 24. Falls back step by step, so an odd camera still starts. */
async function openCamera() {
  const base = { audio: false }, md = navigator.mediaDevices;
  const size = { width: { ideal: 640 }, height: { ideal: 480 }, facingMode: 'user' };
  const tries = [{ ...size, frameRate: { ideal: 60, min: 24 } }, { ...size, frameRate: { ideal: 60 } }, true];
  let last;
  for (const video of tries) {
    try {
      const stream = await md.getUserMedia({ ...base, video });
      const st = stream.getVideoTracks()[0]?.getSettings?.() ?? {};
      S.camera = { width: st.width, height: st.height, frameRate: st.frameRate, deviceId: undefined, ask: video === true ? 'any' : JSON.stringify(video.frameRate) };
      console.log(`[camera] granted ${st.width}x${st.height} at ${st.frameRate ?? '?'} fps (asked ${S.camera.ask})`);
      return stream;
    } catch (e) {
      last = e;
      if (e?.name !== 'OverconstrainedError' && e?.name !== 'ConstraintNotSatisfiedError') throw e;
    }
  }
  throw last;
}

async function startCamera() {
  const why = unsupportedReason();
  if (why) { showGate(why); return; }
  openClaude();
  document.documentElement.dataset.go = '';   // loading only: the consent copy lives in the menu now
  el.gate.hidden = false; el.finish.hidden = true;
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
  tick_('enabled');
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
  S.glide.sample(t, S.nose.x, S.nose.y);
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
  renderCoach();
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
  if (was && centre) { DONE.centred = true; if (S.step < 0) startTutorial(); else renderCoach(); }
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

/** A ring spreads from the control a gesture pressed: the microphone for dictation, the composer's right end for send. */
function ripple(pane, kind) {
  const root = pane.el, base = root.getBoundingClientRect();
  const target = kind === 'mic' ? root.querySelector('.ic.mic') : root.querySelector('.ls-composer');
  if (!target) return;
  const r = target.getBoundingClientRect();
  const cx = kind === 'mic' ? r.left + r.width / 2 : r.right - 26, cy = r.top + r.height / 2;
  for (const cls of ['r1', 'r2']) {
    const ring = document.createElement('i'); ring.className = `ripple ${cls}`;
    ring.style.left = `${cx - base.left}px`; ring.style.top = `${cy - base.top}px`;
    root.append(ring); ring.addEventListener('animationend', () => ring.remove());
    setTimeout(() => ring.remove(), 1500);
  }
}

function beginDictation() {
  const pane = S.focus.target;
  if (!pane) { S.machine.abortTalk(); banner('info', 'No session in focus', 'Look at a session first'); return; }
  S.dict = { pane, start: now(), from: pane.typed };
  pane.el.classList.add('dictating'); ripple(pane, 'mic');
  tick_('dictated');
}

function endDictation(reason) {
  const d = S.dict;
  if (!d) return;
  d.pane.el.classList.remove('dictating'); if (reason === 'released' || reason === 'stem') ripple(d.pane, 'mic');
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
  ripple(pane, 'send');
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

// ---- the desktop: double-click Claude, then turn Ensemble on from the menu bar ------------------------------------

/** Claude's window opens from its icon. Idempotent: the camera and mouse paths call it too, so nothing can start with Claude closed. */
function openClaude() {
  if (S.opened) return;
  S.opened = true;
  el.mac.dataset.claude = 'open'; el.mbApp.textContent = 'Claude'; el.claudeIcon.classList.remove('selected');
  el.claudeIcon.setAttribute('aria-label', 'Claude. Open.');
  tick_('opened');
  for (const p of panes) stick(p);
  setTimeout(() => { refreshFrames(); for (const p of panes) stick(p); }, 650);   // after the window has settled into place
}

{
  // A double-click opens it. Two taps within 450 ms count too (touch), and Enter does for the keyboard.
  let lastTap = 0;
  el.claudeIcon.addEventListener('click', (e) => {
    if (S.opened) return;
    el.claudeIcon.classList.add('selected');
    const t = e.timeStamp;
    if (e.detail === 0 || e.detail >= 2 || t - lastTap < 450) openClaude();
    lastTap = t;
  });
  document.addEventListener('pointerdown', (e) => { if (!S.opened && !el.claudeIcon.contains(e.target)) el.claudeIcon.classList.remove('selected'); });
}

const menuOpen = () => !el.menu.hidden;
function toggleMenu(open = !menuOpen()) {
  el.menu.hidden = !open; el.mbEns.setAttribute('aria-expanded', String(open));
  if (open) { syncEns(); el.mpPower.focus({ preventScroll: true }); }
  placeTip();
}

/** Back to the empty desktop with Ensemble off, as the switch or Quit does in the app. */
function turnOff() {
  if (S.mode === 'none') return;
  S.resumeOnShow = false; stopCamera(); S.machine.reset(); endDictation('stopped'); endCentring(null);
  S.mode = 'none'; S.handSeen = null; S.faceSeen = null;
  el.app.dataset.mode = 'none'; el.stop.hidden = true; el.recentre.hidden = true;
  setState('desk'); syncEns();
}

/** The panel and the menu bar icon follow the state, with the app's own words (AppStatus.title, ScreenLayout.cameraLine). */
function syncEns() {
  const on = S.mode !== 'none';
  el.mbEns.classList.toggle('on', on);
  el.mbEns.setAttribute('aria-label', `Ensemble, in the menu bar. ${on ? 'On.' : 'Off.'}`);
  el.mpPower.setAttribute('aria-checked', String(on)); el.mpPower.classList.toggle('on', on);
  el.mpStatus.textContent = !on ? 'Off' : S.machine.talking ? 'Claude dictation on' : S.centring ? 'Needs calibration' : 'Watching';
  const fps = Math.round(S.camera?.frameRate || 0);
  el.mpCamera.textContent = S.mode === 'camera' ? `Your camera${fps ? ` · camera ${fps} fps` : ''}` : S.mode === 'mouse' ? 'No camera' : 'Your camera';
  el.mpScreen.textContent = on && DONE.centred ? 'Calibrated for this window' : 'Not calibrated';
  el.mbEns.classList.toggle('hint', S.opened && !on && !menuOpen());
  $('stem-btn').disabled = !on; $('phones-note').hidden = on;
}

const flip = (btn, on) => { btn.classList.toggle('on', on); btn.setAttribute('aria-checked', String(on)); };
el.mbEns.addEventListener('click', () => toggleMenu());
document.addEventListener('pointerdown', (e) => { if (menuOpen() && !el.menu.contains(e.target) && !el.mbEns.contains(e.target)) toggleMenu(false); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && menuOpen()) { toggleMenu(false); el.mbEns.focus(); } });
el.mpPower.addEventListener('click', () => {
  if (S.mode !== 'none') { turnOff(); return; }
  if (S.preferred === 'mouse' || phone) enterMouse(); else startCamera();
  toggleMenu(false);
});
el.mpQuit.addEventListener('click', () => { turnOff(); toggleMenu(false); });
el.mpDot.addEventListener('click', () => { S.showDot = !S.showDot; flip(el.mpDot, S.showDot); });
el.mpHl.addEventListener('click', () => { S.showHl = !S.showHl; flip(el.mpHl, S.showHl); });
el.mpCalibrate.addEventListener('click', () => { if (S.mode === 'camera') { toggleMenu(false); beginCentring(); } });
el.mpReplay.addEventListener('click', () => {
  toggleMenu(false); turnOff();
  for (const k of Object.keys(DONE)) DONE[k] = false;
  S.opened = false; S.step = -1; el.mac.dataset.claude = 'closed'; el.mbApp.textContent = 'Finder'; el.claudeIcon.setAttribute('aria-label', 'Claude. Double-click to open.');
  renderCoach();
});

// ---- the tour's tooltips: the setup steps (open Claude, turn on Ensemble, look) point at the thing to use and are not counted as steps ----

const tipEl = el.tip, spotEl = $('spot');
/** `at` is what the tooltip points at, `hole` what stays lit (default: `at`), `pad` the lit margin, `radius` its corner. */
const TIPS = {
  opened: () => ({ at: el.claudeIcon, pad: 8, radius: 18, side: 'left', html: phone ? 'Double-tap <strong>Claude</strong> to open it.' : 'Double-click <strong>Claude</strong> to open it.' }),
  enabled: () => (menuOpen()
    ? { at: el.mpPower, hole: el.menu, also: el.mbEns, pad: 4, radius: 26, side: 'left', html: mouseish() ? 'Flip the switch to turn <strong>Ensemble</strong> on. The mouse stands in for your hands.' : 'Flip the switch to turn <strong>Ensemble</strong> on. It asks for your camera; the video stays in this tab, and about 12 MB downloads.' }
    : { at: el.mbEns, pad: 6, radius: 10, side: 'below', html: 'Click the <strong>Ensemble</strong> icon in the menu bar.' }),
  looked: () => (S.mode !== 'none' && !S.centring ? { at: $('window'), pad: 0, radius: 12, side: 'inside', html: mouseish() ? 'Move the mouse around the screen to select a session.' : 'Look around the screen to select and activate a session. The <strong>blue outline</strong> follows your nose.' } : null),
};
function placeTip() {
  const cur = currentStep(), spec = !el.finish.hidden || !el.gate.hidden ? null : TIPS[cur]?.();
  if (!spec) { tipEl.hidden = true; spotEl.hidden = true; return; }
  if (el.tipText.innerHTML !== spec.html) el.tipText.innerHTML = spec.html;
  const vw = innerWidth, vh = innerHeight, first = tipEl.hidden || spotEl.hidden;
  tipEl.hidden = false; spotEl.hidden = false; tipEl.dataset.side = spec.side;
  const r = spec.at.getBoundingClientRect(), pad = spec.pad;
  let h = (spec.hole || spec.at).getBoundingClientRect();
  if (spec.also) {   // keep the menu-bar item lit together with its panel
    const o = spec.also.getBoundingClientRect(), l = Math.min(h.left, o.left), t = Math.min(h.top, o.top), rr = Math.max(h.right, o.right), bb = Math.max(h.bottom, o.bottom);
    h = { left: l, top: t, right: rr, bottom: bb, width: rr - l, height: bb - t };
  }
  const tw = tipEl.offsetWidth, th = tipEl.offsetHeight;
  let x, y, ax = tw / 2;
  if (spec.side === 'left') { x = h.left - pad - tw - 16; y = r.top + r.height / 2 - th / 2; }
  else if (spec.side === 'below') { x = r.left + r.width / 2 - tw / 2; y = h.bottom + pad + 14; }
  else { x = h.left + (h.width - tw) / 2; y = h.top + 64; }   // inside the lit window, below the pane titles
  const nx = Math.min(Math.max(x, 12), vw - tw - 12), ny = Math.min(Math.max(y, 12), vh - th - 12);
  ax = r.left + r.width / 2 - nx; x = nx; y = ny;
  const put = (node, tx, ty) => { if (first) { node.style.transition = 'none'; } node.style.transform = `translate(${Math.round(tx)}px, ${Math.round(ty)}px)`; if (first) { void node.offsetWidth; node.style.transition = ''; } };
  tipEl.style.setProperty('--ax', `${Math.round(ax)}px`);
  put(tipEl, x, y);
  spotEl.style.width = `${Math.round(h.width + 2 * pad)}px`; spotEl.style.height = `${Math.round(h.height + 2 * pad)}px`; spotEl.style.borderRadius = `${spec.radius}px`;
  put(spotEl, h.left - pad, h.top - pad);
}

// ---- the guide column: a progressor that collapses finished steps and opens the next, and the hand that shows the gesture ----

const RAIL = ['dictated', 'sent', 'scrolled'];   // the counted steps; opening Claude, turning on, centring and looking are tooltips, install a closing note
const ORDER = ['opened', 'enabled', 'centred', 'looked', ...RAIL, 'install'];
const DONE = { opened: false, enabled: false, centred: false, looked: false, dictated: false, sent: false, scrolled: false, install: false };
const APPLE_GUIDE = 'https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac';
const TITLES = { opened: 'Open Claude', enabled: 'Turn on Ensemble', centred: 'Centre your head', looked: 'Look at a session', dictated: 'Dictate', sent: 'Send', scrolled: 'Scroll', install: 'Before you open it' };
const both = (t) => ({ camera: t, mouse: t });
const HINTS = {
  opened: { camera: 'Double-click the <strong>Claude</strong> icon on the desktop.', mouse: 'Double-click the <strong>Claude</strong> icon on the desktop.', touch: 'Double-tap the <strong>Claude</strong> icon on the desktop.' },
  enabled: both('Click the Ensemble icon in the menu bar, then flip the switch to turn <strong>Ensemble</strong> on.'),
  centred: { camera: 'Point your nose at the glass dot and hold still for three seconds.', mouse: '' },
  looked: { camera: 'Look around the screen to select and activate a session. The blue outline follows your nose.', mouse: 'Move the mouse around the screen to select a session.' },
  dictated: { camera: '<strong>Double pinch</strong> (thumb and index, twice, quickly) to dictate into the session you are looking at.', mouse: '<strong>Click twice</strong>, quickly, to dictate into the session under the mouse.' },
  sent: { camera: 'Hold a <strong>thumbs-up</strong> to send what was typed.', mouse: 'Press and hold still: that is the <strong>thumbs-up</strong>. It sends.' },
  scrolled: { camera: '<strong>Pinch and drag</strong> up or down to scroll the session you are looking at.', mouse: 'Press and <strong>drag</strong> up or down to scroll the session under the mouse.' },
  install: both(`Ensemble is <strong>unsigned</strong>: Akshay has not set up an Apple Developer certificate yet, so macOS blocks the first launch. After you download it, <a href="${APPLE_GUIDE}" target="_blank" rel="noopener">Apple's guide shows how to open it anyway</a>.`),
};
const SCENE = { dictated: 'dictate', sent: 'send', scrolled: 'scroll' };
const CAPTION = { dictated: ['Double pinch', 'Double click'], sent: ['Thumbs-up, hold', 'Press and hold'], scrolled: ['Pinch and drag', 'Press and drag'], headphones: ['Press once, press twice', 'Press once, press twice'], install: ['Unsigned app', 'Unsigned app'] };

const ART = {
  dictated: '<svg viewBox="0 0 160 120"><circle class="a-tip t1" cx="64" cy="60" r="11"/><circle class="a-tip t2" cx="96" cy="60" r="11"/></svg>',
  sent: '<svg viewBox="0 0 160 120"><circle class="a-trk" cx="80" cy="60" r="34"/><path class="a-send" d="M60 62 100 46 90 80 79 66z"/></svg>',
  headphones: '<svg viewBox="0 0 160 120"><circle class="a-rip p1" cx="74" cy="88" r="10"/><circle class="a-rip p2" cx="74" cy="88" r="10"/><circle class="a-rip p3" cx="74" cy="88" r="10"/><path class="a-pod" d="M52 40a24 24 0 0 1 48 0c0 10-5 17-12 20v34a7 7 0 0 1-14 0V60c-12-3-22-9-22-20z"/><circle class="a-podhole" cx="66" cy="40" r="6"/></svg>',
  scrolled: '<svg viewBox="0 0 160 120"><path class="a-arrow up" d="M80 24 66 40h28z"/><rect class="a-trk2" x="72" y="44" width="16" height="32" rx="8"/><path class="a-arrow down" d="M80 96 66 80h28z"/></svg>',
};

const steps = {};
for (const k of [...RAIL, 'install']) {
  const li = document.createElement('li');
  li.className = k === 'install' ? 'step note' : 'step'; li.dataset.k = k; li.dataset.state = 'todo';
  li.innerHTML = `<i class="step-dot" aria-hidden="true"></i><h3 class="step-title">${TITLES[k]}</h3><div class="step-body"><div><p></p></div></div>`;
  el.steps.append(li); steps[k] = { li, text: li.querySelector('p'), shown: '' };
}

// ---- headphones: an optional second tab, never part of the progressor. A press on the stem, one or two. The Mac app hears these from AirPods and
// other Bluetooth headphones (HeadphoneRemote); the browser cannot, so a button stands in for the stem, and the media keys do the same where reported. ----

const stemDone = { once: false, twice: false };
const tabs = { gestures: { tab: $('tab-g'), panel: $('panel-g') }, headphones: { tab: $('tab-h'), panel: $('panel-h') } };
let activeTab = 'gestures';
function selectTab(name, focus = false) {
  activeTab = name;
  for (const [k, t] of Object.entries(tabs)) {
    const on = k === name;
    t.tab.setAttribute('aria-selected', String(on)); t.tab.tabIndex = on ? 0 : -1; t.panel.hidden = !on;
    if (on && focus) t.tab.focus();
  }
  renderCoach();
}
for (const [k, t] of Object.entries(tabs)) {
  t.tab.addEventListener('click', () => selectTab(k));
  t.tab.addEventListener('keydown', (e) => { if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.preventDefault(); selectTab(k === 'gestures' ? 'headphones' : 'gestures', true); } });
}
$('stem-skip').addEventListener('click', () => selectTab('gestures', true));
{
  const state = $('stem-state'), btn = $('stem-btn');
  let timer = 0;
  const paint = () => { state.textContent = stemDone.once || stemDone.twice ? `Once ${stemDone.once ? 'done' : 'to do'}, twice ${stemDone.twice ? 'done' : 'to do'}` : ''; };
  /** One press toggles dictation like the double pinch; two presses send like the thumbs-up. Presses do nothing until Ensemble is on. */
  function stem(n) {
    if (S.mode === 'none') return;
    if (n === 1) {
      if (S.machine.talking) { S.machine.pressTalk(false); endDictation('stem'); }
      else { S.machine.pressTalk(true); beginDictation(); }
      stemDone.once = true;
    } else {
      if (S.machine.talking) { S.machine.pressTalk(false); endDictation('sent'); }
      send(); stemDone.twice = true;
    }
    paint();
  }
  btn.addEventListener('click', () => {
    if (timer) { clearTimeout(timer); timer = 0; stem(2); return; }   // a second press inside the window: a double press
    timer = setTimeout(() => { timer = 0; stem(1); }, 320);
  });
  addEventListener('keydown', (e) => { if (e.key === 'MediaPlayPause') { e.preventDefault(); stem(1); } else if (e.key === 'MediaTrackNext') { e.preventDefault(); stem(2); } });
  S.stem = stem;
}

const mouseish = () => S.mode === 'mouse' || S.preferred === 'mouse' || phone;
const modeKey = () => (mouseish() ? 'mouse' : 'camera');
const hintFor = (k) => (phone && HINTS[k].touch) || HINTS[k][modeKey()];
const currentStep = () => ORDER.find((k) => !DONE[k] && !(k === 'centred' && mouseish()));

function tick_(k) {
  if (DONE[k]) return;
  DONE[k] = true; renderCoach();
}

function renderCoach() {
  const cur = currentStep(), m = modeKey();
  for (const k of [...RAIL, 'install']) {
    const st = steps[k];
    st.li.hidden = k === 'install' && cur !== 'install' && !DONE.install;
    st.li.dataset.state = DONE[k] ? 'done' : k === cur ? 'current' : 'todo';
    const h = hintFor(k);
    if (st.shown !== h) { st.shown = h; st.text.innerHTML = h; }
  }
  const n = RAIL.filter((k) => DONE[k]).length;
  el.meterText.textContent = n === RAIL.length ? 'All 3 done' : RAIL.includes(cur) ? `Step ${n + 1} of 3` : '3 steps';
  el.meterBar.style.width = `${Math.round((n / RAIL.length) * 100)}%`;
  el.prompt.innerHTML = cur ? hintFor(cur) : 'That is everything. Keep playing, or see the download.';
  el.done.hidden = cur !== 'install';
  showGuide(activeTab === 'headphones' ? 'headphones' : cur, m);
  placeTip();
}

// ---- the 3D hand: the scene the letter and the Mac app's tour use, hand only, loaded the first time a step is about to need it ----

const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const saveData = !!(navigator.connection && (navigator.connection.saveData || /(^|-)2g$/.test(navigator.connection.effectiveType || '')));
const hasGL = () => { try { const c = document.createElement('canvas'), g = c.getContext('webgl'); if (!g) return false; g.getExtension('WEBGL_lose_context')?.loseContext(); return true; } catch { return false; } };
const loadJS = (src) => new Promise((res, rej) => { const sc = document.createElement('script'); sc.src = src; sc.onload = res; sc.onerror = () => rej(new Error(src)); document.head.append(sc); });
let handLibs = null, handInst = null, handScene = '', artKey = '';

/** Three.js and the scene module, in the order they need: the recorded hand motion must be defined before the scene module runs. */
function ensureHandLibs() {
  if (handLibs) return handLibs;
  handLibs = phone || saveData || !hasGL()
    ? Promise.reject(new Error('no 3D'))
    : loadJS('../assets/3d/three.min.js').then(() => Promise.all([loadJS('../assets/3d/GLTFLoader.js'), loadJS('../assets/3d/CCDIKSolver.js'), loadJS('../assets/3d/capture-default.js')])).then(() => loadJS('../assets/3d/scene3d.js'));
  handLibs.catch(() => {});
  return handLibs;
}

function showArt(k) {
  if (artKey === k) return;
  artKey = k; el.art.innerHTML = k ? ART[k] : ''; el.art.dataset.k = k;
}

/** The hand panel is for gestures. While the setup tooltips run it previews the first gesture (or stays blank until the files load); drawn pictures are
 *  only the fallback for the gesture steps and the headphones tab, never a copy of what a tooltip already shows. */
const ART_STEPS = ['dictated', 'sent', 'scrolled', 'headphones'];
function showGuide(cur, m) {
  const setup = ['opened', 'enabled', 'centred', 'looked'].includes(cur);
  const scene = SCENE[cur] || (setup && cur !== 'opened' ? 'dictate' : cur === 'install' ? 'scroll' : null);
  const cap = CAPTION[cur] || (setup ? CAPTION.dictated : null);
  const mi = m === 'camera' ? 0 : 1;
  el.handCap.textContent = cur === 'install' ? 'All three done' : setup ? (cur === 'opened' ? 'Gestures show up here' : `Coming up: ${cap[mi].toLowerCase()}`) : cap ? cap[mi] : '';
  if (cur === 'opened' || cur === 'enabled') ensureHandLibs();   // warm the files while the visitor is still on the desktop
  if (!scene) { el.hand.classList.remove('on'); showArt(ART_STEPS.includes(cur) ? cur : ''); return; }
  ensureHandLibs().then(() => {
    if (currentStep() !== cur && activeTab !== 'headphones') return;
    if (!handInst) {
      handInst = window.EnsembleScene.mount(el.hand, { scene, handOnly: true, reducedMotion: reduce, handUrl: '../assets/3d/hand.glb' });
      handScene = scene;
      if (!handInst.canvas) { handInst = null; throw new Error('no 3D'); }
    } else if (handScene !== scene) { handInst.setScene(scene); handScene = scene; }
    el.hand.classList.add('on'); showArt('');
  }).catch(() => { el.hand.classList.remove('on'); showArt(ART_STEPS.includes(cur) ? cur : ''); });
}

function startTutorial() { S.step = 0; renderCoach(); }

function finish() {
  tick_('install');
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

let frameAt = 0;
function renderOverlays(t, target) {
  if (S.centring) renderCentre(t);
  // the blue outline follows the focused pane with a spring; it breathes while dictating
  if (t - frameAt > 0.5) { frameAt = t; refreshFrames(); }
  if (target && S.showHl && el.app.dataset.state === 'running' && !S.centring) {
    const f = target.frame, i = 4;
    el.hl.style.width = `${Math.max(f.w - 2 * i, 0)}px`; el.hl.style.height = `${Math.max(f.h - 2 * i, 0)}px`;
    el.hl.style.transform = `translate(${f.x + i}px, ${f.y + i}px)`;
    el.hl.classList.add('on');
    el.hl.classList.toggle('listening', S.machine.talking);
  } else el.hl.classList.remove('on', 'listening');
  // the glass-bead dot is drawn every display frame: the latest tracker sample, its velocity carried forward for at most one sample,
  // and a short glide (NoseGlide), so it moves continuously instead of stepping at the camera rate
  const pos = S.mode === 'camera' && !S.centring && S.showDot ? S.glide.frame(t) : null;
  if (pos) {
    el.dot.style.transform = `translate3d(${pos.x.toFixed(2)}px, ${pos.y.toFixed(2)}px, 0)`;
    el.dot.classList.add('on'); S.dotMoves += 1;
    el.dot.classList.toggle('scroll', showsScrollGlyph(S.machine.isDragging, S.machine.pinchHeld));
  } else { el.dot.classList.remove('on'); if (S.mode !== 'camera' || S.centring) S.glide.reset(); }
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
  syncEns(); placeTip();
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
  // The demo always opens on the empty desktop: the visitor opens Claude, then turns Ensemble on from the menu bar. The letter's ?go=1 only says
  // the camera is already allowed (no second prompt), and ?mouse=1 that the visitor chose the mouse there, so the menu offers just that.
  const q = new URLSearchParams(location.search);
  delete document.documentElement.dataset.go;
  if (q.get('mouse') === '1' || phone) S.preferred = 'mouse';
  if (phone) el.claudeIcon.setAttribute('aria-label', 'Claude. Double-tap to open.');
  syncEns(); renderCoach();
}

window.__live = {
  get mode() { return S.mode; }, done: () => ({ ...DONE }), get delegate() { return trackers.delegate; },
  camera: () => S.camera,
  stem: (n) => S.stem(n), tab: () => activeTab,
  opened: () => S.opened, step: () => currentStep(), openClaude, menu: () => ({ open: menuOpen(), state: el.mpStatus.textContent }), tip: () => (el.tip.hidden ? null : el.tipText.textContent),
  dotMoves: () => S.dotMoves,
  stats: () => ({ face: trackers.summary('face'), hand: trackers.summary('hand'), warmed: !trackers.warming, frames: { ...S.frames }, delegate: trackers.delegate, handHz: S.scheduler.handHz, faceHz: S.scheduler.faceHz }),
  focus: () => S.focus.target?.id ?? null,
  draft: (id) => panes.find((p) => p.id === id)?.draft ?? null,
  talking: () => S.machine.talking,
  // test hooks: feed one synthetic head reading (radians) as if the face tracker had seen it; read the centring state
  suppressHand: () => { S.noHand = true; },
  feedHead: (yaw, pitch) => readHead(now(), yaw, pitch, null),
  centring: () => ({ active: S.centring, state: el.centre.dataset.state, count: S.centre?.count ?? null, progress: S.centre?.progress ?? null, line: el.centreLine.textContent }),
  centre: () => S.head.centre,
  feedPinch: (d, y = 0.5) => { const t = now(), obs = { t, present: true, pose: null, palmCenter: { x: 0.5, y }, pinch: d, pinchSource: 'test' }; S.adapt.push(d); S.machine.pinchClosed = S.adapt.closed; S.machine.pinchOpen = S.adapt.open; feed(obs); showPinch(obs, t); },
  pinch: () => ({ closed: S.adapt.closed, open: S.adapt.open, dips: S.adapt.dips.length }),
};
