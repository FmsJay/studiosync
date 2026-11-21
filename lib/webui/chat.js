// StudioSync's chat in the web UI: messages, to-dos and links for This room, This project or the Studio, as the panel's Chat page has them,
// and (rt-chat2) the studio's named channels, direct messages (1:1 and small groups), unread counts and @mentions, the All tab, and files
// dragged onto a person or a conversation (or picked on a phone).
// Reads the "chat" topic (This project's, always built), "chat_room" / "chat_band" / "chat_dm_<id>" / "chat_ch_<id>" (built only while a
// page shows that one: it says so every 10 s) and "chat_index" (every conversation with its unread count, the studio's people). Sends on the
// "chat" topic with the scope picked, which is who you're writing to. Live sync applies each through the Chat page's own store
// (lib/page_chat.lua web_action; files: lib/chatfiles.lua): anyone ticks a to-do off, only its writer deletes. Bandmates' words go in as text,
// never HTML; a link opens only when it's a web address; a file is only ever saved or downloaded when you press for it, never opened.
// GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const section = document.getElementById('chat');
  if (!section || !window.ssTabs) return;
  const css = document.createElement('link'); // (its own look: chat.css, the page's own file as the CSP wants)
  css.rel = 'stylesheet'; css.href = 'chat.css';
  document.head.append(css);
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const HERE = [['room', 'This room'], ['song', 'This project'], ['band', 'Studio']];
  const topicOf = (sc) => ({ song: 'chat', room: 'chat_room', band: 'chat_band' })[sc] || 'chat_' + String(sc).replace(':', '_');
  const okScope = (sc) => typeof sc === 'string' && (['room', 'song', 'band'].includes(sc) || /^(dm:[0-9a-f]{16}|ch:[0-9a-f]{12})$/.test(sc));
  const KINDS = [['msgs', 'Messages'], ['todo', 'To-do'], ['links', 'Links'], ['all', 'All']];
  let scope = 'song', kind = 'msgs', pending = [];
  try { const s = localStorage.getItem('ss-chat-scope'); if (okScope(s)) scope = s; } catch (e) {}
  const index = () => ssTabs.topics.chat_index || null;
  const me = () => { const x = index(); if (x && x.me) return x.me; const p = ssTabs.topics.presence; const y = p && (p.people || []).find((z) => z.me); return y ? y.user : null; };

  // ---- the controls: the conversations, Messages / To-do / Links / All -----------------------------------------------------------------
  const msgs = document.getElementById('msgs'), say = document.getElementById('say'), input = document.getElementById('text');
  const note = section.querySelector('h2 .dim');
  const convs = mk('nav', 'cconvs');
  convs.setAttribute('aria-label', 'Conversations: what you see and who you’re writing to');
  const bar = mk('div', 'cbar');
  const kinds = mk('div', 'ckinds');
  kinds.setAttribute('role', 'group');
  const kindBtn = {};
  for (const [k, t] of KINDS) { const b = mk('button', 'tab', t); b.type = 'button'; b.addEventListener('click', () => { kind = k; layout(); }); kindBtn[k] = b; kinds.append(b); }
  const admin = mk('div', 'cadmin');
  bar.append(kinds, admin);
  section.querySelector('h2').after(convs, bar);
  const groupForm = mk('form', 'cgroup');
  groupForm.hidden = true;
  convs.after(groupForm);
  const todoList = mk('ul', 'clist ctodo'), linkList = mk('ul', 'clist clinks'), allList = mk('ul', 'clist call');
  const todoForm = mk('form', 'cform'), todoText = mk('input'), todoFor = mk('select', 'ctodofor');
  todoFor.setAttribute('aria-label', 'Who the to-do is for');
  todoText.maxLength = 2000; todoText.placeholder = 'add a to-do'; todoText.setAttribute('aria-label', 'A new to-do'); todoText.autocomplete = 'off';
  const todoAdd = mk('button', 'csend', 'Add'); todoAdd.type = 'submit';
  todoForm.append(todoText, todoFor, todoAdd);
  const linkForm = mk('form', 'cform'), linkTitle = mk('input'), linkUrl = mk('input');
  linkTitle.maxLength = 200; linkTitle.placeholder = 'title (lyrics, chart…)'; linkTitle.setAttribute('aria-label', 'The link’s title'); linkTitle.autocomplete = 'off';
  linkUrl.maxLength = 2000; linkUrl.placeholder = 'link or file path'; linkUrl.setAttribute('aria-label', 'The link'); linkUrl.autocomplete = 'off';
  const linkAdd = mk('button', 'csend', 'Add'); linkAdd.type = 'submit';
  linkForm.append(linkTitle, linkUrl, linkAdd);
  say.after(todoList, todoForm, linkList, linkForm, allList);
  // attach: a file picked (a phone) goes to this conversation, as one dropped would
  const attach = mk('button', 'cattach', '+ File'); attach.type = 'button';
  attach.title = 'Send a file to this conversation (or drag one onto a person or a conversation). Audio, MIDI, video, pictures, PDFs, text, presets and zips; never programs.';
  const picker = mk('input'); picker.type = 'file'; picker.multiple = true; picker.hidden = true;
  attach.addEventListener('click', () => picker.click());
  picker.addEventListener('change', () => { sendFiles([...picker.files], { scope }); picker.value = ''; });
  say.prepend(attach, picker);

  function convOf(sc) { const x = index(); return x && (x.convs || []).find((c) => c.scope === sc); }
  function nameOf(sc) {
    const c = convOf(sc), h = HERE.find((x) => x[0] === sc);
    if (h) return h[1];
    return c ? (c.kind === 'ch' ? '#' + c.name : c.name) : 'a conversation';
  }
  function layout() {
    for (const [k] of KINDS) kindBtn[k].setAttribute('aria-pressed', String(k === kind));
    msgs.hidden = say.hidden = kind !== 'msgs';
    todoList.hidden = todoForm.hidden = kind !== 'todo';
    linkList.hidden = linkForm.hidden = kind !== 'links';
    allList.hidden = kind !== 'all';
    if (note) note.textContent = '(' + nameOf(scope).replace(/^This /, 'this ') + ')';
    const c = convOf(scope);
    input.placeholder = scope === 'band' ? 'Message the whole studio' : scope === 'room' ? 'Message this room' : scope === 'song' ? 'Message the band'
      : c && c.archived ? 'This channel is archived' : 'Message ' + nameOf(scope);
    input.disabled = !!(c && c.archived);
    drawConvs();
    draw(true);
  }
  // (the other scopes are built only while a page shows them)
  const main = section.closest('main');
  const shown = () => !document.hidden && !(main && main.hidden);
  const want = () => { if (scope !== 'song' && shown()) ssTabs.act('chat', { want: scope, scope }).catch(() => {}); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', () => { want(); draw(true); });
  if (main) new MutationObserver(() => { want(); draw(true); }).observe(main, { attributes: true, attributeFilter: ['hidden'] }); // (back on Here: at once)
  function pick(sc) {
    if (!okScope(sc) || sc === scope) return;
    scope = sc;
    try { localStorage.setItem('ss-chat-scope', scope); } catch (e) {}
    pending = [];
    want();
    layout();
  }

  // ---- the conversation list: Here, channels, people and groups, each with its unread count; each takes a dropped file ----------------
  const badge = (c) => {
    if (!c || !c.n) return null;
    const b = mk('span', 'cbadge' + (c.at ? ' cat' : ''), (c.at ? '@ ' : '') + c.n);
    b.title = c.n + ' unread' + (c.at ? ', ' + c.at + ' mentioning you' : '');
    return b;
  };
  function chip(label, sc, c, extra) {
    const b = mk('button', 'cchip' + (extra || ''));
    b.type = 'button';
    b.append(mk('span', '', label));
    const bd = badge(c); if (bd) b.append(bd);
    if (sc) { b.dataset.scope = sc; b.setAttribute('aria-pressed', String(sc === scope)); b.addEventListener('click', () => pick(sc)); }
    return b;
  }
  let lastIdx = null;
  function fillFor() { // (who a to-do can be for: anyone in particular, you, or a person of the studio)
    const x = index(), want = [''].concat(x && x.me ? [x.me] : [], (x && x.people) || []);
    if (todoFor.dataset.keys === want.join('\n')) return;
    todoFor.dataset.keys = want.join('\n');
    const cur = todoFor.value;
    todoFor.replaceChildren(...want.map((u) => { const o = mk('option', '', u === '' ? 'for anyone' : u === (x && x.me) ? 'for me' : 'for ' + u); o.value = u; return o; }));
    todoFor.value = want.includes(cur) ? cur : '';
  }
  function drawConvs() {
    fillFor();
    const x = index();
    lastIdx = x;
    convs.replaceChildren();
    const row = (title) => { const r = mk('div', 'crow'); r.append(mk('span', 'clabel dim', title)); convs.append(r); return r; };
    const here = row('Here');
    for (const [sc, t] of HERE) here.append(chip(t, sc, convOf(sc)));
    if (!x) return; // (an older Live sync: the three of the project only)
    const chans = (x.convs || []).filter((c) => c.kind === 'ch' && (!c.archived || x.admin));
    if (chans.length || x.admin) {
      const r = row('Channels');
      for (const c of chans) r.append(chip('#' + c.name + (c.archived ? ' (archived)' : ''), c.scope, c, c.archived ? ' carch' : ''));
      if (x.admin) {
        const add = chip('+ Channel', null, null, ' cadd');
        add.title = 'A new text channel for the whole studio (owner and admins)';
        add.addEventListener('click', () => { const n = prompt('The new channel’s name'); if (n && n.trim()) ssTabs.act('chat', { channel: { new: n.trim() } }).catch(oops); });
        r.append(add);
      }
    }
    const dms = (x.convs || []).filter((c) => c.kind === 'dm');
    const r = row('Direct');
    for (const p of x.people || []) { // (one chip per person: their 1:1 conversation, made on the first message or file)
      const c = dms.find((d) => (d.members || []).length === 2 && d.members.includes(p));
      const b = chip(p, c ? c.scope : null, c, ' cperson');
      b.dataset.person = p;
      b.title = 'Only you and ' + p + ' (drop a file here to send it to ' + p + ')';
      if (!c) b.addEventListener('click', () => openDm([p]).then(pick).catch(oops));
      r.append(b);
    }
    for (const c of dms.filter((d) => (d.members || []).length > 2)) { const b = chip(c.name, c.scope, c, ' cperson'); b.title = 'Only ' + c.members.join(', '); r.append(b); }
    if ((x.people || []).length > 1) {
      const g = chip('+ Group', null, null, ' cadd');
      g.title = 'A conversation with a few people, seen only by them';
      g.addEventListener('click', () => { groupForm.hidden = !groupForm.hidden; drawGroup(); });
      r.append(g);
    }
    if (!(x.people || []).length) r.append(mk('span', 'dim', 'nobody else in the studio yet'));
    // the chosen channel's admin buttons
    admin.replaceChildren();
    const c = convOf(scope);
    if (c && c.kind === 'ch' && x.admin) {
      const ren = mk('button', 'tab', 'Rename'); ren.type = 'button';
      ren.addEventListener('click', () => { const n = prompt('The channel’s new name', c.name); if (n && n.trim()) ssTabs.act('chat', { channel: { id: c.scope.slice(3), name: n.trim() } }).catch(oops); });
      const arc = mk('button', 'tab', c.archived ? 'Unarchive' : 'Archive'); arc.type = 'button';
      arc.title = c.archived ? 'Open it again for messages' : 'Hide it from everyone’s list and stop new messages (kept, and admins can open it again)';
      arc.addEventListener('click', () => { if (c.archived || confirm('Archive #' + c.name + ' for everyone?')) ssTabs.act('chat', { channel: { id: c.scope.slice(3), archive: !c.archived } }).catch(oops); });
      admin.append(ren, arc);
    }
  }
  function drawGroup() {
    const x = index();
    groupForm.replaceChildren();
    if (!x) return;
    groupForm.append(mk('span', 'dim', 'With: '));
    for (const p of x.people || []) {
      const l = mk('label'), box = mk('input');
      box.type = 'checkbox'; box.value = p;
      l.append(box, document.createTextNode(' ' + p));
      groupForm.append(l);
    }
    const go = mk('button', 'csend', 'Start'); go.type = 'submit';
    groupForm.append(go);
  }
  groupForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const names = [...groupForm.querySelectorAll('input:checked')].map((b) => b.value);
    const x = index(), max = (x && x.dm_max) || 8;
    if (!names.length || names.length > max - 1) return alert('Pick 1 to ' + (max - 1) + ' people.');
    groupForm.hidden = true;
    openDm(names).then(pick).catch(oops);
  });
  // A DM with these people (you're added): its scope, opened by Live sync if it isn't there yet (it shows in the index within seconds).
  function openDm(names) {
    const user = me();
    const want = [...new Set([user, ...names])].sort().join('\n');
    const find = () => { const x = index(); const c = x && (x.convs || []).find((d) => d.kind === 'dm' && [...d.members].sort().join('\n') === want); return c && c.scope; };
    const now = find();
    if (now) return Promise.resolve(now);
    return ssTabs.act('chat', { dm: names }).then(() => new Promise((res, rej) => {
      const t0 = Date.now();
      const look = () => { const sc = find(); if (sc) return res(sc); if (Date.now() - t0 > 15000) return rej(new Error('Live sync didn’t open it')); setTimeout(look, 300); };
      look();
    }));
  }
  function oops(e) {
    const conn = document.getElementById('conn');
    if (conn) { conn.textContent = 'couldn’t send'; conn.className = 'conn bad'; }
    if (e && e.message) console.warn('chat:', e.message);
  }

  // ---- drawing --------------------------------------------------------------------------------------------------------------------------
  function when(iso) {
    const d = new Date(iso || '');
    if (isNaN(d)) return '';
    const t = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return d.toDateString() === new Date().toDateString() ? t : d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + t;
  }
  const size = (n) => n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB';
  // (what mentions you, as lib/page_chat.lua names_of says it: your user name, your display name, @everyone and @all. rt-p5)
  const mentions = (text, user) => !!user && [user, window.ssProfiles ? ssProfiles.name(user) : null, 'everyone', 'all']
    .some((n) => !!n && new RegExp('@' + n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?![\\w])', 'i').test(text || ''));
  function del(k, e) {
    const b = mk('button', 'cdel', '×');
    b.type = 'button';
    b.title = 'Delete yours (for everyone)';
    b.setAttribute('aria-label', 'Delete this for everyone');
    b.addEventListener('click', () => { if (confirm('Delete this for everyone?')) send({ delete: { kind: k, id: e.id } }); });
    return b;
  }
  const asked = {}; // message id -> a download was asked for (it starts once Live sync has checked the file and offered it)
  function fileBox(m, mine) {
    const f = m.file, box = mk('div', 'cfile');
    box.append(mk('span', 'cfname', f.name), mk('span', 'dim', ' ' + size(f.size)));
    const st = mk('div', 'cfstate dim');
    if (mine) st.textContent = f.via === 'link' ? 'sent over the direct link' : 'sent (through the shared folder)';
    else if (f.state === 'coming') st.textContent = 'arriving… ' + (f.bytes ? Math.min(100, Math.round(f.bytes * 100 / f.size)) + '%' : '');
    else if (f.state === 'waiting') st.textContent = 'on its way';
    else if (f.state === 'bad') st.textContent = 'didn’t arrive whole: ask them to send it again';
    if (f.saved) st.textContent = 'saved to ' + f.saved;
    if (st.textContent) box.append(st);
    if (f.state === 'ready' && m.id) {
      const row = mk('div', 'cfbtns');
      const b = (t, title, o) => { const x = mk('button', 'tab', t); x.type = 'button'; x.title = title; x.addEventListener('click', () => send(Object.assign({}, o)).catch(() => {})); return x; };
      if (!mine) row.append(b('Save', 'Save it on the computer running StudioSync, in its Received files folder. Nothing opens it.', { save: m.id }));
      if (f.audio) row.append(b(mine ? 'To project folder' : 'Save to project folder', 'Copy it into this project’s own folder, ready to drag onto a track', { save: m.id, into: 'project' }));
      const dl = mk('button', 'tab', 'Download'); dl.type = 'button';
      dl.title = 'Download it to this device (checked against the sender’s fingerprint first)';
      dl.addEventListener('click', () => { asked[m.id] = true; send({ download: m.id }).catch(() => {}); if (f.dl) fetchDl(m); });
      row.append(dl);
      box.append(row);
      if (asked[m.id] && f.dl) fetchDl(m);
    }
    return box;
  }
  function fetchDl(m) { // (an <a download>: the browser saves it; the server sends it as plain bytes, never shown or run)
    delete asked[m.id];
    const a = mk('a'); a.href = 'api/file?id=' + encodeURIComponent(m.file.dl); a.download = m.file.name; a.hidden = true;
    document.body.append(a); a.click(); a.remove();
  }
  function line(m, mine, isPending, user) {
    const li = mk('li', (mine ? 'mine' : '') + (isPending ? ' pending' : '') + (!mine && mentions(m.text, user) ? ' cmention' : ''));
    const who = mk('div', 'who', (mine ? '' : m.user + '  ') + (isPending ? 'sending…' : when(m.time) + (m.where ? ' · ' + m.where : '')));
    if (mine && !isPending && m.id) who.append(del('msgs', m));
    li.append(who);
    if (m.file) li.append(fileBox(m, mine)); else li.append(mk('div', 'bubble', m.text));
    if (m.join && window.ssInvite) li.append(ssInvite.joinBox(m, scope, mine)); // (a join request: Join / Decline, invite.js)
    return li;
  }
  let lastC = null, lastSeen = {};
  function draw(force) {
    const c = ssTabs.topics[topicOf(scope)];
    if (index() !== lastIdx) { drawConvs(); }
    if (c === lastC && !force) return;
    lastC = c;
    const user = me();
    // messages
    const atEnd = msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 40;
    msgs.replaceChildren();
    const ms = (c && c.msgs) || [];
    pending = pending.filter((p) => !ms.some((m) => m.user === user && (m.text === p.text || (m.file && p.file && m.file.name === p.file)))); // (here as a file now)
    for (const m of ms) msgs.append(line(m, m.user === user, false, user));
    for (const p of pending) msgs.append(line(p.file ? { text: 'sending ' + p.file + (p.pct != null ? ' ' + p.pct + '%' : '') } : p, true, true, user));
    if (!c) msgs.append(mk('li', 'dim', 'Asking Live sync…'));
    else if (!ms.length && !pending.length) msgs.append(mk('li', 'dim', scope.startsWith('dm:') ? 'No messages yet. Only the people in it see this conversation in StudioSync (see who can read the files in the docs).'
      : 'No messages yet: write one below. Everyone in it sees it, even if they’re not in the project right now.'));
    if (atEnd) msgs.scrollTop = msgs.scrollHeight;
    // seen: what's shown here counts as read (the unread counts here and on the panel)
    const newest = ms.length ? ms[ms.length - 1].id : null;
    if (newest && shown() && (kind === 'msgs' || kind === 'all') && lastSeen[scope] !== newest) {
      lastSeen[scope] = newest;
      const cv = convOf(scope);
      if (!cv || cv.n) ssTabs.act('chat', { seen: true, scope }).catch(() => {});
    }
    // to-dos
    todoList.replaceChildren();
    for (const d of (c && c.todo) || []) {
      const li = mk('li', d.done ? 'done' : '');
      const l = mk('label'), box = mk('input');
      box.type = 'checkbox'; box.checked = !!d.done;
      box.addEventListener('change', () => send({ done: d.id, on: box.checked }));
      l.append(box, document.createTextNode(' ' + d.text));
      li.append(l);
      const meta = (d.done && d.by ? '(' + d.by + ') ' : '') + (d.user !== user ? d.user : '') + (d.for ? ' → for ' + (d.for === user ? 'you' : d.for) : '') + (d.where ? ' · ' + d.where : '');
      if (meta.trim()) li.append(mk('span', 'dim cmeta', meta));
      if (d.user === user && d.id) li.append(del('todo', d));
      todoList.append(li);
    }
    if (c && !(c.todo || []).length) todoList.append(mk('li', 'dim', 'No to-dos yet.'));
    // links
    linkList.replaceChildren();
    for (const k of (c && c.links) || []) linkList.append(linkLine(k, user, true));
    if (c && !(c.links || []).length) linkList.append(mk('li', 'dim', 'No links yet.'));
    // All: messages, to-dos and links together, newest first (as the panel's All, without its notes, likes and drawings)
    allList.replaceChildren();
    const rows = [];
    for (const m of ms) rows.push(['message', m]);
    for (const d of (c && c.todo) || []) rows.push(['to-do', d]);
    for (const k of (c && c.links) || []) rows.push(['link', k]);
    rows.sort((a, z) => String(z[1].time || '').localeCompare(String(a[1].time || '')));
    for (const [what, e] of rows.slice(0, 300)) {
      const li = mk('li', what === 'message' && e.user !== user && mentions(e.text, user) ? 'cmention' : '');
      li.append(mk('span', 'dim cmeta', when(e.time) + ' '), mk('span', 'ckind', what), document.createTextNode(' ' + e.user + ': '));
      if (what === 'link') li.append(linkLine(e, user, false));
      else li.append(document.createTextNode(what === 'to-do' ? (e.done ? '[done] ' : '[ ] ') + e.text : e.file ? 'a file: ' + e.file.name : e.text));
      if (e.where) li.append(mk('span', 'dim cmeta', ' (' + e.where + ')'));
      allList.append(li);
    }
    if (c && !rows.length) allList.append(mk('li', 'dim', 'Nothing here yet.'));
  }
  function linkLine(k, user, full) {
    const li = full ? mk('li') : mk('span');
    if (/^https?:\/\//i.test(k.url)) {
      const a = mk('a', '', k.title || k.url);
      a.href = k.url; a.target = '_blank'; a.rel = 'noopener noreferrer'; a.title = k.url;
      li.append(a);
    } else {
      // (not a web link: a file or a program on someone's computer. Shown, never opened from here)
      li.append(mk('span', '', (k.title ? k.title + ': ' : '')), mk('code', '', k.url));
    }
    if (full) {
      li.append(mk('span', 'dim cmeta', ' (' + k.user + (k.where ? ' · ' + k.where : '') + ')'));
      if (k.user === user && k.id) li.append(del('links', k));
    }
    return li;
  }
  addEventListener('ss-state', () => draw(false));
  addEventListener('ss-tabs', () => draw(false));

  // ---- sending ------------------------------------------------------------------------------------------------------------------------
  function send(o, sc) {
    return ssTabs.act('chat', Object.assign({ scope: sc || scope }, o)).catch((e) => { oops(e); throw e; });
  }
  say.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    send({ text }).then(() => { input.value = ''; pending.push({ text }); draw(true); }).catch(() => {});
  });
  todoForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = todoText.value.trim();
    if (text) send({ todo: text, todofor: todoFor.value || undefined }).then(() => { todoText.value = ''; }).catch(() => {});
  });
  linkForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const url = linkUrl.value.trim();
    if (url) send({ title: linkTitle.value.trim(), url }).then(() => { linkTitle.value = ''; linkUrl.value = ''; }).catch(() => {});
  });

  // ---- files: dropped on a person or a conversation, or picked --------------------------------------------------------------------------
  // Each goes up to this computer (POST api/upload), then Live sync sends it (lib/chatfiles.lua). One at a time: the server keeps only the
  // last two uploads, so the next waits until the last one's message is here.
  const queue = [];
  let busy = false;
  // (a file dropped anywhere else is ignored, never opened by the browser in place of the page)
  addEventListener('dragover', (e) => { if (e.dataTransfer && [...e.dataTransfer.types].includes('Files')) e.preventDefault(); });
  addEventListener('drop', (e) => { if (e.dataTransfer && e.dataTransfer.files.length) e.preventDefault(); });
  function target(el) {
    const ch = el.closest && el.closest('.cchip');
    if (ch && (ch.dataset.scope || ch.dataset.person)) return ch.dataset.scope ? { scope: ch.dataset.scope } : { person: ch.dataset.person };
    if (el.closest && el.closest('#msgs, #say')) return { scope };
    return null;
  }
  for (const zone of [convs, msgs, say]) {
    zone.addEventListener('dragover', (e) => { const t = target(e.target); if (t) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; (e.target.closest('.cchip') || zone).classList.add('cdrop'); } });
    zone.addEventListener('dragleave', (e) => { (e.target.closest('.cchip') || zone).classList.remove('cdrop'); });
    zone.addEventListener('drop', (e) => {
      const t = target(e.target);
      for (const x of section.querySelectorAll('.cdrop')) x.classList.remove('cdrop');
      if (!t || !e.dataTransfer.files.length) return;
      e.preventDefault();
      sendFiles([...e.dataTransfer.files], t);
    });
  }
  function sendFiles(files, t) {
    const x = index(), max = (x && x.file_max) || 150 * 1048576, exts = (x && x.file_ext) || [];
    const bad = [];
    for (const f of files) {
      const ext = (f.name.match(/\.([A-Za-z0-9]+)$/) || [])[1];
      if (!ext || (exts.length && !exts.includes(ext.toLowerCase()))) bad.push(f.name + ': only audio, MIDI, video, pictures, PDFs, text, presets and zips (never programs)');
      else if (f.size > max) bad.push(f.name + ': over ' + Math.round(max / 1048576) + ' MB');
      else if (!f.size) bad.push(f.name + ': empty');
      else queue.push({ f, t });
    }
    if (bad.length) alert('Not sent:\n' + bad.join('\n'));
    pump();
  }
  function upload(f, progress) {
    return new Promise((res, rej) => {
      const r = new XMLHttpRequest();
      r.open('POST', 'api/upload');
      r.setRequestHeader('X-StudioSync', '1');
      r.setRequestHeader('Content-Type', 'application/octet-stream');
      r.upload.onprogress = (e) => { if (e.lengthComputable) progress(Math.round(e.loaded * 100 / e.total)); };
      r.onload = () => { try { const j = JSON.parse(r.responseText); if (r.status === 200 && j.ok) return res(j.id); } catch (e) {} rej(new Error(r.status === 413 ? 'too big for one upload' : 'the computer said ' + r.status)); };
      r.onerror = () => rej(new Error('the connection dropped'));
      r.send(f);
    });
  }
  const arrived = (sc, name) => { const c = ssTabs.topics[topicOf(sc)]; const u = me(); return !!(c && (c.msgs || []).some((m) => m.user === u && m.file && m.file.name === name)); };
  async function pump() {
    if (busy) return;
    busy = true;
    while (queue.length) {
      const { f, t } = queue.shift();
      const p = { file: f.name, pct: 0 };
      try {
        const sc = t.scope || await openDm([t.person]);
        if (sc !== scope) pick(sc);
        pending.push(p); draw(true);
        const id = await upload(f, (n) => { p.pct = n; draw(true); });
        await send({ file: { id, name: f.name, size: f.size } }, sc);
        want();
        const t0 = Date.now();
        while (!arrived(sc, f.name) && Date.now() - t0 < 15000) await new Promise((r) => setTimeout(r, 400));
        if (!arrived(sc, f.name)) throw new Error('Live sync didn’t take it (its log says why)');
      } catch (e) {
        alert('Not sent: ' + f.name + ': ' + (e && e.message ? e.message : e));
      }
      pending = pending.filter((x) => x !== p); draw(true);
    }
    busy = false;
  }
  layout();
  want();
})();
