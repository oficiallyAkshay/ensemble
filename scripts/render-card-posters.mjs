#!/usr/bin/env node
// Renders one small still (a poster) for every 3D card on the home page, and prints the size of the text each card draws.
// The page shows a card's poster before its scene loads and on a phone (docs/index.html, class "poster"). The scenes are the
// tour's own files (published as assets/3d); headless Chrome is driven by playwright-core (npm ci in docs/live/test first),
// the same way scripts/render-hero-hands.mjs does it.
//
// Writes docs/assets/posters/<scene>.webp, 640 px wide, from the page at 1280 px wide with the scene on its still frame.
// Prints, for each card at 1280 px and at 390 px wide, the smallest text the scene draws in CSS pixels, and exits 1 when that is
// under 14 px (1280) or 12 px (390). Words only: the cards draw their other text as grey bars, and a mark such as the star is not counted.
// Run it when a scene, the hand or the page layout changes.
//
// Usage: node scripts/render-card-posters.mjs
import { createServer } from 'node:http';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { launch, Page, sleep, say } from '../docs/live/test/browser.mjs';
import { appCopy } from '../docs/live/test/app-copies.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DOCS = join(ROOT, 'docs');
const OUT = join(DOCS, 'assets', 'posters');
const POSTER_W = 640;
const VIEWS = [{ width: 1280, floor: 14, posters: true }, { width: 390, floor: 12, posters: false }];

// Every word the scenes draw goes through fillText; the canvas's transform and pixel ratio turn its font size into CSS pixels.
const HOOK = `(() => {
  window.__texts = {};
  const draw = CanvasRenderingContext2D.prototype.fillText;
  CanvasRenderingContext2D.prototype.fillText = function (s, ...rest) {
    try {
      const c = this.canvas, host = /[A-Za-z0-9]/.test(s) && c.closest && c.closest('.card3d') && c.closest('.card3d').querySelector('[data-scene]');
      if (host) {
        const px = parseFloat(/(\\d+(?:\\.\\d+)?)px/.exec(this.font)[1]) * this.getTransform().a / (c.width / c.clientWidth);
        (window.__texts[host.dataset.scene] = window.__texts[host.dataset.scene] || []).push([String(s).slice(0, 24), Math.round(px * 10) / 10]);
      }
    } catch (e) { /* a measurement must never stop a scene drawing */ }
    return draw.call(this, s, ...rest);
  };
})()`;

const server = createServer((req, res) => {
  const path = new URL(req.url, 'http://x').pathname;
  (async () => {
    const file = join(DOCS, path === '/' ? 'index.html' : path);
    if (!file.startsWith(DOCS)) throw new Error('outside docs');
    // The 3D files live in the app; serve them at their published path when docs/ has no copy.
    let body;
    try { body = readFileSync(file); } catch (e) { body = await appCopy(path); if (!body) throw e; }
    const type = path.endsWith('.js') || path.endsWith('.mjs') ? 'text/javascript' : path.endsWith('.html') || path === '/' ? 'text/html' : path.endsWith('.css') ? 'text/css' : 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': type });
    res.end(body);
  })().catch(() => { res.writeHead(404).end(); });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const flags = ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'];
const chrome = await launch({ size: '1280,900', flags });
const failures = [];
try {
  mkdirSync(OUT, { recursive: true });
  for (const view of VIEWS) {
    const p = await Page.open(chrome);
    await p.send('Page.enable');
    await p.send('Emulation.setDeviceMetricsOverride', { width: view.width, height: 900, deviceScaleFactor: 1, mobile: false });
    // Reduced motion makes each scene draw once, on its still frame (the frame a poster shows).
    await p.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
    await p.send('Page.addScriptToEvaluateOnNewDocument', { source: HOOK });
    await p.page.goto(`http://127.0.0.1:${port}/index.html`);
    const names = await p.eval("[...document.querySelectorAll('.card3d [data-scene]')].map((e) => e.dataset.scene)");
    for (const name of names) {
      const sel = `document.querySelector('[data-scene="${name}"]')`;
      await p.eval(`${sel}.scrollIntoView({ block: 'center' }); 0`);
      await p.waitFor(`${sel}.closest('.card3d').classList.contains('ready')`, 60000, `the ${name} card`);
      await sleep(1000);   // the poster fades out over 0.6 s once the card is ready
      const texts = await p.eval(`window.__texts[${JSON.stringify(name)}] || []`);
      const smallest = texts.length ? Math.min(...texts.map((t) => t[1])) : null;
      const where = texts.length ? texts.find((t) => t[1] === smallest)[0] : '';
      say(`${view.width} px  ${name.padEnd(10)} ${smallest === null ? 'no words drawn' : `smallest text ${smallest} px ("${where}")`}`);
      if (smallest !== null && smallest < view.floor) failures.push(`${name} at ${view.width} px: ${smallest} px`);
      if (view.posters) {
        const r = await p.eval(`(() => { const b = ${sel}.closest('.card3d').getBoundingClientRect(); return { x: b.left + scrollX, y: b.top + scrollY, width: b.width, height: b.height }; })()`);
        const shot = await p.send('Page.captureScreenshot', { format: 'webp', quality: 60, clip: { ...r, scale: POSTER_W / r.width } });
        const bytes = Buffer.from(shot.data, 'base64');
        writeFileSync(join(OUT, `${name}.webp`), bytes);
        say(`wrote docs/assets/posters/${name}.webp (${bytes.length} bytes)`);
      }
    }
    await p.page.close();
  }
} finally {
  await chrome.close();
  server.close();
}
if (failures.length) { say(`under the floor: ${failures.join('; ')}`); process.exitCode = 1; }
process.exit(process.exitCode || 0);
