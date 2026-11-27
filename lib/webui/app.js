// StudioSync's web UI: the state from /api/events (Server-Sent Events; /api/state every 2 s where there's no EventSource), handed to the
// other files as an 'ss-state' event (chat.js sends the chat to /api/action). Everything a bandmate wrote goes in as text (textContent),
// never as HTML. GPL-3.0-or-later.
'use strict';
const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

// (the header's own parts, light / dark, Dock / Undock and Studio > Project > Room, are shell.js's: rt-ui1)
function conn(text, cls) { const c = $('conn'); c.textContent = text; c.className = 'conn ' + (cls || ''); }
function mmss(s) { const m = Math.floor(s / 60), r = Math.floor(s % 60); return m + ':' + String(r).padStart(2, '0'); }

// (Who's here, the claims and the asks on them are Session's now: play.js draws them from the presence and session topics. rt-ui6)

// (the chat itself, its scopes, to-dos and links: chat.js)
function show(s) {
  if (!s) return;
  conn(s.engine ? 'live' : 'Live sync isn’t running', s.engine ? 'ok' : 'bad');
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
