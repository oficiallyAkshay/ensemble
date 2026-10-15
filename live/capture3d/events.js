// Reads a recorded take and finds the moments a person would check by eye: pinch contacts, a held thumbs-up, and the range of a
// pinch-and-drag. Pure functions over the capture page's frame shape, so the timeline works with or without the 3D scene.

const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], (a[2] || 0) - (b[2] || 0));
const PALM_CM = 9.5; // wrist to middle knuckle, an average adult hand; only used for the rough centimetre estimate

// Pinch contact uses a closed threshold and a wider open one so a trembling fingertip does not count twice.
const PINCH_CLOSE = 0.28, PINCH_OPEN = 0.42;

function runs(flags, times, gapMs) {
  const out = [];
  let start = -1, last = -1;
  for (let i = 0; i < flags.length; i++) {
    if (flags[i]) { if (start < 0) start = i; else if (times[i] - times[last] > gapMs) { out.push([start, last]); start = i; } last = i; }
  }
  if (start >= 0) out.push([start, last]);
  return out.map(([a, b]) => ({ start: times[a], end: times[b], a, b }));
}

// Thumb tip to index tip over palm length, from world landmarks; null without a hand.
export const pinchRatio = (world) => (world ? dist(world[4], world[8]) / (dist(world[0], world[9]) || 1) : null);
export const PINCH_IS_OPEN = PINCH_OPEN;

export function detectEvents(frames, { aspect = 16 / 9 } = {}) {
  const n = frames.length;
  const times = frames.map((f) => f.t);
  const durationMs = n ? times[n - 1] : 0;
  const handFrames = frames.filter((f) => f.world).length;

  // Pinch distance relative to the palm, so it does not depend on how far the hand is from the camera. Measured on the image
  // landmarks: on the owner's recordings the world landmarks' depth kept thumb and index 7 cm apart through every visible pinch
  // (palm ratio never under 0.77 in a double-pinch take), while the image showed four clean contacts (ratio down to 0.10).
  const imgRatio = (im) => Math.hypot((im[4][0] - im[8][0]) * aspect, im[4][1] - im[8][1]) / (Math.hypot((im[0][0] - im[9][0]) * aspect, im[0][1] - im[9][1]) || 1);
  const ratio = frames.map((f) => (f.image ? imgRatio(f.image) : f.world ? dist(f.world[4], f.world[8]) / (dist(f.world[0], f.world[9]) || 1) : null));
  let closed = false;
  const pinchOn = ratio.map((r) => {
    if (r === null) { closed = false; return false; }
    closed = closed ? r < PINCH_OPEN : r < PINCH_CLOSE;
    return closed;
  });
  const pinches = runs(pinchOn, times, 120).filter((p) => p.end - p.start >= 30 || p.a === p.b);

  const up = frames.map((f) => f.gesture === 'Thumb_Up' && f.score >= 0.5);
  const holds = runs(up, times, 200).filter((h) => h.end - h.start >= 150);

  // Scroll: the longest pinch, followed through the image y of the pinch point (smaller y is higher in the picture).
  let scroll = null;
  const long = pinches.slice().sort((x, y) => (y.end - y.start) - (x.end - x.start))[0];
  if (long && long.end - long.start >= 600) {
    const ys = [];
    for (let i = long.a; i <= long.b; i++) {
      const f = frames[i];
      if (f.image) ys.push({ t: f.t, y: (f.image[4][1] + f.image[8][1]) / 2, palm: Math.hypot((f.image[0][0] - f.image[9][0]) * aspect, f.image[0][1] - f.image[9][1]) });
    }
    if (ys.length > 3) {
      const lo = ys.reduce((m, p) => (p.y < m.y ? p : m)), hi = ys.reduce((m, p) => (p.y > m.y ? p : m));
      const palm = ys.reduce((s, p) => s + p.palm, 0) / ys.length || 1;
      const first = ys[0].y;
      scroll = {
        start: long.start, end: long.end,
        upCm: Math.max(0, ((first - lo.y) / palm) * PALM_CM),
        downCm: Math.max(0, ((hi.y - lo.y) / palm) * PALM_CM),
        topT: lo.t,
        upThenDown: lo.t > ys[0].t && lo.t < ys[ys.length - 1].t,
      };
    }
  }
  return { durationMs, handFrames, total: n, pinches, holds, scroll };
}

// One plain sentence per check; ok=false tells the owner the take probably needs a retake.
export function judge(id, ev) {
  const s = (ms) => (ms / 1000).toFixed(1);
  const out = [];
  if (ev.total && ev.handFrames / ev.total < 0.5) out.push({ ok: false, text: `The hand was seen in only ${ev.handFrames} of ${ev.total} frames.` });
  if (id === 'rest') {
    if (ev.pinches.length) out.push({ ok: false, text: `${ev.pinches.length} pinch${ev.pinches.length > 1 ? 'es' : ''} found, but the hand should stay still.` });
    else if (ev.holds.length) out.push({ ok: false, text: 'A thumbs-up was found, but the hand should stay relaxed.' });
    else out.push({ ok: true, text: 'The hand stayed relaxed.' });
  } else if (id === 'dictate') {
    const gaps = ev.pinches.slice(1).map((p, i) => p.start - ev.pinches[i].end);
    const pause = gaps.length ? Math.max(...gaps) : 0;
    out.push({ ok: ev.pinches.length === 4, text: `${ev.pinches.length} pinch contacts found (4 expected).` });
    if (ev.pinches.length >= 3) out.push({ ok: pause >= 700, text: `Longest pause between pinches ${s(pause)} s (about 1 s expected).` });
  } else if (id === 'send') {
    const h = ev.holds.slice().sort((x, y) => (y.end - y.start) - (x.end - x.start))[0];
    if (!h) out.push({ ok: false, text: 'No thumbs-up found.' });
    else out.push({ ok: h.end - h.start >= 1200, text: `Thumbs-up held ${s(h.end - h.start)} s (1.5 s expected).` });
  } else if (id === 'scroll') {
    const sc = ev.scroll;
    if (!sc) out.push({ ok: false, text: 'No long pinch found.' });
    else {
      out.push({ ok: sc.upCm >= 5, text: `Hand moved up about ${Math.round(sc.upCm)} cm while pinched (about 10 expected, an estimate).` });
      out.push({ ok: sc.upThenDown, text: sc.upThenDown ? 'It went up, then back down.' : 'It did not go up and then down.' });
    }
  } else if (id === 'look') {
    out.push({ ok: ev.handFrames / (ev.total || 1) < 0.3, text: ev.handFrames / (ev.total || 1) < 0.3 ? 'The hand was out of view.' : 'The hand was still in view.' });
  }
  return out;
}
