// node --test docs/live/test : the ported pure logic, replayed with explicit clocks.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  OneEuroFilter, GestureMachine, FocusTracker, sessionAt, FOCUS, observationFromHand, handFromLandmarks, J,
  HeadPointer, CentreStep, HEAD, pinchMeasure, PinchAdapt, PINCH, AxisSign, anglesFromMatrix, noseOffset, FrameScheduler, PointerHand, islandMode, wordsTyped, classify,
} from '../logic.js';

const near = (a, b, e = 1e-9) => assert.ok(Math.abs(a - b) <= e, `${a} vs ${b}`);

// A Vision-style hand (y up), wrist at the origin-ish, palm length 0.2 (wrist to middle knuckle).
function handWith({ pinch = 0.5, thumbUp = false, curled = false, at = { x: 0.5, y: 0.4 } } = {}) {
  const p = Array.from({ length: 21 }, () => ({ x: at.x, y: at.y }));
  const W = { x: at.x, y: at.y };
  p[J.wrist] = W;
  p[J.middleMCP] = { x: at.x, y: at.y + 0.2 };
  p[J.indexMCP] = { x: at.x - 0.04, y: at.y + 0.19 };
  p[J.ringMCP] = { x: at.x + 0.03, y: at.y + 0.19 };
  p[J.littleMCP] = { x: at.x + 0.06, y: at.y + 0.17 };
  p[J.thumbIP] = { x: at.x - 0.08, y: at.y + 0.12 };
  p[J.indexTip] = { x: at.x - 0.04, y: at.y + 0.38 };
  p[J.indexPIP] = { x: at.x - 0.04, y: at.y + 0.27 };
  p[J.middlePIP] = { x: at.x, y: at.y + 0.28 }; p[J.middleTip] = { x: at.x, y: at.y + 0.4 };
  p[J.ringPIP] = { x: at.x + 0.03, y: at.y + 0.27 }; p[J.ringTip] = { x: at.x + 0.03, y: at.y + 0.38 };
  p[J.littlePIP] = { x: at.x + 0.06, y: at.y + 0.24 }; p[J.littleTip] = { x: at.x + 0.06, y: at.y + 0.33 };
  if (curled) for (const [t, q] of [[J.indexTip, J.indexPIP], [J.middleTip, J.middlePIP], [J.ringTip, J.ringPIP], [J.littleTip, J.littlePIP]]) {
    p[t] = { x: p[q].x, y: at.y + 0.12 }; p[q] = { x: p[q].x, y: at.y + 0.2 };
  }
  if (thumbUp) p[J.thumbTip] = { x: at.x - 0.07, y: at.y + 0.42 };
  else p[J.thumbTip] = { x: p[J.indexTip].x + pinch * 0.2, y: p[J.indexTip].y };
  return { points: p };
}

test('one euro: first sample passes, a constant stays, a step is followed but smoothed', () => {
  const f = new OneEuroFilter(0.6, 3, 1);
  assert.equal(f.filter(5, 0), 5);
  near(f.filter(5, 0.033), 5);
  const y = f.filter(10, 0.066);
  assert.ok(y > 5 && y < 10);
  assert.equal(f.filter(NaN, 0.1), f.lastFiltered);
  assert.equal(f.filter(7, 0.066), f.lastFiltered, 'a non-advancing clock changes nothing');
});

test('one euro: slow drift is smoothed harder than fast motion follows', () => {
  const slow = new OneEuroFilter(), fast = new OneEuroFilter();
  slow.filter(0, 0); fast.filter(0, 0);
  let s = 0, q = 0;
  for (let i = 1; i <= 30; i++) { s = slow.filter(i * 0.001, i / 30); q = fast.filter(i * 0.1, i / 30); }
  assert.ok(Math.abs(s - 0.03) < 0.01);
  assert.ok(q > 2.0, `fast follows (${q})`);
});

test('pinch distance is thumb tip to index tip in palm lengths', () => {
  const h = handWith({ pinch: 0.5 });
  const o = observationFromHand(h, 1);
  // thumb-index gap 0.5 * 0.2 = 0.1, palm 0.2 -> 0.5 palms
  near(o.pinch, 0.5, 1e-6);
  const closed = observationFromHand(handWith({ pinch: 0.05 }), 1);
  near(closed.pinch, 0.05, 1e-6);
  assert.equal(observationFromHand(null, 2).present, false);
});

test('mediapipe landmarks are flipped to y up', () => {
  const h = handFromLandmarks([{ x: 0.2, y: 0.9 }]);
  near(h.points[0].y, 0.1);
});

const obs = (t, pinch, extra = {}) => ({ t, present: true, pose: null, palmCenter: { x: 0.5, y: 0.5 }, pinch, ...extra });

function run(m, script) {
  // script: [[t, pinch]...] at 30 Hz-ish, returns every intent type in order
  const out = [];
  for (const [t, d, extra] of script) for (const i of m.push(obs(t, d, extra))) out.push(i);
  return out;
}

function taps(start, count, { closedFor = 0.12, gap = 0.2 } = {}) {
  const s = []; let t = start;
  for (let k = 0; k < count; k++) {
    for (let i = 0; i < Math.round(closedFor * 30); i++) { s.push([t, 0.05]); t += 1 / 30; }
    for (let i = 0; i < Math.round(gap * 30); i++) { s.push([t, 0.5]); t += 1 / 30; }
  }
  return { s, end: t };
}

test('double pinch begins dictation on the second touch, and a second double pinch ends it', () => {
  const m = new GestureMachine();
  const a = taps(0, 2);
  const out = run(m, a.s);
  assert.deepEqual(out.map((i) => i.type), ['talkBegan']);
  assert.equal(m.talking, true);
  const b = taps(a.end + 1, 2);
  const out2 = run(m, b.s);
  assert.deepEqual(out2.map((i) => i.type), ['talkEnded']);
  assert.equal(out2[0].reason, 'released');
  assert.equal(m.talking, false);
});

test('a single pinch does nothing; two pinches further apart than the gap do nothing', () => {
  const m = new GestureMachine();
  assert.deepEqual(run(m, taps(0, 1).s), []);
  const m2 = new GestureMachine();
  const first = taps(0, 1), second = taps(first.end + 1.5, 1);
  assert.deepEqual(run(m2, [...first.s, ...second.s]), []);
});

test('a pinch held longer than two seconds never counts as a tap', () => {
  const m = new GestureMachine();
  const s = []; let t = 0;
  for (let i = 0; i < 90; i++, t += 1 / 30) s.push([t, 0.05]);
  for (let i = 0; i < 10; i++, t += 1 / 30) s.push([t, 0.5]);
  const rest = taps(t, 1);
  assert.deepEqual(run(m, [...s, ...rest.s]), []);
});

test('the pinch needs two consecutive closed frames (a single noisy frame is ignored)', () => {
  const m = new GestureMachine();
  const s = [[0, 0.5], [0.03, 0.05], [0.06, 0.5], [0.09, 0.5], [0.4, 0.05], [0.43, 0.5], [0.46, 0.5]];
  assert.deepEqual(run(m, s), []);
});

test('thumbs-up held 0.75 s sends once, and not before', () => {
  const m = new GestureMachine(); m.sendHold = 0.75;
  const early = [];
  for (let t = 0; t < 0.7; t += 1 / 30) early.push(...m.push({ t, present: true, pose: 'thumbsUp', palmCenter: { x: 0.5, y: 0.5 }, pinch: 0.9 }));
  assert.deepEqual(early, []);
  assert.equal(m.progress.action, 'send');
  assert.ok(m.progress.progress > 0.85 && m.progress.progress < 1);
  const late = [];
  for (let t = 0.7; t < 1.2; t += 1 / 30) late.push(...m.push({ t, present: true, pose: 'thumbsUp', palmCenter: { x: 0.5, y: 0.5 }, pinch: 0.9 }));
  assert.deepEqual(late.map((i) => i.type), ['sendRequested']);
});

test('a thumbs-up interrupted before the hold sends nothing', () => {
  const m = new GestureMachine(); m.sendHold = 0.75;
  const out = [];
  for (let t = 0; t < 0.5; t += 1 / 30) out.push(...m.push({ t, present: true, pose: 'thumbsUp', palmCenter: null, pinch: null }));
  for (let t = 0.5; t < 1.5; t += 1 / 30) out.push(...m.push({ t, present: true, pose: null, palmCenter: null, pinch: null }));
  assert.deepEqual(out, []);
});

test('thumbs-up while dictating stops the dictation first, then sends', () => {
  const m = new GestureMachine(); m.sendHold = 0.75;
  const a = taps(0, 2);
  run(m, a.s);
  assert.equal(m.talking, true);
  const out = [];
  for (let t = a.end + 0.5; t < a.end + 2; t += 1 / 30) out.push(...m.push({ t, present: true, pose: 'thumbsUp', palmCenter: null, pinch: null }));
  assert.deepEqual(out.map((i) => i.type), ['talkEnded', 'sendRequested']);
});

test('pinch and drag scrolls: movement past the start distance emits dragScroll, release ends it', () => {
  const m = new GestureMachine();
  const out = [];
  let t = 0;
  for (let i = 0; i < 4; i++, t += 1 / 30) out.push(...m.push(obs(t, 0.05, { palmCenter: { x: 0.5, y: 0.4 } })));
  for (let i = 0; i < 20; i++, t += 1 / 30) out.push(...m.push(obs(t, 0.05, { palmCenter: { x: 0.5, y: 0.4 + i * 0.01 } })));
  for (let i = 0; i < 4; i++, t += 1 / 30) out.push(...m.push(obs(t, 0.6, { palmCenter: { x: 0.5, y: 0.6 } })));
  const types = new Set(out.map((i) => i.type));
  assert.ok(types.has('dragScroll'));
  assert.ok(types.has('dragScrollEnded'));
  assert.ok(out.filter((i) => i.type === 'dragScroll').every((i) => i.handDy > 0), 'hand moving up scrolls up the page');
  assert.ok(!types.has('talkBegan'));
});

test('stale dictation ends when frames stop arriving', () => {
  const m = new GestureMachine();
  run(m, taps(0, 2).s);
  assert.equal(m.talking, true);
  const out = m.tick(m.lastPushT + 1.2);
  assert.deepEqual(out.map((i) => i.type), ['talkEnded']);
  assert.equal(out[0].reason, 'stale');
});

test('non-finite readings never reach the state', () => {
  const m = new GestureMachine();
  assert.deepEqual(m.push({ t: NaN, present: true, pose: null, palmCenter: null, pinch: 0.05 }), []);
  m.push(obs(0, NaN));
  assert.equal(m.pinchHeld, false);
});

// ---- focus ----

const S = [
  { id: 'a', frame: { x: 0, y: 0, w: 100, h: 100 } }, { id: 'b', frame: { x: 100, y: 0, w: 100, h: 100 } },
  { id: 'c', frame: { x: 0, y: 100, w: 100, h: 100 } }, { id: 'd', frame: { x: 100, y: 100, w: 100, h: 100 } },
];

test('sessionAt: inside a pane picks it; near the border the current one stays', () => {
  assert.equal(sessionAt({ x: 150, y: 50 }, S, null).id, 'b');
  assert.equal(sessionAt({ x: 105, y: 50 }, S, S[0]).id, 'a', 'within the 28 pt margin of the current one');
  assert.equal(sessionAt({ x: 140, y: 50 }, S, S[0]).id, 'b', 'clearly inside the other');
  assert.equal(sessionAt({ x: -10, y: 50 }, S, S[0]), null);
});

test('focus tracker: a new target needs 75 ms of dwell; a flicker does not switch', () => {
  const f = new FocusTracker();
  assert.equal(f.observe(S[0], 0, false, false), null);
  assert.equal(f.observe(S[0], 0.05, false, false), null);
  assert.equal(f.observe(S[0], 0.08, false, false).id, 'a');
  assert.equal(f.target.id, 'a');
  assert.equal(f.observe(S[1], 1, false, false), null);
  assert.equal(f.observe(S[0], 1.03, false, false), null, 'back on the target cancels the candidate');
  assert.equal(f.observe(S[1], 1.1, false, false), null);
  assert.equal(f.observe(S[1], 1.16, false, false), null);
  assert.equal(f.observe(S[1], 1.2, false, false).id, 'b');
});

test('focus tracker: held (pinch closed) freezes focus; while listening the dwell is 2 s', () => {
  const f = new FocusTracker(); f.target = S[0];
  assert.equal(f.observe(S[1], 0, true, false), null);
  assert.equal(f.observe(S[1], 5, true, false), null);
  assert.equal(f.candidate, null);
  f.observe(S[1], 6, false, true);
  assert.equal(f.observe(S[1], 7.9, false, true), null);
  assert.equal(f.observe(S[1], 8.1, false, true).id, 'b');
  assert.equal(FOCUS.switchDwell, 0.075);
});

// ---- head ----

test('head pointer: centres on the first second, then maps a turn across the stage', () => {
  const h = new HeadPointer();
  let r = null;
  for (let i = 0; i < 40; i++) r = h.push({ t: i / 30, yaw: 0.1, pitch: 0.02 });
  assert.notEqual(r, null);
  assert.equal(h.centring, false);
  near(r.x, 0.5, 0.02); near(r.y, 0.5, 0.02);
  // prior: yaw sign -1 -> a positive yaw delta moves left
  let last;
  for (let i = 40; i < 90; i++) last = h.push({ t: i / 30, yaw: 0.3, pitch: 0.02 });
  assert.ok(last.x < 0.1, `x ${last.x}`);
});

test('head pointer returns null while centring and ignores non-finite readings', () => {
  const h = new HeadPointer();
  assert.equal(h.push({ t: 0, yaw: 0, pitch: 0 }), null);
  assert.equal(h.push({ t: 0.1, yaw: NaN, pitch: 0 }), null);
  assert.ok(h.centringProgress < 0.2);
});

test('axis sign: rests on the prior until the angle and the nose offset really move together or against', () => {
  const rest = new AxisSign(-1);
  for (let i = 0; i < 100; i++) rest.add(0.1 + 0.001 * Math.sin(i), 0.02 + 0.0005 * Math.cos(i * 1.3));
  assert.equal(rest.sign, -1);
  const together = new AxisSign(-1), against = new AxisSign(-1);
  for (let i = 0; i < 60; i++) {
    const a = 0.2 * Math.sin(i / 5);
    together.add(a, 0.25 * a + 0.001 * Math.cos(i));
    against.add(a, -0.25 * a + 0.001 * Math.cos(i));
  }
  assert.equal(together.sign, -1);
  assert.equal(against.sign, 1);
});

test('head pointer flips its sign when the nose evidence contradicts the prior (y: looking down is +y)', () => {
  const h = new HeadPointer();
  // pitch rises while the nose offset falls: against the prior of +1, so the mapping flips
  for (let i = 0; i < 70; i++) {
    const p = 0.12 * Math.sin(i / 4);
    h.push({ t: i / 30, yaw: 0, pitch: p, offset: { x: 0, y: -0.2 * p } });
  }
  assert.equal(h.pitchSign.sign, -1);
});

test('angles from a head matrix, and the nose offset in face widths', () => {
  const yawed = anglesFromMatrix([1, 0, 0, 0, 0, 1, 0, 0, Math.sin(0.3), 0, Math.cos(0.3), 0, 0, 0, 0, 1]);
  near(yawed.yaw, 0.3, 1e-9); near(yawed.pitch, 0, 1e-9);
  const lm = new Array(478).fill(null).map(() => ({ x: 0.5, y: 0.5 }));
  lm[234] = { x: 0.4, y: 0.5 }; lm[454] = { x: 0.6, y: 0.5 }; lm[10] = { x: 0.5, y: 0.3 }; lm[152] = { x: 0.5, y: 0.7 };
  lm[4] = { x: 0.55, y: 0.55 };
  const o = noseOffset(lm);
  near(o.x, 0.25, 1e-9); near(o.y, 0.125, 1e-9);
});

// ---- scheduler, pointer stand-in, island ----

test('frame scheduler: hand every due frame, face decimated, and both slow down when inference is dear', () => {
  const s = new FrameScheduler({ handHz: 30, faceHz: 15 });
  let hand = 0, face = 0;
  for (let i = 0; i < 300; i++) { const p = s.plan(i / 30); hand += p.hand; face += p.face; if (p.hand) s.record('hand', 6); if (p.face) s.record('face', 8); }
  assert.ok(hand >= 280, `hand ${hand}`);
  assert.ok(face >= 130 && face <= 160, `face ${face}`);
  const slow = new FrameScheduler({ handHz: 30, faceHz: 15 });
  for (let i = 0; i < 600; i++) { const p = slow.plan(i / 30); if (p.hand) slow.record('hand', 30); if (p.face) slow.record('face', 40); }
  assert.ok(slow.faceHz < 15 && slow.handHz < 30, `${slow.handHz} ${slow.faceHz}`);
  assert.ok(slow.faceHz >= slow.minFaceHz && slow.handHz >= slow.minHandHz);
});

const pos = (x, y) => ({ x, y, nx: x / 800, ny: y / 600 });

function feedPointer(m, ph, t0, t1, step = 1 / 60) {
  const out = [];
  for (let t = t0; t <= t1; t += step) for (const o of ph.frames(t)) out.push(...m.push(o));
  return out;
}

test('mouse stand-in: click-click is a double pinch', () => {
  const m = new GestureMachine(), ph = new PointerHand();
  const out = [];
  ph.down(0, pos(100, 100)); out.push(...feedPointer(m, ph, 0, 0.1)); ph.up(0.1, pos(100, 100)); out.push(...feedPointer(m, ph, 0.1, 0.3));
  ph.down(0.3, pos(100, 100)); out.push(...feedPointer(m, ph, 0.3, 0.4)); ph.up(0.4, pos(100, 100)); out.push(...feedPointer(m, ph, 0.4, 0.6));
  assert.deepEqual(out.map((i) => i.type), ['talkBegan']);
});

test('mouse stand-in: a held press is a thumbs-up and sends after the hold', () => {
  const m = new GestureMachine(); m.sendHold = 0.75;
  const ph = new PointerHand();
  ph.down(0, pos(100, 100));
  const out = feedPointer(m, ph, 0, 1.5);
  assert.deepEqual(out.map((i) => i.type), ['sendRequested']);
});

test('mouse stand-in: press and move scrolls', () => {
  const m = new GestureMachine();
  const ph = new PointerHand();
  ph.down(0, pos(100, 300));
  const out = [];
  for (let t = 0; t < 0.6; t += 1 / 60) {
    ph.move(pos(100, 300 - t * 200));
    for (const o of ph.frames(t)) out.push(...m.push({ ...o, palmCenter: { x: 100 / 800, y: 1 - (300 - t * 200) / 600 } }));
  }
  assert.ok(out.some((i) => i.type === 'dragScroll'));
});

test('island mode follows the app priority', () => {
  assert.equal(islandMode({ listening: false }), 'idle');
  assert.equal(islandMode({ listening: true }), 'dictating');
  assert.equal(islandMode({ listening: true, sessionSwitch: true }), 'switching');
  assert.equal(islandMode({ listening: false, gesture: { action: 'talk', active: false } }), 'firstPinch');
  assert.equal(islandMode({ listening: true, gesture: { action: 'stop', active: false } }), 'firstPinch');
  assert.equal(islandMode({ gesture: { action: 'send', willAct: true } }), 'sendHold');
  assert.equal(islandMode({ banner: { style: 'sent' } }), 'banner');
});

test('dictation types words at a steady rate after a short delay and never past the end', () => {
  assert.equal(wordsTyped(10, 0.2), 0);
  assert.equal(wordsTyped(10, 0.7), 1);
  assert.equal(wordsTyped(10, 2), 5);
  assert.equal(wordsTyped(10, 100), 10);
});

test('classify: an extended-finger fist is not a thumbs up; a curled fist with thumb raised is', () => {
  assert.equal(classify(handWith({ thumbUp: true, curled: true })), 'thumbsUp');
  assert.notEqual(classify(handWith({ curled: true })), 'thumbsUp');
});

// ---- the centring step ----

const runStep = (step, from, to, yaw, pitch, { fps = 30, face = () => true } = {}) => {
  for (let t = from; t < to; t += 1 / fps) { if (face(t)) step.push(t, typeof yaw === 'function' ? yaw(t) : yaw, pitch); step.tick(t); }
};

test('centring step: counts 3, 2, 1 while a face is seen and averages only the final 1.5 s', () => {
  const s = new CentreStep();
  // the first 1.5 s the head drifts (0.3); the last 1.5 s it rests at 0.05 and 0.02 with a little noise
  runStep(s, 0, 3.2, (t) => (t < 1.5 ? 0.3 : 0.05 + 0.01 * Math.sin(t * 40)), 0.02);
  assert.ok(s.done);
  near(s.centre.yaw, 0.05, 0.004); near(s.centre.pitch, 0.02, 1e-9);
  const c = new CentreStep();
  runStep(c, 0, 0.4, 0, 0); assert.equal(c.count, 3);
  runStep(c, 0.4, 1.4, 0, 0); assert.equal(c.count, 2);
  runStep(c, 1.4, 2.4, 0, 0); assert.equal(c.count, 1);
  assert.ok(c.progress > 0.7 && c.progress < 0.9, `progress ${c.progress}`);
});

test('centring step: pauses while the face is lost and resumes when it is back', () => {
  const s = new CentreStep();
  runStep(s, 0, 1.0, 0, 0);
  const at = s.elapsed;
  runStep(s, 1.0, 3.0, 0, 0, { face: () => false });
  assert.ok(s.lost);
  near(s.elapsed, at + 0.4, 0.1);           // time counts only for the 0.4 s the last reading still counts as a face
  assert.ok(!s.done);
  const frozen = s.elapsed;
  runStep(s, 3.0, 3.5, 0, 0, { face: () => false });
  near(s.elapsed, frozen, 1e-9);
  runStep(s, 3.5, 6.5, 0.04, 0.01);
  assert.ok(s.done);
  near(s.centre.yaw, 0.04, 1e-9);
});

test('centring step: a face lost during the averaging window restarts that window, so the centre is never a mix', () => {
  const s = new CentreStep();
  runStep(s, 0, 2.4, 0.4, 0);                   // 0.9 s into the window, resting at 0.4
  assert.ok(!s.done);
  runStep(s, 2.4, 3.4, 0.4, 0, { face: () => false });
  runStep(s, 3.4, 7.0, 0.0, 0);                 // back, now resting at 0.0
  assert.ok(s.done);
  near(s.centre.yaw, 0.0, 1e-9);
});

test('centring step: never finishes without enough readings, ignores non-finite ones', () => {
  const s = new CentreStep();
  for (let t = 0; t < 4; t += 0.1) { s.tick(t); }
  assert.ok(!s.done && s.lost);
  s.push(4, NaN, 0); assert.ok(s.lastSeen === null);
});

test('head pointer: a centre from the step replaces the automatic one, and the gain puts natural turns on the panes', () => {
  const h = new HeadPointer();
  h.setCentre(0.05, 0.02);
  assert.equal(h.centring, false);
  let clock = 10;
  const at = (dyaw, dpitch = 0) => { let r; for (let i = 0; i < 90; i++) { clock += 1 / 30; r = h.push({ t: clock, yaw: 0.05 + dyaw, pitch: 0.02 + dpitch }); } return r; };
  near(at(0).x, 0.5, 0.01);
  const pane = (x) => Math.min(Math.floor(x * 4), 3);
  // positive yaw moves left (the prior: nose to the visitor's left in the mirror)
  assert.equal(pane(at(0.15).x), 0);
  assert.equal(pane(at(0.07).x), 1);
  assert.equal(pane(at(-0.07).x), 2);
  assert.equal(pane(at(-0.15).x), 3);
  // the window edge is reached by 0.2 rad (11.5 degrees); a 6 degree turn already leaves the middle panes
  assert.ok(at(-0.2).x > 0.99 && at(0.2).x < 0.01);
  assert.ok(at(0, 0.13).y > 0.99);
  assert.equal(HEAD.yawRange, 0.2);
});

// ---- the pinch measure and its thresholds ----

// A MediaPipe world hand in metres: wrist at the origin, middle knuckle 9 cm up, thumb and index tips `gap` metres apart.
const worldHand = (gap) => {
  const w = Array.from({ length: 21 }, () => ({ x: 0, y: 0, z: 0 }));
  w[0] = { x: 0, y: 0, z: 0 }; w[9] = { x: 0, y: -0.09, z: 0 };
  w[8] = { x: -gap / 2, y: -0.17, z: 0.01 }; w[4] = { x: gap / 2, y: -0.17, z: 0.01 };
  return w;
};
// The same hand in the image: normalised x is a fraction of the width, y of the height, so a 4:3 frame stretches x.
const imageHand = (gap, aspect = 4 / 3) => {
  const p = Array.from({ length: 21 }, () => ({ x: 0.5, y: 0.5 }));
  const cm = 1 / 0.3;   // the frame is 0.3 m tall
  p[0] = { x: 0.5, y: 0.2 }; p[9] = { x: 0.5, y: 0.2 + 0.09 * cm };
  p[8] = { x: 0.5 - gap / 2 * cm / aspect, y: 0.6 }; p[4] = { x: 0.5 + gap / 2 * cm / aspect, y: 0.6 };
  return p;
};

test('pinch measure from world landmarks: open hand, touching pinch, half pinch', () => {
  const open = pinchMeasure([], worldHand(0.08)), touch = pinchMeasure([], worldHand(0.018)), half = pinchMeasure([], worldHand(0.03));
  assert.equal(open.source, 'world');
  near(open.pinch, 0.08 / 0.09, 0.02); near(touch.pinch, 0.018 / 0.09, 0.02); near(half.pinch, 0.03 / 0.09, 0.02);
  assert.ok(touch.pinch < PINCH.closed, `touching ${touch.pinch}`);
  assert.ok(half.pinch > PINCH.closed && half.pinch < PINCH.open, `half ${half.pinch}`);
  assert.ok(open.pinch > PINCH.open, `open ${open.pinch}`);
  assert.equal(pinchMeasure([], null).pinch, null);
});

test('pinch measure from image points corrects x for the frame aspect (4:3 frames skew x against y)', () => {
  for (const gap of [0.018, 0.03, 0.08]) {
    const right = pinchMeasure(imageHand(gap), null, 4 / 3), naive = pinchMeasure(imageHand(gap), null, 1);
    assert.equal(right.source, 'image');
    near(right.pinch, gap / 0.09, 0.02);
    assert.ok(Math.abs(naive.pinch - gap / 0.09) > 0.01, 'without the aspect the horizontal gap reads too small');
  }
});

test('the observation carries the world pinch when the model gives it, and the image one when not', () => {
  const hand = { points: imageHand(0.018).map((p) => ({ x: p.x, y: 1 - p.y })) };
  const w = observationFromHand(hand, 1, false, { world: worldHand(0.018), aspect: 4 / 3 });
  const i = observationFromHand(hand, 1, false, { aspect: 4 / 3 });
  assert.equal(w.pinchSource, 'world'); assert.equal(i.pinchSource, 'image');
  assert.ok(w.pinch < PINCH.closed && i.pinch < PINCH.closed);
});

test('the machine treats a world-measure touching pinch as closed and a relaxed hand as open', () => {
  const m = new GestureMachine();
  const out = run(m, [[0, 0.7], [0.03, 0.7], [0.1, 0.22], [0.13, 0.22], [0.2, 0.7], [0.23, 0.7], [0.5, 0.22], [0.53, 0.22]]);
  assert.deepEqual(out.map((i) => i.type), ['talkBegan']);
  // a half pinch (0.35) between the thresholds neither closes nor opens
  const h = new GestureMachine();
  run(h, [[0, 0.22], [0.03, 0.22], [0.06, 0.35], [0.09, 0.35], [0.12, 0.35]]);
  assert.equal(h.pinchHeld, true);
  run(h, [[0.2, 0.5], [0.23, 0.5]]);
  assert.equal(h.pinchHeld, false);
});

test('adaptive pinch thresholds: defaults first, then converge on this visitor after three dips', () => {
  const a = new PinchAdapt();
  assert.equal(a.closed, PINCH.closed); assert.equal(a.open, PINCH.open);
  const stream = (low, high, dips, noise = 0.01) => {
    for (let k = 0; k < dips; k++) {
      for (let i = 0; i < 30; i++) a.push(high + noise * Math.sin(i * 1.7));          // hand open
      for (let i = 0; i < 6; i++) a.push(low + noise * Math.cos(i * 2.1) + (i === 3 ? 0 : 0.02)); // a pinch
    }
    for (let i = 0; i < 30; i++) a.push(high);
  };
  stream(0.15, 0.55, 2);
  assert.equal(a.closed, PINCH.closed, 'two dips are not enough');
  stream(0.15, 0.55, 2);
  assert.ok(a.ready);
  // 0.15 + 0.4 * (0.55 - 0.15) = 0.31
  near(a.closed, 0.31, 0.03); assert.ok(a.open > a.closed + 0.1 - 1e-9 && a.open <= PINCH.maxOpen);
  // a visitor whose landmarks never get close: the bound keeps "closed" sane
  const b = new PinchAdapt();
  for (let k = 0; k < 4; k++) { for (let i = 0; i < 20; i++) b.push(0.9); for (let i = 0; i < 4; i++) b.push(0.45); }
  for (let i = 0; i < 20; i++) b.push(0.9);
  assert.equal(b.closed, PINCH.maxClosed);
  // one with a very tight pinch lands low but never under the floor
  const c = new PinchAdapt();
  for (let k = 0; k < 4; k++) { for (let i = 0; i < 20; i++) c.push(0.5); for (let i = 0; i < 4; i++) c.push(0.0); }
  for (let i = 0; i < 20; i++) c.push(0.5);
  assert.equal(c.closed, PINCH.minClosed);
  c.push(NaN); assert.ok(Number.isFinite(c.closed));
});
