// StudioSync's web UI: the state from /api/events (Server-Sent Events; /api/state every 2 s where there's no EventSource), chat sends to
// /api/action. Everything a bandmate wrote goes in as text (textContent), never as HTML. GPL-3.0-or-later.
'use strict';
const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
let me = null, pending = [];

// light / dark: the system's, or the one picked here
const root = document.documentElement;
try { const t = localStorage.getItem('ss-theme'); if (t) root.dataset.theme = t; } catch (e) {}
$('theme').addEventListener('click', () => {
  const dark = root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
  root.dataset.theme = dark ? 'light' : 'dark';
  try { localStorage.setItem('ss-theme', root.dataset.theme); } catch (e) {}
});

function conn(text, cls) { const c = $('conn'); c.textContent = text; c.className = 'conn ' + (cls || ''); }
function when(iso) {
  const d = new Date(iso || '');
  if (isNaN(d)) return '';
  const t = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return d.toDateString() === new Date().toDateString() ? t : d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + t;
}
function mmss(s) { const m = Math.floor(s / 60), r = Math.floor(s % 60); return m + ':' + String(r).padStart(2, '0'); }

function presence(p) {
  if (!p) return;
  $('where').textContent = p.song ? p.song + (p.room && p.room !== 'main' ? ' / ' + p.room : '') : '';
  me = (p.people || []).find((x) => x.me) || me;
  const ul = $('people');
  ul.replaceChildren();
  for (const x of p.people || []) {
    const li = el('li', x.me ? 'me' : '');
    li.append(el('span', 'name', x.user + (x.me ? ' (you)' : '')));
    if (x.user === p.driver) li.append(el('span', 'badge drv', 'driver'));
    if (x.recording) li.append(el('span', 'badge rec', 'recording'));
    else if (x.playing) li.append(el('span', 'badge play', 'playing'));
    if (x.live === 'rt') li.append(el('span', 'badge', 'real time'));
    else if (x.live === 'ts') li.append(el('span', 'badge', 'time-sync'));
    if (x.call) li.append(el('span', 'badge', 'on the call'));
    if ((x.armed || []).length) li.append(el('div', 'armed', 'armed: ' + x.armed.join(', ')));
    ul.append(li);
  }
  if ((p.people || []).length < 2) ul.append(el('li', 'dim', 'Nobody else is here right now.'));
  const cl = $('claims');
  cl.replaceChildren();
  for (const c of p.claims || []) {
    const what = c.kind === 'time' ? mmss(c.from) + ' to ' + mmss(c.to) : c.kind + ' ' + c.name;
    cl.append(el('li', '', c.user + ': ' + what));
  }
  if (!(p.claims || []).length) cl.append(el('li', 'dim', 'None'));
}

function chat(c) {
  if (!c) return;
  const ol = $('msgs');
  const atEnd = ol.scrollHeight - ol.scrollTop - ol.clientHeight < 40;
  ol.replaceChildren();
  const msgs = c.msgs || [];
  pending = pending.filter((t) => !msgs.some((m) => me && m.user === me.user && m.text === t)); // (here as a file now)
  for (const m of msgs) ol.append(line(m.user, m.text, when(m.time) + (m.where ? ' · ' + m.where : ''), me && m.user === me.user));
  for (const t of pending) ol.append(line(me ? me.user : 'you', t, 'sending…', true, true));
  if (!msgs.length && !pending.length) ol.append(el('li', 'dim', 'No messages in this project yet.'));
  if (atEnd) ol.scrollTop = ol.scrollHeight;
}
function line(user, text, meta, mine, isPending) {
  const li = el('li', (mine ? 'mine' : '') + (isPending ? ' pending' : ''));
  li.append(el('div', 'who', (mine ? '' : user + '  ') + meta));
  li.append(el('div', 'bubble', text));
  return li;
}

let lastChat = null;
function show(s) {
  if (!s) return;
  conn(s.engine ? 'live' : 'Live sync isn’t running', s.engine ? 'ok' : 'bad');
  const t = s.topics || {};
  presence(t.presence);
  if (t.chat) lastChat = t.chat;
  chat(lastChat);
  dispatchEvent(new CustomEvent('ss-state', { detail: s })); // (call.js: video calls and screen share read the same snapshot)
}

if (window.EventSource) {
  const es = new EventSource('api/events');
  es.onmessage = (e) => { try { show(JSON.parse(e.data)); } catch (err) {} };
  es.onerror = () => conn('reconnecting', 'bad');
} else {
  const poll = () => fetch('api/state').then((r) => r.json()).then(show).catch(() => conn('offline', 'bad')).finally(() => setTimeout(poll, 2000));
  poll();
}

$('say').addEventListener('submit', (e) => {
  e.preventDefault();
  const input = $('text'), text = input.value.trim();
  if (!text) return;
  fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' }, body: JSON.stringify({ topic: 'chat', text }) })
    .then((r) => {
      if (!r.ok) throw new Error(r.status);
      input.value = '';
      pending.push(text);
      chat(lastChat);
    })
    .catch(() => conn('couldn’t send', 'bad'));
});

// Docked in REAPER (extension/webui_dock.cpp: WebView2 on Windows, WKWebView on macOS). The view takes REAPER's keys while it has focus, so
// the ones the page doesn't use go back to REAPER's shortcuts: outside a text field every key but Tab (and Enter on a button); inside one,
// only Ctrl/Cmd/Alt combinations that aren't editing, and F-keys. Esc leaves the field. Dock / Undock moves the window in or out of the
// docker. In a browser none of this exists. (James, rt)
const host = (window.chrome && window.chrome.webview) || (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.studiosync);
if (host) {
  const send = (m) => { try { host.postMessage(m); } catch (e) {} };
  const where = new URLSearchParams(location.search).get('host');
  if (where === 'docked' || where === 'floating') {
    const b = $('dock');
    b.textContent = where === 'docked' ? 'Undock' : 'Dock';
    b.title = where === 'docked' ? 'Float this in its own window' : 'Put this in a REAPER docker';
    b.hidden = false;
    b.addEventListener('click', () => send('dock'));
  }
  const EDIT = new Set(['a', 'c', 'v', 'x', 'z', 'y', 'arrowleft', 'arrowright', 'arrowup', 'arrowdown', 'home', 'end', 'backspace', 'delete']);
  addEventListener('keydown', (e) => {
    if (e.defaultPrevented || e.isComposing || !e.keyCode || ['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
    const t = e.target, typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
    const mod = e.ctrlKey || e.metaKey || e.altKey, fkey = /^F\d+$/.test(e.key);
    if (typing) {
      if (e.key === 'Escape') { t.blur(); e.preventDefault(); return; }
      if (!fkey && (!mod || EDIT.has(e.key.toLowerCase()))) return;
    } else if (e.key === 'Tab' || (e.key === 'Enter' && t && t.tagName === 'BUTTON')) return;
    e.preventDefault(); // (so Space doesn't also press the focused button or scroll the list)
    send('key:' + e.keyCode + ':' + ((e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0)));
  });
}
