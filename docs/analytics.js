// Anonymous visit counts for the website, shared by the letter (index.html) and the demo (live/index.html). What is sent, and what is never sent,
// is listed in docs/telemetry.md ("The website"); AGENTS.md's trust rules cover the Mac app, not this site. No SDK, no cookie, no localStorage.
// Every event is sent at most once per visit, after the page has loaded, at low priority, and silently fails.

const URL_ = 'https://us.i.posthog.com/i/v0/e/';
const KEY = 'phc_BGLN5bXDwYbwdzkzci7L2tNbyWXtUfwokDRhP6TG5w2Q';   // PostHog's public, write-only project token (allow-listed in .gitleaks.toml)
const STORE = 'ensemble-site-visit';

const nav = typeof navigator === 'undefined' ? {} : navigator;
const off = nav.doNotTrack === '1' || window.doNotTrack === '1' || nav.globalPrivacyControl === true
  // pages opened from a local server or file never count, so developing the site does not pollute the numbers (the end-to-end test opts in)
  || (!window.__ensembleAnalyticsLocal && /^(localhost|127\.0\.0\.1|\[::1\]|)$/.test(location.hostname));

const PAGE = document.querySelector('.ls-app') ? 'demo' : 'letter';
const viewport = () => (innerWidth < 600 ? 'phone' : innerWidth < 1024 ? 'tablet' : 'desktop');

// the per-visit id and the list of events already sent live in sessionStorage; where that is unavailable they live in memory for this page
let mem = null;
function visit() {
  try {
    const raw = sessionStorage.getItem(STORE);
    if (raw) { const v = JSON.parse(raw); if (typeof v.id === 'string' && Array.isArray(v.sent)) return v; }
    const v = { id: crypto.randomUUID(), sent: [] };
    sessionStorage.setItem(STORE, JSON.stringify(v));
    return v;
  } catch { return mem || (mem = { id: crypto.randomUUID?.() || String(Math.random()).slice(2) + Date.now(), sent: [] }); }
}
function remember(v) { try { sessionStorage.setItem(STORE, JSON.stringify(v)); } catch { mem = v; } }

const queue = [];
let loaded = document.readyState === 'complete';

function post(body) {
  try {
    // a Blob of text/plain is a "simple" request, so no preflight; PostHog reads the JSON body whatever the content type says
    if (nav.sendBeacon && nav.sendBeacon(URL_, new Blob([body], { type: 'text/plain' }))) return;
  } catch { /* fall through */ }
  try { fetch(URL_, { method: 'POST', body, keepalive: true, credentials: 'omit', referrerPolicy: 'no-referrer', priority: 'low' }).catch(() => {}); } catch { /* silent */ }
}

function flush() {
  while (queue.length) post(queue.shift());
}

/** Count `event` once per visit (once per stage for demo_stage). `props` may only be `{ stage }`. */
export function track(event, props = {}) {
  if (off) return;
  try {
    const v = visit(), once = `${PAGE}:${event}:${props.stage || ''}`;
    if (v.sent.includes(once)) return;
    v.sent.push(once); remember(v);
    const properties = { page: PAGE, viewport: viewport(), schema_version: 1, ...(props.stage ? { stage: props.stage } : {}), $process_person_profile: false, $geoip_disable: true };
    queue.push(JSON.stringify({ api_key: KEY, event, distinct_id: v.id, timestamp: new Date().toISOString(), properties }));
    if (loaded) setTimeout(flush, 0);
  } catch { /* silent */ }
}

if (!off) {
  if (!loaded) addEventListener('load', () => { loaded = true; setTimeout(flush, 0); }, { once: true });

  // any element that starts the DMG download: the buttons, the nav link, the demo's finish card
  addEventListener('click', (e) => { if (e.target instanceof Element && e.target.closest('a[href$="/Ensemble.dmg"]')) track('download_clicked'); }, true);

  // the download section of the letter, or the demo's finish screen, has been at least half on screen
  const target = PAGE === 'demo' ? document.getElementById('finish') : document.getElementById('download');
  if (target && 'IntersectionObserver' in window) {
    const io = new IntersectionObserver((rows) => { if (rows.some((r) => r.intersectionRatio >= 0.5 || r.intersectionRect.height >= innerHeight * 0.5)) { io.disconnect(); track('download_seen'); } }, { threshold: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1] });   // a section taller than two screens can never be half visible, so half a screen of it counts too
    io.observe(target);
  }

  if (PAGE === 'demo') track('demo_stage', { stage: 'opened' });
  else {
    track('site_visit');
    let queued = false;
    const atBottom = () => { queued = false; if (innerHeight + scrollY >= document.documentElement.scrollHeight - 24) { removeEventListener('scroll', onScroll); track('scrolled_to_bottom'); } };
    const onScroll = () => { if (!queued) { queued = true; requestAnimationFrame(atBottom); } };
    addEventListener('scroll', onScroll, { passive: true });
  }
}
