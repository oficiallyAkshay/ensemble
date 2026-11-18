// Stand-in app: one window with a fixed title and a few named controls. Start it with --force-renderer-accessibility
// so Chromium builds the accessibility tree without an assistive tool attached.
const { app, BrowserWindow } = require('electron');
const path = require('path');

app.whenReady().then(() => {
  const win = new BrowserWindow({ width: 480, height: 320, title: 'Window Tree Stand-In' });
  // The page title would replace the window title, so keep the one set above.
  win.on('page-title-updated', (event) => event.preventDefault());
  win.loadFile(path.join(__dirname, 'index.html'));
});

app.on('window-all-closed', () => app.quit());
