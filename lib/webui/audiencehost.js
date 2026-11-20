// Listening links on the host's web UI (lib/audience.lua, topic "audience"; docs/rt/rt-audience.md): under Who's here, the owner or an admin
// makes a link that plays the live session (or the latest mix) in any browser, sees who listens and what it costs, revokes links, sets the
// cap; the owner alone turns Public listening on (after its warning) or off. Uses guest.css's box styles. Text only. GPL-3.0-or-later.
'use strict';
(() => {
  const here = document.getElementById('here');
  if (!here || !window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const btn = (text, fn) => { const b = mk('button', '', text); b.type = 'button'; b.addEventListener('click', fn); return b; };
  const box = mk('div', 'gbox abox');
  box.hidden = true;
  const note = mk('p', 'dim small', 'A link that plays the band live in any browser (a phone, a client, a bandmate away from REAPER), and the song’s latest mix ' +
    'when nobody plays. Listeners only listen: nothing they do comes back.');
  const hours = mk('select');
  hours.setAttribute('aria-label', 'How long the link works');
  for (const h of [1, 4, 12, 24, 48, 168]) { const o = mk('option', '', h < 24 ? h + ' h' : h / 24 + (h === 24 ? ' day' : ' days')); o.value = h; if (h === 4) o.selected = true; hours.append(o); }
  const act = (o) => ssTabs.act('audience', o).catch(() => { last.textContent = 'Couldn’t reach Live sync.'; });
  const makeT = btn('Make a listening link', () => act({ make: { hours: Number(hours.value) } }));
  const makeP = btn('Make a PUBLIC link', () => act({ make: { hours: Number(hours.value), public: true } }));
  const row = mk('div', 'gbtns');
  row.append(hours, makeT, makeP);
  const last = mk('p', 'small');
  const stats = mk('p', 'dim small');
  const ul = mk('ul');
  const capRow = mk('div', 'gbtns');
  const cap = mk('input');
  cap.type = 'number'; cap.min = 1; cap.max = 100; cap.setAttribute('aria-label', 'Listeners at most');
  const kbps = mk('select');
  kbps.setAttribute('aria-label', 'Sound quality');
  for (const k of [64, 96, 128, 160]) { const o = mk('option', '', k + ' kbit/s'); o.value = k; kbps.append(o); }
  capRow.append(mk('span', 'dim small', 'At most'), cap, mk('span', 'dim small', 'listeners at'), kbps, btn('Set', () => act({ cap: Number(cap.value), kbps: Number(kbps.value) })));
  const pubBox = mk('div');
  const pubText = mk('p', 'small');
  const pubOn = btn('Turn on public listening…', () => {
    const t = ssTabs.topics.audience || {};
    if (confirm((t.warning || 'Public listening opens this computer to the internet.') + '\n\nTurn it on?')) act({ public: { on: true, sure: true } });
  });
  const pubOff = btn('Turn public listening off', () => act({ public: { on: false } }));
  pubBox.append(pubText, pubOn, pubOff);
  box.append(mk('h3', '', 'Listening links'), note, row, last, stats, ul, capRow, pubBox);
  here.append(box);

  function draw() {
    const t = ssTabs.topics.audience;
    box.hidden = !t || !t.may;
    if (box.hidden) return;
    makeP.hidden = !t.public;
    last.textContent = t.last ? t.last.text : '';
    last.className = 'small' + (t.last && t.last.bad ? ' bad' : '');
    const load = typeof t.enc_load === 'number' ? ' · encoder ' + (t.enc_load * 100).toFixed(1) + '% of a core' : '';
    const out = typeof t.out_kbps === 'number' && t.listeners ? ' · ' + Math.round(t.out_kbps) + ' kbit/s out' : '';
    stats.textContent = (t.live ? 'Live now' : 'Not playing') + ' · ' + (t.listeners || 0) + ' of ' + t.cap + ' listening' +
      (t.public_listeners ? ' (' + t.public_listeners + ' public)' : '') + load + out + (t.mix ? ' · latest mix: ' + t.mix : ' · no mix yet');
    if (document.activeElement !== cap) cap.value = t.cap;
    if (document.activeElement !== kbps) kbps.value = String(t.kbps);
    pubOn.hidden = !t.owner || !!t.public;
    pubOff.hidden = !t.public || !t.owner;
    pubText.textContent = t.public ? 'PUBLIC listening is on until ' + new Date(t.public.until * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) +
      ' (Tailscale Funnel)' + (t.public.err ? ': ' + t.public.err : '') : t.owner ? 'Public listening is off: links work only on the studio’s Tailscale.' : '';
    if (ul.contains(document.activeElement)) return;
    ul.replaceChildren();
    for (const k of t.links || []) {
      const li = mk('li');
      const ends = new Date(k.ends * 1000);
      li.append(mk('b', '', k.pub ? 'Public link' : 'Tailnet link'), mk('span', 'dim', ' · ' + (k.n || 0) + ' listening · until ' +
        ends.toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' })));
      if (k.url) {
        const inp = mk('input', 'glink');
        inp.readOnly = true; inp.value = k.url; inp.setAttribute('aria-label', 'Listening link');
        const copy = btn('Copy', () => { inp.select(); (navigator.clipboard ? navigator.clipboard.writeText(k.url) : Promise.reject()).then(() => { copy.textContent = 'Copied'; }).catch(() => document.execCommand && document.execCommand('copy')); });
        li.append(inp, copy);
      }
      li.append(btn('Revoke', () => { if (confirm('Revoke this link now? Everyone listening on it is cut off.')) act({ revoke: k.id }); }));
      ul.append(li);
    }
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
})();
