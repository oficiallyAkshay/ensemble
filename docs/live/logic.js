// Pure logic for the live stage, ported from Sources/EnsembleCore (OneEuroFilter, GestureMachine,
// HandClassifierAdapter, FocusTracker, Vendor/Sleight GestureClassifier) and Coordinator/FocusController.
// No DOM, no clock: time arrives as arguments, so node --test replays it deterministically.
// Hand coordinates here are Vision-style: normalized, origin bottom-left (y up). Callers flip MediaPipe's y.

const finite = Number.isFinite;

export class OneEuroFilter {
  constructor(minCutoff = 0.6, beta = 3, dCutoff = 1) {
    this.minCutoff = minCutoff; this.beta = beta; this.dCutoff = dCutoff;
    this.lastT = null; this.lastRaw = 0; this.lastFiltered = 0; this.lastDerivative = 0;
  }

  reset() { this.lastT = null; }

  filter(x, t) {
    if (!finite(x) || !finite(t)) return this.lastFiltered;
    if (this.lastT === null) {
      this.lastT = t; this.lastRaw = x; this.lastFiltered = x; this.lastDerivative = 0;
      return x;
    }
    if (!(t > this.lastT)) return this.lastFiltered;
    const dt = t - this.lastT;
    const rawDerivative = (x - this.lastRaw) / dt;
    const derivative = this.lastDerivative + OneEuroFilter.alpha(this.dCutoff, dt) * (rawDerivative - this.lastDerivative);
    const cutoff = this.minCutoff + this.beta * Math.abs(derivative);
    const filtered = this.lastFiltered + OneEuroFilter.alpha(cutoff, dt) * (x - this.lastFiltered);
    this.lastT = t; this.lastRaw = x; this.lastFiltered = filtered; this.lastDerivative = derivative;
    return filtered;
  }

  static alpha(cutoff, dt) {
    const tau = 1 / (2 * Math.PI * cutoff);
    return 1 / (1 + tau / dt);
  }
}

// ---- Hand ----------------------------------------------------------------------------------------------

// MediaPipe and Vision order the 21 hand landmarks identically.
export const J = {
  wrist: 0, thumbCMC: 1, thumbMP: 2, thumbIP: 3, thumbTip: 4,
  indexMCP: 5, indexPIP: 6, indexDIP: 7, indexTip: 8,
  middleMCP: 9, middlePIP: 10, middleDIP: 11, middleTip: 12,
  ringMCP: 13, ringPIP: 14, ringDIP: 15, ringTip: 16,
  littleMCP: 17, littlePIP: 18, littleDIP: 19, littleTip: 20,
};

export const HAND_BONES = [
  [0, 1], [1, 2], [2, 3], [3, 4], [0, 5], [5, 6], [6, 7], [7, 8], [5, 9], [9, 10], [10, 11], [11, 12],
  [9, 13], [13, 14], [14, 15], [15, 16], [13, 17], [17, 18], [18, 19], [19, 20], [0, 17],
];

/** A Hand from MediaPipe landmarks (y down) as Vision-style points (y up). */
export function handFromLandmarks(landmarks) {
  return { points: landmarks.map((p) => ({ x: p.x, y: 1 - p.y })) };
}

const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

export function handExtent(hand) {
  const pts = hand.points.filter(Boolean);
  if (pts.length < 5) return 0;
  const xs = pts.map((p) => p.x), ys = pts.map((p) => p.y);
  return Math.hypot(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys));
}

/** Mean of the palm joints; needs three of the five so a half-visible hand cannot jump between them. */
export function palmCenter(hand) {
  const pts = [J.wrist, J.indexMCP, J.middleMCP, J.ringMCP, J.littleMCP].map((i) => hand.points[i]).filter(Boolean);
  if (pts.length < 3) return null;
  return { x: pts.reduce((a, p) => a + p.x, 0) / pts.length, y: pts.reduce((a, p) => a + p.y, 0) / pts.length };
}

export const CLASSIFIER = {
  minOpenExtent: 0.19, minClosedExtent: 0.11, minTwoFingersExtent: 0.15, maxPalmSpan: 0.6,
  extendRatio: 1.15, curlRatio: 0.85, fistTipReach: 0.8,
  gatherMaxSpread: 0.6, gatherMinReach: 1.0,
  closeFistExtent: 0.2, closeFistTipReach: 0.95, closeFistMaxPalmSpan: 0.7,
  maxOpenTipReach: 2.1, minUpright: 0.3, pointMinRise: 0.5, twoFingersFoldRatio: 1.0,
};

/** Rule-based static pose classifier (Sleight, with Ensemble's gather and pointing changes). Null when unreadable. */
export function classifyFeatures(hand) {
  const C = CLASSIFIER, P = hand.points;
  const wrist = P[J.wrist], midMCP = P[J.middleMCP];
  if (!wrist || !midMCP) return null;
  const size = dist(wrist, midMCP);
  if (!(size > 0.01)) return null;
  const reach = (tip, pip) => {
    const t = P[tip], p = P[pip];
    if (!t || !p) return null;
    const d = dist(p, wrist);
    return d > 0 ? dist(t, wrist) / d : null;
  };
  const index = reach(J.indexTip, J.indexPIP), middle = reach(J.middleTip, J.middlePIP);
  const ring = reach(J.ringTip, J.ringPIP), little = reach(J.littleTip, J.littlePIP);
  const indexTip = P[J.indexTip], thumbTip = P[J.thumbTip], thumbIP = P[J.thumbIP];
  const indexMCP = P[J.indexMCP], littleMCP = P[J.littleMCP];
  if ([index, middle, ring, little].some((r) => r === null) || !indexTip || !thumbTip || !thumbIP || !indexMCP || !littleMCP) return null;
  const reaches = [index, middle, ring, little];
  const ext = reaches.map((r) => r > C.extendRatio);
  const curl = reaches.map((r) => r < C.curlRatio);
  const tipReach = Math.max(...[J.indexTip, J.middleTip, J.ringTip, J.littleTip].map((i) => P[i]).filter(Boolean).map((p) => dist(p, wrist) / size));

  const thumbStraight = dist(thumbTip, wrist) > dist(thumbIP, wrist) * 1.1;
  const thumbClear = dist(thumbTip, indexMCP) / size > 0.6;
  const extent = handExtent(hand);
  const f = {
    index: ext[0], middle: ext[1], ring: ext[2], little: ext[3],
    curled: curl.filter(Boolean).length, tipReach, thumbStraight, thumbClear,
    thumbUp: thumbTip.y > indexMCP.y + 0.3 * size,
    extent, palm: size, span: dist(indexMCP, littleMCP) / size,
    upright: (midMCP.y - wrist.y) / size, tooSmall: false, angled: false,
    indexRise: (indexTip.y - indexMCP.y) / size, gesture: null,
  };
  f.thumb = thumbStraight && thumbClear;
  const n = ext.filter(Boolean).length;

  const tipPts = [J.thumbTip, J.indexTip, J.middleTip, J.ringTip, J.littleTip].map((i) => P[i]).filter(Boolean);
  let gathered = false;
  if (tipPts.length === 5) {
    let spread = 0;
    for (let i = 0; i < 5; i++) for (let j = i + 1; j < 5; j++) spread = Math.max(spread, dist(tipPts[i], tipPts[j]));
    const c = { x: tipPts.reduce((a, p) => a + p.x, 0) / 5, y: tipPts.reduce((a, p) => a + p.y, 0) / 5 };
    gathered = spread / size <= C.gatherMaxSpread && dist(c, wrist) / size >= C.gatherMinReach;
  }
  if (gathered) f.gesture = 'gather';
  else if (n === 4 && tipReach <= C.maxOpenTipReach) f.gesture = 'openPalm';
  else if (f.curled === 4 && !f.thumb && tipReach < (extent >= C.closeFistExtent ? C.closeFistTipReach : C.fistTipReach)) f.gesture = 'fist';
  else if (ext[0] && ext[1] && ring < C.twoFingersFoldRatio && little < C.twoFingersFoldRatio) f.gesture = 'twoFingers';
  else if (f.curled === 4 && f.thumb && f.thumbUp) f.gesture = 'thumbsUp';
  else if (ext[0] && curl[1] && curl[2] && curl[3]) {
    if (f.indexRise > C.pointMinRise) f.gesture = 'pointUp';
    else if (f.indexRise < -C.pointMinRise) f.gesture = 'pointDown';
  }

  const g = f.gesture;
  if (g) {
    const floor = g === 'openPalm' ? C.minOpenExtent : g === 'twoFingers' ? C.minTwoFingersExtent : C.minClosedExtent;
    if (f.extent < floor) { f.tooSmall = true; f.gesture = null; }
    else if ((g !== 'thumbsUp' && g !== 'gather' && f.span > (g === 'fist' && f.extent >= C.closeFistExtent ? C.closeFistMaxPalmSpan : C.maxPalmSpan))
      || (f.upright < C.minUpright && g !== 'pointUp' && g !== 'pointDown')) { f.angled = true; f.gesture = null; }
  }
  return f;
}

export const classify = (hand) => classifyFeatures(hand)?.gesture ?? null;

/**
 * One frame's hand reading, as HandClassifierAdapter builds it. The pinch is thumb tip to index tip in palm
 * lengths (wrist to middle knuckle). `modelThumbsUp` is the recognizer's own Thumb_Up verdict, accepted as
 * well as the rule classifier's.
 */
export function observationFromHand(hand, t, modelThumbsUp = false, { world = null, aspect = 1 } = {}) {
  if (!hand) return { t, present: false, pose: null, palmCenter: null, pinch: null };
  const { pinch, source, world: pinchWorld } = pinchMeasure(hand.points, world, aspect);
  let pose = classify(hand);
  if (modelThumbsUp && pose !== 'thumbsUp') pose = 'thumbsUp';
  return { t, present: true, pose, palmCenter: palmCenter(hand), pinch, pinchSource: source, pinchWorld };
}

/**
 * The pinch measure: thumb tip (4) to index tip (8), divided by wrist (0) to middle knuckle (9), in the image with x scaled by the
 * frame's aspect (width / height, because normalised x and y are fractions of different lengths). The model's world landmarks are
 * measured too (`world`, metric 3D) but not used to decide: on the owner's real hand recordings the world distance stays at 0.55 to
 * 1.3 palms through a clean closed pinch (pads touching in the picture, ratio 0.08 to 0.16 there), so a pinch-and-drag never read as
 * closed. The image measure is clean on all of them. `points` are y-up image points, `world` the raw world landmarks.
 */
export function pinchMeasure(points, world = null, aspect = 1) {
  const ok = (a, b, c, d) => a && b && c && d;
  let worldPinch = null;
  if (world && ok(world[J.thumbTip], world[J.indexTip], world[J.wrist], world[J.middleMCP])) {
    const d3 = (p, q) => Math.hypot(p.x - q.x, p.y - q.y, (p.z ?? 0) - (q.z ?? 0));
    const palm = d3(world[J.wrist], world[J.middleMCP]);
    if (palm > 0.01) worldPinch = d3(world[J.thumbTip], world[J.indexTip]) / palm;
  }
  const a = points[J.thumbTip], b = points[J.indexTip], w = points[J.wrist], m = points[J.middleMCP];
  if (ok(a, b, w, m)) {
    const d2 = (p, q) => Math.hypot((p.x - q.x) * aspect, p.y - q.y);
    const palm = d2(w, m);
    if (palm > 0.01) return { pinch: d2(a, b) / palm, source: 'image', world: worldPinch };
  }
  return worldPinch === null ? { pinch: null, source: null, world: null } : { pinch: worldPinch, source: 'world', world: worldPinch };
}

/**
 * Thresholds for the pinch measure above: closed below 0.30, open above 0.42. On the owner's recorded hand (1280x720, about 75 fps) the
 * image measure is 0.02 to 0.16 in a pinch and 0.6 to 1.1 in an open hand; between 0.3 and 0.42 lies the half pinch. ?debug=1 on the demo
 * logs the numbers.
 */
export const PINCH = { closed: 0.30, open: 0.42, rise: 0.12, minClosed: 0.2, maxClosed: 0.36, hysteresis: 0.12, minOpen: 0.32, maxOpen: 0.5 };

/**
 * Learns this visitor's own closed and open values over the session. A "dip" is an excursion of the measure below `dipBelow` for
 * at least two frames; its lowest value is their closed value for that pinch. After `minDips` dips, "closed" sits 40% of the way from
 * the median dip minimum to their open value (the 90th percentile of all readings), clamped to sane bounds, and "open" a hysteresis above it.
 */
export class PinchAdapt {
  constructor(opts = {}) {
    this.o = { dipBelow: 0.5, minDips: 3, share: 0.4, keep: 1500, ...PINCH, ...opts };
    this.reset();
  }

  reset() { this.samples = []; this.dips = []; this.runMin = null; this.runLen = 0; this.closed = this.o.closed; this.open = this.o.open; this.lowValue = null; this.highValue = null; }

  get ready() { return this.dips.length >= this.o.minDips; }

  push(d) {
    if (!finite(d)) return;
    this.samples.push(d); if (this.samples.length > this.o.keep) this.samples.shift();
    if (d < this.o.dipBelow) { this.runLen += 1; this.runMin = this.runMin === null ? d : Math.min(this.runMin, d); }
    else { if (this.runLen >= 2) { this.dips.push(this.runMin); if (this.dips.length > 40) this.dips.shift(); } this.runLen = 0; this.runMin = null; }
    if (this.ready) this.update();
  }

  update() {
    const o = this.o, sorted = [...this.samples].sort((a, b) => a - b);
    this.lowValue = median(this.dips);
    this.highValue = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.9))];
    const span = Math.max(this.highValue - this.lowValue, 0.1);
    this.closed = Math.min(Math.max(this.lowValue + o.share * span, o.minClosed), o.maxClosed);
    this.open = Math.min(Math.max(this.closed + o.hysteresis, o.minOpen), o.maxOpen);
  }
}

// ---- GestureMachine ------------------------------------------------------------------------------------

export class GestureMachine {
  static reopenAbove = 0.42;   // see PINCH: the measure is wrist-to-knuckle in 3D, not Apple Vision's image distance
  static reopenRise = 0.12;
  // A pinch edge (closing or opening) needs the measure to hold for edgeDwell seconds, or for one frame when frames are farther apart
  // than that, so a quick tap reads the same at 15, 20, 30 or 60 Hz. A frame closer than edgeSlack of the dwell still confirms
  // (two frames at 30 Hz are 33 ms apart: close enough to 40).
  static edgeDwell = 0.04;
  static edgeSlack = 0.75;
  // While a pinch is dragging, only a clear open ends it: above the open threshold for this long. Noise near the closed value never does.
  static dragReleaseHold = 0.08;
  static tapMin = 0.05;
  static tapMax = 2.0;
  static tapGap = 1.2;
  static quietAfterSendPose = 0.7;
  static toggleCooldown = 0.8;
  static dragStart = 0.02;
  static dragPointsPerFrameHeight = 5000;
  static dragAccel = 3;
  static staleHold = 1.0;
  static stopAndSendHold = 0.35;
  static sendAfterTalkEnd = 0.5;
  static scrollHold = 0.25;
  static scrollMinSpeed = 300;
  static scrollMaxSpeed = 1200;
  static scrollRamp = 1.5;
  static scrollMaxGap = 0.2;

  constructor(mapping = {}) {
    this.mapping = { send: 'thumbsUp', scrollUp: null, scrollDown: null, ...mapping };
    this.talking = false;
    this.pinchClosed = 0.30;
    this.pinchOpen = GestureMachine.reopenAbove;
    this.sendHold = 1.5;
    this.frameAspect = 640 / 480;
    this.isDragging = false;
    this.pinchIsClosed = false;
    this.pinchClosedAt = null;
    this.pinchMin = 1;
    this.dragging = false;
    this.dragOriginY = null; this.dragLastY = null; this.dragLastT = null; this.dragOriginX = null; this.dragLastX = null;
    this.dragFilter = new OneEuroFilter(1, 2, 1);
    this.dragFilterX = new OneEuroFilter(1, 2, 1);
    this.pinchToggled = false;
    this.closeSince = null; this.openSince = null; this.lastPinchT = null; this.frameDt = Infinity;
    this.pinchSuspect = false;
    this.lastSendPoseT = -Infinity;
    this.lastTapEnd = null;
    this.lastToggleAt = -Infinity;
    this.run = null;
    this.lastPushT = null;
    this.lastTalkEndT = null;
  }

  /** A pinch is closed right now (tap, drag or hold in progress): focus holds still meanwhile. */
  get pinchHeld() { return this.pinchIsClosed; }

  get awaitingSecondTap() {
    if (this.lastTapEnd === null || this.lastPushT === null) return false;
    return this.lastPushT - this.lastTapEnd <= GestureMachine.tapGap;
  }

  /** The pose held and how far its hold has progressed toward acting, for on-screen feedback. */
  get progress() {
    const G = GestureMachine;
    if (this.awaitingSecondTap) return { pose: 'gather', action: this.talking ? 'stop' : 'talk', progress: 0.5, willAct: true, active: false };
    if (this.talking && this.run?.pose !== this.mapping.send) return { pose: 'gather', action: 'talk', progress: 1, willAct: true, active: true };
    const r = this.run;
    if (!r) return null;
    const held = r.lastT - r.start;
    const make = (action, need, can) => ({ pose: r.pose, action, progress: Math.min(Math.max(held / need, 0), 1), willAct: can, active: false });
    if (this.talking) return null;
    if (r.pose === this.mapping.send) return make('send', this.sendHold, (!r.startedWhileTalking || r.stoppedForSend) && !r.fired);
    const dir = this.scrollDirection(r.pose);
    if (dir !== null) {
      const p = make(dir < 0 ? 'scrollUp' : 'scrollDown', G.scrollHold, !r.startedWhileTalking);
      return { ...p, active: p.willAct && p.progress >= 1 };
    }
    return null;
  }

  reset() {
    this.talking = false;
    this.pinchIsClosed = false; this.pinchClosedAt = null; this.lastTapEnd = null;
    this.pinchToggled = false; this.dragging = false; this.isDragging = false; this.closeSince = null; this.openSince = null; this.lastPinchT = null;
    this.pinchSuspect = false; this.lastSendPoseT = -Infinity;
    this.lastToggleAt = -Infinity;
    this.run = null; this.lastPushT = null; this.lastTalkEndT = null;
  }

  /** The caller refused the dictation this machine announced: forget it so the next double tap starts again. */
  abortTalk() {
    this.talking = false;
    this.lastTapEnd = null;
    this.lastToggleAt = -Infinity;
  }

  push(observation) {
    const G = GestureMachine;
    const h = { ...observation };
    // A non-finite reading is a missing reading: it must not reach the filters or the pinch hysteresis.
    if (h.pinch !== null && h.pinch !== undefined && !finite(h.pinch)) h.pinch = null;
    if (h.pinch === undefined) h.pinch = null;
    if (h.palmCenter && !(finite(h.palmCenter.x) && finite(h.palmCenter.y))) h.palmCenter = null;
    if (!finite(h.t)) return [];
    this.lastPushT = h.t;
    const intents = [];
    if (h.present && this.mapping.send && h.pose === this.mapping.send) this.lastSendPoseT = h.t;
    if (this.lastTapEnd !== null && h.t - this.lastTapEnd > G.tapGap && !this.pinchIsClosed) this.lastTapEnd = null;
    this.trackTaps(h, intents);

    if (!h.present || !h.pose) { this.run = null; return intents; }
    const pose = h.pose;
    if (this.run?.pose !== pose) this.run = { pose, start: h.t, startedWhileTalking: this.talking, fired: false, stoppedForSend: false, lastT: h.t };
    const r = this.run;
    const held = h.t - r.start;

    if (this.talking && pose === this.mapping.send && !r.stoppedForSend && held >= G.stopAndSendHold) {
      r.stoppedForSend = true;
      this.endTalk('released', h.t, intents);
    } else if (!this.talking) {
      if (pose === this.mapping.send && (!r.startedWhileTalking || r.stoppedForSend) && !r.fired && held >= this.sendHold
        && (r.stoppedForSend || (this.lastTalkEndT === null ? true : h.t - this.lastTalkEndT >= G.sendAfterTalkEnd))) {
        r.fired = true;
        intents.push({ type: 'sendRequested' });
      } else {
        const direction = this.scrollDirection(pose);
        if (direction !== null && !r.startedWhileTalking && held >= G.scrollHold) {
          const dt = h.t - r.lastT;
          if (dt > 0 && dt <= G.scrollMaxGap) {
            const ramp = Math.min((held - G.scrollHold) / G.scrollRamp, 1);
            const speed = G.scrollMinSpeed + (G.scrollMaxSpeed - G.scrollMinSpeed) * ramp;
            intents.push({ type: 'scroll', dy: direction * speed * dt });
          }
        }
      }
    }
    r.lastT = h.t;
    return intents;
  }

  /** Call on a timer. Ends a dictation hold when the camera stopped delivering frames. */
  tick(now) {
    if (!this.talking || this.lastPushT === null || now - this.lastPushT < GestureMachine.staleHold) return [];
    const intents = [];
    this.endTalk('stale', now, intents);
    return intents;
  }

  /** Two quick thumb-to-index taps toggle dictation; a pinch held longer than tapMax never counts. */
  trackTaps(h, intents) {
    const G = GestureMachine;
    if (!h.present || h.pinch === null) {
      if (this.dragging) intents.push({ type: 'dragScrollEnded' });
      this.pinchIsClosed = false; this.pinchClosedAt = null; this.closeSince = null; this.openSince = null; this.lastPinchT = null;
      this.dragging = false; this.isDragging = false;
      return;
    }
    const d = h.pinch;
    // Time, not frame counts: how far apart the frames are decides how long an edge must hold.
    const gap = this.lastPinchT === null ? Infinity : h.t - this.lastPinchT;
    if (gap > 0 && gap < 0.25) this.frameDt = this.frameDt === Infinity ? gap : this.frameDt * 0.9 + gap * 0.1;
    this.lastPinchT = h.t;
    const held = (since) => h.immediate || gap >= G.edgeDwell || h.t - since >= G.edgeDwell * G.edgeSlack;
    if (!this.pinchIsClosed) {
      if (d < this.pinchClosed) { if (this.closeSince === null) this.closeSince = h.t; } else { this.closeSince = null; return; }
      if (!held(this.closeSince)) return;
      this.pinchIsClosed = true;
      this.pinchClosedAt = this.closeSince; this.closeSince = null; this.pinchMin = d;
      this.pinchToggled = false;
      this.dragging = false; this.isDragging = false;
      this.dragFilter.reset(); this.dragFilterX.reset();
      this.dragOriginY = h.palmCenter ? this.dragFilter.filter(h.palmCenter.y, h.t) : null;
      this.dragOriginX = h.palmCenter ? this.dragFilterX.filter(h.palmCenter.x, h.t) : null;
      this.dragLastY = this.dragOriginY; this.dragLastX = this.dragOriginX;
      if (this.lastTapEnd !== null && h.t - this.lastTapEnd > G.tapGap) this.lastTapEnd = null;
      this.pinchSuspect = h.t - this.lastSendPoseT < G.quietAfterSendPose;
      if (this.pinchSuspect) this.lastTapEnd = null;
      // The second pinch acts the moment it touches; holding it afterwards changes nothing.
      if (this.lastTapEnd !== null && h.t - this.lastToggleAt >= G.toggleCooldown) {
        this.lastTapEnd = null;
        this.lastToggleAt = h.t;
        this.pinchToggled = true;
        if (this.talking) this.endTalk('released', h.t, intents);
        else { this.talking = true; intents.push({ type: 'talkBegan' }); }
      }
      return;
    }
    // Pinch and drag: a held pinch that moves scrolls, with the hand position smoothed.
    // Release first: fingers that have parted while dragging end the drag before any movement counts.
    if (this.dragging) {
      if (d > this.pinchOpen) { if (this.openSince === null) this.openSince = h.t; } else this.openSince = null;
      if (this.openSince !== null && h.t - this.openSince >= G.dragReleaseHold) {
        this.pinchIsClosed = false; this.openSince = null; this.pinchClosedAt = null;
        this.dragging = false; this.isDragging = false; this.lastTapEnd = null;
        intents.push({ type: 'dragScrollEnded' });
        return;
      }
      // fingers opening: the page stops moving at once, and the release is confirmed once the open has held
      if (this.openSince !== null) { this.dragLastT = h.t; return; }
    }
    if (!this.pinchToggled && d <= this.pinchOpen && h.palmCenter && this.dragOriginY !== null && this.dragOriginX !== null) {
      const y = this.dragFilter.filter(h.palmCenter.y, h.t);
      const x = this.dragFilterX.filter(h.palmCenter.x, h.t);
      if (!this.dragging && Math.hypot(x - this.dragOriginX, y - this.dragOriginY) >= G.dragStart) {
        this.dragging = true; this.isDragging = true; this.lastTapEnd = null;
      }
      if (this.dragging && this.dragLastY !== null && this.dragLastX !== null && this.dragLastT !== null && h.t > this.dragLastT) {
        const dy = y - this.dragLastY, dx = (x - this.dragLastX) * this.frameAspect;
        // Like dragging the page. Mainly vertical: the sideways part of an arc counts too (full step length, signed
        // by up or down); mainly sideways: only the small vertical part, so sideways jitter cannot drive it.
        const step = Math.abs(dy) >= 0.5 * Math.abs(dx) ? (dy >= 0 ? 1 : -1) * Math.hypot(dx, dy) : dy;
        if (step !== 0) {
          const speed = Math.abs(step) / (h.t - this.dragLastT);
          const gain = 1 + G.dragAccel * Math.min(speed, 1);
          intents.push({ type: 'dragScroll', handDy: step * G.dragPointsPerFrameHeight * gain });
        }
      }
      this.dragLastT = h.t;
      this.dragLastY = y; this.dragLastX = x;
    }
    this.pinchMin = Math.min(this.pinchMin, d);
    // While dragging, opening the fingers even a little ends the drag at once, so the page never follows a hand that let go.
    const opened = d > Math.max(this.pinchOpen, this.pinchMin + G.reopenRise);
    if (opened) { if (this.openSince === null) this.openSince = h.t; } else this.openSince = null;
    if (this.pinchClosedAt !== null && h.t - this.pinchClosedAt > G.tapMax) this.lastTapEnd = null;
    if (!opened || !held(this.openSince)) return;
    // The tap ended when the fingers first parted, not when that was confirmed.
    const endT = this.openSince;
    this.pinchIsClosed = false; this.openSince = null;
    if (this.pinchClosedAt === null) return;
    const start = this.pinchClosedAt;
    this.pinchClosedAt = null;
    const closedFor = endT - start;
    // One closed frame is a tap however slowly frames arrive: the minimum never exceeds 80% of the frame spacing.
    const tapMin = Math.min(G.tapMin, 0.8 * this.frameDt);
    if (this.pinchToggled) { this.pinchToggled = false; this.lastTapEnd = null; return; }
    if (this.dragging) { this.dragging = false; this.isDragging = false; this.lastTapEnd = null; intents.push({ type: 'dragScrollEnded' }); return; }
    if (!(closedFor >= tapMin && closedFor <= G.tapMax) || this.pinchSuspect) { this.lastTapEnd = null; return; }
    this.lastTapEnd = endT;
  }

  endTalk(reason, t, intents) {
    this.talking = false;
    this.lastTalkEndT = t;
    if (reason !== 'released') this.run = null;
    intents.push({ type: 'talkEnded', reason });
  }

  scrollDirection(pose) {
    if (pose && pose === this.mapping.scrollUp) return -1;
    if (pose && pose === this.mapping.scrollDown) return 1;
    return null;
  }
}

// ---- Focus ---------------------------------------------------------------------------------------------

export const FOCUS = { switchDwell: 0.075, switchMargin: 28, listeningSwitchDwell: 2.0 };

const contains = (r, p) => p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h;
const inset = (r, d) => ({ x: r.x + d, y: r.y + d, w: r.w - 2 * d, h: r.h - 2 * d });

/** The session under the point. Near the border between the current one and another, the current one stays. */
export function sessionAt(p, sessions, current, margin = FOCUS.switchMargin) {
  let under = sessions.find((s) => contains(s.frame, p)) ?? null;
  if (under && current && under.id !== current.id && !contains(inset(under.frame, margin), p)) {
    const still = sessions.find((s) => s.id === current.id);
    if (still && contains(inset(still.frame, -margin), p)) under = still;
  }
  return under;
}

export class FocusTracker {
  constructor() { this.target = null; this.candidate = null; }

  /** Feeds one reading; returns the session the target just moved onto, else null. `held` holds everything still. */
  observe(under, t, held, listening) {
    if (held) {
      this.candidate = null;
    } else if ((under?.id ?? null) === (this.target?.id ?? null)) {
      this.candidate = null;
    } else if (this.candidate && (this.candidate.session?.id ?? null) === (under?.id ?? null)) {
      const dwell = listening && under ? FOCUS.listeningSwitchDwell : FOCUS.switchDwell;
      if (t - this.candidate.since >= dwell) { this.target = under; this.candidate = null; return under; }
    } else {
      this.candidate = { session: under, since: t };
    }
    return null;
  }

  forgetAll() { this.target = null; this.candidate = null; }
}

// ---- Head ----------------------------------------------------------------------------------------------

/** Column-major 4x4 head transform, as head.js reads it: yaw from the forward axis, pitch from its y component. */
export function anglesFromMatrix(m) {
  return { yaw: Math.atan2(m[8], m[10]), pitch: Math.asin(Math.max(-1, Math.min(1, m[9]))) };
}

/**
 * Where the nose sits in the face outline, from raw (unmirrored) landmarks, in face widths: the sign of a head
 * turn that does not depend on the transform matrix's axis conventions. 234 and 454 are the cheek edges, 4 the
 * nose tip, 10 and 152 the top of the forehead and the chin.
 */
export function noseOffset(lm) {
  const w = Math.abs(lm[454].x - lm[234].x), h = Math.abs(lm[152].y - lm[10].y);
  if (!(w > 1e-4) || !(h > 1e-4)) return null;
  return { x: (lm[4].x - (lm[234].x + lm[454].x) / 2) / w, y: (lm[4].y - (lm[10].y + lm[152].y) / 2) / h };
}

/**
 * Decides whether an angle from the matrix and an offset from the landmarks move together, from the correlation
 * of their deviations (running mean removed, so a resting head contributes nothing). Until both have really
 * moved it returns the prior: the sign to apply when they rise together.
 */
export class AxisSign {
  constructor(prior, { minSamples = 8, minAngleStd = 0.03, minOffsetStd = 0.004, minCorr = 0.4 } = {}) {
    Object.assign(this, { prior, minSamples, minAngleStd, minOffsetStd, minCorr });
    this.n = 0; this.ma = 0; this.mo = 0; this.saa = 0; this.soo = 0; this.sao = 0;
  }

  add(angle, offset) {
    if (!finite(angle) || !finite(offset)) return;
    this.n += 1;
    const da = angle - this.ma, doo = offset - this.mo;
    this.ma += da / this.n; this.mo += doo / this.n;
    this.saa += da * (angle - this.ma); this.soo += doo * (offset - this.mo); this.sao += da * (offset - this.mo);
  }

  get sign() {
    if (this.n < this.minSamples) return this.prior;
    const sa = Math.sqrt(this.saa / this.n), so = Math.sqrt(this.soo / this.n);
    if (sa < this.minAngleStd || so < this.minOffsetStd) return this.prior;
    const corr = this.sao / this.n / (sa * so);
    return Math.abs(corr) >= this.minCorr ? Math.sign(corr) * this.prior : this.prior;
  }
}

export const HEAD = {
  centreSeconds: 1.0, centreMinSamples: 6,
  // Gain: the head turn, from the centre, that reaches the edge of the Claude window. The Mac app's calibration assumes a turn of
  // 0.5 rad across a screen's width and 0.3 rad across its height (CalibrationAim: assumedYawPerScreenWidth, assumedPitchPerScreenHeight),
  // so 0.25 and 0.15 rad each way from the centre, which is the 15 degrees an edge costs at laptop distance. A head-only turn
  // covers about 80% of the angle to a target (the eyes take the rest), hence 0.2 and 0.13. With four panes the outer pane then
  // starts at a 0.1 rad (6 degree) turn and the window edge is 11.5 degrees: well inside a natural turn.
  yawRange: 0.2,
  pitchRange: 0.13,
  lostAfter: 1.0,
};

/** The centring step: "point your nose at the dot", a 3, 2, 1 countdown that runs only while a face is seen. */
export const CENTRE = { seconds: 3, averageLast: 1.5, minSamples: 6, lostAfter: 0.4 };

export class CentreStep {
  constructor(opts = {}) { this.opts = { ...CENTRE, ...opts }; this.reset(); }

  reset() {
    this.elapsed = 0; this.samples = []; this.lastSeen = null; this.lastTick = null; this.centre = null; this.lost = true; this.everSeen = false;
  }

  get done() { return this.centre !== null; }
  /** The big number: 3, 2, 1. */
  get count() { return Math.max(1, Math.ceil(this.opts.seconds - this.elapsed - 1e-9)); }
  get progress() { return Math.min(this.elapsed / this.opts.seconds, 1); }

  /** A face reading (head angles in radians). Readings in the final `averageLast` seconds make the centre. */
  push(t, yaw, pitch) {
    if (this.done || !finite(t) || !finite(yaw) || !finite(pitch)) return;
    this.lastSeen = t; this.everSeen = true;
    if (this.lost) { this.lost = false; if (this.elapsed > this.opts.seconds - this.opts.averageLast) this.elapsed = this.opts.seconds - this.opts.averageLast; this.samples = []; }
    if (this.elapsed >= this.opts.seconds - this.opts.averageLast) this.samples.push([yaw, pitch]);
  }

  /** Advance the clock; call every display frame. Time only counts while a face was seen within `lostAfter`. */
  tick(t) {
    if (this.done) return this;
    const dt = this.lastTick === null ? 0 : Math.min(Math.max(t - this.lastTick, 0), 0.1);
    this.lastTick = t;
    const seen = this.lastSeen !== null && t - this.lastSeen <= this.opts.lostAfter;
    if (!seen) { this.lost = true; return this; }
    if (this.lost) return this;   // wait for the next reading to confirm the face is back
    this.elapsed = Math.min(this.elapsed + dt, this.opts.seconds);
    if (this.elapsed >= this.opts.seconds && this.samples.length >= this.opts.minSamples) {
      const n = this.samples.length;
      this.centre = { yaw: this.samples.reduce((a, q) => a + q[0], 0) / n, pitch: this.samples.reduce((a, q) => a + q[1], 0) / n };
    }
    return this;
  }
}

/**
 * Head yaw and pitch to a point on the stage, 0...1 each way. The first second of readings sets the centre
 * (their median), so there is no calibration screen. Smoothed with the same One Euro settings as NosePointer.
 */
export class HeadPointer {
  constructor(opts = {}) {
    this.opts = { ...HEAD, ...opts };
    this.yawSign = new AxisSign(-1);     // +x on the stage = the visitor's right = nose moving right in the mirror
    this.pitchSign = new AxisSign(1);    // +y = down: the nose sinking in the face outline reads as looking down
    // Tuned for 15 to 30 Hz head samples (simulated sweep, 0.5 Hz across 80% of the stage, noise 0.4%): 0.6/3 lags 67 ms, 1/5 lags one sample
    // (33 ms at 30 Hz) and adds about 1 px of rest jitter on a 1400 px stage. The display-rate glide (NoseGlide) hides the sample steps.
    this.fx = new OneEuroFilter(1.0, 5, 1);
    this.fy = new OneEuroFilter(1.0, 5, 1);
    this.recentre();
  }

  recentre() {
    this.centre = null; this.samples = []; this.startT = null; this.lastT = null;
    this.fx.reset(); this.fy.reset();
  }

  get centring() { return this.centre === null; }

  /** Use a centre taken elsewhere (the centring step) instead of the automatic first second. */
  setCentre(yaw, pitch) {
    this.centre = { yaw, pitch }; this.samples = []; this.startT = null; this.lastT = null;
    this.fx.reset(); this.fy.reset();
  }

  /** 0...1 through the centring second. */
  get centringProgress() {
    if (this.centre) return 1;
    if (this.startT === null || this.lastT === null) return 0;
    return Math.min((this.lastT - this.startT) / this.opts.centreSeconds, 1);
  }

  /** `reading`: {t, yaw, pitch, offset?}. Returns {x, y} or null while centring. */
  push(reading) {
    const { t, yaw, pitch, offset } = reading;
    if (!finite(t) || !finite(yaw) || !finite(pitch)) return null;
    if (offset) { this.yawSign.add(yaw, offset.x); this.pitchSign.add(pitch, offset.y); }
    // A face gone for a while restarts the one-second centring only if the wait was long.
    if (this.lastT !== null && t - this.lastT > this.opts.lostAfter && this.centre === null) { this.samples = []; this.startT = null; }
    this.lastT = t;
    const yawS = yaw * this.yawSign.sign, pitchS = pitch * this.pitchSign.sign;
    if (this.centre === null) {
      if (this.startT === null) this.startT = t;
      this.samples.push([yawS, pitchS, yaw, pitch]);
      if (t - this.startT < this.opts.centreSeconds || this.samples.length < this.opts.centreMinSamples) return null;
      this.centre = { yaw: median(this.samples.map((q) => q[2])), pitch: median(this.samples.map((q) => q[3])) };
      this.samples = [];
    }
    // The sign may flip once evidence arrives; the offset is taken from the raw angles so the centre stays valid.
    const dx = (yaw - this.centre.yaw) * this.yawSign.sign / (2 * this.opts.yawRange);
    const dy = (pitch - this.centre.pitch) * this.pitchSign.sign / (2 * this.opts.pitchRange);
    const x = Math.min(Math.max(0.5 + dx, 0), 1), y = Math.min(Math.max(0.5 + dy, 0), 1);
    return { x: this.fx.filter(x, t), y: this.fy.filter(y, t) };
  }
}

/** Median of the centring samples is steadier than any single frame. */
export function median(values) {
  const v = values.filter(finite).sort((a, b) => a - b);
  if (!v.length) return 0;
  const k = v.length >> 1;
  return v.length % 2 ? v[k] : (v[k - 1] + v[k]) / 2;
}

// ---- Frame scheduler -----------------------------------------------------------------------------------

/**
 * Decides which tracker runs on a camera frame. The hand runs as often as the camera allows (taps are read from
 * short edges), the face less often (the head moves slowly and is smoothed). When measured inference time would
 * take more than `maxBusy` of the main thread, the face slows first, then the hand.
 */
export class FrameScheduler {
  /**
   * The hand runs on every camera frame (gestures matter more than head precision). Only the face is decimated, and only as far as
   * the time budget needs: the nose dot is smoothed and extrapolated at display rate anyway. If even the slowest face rate does
   * not fit, the hand drops to every other frame as a last resort.
   */
  constructor({ faceHz = 30, minFaceHz = 15, maxBusy = 0.8 } = {}) {
    Object.assign(this, { faceHz, minFaceHz, maxBusy });
    this.targetFaceHz = faceHz; this.handEvery = 1; this.frameN = 0;
    this.lastFace = -Infinity; this.lastFrame = null; this.frameHz = 30;
    this.avgHand = 0; this.avgFace = 0;
  }

  get handHz() { return this.frameHz / this.handEvery; }

  record(kind, ms) {
    const k = kind === 'hand' ? 'avgHand' : 'avgFace';
    this[k] = this[k] === 0 ? ms : this[k] * 0.9 + ms * 0.1;
    const busy = (this.avgHand * this.handHz + this.avgFace * this.faceHz) / 1000;
    if (busy > this.maxBusy) {
      if (this.faceHz > this.minFaceHz) this.faceHz = Math.max(this.minFaceHz, this.faceHz * 0.85);
      else if (this.handEvery < 2) this.handEvery = 2;
    } else if (busy < this.maxBusy * 0.6) {
      if (this.handEvery > 1) this.handEvery = 1;
      else this.faceHz = Math.min(this.targetFaceHz, this.faceHz * 1.05);
    }
  }

  /** What to run on the frame arriving at `now` (seconds). */
  plan(now) {
    if (this.lastFrame !== null && now > this.lastFrame) { const hz = 1 / (now - this.lastFrame); if (hz < 240) this.frameHz = this.frameHz * 0.9 + hz * 0.1; }
    this.lastFrame = now; this.frameN += 1;
    const hand = this.frameN % this.handEvery === 0 || this.handEvery === 1;
    // The face takes the frames the hand leaves room for: never both when the pair would not fit one frame interval.
    let face = (now - this.lastFace) * this.faceHz >= 0.9;
    if (face && hand && (this.avgHand + this.avgFace) > 1000 / this.frameHz * 0.9) face = false;
    if (!face && (now - this.lastFace) * this.faceHz >= 1.3) face = true;   // never starve the face for long
    if (face) this.lastFace = now;
    return { hand, face };
  }
}

/**
 * The nose dot at display rate. Trackers deliver filtered head positions at 15 to 30 Hz; the display runs at 60 to 120. `sample` takes a
 * tracker position; `frame` is called every display frame and returns where to draw: the latest sample plus its velocity carried
 * forward for at most one sample interval (so the dot does not wait for the next reading), then a short eased glide toward that.
 */
export class NoseGlide {
  constructor({ tau = 0.035, extrapolate = 1, maxInterval = 0.1, velocityMix = 0.5, staleAfter = 0.5 } = {}) {
    Object.assign(this, { tau, extrapolate, maxInterval, velocityMix, staleAfter });
    this.reset();
  }

  reset() { this.last = null; this.vx = 0; this.vy = 0; this.interval = 0.05; this.pos = null; this.lastFrame = null; }

  sample(t, x, y) {
    if (!finite(t) || !finite(x) || !finite(y)) return;
    if (this.last && t > this.last.t) {
      const dt = t - this.last.t;
      this.interval = Math.min(Math.max(this.interval * 0.7 + dt * 0.3, 0.008), this.maxInterval);
      const m = this.velocityMix;
      this.vx = this.vx * (1 - m) + (x - this.last.x) / dt * m;
      this.vy = this.vy * (1 - m) + (y - this.last.y) / dt * m;
    }
    this.last = { t, x, y };
  }

  /** Where to draw at `now` (seconds), or null when there is no recent sample. */
  frame(now) {
    if (!this.last || now - this.last.t > this.staleAfter) { this.pos = null; this.lastFrame = null; return null; }
    const ext = Math.min(Math.max(now - this.last.t, 0), this.interval * this.extrapolate);
    const tx = this.last.x + this.vx * ext, ty = this.last.y + this.vy * ext;
    if (!this.pos) this.pos = { x: tx, y: ty };
    else {
      const dt = Math.min(Math.max(now - (this.lastFrame ?? now - 1 / 60), 0), 0.1), k = 1 - Math.exp(-dt / this.tau);
      this.pos = { x: this.pos.x + (tx - this.pos.x) * k, y: this.pos.y + (ty - this.pos.y) * k };
    }
    this.lastFrame = now;
    return this.pos;
  }
}

// ---- Mouse and touch stand-in for the hand -------------------------------------------------------------

/**
 * Turns pointer events into hand observations, so the same GestureMachine drives the fallback mode: a press is
 * a closed pinch (click-click = double pinch, press and move = pinch and drag), and a press held still for
 * `holdAfter` seconds is the thumbs-up pose.
 */
export class PointerHand {
  constructor({ holdAfter = 0.3, moveTolerance = 14, minTap = 0.06 } = {}) {
    Object.assign(this, { holdAfter, moveTolerance, minTap });
    this.downAt = null; this.pos = null; this.origin = null; this.moved = false; this.pending = [];
  }

  frameFor(t, pos, pinch, pose) {
    // A press or release is an exact event, not a measurement to debounce.
    return { t, present: true, pose, palmCenter: pos ? { x: pos.nx, y: 1 - pos.ny } : null, pinch, immediate: true };
  }

  down(t, pos) {
    this.downAt = t; this.pos = pos; this.origin = pos; this.moved = false;
    this.pending.push(this.frameFor(t, pos, 0.03, null), this.frameFor(t + 0.001, pos, 0.03, null));
  }

  move(pos) {
    this.pos = pos;
    if (this.downAt !== null && Math.hypot(pos.x - this.origin.x, pos.y - this.origin.y) > this.moveTolerance) this.moved = true;
  }

  up(t, pos) {
    if (this.downAt === null) return;
    const holding = !this.moved && t - this.downAt >= this.holdAfter;
    const at = Math.max(t, this.downAt + this.minTap);
    if (!holding) this.pending.push(this.frameFor(at, pos ?? this.pos, 0.5, null), this.frameFor(at + 0.001, pos ?? this.pos, 0.5, null));
    this.downAt = null;
    if (holding) this.pending.push({ t: at, present: false, pose: null, palmCenter: null, pinch: null });
  }

  /** The observations to feed for the frame at `t`, in order. */
  frames(t) {
    const out = this.pending; this.pending = [];
    if (this.downAt !== null) {
      const holding = !this.moved && t - this.downAt >= this.holdAfter;
      // A hold is not a pinch: no distance, so it can never read as a tap.
      out.push(this.frameFor(t, this.pos, holding ? null : 0.03, holding ? 'thumbsUp' : null));
    } else if (!out.length) {
      out.push({ t, present: false, pose: null, palmCenter: null, pinch: null });
    }
    return out.filter((o, i) => i === 0 || o.t > out[i - 1].t);
  }
}

// ---- Island and dictation ------------------------------------------------------------------------------

/** Which island layout is live: the app's own priority order (OverlayModel gestures, then dictation, then banner). */
export function islandMode({ listening, sessionSwitch, gesture, banner }) {
  if (listening && sessionSwitch) return 'switching';
  if (gesture) {
    if ((gesture.action === 'talk' || gesture.action === 'stop') && !gesture.active) return 'firstPinch';
    if (gesture.action === 'send' && gesture.willAct) return 'sendHold';
  }
  if (listening) return 'dictating';
  if (banner) return 'banner';
  return 'idle';
}

/** How many words of the canned sentence a dictation has typed after `elapsed` seconds. */
export function wordsTyped(total, elapsed, wordsPerSecond = 3.2, startDelay = 0.6) {
  if (elapsed < startDelay) return 0;
  return Math.min(total, 1 + Math.floor((elapsed - startDelay) * wordsPerSecond));
}
