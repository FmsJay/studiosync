// StudioSync's web UI: the state from /api/events (Server-Sent Events; /api/state every 2 s where there's no EventSource), handed to the
// other files as an 'ss-state' event (chat.js sends the chat to /api/action). Everything a bandmate wrote goes in as text (textContent),
// never as HTML. GPL-3.0-or-later.
'use strict';
const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

// (the header's own parts, light / dark, Dock / Undock and Studio > Project > Room, are shell.js's: rt-ui1)
function conn(text, cls) { const c = $('conn'); c.textContent = text; c.className = 'conn ' + (cls || ''); }
function mmss(s) { const m = Math.floor(s / 60), r = Math.floor(s % 60); return m + ':' + String(r).padStart(2, '0'); }

function presence(p) {
  if (!p) return;
  const ul = $('people');
  ul.replaceChildren();
  for (const x of p.people || []) {
    const li = el('li', x.me ? 'me' : '');
    li.dataset.avUser = x.user; // (profile.js puts their picture in front)
    // (a person's computers are one entry, each listed under it: lib/persons.lua, rt-people)
    const devs = (x.devices || []).map((d) => d.user);
    li.append(el('span', 'name', (window.ssProfiles ? ssProfiles.name(x.user) : x.user) + (x.me ? ' (you)' : '')));
    if (devs.length) li.append(el('span', 'dim', ' on ' + devs.join(', ')));
    if (x.user === p.driver || devs.includes(p.driver)) li.append(el('span', 'badge drv', 'in control')); // (James, 2026-11-27: "In control" replaces "driver")
    if (x.recording) li.append(el('span', 'badge rec', 'recording'));
    else if (x.playing) li.append(el('span', 'badge play', 'playing'));
    if (x.live === 'rt') li.append(el('span', 'badge', 'real time'));
    else if (x.live === 'ts') li.append(el('span', 'badge', 'time-sync'));
    if (x.call) li.append(el('span', 'badge', 'on the call'));
    if ((x.armed || []).length) li.append(el('div', 'armed', 'armed: ' + x.armed.join(', ')));
    // Admins only (lib/grants.lua): who an admin let edit in this room, and Let edit / Revoke for the owner and admins
    const granted = (p.granted || []).includes(x.user);
    if (granted) li.append(el('span', 'badge', 'can edit here'));
    if (p.mode === 'admins' && p.may_grant && !x.me) {
      const b = el('button', '', granted ? 'Revoke' : 'Let edit');
      b.type = 'button';
      b.title = granted ? 'Take back their editing in this room' : 'Let them edit in this room as an admin would (this room only; a guest’s other limits stay)';
      b.addEventListener('click', () => {
        b.disabled = true;
        fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
          body: JSON.stringify({ topic: 'grants', user: x.user, on: !granted }) }).catch(() => { b.disabled = false; });
      });
      li.append(b);
    }
    ul.append(li);
  }
  for (const u of p.granted || []) if (!(p.people || []).some((x) => x.user === u)) ul.append(el('li', 'dim', u + ': can edit here (not here now)'));
  if ((p.people || []).length < 2) ul.append(el('li', 'dim', 'Nobody else is here right now.'));
  const cl = $('claims');
  cl.replaceChildren();
  for (const c of p.claims || []) {
    const what = c.kind === 'time' ? mmss(c.from) + ' to ' + mmss(c.to) : c.kind + ' ' + c.name;
    const cn = window.ssProfiles ? ssProfiles.name(c.user) : c.user; // (the person, and the computer when it differs: rt-people)
    cl.append(el('li', '', cn + (cn !== c.user ? ' (' + c.user + ')' : '') + ': ' + what + (c.auto ? ' (while editing)' : '')));
  }
  if (!(p.claims || []).length) cl.append(el('li', 'dim', 'None'));
  asks(p.asks || {});
}
// Claims mode (lib/claimask.lua): someone asks for what you claimed (Release / Keep), and your own asks waiting on others.
// (the seconds left count down here, every second: they moved only when the presence topic changed. Backlog 1.4, rt-p1)
function askLeft(till) { return Math.max(0, Math.round(till - Date.now() / 1000)) + ' s'; }
function askTill(till) { const s = el('span', 'asktill', askLeft(till)); s.dataset.till = till; return s; }
setInterval(() => { for (const s of document.querySelectorAll('#asks .asktill')) s.textContent = askLeft(Number(s.dataset.till)); }, 1000);
function asks(a) {
  const ul = $('asks');
  if (!ul) return;
  ul.replaceChildren();
  for (const q of a.incoming || []) {
    const li = el('li', 'ask', q.from + ' wants to edit ' + q.what + ' (');
    li.append(askTill(q.till), ') ');
    for (const [label, answer, tip] of [['Release', 'release', 'Let go of it: their edit goes to everyone and the claim is theirs'], ['Keep', 'keep', 'Keep your claim: their edit is put back']]) {
      const b = el('button', '', label);
      b.type = 'button';
      b.title = tip;
      b.addEventListener('click', () => {
        b.disabled = true;
        fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
          body: JSON.stringify({ topic: 'claimask', id: q.id, answer }) }).catch(() => { b.disabled = false; });
      });
      li.append(b);
    }
    ul.append(li);
  }
  for (const w of a.waiting || []) {
    const li = el('li', 'dim', 'Asked ' + w.to + ' for ' + w.what + ': your edit waits for their answer (');
    li.append(askTill(w.till), ')');
    ul.append(li);
  }
}

// (the chat itself, its scopes, to-dos and links: chat.js)
function show(s) {
  if (!s) return;
  conn(s.engine ? 'live' : 'Live sync isn’t running', s.engine ? 'ok' : 'bad');
  const t = s.topics || {};
  presence(t.presence);
  dispatchEvent(new CustomEvent('ss-state', { detail: s })); // (call.js, daw.js, tabs.js and the pages read the same snapshot; after the first, the stream sends only changed topics)
}

if (window.EventSource) {
  const es = new EventSource('api/events');
  es.onmessage = (e) => { try { show(JSON.parse(e.data)); } catch (err) {} };
  es.onerror = () => conn('reconnecting', 'bad');
} else {
  const poll = () => fetch('api/state').then((r) => r.json()).then(show).catch(() => conn('offline', 'bad')).finally(() => setTimeout(poll, 2000));
  poll();
}

// Docked in REAPER (extension/webui_dock.cpp: WebView2 on Windows, WKWebView on macOS). The view takes REAPER's keys while it has focus, so
// the ones the page doesn't use go back to REAPER's shortcuts: outside a text field every key but Tab (and Enter on a button); inside one,
// only Ctrl/Cmd/Alt combinations that aren't editing, and F-keys. Esc leaves the field. (Dock / Undock and the window's other messages:
// shell.js, rt-ui1.) In a browser none of this exists. (James, rt)
const host = (window.chrome && window.chrome.webview) || (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.studiosync);
if (host) {
  const send = (m) => { try { host.postMessage(m); } catch (e) {} };
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
