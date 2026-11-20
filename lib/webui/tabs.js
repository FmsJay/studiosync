// More pages beside Here and Song (daw.js makes the tab bar and those two): window.ssTabs.add(name, label, element, onShow) puts a tab on the
// bar for a page made by another file (health.js, play.js). Showing one hides the main view and the Song page and unpresses the other tabs;
// pressing Here or Song hides ours again. The topics each page reads come with app.js's 'ss-state' event (after the first, only the ones that
// changed), so ssTabs.topics keeps the latest of each for all of them. No framework. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const nav = document.querySelector('nav.tabs'), main = document.querySelector('main');
  const here = nav && nav.querySelector('.tab');
  const ours = [];
  const T = {};
  function take(s, seed) { const t = (s && s.topics) || {}; for (const k in t) if (!(seed && k in T)) T[k] = t[k]; }
  addEventListener('ss-state', (e) => take(e.detail, false));
  // (a page made after the first snapshot went by: what's there now, without overwriting anything newer from the stream)
  fetch('api/state').then((r) => r.json()).then((s) => { take(s, true); dispatchEvent(new CustomEvent('ss-tabs')); }).catch(() => {});

  function hideOurs() {
    for (const o of ours) {
      if (o.page.hidden) continue;
      o.page.hidden = true;
      o.tab.setAttribute('aria-pressed', 'false');
      if (o.onShow) o.onShow(false);
    }
  }
  function show(o) {
    if (here && here.getAttribute('aria-pressed') !== 'true') here.click(); // (daw.js's own: the Song page put away, as Here does)
    hideOurs();
    main.hidden = true;
    if (here) here.setAttribute('aria-pressed', 'false');
    o.page.hidden = false;
    o.tab.setAttribute('aria-pressed', 'true');
    try { localStorage.setItem('ss-page-more', o.name); } catch (e) {}
    if (o.onShow) o.onShow(true);
  }
  if (nav) {
    nav.addEventListener('click', (e) => {
      const t = e.target.closest('.tab');
      if (t && !ours.some((o) => o.tab === t)) { hideOurs(); try { localStorage.removeItem('ss-page-more'); } catch (err) {} }
    }, true);
  }
  window.ssTabs = {
    topics: T,
    act(topic, o) {
      return fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
        body: JSON.stringify(Object.assign({ topic }, o)) }).then((r) => { if (!r.ok) throw new Error(String(r.status)); });
    },
    add(name, label, page, onShow) {
      const tab = document.createElement('button');
      tab.type = 'button';
      tab.className = 'tab';
      tab.textContent = label;
      tab.setAttribute('aria-pressed', 'false');
      page.hidden = true;
      page.classList.add('sspage');
      document.body.append(page);
      const o = { name, tab, page, onShow };
      ours.push(o);
      tab.addEventListener('click', () => show(o));
      if (nav) nav.append(tab);
      let saved = null;
      try { saved = localStorage.getItem('ss-page-more'); } catch (e) {}
      if (saved === name) queueMicrotask(() => show(o)); // (after the page's own file has finished setting itself up)
      return o;
    },
  };
})();
