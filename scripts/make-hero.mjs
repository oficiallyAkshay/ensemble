#!/usr/bin/env node
// Builds the README hero, Assets/hero.svg, from the committed spec Assets/hero.hero.json and the two hand stills in Assets/hero-hands.
// Every word in the picture comes from the spec, so the spec and the picture cannot disagree (figurehead's check reads both).
// Same inputs, same bytes: no dates, no randomness.
//
// Usage: node scripts/make-hero.mjs           writes Assets/hero.svg
//        node scripts/make-hero.mjs --check   exits 1 when Assets/hero.svg is not what the spec and stills build
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SPEC = join(ROOT, 'Assets', 'hero.hero.json');
const OUT = join(ROOT, 'Assets', 'hero.svg');

const spec = JSON.parse(readFileSync(SPEC, 'utf8'));
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const still = (name) => `data:image/png;base64,${readFileSync(join(ROOT, 'Assets', 'hero-hands', `${name}.png`)).toString('base64')}`;
const [look, talk, send, scroll, widen, even] = spec.handled;
const [face, hand] = spec.sources;

const W = 900;
const CARD = { y: 132, w: 250, h: 232, gap: 25, x: 50 };
const cardX = (i) => CARD.x + i * (CARD.w + CARD.gap);

// One abstract Claude session: a name bar and rows of text.
function session(x, y, w, h, { lit = false, rows = 4, lead = 0 } = {}) {
  const out = [`<rect class="${lit ? 'win lit' : 'win'}" x="${x}" y="${y}" width="${w}" height="${h}" rx="10"/>`];
  out.push(`<rect class="bar strong" x="${x + 10}" y="${y + 10 + lead}" width="${Math.round(w * 0.38)}" height="6" rx="3"/>`);
  for (let i = 0; i < rows; i++) {
    out.push(`<rect class="bar" x="${x + 10}" y="${y + 26 + lead + i * 14}" width="${Math.round((w - 20) * [1, 0.82, 0.94, 0.6][i % 4])}" height="6" rx="3"/>`);
  }
  return out.join('\n    ');
}

function handTile(cx, cy, r, id, href) {
  return `<circle class="tile" cx="${cx}" cy="${cy}" r="${r}"/>
    <image href="${href}" x="${cx - r}" y="${cy - r}" width="${2 * r}" height="${2 * r}" clip-path="url(#${id})"/>
    <circle class="ring" cx="${cx}" cy="${cy}" r="${r}"/>`;
}

function card(i, title, sub, tag, art) {
  const x = cardX(i);
  return `<g>
    <rect class="card" x="${x}" y="${CARD.y}" width="${CARD.w}" height="${CARD.h}" rx="18"/>
    <circle class="chip" cx="${x + 28}" cy="${CARD.y + 30}" r="13"/>
    <text class="num" x="${x + 28}" y="${CARD.y + 35.5}" text-anchor="middle">${i + 1}</text>
    <text class="h" x="${x + 52}" y="${CARD.y + 38}">${esc(title)}</text>
    <text class="tag" x="${x + CARD.w - 16}" y="${CARD.y + 36}" text-anchor="end">${esc(tag)}</text>
    ${art}
    <text class="sub" x="${x + 18}" y="${CARD.y + CARD.h - 22}">${esc(sub)}</text>
  </g>`;
}

const artY = CARD.y + 58;
const winH = 110;

// 1 Look: three sessions side by side, the one you face lit, the nose dot on it.
const x1 = cardX(0) + 19;
const lookArt = [0, 1, 2].map((k) => session(x1 + k * 74, artY, 64, winH, { lit: k === 1, rows: 4 })).join('\n    ') +
  `\n    <circle class="halo" cx="${x1 + 74 + 32}" cy="${artY + 66}" r="17"/>\n    <circle class="dot" cx="${x1 + 74 + 32}" cy="${artY + 66}" r="7"/>`;

// 2 Talk: the capsule says it is listening, the composer shows the voice, the hand is the real pinch.
const x2 = cardX(1) + 16;
const bars = [8, 16, 26, 14, 22, 10, 18].map((hh, k) => `<rect class="wave" x="${x2 + 12 + k * 11}" y="${artY + winH - 22 - hh / 2 + 1}" width="5" height="${hh}" rx="2.5"/>`).join('');
const talkArt = `${session(x2, artY, 118, winH, { rows: 2, lead: 30 })}
    <rect class="capsule" x="${x2 + 12}" y="${artY + 10}" width="94" height="26" rx="13"/>
    <text class="capsule-t" x="${x2 + 59}" y="${artY + 28}" text-anchor="middle">Listening</text>
    <rect class="composer" x="${x2 + 6}" y="${artY + winH - 40}" width="106" height="30" rx="9"/>
    ${bars}
    ${handTile(x2 + 118 + 10 + 46, artY + 55, 46, 'clip-a', still('pinch'))}`;

// 3 Send: the draft leaves as a message, the hand is the real thumbs-up.
const sendArt = `${session(x2 + (cardX(2) - cardX(1)), artY, 118, winH, { rows: 2, lead: 0 })}
    <rect class="bubble" x="${cardX(2) + 16 + 24}" y="${artY + 52}" width="88" height="30" rx="10"/>
    <rect class="onbubble" x="${cardX(2) + 16 + 34}" y="${artY + 61}" width="52" height="5" rx="2.5"/>
    <rect class="onbubble" x="${cardX(2) + 16 + 34}" y="${artY + 71}" width="34" height="5" rx="2.5"/>
    <path class="check" d="M${cardX(2) + 16 + 12},${artY + 98} l5,5 l9,-10"/>
    <text class="sent" x="${cardX(2) + 16 + 34}" y="${artY + 104}">${esc(spec.deliverable.label)}</text>
    ${handTile(cardX(2) + 16 + 118 + 10 + 46, artY + 55, 46, 'clip-b', still('thumbs-up'))}`;

// The secondary gestures, one chip each.
const chipY = CARD.y + CARD.h + 20;
const chipH = 54;
const glyphs = [
  // pinch and drag: two chevrons around the pinch point
  '<path class="g" d="M-6,-5 L0,-11 L6,-5"/><path class="g" d="M-6,5 L0,11 L6,5"/><circle class="gf" cx="0" cy="0" r="3"/>',
  // peace sign: two fingers
  '<path class="g thick" d="M-1,11 L-8,-10"/><path class="g thick" d="M1,11 L8,-10"/>',
  // scissors, closing
  '<g transform="translate(-12 -12) scale(1.2)"><circle class="g" cx="5" cy="5" r="3"/><circle class="g" cx="5" cy="15" r="3"/><path class="g" d="M7.5,7 L19,17"/><path class="g" d="M7.5,13 L19,3"/></g>',
];
const chips = [scroll, widen, even].map((it, k) => {
  const x = cardX(k);
  return `<g>
    <rect class="chipbox" x="${x}" y="${chipY}" width="${CARD.w}" height="${chipH}" rx="14"/>
    <g transform="translate(${x + 30} ${chipY + chipH / 2})">${glyphs[k]}</g>
    <text class="ch" x="${x + 58}" y="${chipY + 23}">${esc(it.label)}</text>
    <text class="cs" x="${x + 58}" y="${chipY + 42}">${esc(it.sub)}</text>
  </g>`;
}).join('\n  ');

const arrows = [0, 1].map((k) => `<path class="arrow" d="M${cardX(k) + CARD.w + 8},${CARD.y + CARD.h / 2 - 7} l8,7 l-8,7"/>`).join('\n  ');
const H = chipY + chipH + 34;

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-labelledby="hero-title">
  <title id="hero-title">${esc(spec.title)}</title>
  <defs>
    <clipPath id="clip-a"><circle cx="${x2 + 118 + 10 + 46}" cy="${artY + 55}" r="46"/></clipPath>
    <clipPath id="clip-b"><circle cx="${cardX(2) + 16 + 118 + 10 + 46}" cy="${artY + 55}" r="46"/></clipPath>
    <style>
      :root { --bg: #f4f7fc; --card: #ffffff; --edge: #d3dcea; --ink: #101828; --muted: #556176; --accent: #2563d9; --accent-soft: #dbe7fd; --bar: #dfe6f1; --bar-strong: #b7c4da; --tile: #e8eef8; --fill: #2563d9; }
      @media (prefers-color-scheme: dark) { :root { --bg: #0e131c; --card: #172030; --edge: #2a374d; --ink: #eef3fb; --muted: #a3afc3; --accent: #7aa9ff; --accent-soft: #1f3560; --bar: #2a374d; --bar-strong: #475877; --tile: #d9e2f2; --fill: #3377ee; } }
      text { font-family: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
      .bg { fill: var(--bg); }
      .card { fill: var(--card); stroke: var(--edge); stroke-width: 1.5; }
      .eyebrow { fill: var(--accent); font-size: 15px; font-weight: 700; letter-spacing: 2px; }
      .headline { fill: var(--ink); font-size: 34px; font-weight: 700; }
      .subhead { fill: var(--muted); font-size: 17px; }
      .chip { fill: var(--fill); }
      .num { fill: #fff; font-size: 14px; font-weight: 700; }
      .h { fill: var(--ink); font-size: 22px; font-weight: 700; }
      .tag { fill: var(--muted); font-size: 14px; }
      .sub { fill: var(--muted); font-size: 15px; }
      .win { fill: var(--bg); stroke: var(--edge); stroke-width: 1.5; }
      .win.lit { fill: var(--accent-soft); stroke: var(--accent); stroke-width: 3; }
      .bar { fill: var(--bar); }
      .strong { fill: var(--bar-strong); }
      .halo { fill: var(--accent); opacity: 0.22; }
      .dot { fill: var(--accent); }
      .capsule { fill: var(--fill); }
      .capsule-t { fill: #fff; font-size: 14px; font-weight: 600; }
      .composer { fill: var(--card); stroke: var(--edge); stroke-width: 1.5; }
      .wave { fill: var(--accent); }
      .tile { fill: var(--tile); }
      .ring { fill: none; stroke: var(--accent); stroke-width: 2.5; }
      .bubble { fill: var(--fill); }
      .onbubble { fill: #fff; opacity: 0.9; }
      .check { fill: none; stroke: var(--accent); stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; }
      .sent { fill: var(--accent); font-size: 14px; font-weight: 700; }
      .arrow { fill: none; stroke: var(--bar-strong); stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; }
      .chipbox { fill: var(--card); stroke: var(--edge); stroke-width: 1.5; }
      .g { fill: none; stroke: var(--accent); stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round; }
      .g.thick { stroke-width: 5; }
      .gf { fill: var(--accent); }
      .ch { fill: var(--ink); font-size: 16px; font-weight: 700; }
      .cs { fill: var(--muted); font-size: 14px; }
    </style>
  </defs>
  <rect class="bg" width="${W}" height="${H}" rx="22"/>
  <text class="eyebrow" x="${W / 2}" y="40" text-anchor="middle">${esc(spec.hub.label)}</text>
  <text class="headline" x="${W / 2}" y="82" text-anchor="middle">${esc(spec.headline)}</text>
  <text class="subhead" x="${W / 2}" y="110" text-anchor="middle">${esc(spec.subhead)}</text>
  ${card(0, look.label, look.sub, face.label, lookArt)}
  ${card(1, talk.label, talk.sub, hand.label, talkArt)}
  ${card(2, send.label, send.sub, hand.label, sendArt)}
  ${arrows}
  ${chips}
</svg>
`;

if (process.argv.includes('--check')) {
  let current = '';
  try { current = readFileSync(OUT, 'utf8'); } catch { /* missing */ }
  if (current !== svg) { console.error('Assets/hero.svg is not what Assets/hero.hero.json and Assets/hero-hands build. Run: node scripts/make-hero.mjs'); process.exit(1); }
  console.log('Assets/hero.svg matches its spec and stills');
} else {
  writeFileSync(OUT, svg);
  console.log(`wrote Assets/hero.svg (${svg.length} bytes)`);
}
