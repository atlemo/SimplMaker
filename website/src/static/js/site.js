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
    // Escape closes the menu and returns focus to its button.
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') {
        toggle.setAttribute('aria-expanded', 'false'); menu.classList.remove('open'); toggle.focus();
      }
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
  // Screenshot slideshow: arrows, keys and mouse drag move it one picture at a time; touch scrolls it natively.
  var track = document.querySelector('.shots-track');
  if (track) {
    var prevBtn = document.querySelector('.shots-btn[data-dir="-1"]'), nextBtn = document.querySelector('.shots-btn[data-dir="1"]');
    var step = function () { var f = track.querySelector('.shot'); return f ? f.getBoundingClientRect().width + parseFloat(getComputedStyle(track).columnGap || 0) : 600; };
    var shots = track.querySelectorAll('.shot');
    var maxLeft = function () { return Math.max(0, track.scrollWidth - track.clientWidth); };
    var slideLeft = function (i) { return Math.min(Math.max(0, Math.min(i, shots.length - 1)) * step(), maxLeft()); };
    var nearest = function (x) { return Math.max(0, Math.min(shots.length - 1, Math.round(x / step()))); };
    // One eased glide to a picture. Mouse and trackpad scrolling settle through this instead of the browser's
    // hard CSS snap, which jumps as soon as the wheel stops; touch screens keep the native snap (it is smooth there).
    var fine = window.matchMedia('(hover: hover) and (pointer: fine)');
    var anim = 0, animTarget = null;
    var stop = function () { if (anim) cancelAnimationFrame(anim); anim = 0; animTarget = null; };
    var glide = function (x) {
      stop();
      x = Math.min(Math.max(0, x), maxLeft());
      var from = track.scrollLeft, d = x - from;
      if (Math.abs(d) < 1) return;
      if (reduced) { track.scrollLeft = x; return; }
      var t0 = performance.now(), dur = Math.min(900, Math.max(450, Math.abs(d) * 0.55));
      animTarget = x;
      var tick = function (now) {
        var p = Math.min(1, (now - t0) / dur);
        track.scrollLeft = from + d * (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);   // ease in-out cubic
        if (p < 1) anim = requestAnimationFrame(tick); else { anim = 0; animTarget = null; }
      };
      anim = requestAnimationFrame(tick);
    };
    var go = function (dir) {
      var base = animTarget !== null ? animTarget : track.scrollLeft;
      glide(slideLeft(nearest(base) + dir));
    };
    var settleTimer = 0, pointerDown = false;
    var settleSoon = function () {
      clearTimeout(settleTimer);
      if (!fine.matches || anim || pointerDown) return;
      settleTimer = setTimeout(function () { if (!pointerDown) glide(slideLeft(nearest(track.scrollLeft))); }, 120);
    };
    track.addEventListener('wheel', stop, { passive: true });          // the user took over: let go
    track.addEventListener('scroll', settleSoon, { passive: true });
    var sync = function () {
      var max = track.scrollWidth - track.clientWidth - 2;
      if (prevBtn) prevBtn.disabled = track.scrollLeft <= 2;
      if (nextBtn) nextBtn.disabled = track.scrollLeft >= max;
    };
    if (prevBtn) prevBtn.addEventListener('click', function () { go(-1); });
    if (nextBtn) nextBtn.addEventListener('click', function () { go(1); });
    track.addEventListener('scroll', sync, { passive: true });
    window.addEventListener('resize', sync);
    track.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowRight') { e.preventDefault(); go(1); } else if (e.key === 'ArrowLeft') { e.preventDefault(); go(-1); }
    });
    var down = false, startX = 0, startLeft = 0, moved = false;
    track.addEventListener('pointerdown', function (e) {
      if (e.pointerType !== 'mouse' || e.button !== 0) return;
      stop(); clearTimeout(settleTimer); pointerDown = true;
      down = true; moved = false; startX = e.clientX; startLeft = track.scrollLeft;
    });
    window.addEventListener('pointermove', function (e) {
      if (!down) return;
      var dx = e.clientX - startX;
      if (!moved && Math.abs(dx) > 4) { moved = true; track.classList.add('dragging'); }
      if (moved) track.scrollLeft = startLeft - dx;
    });
    window.addEventListener('pointerup', function () {
      if (!down) return;
      down = false; pointerDown = false;
      if (moved) {                       // settle on the nearest picture
        track.classList.remove('dragging');
        glide(slideLeft(nearest(track.scrollLeft)));
      }
    });
    sync();
  }
})();
