/* ============================================================
   SwitchBar — site motion
   Restrained: fades and rises on scroll, the usage bars filling,
   and the automatic-switch sequence. Nothing else moves.
   The page stays fully readable if GSAP never loads.
   ============================================================ */
(function () {
  'use strict';

  var root = document.documentElement;

  /* ── copy buttons work with or without GSAP ───────────────── */
  document.querySelectorAll('[data-copy]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var text = btn.getAttribute('data-copy') || '';

      function done() {
        btn.classList.add('is-done');
        btn.textContent = 'Copied';
        setTimeout(function () {
          btn.classList.remove('is-done');
          btn.textContent = 'Copy';
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

  var EASE = 'power2.out';
  var CAPTION_AFTER = 'alex@example.com crossed 97% of its 5-hour window, so SwitchBar made sam@example.com the active account.';

  function rows(scope) {
    return Array.prototype.map.call(scope.querySelectorAll('.row'), function (row) {
      return {
        el: row.querySelector('.row__fill'),
        value: (parseFloat(row.getAttribute('data-fill')) || 0) / 100
      };
    });
  }

  gsap.matchMedia().add({
    // `always` guarantees the callback runs: matchMedia only fires when at
    // least one condition matches, and `reduce` can be false on its own.
    always: '(min-width: 0px)',
    reduce: '(prefers-reduced-motion: reduce)'
  }, function (context) {
    var panel = document.getElementById('app-panel');

    /* ── reduced motion: finished state, nothing animates ───── */
    if (context.conditions.reduce) {
      gsap.set('[data-reveal], [data-reveal-group] > *', { opacity: 1 });
      if (panel) rows(panel).forEach(function (r) { gsap.set(r.el, { '--p': r.value }); });
      root.classList.remove('js');
      return;
    }

    /* ── nav gets a surface once the page moves ─────────────── */
    ScrollTrigger.create({
      start: 'top -24',
      end: 99999,
      onToggle: function (self) {
        document.getElementById('nav').classList.toggle('is-scrolled', self.isActive);
      }
    });

    /* ── hero: one short sequence on load ───────────────────── */
    gsap.fromTo('.hero [data-reveal]',
      { y: 24, opacity: 0 },
      { y: 0, opacity: 1, duration: 0.8, ease: EASE, stagger: 0.07, delay: 0.05 });

    /* ── everything else rises into place on scroll ─────────── */
    gsap.utils.toArray('[data-reveal]').forEach(function (el) {
      if (el.closest('.hero')) return;
      gsap.fromTo(el, { y: 24, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.7, ease: EASE,
        scrollTrigger: { trigger: el, start: 'top 88%' }
      });
    });

    gsap.utils.toArray('[data-reveal-group]').forEach(function (group) {
      gsap.fromTo(group.children, { y: 24, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.7, ease: EASE, stagger: 0.06,
        scrollTrigger: { trigger: group, start: 'top 85%' }
      });
    });

    /* ── the panel: bars fill, then the switch happens ──────── */
    if (panel) {
      var bars = rows(panel);
      var alexFill = document.querySelector('#row-alex .row__fill');
      var alexPct = document.querySelector('#row-alex .row__pct');
      var caption = document.getElementById('caption');
      var counter = { v: 55 };
      var red = getComputedStyle(root).getPropertyValue('--red').trim() || '#ff6061';

      var tl = gsap.timeline({
        scrollTrigger: { trigger: panel, start: 'top 78%', once: true },
        defaults: { ease: EASE }
      });

      tl.fromTo(bars.map(function (b) { return b.el; }), { '--p': 0 }, {
        '--p': function (i) { return bars[i].value; },
        duration: 0.7, stagger: 0.05
      });

      // the active account fills up past the threshold
      tl.to(alexFill, { '--p': 0.97, duration: 1.1, ease: 'power1.inOut' }, '+=1.1');
      tl.to(counter, {
        v: 97, duration: 1.1, ease: 'power1.inOut', lazy: false, // the callback writes to the DOM
        onUpdate: function () { if (alexPct) alexPct.textContent = Math.round(counter.v) + '%'; }
      }, '<');
      tl.to(alexFill, { backgroundColor: red, duration: 0.4 }, '<0.6');

      // and the badge moves to the next one
      tl.to('#badge-alex', { opacity: 0, duration: 0.25 }, '+=0.15');
      tl.to('#acct-alex', { backgroundColor: getComputedStyle(root).getPropertyValue('--s2').trim() || '#17171a', duration: 0.4 }, '<');
      tl.to('#dot-alex', { backgroundColor: '#4a4a52', duration: 0.4 }, '<');
      tl.to('#acct-sam', { backgroundColor: getComputedStyle(root).getPropertyValue('--s3').trim() || '#1c1c1f', duration: 0.4 }, '<0.1');
      tl.to('#dot-sam', { backgroundColor: getComputedStyle(root).getPropertyValue('--green').trim() || '#30d158', duration: 0.4 }, '<');
      tl.to('#badge-sam', { opacity: 1, duration: 0.35 }, '<0.05');

      if (caption) {
        tl.to(caption, {
          opacity: 0, duration: 0.25,
          onComplete: function () { caption.textContent = CAPTION_AFTER; }
        }, '<');
        tl.to(caption, { opacity: 1, duration: 0.35 });
      }
    }

    /* GSAP owns the opening state through inline styles now, so the CSS
       safety net can go: a failure above leaves content visible, not hidden. */
    requestAnimationFrame(function () { root.classList.remove('js'); });
  });

  window.addEventListener('load', function () { ScrollTrigger.refresh(); });
})();
