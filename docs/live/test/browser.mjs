// The test browser: the installed Chrome, driven by playwright-core (npm install in this folder first).
// Playwright owns the launch, the pages and the permissions. Request priority, encoded data length and cache flags are not in
// Playwright's API, so each page also holds a Chrome DevTools Protocol session, used for those and for the raw calls the scenarios make.
import { chromium } from 'playwright-core';

export const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
export const say = (m) => console.log(`[${new Date().toISOString()}] ${m}`);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function launch({ flags = [], size = '1280,800' }) {
  // Chrome refuses to start as root without this, and cloud sessions run as root; the test browser only opens local pages.
  const asRoot = process.platform !== 'darwin' && process.getuid?.() === 0 ? ['--no-sandbox'] : [];
  // headless:false so the new headless mode is chosen by the flag below, not by Playwright's own headless choice.
  const browser = await chromium.launch({ executablePath: CHROME, headless: false,
    args: ['--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-background-timer-throttling', `--window-size=${size}`, ...asRoot, ...flags] });
  // viewport:null keeps the window size above as the page size, as a plain Chrome window has it.
  const context = await browser.newContext({ viewport: null });
  return { browser, context, close: () => browser.close() };
}

export class Page {
  constructor(page, session) { this.page = page; this.session = session; }

  static async open(c) {
    const page = await c.context.newPage();
    const p = new Page(page, await c.context.newCDPSession(page));
    p.c = c;
    return p;
  }

  send(method, params = {}) { return this.session.send(method, params); }

  on(method, fn) { this.session.on(method, fn); }

  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  }

  async waitFor(expression, timeoutMs, what) {
    const t0 = Date.now();
    for (;;) {
      if (await this.eval(expression)) return Date.now() - t0;
      if (Date.now() - t0 > timeoutMs) throw new Error(`timeout waiting for ${what || expression}`);
      await sleep(100);
    }
  }

  async mouse(type, x, y, extra = {}) {
    await this.send('Input.dispatchMouseEvent', { type, x, y, button: type === 'mouseMoved' ? 'none' : 'left', clickCount: 1, ...extra });
  }

  /** The camera permission for one address: Playwright grants it; a refusal is not in its API, so it is set on the browser itself. */
  async camera(setting, origin) {
    if (setting === 'granted') { await this.c.context.grantPermissions(['camera'], { origin }); return; }
    const { targetInfo } = await this.send('Target.getTargetInfo');
    const browserSession = await this.c.browser.newBrowserCDPSession();
    try { await browserSession.send('Browser.setPermission', { permission: { name: 'camera' }, setting, origin, browserContextId: targetInfo.browserContextId }); }
    finally { await browserSession.detach(); }
  }

  /** Records requests, bytes and console problems from now on. */
  async watch() {
    const w = { requests: [], bytes: new Map(), errors: [], logs: [] };
    await this.send('Network.enable'); await this.send('Runtime.enable'); await this.send('Log.enable'); await this.send('Page.enable');
    this.on('Network.requestWillBeSent', (p) => w.requests.push({ id: p.requestId, url: p.request.url, type: p.type, priority: p.request.initialPriority, at: Date.now() }));
    this.on('Network.loadingFinished', (p) => { const r = w.requests.find((q) => q.id === p.requestId); if (r) r.bytes = p.encodedDataLength; });
    this.on('Network.responseReceived', (p) => { const r = w.requests.find((q) => q.id === p.requestId); if (r) { r.status = p.response.status; r.mime = p.response.mimeType; r.enc = p.response.headers['content-encoding'] || ''; r.cached = !!(p.response.fromDiskCache || p.response.fromServiceWorker || r.cached); } });
    this.on('Network.requestServedFromCache', (p) => { const r = w.requests.find((q) => q.id === p.requestId); if (r) r.cached = true; });
    this.on('Runtime.exceptionThrown', (p) => w.errors.push('exception: ' + (p.exceptionDetails.exception?.description || p.exceptionDetails.text)));
    this.on('Runtime.consoleAPICalled', (p) => { const line = p.args.map((a) => a.value ?? a.description).join(' '); (p.type === 'error' ? w.errors : w.logs).push(`${p.type}: ${line}`); });
    this.on('Log.entryAdded', (p) => { if (p.entry.level === 'error') w.errors.push(`log: ${p.entry.text} ${p.entry.url || ''}`); });
    return w;
  }

  close() { this.session.detach().catch(() => { /* closed */ }); }
}
