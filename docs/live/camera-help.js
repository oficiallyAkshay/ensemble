// The "allow the camera again" steps, shared by the home page popover and the demo start screen.
// Each browser words its permission menu differently across versions, so every set names the site
// settings control and the Camera choice instead of quoting a menu path that will drift.
const STEPS = {
  safari: ['Safari', ['Choose Safari, then Settings, then Websites, then Camera.', 'Next to this site, choose Allow.', 'Come back and press Try again.']],
  firefox: [
    'Firefox',
    ['Click the permissions icon at the left of the address bar.', 'Next to Camera, clear the blocked setting or choose Allow.', 'Come back and press Try again.'],
  ],
  chrome: [
    'Chrome',
    ['Click the site settings icon at the left of the address bar.', 'Set Camera to Allow.', 'Come back and press Try again.'],
  ],
};

/** Which of the three the visitor is using; Chrome-based browsers share Chrome's steps. */
export function browserOf(ua) {
  if (/Firefox\/|FxiOS\//.test(ua)) return 'firefox';
  if (/Chrome\/|Chromium\/|CriOS\/|Edg\//.test(ua)) return 'chrome';
  if (/Safari\//.test(ua)) return 'safari';
  return 'chrome';
}

/** A block of three separate step lists, the visitor's browser first and open, the other two one click away. */
export function cameraHelp(doc, ua) {
  const mine = browserOf(ua);
  const root = doc.createElement('div');
  root.className = 'cam-help';
  for (const key of [mine, ...Object.keys(STEPS).filter((k) => k !== mine)]) {
    const [name, steps] = STEPS[key];
    const d = doc.createElement('details');
    d.dataset.browser = key;
    d.open = key === mine;
    const s = doc.createElement('summary');
    s.textContent = `Allow the camera in ${name}`;
    const ol = doc.createElement('ol');
    for (const t of steps) { const li = doc.createElement('li'); li.textContent = t; ol.appendChild(li); }
    d.append(s, ol);
    root.appendChild(d);
  }
  return root;
}
