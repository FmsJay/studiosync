// StudioSync's shell (docs/rt/ui-web-plan.md 2.1, 2.2, 3.1, 4.2-4.4; rt-ui1), loaded first: where this page runs (window.ssEnv), the one
// label map every page uses (window.ssLabels), the top bar (logo, Studio > Project > Room, the status pill, the window buttons in REAPER,
// the menu) and the window's shape: the whole shell, or a strip or a button (?win=strip|button now; the REAPER window says so itself once
// Phase 8 lands, as {"win": mode}). The tabs are tabs.js. What it shows is only what can work where it runs; the server still refuses what
// a remote page mustn't do. No framework. GPL-3.0-or-later. (rt-ui1)
'use strict';
(() => {
  const $ = (id) => document.getElementById(id);
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const qs = new URLSearchParams(location.search);

  // ---- where this page runs (3.1) --------------------------------------------------------------------------------------------------------
  const host = (window.chrome && window.chrome.webview) || (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.studiosync) || null;
  const as = qs.get('host');
  const inReaper = !!host && (as === 'docked' || as === 'floating');
  const h = location.hostname;
  const where = inReaper ? 'reaper' : (h === '127.0.0.1' || h === 'localhost' || h === '[::1]') ? 'local' : 'remote';
  const narrow = matchMedia('(max-width: 699px)'), coarse = matchMedia('(pointer: coarse)');
  const env = window.ssEnv = {
    where, // 'reaper' (the docked or floating view), 'local' (a browser on this computer), 'remote' (another device on the tailnet)
    host: inReaper ? as : null,
    reaper: where !== 'remote', // (this computer's REAPER is here: its windows, its files, its plug-ins)
    pop: qs.get('pop') || null, // (a popped-out page: index.html?pop=chat, 4.4)
    app: matchMedia('(display-mode: standalone)').matches,
    get device() { return narrow.matches ? 'phone' : coarse.matches && innerWidth < 1100 ? 'tablet' : 'desktop'; },
    get phone() { return where === 'remote' && narrow.matches; }, // (the phone layout: another device, under 700 px, 3.4)
    winModes: false, // (the REAPER window can be a strip, a button or full screen: it said so, Phase 8)
    send(m) { if (host) try { host.postMessage(m); } catch (e) {} },
  };

  // ---- the names (2.2): one word per idea, the same on every page --------------------------------------------------------------------------
  // (tabs and sub-tabs by route; pages ask ssLabels.tab('history/playback'). James's decisions 2026-11-27: these names, and "In control" for driver)
  const LABELS = {
    'studio': 'Studio',
    'session': 'Session',
    'project': 'Project',
    'chat': 'Chat',
    'history': 'History',
    'plugins': 'Plug-ins',
    'ai': 'AI',
    'health': 'Health',
    'settings': 'Settings',
    'studio/overview': 'Studio',
    'session/here': 'Who’s here',
    'session/play': 'Play together',
    'session/rooms': 'Rooms',
    'project/arrange': 'Arrange',
    'project/mixer': 'Mixer',
    'project/sheet': 'Sheet',
    'project/beat': 'Beat',
    'chat/chat': 'Chat',
    'history/changes': 'Changes',
    'history/versions': 'Versions',
    'history/playback': 'Playback',
    'history/mixes': 'Mixes',
    'plugins/project': 'This project',
    'plugins/try': 'Try a bandmate’s',
    'plugins/find': 'Find a plug-in',
    'plugins/pack': 'Plug-in pack',
    'ai/ai': 'AI',
    'health/checks': 'Checks',
    'health/log': 'Log',
    'health/updates': 'Updates',
    'settings/you': 'You',
    'settings/computer': 'This computer',
    'settings/studio': 'Studio',
    'settings/devices': 'Devices',
    'settings/advanced': 'Advanced',
  };
  // (old word, lower case -> the new one: for any page still holding an old one)
  const WORDS = {
    'song': 'Project',
    'group': 'Studio',
    'band': 'Studio',
    'home': 'Session',
    'here': 'Who’s here',
    'play/jam': 'Play together',
    'play and stop together': 'Play together',
    'start together': 'Play together',
    'watch a bandmate': 'Follow',
    'view': 'Follow',
    'watch': 'Follow',
    'restore': 'History',
    'song history': 'History',
    'bounces': 'Mixes',
    'side room': 'Room',
    'driver': 'In control',
    'drives': 'is in control',
    'driving': 'in control',
    'dismiss': 'Hide',
    'show dismissed': 'Show hidden',
    'box': 'Button',
    'pill': 'Button',
    'web ui': 'StudioSync',
    'the panel': 'StudioSync',
    'try': 'Try a bandmate’s',
    'hop': 'Run on a bandmate’s computer',
    'offload': 'Run on a bandmate’s computer',
    'console': 'Log',
  };
  window.ssLabels = { LABELS, WORDS, tab: (route) => LABELS[route] || route, word: (w) => WORDS[String(w).toLowerCase()] || w };

  // ---- light / dark: the system's, or the one picked here --------------------------------------------------------------------------------
  const root = document.documentElement;
  try { const t = localStorage.getItem('ss-theme'); if (t) root.dataset.theme = t; } catch (e) {}
  function flipTheme() {
    const dark = root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'light' : 'dark';
    try { localStorage.setItem('ss-theme', root.dataset.theme); } catch (e) {}
  }
  if ($('theme')) $('theme').addEventListener('click', flipTheme);
  document.body.classList.add('ss-' + where);

  // ---- the topics this file reads (tabs.js keeps them all; this keeps the few it draws from) ---------------------------------------------
  const T = {};
  let engine = null;
  addEventListener('ss-state', (e) => {
    const s = e.detail || {};
    if ('engine' in s) engine = !!s.engine;
    Object.assign(T, s.topics || {});
    draw();
  });
  const nameOf = (u) => (window.ssProfiles ? ssProfiles.name(u) : u);
  const go = (r) => { if (window.ssTabs) ssTabs.go(r); };

  // ---- the top bar: Studio > Project > Room (each opens where it's switched), the status pill ------------------------------------------
  const crumbs = $('where');
  if ($('sslogo')) $('sslogo').addEventListener('click', () => go('studio'));
  function crumb(text, route, title) {
    const b = mk('button', 'sscrumb', text);
    b.type = 'button';
    b.title = title;
    b.addEventListener('click', () => go(route));
    return b;
  }
  let crumbKey = null;
  function drawCrumbs() {
    if (!crumbs) return;
    const e = T.env || {}, f = e.front || {}, p = T.presence || {};
    const studio = e.studio || (T.home && T.home.studio) || null;
    const project = engine ? f.project || p.song || null : null, room = engine ? f.room || p.room || null : null;
    const key = [studio, project, room].join('\n');
    if (key === crumbKey) return;
    crumbKey = key;
    crumbs.replaceChildren();
    if (studio) crumbs.append(crumb(studio, 'studio', 'Your studios and projects'));
    if (project) crumbs.append(mk('span', 'sssep', '▸'), crumb(project, 'project', 'This project'));
    if (project && room && room !== 'main') crumbs.append(mk('span', 'sssep', '▸'), crumb(room, 'session/rooms', 'Rooms'));
  }
  const pill = $('sspill');
  function pillText() {
    const e = T.env || {}, f = e.front || {}, tr = e.transport || {}, pl = T.play || {};
    if (f.loading) return ['Loading ' + (f.name || 'the project') + '…', 'wait'];
    if (!engine) return null;
    if (tr.recording) return ['Recording', 'rec'];
    if (pl.state === 'live' && pl.mate) return ['Following ' + nameOf(pl.mate), 'follow'];
    if (tr.playing) return ['Playing', 'ok'];
    return null;
  }
  // (while REAPER loads the project, nothing can be pressed on the pages: findings item 14)
  const loadNote = mk('div', 'ssloadnote');
  loadNote.setAttribute('role', 'status');
  loadNote.hidden = true;
  if (crumbs) document.querySelector('header').after(loadNote);
  function draw() {
    drawCrumbs();
    const pt = pillText();
    if (pill) { pill.hidden = !pt; if (pt) { pill.textContent = pt[0]; pill.className = 'conn sspill ' + pt[1]; } }
    const f = (T.env && T.env.front) || {};
    document.body.classList.toggle('ssloading', !!f.loading);
    loadNote.hidden = !f.loading;
    if (f.loading) loadNote.textContent = 'Loading ' + (f.name || 'the project') + (f.tracks ? ' (' + f.tracks + ' tracks)' : '') + '… everything here waits until REAPER has it open.';
    drawStrip();
  }

  // ---- the window buttons (REAPER only) and the menu -----------------------------------------------------------------------------------
  const winBtns = [];
  // (a pop-out window in REAPER has no ?host=, and Dock / Undock keeps the page: the window's own message says which, rt-ui8)
  const dockBtn = host && $('dock');
  const dockLabel = (docked) => {
    dockBtn.textContent = docked ? 'Undock' : 'Dock';
    dockBtn.title = docked ? 'Float this in its own window' : 'Put this in a REAPER docker';
  };
  if (dockBtn) {
    const b = dockBtn;
    dockLabel(as === 'docked');
    b.hidden = !inReaper;
    b.addEventListener('click', () => env.send('dock'));
    // (strip, button, full screen: the window does these once the extension can, Phase 8; until it says so they stay hidden)
    for (const [mode, text, tip] of [['strip', '▁', 'Shrink to the strip'], ['button', '▢', 'Shrink to the button'], ['fullscreen', '⛶', 'Full screen']]) {
      const w = mk('button', 'ssico', text);
      w.type = 'button';
      w.title = tip;
      w.setAttribute('aria-label', tip);
      w.hidden = true;
      w.addEventListener('click', () => env.send('win:' + mode));
      b.before(w);
      winBtns.push(w);
    }
  }
  const menuBtn = $('ssmenu');
  const menu = mk('div', 'ssmenulist');
  menu.setAttribute('role', 'menu');
  menu.hidden = true;
  document.body.append(menu);
  const route = () => (window.ssTabs ? ssTabs.route() : 'studio').split('/');
  function item(text, fn) {
    const b = mk('button', '', text);
    b.type = 'button';
    b.setAttribute('role', 'menuitem');
    b.addEventListener('click', () => { closeMenu(); fn(); });
    return b;
  }
  function act(o) { if (window.ssTabs) ssTabs.act('nav', o).catch(() => {}); }
  function items() {
    const out = [];
    if (where === 'local') out.push(item('Open in REAPER', () => { const [page, sub] = route(); act({ to: 'reaper', page, sub }); }));
    if (where === 'reaper') out.push(item('Open in the browser', () => { const [page, sub] = route(); act({ to: 'browser', page, sub }); }));
    const r = route().join('/');
    if (!env.pop && window.ssTabs && ssTabs.canPop(r)) out.push(item('Pop out this page', () => ssTabs.popOut(r)));
    return out;
  }
  function closeMenu() { menu.hidden = true; if (menuBtn) menuBtn.setAttribute('aria-expanded', 'false'); }
  if (menuBtn) {
    menuBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      if (!menu.hidden) return closeMenu();
      const list = items();
      if (!list.length) list.push(mk('p', 'dim', 'Nothing more here.'));
      menu.replaceChildren(...list);
      const r = menuBtn.getBoundingClientRect();
      menu.style.top = Math.round(r.bottom + 4) + 'px';
      menu.style.right = Math.round(innerWidth - r.right) + 'px';
      menu.hidden = false;
      menuBtn.setAttribute('aria-expanded', 'true');
    });
    // (a remote device has nothing in it but Pop out: the button shows only where a page can pop)
    if (where === 'remote') addEventListener('ss-route', () => { menuBtn.hidden = !!env.pop || !ssTabs.canPop(ssTabs.route()); });
  }
  addEventListener('click', (e) => { if (!menu.hidden && !menu.contains(e.target)) closeMenu(); });
  addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMenu(); });

  // ---- the window's shape: the whole shell, the strip or the button (4.2) -------------------------------------------------------------------
  const strip = mk('div', 'ssstrip');
  strip.hidden = true;
  const sLogo = mk('img', 'sslogoimg');
  sLogo.src = 'icon.svg'; sLogo.alt = 'StudioSync'; sLogo.width = 20; sLogo.height = 20;
  sLogo.draggable = false; // (a press on it moves the window, not a picture: rt-ui8)
  const sDot = mk('span', 'ssdot'), sWords = mk('span', 'sswords'), sFollow = mk('button', '', 'Follow'), sOpen = mk('button', '', 'Open');
  sFollow.type = sOpen.type = 'button';
  sFollow.title = 'Follow someone: Session > Play together';
  const sBadge = mk('b', 'ssbadge');
  strip.append(sLogo, sDot, sWords, sFollow, sOpen, sBadge);
  document.body.append(strip);
  const full = () => { setWin(''); env.send('win:full'); };
  sOpen.addEventListener('click', full);
  sFollow.addEventListener('click', () => { go('session/play'); full(); });
  strip.addEventListener('click', (e) => { if (document.body.dataset.win === 'button' && e.target !== sFollow) full(); });
  strip.addEventListener('contextmenu', (e) => { if (document.body.dataset.win === 'button') { e.preventDefault(); env.send('win:menu'); } });
  // (a press on the strip or the button, off its buttons: the REAPER window follows the mouse till it's let go, rt-ui8)
  strip.addEventListener('mousedown', (e) => { if (e.button === 0 && e.target !== sFollow && e.target !== sOpen) env.send('win:drag'); });
  // -> the strip's words (sync, who's in control, following, unread, Health) and the button's count
  function stripWords() {
    const e = T.env || {}, p = T.presence || {}, pl = T.play || {}, hm = T.home || {};
    const w = [engine ? 'Sync on' : 'Sync off'];
    if (engine && p.driver) w.push(nameOf(p.driver) + ' in control');
    if (pl.state === 'live' && pl.mate) w.push('Following ' + nameOf(pl.mate));
    if (e.transport && e.transport.recording) w.push('Recording');
    if (hm.unread) w.push(hm.unread + (hm.unread === 1 ? ' new message' : ' new messages'));
    if (e.health === 'red') w.push('Health needs you');
    return { words: w.join(' · '), count: (hm.unread || 0) + (e.health === 'red' ? 1 : 0), ok: !!engine && e.health !== 'red' };
  }
  function drawStrip() {
    if (strip.hidden) return;
    const s = stripWords();
    sWords.textContent = s.words;
    sDot.className = 'ssdot ' + (s.ok ? 'ok' : 'bad');
    strip.classList.toggle('off', !engine);
    sBadge.hidden = !s.count;
    sBadge.textContent = s.count > 99 ? '99+' : String(s.count);
    strip.title = s.words;
  }
  function setWin(mode) {
    mode = mode === 'strip' || mode === 'button' ? mode : '';
    if (mode) document.body.dataset.win = mode; else delete document.body.dataset.win;
    strip.hidden = !mode;
    drawStrip();
  }
  // (the REAPER window, Phase 8: {"win": "strip" | "button" | "full" | ..., "focus": bool}; WebView2's message, or ssShell.fromHost elsewhere)
  function fromHost(m) {
    if (typeof m === 'string') { try { m = JSON.parse(m); } catch (e) { return; } }
    if (!m || typeof m !== 'object' || typeof m.win !== 'string') return;
    env.winModes = true;
    for (const w of winBtns) w.hidden = false;
    if (dockBtn && typeof m.docked === 'boolean') { dockLabel(m.docked); dockBtn.hidden = false; env.host = m.docked ? 'docked' : 'floating'; }
    env.winPop = m.pop === true; // (window.open of a ?pop= page opens a REAPER window here)
    setWin(m.win);
  }
  if (host && host.addEventListener) host.addEventListener('message', (e) => fromHost(e.data));
  setWin(qs.get('win'));

  window.ssShell = { setWin, fromHost, flipTheme, words: stripWords };
})();
