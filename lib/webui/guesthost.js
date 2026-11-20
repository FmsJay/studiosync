// Browser guests on the host's web UI (lib/guestweb.lua, topic "guestweb"): under Who's here, the owner or an admin types a name and makes a
// guest link for this project and room (shown until it's used or runs out, with Copy), and sees each guest: waiting, joined or live, their
// level, a volume and End. Everything from guests goes in as text. GPL-3.0-or-later. (rt-browserjoin)
'use strict';
(() => {
  const here = document.getElementById('here');
  if (!here || !window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const box = mk('div', 'gbox');
  box.hidden = true;
  const h = mk('h3', '', 'Browser guests');
  const form = mk('form');
  const name = mk('input');
  name.maxLength = 32; name.placeholder = 'Their name'; name.setAttribute('aria-label', 'Guest’s name');
  const make = mk('button', '', 'Make a guest link');
  make.type = 'submit';
  form.append(name, make);
  const note = mk('p', 'dim small', 'For someone without REAPER: a link that works once, for this project and room, on the studio’s Tailscale. ' +
    'They join from a browser with their audio interface, hear the session, are heard, and record takes onto their own track.');
  const last = mk('p', 'small');
  const ul = mk('ul');
  box.append(h, note, form, last, ul);
  here.append(box);
  const act = (o) => ssTabs.act('guestweb', o).catch(() => { last.textContent = 'Couldn’t reach Live sync.'; });
  form.addEventListener('submit', (e) => { e.preventDefault(); if (name.value.trim()) act({ make: { name: name.value.trim() } }); name.value = ''; });
  const levels = {};
  function draw() {
    const t = ssTabs.topics.guestweb;
    box.hidden = !t;
    if (!t) return;
    form.hidden = note.hidden = !t.may;
    last.textContent = t.last ? t.last.text : '';
    last.className = 'small' + (t.last && t.last.bad ? ' bad' : '');
    const focused = document.activeElement && ul.contains(document.activeElement) ? document.activeElement.dataset.gid : null;
    if (focused) return; // (a volume being dragged isn't redrawn under the finger)
    ul.replaceChildren();
    for (const g of t.guests || []) {
      const li = mk('li');
      const state = g.live ? 'live' : g.joined ? 'joined, not live' : 'hasn’t opened the link yet';
      li.append(mk('b', '', g.name), mk('span', 'dim', ' · ' + state + (g.here ? '' : ' · for ' + g.song + (g.room !== 'main' ? ' / ' + g.room : ''))));
      if (g.link) {
        const inp = mk('input', 'glink');
        inp.readOnly = true; inp.value = g.link; inp.setAttribute('aria-label', 'Guest link for ' + g.name);
        const copy = mk('button', '', 'Copy');
        copy.type = 'button';
        copy.addEventListener('click', () => { inp.select(); (navigator.clipboard ? navigator.clipboard.writeText(g.link) : Promise.reject()).then(() => { copy.textContent = 'Copied'; }).catch(() => document.execCommand && document.execCommand('copy')); });
        li.append(inp, copy);
      }
      const row = mk('div', 'gbtns');
      const m = mk('meter');
      m.min = 0; m.max = 1; m.value = Math.min(1, g.peak || 0); m.title = 'Their level here';
      const vol = mk('input');
      vol.type = 'range'; vol.min = 0; vol.max = 2; vol.step = 0.01; vol.value = levels[g.gid] != null ? levels[g.gid] : (g.gain != null ? g.gain : 1);
      vol.dataset.gid = g.gid; vol.setAttribute('aria-label', g.name + '’s volume here');
      vol.addEventListener('change', () => { levels[g.gid] = Number(vol.value); act({ gain: { gid: g.gid, v: Number(vol.value) } }); vol.blur(); });
      row.append(m, vol);
      if (t.may) {
        const end = mk('button', '', 'End');
        end.type = 'button';
        end.addEventListener('click', () => { if (confirm('End ' + g.name + '’s session now? Their link stops working.')) act({ kick: g.gid }); });
        row.append(end);
      }
      li.append(row);
      if (g.live && (g.under || g.drops)) li.append(mk('div', 'dim small', 'gaps: ' + (g.under || 0) + ' short, ' + (g.drops || 0) + ' caught up'));
      ul.append(li);
    }
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
})();
