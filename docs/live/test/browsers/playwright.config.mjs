// Runs demo.spec.mjs once in Firefox and once in WebKit (Safari's engine, not the Safari app), on a desktop-size window.
// The static server is docs/live/test/serve.mjs, the same one e2e.mjs uses, started here on a fixed port.
import { defineConfig } from '@playwright/test';

const PORT = 8791;
const desktop = { viewport: { width: 1400, height: 860 }, baseURL: `http://127.0.0.1:${PORT}` };

export default defineConfig({
  testDir: '.',
  testMatch: 'demo.spec.mjs',
  timeout: 240000,
  workers: 1,
  reporter: 'list',
  webServer: { command: `node ../serve.mjs ${PORT}`, url: `http://127.0.0.1:${PORT}/index.html`, reuseExistingServer: true },
  projects: [
    {
      name: 'firefox',
      use: {
        ...desktop,
        browserName: 'firefox',
        // Firefox answers getUserMedia with a generated test pattern and skips the permission prompt.
        firefoxUserPrefs: { 'media.navigator.streams.fake': true, 'media.navigator.permission.disabled': true },
      },
    },
    {
      name: 'webkit',
      use: { ...desktop, browserName: 'webkit' },   // WebKit has no fake camera: demo.spec.mjs uses the demo's mouse mode there.
    },
  ],
});
