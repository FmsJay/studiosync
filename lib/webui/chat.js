// StudioSync's chat in the web UI: messages, to-dos and links for This room, This project or the Studio, as the panel's Chat page has them.
// Reads the "chat" topic (This project's, always built) and "chat_room" / "chat_band" (built only while a page shows that scope: it says so
// every 10 s); sends on the "chat" topic with the scope picked, which is who you're writing to. Live sync applies each through the Chat
// page's own store (lib/page_chat.lua web_action): anyone ticks a to-do off, only its writer deletes. Bandmates' words go in as text, never
// HTML; a link opens only when it's a web address (anything else is shown, as the panel asks first). GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const section = document.getElementById('chat');
  if (!section || !window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const SCOPES = [['room', 'This room'], ['song', 'This project'], ['band', 'Studio']];
  const TOPIC = { song: 'chat', room: 'chat_room', band: 'chat_band' };
  const KINDS = [['msgs', 'Messages'], ['todo', 'To-do'], ['links', 'Links']];
  let scope = 'song', kind = 'msgs', pending = [];
  try { scope = TOPIC[localStorage.getItem('ss-chat-scope')] ? localStorage.getItem('ss-chat-scope') : 'song'; } catch (e) {}

  // ---- the controls: who you're writing to, and Messages / To-do / Links --------------------------------------------------------------
  const msgs = document.getElementById('msgs'), say = document.getElementById('say'), input = document.getElementById('text');
  const note = section.querySelector('h2 .dim');
  const bar = mk('div', 'cbar');
  const pick = mk('select');
  pick.setAttribute('aria-label', 'What you see and who you’re writing to');
  pick.title = 'This room: only this room’s. This project: the project’s and all its rooms’. Studio: everything, from every project and room. What you write goes to the one picked here.';
  for (const [v, t] of SCOPES) { const o = mk('option', '', t); o.value = v; pick.append(o); }
  pick.value = scope;
  const kinds = mk('div', 'ckinds');
  kinds.setAttribute('role', 'group');
  const kindBtn = {};
  for (const [k, t] of KINDS) { const b = mk('button', 'tab', t); b.type = 'button'; b.addEventListener('click', () => { kind = k; layout(); }); kindBtn[k] = b; kinds.append(b); }
  bar.append(pick, kinds);
  section.querySelector('h2').after(bar);
  const todoList = mk('ul', 'clist ctodo'), linkList = mk('ul', 'clist clinks');
  const todoForm = mk('form', 'cform'), todoText = mk('input');
  todoText.maxLength = 2000; todoText.placeholder = 'add a to-do'; todoText.setAttribute('aria-label', 'A new to-do'); todoText.autocomplete = 'off';
  const todoAdd = mk('button', 'csend', 'Add'); todoAdd.type = 'submit';
  todoForm.append(todoText, todoAdd);
  const linkForm = mk('form', 'cform'), linkTitle = mk('input'), linkUrl = mk('input');
  linkTitle.maxLength = 200; linkTitle.placeholder = 'title (lyrics, chart…)'; linkTitle.setAttribute('aria-label', 'The link’s title'); linkTitle.autocomplete = 'off';
  linkUrl.maxLength = 2000; linkUrl.placeholder = 'link or file path'; linkUrl.setAttribute('aria-label', 'The link'); linkUrl.autocomplete = 'off';
  const linkAdd = mk('button', 'csend', 'Add'); linkAdd.type = 'submit';
  linkForm.append(linkTitle, linkUrl, linkAdd);
  say.after(todoList, todoForm, linkList, linkForm);

  function layout() {
    for (const [k] of KINDS) kindBtn[k].setAttribute('aria-pressed', String(k === kind));
    msgs.hidden = say.hidden = kind !== 'msgs';
    todoList.hidden = todoForm.hidden = kind !== 'todo';
    linkList.hidden = linkForm.hidden = kind !== 'links';
    if (note) note.textContent = '(' + SCOPES.find((s) => s[0] === scope)[1].toLowerCase() + ')';
    input.placeholder = scope === 'band' ? 'Message the whole studio' : scope === 'room' ? 'Message this room' : 'Message the band';
    draw(true);
  }
  // (the other scopes are built only while a page shows them)
  const main = section.closest('main');
  const want = () => { if (scope !== 'song' && !document.hidden && !(main && main.hidden)) ssTabs.act('chat', { want: scope, scope }).catch(() => {}); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  if (main) new MutationObserver(want).observe(main, { attributes: true, attributeFilter: ['hidden'] }); // (back on Here: at once)
  pick.addEventListener('change', () => {
    scope = pick.value;
    try { localStorage.setItem('ss-chat-scope', scope); } catch (e) {}
    pending = [];
    want();
    layout();
  });

  // ---- drawing --------------------------------------------------------------------------------------------------------------------------
  function when(iso) {
    const d = new Date(iso || '');
    if (isNaN(d)) return '';
    const t = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return d.toDateString() === new Date().toDateString() ? t : d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + t;
  }
  const me = () => { const p = ssTabs.topics.presence; const x = p && (p.people || []).find((y) => y.me); return x ? x.user : null; };
  function del(k, e) {
    const b = mk('button', 'cdel', '×');
    b.type = 'button';
    b.title = 'Delete yours (for everyone)';
    b.setAttribute('aria-label', 'Delete this for everyone');
    b.addEventListener('click', () => { if (confirm('Delete this for everyone?')) send({ delete: { kind: k, id: e.id } }); });
    return b;
  }
  function line(m, mine, isPending) {
    const li = mk('li', (mine ? 'mine' : '') + (isPending ? ' pending' : ''));
    const who = mk('div', 'who', (mine ? '' : m.user + '  ') + (isPending ? 'sending…' : when(m.time) + (m.where ? ' · ' + m.where : '')));
    if (mine && !isPending && m.id) who.append(del('msgs', m));
    li.append(who, mk('div', 'bubble', m.text));
    return li;
  }
  let lastC = null;
  function draw(force) {
    const c = ssTabs.topics[TOPIC[scope]];
    if (c === lastC && !force) return;
    lastC = c;
    const user = me();
    // messages
    const atEnd = msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 40;
    msgs.replaceChildren();
    const ms = (c && c.msgs) || [];
    pending = pending.filter((t) => !ms.some((m) => m.user === user && m.text === t)); // (here as a file now)
    for (const m of ms) msgs.append(line(m, m.user === user));
    for (const t of pending) msgs.append(line({ text: t }, true, true));
    if (!c) msgs.append(mk('li', 'dim', 'Asking Live sync…'));
    else if (!ms.length && !pending.length) msgs.append(mk('li', 'dim', 'No messages yet: write one below. Everyone in it sees it, even if they’re not in the project right now.'));
    if (atEnd) msgs.scrollTop = msgs.scrollHeight;
    // to-dos
    todoList.replaceChildren();
    for (const d of (c && c.todo) || []) {
      const li = mk('li', d.done ? 'done' : '');
      const l = mk('label'), box = mk('input');
      box.type = 'checkbox'; box.checked = !!d.done;
      box.addEventListener('change', () => send({ done: d.id, on: box.checked }));
      l.append(box, document.createTextNode(' ' + d.text));
      li.append(l);
      const meta = (d.done && d.by ? '(' + d.by + ') ' : '') + (d.user !== user ? d.user : '') + (d.where ? ' · ' + d.where : '');
      if (meta.trim()) li.append(mk('span', 'dim cmeta', meta));
      if (d.user === user && d.id) li.append(del('todo', d));
      todoList.append(li);
    }
    if (c && !(c.todo || []).length) todoList.append(mk('li', 'dim', 'No to-dos yet.'));
    // links
    linkList.replaceChildren();
    for (const k of (c && c.links) || []) {
      const li = mk('li');
      if (/^https?:\/\//i.test(k.url)) {
        const a = mk('a', '', k.title || k.url);
        a.href = k.url; a.target = '_blank'; a.rel = 'noopener noreferrer'; a.title = k.url;
        li.append(a);
      } else {
        // (not a web link: a file or a program on someone's computer. Shown, never opened from here)
        li.append(mk('span', '', (k.title ? k.title + ': ' : '')), mk('code', '', k.url));
      }
      li.append(mk('span', 'dim cmeta', ' (' + k.user + (k.where ? ' · ' + k.where : '') + ')'));
      if (k.user === user && k.id) li.append(del('links', k));
      linkList.append(li);
    }
    if (c && !(c.links || []).length) linkList.append(mk('li', 'dim', 'No links yet.'));
  }
  addEventListener('ss-state', () => draw(false));
  addEventListener('ss-tabs', () => draw(false));

  // ---- sending ------------------------------------------------------------------------------------------------------------------------
  const conn = document.getElementById('conn');
  function send(o) {
    return ssTabs.act('chat', Object.assign({ scope }, o)).catch((e) => {
      if (conn) { conn.textContent = 'couldn’t send'; conn.className = 'conn bad'; }
      throw e;
    });
  }
  say.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    send({ text }).then(() => { input.value = ''; pending.push(text); draw(true); }).catch(() => {});
  });
  todoForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = todoText.value.trim();
    if (text) send({ todo: text }).then(() => { todoText.value = ''; }).catch(() => {});
  });
  linkForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const url = linkUrl.value.trim();
    if (url) send({ title: linkTitle.value.trim(), url }).then(() => { linkTitle.value = ''; linkUrl.value = ''; }).catch(() => {});
  });
  layout();
  want();
})();
