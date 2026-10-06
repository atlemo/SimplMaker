// Docs search: filters /docs/search.json in the browser. No dependencies.
(function () {
  'use strict';
  var inputs = document.querySelectorAll('#docs-q');
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
