// A new person's first minutes, followed on the real website: node docs/live/test/first-run.mjs [base address]
// Default base: the live website. Needs the network and Chrome at the usual macOS path (CHROME_PATH overrides).
// It follows the steps marked "test" in docs/first-run.md, prints each one it checks, and says which steps it cannot reach.
// It installs nothing, grants or resets no permission and never opens the installed app: the disk image is only asked about with a header request.
import { launch, Page, say } from './cdp.mjs';

const BASE = (process.argv[2] || process.env.ENSEMBLE_SITE || 'https://oficiallyakshay.github.io/ensemble/').replace(/\/?$/, '/');
const ORIGIN = new URL(BASE).origin;
const DMG = 'https://github.com/oficiallyAkshay/ensemble/releases/latest/download/Ensemble.dmg';
// The star count and the visit events are best-effort on the page; a slow or rate-limited answer from them is not a stop for a stranger.
const OPTIONAL = ['https://api.github.com/', 'https://us.i.posthog.com/'];
const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok }); say(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' :: ' + detail : ''}`); };

async function run() {
  say(`following the first-run path on ${BASE}`);
  const c = await launch({ port: 9335, flags: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const p = await Page.open(c.port); const w = await p.watch();
  const failed = [];
  p.on('Network.loadingFailed', (e) => { if (!e.canceled) failed.push(`${e.errorText} ${w.requests.find((r) => r.id === e.requestId)?.url || ''}`); });
  try {
    // Step 1: open the link and read the page.
    await p.send('Page.navigate', { url: BASE });
    await p.waitFor("document.readyState === 'complete'", 30000, 'home page load');
    check('step 1: the home page loads with a title and a headline', await p.eval("document.title.length > 0 && !!document.querySelector('h1') && document.querySelector('h1').getBoundingClientRect().height > 0"));
    const bad = w.requests.filter((r) => r.url.startsWith(ORIGIN) && r.status >= 400).map((r) => `${r.status} ${r.url}`);
    const mine = failed.filter((f) => !OPTIONAL.some((o) => f.includes(o)));
    check('step 1: the home page makes no failed request', bad.length === 0 && mine.length === 0, [...bad, ...mine].join(' | '));

    // Step 3b: the Download buttons all point at the one disk image, and it exists.
    const links = await p.eval("['dl-btn', 'dl-btn-2'].map((id) => document.getElementById(id)?.href || '').concat([...document.querySelectorAll('.nav-links a')].filter((a) => a.textContent.trim() === 'Download').map((a) => a.href))");
    check('step 3b: three Download links (hero, nav, Download section) all point at the latest disk image', links.length === 3 && links.every((l) => l === DMG), links.join(' '));
    const head = await fetch(DMG, { method: 'HEAD', redirect: 'follow' });
    const size = Number(head.headers.get('content-length') || 0);
    const type = head.headers.get('content-type') || '';
    check('step 3b: the latest disk image resolves (header request only)', head.ok && size > 1e6 && !/html/.test(type), `${head.status} ${type} ${(size / 1e6).toFixed(1)} MB`);

    // Step 3a: See the demo asks for the camera, then opens the demo with the camera already allowed.
    await p.eval("document.getElementById('try').click()");
    await p.waitFor("location.pathname.endsWith('/live/')", 30000, 'the demo to open');
    check('step 3a: See the demo opens the demo with the camera allowed', (await p.eval('location.search')) === '?go=1', await p.eval('location.href'));

    // Step 4: in the demo, open Claude and turn Ensemble on; it reaches its running state.
    await p.waitFor("document.readyState === 'complete' && !!window.__live", 30000, 'the demo to load');
    check('step 4: the demo opens on the empty desktop with the first step waiting', await p.eval("document.getElementById('app').dataset.state === 'desk' && window.__live.step() === 'opened'"));
    await p.eval("document.getElementById('claude-icon').dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 2 }))");
    await p.eval("document.getElementById('mb-ens').click()");
    await p.eval("document.getElementById('mp-power').click()");
    const ms = await p.waitFor("document.getElementById('app').dataset.state === 'running' || (!document.getElementById('gate').hidden && !document.getElementById('gate-message').hidden)", 180000, 'the demo to run');
    const state = await p.eval("document.getElementById('app').dataset.state");
    check('step 4: the demo reaches its running state with a fake camera', state === 'running', `${state} after ${ms} ms${state === 'running' ? '' : ': ' + await p.eval("document.getElementById('gate-message').textContent")}`);
    if (state === 'running') {
      check('step 4: the guide moves on to the first gesture (centring on the camera)', await p.eval("window.__live.step() === 'centred' && !document.getElementById('centre').hidden"), await p.eval('window.__live.step()'));
    }
    const errs = w.errors.filter((e) => !/INFO:/.test(e));
    check('steps 1 to 4: no console errors', errs.length === 0, errs.join(' | '));
  } finally { p.close(); await c.close(); }
}

try { await run(); } catch (e) { check('the first-run path ran to its end', false, e.stack || e.message); }
say('not reached by this script (done by hand, docs/first-run.md): opening the disk image, moving the app, the macOS warning, Camera and Accessibility grants, the app tour, a real hand and a real Claude session');
const bad = results.filter((r) => !r.ok);
say(`${results.length - bad.length} passed, ${bad.length} failed`);
process.exit(bad.length ? 1 : 0);
