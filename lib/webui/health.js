// StudioSync's Health page: the rows the panel's Settings > Health shows, read only, from the "health" topic lib/webpages.lua builds out of
// lib/page_health.lua's own rows (only while a page shows this: it says so every 10 s). A row's buttons stay on the panel; a web link opens in
// the browser. Everything in a row goes in as text (textContent), never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const page = mk('section', 'health');
  page.setAttribute('aria-labelledby', 'health-h');
  const h = mk('h2', '', 'Set up and health');
  h.id = 'health-h';
  const vers = mk('p', 'dim hvers'), list = mk('ul', 'hrows'), foot = mk('p', 'dim hfoot');
  list.setAttribute('aria-live', 'polite');
  page.append(h, vers, list, foot);

  let shown = false;
  const want = () => { if (shown && !document.hidden) ssTabs.act('health', { want: true }).catch(() => {}); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  ssTabs.add('health', 'Health', page, (on) => { shown = on; if (on) { want(); draw(); } });

  const LEVEL = { red: 'needs fixing', yellow: 'worth a look', grey: 'just so you know' };
  let last = null;
  function draw() {
    const m = ssTabs.topics.health;
    if (!shown || m === last) return;
    last = m;
    list.replaceChildren();
    if (!m) { list.append(mk('li', 'dim', 'Asking Live sync…')); return; }
    vers.textContent = 'StudioSync ' + (m.ver || '?') + ' · extension ' + (m.ext || 'not loaded');
    if (m.error) list.append(mk('li', 'hrow red', 'Health couldn’t be read here: ' + m.error));
    for (const r of m.rows || []) {
      const li = mk('li', 'hrow ' + (r.ok ? 'ok' : r.level || 'yellow'));
      const dot = mk('span', 'hdot');
      dot.setAttribute('role', 'img');
      dot.setAttribute('aria-label', r.ok ? 'fine' : LEVEL[r.level] || 'worth a look');
      li.append(dot, mk('span', 'htext', r.text));
      if (r.link) {
        const a = mk('a', 'hlink', r.link.label);
        a.href = r.link.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
        li.append(a);
      }
      if (r.copy) li.append(mk('code', 'hcopy', r.copy));
      list.append(li);
    }
    if (!(m.rows || []).length && !m.error) list.append(mk('li', 'dim', 'Nothing to show.'));
    foot.textContent = (m.hidden ? m.hidden + ' dismissed in the panel. ' : '') + 'Buttons that fix things are on the panel’s Health page.';
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
})();
