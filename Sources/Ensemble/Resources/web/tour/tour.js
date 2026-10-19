/* Glue between the tour window and scene3d.js. Everything here talks to the app through one script message
 * handler named "tour"; nothing leaves the process. Messages out: {ready}, {failed: reason}.
 * The page takes ?scene=<name>&rm=1 (reduce motion). */
(function () {
  'use strict';
  var q = new URLSearchParams(window.location.search);
  var reduced = q.get('rm') === '1';
  var HAND_SCENES = { dictate: 1, send: 1, scroll: 1 };
  var instance = null, current = q.get('scene') || 'welcome', watch = null;
  // The web view does not pass the window's look to the page, so the page reads the colour scheme itself and follows it live.
  var scheme = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  function themeName() { return scheme && scheme.matches ? 'dark' : 'light'; }
  function paintPage() { document.documentElement.style.background = scheme && scheme.matches ? '#0f1218' : '#ffffff'; }

  function post(message) {
    try { window.webkit.messageHandlers.tour.postMessage(message); } catch (e) { /* opened outside the app */ }
  }

  // scene3d.js keeps drawing an empty stage if the hand model cannot load; report it so the app shows its still.
  function watchHand() {
    if (watch) { clearInterval(watch); watch = null; }
    if (!instance || !HAND_SCENES[current]) return;
    var waited = 0;
    watch = setInterval(function () {
      waited += 250;
      if (instance._hand && instance._hand()) { clearInterval(watch); watch = null; return; }
      if ((instance._ready && instance._ready()) || waited > 6000) {
        clearInterval(watch); watch = null; post({ failed: 'hand' });
      }
    }, 250);
  }

  function start() {
    if (!window.THREE || !window.EnsembleScene || !THREE.GLTFLoader) { post({ failed: 'scripts' }); return; }
    var stage = document.getElementById('stage');
    paintPage();
    try {
      instance = window.EnsembleScene.mount(stage, { scene: current, reducedMotion: reduced, handUrl: 'hand.glb', theme: themeName() });
    } catch (e) { post({ failed: 'mount' }); return; }
    if (scheme) scheme.addEventListener('change', function () { paintPage(); if (instance) instance.setTheme(themeName()); });
    var canvas = instance && instance.canvas;
    if (!canvas) { post({ failed: 'webgl' }); return; }
    canvas.addEventListener('webglcontextlost', function (e) { e.preventDefault(); post({ failed: 'webgl' }); });
    post({ ready: true });
    watchHand();
  }

  window.EnsembleTour = {
    setScene: function (name) {
      if (!instance) return;
      current = name;
      instance.setScene(name);
      watchHand();
    },
    destroy: function () {
      if (watch) clearInterval(watch);
      if (instance) instance.destroy();
      instance = null;
    }
  };

  start();
})();
