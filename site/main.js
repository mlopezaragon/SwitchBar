/* ============================================================
   SwitchBar — site motion
   GSAP + ScrollTrigger. The page stays readable and fully
   visible if GSAP never loads or if motion is reduced.
   ============================================================ */
(function () {
  'use strict';

  var root = document.documentElement;

  /* ── copy buttons: independent of GSAP ────────────────────── */
  document.querySelectorAll('.copy').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var text = btn.getAttribute('data-copy') || '';
      var label = btn.querySelector('.copy__label');

      function done() {
        btn.classList.add('is-done');
        if (label) label.textContent = 'Copied';
        setTimeout(function () {
          btn.classList.remove('is-done');
          if (label) label.textContent = 'Copy';
        }, 1800);
      }

      function fallback() {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); done(); } catch (e) { /* clipboard unavailable */ }
        document.body.removeChild(ta);
      }

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else {
        fallback();
      }
    });
  });

  if (typeof gsap === 'undefined' || typeof ScrollTrigger === 'undefined') {
    root.classList.remove('js'); // no motion library, no hidden content
    return;
  }

  gsap.registerPlugin(ScrollTrigger);

  var EASE = 'power3.out';
  var LIT_BG = 'rgba(255,255,255,0.035)';
  var LIT_BORDER = 'rgba(244,242,239,0.10)';

  /* ── word collection that remembers emphasis ──────────────── */
  function collect(node, accent, out) {
    Array.prototype.forEach.call(node.childNodes, function (child) {
      if (child.nodeType === 3) {
        child.textContent.split(/\s+/).forEach(function (chunk) {
          if (chunk) out.push({ text: chunk, accent: accent });
        });
      } else if (child.nodeType === 1) {
        var isAccent = accent ||
          child.tagName === 'EM' ||
          child.classList.contains('statement__accent');
        collect(child, isAccent, out);
      }
    });
  }

  function wordSpans(el, accentTag) {
    var words = [];
    collect(el, false, words);
    el.textContent = '';
    return words.map(function (w, i) {
      var span = document.createElement('span');
      span.style.display = 'inline-block';
      if (w.accent && accentTag === 'em') {
        var em = document.createElement('em');
        em.textContent = w.text;
        span.appendChild(em);
      } else {
        span.textContent = w.text;
        if (w.accent) span.className = 'statement__accent';
      }
      el.appendChild(span);
      if (i < words.length - 1) el.appendChild(document.createTextNode(' '));
      return span;
    });
  }

  /* Wraps each visual line in a mask so it can slide up from below. */
  function splitLines(el) {
    if (!el.dataset.original) el.dataset.original = el.innerHTML;
    el.innerHTML = el.dataset.original; // only ever this element's own markup

    var nodes = wordSpans(el, 'em');

    var lines = [];
    var currentTop = null;
    nodes.forEach(function (n) {
      var top = n.offsetTop;
      if (currentTop === null || Math.abs(top - currentTop) > 4) {
        currentTop = top;
        lines.push([]);
      }
      lines[lines.length - 1].push(n);
    });

    el.textContent = '';
    return lines.map(function (line) {
      var mask = document.createElement('span');
      mask.className = 'split-line';
      var inner = document.createElement('span');
      line.forEach(function (n, i) {
        inner.appendChild(n);
        if (i < line.length - 1) inner.appendChild(document.createTextNode(' '));
      });
      mask.appendChild(inner);
      el.appendChild(mask);
      return inner;
    });
  }

  /* ── usage bars ───────────────────────────────────────────── */
  function fillsIn(scope) {
    return Array.prototype.map.call(scope.querySelectorAll('.ubar'), function (bar) {
      return {
        el: bar.querySelector('.fill'),
        value: (parseFloat(bar.getAttribute('data-fill')) || 0) / 100
      };
    });
  }

  function targets(bars) {
    return bars.map(function (b) { return b.el; });
  }

  var css = getComputedStyle(root);
  var GREEN = css.getPropertyValue('--green').trim() || '#30d158';
  var RED = css.getPropertyValue('--red').trim() || '#ff453a';

  function start() {
    gsap.matchMedia().add({
      // `always` guarantees the callback runs: matchMedia only fires when at
      // least one condition matches, and the other two can both be false.
      always: '(min-width: 0px)',
      reduce: '(prefers-reduced-motion: reduce)',
      desktop: '(min-width: 961px)'
    }, function (context) {
      var cond = context.conditions;

      /* ── reduced motion: show the finished state, animate nothing ── */
      if (cond.reduce) {
        gsap.set('[data-anim="fade"], [data-anim="stagger"] > *, [data-anim="panel"]', { opacity: 1 });
        document.querySelectorAll('.panel').forEach(function (panel) {
          fillsIn(panel).forEach(function (b) { gsap.set(b.el, { '--p': b.value }); });
        });
        document.querySelectorAll('.step').forEach(function (s) { s.classList.add('is-on'); });
        root.classList.remove('js');
        return;
      }

      /* ── sticky nav ───────────────────────────────────────── */
      ScrollTrigger.create({
        start: 'top -60',
        end: 99999,
        onToggle: function (self) {
          document.getElementById('nav').classList.toggle('is-stuck', self.isActive);
        }
      });

      /* ── headline line splits ─────────────────────────────── */
      var splits = [];
      document.querySelectorAll('[data-split="lines"]').forEach(function (el) {
        splits.push({ el: el, lines: splitLines(el) });
      });
      splits.forEach(function (s) { gsap.set(s.lines, { yPercent: 108, opacity: 0 }); });

      /* ── hero ─────────────────────────────────────────────── */
      var hero = gsap.timeline({ delay: 0.12, defaults: { ease: EASE } });

      if (splits[0]) {
        hero.to(splits[0].lines, { yPercent: 0, opacity: 1, duration: 1.1, stagger: 0.09 }, 0);
      }

      hero.fromTo('.hero .eyebrow, .hero .lede, .hero .install-line, .hero__actions, .hero__req',
        { y: 22, opacity: 0 },
        { y: 0, opacity: 1, duration: 0.9, stagger: 0.075 }, 0.35);

      hero.fromTo('.scrollcue', { opacity: 0 }, { opacity: 1, duration: 0.8 }, 1.2);

      var heroPanel = document.querySelector('[data-anim="panel"]');
      if (heroPanel) {
        hero.fromTo(heroPanel,
          { opacity: 0, y: 46, rotateX: 8, rotateY: -6, scale: 0.97 },
          { opacity: 1, y: 0, rotateX: 0, rotateY: 0, scale: 1, duration: 1.5 }, 0.25);

        var heroBars = fillsIn(heroPanel);
        hero.fromTo(targets(heroBars), { '--p': 0 }, {
          '--p': function (i) { return heroBars[i].value; },
          duration: 1.1, ease: 'power2.out', stagger: 0.05
        }, 0.75);
      }

      /* ── generic reveals ──────────────────────────────────── */
      gsap.utils.toArray('[data-anim="fade"]').forEach(function (el) {
        if (el.closest('.hero')) return;
        gsap.fromTo(el, { y: 26, opacity: 0 }, {
          y: 0, opacity: 1, duration: 0.9, ease: EASE,
          scrollTrigger: { trigger: el, start: 'top 88%' }
        });
      });

      gsap.utils.toArray('[data-anim="stagger"]').forEach(function (group) {
        gsap.fromTo(group.children, { y: 30, opacity: 0 }, {
          y: 0, opacity: 1, duration: 0.85, ease: EASE, stagger: 0.075,
          scrollTrigger: { trigger: group, start: 'top 85%' }
        });
      });

      splits.slice(1).forEach(function (s) {
        gsap.to(s.lines, {
          yPercent: 0, opacity: 1, duration: 1.05, ease: EASE, stagger: 0.09,
          scrollTrigger: { trigger: s.el, start: 'top 85%' }
        });
      });

      /* ── statement, word by word, tied to scroll ──────────── */
      document.querySelectorAll('[data-split="words"]').forEach(function (el) {
        if (!el.dataset.original) el.dataset.original = el.innerHTML;
        el.innerHTML = el.dataset.original;
        var spans = wordSpans(el, 'span');
        gsap.fromTo(spans, { opacity: 0.14, y: 6 }, {
          opacity: 1, y: 0, duration: 0.5, ease: 'none', stagger: 0.03,
          scrollTrigger: { trigger: el, start: 'top 82%', end: 'bottom 62%', scrub: 0.6 }
        });
      });

      /* ── ticker ───────────────────────────────────────────── */
      var ticker = document.getElementById('ticker');
      if (ticker) gsap.to(ticker, { xPercent: -50, duration: 26, ease: 'none', repeat: -1 });

      /* ── privacy diagram ──────────────────────────────────── */
      document.querySelectorAll('.net__path').forEach(function (path, i) {
        var len = path.getTotalLength();
        gsap.set(path, { strokeDasharray: len, strokeDashoffset: len });
        gsap.to(path, {
          strokeDashoffset: 0, duration: 1.1, ease: 'power2.inOut', delay: i * 0.12,
          scrollTrigger: { trigger: '.net', start: 'top 78%' }
        });
      });

      /* ── the auto-switch sequence ─────────────────────────── */
      var demo = document.getElementById('panel-demo');
      if (demo) {
        var demoBars = fillsIn(demo);
        var alexBar = demo.querySelector('#bar-alex .fill');
        var alexPct = demo.querySelector('#bar-alex .ubar__pct');
        var steps = gsap.utils.toArray('.step');
        steps.forEach(function (s) { s.classList.remove('is-on'); });
        gsap.set(steps, { opacity: 0.45 });

        var counter = { v: 55 };

        var tl = gsap.timeline({
          defaults: { ease: 'none' },
          scrollTrigger: cond.desktop
            ? { trigger: '#auto-pin', start: 'top top', end: '+=2400', scrub: 0.8, pin: true, anticipatePin: 1, invalidateOnRefresh: true }
            : { trigger: '#auto-pin', start: 'top 72%', end: 'bottom 45%', scrub: 0.8, invalidateOnRefresh: true }
        });

        // 01 — the panel populates
        tl.fromTo(targets(demoBars), { '--p': 0 }, {
          '--p': function (i) { return demoBars[i].value; },
          duration: 0.6, ease: 'power2.out', stagger: 0.04
        }, 0);
        tl.to(steps[0], { opacity: 1, backgroundColor: LIT_BG, borderColor: LIT_BORDER, duration: 0.2 }, 0.1);

        // 02 — alex climbs past the threshold
        tl.to(steps[0], { opacity: 0.45, backgroundColor: 'rgba(255,255,255,0)', borderColor: 'rgba(255,255,255,0)', duration: 0.2 }, 1.0);
        tl.to(steps[1], { opacity: 1, backgroundColor: LIT_BG, borderColor: LIT_BORDER, duration: 0.2 }, 1.05);
        tl.to(alexBar, { '--p': 0.97, duration: 1.0, ease: 'power1.in' }, 1.0);
        tl.to(counter, {
          v: 97, duration: 1.0, ease: 'power1.in', lazy: false, // the callback writes to the DOM
          onUpdate: function () { if (alexPct) alexPct.textContent = Math.round(counter.v) + ' %'; }
        }, 1.0);
        tl.to(alexBar, { backgroundColor: RED, duration: 0.35 }, 1.55);

        // 03 — the active badge jumps to sam
        tl.to(steps[1], { opacity: 0.45, backgroundColor: 'rgba(255,255,255,0)', borderColor: 'rgba(255,255,255,0)', duration: 0.2 }, 2.25);
        tl.to(steps[2], { opacity: 1, backgroundColor: LIT_BG, borderColor: LIT_BORDER, duration: 0.2 }, 2.3);
        tl.to('#badge-alex', { opacity: 0, scale: 0.7, duration: 0.3, ease: 'power2.in' }, 2.3);
        tl.to('#card-alex', { backgroundColor: 'rgba(255,255,255,0.045)', borderColor: 'rgba(255,255,255,0.06)', duration: 0.4 }, 2.3);
        tl.to('#dot-alex', { backgroundColor: 'rgba(244,242,239,0.35)', boxShadow: '0 0 0 3px rgba(48,209,88,0)', duration: 0.4 }, 2.3);
        tl.to('#card-sam', { backgroundColor: 'rgba(48,209,88,0.06)', borderColor: 'rgba(48,209,88,0.35)', duration: 0.4 }, 2.5);
        tl.to('#dot-sam', { backgroundColor: GREEN, boxShadow: '0 0 0 3px rgba(48,209,88,0.14)', duration: 0.4 }, 2.5);
        tl.fromTo('#badge-sam', { opacity: 0, scale: 0.7 }, { opacity: 1, scale: 1, duration: 0.45, ease: 'back.out(2)' }, 2.55);
        tl.fromTo('#demo-toast', { opacity: 0, y: 8 }, { opacity: 1, y: 0, duration: 0.4, ease: EASE }, 2.75);
        tl.to({}, { duration: 0.7 });
      }

      /* ── other panels' bars ───────────────────────────────── */
      document.querySelectorAll('.panel').forEach(function (panel) {
        if (panel.closest('.hero__panel') || panel.id === 'panel-demo') return;
        var bars = fillsIn(panel);
        gsap.fromTo(targets(bars), { '--p': 0 }, {
          '--p': function (i) { return bars[i].value; },
          duration: 1, ease: 'power2.out', stagger: 0.05,
          scrollTrigger: { trigger: panel, start: 'top 80%' }
        });
      });

      /* ── magnetic buttons, fine pointers only ─────────────── */
      if (window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
        document.querySelectorAll('.btn, .copy').forEach(function (btn) {
          var qx = gsap.quickTo(btn, 'x', { duration: 0.45, ease: 'power3' });
          var qy = gsap.quickTo(btn, 'y', { duration: 0.45, ease: 'power3' });
          btn.addEventListener('mousemove', function (e) {
            var r = btn.getBoundingClientRect();
            qx((e.clientX - (r.left + r.width / 2)) * 0.2);
            qy((e.clientY - (r.top + r.height / 2)) * 0.28);
          });
          btn.addEventListener('mouseleave', function () { qx(0); qy(0); });
        });
      }

      /* ── re-measure line breaks after a real width change ─── */
      var lastWidth = window.innerWidth;
      var resizeId;
      function onResize() {
        if (Math.abs(window.innerWidth - lastWidth) < 60) return;
        lastWidth = window.innerWidth;
        clearTimeout(resizeId);
        resizeId = setTimeout(function () {
          splits.forEach(function (s) {
            s.lines = splitLines(s.el);
            gsap.set(s.lines, { yPercent: 0, opacity: 1 });
          });
          ScrollTrigger.refresh();
        }, 220);
      }
      window.addEventListener('resize', onResize);

      /* GSAP now owns the opening state of every animated element through
         inline styles, so the CSS safety net can go. If anything above had
         failed, the content would simply stay visible instead of hidden. */
      requestAnimationFrame(function () { root.classList.remove('js'); });

      return function () {
        window.removeEventListener('resize', onResize);
        clearTimeout(resizeId);
      };
    });

    ScrollTrigger.refresh();
  }

  /* Line breaks are measured after the webfonts land, otherwise the
     masks are cut for the fallback face. */
  if (document.fonts && document.fonts.ready) {
    var fired = false;
    var go = function () { if (!fired) { fired = true; start(); } };
    document.fonts.ready.then(go);
    setTimeout(go, 1500);
  } else {
    start();
  }
})();
