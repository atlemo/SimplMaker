// Docs search: filters /docs/search.json in the browser. No dependencies.
(function () {
  'use strict';
  var inputs = document.querySelectorAll('.docs-search input, .docs-home-search input');
  if (!inputs.length) return;
  var index = null, loading = null;
  function load() {
    if (index) return Promise.resolve(index);
    loading = loading || fetch('/docs/search.json').then(function (r) { return r.json(); }).then(function (d) { index = d; return d; });
    return loading;
  }
  function score(entry, words) {
    var total = 0;
    var title = entry.t.toLowerCase(), heads = entry.h.join(' ').toLowerCase(), text = entry.x.toLowerCase();
    for (var i = 0; i < words.length; i++) {
      var w = words[i], s = 0;
      if (title.indexOf(w) !== -1) s += 10;
      if (heads.indexOf(w) !== -1) s += 4;
      if (text.indexOf(w) !== -1) s += 1;
      if (!s) return 0;
      total += s;
    }
    return total;
  }
  function esc(s) { return s.replace(/[&<>"]/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]; }); }
  inputs.forEach(function (input) {
    var list = input.parentNode.querySelector('.docs-results');
    input.addEventListener('focus', load);
    input.addEventListener('input', function () {
      var q = input.value.trim().toLowerCase();
      if (!q) { list.hidden = true; list.innerHTML = ''; return; }
      load().then(function (data) {
        var words = q.split(/\s+/);
        var hits = data.map(function (e) { return { e: e, s: score(e, words) }; })
          .filter(function (h) { return h.s > 0; })
          .sort(function (a, b) { return b.s - a.s; }).slice(0, 8);
        list.innerHTML = hits.length
          ? hits.map(function (h) { return '<li><a href="' + h.e.u + '">' + esc(h.e.t) + '<small>' + esc(h.e.g) + '</small></a></li>'; }).join('')
          : '<li class="none">Nothing found. Try another word.</li>';
        list.hidden = false;
      });
    });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { input.value = ''; list.hidden = true; }
      if (e.key === 'Enter') { var a = list.querySelector('a'); if (a) location.href = a.href; }
    });
  });

  // Highlight the current section in "On this page".
  var toc = document.querySelectorAll('.docs-toc a');
  if (toc.length && 'IntersectionObserver' in window) {
    var map = {};
    toc.forEach(function (a) { map[a.getAttribute('href').slice(1)] = a; });
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { toc.forEach(function (a) { a.classList.remove('active'); }); var a = map[e.target.id]; if (a) a.classList.add('active'); }
      });
    }, { rootMargin: '-80px 0px -70% 0px' });
    Object.keys(map).forEach(function (id) { var el = document.getElementById(id); if (el) io.observe(el); });
  }
})();

// Zoom for the screenshots: a magnifier on hover and a lightbox. Click the picture or the magnifier to open it; click outside it,
// press Esc or use the X to close.
(function () {
  'use strict';
  var shots = document.querySelectorAll('.shot:not(.missing) img');
  if (!shots.length) return;
  var ICONS = {
    zoom: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21M10.5 7.5v6M7.5 10.5h6"/></svg>',
    close: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M5 5l14 14M19 5 5 19"/></svg>'
  };
  var box = null, img = null, caption = null, closeButton = null, opener = null;

  function build() {
    box = document.createElement('div');
    box.className = 'lightbox';
    box.hidden = true;
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-modal', 'true');
    box.setAttribute('aria-label', 'Screenshot');
    var figure = document.createElement('figure');
    figure.className = 'lightbox-figure';
    img = document.createElement('img');
    caption = document.createElement('figcaption');
    figure.appendChild(img);
    figure.appendChild(caption);
    closeButton = document.createElement('button');
    closeButton.type = 'button';
    closeButton.className = 'lightbox-close';
    closeButton.setAttribute('aria-label', 'Close');
    closeButton.innerHTML = ICONS.close;
    box.appendChild(figure);
    box.appendChild(closeButton);
    document.body.appendChild(box);
    closeButton.addEventListener('click', close);
    // A click on the dark area (not on the picture or its caption) closes it.
    box.addEventListener('click', function (e) { if (e.target === box || e.target === figure) close(); });
  }

  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); close(); }
    else if (e.key === 'Tab') { e.preventDefault(); closeButton.focus(); }  // the X is the only thing to reach
  }

  function open(source, trigger) {
    if (!box) build();
    img.src = source.currentSrc || source.src;
    img.alt = source.alt;
    var figcaption = source.closest('figure') && source.closest('figure').querySelector('figcaption');
    caption.textContent = figcaption ? figcaption.textContent : '';
    caption.hidden = !caption.textContent;
    opener = trigger;
    box.hidden = false;
    document.documentElement.classList.add('lightbox-open');
    document.addEventListener('keydown', onKey);
    closeButton.focus();
  }

  function close() {
    if (!box || box.hidden) return;
    box.hidden = true;
    img.removeAttribute('src');
    document.documentElement.classList.remove('lightbox-open');
    document.removeEventListener('keydown', onKey);
    if (opener && document.contains(opener)) opener.focus();
    opener = null;
  }

  shots.forEach(function (shot) {
    var frame = document.createElement('span');
    frame.className = 'shot-frame';
    frame.style.maxWidth = shot.style.maxWidth;  // the picture is shown at half its size; the frame follows
    shot.parentNode.insertBefore(frame, shot);
    frame.appendChild(shot);
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'shot-zoom';
    button.setAttribute('aria-label', 'Enlarge the screenshot');
    button.title = 'Enlarge';
    button.innerHTML = ICONS.zoom;
    frame.appendChild(button);
    button.addEventListener('click', function () { open(shot, button); });
    shot.addEventListener('click', function () { open(shot, button); });
  });
})();
