// join.html: a StudioSync join link opened in a browser on this computer (http://127.0.0.1:<port>/join.html?s=...&p=...). Shows what it
// is, as text; Open in REAPER sends it to Live sync ({topic:"invite", link}), which checks it exactly as a clicked studiosync:// link
// (lib/invite.lua parse_link) and, for a studio you're not in yet, asks first in REAPER. Nothing is sent without a press. GPL-3.0-or-later.
'use strict';
(() => {
  const $ = (id) => document.getElementById(id);
  const q = location.search.replace(/^\?/, '');
  const p = new URLSearchParams(q);
  const known = ['s', 'p', 'r', 'n', 'h', 'c'];
  let ok = q.length > 0 && q.length <= 600 && p.get('s');
  for (const k of p.keys()) if (!known.includes(k)) ok = false;
  const what = $('what'), go = $('go'), app = $('app'), note = $('note');
  if (!ok) { what.textContent = 'This isn’t a StudioSync join link.'; return; }
  const link = 'studiosync://join?' + q;
  if (p.get('c')) {
    what.textContent = 'An invitation to the studio ' + (p.get('n') || p.get('s')) + ', from ' + (p.get('h') || 'a bandmate');
    // (rt-p10: a code link reaches the inviter only over their Tailscale network; say so before the press, not after two minutes)
    note.textContent = 'This works only on ' + (p.get('h') || 'their') + '’s Tailscale network. If this computer isn’t on it, ask them for the ' +
      'invitation message and paste it with Paste join code.';
  } else what.textContent = 'Open ' + (p.get('p') || '?') + (p.get('r') && p.get('r') !== 'main' ? ' (room ' + p.get('r') + ')' : '') + ' in your studio';
  go.disabled = false;
  app.href = link;
  app.hidden = false;
  go.addEventListener('click', () => {
    go.disabled = true;
    fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
      body: JSON.stringify({ topic: 'invite', link }) })
      .then((r) => { if (!r.ok) throw new Error(String(r.status)); note.textContent = 'Sent to StudioSync: REAPER opens it (or asks you first).'; })
      .catch(() => { note.textContent = 'StudioSync’s Live sync isn’t running on this computer. Open REAPER, or use the link handler link.'; go.disabled = false; });
  });
})();
