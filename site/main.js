/* ============================================================
   SwitchBar — language, theme and motion
   Everything degrades: without GSAP the page is a plain readable
   document, and with reduced motion it renders its final state.
   ============================================================ */
(function () {
  'use strict';

  var root = document.documentElement;
  var STRINGS = window.SB_I18N || {};
  var LANGS = ['en', 'es', 'fr', 'de', 'pt-BR', 'it', 'ja', 'ko', 'zh-Hans', 'zh-Hant'];

  var state = { lang: 'en', switched: false };

  /* ══════════════ language ═══════════════════════════════════ */

  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) { /* private mode */ }
  }
  function stored(key) {
    try { return localStorage.getItem(key); } catch (e) { return null; }
  }

  /* Maps whatever the browser reports onto one of the ten bundles. */
  function resolveLang(tag) {
    if (!tag) return null;
    if (LANGS.indexOf(tag) !== -1) return tag;
    var lower = tag.toLowerCase();
    if (lower.indexOf('zh') === 0) {
      return /hant|tw|hk|mo/.test(lower) ? 'zh-Hant' : 'zh-Hans';
    }
    if (lower.indexOf('pt') === 0) return 'pt-BR';
    var base = lower.split('-')[0];
    for (var i = 0; i < LANGS.length; i++) {
      if (LANGS[i].toLowerCase().split('-')[0] === base) return LANGS[i];
    }
    return null;
  }

  function detectLang() {
    var saved = resolveLang(stored('switchbar-lang'));
    if (saved) return saved;
    var list = navigator.languages || [navigator.language];
    for (var i = 0; i < list.length; i++) {
      var hit = resolveLang(list[i]);
      if (hit) return hit;
    }
    return 'en';
  }

  function t(key) {
    var bundle = STRINGS[state.lang] || STRINGS.en || {};
    return bundle[key] !== undefined ? bundle[key] : (STRINGS.en ? STRINGS.en[key] : '');
  }

  function applyLang(lang) {
    state.lang = STRINGS[lang] ? lang : 'en';
    root.setAttribute('lang', state.lang);

    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      var value = t(el.getAttribute('data-i18n'));
      if (value) el.textContent = value;
    });
    document.querySelectorAll('[data-i18n-aria]').forEach(function (el) {
      var value = t(el.getAttribute('data-i18n-aria'));
      if (value) el.setAttribute('aria-label', value);
    });

    // the caption has two states and the sequence may already have run
    var caption = document.getElementById('caption');
    if (caption && state.switched) caption.textContent = t('panel.caption_after');

    document.title = t('meta.title') || document.title;
    var desc = document.querySelector('meta[name="description"]');
    if (desc && t('meta.desc')) desc.setAttribute('content', t('meta.desc'));

    var select = document.getElementById('lang');
    if (select) select.value = state.lang;

    syncThemeLabel();
  }

  /* ══════════════ theme ══════════════════════════════════════ */

  function currentTheme() {
    return root.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
  }

  function syncThemeLabel() {
    var btn = document.getElementById('theme');
    if (!btn) return;
    var label = currentTheme() === 'dark' ? t('ui.to_light') : t('ui.to_dark');
    if (label) btn.setAttribute('aria-label', label);
  }

  function applyTheme(theme) {
    root.setAttribute('data-theme', theme);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', theme === 'light' ? '#ffffff' : '#0a0a0b');
    syncThemeLabel();
  }

  var themeBtn = document.getElementById('theme');
  if (themeBtn) {
    themeBtn.addEventListener('click', function () {
      var next = currentTheme() === 'dark' ? 'light' : 'dark';
      applyTheme(next);
      store('switchbar-theme', next);
    });
  }

  // system changes still win while the visitor has not chosen one
  var systemLight = window.matchMedia('(prefers-color-scheme: light)');
  var onSystemTheme = function (e) {
    if (!stored('switchbar-theme')) applyTheme(e.matches ? 'light' : 'dark');
  };
  if (systemLight.addEventListener) systemLight.addEventListener('change', onSystemTheme);
  else if (systemLight.addListener) systemLight.addListener(onSystemTheme);

  /* ══════════════ copy buttons (work without GSAP) ═══════════ */

  document.querySelectorAll('[data-copy]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var text = btn.getAttribute('data-copy') || '';

      function done() {
        btn.classList.add('is-done');
        btn.textContent = t('ui.copied') || 'Copied';
        setTimeout(function () {
          btn.classList.remove('is-done');
          btn.textContent = t('ui.copy') || 'Copy';
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
        try { document.execCommand('copy'); done(); } catch (e) { /* unavailable */ }
        document.body.removeChild(ta);
      }

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else {
        fallback();
      }
    });
  });

  /* ══════════════ boot ═══════════════════════════════════════ */

  applyLang(detectLang());
  requestAnimationFrame(function () { root.classList.add('theme-ready'); });

  var select = document.getElementById('lang');
  if (select) {
    select.addEventListener('change', function () {
      applyLang(select.value);
      store('switchbar-lang', select.value);
      if (window.SB_RELAYOUT) window.SB_RELAYOUT();
    });
  }

  if (typeof gsap === 'undefined' || typeof ScrollTrigger === 'undefined') {
    root.classList.remove('js'); // no motion library, nothing hidden
    return;
  }

  gsap.registerPlugin(ScrollTrigger);

  /* ══════════════ motion ═════════════════════════════════════ */

  /* Wraps every visual line of a headline in its own overflow mask so
     the line can slide up from below its own box. */
  function splitLines(el) {
    var text = el.getAttribute('data-plain') || el.textContent;
    el.setAttribute('data-plain', text);
    el.textContent = '';

    var words = text.split(/\s+/).filter(Boolean);
    var probes = words.map(function (word, i) {
      var span = document.createElement('span');
      span.style.display = 'inline-block';
      span.textContent = word;
      el.appendChild(span);
      if (i < words.length - 1) el.appendChild(document.createTextNode(' '));
      return span;
    });

    var lines = [];
    var top = null;
    probes.forEach(function (probe) {
      if (top === null || Math.abs(probe.offsetTop - top) > 4) {
        top = probe.offsetTop;
        lines.push([]);
      }
      lines[lines.length - 1].push(probe);
    });

    el.textContent = '';
    return lines.map(function (line, index) {
      var mask = document.createElement('span');
      mask.className = 'split-line';
      var inner = document.createElement('span');
      line.forEach(function (probe, i) {
        inner.appendChild(probe);
        if (i < line.length - 1) inner.appendChild(document.createTextNode(' '));
      });
      // keeps the words separated for screen readers and for copied text,
      // where the line boxes themselves are invisible
      if (index < lines.length - 1) inner.appendChild(document.createTextNode(' '));
      mask.appendChild(inner);
      el.appendChild(mask);
      return inner;
    });
  }

  function rowsIn(scope) {
    return Array.prototype.map.call(scope.querySelectorAll('.row'), function (row) {
      return {
        el: row.querySelector('.row__fill'),
        value: (parseFloat(row.getAttribute('data-fill')) || 0) / 100
      };
    });
  }

  var css = getComputedStyle(root);
  var RED = css.getPropertyValue('--p-red').trim() || '#ff6061';
  var GREEN = css.getPropertyValue('--p-green').trim() || '#30d158';
  var CARD = css.getPropertyValue('--p-card').trim() || '#17171a';
  var CARD_ON = css.getPropertyValue('--p-card-on').trim() || '#1c1c1f';
  var DOT = css.getPropertyValue('--p-dot').trim() || '#4a4a52';

  gsap.matchMedia().add({
    // `always` guarantees the callback runs: matchMedia only fires when
    // at least one condition matches, and the others can all be false.
    always: '(min-width: 0px)',
    reduce: '(prefers-reduced-motion: reduce)',
    // pinning needs both room to breathe and a real pointer surface
    pinnable: '(min-width: 900px) and (min-height: 760px)'
  }, function (context) {
    var cond = context.conditions;
    var panel = document.getElementById('app-panel');

    /* ── reduced motion: final state, nothing animates ──────── */
    if (cond.reduce) {
      gsap.set('[data-reveal], .card, .spec, .hero__icon', { opacity: 1 });
      gsap.set('.card__rule', { scaleX: 1 });
      if (panel) rowsIn(panel).forEach(function (r) { gsap.set(r.el, { '--p': r.value }); });
      root.classList.remove('js');
      return;
    }

    /* ── headlines split into masked lines ──────────────────── */
    var splits = [];
    document.querySelectorAll('[data-split]').forEach(function (el) {
      splits.push({ el: el, lines: splitLines(el) });
    });
    splits.forEach(function (s) { gsap.set(s.lines, { yPercent: 110 }); });

    /* ── hero ───────────────────────────────────────────────── */
    var hero = gsap.timeline({ delay: 0.08 });

    hero.fromTo('.hero__icon',
      { opacity: 0, scale: 0.92 },
      { opacity: 1, scale: 1, duration: 0.9, ease: 'power3.out' }, 0);

    if (splits[0]) {
      hero.to(splits[0].lines, {
        yPercent: 0, duration: 1, ease: 'power4.out', stagger: 0.08
      }, 0.15);
    }

    hero.fromTo('.hero__sub, .hero__cta, .hero__note',
      { y: 20, opacity: 0 },
      { y: 0, opacity: 1, duration: 0.75, ease: 'power2.out', stagger: 0.07 }, 0.5);

    /* ── nav surface fades in with scroll instead of snapping ─ */
    gsap.fromTo('#nav-bg', { opacity: 0 }, {
      opacity: 1, ease: 'none',
      scrollTrigger: { start: 'top top', end: '+=140', scrub: 0.4 }
    });

    /* ── generic reveals ────────────────────────────────────── */
    gsap.utils.toArray('[data-reveal]').forEach(function (el) {
      if (el.closest('.hero')) return;
      gsap.fromTo(el, { y: 24, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.7, ease: 'power2.out',
        scrollTrigger: { trigger: el, start: 'top 88%' }
      });
    });

    /* headlines below the fold slide up as they arrive */
    splits.slice(1).forEach(function (s) {
      gsap.to(s.lines, {
        yPercent: 0, duration: 0.9, ease: 'power4.out', stagger: 0.08,
        scrollTrigger: { trigger: s.el, start: 'top 88%' }
      });
    });

    /* ── cards: rise, with a hairline drawn across the top ──── */
    gsap.utils.toArray('.cards .card').forEach(function (card, i) {
      var tl = gsap.timeline({ scrollTrigger: { trigger: '.cards', start: 'top 82%' } });
      tl.fromTo(card, { y: 28, opacity: 0 },
        { y: 0, opacity: 1, duration: 0.7, ease: 'power2.out' }, i * 0.08);
      tl.fromTo(card.querySelector('.card__rule'), { scaleX: 0 },
        { scaleX: 1, duration: 0.8, ease: 'power2.inOut' }, i * 0.08 + 0.15);
    });

    gsap.fromTo('.specs .spec', { y: 20, opacity: 0 }, {
      y: 0, opacity: 1, duration: 0.6, ease: 'power2.out', stagger: 0.06,
      scrollTrigger: { trigger: '.specs', start: 'top 85%' }
    });

    /* ── the panel sequence ─────────────────────────────────── */
    if (panel) {
      var bars = rowsIn(panel);
      var alexFill = document.querySelector('#row-alex .row__fill');
      var alexPct = document.querySelector('#row-alex .row__pct');
      var caption = document.getElementById('caption');
      var counter = { v: 55 };

      function setCaptionAfter() {
        state.switched = true;
        if (caption) caption.textContent = t('panel.caption_after');
      }
      function setCaptionBefore() {
        state.switched = false;
        if (caption) caption.textContent = t('panel.caption');
      }

      var trigger = cond.pinnable
        ? { trigger: '#panel-pin', start: 'top top', end: '+=1900',
            pin: true, anticipatePin: 1, scrub: 0.7, invalidateOnRefresh: true }
        : { trigger: panel, start: 'top 78%', once: true };

      var tl = gsap.timeline({ scrollTrigger: trigger, defaults: { ease: 'power2.out' } });

      // (a) the bars grow
      tl.fromTo(bars.map(function (b) { return b.el; }), { '--p': 0 }, {
        '--p': function (i) { return bars[i].value; },
        duration: 0.8, stagger: 0.05
      });

      // (b) the active window fills past the threshold, counting up
      tl.to(alexFill, { '--p': 0.97, duration: 1.2, ease: 'power1.inOut' }, '+=0.5');
      tl.to(counter, {
        v: 97, duration: 1.2, ease: 'power1.inOut', lazy: false, // writes to the DOM
        onUpdate: function () { if (alexPct) alexPct.textContent = Math.round(counter.v) + '%'; }
      }, '<');
      tl.to(alexFill, { backgroundColor: RED, duration: 0.45 }, '<0.65');

      // (c) the badge moves to the next account
      tl.to('#badge-alex', { opacity: 0, duration: 0.25 }, '+=0.2');
      tl.to('#acct-alex', { backgroundColor: CARD, duration: 0.4 }, '<');
      tl.to('#dot-alex', { backgroundColor: DOT, duration: 0.4 }, '<');
      tl.to('#acct-sam', { backgroundColor: CARD_ON, duration: 0.4 }, '<0.1');
      tl.to('#dot-sam', { backgroundColor: GREEN, duration: 0.4 }, '<');
      tl.to('#badge-sam', { opacity: 1, duration: 0.35 }, '<0.05');

      // (d) the caption explains what just happened, both ways
      if (caption) {
        tl.to(caption, {
          opacity: 0, duration: 0.2,
          onComplete: setCaptionAfter, onReverseComplete: setCaptionBefore
        }, '<0.1');
        tl.to(caption, { opacity: 1, duration: 0.35 });
      }
      tl.to({}, { duration: 0.4 });

      /* A very small parallax — never more than 20px — and only when
         the section is not pinned, where it would fight the pin. */
      if (!cond.pinnable) {
        gsap.fromTo(panel, { y: 20 }, {
          y: -20, ease: 'none',
          scrollTrigger: { trigger: '.panel-sec', start: 'top bottom', end: 'bottom top', scrub: 0.6 }
        });
      }
    }

    /* Re-measure line breaks after a language change or a real resize:
       the same words wrap differently in German and in Japanese. */
    function relayout() {
      if (hero.progress() < 1) hero.progress(1);
      // Refrescar estando dentro del tramo anclado deja el panel fijo
      // sobre el resto de la página: el pin se mide a medio camino. Se
      // sale del tramo, se vuelve a medir y se recupera la posición, que
      // ya entra en el pin por la vía normal del scroll.
      var y = window.scrollY;
      window.scrollTo(0, 0);
      splits.forEach(function (s) {
        s.el.removeAttribute('data-plain');   // textContent is the new language
        s.lines = splitLines(s.el);
        gsap.set(s.lines, { yPercent: 0 });
      });
      ScrollTrigger.refresh();
      var max = document.documentElement.scrollHeight - window.innerHeight;
      window.scrollTo(0, Math.max(0, Math.min(y, max)));
    }
    window.SB_RELAYOUT = relayout;

    var lastWidth = window.innerWidth;
    var resizeId;
    function onResize() {
      if (Math.abs(window.innerWidth - lastWidth) < 60) return;
      lastWidth = window.innerWidth;
      clearTimeout(resizeId);
      resizeId = setTimeout(relayout, 200);
    }
    window.addEventListener('resize', onResize);

    /* GSAP owns the opening state through inline styles now, so the CSS
       safety net can go: a failure above leaves content visible. */
    requestAnimationFrame(function () { root.classList.remove('js'); });

    return function () {
      window.removeEventListener('resize', onResize);
      clearTimeout(resizeId);
      window.SB_RELAYOUT = null;
    };
  });

  window.addEventListener('load', function () { ScrollTrigger.refresh(); });
})();
