// The Claude desktop pane, shared by the demo (live.js) and the letter page's mini screens, so both draw exactly the same thing.
// Pure DOM building: no timers, no state beyond what the callers keep on the pane object.

export const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

export const ICON = {
  terminal: '<path d="m4 6 5 4-5 4M11 15h6"/>', panel: '<rect x="3.5" y="4" width="13" height="12" rx="2.5"/><path d="M11.5 4v12"/>', globe: '<circle cx="10" cy="10" r="6.8"/><path d="M3.2 10h13.6M10 3.2c2.6 2.6 2.6 11 0 13.6M10 3.2c-2.6 2.6-2.6 11 0 13.6"/>',
  folder: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h3.2l1.6 1.8h6.2A1.5 1.5 0 0 1 17 8.3v6.2a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 3 14.500z"/>',
  more: '<circle cx="10" cy="4.5" r=".6"/><circle cx="10" cy="10" r=".6"/><circle cx="10" cy="15.5" r=".6"/>', close: '<path d="m5 5 10 10M15 5 5 15"/>',
  sidebar: '<rect x="3" y="4" width="14" height="12" rx="2.5"/><path d="M8 4v12"/>', back: '<path d="M16 10H4.500m4.500-4.500L4.500 10 9 14.500"/>', fwd: '<path d="M4 10h11.500M11 5.500 15.500 10 11 14.500"/>',
  chev: '<path d="m5 8 5 5 5-5"/>', plus: '<path d="M10 4v12M4 10h12"/>', rec: '<circle cx="10" cy="10" r="7"/><circle cx="10" cy="10" r="2.6" fill="currentColor"/>',
  mic: '<rect x="7.500" y="3" width="5" height="9" rx="2.500"/><path d="M4.500 10a5.500 5.500 0 0 0 11 0M10 15.500V17.500"/>',
};
/** Light inline formatting for Claude's text: **bold** and `code`, only once both marks are present. */
export const fmt = (t) => esc(t).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/`(.+?)`/g, '<code>$1</code>');
export const ic = (n, cls = '') => `<svg class="ic ${cls}" viewBox="0 0 20 20" aria-hidden="true">${ICON[n]}</svg>`;
export const MODES = ['Opus 5.5', 'Sonnet 5.5', 'Opus 5.5', 'Sonnet 5.5'], EFFORT = ['Medium', 'High', 'Medium', 'Low'];

/** One session pane. `k` is its position in the window (the first pane carries the traffic lights). Returns the pane object the callers drive. */
export function buildPane(s, k) {
  const root = document.createElement('article');
  root.className = 'ls-pane'; root.dataset.id = s.id;
  root.innerHTML = `<header class="ls-ph">
      ${k === 0 ? `<span class="ls-lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="ls-nav x1">${ic('sidebar')}${ic('back')}${ic('fwd')}</span>` : ''}
      <button type="button" class="ls-title" tabindex="-1"><span>${esc(s.name)}</span>${ic('chev')}</button>
      <span class="ls-icons">${ic('terminal', 'x2')}${ic('panel', 'x2')}${ic('globe', 'x1')}${ic('folder')}${ic('more')}${ic('close')}</span>
    </header>
    <div class="ls-transcript" tabindex="-1"><div class="ls-working"><span class="gl"><i></i><i></i><i></i><i></i></span><span class="wl">Running a command</span></div></div>
    <i class="ls-ind" aria-hidden="true"></i>
    <div class="ls-composer">${ic('plus')}<span class="draft"></span>${ic('rec')}${ic('mic', 'mic')}</div>
    <div class="ls-foot"><span>Bypass permissions</span><span class="sp">${esc(MODES[k])}</span><span>${EFFORT[k]}</span><i class="ring"></i></div>`;
  const pane = {
    id: s.id, name: s.name, el: root, transcript: root.querySelector('.ls-transcript'), draftEl: root.querySelector('.draft'), workEl: root.querySelector('.ls-working'),
    draft: '', prompts: s.prompts, promptIdx: 0, typed: 0, streams: 0, frame: { x: 0, y: 0, w: 0, h: 0 },
    get words() { return this.prompts[this.promptIdx % this.prompts.length].say.split(' '); },
    get reply() { return this.prompts[this.promptIdx % this.prompts.length].reply; },
  };
  for (const [who, text] of s.transcript) addLine(pane, who, text);
  // a thin scroll indicator that shows while the transcript moves, and the top fade says there is more above
  const ind = root.querySelector('.ls-ind'); let hide = 0;
  pane.transcript.addEventListener('scroll', () => {
    const tr = pane.transcript, room = tr.scrollHeight - tr.clientHeight;
    if (room <= 0) return;
    const h = Math.max(tr.clientHeight * tr.clientHeight / tr.scrollHeight, 28);
    ind.style.height = `${h}px`;
    ind.style.top = `${tr.offsetTop + (tr.scrollTop / room) * (tr.clientHeight - h)}px`;
    root.classList.add('scrolling'); clearTimeout(hide); hide = setTimeout(() => root.classList.remove('scrolling'), 900);
  }, { passive: true });
  return pane;
}

export function addLine(pane, who, text) {
  let p;
  if (who === 'list') { p = document.createElement('ul'); p.className = 'ls-line list'; p.innerHTML = text.map((t) => `<li>${fmt(t)}</li>`).join(''); }
  else if (who === 'table') {
    p = document.createElement('div'); p.className = 'ls-line tablewrap';
    p.innerHTML = `<table><thead><tr>${text.head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${text.rows.map((r) => `<tr>${r.map((c) => `<td>${esc(c)}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
  } else {
    p = document.createElement(who === 'code' ? 'pre' : 'p');
    p.className = `ls-line ${who}`;
    if (who === 'claude') p.innerHTML = fmt(text); else p.textContent = text;
  }
  pane.transcript.insertBefore(p, pane.workEl);
  return p;
}
