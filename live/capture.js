// Records Ensemble's gestures from the webcam as per-frame hand data. Everything stays in this tab; the only way data leaves
// is the file the user saves (or the JSON they copy).

import { Trackers, unsupportedReason } from './tracker.js';

const TAKES = [
  { id: 'rest', title: 'Rest', seconds: 4, optional: false, text: 'Raise your hand, relaxed and still.' },
  { id: 'dictate', title: 'Dictate', seconds: 6, optional: false, text: 'Double pinch (thumb and index, two quick taps), pause 1 second, double pinch again.' },
  { id: 'send', title: 'Send', seconds: 5, optional: false, text: 'From relaxed, make a thumbs-up, hold it 1.5 seconds, then relax.' },
  { id: 'scroll', title: 'Scroll', seconds: 6, optional: false, text: 'Pinch and hold, move your hand up about 10 cm, then down, then release.' },
  { id: 'look', title: 'Look', seconds: 2, optional: true, text: 'Put your hand down, out of view.' },
];
const COUNTDOWN = 3;
const $ = (id) => document.getElementById(id);
const log = (m) => console.log(`[${new Date().toISOString()}] ${m}`);
const r5 = (n) => Math.round(n * 1e5) / 1e5;

const trackers = new Trackers();
const state = { stream: null, running: false, raf: 0, takes: {}, active: null, fps: [], lastVideoTime: -1, video: $('video'), busy: false };
const ctx = $('overlay').getContext('2d');
const BONES = [[0,1],[1,2],[2,3],[3,4],[0,5],[5,6],[6,7],[7,8],[5,9],[9,10],[10,11],[11,12],[9,13],[13,14],[14,15],[15,16],[13,17],[17,18],[18,19],[19,20],[0,17]];

function say(t) { $('msg').textContent = t || ''; }

// ---- takes list ----
function buildList() {
  $('takes').innerHTML = '';
  for (const t of TAKES) {
    const li = document.createElement('li');
    li.className = 'cp-take'; li.id = 'take-' + t.id;
    li.innerHTML = `<div class="cp-take-top"><h2>${t.title}<small>${t.seconds} s${t.optional ? ', optional' : ''}</small></h2><span class="cp-state">not recorded</span></div>
      <p>${t.text}</p><div class="cp-bar"><i></i></div>
      <div class="cp-actions"><button type="button" class="cp-btn primary rec">Record</button>${t.optional ? '<button type="button" class="cp-btn skip">Skip</button>' : ''}</div>`;
    li.querySelector('.rec').addEventListener('click', () => record(t));
    li.querySelector('.skip')?.addEventListener('click', () => { delete state.takes[t.id]; refresh(); });
    $('takes').append(li);
  }
  refresh();
}

function refresh() {
  const camOn = !!state.stream && !!trackers.hand;
  let n = 0;
  for (const t of TAKES) {
    const li = $('take-' + t.id), frames = state.takes[t.id];
    const done = !!frames; if (done) n++;
    li.classList.toggle('done', done);
    li.classList.toggle('active', state.active?.id === t.id);
    if (state.active?.id !== t.id) li.querySelector('.cp-state').textContent = done ? `${frames.length} frames` : 'not recorded';
    const rec = li.querySelector('.rec');
    rec.textContent = done ? 'Retake' : 'Record';
    rec.disabled = !camOn || state.busy;
    const skip = li.querySelector('.skip'); if (skip) skip.disabled = state.busy;
  }
  $('taken').textContent = `(${n} of ${TAKES.length} takes)`;
  const has = n > 0;
  $('save').disabled = !has; $('copy').disabled = !has;
  $('size').textContent = has ? fmtBytes(new Blob([payload()]).size) : '0 B';
}

function fmtBytes(b) { return b < 1024 ? b + ' B' : b < 1048576 ? (b / 1024).toFixed(1) + ' KB' : (b / 1048576).toFixed(2) + ' MB'; }

function averageFps() {
  let frames = 0, ms = 0;
  for (const f of Object.values(state.takes)) if (f.length > 1) { frames += f.length - 1; ms += f[f.length - 1].t - f[0].t; }
  return ms > 0 ? Math.round((frames / ms) * 1000 * 10) / 10 : 0;
}

function payload() {
  const v = state.video;
  return JSON.stringify({
    version: 1,
    takes: state.takes,
    camera: { width: v.videoWidth || 0, height: v.videoHeight || 0 },
    fps: averageFps(),
    // Handedness is MediaPipe's label for the unmirrored camera image; the preview is only mirrored by CSS.
    note: 'frame: t ms from take start, hand Left|Right|null, world 21x[x,y,z] metres, image 21x[x,y,z] normalized, gesture, score',
  });
}

// ---- camera ----
async function startCamera() {
  const why = unsupportedReason();
  if (why) { say(why); return; }
  $('camera').disabled = true;
  try {
    say('Asking for the camera.');
    state.stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 } }, audio: false });
    state.video.srcObject = state.stream;
    await state.video.play();
    log(`camera on ${state.video.videoWidth}x${state.video.videoHeight}`);
    $('idle').hidden = true; $('stop').hidden = false; $('camera').hidden = true;
    if (!trackers.hand) {
      $('r-tracker').textContent = 'loading';
      await trackers.load({ onProgress: (f) => { $('r-tracker').textContent = `loading ${Math.round(f * 100)}%`; say(''); }, log });
      await trackers.warmUp(state.video);
    }
    $('r-tracker').textContent = trackers.delegate;
    log(`tracker ready (${trackers.delegate})`);
    say('');
    state.running = true; loop();
  } catch (e) {
    console.error(e);
    say(e?.name === 'NotAllowedError' ? 'The camera is blocked. Allow it in the address bar and try again.' : 'Could not start: ' + (e?.message || e));
    stopCamera();
  }
  refresh();
}

function stopCamera() {
  state.running = false; cancelAnimationFrame(state.raf);
  state.stream?.getTracks().forEach((t) => t.stop()); state.stream = null;
  state.video.srcObject = null;
  $('idle').hidden = false; $('stop').hidden = true; $('camera').hidden = false; $('camera').disabled = false;
  ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
  $('r-hand').textContent = 'off';
  refresh();
}

// ---- per-frame loop ----
function readHand(video, nowMs) {
  // Same call as Trackers.detectHand, kept here to also get handedness, which that method drops.
  const h = trackers.hand; if (!h) return null;
  trackers.lastHandTs = Math.max(trackers.lastHandTs + 1, Math.round(nowMs));
  const t0 = performance.now();
  const r = h.recognizeForVideo(video, trackers.lastHandTs);
  trackers.record('hand', performance.now() - t0);
  const lm = r.landmarks?.[0]; if (!lm) return null;
  const g = r.gestures?.[0]?.[0];
  return { landmarks: lm, world: r.worldLandmarks?.[0] ?? null, hand: r.handedness?.[0]?.[0]?.categoryName ?? r.handednesses?.[0]?.[0]?.categoryName ?? null, gesture: g?.categoryName ?? null, score: g?.score ?? 0 };
}

function loop() {
  if (!state.running) return;
  state.raf = requestAnimationFrame(loop);
  const v = state.video;
  if (v.readyState < 2 || v.currentTime === state.lastVideoTime) return;
  state.lastVideoTime = v.currentTime;
  const now = performance.now();
  let res = null;
  try { res = readHand(v, now); } catch (e) { console.error(e); say('Tracker error: ' + (e?.message || e)); }
  state.fps.push(now); while (state.fps.length && now - state.fps[0] > 1000) state.fps.shift();
  $('r-fps').textContent = state.fps.length;
  $('r-hand').textContent = res ? (res.hand || 'found') : 'none';
  $('r-gesture').textContent = res?.gesture && res.gesture !== 'None' ? `${res.gesture} ${res.score.toFixed(2)}` : 'none';
  draw(res);
  const a = state.active;
  if (a && a.recording) {
    a.frames.push({
      t: Math.round(now - a.t0),
      hand: res?.hand ?? null,
      world: res?.world ? res.world.map((p) => [r5(p.x), r5(p.y), r5(p.z)]) : null,
      image: res ? res.landmarks.map((p) => [r5(p.x), r5(p.y), r5(p.z)]) : null,
      gesture: res?.gesture ?? null,
      score: res ? r5(res.score) : 0,
    });
  }
}

function draw(res) {
  const c = ctx.canvas, v = state.video;
  if (c.width !== v.videoWidth) { c.width = v.videoWidth; c.height = v.videoHeight; }
  ctx.clearRect(0, 0, c.width, c.height);
  if (!res) return;
  const P = res.landmarks.map((p) => [p.x * c.width, p.y * c.height]);
  ctx.lineWidth = Math.max(2, c.width / 320); ctx.strokeStyle = '#5294ff'; ctx.lineCap = 'round';
  ctx.beginPath(); for (const [a, b] of BONES) { ctx.moveTo(...P[a]); ctx.lineTo(...P[b]); } ctx.stroke();
  ctx.fillStyle = '#fff';
  for (const [x, y] of P) { ctx.beginPath(); ctx.arc(x, y, ctx.lineWidth * 1.3, 0, 7); ctx.fill(); }
}

// ---- recording a take ----
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function record(t) {
  if (state.busy || !state.running) return;
  state.busy = true;
  const li = $('take-' + t.id), bar = li.querySelector('.cp-bar i'), stateEl = li.querySelector('.cp-state');
  const a = { id: t.id, frames: [], recording: false, t0: 0 };
  state.active = a;
  li.classList.add('active'); bar.style.width = '0';
  refresh();
  log(`take ${t.id}: countdown`);
  for (let i = COUNTDOWN; i >= 1; i--) { $('count').hidden = false; $('count').textContent = i; stateEl.textContent = `starting in ${i}`; await sleep(1000); }
  $('count').hidden = true;
  a.t0 = performance.now(); a.recording = true;
  stateEl.textContent = 'recording';
  while (performance.now() - a.t0 < t.seconds * 1000 && state.running) {
    bar.style.width = Math.min(100, ((performance.now() - a.t0) / (t.seconds * 1000)) * 100) + '%';
    await sleep(50);
  }
  a.recording = false; bar.style.width = '100%';
  if (state.running && a.frames.length) state.takes[t.id] = a.frames;
  const seen = a.frames.filter((f) => f.world).length;
  log(`take ${t.id}: ${a.frames.length} frames, ${seen} with a hand`);
  if (a.frames.length && !seen) say(`No hand was seen during ${t.title}. Retake if that was not intended.`); else say('');
  state.active = null; state.busy = false;
  li.classList.remove('active');
  refresh();
}

// ---- save ----
function save() {
  const json = payload();
  const date = new Date().toISOString().slice(0, 10);
  const url = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
  const a = document.createElement('a'); a.href = url; a.download = `ensemble-hand-capture-${date}.json`;
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
  log(`saved ${fmtBytes(json.length)}`); say('Saved to your downloads.');
}

async function copy() {
  try { await navigator.clipboard.writeText(payload()); say('Copied the JSON.'); }
  catch (e) { say('Copy was refused by the browser. Use Save recording instead.'); }
}

$('camera').addEventListener('click', startCamera);
$('stop').addEventListener('click', stopCamera);
$('save').addEventListener('click', save);
$('copy').addEventListener('click', copy);
buildList();
log('capture page ready');
