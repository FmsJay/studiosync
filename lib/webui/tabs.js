// StudioSync's tabs (docs/rt/ui-web-plan.md 2.1, 3.4, 4.4, 4.5; rt-ui1): the nine tabs and their sub-tabs, each shown only where it can
// work (ssEnv.where) and when what it needs is there (a project open, a studio known, the studio's AI on: the env and presence topics); deep
// links (#history/playback); the pop-out route (?pop=chat: that page alone); the "nav" topic (a REAPER action shows a tab in the docked view);
// a "More" menu when the row doesn't fit (a docker); the phone's bottom bar. Pages register with ssTabs.add(name, label, page, onShow, opts) or
// ssTabs.sub(tab, name, label, page, onShow, opts); an older page's ssTabs.add('mixer', ...) lands as Project > Mixer by LEGACY, and what isn't
// built yet shows a "coming" page. Showing a sub calls its onShow(true), hiding it onShow(false), every time. The topics each page reads come
// with app.js's 'ss-state' event (after the first, only the ones that changed), so ssTabs.topics keeps the latest of each. Labels come from
// shell.js's map. No framework. GPL-3.0-or-later. (James, rt; rt-ui1)
'use strict';
(() => {
  const E = window.ssEnv || { where: 'local', reaper: true, phone: false, pop: null, send() {} };
  const L = window.ssLabels || { tab: (r) => r, LABELS: {} };
  const $ = (id) => document.getElementById(id);
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

  // ---- the topics -----------------------------------------------------------------------------------------------------------------------
  const T = {};
  let engine = null, known = false;
  function take(s, seed) {
    if (!s) return;
    if ('engine' in s && !(seed && known)) engine = !!s.engine;
    known = true;
    const t = s.topics || {};
    for (const k in t) if (!(seed && k in T)) T[k] = t[k];
  }
  addEventListener('ss-state', (e) => { take(e.detail, false); refresh(); });
  // (a page made after the first snapshot went by: what's there now, without overwriting anything newer from the stream)
  fetch('api/state').then((r) => r.json()).then((s) => { take(s, true); refresh(); dispatchEvent(new CustomEvent('ss-tabs')); }).catch(() => {});

  // ---- the tabs (2.1, 3.4) --------------------------------------------------------------------------------------------------------------
  const ALL = ['reaper', 'local', 'remote'], HERE = ['reaper', 'local'];
  // name, what it needs, its sub-tabs in order (the first built one opens by default)
  const TABS = [
    ['studio', [], ['overview']],
    ['session', ['project'], ['here', 'play', 'rooms']],
    ['project', ['project'], ['arrange', 'mixer', 'sheet', 'beat']],
    ['chat', ['studio'], ['chat']],
    ['history', ['project'], ['changes', 'versions', 'playback', 'mixes']],
    ['plugins', ['project'], ['project', 'try', 'find', 'pack']],
    ['ai', ['ai'], ['ai']],
    ['health', [], ['checks', 'log', 'updates']],
    ['settings', [], ['you', 'computer', 'studio', 'devices', 'advanced']],
  ];
  // (only on this computer, in REAPER or its browser: they reach this REAPER's windows, files and plug-ins, or change the studio, 3.4)
  const ENVS = { 'plugins/try': HERE, 'plugins/find': HERE, 'health/log': HERE, 'health/updates': HERE, 'settings/computer': HERE,
    'settings/studio': HERE, 'settings/devices': HERE, 'settings/advanced': HERE };
  // (the pages from before the shell: their old ssTabs.add names, and where they go now)
  const LEGACY = { play: 'session/play', mixer: 'project/mixer', sheet: 'project/sheet', beat: 'project/beat', history: 'history/playback',
    tryfx: 'plugins/try', health: 'health/checks', ai: 'ai/ai' };
  // (what can pop out into its own window, 4.4)
  const POP = new Set(['chat/chat', 'project/beat', 'project/sheet', 'project/mixer', 'plugins/try']);
  // (where each part not built here yet is meanwhile)
  const COMING = { 'session/rooms': 'the panel’s Rooms page', 'history/changes': 'the panel’s Restore page (every change)',
    'history/versions': 'the panel’s Restore page (saved versions)', 'history/mixes': 'the panel’s Restore page (Mixes)',
    'plugins/project': 'the panel’s Plugins page', 'plugins/find': 'the panel’s Plugins page (Find a plug-in)', 'plugins/pack': 'the panel’s Settings > Extras',
    'health/log': 'the panel’s Settings > Console', 'health/updates': 'the panel’s Settings > Updates', 'settings/you': 'the panel’s Settings > You',
    'settings/computer': 'the panel’s Settings > Look, Options and Advanced', 'settings/studio': 'the panel’s Settings > Studio',
    'settings/devices': 'the panel’s Chat page (Copy phone link)', 'settings/advanced': 'the panel’s Settings > Advanced' };
  const NEEDS = { project: (c) => c.project, studio: (c) => c.studio, ai: (c) => c.ai, reaper: () => E.reaper };

  // -> what the tabs may need, now. Before the first state everything counts as there (no flash of a bare Studio on a reload).
  function ctx() {
    if (!known) return { project: true, studio: true, ai: true };
    const e = T.env, p = T.presence;
    const project = !!engine && !!((e && e.front && e.front.project) || (p && p.song));
    return { project, studio: project || (!!engine && !!(e && e.studio)), ai: !!(e ? e.ai : T.ai && T.ai.on) };
  }
  const needOk = (need, c) => need.every((n) => (NEEDS[n] ? NEEDS[n](c) : !!c[n]));
  const subOk = (s, c) => s.envs.includes(E.where) && needOk(s.need, c);
  const tabOk = (t, c) => t.envs.includes(E.where) && needOk(t.need, c) && t.subs.some((s) => subOk(s, c));

  // ---- the row, the pages' place, the More menu -----------------------------------------------------------------------------------------
  let nav = $('sstabs');
  if (!nav) { nav = mk('nav', 'tabs sstabs'); nav.setAttribute('aria-label', 'Pages'); const hd = document.querySelector('header'); if (hd) hd.after(nav); else document.body.prepend(nav); }
  const pages = $('sspages') || document.body;
  const more = mk('button', 'tab ssmore', 'More ▾');
  more.type = 'button';
  more.hidden = true;
  more.setAttribute('aria-haspopup', 'menu');
  nav.append(more);
  const menu = mk('div', 'ssmenulist');
  menu.setAttribute('role', 'menu');
  menu.hidden = true;
  document.body.append(menu);

  const tabs = new Map();
  let cur = '', wanted = '', started = false;
  function newTab(name, o) {
    const t = { name, need: o.need || [], envs: o.envs || ALL, order: o.order != null ? o.order : 100 + tabs.size, subs: [], cur: null,
      label: L.LABELS[name] || o.label || name };
    t.btn = mk('button', 'tab', t.label);
    t.btn.type = 'button';
    t.btn.dataset.tab = name;
    t.btn.setAttribute('aria-pressed', 'false');
    t.btn.addEventListener('click', () => go(name, true));
    t.el = mk('div', 'sstab'); // (not a section: style.css pads those)
    t.el.setAttribute('role', 'region');
    t.el.dataset.tab = name;
    t.el.setAttribute('aria-label', t.label);
    t.el.hidden = true;
    t.bar = mk('div', 'sssubs');
    t.bar.setAttribute('role', 'toolbar');
    t.bar.setAttribute('aria-label', t.label);
    t.el.append(t.bar);
    tabs.set(name, t);
    for (const x of [...tabs.values()].sort((a, z) => a.order - z.order)) { nav.insertBefore(x.btn, more); pages.append(x.el); }
    return t;
  }
  TABS.forEach(([name, need], i) => newTab(name, { need, order: i }));

  function sub(tab, name, label, page, onShow, o) {
    o = o || {};
    const t = tabs.get(tab) || newTab(tab, { label });
    const route = tab + '/' + name;
    let s = t.subs.find((x) => x.name === name);
    if (s) { if (s.page !== page) { hideSub(s); s.page.remove(); } }
    else {
      const decl = (TABS.find((x) => x[0] === tab) || [0, 0, []])[2].indexOf(name);
      s = { name, route, order: o.order != null ? o.order : decl >= 0 ? decl : 50 + t.subs.length, shown: false };
      s.btn = mk('button', 'sssub-b');
      s.btn.type = 'button';
      s.btn.setAttribute('aria-pressed', 'false');
      s.btn.addEventListener('click', () => go(route, true));
      t.subs.push(s);
      t.subs.sort((a, z) => a.order - z.order);
      for (const x of t.subs) t.bar.append(x.btn);
    }
    Object.assign(s, { label: L.LABELS[route] || label || name, page, onShow: onShow || null, envs: o.envs || ENVS[route] || ALL, need: o.need || [],
      coming: !!o.coming, shown: false });
    s.btn.textContent = s.label;
    page.hidden = true;
    page.classList.add('sssub');
    t.el.append(page);
    if (started) { drawn = ''; if (cur === route) { cur = ''; go(route, false); } refresh(); }
    return s;
  }

  // ---- showing --------------------------------------------------------------------------------------------------------------------------
  function call(s, on) { if (s.onShow) try { s.onShow(on); } catch (e) { console.error(e); } }
  function showSub(s) {
    s.btn.setAttribute('aria-pressed', 'true');
    if (s.shown) return;
    s.page.hidden = false;
    s.shown = true;
    call(s, true);
  }
  function hideSub(s) {
    s.btn.setAttribute('aria-pressed', 'false');
    s.page.hidden = true;
    if (s.shown) { s.shown = false; call(s, false); }
  }
  function hideTab(t) { t.el.hidden = true; for (const s of t.subs) hideSub(s); }
  function pickSub(t, name, c) {
    return t.subs.find((s) => s.name === name && subOk(s, c)) || t.subs.find((s) => s.name === t.cur && subOk(s, c))
      || t.subs.find((s) => !s.coming && subOk(s, c)) || t.subs.find((s) => subOk(s, c));
  }
  const split = (r) => { r = String(r || ''); const i = r.indexOf('/'); return i < 0 ? [r, ''] : [r.slice(0, i), r.slice(i + 1)]; };
  function canShow(r, c) {
    const [tn, sn] = split(r), t = tabs.get(tn);
    return !!t && tabOk(t, c) && (!sn || t.subs.some((s) => s.name === sn && subOk(s, c)));
  }
  // user: a choice (a click, a link, a REAPER action), remembered: it comes back when its tab can show again (a project reopened)
  function go(r, user) {
    const [tn, sn] = split(r), t = tabs.get(tn), c = ctx();
    if (user && t) wanted = r;
    if (!t || !tabOk(t, c)) return false;
    const s = pickSub(t, sn, c);
    for (const o of tabs.values()) if (o !== t) hideTab(o);
    for (const x of t.subs) if (x !== s) hideSub(x);
    t.el.hidden = false;
    t.cur = s.name;
    showSub(s);
    const was = cur;
    cur = s.route;
    if (user) wanted = cur;
    try { localStorage.setItem('ss-route', cur); } catch (e) {}
    if (!E.pop && location.hash !== '#' + cur) history.replaceState(null, '', location.pathname + location.search + '#' + cur);
    render();
    if (was !== cur) dispatchEvent(new CustomEvent('ss-route', { detail: cur }));
    return true;
  }
  const order = () => [...tabs.values()].sort((a, z) => a.order - z.order);
  // (a pop-out another file owns, e.g. call.js's ?pop=share: no tab shows in it)
  const foreignPop = () => !!E.pop && !tabs.has(split(E.pop)[0]);
  function refresh() {
    if (!started || foreignPop()) return;
    navTopic();
    const c = ctx(), t = tabs.get(split(cur)[0]);
    if (wanted && wanted !== cur && canShow(wanted, c)) go(wanted, true);
    else if (!t || !tabOk(t, c)) { const f = order().find((x) => tabOk(x, c)); if (f) go(f.name, false); }
    else if (!t.subs.some((s) => s.route === cur && subOk(s, c))) go(t.name, false);
    else render();
  }

  // ---- drawing the row, the sub-tabs, More, the phone's bar -----------------------------------------------------------------------------
  const railQ = matchMedia('(min-width: 900px) and (orientation: landscape)');
  const rail = () => railQ.matches && !E.pop && !E.phone && !!nav.closest('.ssbody'); // (a page without index.html's layout keeps the row)
  let drawn = '';
  function render(force) {
    const c = ctx(), h = T.env && T.env.health, ct = split(cur)[0];
    // (the stream brings topics many times a second: the row is laid out again only when something it shows changed)
    const key = [c.project, c.studio, c.ai, h, cur, innerWidth].join();
    if (!force && key === drawn) return;
    drawn = key;
    document.body.classList.toggle('ssrail', rail());
    for (const t of tabs.values()) {
      t.btn.hidden = !tabOk(t, c);
      delete t.btn.dataset.more;
      t.btn.setAttribute('aria-pressed', String(t.name === ct));
      let n = 0;
      for (const s of t.subs) { s.btn.hidden = !subOk(s, c); if (!s.btn.hidden) n++; }
      t.bar.hidden = n < 2;
    }
    const hb = tabs.get('health').btn;
    hb.classList.toggle('ssred', h === 'red');
    hb.classList.toggle('ssyellow', h === 'yellow');
    hb.title = h === 'red' ? 'Something needs fixing' : h === 'yellow' ? 'Something is worth a look' : '';
    fit();
    phoneBar(c);
  }
  // (a docker too narrow for the row: the last tabs go into More, the open one named on it)
  function fit() {
    more.hidden = true;
    if (E.pop || E.phone || rail() || !nav.clientWidth) return;
    if (nav.scrollWidth <= nav.clientWidth + 1) return;
    more.hidden = false;
    const vis = order().filter((t) => !t.btn.hidden);
    for (let i = vis.length - 1; i > 0 && nav.scrollWidth > nav.clientWidth + 1; i--) { vis[i].btn.hidden = true; vis[i].btn.dataset.more = '1'; }
    const inMore = vis.find((t) => t.btn.dataset.more && t.name === split(cur)[0]);
    more.textContent = (inMore ? inMore.label : 'More') + ' ▾';
    more.setAttribute('aria-pressed', String(!!inMore));
  }
  addEventListener('resize', () => render(true));
  function openMenu(list, anchor) {
    menu.replaceChildren(...list.map((t) => {
      const b = mk('button', '', t.label);
      b.type = 'button';
      b.setAttribute('role', 'menuitem');
      if (t.name === split(cur)[0]) b.setAttribute('aria-current', 'page');
      b.addEventListener('click', () => { menu.hidden = true; go(t.name, true); });
      return b;
    }));
    const r = anchor.getBoundingClientRect();
    menu.style.left = Math.max(4, Math.min(innerWidth - 224, Math.round(r.left))) + 'px';
    if (E.phone) { menu.style.top = ''; menu.style.bottom = Math.round(innerHeight - r.top + 4) + 'px'; }
    else { menu.style.bottom = ''; menu.style.top = Math.round(r.bottom + 4) + 'px'; }
    menu.hidden = false;
  }
  more.addEventListener('click', (e) => { e.stopPropagation(); if (!menu.hidden) { menu.hidden = true; return; } openMenu(order().filter((t) => t.btn.dataset.more), more); });
  addEventListener('click', (e) => { if (!menu.hidden && !menu.contains(e.target)) menu.hidden = true; });
  addEventListener('keydown', (e) => { if (e.key === 'Escape') menu.hidden = true; });

  // The phone (another device under 700 px): Session, Project, Record (the phone's own page), Chat, More at the bottom; Studio in Session's
  // place while no project is open.
  const bar = $('ssbar');
  const barBtns = {};
  let barMore = null;
  function phoneBar(c) {
    const on = !!E.phone && !E.pop;
    document.body.classList.toggle('ssphone', on);
    if (!bar) return;
    bar.hidden = !on;
    if (!on) return;
    if (!barMore) {
      for (const name of ['studio', 'session', 'project', 'record', 'chat']) {
        const b = name === 'record' ? mk('a', 'ssbarb', 'Record') : mk('button', 'ssbarb', tabs.get(name).label);
        if (name === 'record') { b.href = 'record.html'; b.title = 'Record a take from this phone into the project'; } else { b.type = 'button'; b.addEventListener('click', () => go(name, true)); }
        bar.append(b);
        barBtns[name] = b;
      }
      barMore = mk('button', 'ssbarb', 'More');
      barMore.type = 'button';
      barMore.addEventListener('click', (e) => {
        e.stopPropagation();
        if (!menu.hidden) { menu.hidden = true; return; }
        const now = ctx();
        openMenu(order().filter((t) => tabOk(t, now) && !(barBtns[t.name] && !barBtns[t.name].hidden)), barMore);
      });
      bar.append(barMore);
    }
    const ct = split(cur)[0];
    for (const name of ['session', 'project', 'chat']) barBtns[name].hidden = !tabOk(tabs.get(name), c);
    barBtns.studio.hidden = !barBtns.session.hidden;
    barBtns.record.hidden = !c.project;
    for (const name in barBtns) barBtns[name].setAttribute('aria-pressed', String(name === ct));
  }

  // ---- the nav topic: a REAPER action (or Open in REAPER) shows a tab in the docked view; fresh ones only (5 s) --------------------------
  let navSeen = null;
  function navTopic() {
    const n = T.nav;
    if (!n || n.id === navSeen) return;
    navSeen = n.id;
    if (E.where !== 'reaper' || E.pop || Math.abs(Date.now() / 1000 - n.at) > 5) return;
    go(n.sub ? n.page + '/' + n.sub : n.page, true);
    if (n.wake && window.ssShell) { ssShell.setWin(''); E.send('win:full'); }
  }

  // ---- pop-outs (4.4) -------------------------------------------------------------------------------------------------------------------
  const canPop = (r) => POP.has(r) || POP.has(r + '/' + r);
  function popOut(r) {
    // (no ?t= token: the page's cookie carries it; a REAPER window will catch this and open its own, Phase 8)
    window.open(location.pathname + '?pop=' + encodeURIComponent(r), 'ss-pop-' + r.replace('/', '-'), 'popup,width=480,height=720');
  }

  // ---- placeholders, today's three pages from index.html, and the first page to show -----------------------------------------------------
  function coming(route) {
    const p = mk('section', 'sspage sscoming');
    p.append(mk('h2', '', L.tab(route)), mk('p', '', 'Coming here soon.'));
    const w = COMING[route];
    if (w) p.append(mk('p', 'dim', 'Until then: ' + w + (E.where === 'remote' ? ', in REAPER on the computer serving this page.' : ', in REAPER.')));
    if (route === 'settings/you' && window.ssProfiles && ssProfiles.edit) {
      const b = mk('button', '', 'Your picture, name and colour');
      b.type = 'button';
      b.addEventListener('click', () => ssProfiles.edit());
      p.append(b);
    }
    return p;
  }
  const hashRoute = () => { let h = ''; try { h = decodeURIComponent(location.hash.slice(1)); } catch (e) {} return /^[a-z]+(\/[a-z]+)?$/.test(h) ? h : ''; };
  function start() {
    // (Studio: the studio overview, home.js's column in the first <main>; Session > Who's here: #here, moved out of that column now that
    // home.js has set it up; Chat: the chat's own <main>, so chat.js's "shown" stays its main's hidden)
    const sm = $('studiomain') || document.querySelector('main');
    if (sm && !tabs.get('studio').subs.length) sub('studio', 'overview', null, sm);
    const here = $('here');
    if (here && !tabs.get('session').subs.some((s) => s.name === 'here')) { const w = mk('div', 'sshere'); w.append(here); sub('session', 'here', null, w); }
    const cm = $('chatmain');
    if (cm) sub('chat', 'chat', null, cm);
    for (const [name, , subs] of TABS) {
      const t = tabs.get(name);
      for (const sn of subs) if (!t.subs.some((s) => s.name === sn)) sub(name, sn, null, coming(name + '/' + sn), null, { coming: true });
    }
    started = true;
    if (E.pop) {
      document.body.classList.add('sspop');
      const back = mk('button', 'ssback', 'Back into the main window');
      back.type = 'button';
      back.title = 'Close this window: the page stays in the main one';
      back.addEventListener('click', () => { window.close(); setTimeout(() => { location.href = location.pathname + '#' + cur; }, 200); });
      const hd = document.querySelector('header');
      if (hd) hd.append(back);
    }
    let saved = '';
    try { saved = localStorage.getItem('ss-route') || ''; } catch (e) {}
    if (foreignPop()) return;
    if (!go(E.pop || hashRoute() || saved || 'studio', true)) go('studio', false);
    refresh();
  }
  addEventListener('hashchange', () => { const r = hashRoute(); if (r && r !== cur) go(r, true); });
  // (after every deferred page file has run and registered: readyState is already "interactive" while they run, so not that)
  const once = () => { if (!started) start(); };
  if (document.readyState === 'complete') queueMicrotask(once); else { document.addEventListener('DOMContentLoaded', once); addEventListener('load', once); }

  window.ssTabs = {
    topics: T,
    act(topic, o) {
      return fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
        body: JSON.stringify(Object.assign({ topic }, o)) }).then((r) => { if (!r.ok) throw new Error(String(r.status)); });
    },
    // a page of its own: one of the nine tabs' single page, a new tab (opts: order, envs, need, label), or an older page's name (LEGACY)
    add(name, label, page, onShow, opts) {
      page.classList.add('sspage');
      const r = LEGACY[name] || (opts && opts.parent ? opts.parent + '/' + name : null);
      if (r) { const [t, s] = split(r); return sub(t, s, label, page, onShow, opts); }
      if (!tabs.has(name)) newTab(name, Object.assign({ label }, opts));
      return sub(name, name, label, page, onShow, opts);
    },
    // a sub-tab: ssTabs.sub('history', 'changes', 'Changes', el, (on) => ..., { need: ['project'], envs: ['reaper', 'local'] })
    sub,
    go: (r) => go(r, true),
    route: () => cur,
    shown: (r) => cur === r || split(cur)[0] === r,
    canPop,
    popOut,
    // -> every tab and sub-tab, with whether it can show here now (for the tests and the docs)
    list: () => { const c = ctx(); return order().map((t) => ({ name: t.name, label: t.label, ok: tabOk(t, c), subs: t.subs.map((s) => ({ name: s.name, label: s.label, ok: subOk(s, c), coming: s.coming })) })); },
  };
})();
