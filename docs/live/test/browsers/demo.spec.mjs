// A first visit in Firefox and in WebKit (Safari's engine): the home page loads and shows its sections, the demo opens on the
// desktop, and turning Ensemble on reaches the running state. Both projects in playwright.config.mjs run this one file.
//
// Firefox runs the demo on a fake camera (a test pattern with no face or hand). WebKit has no fake camera, so there the demo
// runs in its mouse mode (live/?mouse=1, the same path as the mouse scenario in ../e2e.mjs); the camera path is not exercised in WebKit.
// The Chrome speed and frame-rate asserts of e2e.mjs are not repeated here.
import { test, expect } from '@playwright/test';

// The only off-origin requests the home page may make, the same list as LETTER_ALLOWED in ../e2e.mjs. Each is answered with an
// empty stand-in so the test never reaches the network, and a 404 never shows up as a console error.
const STARS_URL = 'https://api.github.com/repos/oficiallyAkshay/ensemble';
const RELEASES_URL = 'https://api.github.com/repos/oficiallyAkshay/ensemble/releases?per_page=100';
const POSTHOG_URL = 'https://us.i.posthog.com/i/v0/e/';
const STUBS = new Map([[STARS_URL, '{"stargazers_count":0}'], [RELEASES_URL, '[]'], [POSTHOG_URL, '{}']]);
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };

// Collects console errors, uncaught page errors and off-origin requests for one page.
async function watch(page, baseURL) {
  const w = { errors: [], offOrigin: [] };
  // MediaPipe reports its own INFO lines through console.error; those are not errors.
  page.on('console', (m) => { if (m.type() === 'error' && !/INFO:/.test(m.text())) w.errors.push(m.text()); });
  page.on('pageerror', (e) => w.errors.push(String(e)));
  await page.route((u) => !u.href.startsWith(baseURL) && !/^(blob:|data:|about:)/.test(u.href), (route) => {
    const url = route.request().url();
    if (!STUBS.has(url)) { w.offOrigin.push(url); return route.abort(); }
    if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
    return route.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: STUBS.get(url) });
  });
  return w;
}

test('the home page loads with no console errors and shows its sections', async ({ page, baseURL }) => {
  const w = await watch(page, baseURL);
  await page.goto('/index.html');
  await page.waitForLoadState('load');
  await expect(page.locator('#try')).toBeVisible();
  for (const id of ['intuitive', 'how', 'download']) await expect(page.locator(`#${id}`)).toBeAttached();
  await page.locator('#download').scrollIntoViewIfNeeded();
  await expect(page.locator('#download')).toBeVisible();
  expect(w.offOrigin, 'requests outside the allow-list').toEqual([]);
  expect(w.errors, 'console errors').toEqual([]);
});

test('the demo opens on the desktop and turning Ensemble on reaches the running state', async ({ page, baseURL, browserName }) => {
  const w = await watch(page, baseURL);
  const mouseMode = browserName === 'webkit';
  await page.goto(mouseMode ? '/live/index.html?mouse=1' : '/live/index.html');
  await page.waitForLoadState('load');

  const app = page.locator('#app');
  await expect(app).toHaveAttribute('data-state', 'desk');
  await expect(page.locator('#gate')).toBeHidden();
  await expect(page.locator('#mac')).toHaveAttribute('data-claude', 'closed');

  // Double-click Claude, then turn Ensemble on from the menu bar: the same steps as turnOn() in ../e2e.mjs.
  await page.evaluate(() => document.getElementById('claude-icon').dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 2 })));
  await page.evaluate(() => document.getElementById('mb-ens').click());
  await page.evaluate(() => document.getElementById('mp-power').click());

  // Running, or the gate explaining why not: the second case fails with the gate's own words.
  await expect.poll(async () => (await app.getAttribute('data-state')) === 'running' || (await page.locator('#gate-message').isVisible()), { timeout: 180000 }).toBe(true);
  const gateText = await page.locator('#gate-message').textContent();
  await expect(app, `the gate said: ${gateText}`).toHaveAttribute('data-state', 'running');
  expect(await page.evaluate(() => window.__live.mode)).toBe(mouseMode ? 'mouse' : 'camera');

  expect(w.errors, 'console errors').toEqual([]);
});
