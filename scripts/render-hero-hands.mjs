#!/usr/bin/env node
// Renders the two hand stills the README hero uses (the double pinch and the thumbs-up) from the same 3D hand and recorded motion
// the tour and the website use (docs/assets/3d), with headless Chrome driven over the DevTools Protocol, no packages.
// Writes Assets/hero-hands/pinch.png and Assets/hero-hands/thumbs-up.png. Run it only when the hand model or the recorded
// motion changes; `scripts/make-hero.mjs` then folds the stills into Assets/hero.svg.
//
// Usage: node scripts/render-hero-hands.mjs
import { createServer } from 'node:http';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { launch, Page, sleep } from '../docs/live/test/cdp.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DOCS = join(ROOT, 'docs');
const OUT = join(ROOT, 'Assets', 'hero-hands');

// scene and time pick the frame of the tour's recorded take; clip is the square, in the 480-point stage, that frames the hand.
const STILLS = [
  { name: 'pinch', scene: 'dictate', t: 3.0, clip: [122, 100, 162, 162] },
  { name: 'thumbs-up', scene: 'send', t: 1.5, clip: [130, 108, 162, 162] },
];

const HARNESS = `<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;background:transparent}#h{position:absolute;left:0;top:0;width:480px;height:480px}</style>
<div id="h"></div>
<script src="/assets/3d/three.min.js"></script><script src="/assets/3d/GLTFLoader.js"></script><script src="/assets/3d/CCDIKSolver.js"></script>
<script src="/assets/3d/capture-default.js"></script><script src="/assets/3d/scene3d.js"></script>
<script>
window.pose = (scene, t) => {
  const el = document.getElementById('h'); el.innerHTML = '';
  const inst = window.EnsembleScene.mount(el, { scene, reducedMotion: true, handUrl: '/assets/3d/hand.glb', handOnly: true });
  return new Promise((done) => { let n = 0; const timer = setInterval(() => {
    if ((inst._ready && inst._ready()) || ++n > 100) { clearInterval(timer); inst._seek(scene, t); if (el.firstChild) el.firstChild.style.background = 'transparent'; setTimeout(() => done(true), 400); }
  }, 100); });
};
</script>`;

const server = createServer((req, res) => {
  const path = new URL(req.url, 'http://x').pathname;
  if (path === '/harness.html') { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(HARNESS); return; }
  try {
    const file = join(DOCS, path);
    if (!file.startsWith(DOCS)) throw new Error('outside docs');
    const body = readFileSync(file);
    res.writeHead(200, { 'Content-Type': path.endsWith('.js') ? 'text/javascript' : 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404).end(); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const webPort = server.address().port;

const chrome = await launch({ port: 9344, size: '600,600', flags: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
try {
  const page = await Page.open(9344, `http://127.0.0.1:${webPort}/harness.html`);
  await page.send('Page.enable');
  await page.send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  await page.send('Emulation.setDeviceMetricsOverride', { width: 480, height: 480, deviceScaleFactor: 1, mobile: false });
  await sleep(1500);
  mkdirSync(OUT, { recursive: true });
  for (const s of STILLS) {
    await page.eval(`pose(${JSON.stringify(s.scene)}, ${s.t})`);
    await sleep(500);
    const [x, y, width, height] = s.clip;
    const shot = await page.send('Page.captureScreenshot', { format: 'png', clip: { x, y, width, height, scale: 1.5 } });
    writeFileSync(join(OUT, `${s.name}.png`), Buffer.from(shot.data, 'base64'));
    console.log(`wrote Assets/hero-hands/${s.name}.png`);
  }
  page.close();
} finally {
  await chrome.close();
  server.close();
}
process.exit(0);
