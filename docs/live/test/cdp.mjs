// A very small Chrome DevTools Protocol client over node's built-in WebSocket: no packages.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
export const say = (m) => console.log(`[${new Date().toISOString()}] ${m}`);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function launch({ port, flags = [], size = '1280,800' }) {
  const dir = mkdtempSync(join(tmpdir(), 'live-chrome-'));
  // Chrome refuses to start as root without this, and cloud sessions run as root; the test browser only opens local pages.
  const asRoot = process.platform !== 'darwin' && process.getuid?.() === 0 ? ['--no-sandbox'] : [];
  const proc = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${dir}`, '--no-first-run', '--no-default-browser-check',
    '--disable-background-timer-throttling', `--window-size=${size}`, ...asRoot, ...flags, 'about:blank'], { stdio: 'ignore' });
  for (let i = 0; i < 100; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}/json/version`); if (r.ok) break; } catch { /* not up yet */ }
    await sleep(100);
  }
  return {
    port, proc,
    async close() { proc.kill('SIGTERM'); await sleep(300); rmSync(dir, { recursive: true, force: true }); },
  };
}

export class Page {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); this.handlers = new Map(); ws.addEventListener('message', (e) => this.onMessage(e)); }

  static async open(port, url = 'about:blank') {
    const t = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' })).json();
    const ws = new WebSocket(t.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.addEventListener('open', res); ws.addEventListener('error', rej); });
    const p = new Page(ws); p.targetId = t.id;
    return p;
  }

  onMessage(e) {
    const m = JSON.parse(e.data);
    if (m.id) { const p = this.pending.get(m.id); this.pending.delete(m.id); if (m.error) p.rej(new Error(m.error.message)); else p.res(m.result); return; }
    for (const h of this.handlers.get(m.method) || []) h(m.params);
  }

  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((res, rej) => this.pending.set(id, { res, rej }));
  }

  on(method, fn) { (this.handlers.get(method) || this.handlers.set(method, []).get(method)).push(fn); }

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

  close() { try { this.ws.close(); } catch { /* closed */ } }
}
