(() => {
  'use strict';
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (id) => document.getElementById(id);

  /* ---------- live lyrics ---------- */
  // One clock drives every live surface: the hero desktop and the app windows on the chapter stages.
  // Elements opt in with data hooks: data-l="main" is the current line, lit word by word (data-scroll follows
  // the singing when it overflows, data-paint="0" is an outline copy); data-l="next" | "prog" | "cur" | "rem";
  // data-t="title" | "artist" | "album"; data-cover and data-blur take the demo track's artwork.
  const DEMO = JSON.parse($('demoData').textContent);
  const LINES = DEMO.lines;
  const CHAR_MS = 280, SPACE_MS = 240;

  const hexA = (hex, a) => {
    const n = parseInt(hex.slice(1), 16);
    return `rgba(${n >> 16 & 255}, ${n >> 8 & 255}, ${n & 255}, ${a})`;
  };
  const lives = [...document.querySelectorAll('.live')];
  // Colours come from the cover through the app's own pipeline (see demoData).
  lives.forEach((el) => {
    el.style.setProperty('--accent', DEMO.notchAccent);
    el.style.setProperty('--accent-dim', hexA(DEMO.notchAccent, 0.35));
    el.style.setProperty('--ov', DEMO.overlayText);
    el.style.setProperty('--ov-dim', hexA(DEMO.overlayText, 0.35));
  });
  document.querySelectorAll('[data-cover]').forEach((el) => { el.style.backgroundImage = `url("${DEMO.cover}")`; });
  document.querySelectorAll('[data-blur]').forEach((el) => {
    el.style.backgroundImage = el.dataset.blur === 'plain'
      ? `url("${DEMO.blur}")`
      : `linear-gradient(rgba(0,0,0,.45), rgba(0,0,0,.45)), url("${DEMO.blur}")`;
  });
  document.querySelectorAll('[data-t]').forEach((el) => { el.textContent = DEMO[el.dataset.t]; });

  // Only surfaces that are on screen, and on the selected tab of their stage, get painted.
  const onScreen = new Set();
  const liveIO = new IntersectionObserver((es) => es.forEach((e) => (e.isIntersecting ? onScreen.add(e.target) : onScreen.delete(e.target))));
  lives.forEach((el) => liveIO.observe(el));
  const surface = (el) => ({ el, root: el.closest('.live'), view: el.closest('.view') });
  const shown = (s) => onScreen.has(s.root) && (!s.view || s.view.classList.contains('on'));

  const mains = [...document.querySelectorAll('[data-l="main"]')]
    .map((el) => Object.assign(surface(el), { scroll: el.hasAttribute('data-scroll'), paint: el.dataset.paint !== '0' }));
  const nexts = [...document.querySelectorAll('[data-l="next"]')];
  const eqs = [...document.querySelectorAll('.eq')].map((el) => Object.assign(surface(el), { bars: [...el.children] }));
  const progs = [...document.querySelectorAll('[data-l="prog"]')];
  const curs = [...document.querySelectorAll('[data-l="cur"]')];
  const rems = [...document.querySelectorAll('[data-l="rem"]')];
  const mmss = (ms) => { const s = Math.max(0, Math.floor(ms / 1000)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };

  // CJK lights one char at a time; a Latin word lights as one unit spread over its letters.
  // The fill uses 82% of the line's real duration and holds for the rest, like the app.
  const LATIN = /[A-Za-z0-9'’\-]/;
  function layout(text, ms) {
    const chars = []; let t = 0;
    const s = [...text];
    for (let i = 0; i < s.length;) {
      const ch = s[i];
      if (ch === ' ') { chars.push({ ch, sp: true, start: t, dur: 0 }); t += SPACE_MS; i++; continue; }
      if (!LATIN.test(ch)) { chars.push({ ch, start: t, dur: CHAR_MS }); t += CHAR_MS; i++; continue; }
      let j = i; while (j < s.length && LATIN.test(s[j])) j++;
      const word = s.slice(i, j), wordMs = 260 + 45 * word.length, per = wordMs / word.length;
      word.forEach((c, k) => chars.push({ ch: c, start: t + k * per, dur: per }));
      t += wordMs; i = j;
    }
    const k = (ms * 0.82) / t;
    chars.forEach((c) => { c.start *= k; c.dur *= k; });
    return { chars, cycle: ms };
  }

  const spansFor = (host, line) => line.chars.map((c) => {
    const s = document.createElement('span');
    s.className = c.sp ? 'w sp' : 'w';
    s.textContent = c.ch;
    host.appendChild(s);
    return s;
  });

  function render(m, line) {
    m.el.textContent = '';
    const host = m.scroll ? m.el.appendChild(document.createElement('span')) : m.el;
    if (m.scroll) host.className = 'run';
    m.run = m.scroll ? host : null;
    m.spans = spansFor(host, line);
  }

  // The Lyrics Window lists the block several times over and keeps the current line at 42% of its height;
  // near the end it jumps back two copies, which looks the same, so the scroll never runs out.
  const COPIES = 6;
  const lists = [...document.querySelectorAll('.lw-list')].map((el) => {
    const track = el.querySelector('.lw-track');
    const rows = [];
    for (let c = 0; c < COPIES; c++) {
      LINES.forEach((l) => { const p = document.createElement('p'); p.className = 'lw-row'; p.textContent = l.text; track.appendChild(p); rows.push(p); });
    }
    return Object.assign(surface(el), { track, rows, at: -1, spans: [], placed: false });
  });
  const mark = (L) => L.rows.forEach((r, j) => { r.dataset.d = String(Math.min(3, Math.abs(j - L.at))); });
  function place(L, animate) {
    const row = L.rows[L.at];
    const y = L.el.clientHeight * 0.42 - (row.offsetTop + row.offsetHeight / 2);
    L.track.style.transition = animate ? '' : 'none';
    L.track.style.transform = `translateY(${y.toFixed(1)}px)`;
    if (!animate) { void L.track.offsetWidth; L.track.style.transition = ''; }
  }
  function listShow(L, i, line) {
    const n = LINES.length;
    if (L.at < 0) {
      L.at = 2 * n + (i % n);
    } else {
      L.rows[L.at].textContent = LINES[L.at % n].text;
      if (L.at + 1 >= (COPIES - 1) * n) { L.at -= 2 * n; mark(L); place(L, false); }
      L.at += 1;
    }
    const row = L.rows[L.at];
    row.textContent = '';
    L.spans = spansFor(row, line);
    mark(L);
    place(L, L.placed && !reduce);
    L.placed = true;
  }

  // Layout is read once per line (and on resize), never inside the animation frame.
  function measure() {
    for (const m of mains) {
      if (!m.run) continue;
      m.cw = m.el.clientWidth;
      m.sw = m.run.scrollWidth;
      m.left = m.spans.map((s) => s.offsetLeft);
      m.width = m.spans.map((s) => s.offsetWidth);
    }
  }

  let idx = 0, line = null, t0 = performance.now(), loopStart = 0;
  const loopMs = LINES.reduce((a, l) => a + l.ms, 0);

  function show(i) {
    const cur = LINES[i % LINES.length], nxt = LINES[(i + 1) % LINES.length];
    line = layout(cur.text, cur.ms);
    mains.forEach((m) => render(m, line));
    nexts.forEach((el) => { el.textContent = nxt.text; });
    lists.forEach((L) => listShow(L, i, line));
    loopStart = LINES.slice(0, i % LINES.length).reduce((a, l) => a + l.ms, 0);
    t0 = performance.now();
    measure();
  }

  // Reading position = where the fill has reached; keep it at 45% of the box.
  function follow(m, t) {
    if (!m.run) return;
    if (m.sw <= m.cw) { m.run.style.transform = ''; return; }
    let x = 0;
    line.chars.forEach((c, k) => {
      if (c.sp || t < c.start) return;
      x = m.left[k] + m.width[k] * Math.min(1, (t - c.start) / c.dur);
    });
    const off = Math.min(m.sw - m.cw, Math.max(0, x - m.cw * 0.45));
    m.run.style.transform = `translateX(${-off.toFixed(1)}px)`;
  }

  function paint(t) {
    const vals = line.chars.map((c) => (c.sp ? null : (Math.min(1, Math.max(0, (t - c.start) / c.dur)) * 124 - 12).toFixed(1) + '%'));
    const fill = (spans) => vals.forEach((v, k) => { if (v) spans[k].style.setProperty('--p', v); });
    for (const m of mains) if (m.paint && shown(m)) fill(m.spans);
    for (const L of lists) if (shown(L)) fill(L.spans);
    for (const m of mains) if (m.run && shown(m)) follow(m, t);
  }

  // Vocal envelope drives the equalizer, as in the app: full inside a sung char, 0.6 between.
  function eq(now, t) {
    const singing = line.chars.some((c) => !c.sp && t >= c.start && t < c.start + c.dur);
    const amp = singing ? 1 : 0.6;
    const s = now / 1000;
    for (const e of eqs) {
      if (!shown(e)) continue;
      e.bars.forEach((b, k) => {
        const ph = k * 2.399963;
        const w = (Math.sin(2 * Math.PI * 2.2 * s + ph) + Math.sin(2 * Math.PI * 3.6 * s + ph * 1.7)) / 4 + 0.5;
        b.style.height = 'calc(' + (2.5 + 13.5 * Math.min(1, w * amp)).toFixed(2) + ' * var(--u))';
      });
    }
  }

  // Every progress readout follows the lyrics: the demo starts at the song's chorus.
  function clock(t) {
    const played = DEMO.startMs + ((loopStart + Math.min(t, line.cycle)) % loopMs);
    const w = (played / DEMO.songMs * 100).toFixed(2) + '%';
    progs.forEach((el) => { el.style.width = w; });
    curs.forEach((el) => { el.textContent = mmss(played); });
    rems.forEach((el) => { el.textContent = '-' + mmss(DEMO.songMs - played); });
  }

  show(0);
  if (reduce) {
    paint(1e9);
    clock(0);
  } else {
    const tick = (now) => {
      if (onScreen.size && line) {
        const t = now - t0;
        paint(t);
        eq(now, t);
        clock(t);
        if (t > line.cycle) { idx++; show(idx); }
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }
  window.addEventListener('resize', () => { measure(); lists.forEach((L) => place(L, false)); });
  document.querySelectorAll('.island').forEach((el) => el.addEventListener('transitionend', (e) => { if (e.propertyName === 'width') measure(); }));

  // Hover the hero notch to expand it, with the app's intent delays (0.12s in, 0.1s out).
  // A mouse click while hovering keeps it open; a tap toggles it.
  const notch = $('notchWrap'), island = notch.querySelector('.island');
  let notchTimer = 0, notchHover = false;
  const setOpen = (open, delay) => { clearTimeout(notchTimer); notchTimer = setTimeout(() => island.classList.toggle('open', open), delay); };
  notch.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') { notchHover = true; setOpen(true, 120); } });
  notch.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') { notchHover = false; setOpen(false, 100); } });
  notch.addEventListener('click', () => { if (notchHover) setOpen(true, 0); else island.classList.toggle('open'); });

  /* ---------- page ---------- */
  // Seamless marquee: append one hidden copy of the players so the loop has no gap.
  const track = document.querySelector('.track');
  if (track) [...track.children].forEach((n) => { const c = n.cloneNode(true); c.setAttribute('aria-hidden', 'true'); track.appendChild(c); });

  // Reveal on scroll. The first screen (the headline block and the players strip) comes in by itself from lp.css,
  // so it is left out here. If the observer is late, whatever is already on screen (or above it) shows anyway;
  // what is further down still plays its entrance when it is scrolled to.
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add('in');
      io.unobserve(e.target);
    }
  }, { threshold: 0.12 });
  const reveals = [...document.querySelectorAll('.reveal')].filter((el) => !el.closest('.hero') && !el.classList.contains('players'));
  reveals.forEach((el) => io.observe(el));
  setTimeout(() => reveals.forEach((el) => { if (el.getBoundingClientRect().top < innerHeight) el.classList.add('in'); }), 1500);
  // the page's inline script shows everything if this flag never appears (the script failed before here)
  window.lpReady = true;

  /* ---------- feature chapters ---------- */
  // Each chapter stage switches its views with a glass segmented control. While it is on screen it advances
  // by itself (the bar under the selected tab shows how long is left); a click hands it over to the user.
  // The shown view gets .go, which starts its entrance animations; numbers marked data-count count up.
  // A mouse resting on the stage holds the rotation, so nothing changes under the pointer.
  const fmt = new Intl.NumberFormat('en-US');
  function countUp(view) {
    view.querySelectorAll('[data-count]').forEach((el) => {
      const to = +el.dataset.count;
      if (reduce) { el.textContent = fmt.format(to); return; }
      const t0c = performance.now(), D = 1100;
      const step = (now) => {
        const k = Math.min(1, (now - t0c) / D), e = 1 - Math.pow(1 - k, 3);
        el.textContent = fmt.format(Math.round(to * e));
        if (k < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    });
  }
  const shows = [...document.querySelectorAll('.show')];
  const moveThumb = (seg, btn, animate) => {
    const thumb = seg.querySelector('.seg-thumb');
    thumb.style.width = btn.offsetWidth + 'px';
    thumb.style.transform = `translateX(${btn.offsetLeft}px)`;
    if (animate) { seg.classList.remove('moving'); void seg.offsetWidth; seg.classList.add('moving'); }
  };
  shows.forEach((show) => {
    const seg = show.querySelector('.seg');
    const views = [...show.querySelectorAll('.view')];
    const tabs = seg ? [...seg.querySelectorAll('.seg-btn')] : [];
    const ctl = { at: 0, auto: !reduce && tabs.length > 1, timer: 0, visible: false, hover: false, dur: 6500, onSelect: null };
    show.ctl = ctl;
    const go = () => {
      views.forEach((v, k) => { if (k !== ctl.at) v.classList.remove('go'); });
      const v = views[Math.min(ctl.at, views.length - 1)];
      if (!v || v.classList.contains('go')) return;
      requestAnimationFrame(() => { v.classList.add('go'); countUp(v); });
    };
    // a view may ask for a longer turn (data-dur) when it plays a sequence of its own
    const schedule = () => {
      clearTimeout(ctl.timer);
      show.classList.remove('auto');
      if (!ctl.auto || !ctl.visible || ctl.hover) return;
      void show.offsetWidth;
      const dur = +(views[ctl.at] && views[ctl.at].dataset.dur) || ctl.dur;
      show.style.setProperty('--dur', dur + 'ms');
      show.classList.add('auto');
      ctl.timer = setTimeout(() => select((ctl.at + 1) % tabs.length, false), dur);
    };
    const stage = show.querySelector('.ch-stage');
    // a glare crosses the stage when it changes view (and the first time it comes into view)
    const sweep = () => {
      if (reduce) return;
      stage.classList.remove('sweep');
      void stage.offsetWidth;
      stage.classList.add('sweep');
    };
    stage.addEventListener('animationend', (e) => { if (e.animationName === 'sweep') stage.classList.remove('sweep'); });
    const select = (i, byUser) => {
      if (byUser) ctl.auto = false;
      ctl.at = i;
      tabs.forEach((b, k) => b.setAttribute('aria-selected', String(k === i)));
      if (views.length > 1) views.forEach((v, k) => v.classList.toggle('on', k === i));
      if (seg) moveThumb(seg, tabs[i], true);
      if (ctl.onSelect) ctl.onSelect(i);
      if (ctl.visible) go();
      sweep();
      measure();
      schedule();
    };
    ctl.schedule = schedule;
    stage.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') { ctl.hover = true; schedule(); } });
    stage.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') { ctl.hover = false; schedule(); } });
    tabs.forEach((b, k) => b.addEventListener('click', () => { if (k !== ctl.at || ctl.auto) select(k, true); }));
    if (seg) {
      seg.addEventListener('keydown', (e) => {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
        e.preventDefault();
        const n = (ctl.at + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length;
        select(n, true);
        tabs[n].focus();
      });
      requestAnimationFrame(() => moveThumb(seg, tabs[0], false));
    }
    new IntersectionObserver(([e]) => {
      ctl.visible = e.isIntersecting;
      if (ctl.visible) { go(); if (!ctl.seen) { ctl.seen = true; sweep(); } }
      schedule();
    }, { threshold: 0.45 }).observe(show);
  });
  window.addEventListener('resize', () => shows.forEach((s) => {
    const seg = s.querySelector('.seg');
    if (seg) moveThumb(seg, seg.querySelectorAll('.seg-btn')[s.ctl.at], false);
  }));

  /* ---------- editor previews ---------- */
  // The sliders resize the previews live, the way the app's editors do.
  const fillPct = (r) => r.style.setProperty('--f', ((r.value - r.min) / (r.max - r.min) * 100).toFixed(1) + '%');
  document.querySelectorAll('.ed-prev').forEach((prev) => {
    const out = prev.querySelector('output');
    const box = prev.querySelector('.ed-box');
    if (box) {
      // floating lyrics: overlay width
      const r = prev.querySelector('.ed-range');
      const apply = () => { box.style.setProperty('--w', r.value); out.textContent = r.value + 'pt'; fillPct(r); };
      r.addEventListener('input', () => { apply(); measure(); });
      apply();
      return;
    }
    const mbw = prev.querySelector('.ed-range.mbw');
    if (mbw) {
      // menu bar: maximum width of the lyric slot
      const slot = prev.querySelector('.ed-mbl');
      const apply = () => { slot.style.setProperty('--mbw', mbw.value); out.textContent = mbw.value + 'pt'; fillPct(mbw); };
      mbw.addEventListener('input', () => { apply(); measure(); });
      apply();
      return;
    }
    const lo = prev.querySelector('.ed-range.lo'), hi = prev.querySelector('.ed-range.hi');
    if (!lo || !hi) return;
    // notch: one track, two thumbs, steady width on the left and expanded width on the right, kept 60pt apart
    const isl = prev.querySelector('.island'), wrap = prev.querySelector('.notch-wrap'), trackEl = prev.querySelector('.ed-dual-track');
    const pct = (v) => ((v - lo.min) / (lo.max - lo.min) * 100).toFixed(1) + '%';
    const apply = () => {
      isl.style.setProperty('--isw', lo.value);
      isl.style.setProperty('--iew', hi.value);
      out.textContent = `${lo.value}–${hi.value}pt`;
      trackEl.style.setProperty('--a', pct(lo.value));
      trackEl.style.setProperty('--b', pct(hi.value));
    };
    lo.addEventListener('input', () => { if (+lo.value > +hi.value - 60) lo.value = +hi.value - 60; apply(); measure(); });
    hi.addEventListener('input', () => { if (+hi.value < +lo.value + 60) hi.value = +lo.value + 60; apply(); isl.classList.add('open'); });
    hi.addEventListener('change', () => isl.classList.remove('open'));
    apply();
    // hovering the preview card expands it, as in the app
    wrap.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') isl.classList.add('open'); });
    wrap.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') isl.classList.remove('open'); });
    wrap.addEventListener('click', () => isl.classList.toggle('open'));
  });
  // Lyrics Window: full and mini size of the same window (.lwx). The picture-in-picture buttons switch it,
  // as in the app, and the settings preview has its own full / mini buttons. While a stage runs on its own
  // the window shrinks to the mini size halfway through its turn; touching either control hands the
  // stage over to the visitor.
  document.querySelectorAll('.lwx').forEach((lwx) => {
    const view = lwx.closest('.view'), show = lwx.closest('.show'), ed = lwx.closest('.ed');
    const sizeBtns = ed ? [...ed.querySelectorAll('.ed-size button')] : [];
    let timer = 0;
    const set = (mini) => {
      lwx.classList.toggle('mini', mini);
      sizeBtns.forEach((b, k) => b.setAttribute('aria-pressed', String(k === (mini ? 1 : 0))));
      measure();
    };
    const takeOver = () => {
      clearTimeout(timer);
      if (show && show.ctl && show.ctl.auto) { show.ctl.auto = false; show.ctl.schedule(); }
    };
    lwx.querySelectorAll('[data-mini]').forEach((b) => b.addEventListener('click', () => { takeOver(); set(b.dataset.mini === '1'); }));
    sizeBtns.forEach((b, k) => b.addEventListener('click', () => { takeOver(); set(k === 1); }));
    if (!view) return;
    new MutationObserver(() => {
      clearTimeout(timer);
      // back to full once the view has faded out, so the next visit starts from the full size
      if (!view.classList.contains('on')) { timer = setTimeout(() => set(false), 700); return; }
      if (view.classList.contains('go') && show && show.ctl && show.ctl.auto && !reduce) timer = setTimeout(() => set(true), 3200);
    }).observe(view, { attributes: true, attributeFilter: ['class'] });
  });

  // Display chapter, notch view: the card goes through its forms the way the app does. Steady with its lyric
  // row, opened (as on hover), then the header's "Show Lyrics" key is pressed (it only dims while the card is
  // open) and the card folds back into a status bar. Hovering opens it; a tap opens or closes it; the key
  // toggles the lyric row. A tap or the key hands the stage over to the visitor.
  document.querySelectorAll('.nz').forEach((nz) => {
    const isl = nz.querySelector('.island'), wrap = nz.querySelector('.notch-wrap'), key = nz.querySelector('.ix-lyr');
    const view = nz.closest('.view'), show = nz.closest('.show');
    if (!isl || !key || !view) return;
    let timers = [], hovering = false;
    const clear = () => { timers.forEach(clearTimeout); timers = []; };
    const at = (ms, fn) => timers.push(setTimeout(fn, ms));
    const setOpen = (open) => isl.classList.toggle('open', open);
    const setLyrics = (on) => {
      isl.classList.toggle('bare', !on);
      key.classList.toggle('off', !on);
      key.setAttribute('aria-pressed', String(on));
      key.title = on ? key.dataset.on : key.dataset.off;
    };
    const takeOver = () => {
      clear();
      if (show && show.ctl && show.ctl.auto) { show.ctl.auto = false; show.ctl.schedule(); }
    };
    const play = () => {
      clear();
      setLyrics(true);
      setOpen(false);
      at(1500, () => setOpen(true));
      at(3500, () => { key.classList.add('press'); setLyrics(false); });
      at(3900, () => key.classList.remove('press'));
      at(5100, () => setOpen(false));
    };
    // the markup is the opened card, which is what reduced motion (and no script) shows
    if (!reduce) setOpen(false);
    wrap.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') { hovering = true; clear(); setOpen(true); } });
    wrap.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') { hovering = false; setOpen(false); } });
    wrap.addEventListener('click', (e) => {
      if (hovering || e.target.closest('.ix-lyr')) return;
      takeOver();
      setOpen(!isl.classList.contains('open'));
    });
    key.addEventListener('click', () => { takeOver(); setLyrics(key.classList.contains('off')); });
    new MutationObserver(() => {
      if (!view.classList.contains('on')) {
        // back to the opening form once the view has faded out
        clear();
        at(700, () => { setLyrics(true); setOpen(reduce); });
        return;
      }
      if (view.classList.contains('go') && !reduce && !hovering) play();
    }).observe(view, { attributes: true, attributeFilter: ['class'] });
  });

  /* ---------- translation and readings ---------- */
  // Real lines from the lyrics cache (#readData): each word group carries its reading and its real timing,
  // and the words light up together with their readings, like the overlay's per-word romanization.
  const rdShow = document.querySelector('.ch-rd .show');
  if (rdShow && $('readData')) {
    const EX = JSON.parse($('readData').textContent);
    const box = rdShow.querySelector('.rd-lines'), row = rdShow.querySelector('.rd-row');
    const tr = rdShow.querySelector('.rd-tr'), song = rdShow.querySelector('.rd-song');
    const HOLD = 2400, FADE = 300;
    const ctl = rdShow.ctl;
    const cycleOf = (ex) => Math.max(...ex.groups.map((g) => g.s + g.d));
    const mk = (cls, text) => { const s = document.createElement('span'); s.className = cls; s.textContent = text; return s; };
    let cur = null, r0 = performance.now(), swapping = false, swapT = 0, seen = false;
    function rdBuild(ex) {
      row.lang = ex.lang;
      row.textContent = '';
      const groups = ex.groups.map((g) => {
        const top = mk('rg-t', ''), bot = mk('rg-r', ''), fill = mk('rd-fill', '');
        top.append(mk('rd-stroke', g.t));
        const spans = [...g.t].map((c) => { const s = mk(c === ' ' ? 'w sp' : 'w', c); fill.append(s); return s; });
        top.append(fill);
        const reading = g.r || ' ';
        const rf = mk('rd-fill', reading);
        bot.append(mk('rd-stroke', reading), rf);
        const el = mk('rg', '');
        el.append(top, bot);
        row.append(el);
        return { g, spans, rf };
      });
      tr.hidden = !ex.tr;
      tr.querySelectorAll('span').forEach((s) => { s.textContent = ex.tr; });
      song.textContent = ex.song;
      cur = { groups, cycle: cycleOf(ex) };
    }
    const at = (p) => (p * 124 - 12).toFixed(1) + '%';
    function rdPaint(t) {
      for (const { g, spans, rf } of cur.groups) {
        const p = Math.min(1, Math.max(0, (t - g.s) / g.d));
        spans.forEach((s, k) => s.style.setProperty('--p', at(Math.min(1, Math.max(0, p * spans.length - k)))));
        rf.style.setProperty('--p', at(p));
      }
    }
    ctl.dur = cycleOf(EX[0]) + HOLD;
    ctl.onSelect = (i) => {
      ctl.dur = cycleOf(EX[i]) + HOLD + FADE;
      clearTimeout(swapT);
      swapping = true;
      box.classList.add('out');
      swapT = setTimeout(() => {
        rdBuild(EX[i]);
        r0 = performance.now();
        swapping = false;
        box.classList.remove('out');
        if (reduce) rdPaint(1e9);
      }, FADE);
    };
    rdBuild(EX[0]);
    if (reduce) {
      rdPaint(1e9);
    } else {
      let rdVisible = false;
      new IntersectionObserver(([e]) => {
        rdVisible = e.isIntersecting;
        if (rdVisible && !seen) { seen = true; r0 = performance.now(); }
      }, { threshold: 0.45 }).observe(rdShow);
      const tick = (now) => {
        if (rdVisible && cur && !swapping) {
          const t = now - r0;
          rdPaint(t);
          // once the user has picked a language, that line keeps replaying
          if (!ctl.auto && t > cur.cycle + HOLD) r0 = now;
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }
  }

  /* ---------- glass and depth ---------- */
  const fine = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  // Glass picks up a highlight where the pointer is.
  document.querySelectorAll('.glass').forEach((el) => {
    el.addEventListener('pointermove', (e) => {
      const r = el.getBoundingClientRect();
      el.style.setProperty('--gx', ((e.clientX - r.left) / r.width * 100).toFixed(1) + '%');
      el.style.setProperty('--gy', ((e.clientY - r.top) / r.height * 100).toFixed(1) + '%');
    });
    el.addEventListener('pointerleave', () => { el.style.removeProperty('--gx'); el.style.removeProperty('--gy'); });
  });
  // A light follows the pointer across the stages and the final card. The position goes on the light itself,
  // so nothing else on the stage restyles.
  if (fine) {
    document.querySelectorAll('.ch-stage, .more-stage, .final-card').forEach((host) => {
      const spot = host.querySelector('.spot');
      if (!spot) return;
      host.addEventListener('pointermove', (e) => {
        const r = host.getBoundingClientRect();
        spot.style.setProperty('--sx', (e.clientX - r.left).toFixed(0) + 'px');
        spot.style.setProperty('--sy', (e.clientY - r.top).toFixed(0) + 'px');
      });
    });
  }

  // Headings light up like a lyric line: one span per CJK character (with the punctuation after it) or per
  // Latin word, weighted by its length so the fill moves at an even speed.
  const WORD = /[A-Za-z0-9'’\-]/, TRAIL = /[，。、！？；：,.!?;:]/;
  function lightable(el) {
    const parts = [];
    const walk = (node) => [...node.childNodes].forEach((n) => {
      if (n.nodeType === 1) { if (n.tagName !== 'BR') walk(n); return; }
      if (n.nodeType !== 3) return;
      const s = [...n.textContent], frag = document.createDocumentFragment();
      for (let i = 0; i < s.length;) {
        if (/\s/.test(s[i])) { let j = i; while (j < s.length && /\s/.test(s[j])) j++; frag.append(s.slice(i, j).join('')); i = j; continue; }
        const latin = WORD.test(s[i]);
        let j = i + 1;
        if (latin) while (j < s.length && WORD.test(s[j])) j++;
        while (j < s.length && TRAIL.test(s[j])) j++;
        const c = document.createElement('span');
        c.className = 'c';
        c.textContent = s.slice(i, j).join('');
        frag.append(c);
        parts.push({ el: c, w: latin ? Math.max(1, (j - i) * 0.55) : 1 });
        i = j;
      }
      n.replaceWith(frag);
    });
    walk(el);
    let k = 0;
    parts.forEach((p) => { p.k = k; k += p.w; p.el.style.setProperty('--k', p.k.toFixed(2)); p.el.style.setProperty('--w', p.w.toFixed(2)); });
    return { parts, total: k };
  }
  // The hero headline and the final card light up once, when they come into view. On the first screen the
  // headline starts once it has faded in (about 0.45s after the page starts). The headline's fade comes from
  // lp.css; if this script arrives after the headline already shows in full ink, it stays as it is, since dimming
  // it to light it up again would read as a flicker.
  document.querySelectorAll('.sing').forEach((el) => {
    if (el.closest('.hero') && !reduce) {
      const fade = el.getAnimations().find((a) => a.animationName === 'enter');
      if (!fade || fade.currentTime > 120) return;
    }
    lightable(el);
    if (reduce) return;
    const singIO = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return;
      if (el.closest('.hero')) el.style.setProperty('--d0', Math.max(150, 450 - performance.now()).toFixed(0) + 'ms');
      el.classList.add('go');
      singIO.disconnect();
    }, { threshold: 0.3 });
    singIO.observe(el);
  });
  // The grey half of each chapter heading fills with the brand gradient, word by word, while it scrolls from
  // the bottom of the window to its middle; scrolling back up empties it again.
  // The gradient's stops are the --g1..--g3 tokens (six-digit hex), which differ between the light and the
  // dark appearance; switching the system appearance re-tints the headings.
  let GRAD = [];
  const readGrad = () => {
    const cs = getComputedStyle(document.documentElement);
    GRAD = ['--g1', '--g2', '--g3'].map((n) => {
      const v = parseInt(cs.getPropertyValue(n).trim().slice(1), 16);
      return [v >> 16 & 255, v >> 8 & 255, v & 255];
    });
  };
  const gradAt = (x) => {
    const f = clamp(x) * (GRAD.length - 1), i = Math.min(GRAD.length - 2, Math.floor(f)), t = f - i;
    return 'rgb(' + GRAD[i].map((v, n) => Math.round(v + (GRAD[i + 1][n] - v) * t)).join(', ') + ')';
  };
  const fills = [...document.querySelectorAll('.fx')].map((el) => Object.assign(lightable(el), { el, p: -1, top: 0 }));
  const tint = () => {
    readGrad();
    fills.forEach((L) => L.parts.forEach((p) => {
      p.el.style.setProperty('--fa', gradAt(p.k / L.total));
      p.el.style.setProperty('--fb', gradAt((p.k + p.w) / L.total));
    }));
  };
  tint();
  const schemeMQ = window.matchMedia('(prefers-color-scheme: dark)');
  if (schemeMQ.addEventListener) schemeMQ.addEventListener('change', tint); else schemeMQ.addListener(tint);
  const fillTo = (f, p) => {
    if (Math.abs(p - f.p) < 0.002) return;
    f.p = p;
    const at = p * f.total;
    f.parts.forEach((c) => c.el.style.setProperty('--fp', (clamp((at - c.k) / c.w) * 124 - 12).toFixed(1) + '%'));
  };
  if (reduce) fills.forEach((f) => fillTo(f, 1));

  // Document positions are cached (layout positions, so the reveal transforms don't skew them) and refreshed
  // when the page reflows; the scroll frame itself reads nothing from the layout.
  const docTop = (el) => { let y = 0; for (let n = el; n; n = n.offsetParent) y += n.offsetTop; return y; };
  const stages = [...document.querySelectorAll('.ch-stage')].map((el) => ({ el, wall: el.querySelector('.ch-wall'), top: 0, h: 0, par: 2 }));
  const navEl = document.querySelector('.nav');
  let maxScroll = 1, phone = false, devTop = 0;
  const recache = () => {
    maxScroll = Math.max(1, document.documentElement.scrollHeight - innerHeight);
    phone = innerWidth <= 820;
    stages.forEach((s) => { s.top = docTop(s.el); s.h = s.el.offsetHeight; });
    fills.forEach((f) => { f.top = docTop(f.el); });
    const dev = document.querySelector('.device');
    devTop = dev ? docTop(dev) : 0;
  };

  // The hero laptop: it leans toward the pointer (eased), and once its top has scrolled past the upper fifth
  // of the window it tips back a little while the player icons drift outward at their own depths.
  const device = document.querySelector('.device');
  const heroWall = document.querySelector('.hero .wall');
  const floats = [...document.querySelectorAll('.fl')].map((el) => ({
    el, d: +el.dataset.d || 1, fx: +el.dataset.fx || 0, fy: +el.dataset.fy || 0, r: +el.dataset.r || 0,
  }));
  const H = { tx: 0, ty: 0, mx: 0, my: 0, hs: 0, raf: 0 };
  function heroPaint() {
    if (!device) return;
    const { mx, my, hs } = H;
    device.style.transform = `perspective(1600px) translateY(${(hs * 24).toFixed(1)}px) scale(${(1 - hs * 0.045).toFixed(4)}) ` +
      `rotateX(${(-my * 1.6 + hs * 7).toFixed(2)}deg) rotateY(${(mx * 2.4).toFixed(2)}deg)`;
    if (heroWall) heroWall.style.translate = `${(-mx * 8).toFixed(1)}px ${(-my * 6).toFixed(1)}px`;
    floats.forEach((f) => {
      f.el.style.transform = `translate3d(${(mx * f.d * 18 + f.fx * hs * 80).toFixed(1)}px, ${(my * f.d * 14 - hs * f.fy).toFixed(1)}px, 0) rotate(${f.r}deg)`;
    });
  }
  if (device && fine && !reduce) {
    const hero = document.querySelector('.hero');
    const ease = () => {
      H.mx += (H.tx - H.mx) * 0.08;
      H.my += (H.ty - H.my) * 0.08;
      const done = Math.abs(H.tx - H.mx) < 0.001 && Math.abs(H.ty - H.my) < 0.001;
      if (done) { H.mx = H.tx; H.my = H.ty; }
      heroPaint();
      H.raf = done ? 0 : requestAnimationFrame(ease);
    };
    const kick = () => { if (!H.raf) H.raf = requestAnimationFrame(ease); };
    hero.addEventListener('pointermove', (e) => {
      const r = device.getBoundingClientRect();
      H.tx = clamp((e.clientX - (r.left + r.width / 2)) / (r.width / 2), -1, 1);
      H.ty = clamp((e.clientY - (r.top + r.height / 2)) / (r.height / 2), -1, 1);
      kick();
    });
    hero.addEventListener('pointerleave', () => { H.tx = 0; H.ty = 0; kick(); });
  }

  // One scroll frame: the reading progress in the nav, the stage wallpapers drifting against the scroll,
  // the hero tipping back, the chapter headings filling.
  let queued = false;
  function frame() {
    queued = false;
    const y = scrollY, vh = innerHeight;
    if (navEl) navEl.style.setProperty('--sp', clamp(y / maxScroll).toFixed(4));
    if (reduce) return;
    const amp = phone ? 40 : 60;
    stages.forEach((s) => {
      const mid = s.top - y + s.h / 2;
      if (mid < -vh || mid > 2 * vh) return;
      const par = clamp((mid - vh / 2) / vh, -1, 1);
      if (Math.abs(par - s.par) < 0.001) return;
      s.par = par;
      if (s.wall) s.wall.style.transform = `translate3d(0, ${(par * amp).toFixed(1)}px, 0)`;
    });
    const hs = clamp((y - (devTop - vh * 0.2)) / (vh * 0.8));
    if (hs !== H.hs) { H.hs = hs; heroPaint(); }
    fills.forEach((f) => {
      const top = f.top - y;
      if (top < -vh || top > 2 * vh) return;
      fillTo(f, clamp((vh * 0.92 - top) / (vh * 0.42)));
    });
  }
  const onScroll = () => { if (!queued) { queued = true; requestAnimationFrame(frame); } };
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', () => { recache(); onScroll(); });
  new ResizeObserver(() => { recache(); onScroll(); }).observe(document.body);
  recache();
  frame();

  // Magnetic buttons lean a little toward the pointer.
  if (fine && !reduce) {
    document.querySelectorAll('.mag').forEach((b) => {
      b.addEventListener('pointermove', (e) => {
        const r = b.getBoundingClientRect();
        b.style.translate = `${((e.clientX - r.left - r.width / 2) * 0.16).toFixed(1)}px ${((e.clientY - r.top - r.height / 2) * 0.24).toFixed(1)}px`;
      });
      b.addEventListener('pointerleave', () => { b.style.translate = ''; });
    });
  }

  /* ---------- faq ---------- */
  // Answers open and close with a height animation instead of jumping; the native toggle still applies
  // with reduced motion.
  document.querySelectorAll('.qa').forEach((d) => {
    const sum = d.querySelector('summary'), a = d.querySelector('.qa-a');
    let anim = null;
    sum.addEventListener('click', (e) => {
      if (reduce || !a.animate) return;
      e.preventDefault();
      if (anim) anim.cancel();
      if (d.open && !d.classList.contains('closing')) {
        d.classList.add('closing');
        anim = a.animate([{ height: a.offsetHeight + 'px', opacity: 1 }, { height: '0px', opacity: 0 }],
          { duration: 260, easing: 'cubic-bezier(.4, 0, .2, 1)' });
        anim.onfinish = () => { d.open = false; d.classList.remove('closing'); anim = null; };
      } else {
        d.classList.remove('closing');
        d.open = true;
        anim = a.animate([{ height: '0px', opacity: 0 }, { height: a.offsetHeight + 'px', opacity: 1 }],
          { duration: 380, easing: 'cubic-bezier(.2, .8, .2, 1)' });
        anim.onfinish = () => { anim = null; };
      }
    });
  });

  // Copy the Homebrew commands; labels come from the button's data attributes.
  const copyBtn = $('copyBrew');
  if (copyBtn) {
    const label = copyBtn.querySelector('.copy-label');
    const orig = label.textContent;
    copyBtn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(copyBtn.dataset.copy);
        copyBtn.classList.add('copied');
        label.textContent = copyBtn.dataset.copied;
      } catch {
        label.textContent = copyBtn.dataset.copy.split('\n').join(' && ');
      }
      setTimeout(() => { copyBtn.classList.remove('copied'); label.textContent = orig; }, 2400);
    });
  }

  // Menus (download, language): hover on desktop, first tap opens on touch.
  // A click on a button trigger that hover just opened must not close it again.
  const menus = [...document.querySelectorAll('.dl')];
  const closers = new Map();
  const closeAll = (except) => menus.forEach((d) => { if (d !== except && closers.has(d)) closers.get(d)(); });
  let latestChecked = false;
  function refreshLatest() {
    if (latestChecked) return;
    latestChecked = true;
    fetch('https://api.github.com/repos/Yudaotor/lyrimuse/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
      .then((r) => (r.ok ? r.json() : null))
      .then((rel) => {
        if (!rel || !rel.tag_name || !Array.isArray(rel.assets)) return;
        const pickAsset = (re) => rel.assets.find((a) => re.test(a.name));
        const arm = pickAsset(/-macos\.dmg$/), x86 = pickAsset(/-macos-intel\.dmg$/);
        const mb = (n) => Math.round(n / 1048576) + ' MB';
        document.querySelectorAll('.dl-ver').forEach((e) => { e.textContent = rel.tag_name; });
        document.querySelectorAll('.dl-item[data-arch]').forEach((a) => {
          const asset = a.dataset.arch === 'arm' ? arm : x86;
          if (!asset) return;
          a.href = asset.browser_download_url;
          const sz = a.querySelector('.dl-size'); if (sz) sz.textContent = mb(asset.size);
        });
      })
      .catch(() => {});
  }
  // Chromium exposes the CPU architecture; Safari does not, so nothing is marked there.
  if (navigator.userAgentData && navigator.userAgentData.getHighEntropyValues) {
    navigator.userAgentData.getHighEntropyValues(['architecture']).then((v) => {
      const arch = v.architecture === 'arm' ? 'arm' : v.architecture === 'x86' ? 'x86' : '';
      if (arch) document.querySelectorAll(`.dl-item[data-arch="${arch}"]`).forEach((a) => a.classList.add('rec'));
    }).catch(() => {});
  }
  menus.forEach((d) => {
    const trigger = d.querySelector('.dl-trigger');
    const isDownload = d.classList.contains('dl-download');
    let t = 0, viaHover = false;
    const open = () => { if (isDownload) refreshLatest(); closeAll(d); d.classList.add('open'); trigger.setAttribute('aria-expanded', 'true'); };
    const close = () => { d.classList.remove('open'); trigger.setAttribute('aria-expanded', 'false'); viaHover = false; };
    closers.set(d, close);
    d.addEventListener('pointerenter', (e) => {
      if (e.pointerType !== 'mouse') return;
      clearTimeout(t);
      if (!d.classList.contains('open')) { open(); viaHover = true; }
    });
    d.addEventListener('pointerleave', (e) => { if (e.pointerType !== 'mouse') return; t = setTimeout(close, 160); });
    trigger.addEventListener('click', (e) => {
      if (trigger.tagName === 'BUTTON') {
        e.preventDefault();
        if (viaHover) { viaHover = false; return; }
        d.classList.contains('open') ? close() : open();
      } else if (!d.classList.contains('open')) {
        e.preventDefault();
        open();
      }
    });
    trigger.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { e.preventDefault(); open(); const first = d.querySelector('.dl-item'); if (first) first.focus(); }
    });
    d.addEventListener('keydown', (e) => { if (e.key === 'Escape') { close(); trigger.focus(); } });
  });
  document.addEventListener('click', (e) => { if (!e.target.closest('.dl')) closeAll(); });

  /* ---------- the 30-second video ---------- */
  // The page carries a tiny blurred poster; the real one (data-poster) loads once the video comes near, so it
  // doesn't take bandwidth from the first screen.
  document.querySelectorAll('video[data-poster]').forEach((video) => {
    const load = () => { video.poster = video.dataset.poster; video.removeAttribute('data-poster'); };
    if (!('IntersectionObserver' in window)) { load(); return; }
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) { io.disconnect(); load(); }
    }, { rootMargin: '400px 0px' });
    io.observe(video);
  });
  // Without this script the video keeps its native controls. With it, the cover carries a play button, the
  // controls appear once it plays, and the cover comes back when it ends (preload is none, so nothing loads early).
  // The play button is styled under .js only, so when the page's safety net has already dropped .js (this script
  // came late) the native controls stay as well.
  document.querySelectorAll('.watch-frame').forEach((frame) => {
    const video = frame.querySelector('video'), btn = frame.querySelector('.watch-play');
    if (!video || !btn || !document.documentElement.classList.contains('js')) return;
    video.controls = false;
    btn.addEventListener('click', () => {
      frame.classList.add('playing');
      video.controls = true;
      const p = video.play();
      if (p && p.catch) p.catch(() => { frame.classList.remove('playing'); });
    });
    video.addEventListener('ended', () => {
      frame.classList.remove('playing');
      video.controls = false;
      video.load();
    });
  });
})();
