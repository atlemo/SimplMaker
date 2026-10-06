// SimplMaker site: mobile menu, lazy looping clips, scroll reveal. No dependencies.
(function () {
  'use strict';
  var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Mobile menu
  var toggle = document.querySelector('.nav-toggle');
  var menu = document.getElementById('nav-menu');
  if (toggle && menu) {
    toggle.addEventListener('click', function () {
      var open = toggle.getAttribute('aria-expanded') !== 'true';
      toggle.setAttribute('aria-expanded', String(open));
      menu.classList.toggle('open', open);
    });
    menu.addEventListener('click', function (e) {
      if (e.target.closest('a')) { toggle.setAttribute('aria-expanded', 'false'); menu.classList.remove('open'); }
    });
  }

  // Clips: nothing is fetched until a clip is near the screen; they play only while visible.
  // A clip whose file does not exist yet keeps its blueprint placeholder.
  var clips = document.querySelectorAll('.clip');
  function load(fig) {
    var v = fig.querySelector('video');
    if (!v || v.dataset.loaded) return;
    v.dataset.loaded = '1';
    [['webm', 'video/webm'], ['mp4', 'video/mp4']].forEach(function (t) {
      var s = document.createElement('source');
      s.src = v.dataset[t[0]]; s.type = t[1];
      v.appendChild(s);
    });
    v.addEventListener('loadeddata', function () {
      fig.classList.add('ready');
      if (reduced) { v.controls = true; } else if (fig.dataset.visible) { v.play().catch(function () {}); }
    });
    v.load();
  }
  if ('IntersectionObserver' in window) {
    var nearObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) { load(e.target); nearObserver.unobserve(e.target); } });
    }, { rootMargin: '600px 0px' });
    var playObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        var v = e.target.querySelector('video');
        e.target.dataset.visible = e.isIntersecting ? '1' : '';
        if (!v || reduced || !e.target.classList.contains('ready')) return;
        if (e.isIntersecting) v.play().catch(function () {}); else v.pause();
      });
    }, { threshold: 0.25 });
    clips.forEach(function (c) { nearObserver.observe(c); playObserver.observe(c); });
  } else {
    clips.forEach(load);
  }

  // Scroll reveal
  var items = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !reduced) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
    }, { rootMargin: '0px 0px -8% 0px' });
    items.forEach(function (el) { io.observe(el); });
  } else {
    items.forEach(function (el) { el.classList.add('in'); });
  }
})();
