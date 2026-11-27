// StudioSync's Home page for the studio: the studio's projects with who worked on each last, when and what; who's online and where; what's
// for you (mentions, to-dos that name you, this project's unread count); new takes and bounces; this room's last session; open any project
// here. Read from the "home" topic lib/webhome.lua builds while a page shows Home (it says so every 10 s); avatars and display names from
// profile.js. Sits in the Home view's left column above Who's here (moved in beside it), the chat stays on the right. A notification for a
// new message or mention when you allow them and the page is in the background (browsers allow it on this computer's own address only).
// Over the phone link (plain http: no browser notifications) a new mention shows as a banner and a short buzz, and the tab title counts new ones.
// A status line of your own ("back at 8") shows to everyone in Online now; each project says how many changes by others came in since this
// browser last had it in front. Everything a bandmate wrote goes in as text, never HTML. GPL-3.0-or-later. (James, rt; rt-p5)
'use strict';
(() => {
  const main = document.querySelector('main'), here = document.getElementById('here');
  if (!main || !here || !window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const P = () => window.ssProfiles;
  const nameOf = (u) => (P() ? P().name(u) : u);
  const av = (u, px) => (P() ? P().avatar(u, px) : mk('span'));

  // ---- the column: Home's cards, then Who's here ---------------------------------------------------------------------------------------
  const col = mk('div', 'hcol');
  const page = mk('section', 'home');
  page.id = 'home';
  page.setAttribute('aria-labelledby', 'home-h');
  main.prepend(col);
  col.append(page, here);
  main.classList.add('has-home');
  const head = mk('div', 'hhead');
  const meBtn = mk('button', 'hme');
  meBtn.type = 'button';
  meBtn.title = 'Your profile: picture, display name, colour';
  meBtn.setAttribute('aria-label', 'Your profile');
  const greet = mk('div', 'hgreet');
  const hello = mk('h2', 'hhello');
  hello.id = 'home-h';
  const sub = mk('div', 'dim hsub');
  greet.append(hello, sub);
  const notify = mk('button', 'hnotify', 'Notify me');
  notify.type = 'button';
  notify.title = 'A notification for new messages and mentions while this page is in the background';
  notify.hidden = !('Notification' in window) || !window.isSecureContext || Notification.permission !== 'default';
  if (!window.isSecureContext) notify.title = 'Pop-up notifications work on the computer’s own address; over this link a banner and the tab title tell you instead';
  head.append(meBtn, greet, notify);
  // a status line of your own: what others see next to you in Online now for a day
  const statusRow = mk('label', 'hstatusrow');
  const statusIn = mk('input', 'hstatusin');
  statusIn.type = 'text';
  statusIn.maxLength = 60;
  statusIn.placeholder = 'What are you up to? (back at 8, mixing tonight)';
  statusIn.setAttribute('aria-label', 'Your status line, shown to the band for a day');
  statusIn.autocomplete = 'off';
  statusRow.append(statusIn);
  let statusSent = null;
  function sendStatus() {
    const t = statusIn.value.trim();
    if (t === statusSent) return;
    statusSent = t;
    ssTabs.act('profile', { id: 's' + Date.now().toString(36), status: t }).catch(() => { statusSent = null; });
  }
  statusIn.addEventListener('change', sendStatus);
  statusIn.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); sendStatus(); statusIn.blur(); } });
  const banner = mk('div', 'hbanner');
  banner.setAttribute('role', 'status');
  banner.hidden = true;
  const note = mk('div', 'hnote dim');
  note.setAttribute('role', 'status');
  note.hidden = true;
  const air = mk('div', 'hair');
  air.setAttribute('role', 'status');
  air.hidden = true;
  const cards = mk('div', 'hcards');
  page.append(head, statusRow, banner, note, air, cards);
  function card(cls, title) {
    const c = mk('div', 'hcard ' + cls), h = mk('h3', '', title), body = mk('div', 'hbody');
    c.append(h, body);
    cards.append(c);
    return { c, h, body };
  }
  const foryou = card('hfor', 'For you'), onl = card('honline', 'Online now'), proj = card('hprojects', 'Projects'),
    takes = card('htakes', 'New takes'), bnc = card('hbounces', 'Mixes and stems'), last = card('hlast', 'Last session here');
  const hereH = here.querySelector('h2');
  if (hereH) hereH.textContent = 'In this project';
  meBtn.addEventListener('click', () => P() && P().edit());
  notify.addEventListener('click', () => { Notification.requestPermission().then(() => { notify.hidden = Notification.permission !== 'default'; }); });

  // ---- talking to Live sync ------------------------------------------------------------------------------------------------------------
  const onHome = () => !main.hidden && !document.hidden;
  // since you were last here: when this browser last had each project in front (kept here; the computer counts others' changes after it)
  let sinceMap = {};
  try { sinceMap = JSON.parse(localStorage.getItem('ss-home-since') || '{}') || {}; } catch (e) {}
  function stamp() { // (the project in front now counts as seen now)
    if (!H || !H.song || document.hidden) return;
    sinceMap[H.song] = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    const keys = Object.keys(sinceMap);
    if (keys.length > 40) delete sinceMap[keys[0]];
    try { localStorage.setItem('ss-home-since', JSON.stringify(sinceMap)); } catch (e) {}
  }
  const want = () => { if (onHome()) { ssTabs.act('home', { want: true, since: sinceMap }).catch(() => {}); stamp(); } };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', () => { want(); draw(true); });
  new MutationObserver(() => { want(); draw(true); }).observe(main, { attributes: true, attributeFilter: ['hidden'] });

  // ---- words ---------------------------------------------------------------------------------------------------------------------------
  function ago(iso) {
    const t = Date.parse(iso || '');
    if (isNaN(t)) return '';
    const s = Math.max(0, (Date.now() - t) / 1000), d = new Date(t);
    if (s < 60) return 'just now';
    if (s < 3600) return Math.floor(s / 60) + ' min ago';
    if (s < 6 * 3600) return Math.floor(s / 3600) + ' h ago';
    const hm = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    if (d.toDateString() === new Date().toDateString()) return 'today ' + hm;
    if (d.toDateString() === new Date(Date.now() - 86400000).toDateString()) return 'yesterday ' + hm;
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + (s < 7 * 86400 ? ' ' + hm : '');
  }
  const full = (iso) => { const d = new Date(iso || ''); return isNaN(d) ? '' : d.toLocaleString(); };
  function when(iso) { const s = mk('time', 'dim hwhen', ago(iso)); s.dateTime = iso || ''; s.title = full(iso); return s; }
  function hi() {
    const h = new Date().getHours();
    return h < 5 ? 'Late session' : h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
  }
  const where = (song, room) => song + (room ? ' / ' + room : '');
  function who(u) { const s = mk('span', 'hwho'); s.dataset.avUser = u; s.dataset.avSize = '20'; s.append(mk('span', 'hname', nameOf(u))); return s; }
  function empty(body, text) { body.append(mk('p', 'dim hempty', text)); }

  // ---- seen mentions (this browser) and notifications --------------------------------------------------------------------------------
  let seen = '';
  try { seen = localStorage.getItem('ss-home-seen') || ''; } catch (e) {}
  let lastTop = null, lastMention = null, H = null;
  function markSeen() {
    if (!H || !onHome()) return;
    const top = (H.mentions || [])[0];
    if (top && top.time && top.time > seen) { seen = top.time; try { localStorage.setItem('ss-home-seen', seen); } catch (e) {} }
  }
  setInterval(() => { markSeen(); badge(); }, 3000);
  // Where the browser won't pop a notification (plain http over the phone link, or not allowed): a banner on the page and a short buzz.
  const popups = () => 'Notification' in window && window.isSecureContext && Notification.permission === 'granted';
  let bannerT = 0;
  function soft(m) {
    banner.textContent = nameOf(m.user) + ' mentioned you' + (m.where ? ' · ' + m.where : '') + ': ' + m.text;
    banner.hidden = false;
    clearTimeout(bannerT);
    bannerT = setTimeout(() => { banner.hidden = true; }, 12000);
    try { if (navigator.vibrate) navigator.vibrate(120); } catch (e) {}
  }
  banner.addEventListener('click', () => { banner.hidden = true; });
  function notifyNew(h) {
    const top = (h.recent || [])[0], men = (h.mentions || [])[0];
    if (!popups() && lastMention !== null && men && men.id !== lastMention) soft(men);
    const can = popups() && document.hidden;
    if (lastTop !== null && top && top.id !== lastTop && can) {
      const isMen = men && men.id === top.id;
      try { new Notification(nameOf(top.user) + (isMen ? ' mentioned you' : '') + (top.where ? ' · ' + top.where : ''), { body: top.text, tag: 'ss-' + top.id }); } catch (e) {}
    } else if (lastMention !== null && men && men.id !== lastMention && can) {
      try { new Notification(nameOf(men.user) + ' mentioned you', { body: men.text, tag: 'ss-' + men.id }); } catch (e) {}
    }
    lastTop = top ? top.id : ''; lastMention = men ? men.id : '';
  }
  function badge() {
    // (the chat's index counts mentions among its unread already; without it, mentions not yet seen here add to this project's count)
    const n = H ? (H.unread || 0) + (H.unread_by ? 0 : (H.mentions || []).filter((m) => (m.time || '') > seen).length) : 0;
    document.title = (n ? '(' + n + ') ' : '') + 'StudioSync';
    const tab = document.querySelector('nav.tabs .tab');
    if (!tab) return;
    let b = tab.querySelector('.hbadge');
    if (!n) { if (b) b.remove(); return; }
    if (!b) { b = mk('span', 'hbadge'); tab.append(b); }
    b.textContent = n > 99 ? '99+' : String(n);
    b.setAttribute('aria-label', n + ' new for you');
  }

  // ---- drawing -------------------------------------------------------------------------------------------------------------------------
  function open(song, room, btn) {
    btn.disabled = true;
    btn.textContent = 'Opening…';
    ssTabs.act('home', { open: { song, room: room || 'main' } }).catch(() => { btn.textContent = 'Couldn’t reach Live sync'; })
      .finally(() => setTimeout(() => { btn.disabled = false; btn.textContent = btn.dataset.label; }, 4000));
  }
  function openBtn(p) {
    if (p.current) {
      const b = mk('button', 'hopen hcur', 'Project view');
      b.type = 'button';
      b.title = 'The shared arrange view of this project';
      b.addEventListener('click', () => ssTabs.go('project/arrange')); // (the shell's Project > Arrange: tabs.js, rt-ui1)
      return b;
    }
    const b = mk('button', 'hopen', p.open ? 'Switch to it' : 'Open');
    b.type = 'button';
    b.dataset.label = b.textContent;
    b.title = p.open ? 'It’s open in another tab here: bring it to the front' : 'Open it in REAPER on this computer';
    b.addEventListener('click', () => open(p.name, null, b));
    return b;
  }
  let lastH = null, lastP = null;
  function draw(force) {
    const h = ssTabs.topics.home, prof = ssTabs.topics.profiles;
    if (!force && h === lastH && prof === lastP) return;
    lastH = h; lastP = prof; H = h || null;
    const me = (h && h.me) || (prof && prof.me) || '';
    // the head
    meBtn.replaceChildren(me ? av(me, 40) : mk('span', 'av', '?'));
    hello.textContent = hi() + (me ? ', ' + nameOf(me) : '');
    sub.textContent = h ? [h.studio, h.song ? 'in ' + where(h.song, h.room) : null].filter(Boolean).join(' · ') : '';
    if (!h) { cards.hidden = true; air.hidden = true; if (onHome()) sub.textContent = 'Asking Live sync…'; badge(); return; }
    cards.hidden = false;
    note.hidden = !h.opened;
    if (h.opened) note.textContent = (h.opened.said ? h.opened.said : 'Opening ' + where(h.opened.song, h.opened.room) + ' on that computer…');
    // (your own status, unless you're typing one)
    const mine = prof && prof.people && prof.people[me];
    if (document.activeElement !== statusIn && statusIn.value !== ((mine && mine.status) || '')) { statusIn.value = (mine && mine.status) || ''; statusSent = statusIn.value; }
    if (h.error) sub.textContent = 'Home couldn’t be read here: ' + h.error;
    // on air: anyone recording or playing anywhere
    const rec = (h.online || []).filter((x) => x.rec), play = (h.online || []).filter((x) => x.play && !x.rec);
    air.hidden = !rec.length && !play.length;
    air.className = 'hair' + (rec.length ? ' rec' : ' play');
    air.textContent = rec.length ? 'On air: ' + rec.map((x) => nameOf(x.user) + ' recording in ' + where(x.song, x.room)).join(', ')
      : play.map((x) => nameOf(x.user) + ' is playing ' + where(x.song, x.room)).join(', ');
    // for you
    const f = foryou.body;
    f.replaceChildren();
    if (h.unread) {
      const by = (h.unread_by || []).map((c) => (c.kind === 'ch' ? '#' : '') + c.name + ' ' + c.n).join(' · ');
      const u = mk('button', 'hunread', h.unread + (h.unread === 1 ? ' unread message' : ' unread messages') + (h.unread_by ? '' : ' in this project')
        + (h.unread_at ? ' (' + h.unread_at + ' mention' + (h.unread_at === 1 ? '' : 's') + ' of you)' : ''));
      if (by) u.append(mk('span', 'dim hby', by));
      u.type = 'button';
      u.title = 'Since you last read them';
      u.addEventListener('click', () => { ssTabs.go('chat'); const t = document.getElementById('text'); if (t) t.focus(); }); // (the Chat tab: rt-ui1)
      f.append(u);
    }
    if ((h.mentions || []).length) {
      f.append(mk('h4', '', 'Mentions'));
      const ul = mk('ul', 'hlist');
      for (const m of h.mentions) {
        const li = mk('li', (m.time || '') > seen ? 'new' : '');
        const top = mk('div', 'hline');
        top.append(who(m.user), m.where ? mk('span', 'dim hwhere', m.where) : '', when(m.time));
        li.append(top, mk('div', 'hmtext', m.text));
        ul.append(li);
      }
      f.append(ul);
    }
    if ((h.todos || []).length) {
      f.append(mk('h4', '', 'To-dos for you'));
      const ul = mk('ul', 'hlist');
      for (const d of h.todos) {
        const li = mk('li');
        const top = mk('div', 'hline');
        top.append(mk('span', 'htodo', '☐'), mk('span', 'hmtext', d.text));
        li.append(top, mk('div', 'dim hmeta', 'from ' + nameOf(d.user) + (d.where ? ' · ' + d.where : '') + ' · ' + ago(d.time)));
        ul.append(li);
      }
      f.append(ul);
    }
    if (!f.childNodes.length) empty(f, 'All caught up. Mention someone with @name in the chat, or put @name in a to-do to give it to them.');
    // online
    const o = onl.body;
    o.replaceChildren();
    const others = (h.online || []).filter((x) => !x.me);
    const chips = mk('ul', 'hchips');
    for (const x of h.online || []) {
      const li = mk('li', 'hchip' + (x.me ? ' me' : '') + (x.rec ? ' rec' : x.play ? ' play' : '') + (x.away ? ' away' : ''));
      li.append(who(x.user));
      const other = x.me && x.user !== me; // (another of your computers: lib/persons.lua, rt-people)
      li.append(mk('span', 'dim hwhere', where(x.song, x.room) + (x.me ? ' (you' + (other ? ', on ' + x.user : x.away ? ', another tab' : '') + ')' : x.away ? ' (away)' : '')));
      // (one entry a person: their other places and computers under it, rt-people)
      const also = (x.devices || []).slice(1).map((d) => (d.user !== x.user ? d.user + ': ' : '') + where(d.song, d.room) + (d.rec ? ' (recording)' : d.play ? ' (playing)' : ''));
      if (also.length) li.append(mk('span', 'dim halso', 'also ' + also.join(', ')));
      const st = prof && prof.people && prof.people[x.user] && prof.people[x.user].status;
      if (st) { const sp = mk('span', 'hstatus', '“' + st + '”'); sp.title = 'Their status line'; li.append(sp); }
      li.title = x.rec ? 'recording' : x.play ? 'playing' : x.away ? 'StudioSync is open but another tab is in front' : 'here';
      chips.append(li);
    }
    o.append(chips);
    if (!others.length) empty(o, 'Nobody else is online right now.');
    // your computers: which of the studio's computers are yours (each says so of the other, then they show as one person: lib/persons.lua)
    const cs = (h.computers || []).filter((c) => c.state !== 'this');
    if (cs.length) {
      const det = mk('details', 'hcomputers');
      const sum = mk('summary', 'dim', 'Your computers');
      det.append(sum);
      if (cs.some((c) => c.state === 'asks')) { det.open = true; sum.textContent = 'Your computers: one says it’s yours'; }
      const STATE = { yours: 'yours: shows as you', waiting: 'yours: waiting for it to say the same', asks: 'says it’s yours', other: '' };
      const ul = mk('ul', 'hlist');
      for (const c of cs) {
        const li = mk('li', 'hline');
        li.append(mk('span', 'hname', c.user), mk('span', 'dim', STATE[c.state] || ''));
        const mine = c.state === 'yours' || c.state === 'waiting';
        const b = mk('button', 'hopen', mine ? 'Not mine' : 'Mine too');
        b.type = 'button';
        b.title = mine ? 'It isn’t one of your computers' : 'It’s one of your computers: say the same on it, and the band sees one person';
        b.addEventListener('click', () => { b.disabled = true; ssTabs.act('home', { computer: { user: c.user, on: !mine } }).catch(() => {}).finally(() => setTimeout(want, 500)); });
        li.append(b);
        ul.append(li);
      }
      det.append(ul);
      o.append(det);
    }
    // projects
    const pl = proj.body;
    pl.replaceChildren();
    const ul = mk('ul', 'hprojlist');
    for (const p of h.projects || []) {
      const li = mk('li', 'hproj' + (p.current ? ' current' : ''));
      const top = mk('div', 'hptop');
      const nm = mk('span', 'hpname', p.name);
      top.append(nm);
      if (p.stage) top.append(mk('span', 'hstage s-' + String(p.stage).toLowerCase(), p.stage));
      if (p.current) top.append(mk('span', 'badge drv', 'you’re here'));
      const faces = mk('span', 'hfaces');
      for (const x of p.online || []) {
        const fspan = mk('span', 'hface' + (x.rec ? ' rec' : ''));
        fspan.append(av(x.user, 22));
        fspan.title = nameOf(x.user) + (x.room ? ' in ' + x.room : '') + (x.rec ? ', recording' : x.play ? ', playing' : '');
        faces.append(fspan);
      }
      top.append(faces, openBtn(p));
      li.append(top);
      if (p.last) {
        const ln = mk('div', 'hplast');
        if (p.last.user) ln.append(who(p.last.user));
        ln.append(mk('span', 'hwhat', (p.last.what || 'worked on it') + (p.last.room && p.last.room !== 'main' ? ' (' + p.last.room + ')' : '')), when(p.last.time));
        li.append(ln);
      } else li.append(mk('div', 'dim hplast', 'Nothing yet.'));
      if (!p.current && p.since > 0) {
        const sn = mk('div', 'hsince', (p.since >= 40 ? '40+' : p.since) + (p.since === 1 ? ' change' : ' changes') + ' by others since you were last here');
        sn.title = 'Since ' + full(p.since_at);
        li.append(sn);
      }
      ul.append(li);
    }
    pl.append(ul);
    if (!(h.projects || []).length) empty(pl, 'No projects in this studio yet.');
    // takes and bounces
    takes.body.replaceChildren();
    const tl = mk('ul', 'hlist');
    for (const t of h.takes || []) {
      const li = mk('li');
      const top = mk('div', 'hline');
      top.append(who(t.user), mk('span', 'hmtext', (t.track ? t.track : 'a take') + ' · ' + where(t.song, t.room !== 'main' ? t.room : null)), when(t.time));
      li.append(top);
      if (t.name) li.append(mk('div', 'dim hmeta', t.name));
      tl.append(li);
    }
    takes.body.append(tl);
    if (!(h.takes || []).length) empty(takes.body, 'No new takes lately.');
    bnc.body.replaceChildren();
    const bl = mk('ul', 'hlist');
    for (const x of h.bounces || []) {
      const li = mk('li');
      const top = mk('div', 'hline');
      if (x.user) top.append(who(x.user));
      top.append(mk('span', 'hkind ' + (x.kind === 'mix' ? 'mix' : 'stems'), x.kind === 'mix' ? 'mix' : 'stems'), mk('span', 'hmtext', x.song), when(x.time));
      li.append(top);
      li.title = x.name;
      bl.append(li);
    }
    bnc.body.append(bl);
    if (!(h.bounces || []).length) empty(bnc.body, 'No mixes or stems yet: Render mix or Render stems on the panel.');
    // last session
    last.c.hidden = !(h.recap && (h.recap.lines || []).length);
    last.body.replaceChildren();
    if (!last.c.hidden) {
      const lu = mk('ul', 'hrecap');
      for (const l of h.recap.lines) lu.append(mk('li', /^\s/.test(l) ? 'sub' : '', l.trim()));
      last.body.append(when(h.recap.time), lu);
    }
    notifyNew(h);
    markSeen();
    badge();
  }
  addEventListener('ss-state', () => draw(false));
  addEventListener('ss-tabs', () => draw(false));
  addEventListener('ss-profiles', () => draw(true));
  setInterval(() => { if (onHome()) draw(true); }, 30000); // ("5 min ago" moves on)
  draw(true);
  want();
})();
