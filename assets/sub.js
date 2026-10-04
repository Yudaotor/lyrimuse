// Lyrimuse landing site: the subpages. The menus behave as on the home page (lp.js), plus the reading progress
// along the nav and the table of contents that follows the section in view.
(() => {
  'use strict';
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));

  // Menus (download, language): hover on desktop, first tap opens on touch.
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
        const pick = (re) => rel.assets.find((a) => re.test(a.name));
        const arm = pick(/-macos\.dmg$/), x86 = pick(/-macos-intel\.dmg$/);
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
  if (navigator.userAgentData && navigator.userAgentData.getHighEntropyValues) {
    navigator.userAgentData.getHighEntropyValues(['architecture']).then((v) => {
      const arch = v.architecture === 'arm' ? 'arm' : v.architecture === 'x86' ? 'x86' : '';
      if (arch) document.querySelectorAll(`.dl-item[data-arch="${arch}"]`).forEach((a) => a.classList.add('rec'));
    }).catch(() => {});
  }
  menus.forEach((d) => {
    const trigger = d.querySelector('.dl-trigger');
    if (!trigger) return;
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

  // Reading progress along the bottom edge of the nav.
  const nav = document.querySelector('.nav');
  let raf = 0;
  const paint = () => {
    raf = 0;
    const max = Math.max(1, document.documentElement.scrollHeight - innerHeight);
    if (nav) nav.style.setProperty('--sp', clamp(scrollY / max).toFixed(4));
  };
  addEventListener('scroll', () => { if (!raf) raf = requestAnimationFrame(paint); }, { passive: true });
  addEventListener('resize', paint);
  paint();

  // The table of contents marks the section being read.
  const toc = [...document.querySelectorAll('.doc-toc a')];
  if (toc.length && 'IntersectionObserver' in window) {
    const byId = new Map(toc.map((a) => [a.getAttribute('href').slice(1), a]));
    const seen = new Set();
    const mark = () => {
      const first = [...document.querySelectorAll('.doc-sec')].find((s) => seen.has(s.id));
      toc.forEach((a) => a.classList.toggle('on', !!first && byId.get(first.id) === a));
    };
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => (e.isIntersecting ? seen.add(e.target.id) : seen.delete(e.target.id)));
      mark();
    }, { rootMargin: '-72px 0px -55% 0px' });
    document.querySelectorAll('.doc-sec').forEach((s) => io.observe(s));
  }

  // A link to one version (#v1.8.0) opens that version on the changelog page.
  const openFromHash = () => {
    const el = location.hash.length > 1 && document.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (el && el.tagName === 'DETAILS' && !el.open) { el.open = true; el.scrollIntoView(); }
  };
  addEventListener('hashchange', openFromHash);
  openFromHash();

  // A rim of light on the final card that follows the pointer.
  document.querySelectorAll('.final-card').forEach((card) => {
    card.addEventListener('pointermove', (e) => {
      const r = card.getBoundingClientRect();
      card.style.setProperty('--sx', `${((e.clientX - r.left) / r.width * 100).toFixed(1)}%`);
      card.style.setProperty('--sy', `${((e.clientY - r.top) / r.height * 100).toFixed(1)}%`);
    });
  });
})();
