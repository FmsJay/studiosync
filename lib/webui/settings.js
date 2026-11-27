// StudioSync's Settings tab (docs/rt/ui-web-plan.md 2.9, Phase 10b; rt-ui10b): You (your picture, name and colour, your studios' roles, and
// this device's look), This computer (Window: what the window does when REAPER takes the focus, its button; Sync; Audio), Studio, Devices (the
// talk mic, the phone link, Your computers) and Advanced. Everything but You and its look comes from the "settings" topic (lib/websettings.lua),
// rows the page draws one way (a switch, a choice, a number, a link, a button); a change goes back as { set: { id, value, sure } } and Live sync
// checks it again: only from this computer's own page, Studio rows only for the owner and admins (Public links: the owner). Rows that ask first
// (confirm_on / confirm_off) say why in a confirm before `sure` is sent. Everything from Live sync goes in as text, never HTML.
// GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const root = document.documentElement;
  // ---- this device's look (You): the theme shell.js keeps, and a text size, both in this browser's storage ----------------------------------
  const store = (k, v) => { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} };
  const stored = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };
  const zoom = (v) => { root.style.zoom = v && v !== '100' ? String(Number(v) / 100) : ''; };
  zoom(stored('ss-text'));
  if (!window.ssTabs) return;

  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, cls) => { const b = mk('button', cls, text); b.type = 'button'; return b; };
  const remote = () => !!(window.ssEnv && window.ssEnv.where === 'remote');
  const computer = () => { const e = ssTabs.topics.env; return (e && e.computer) || 'that computer'; };
  const act = (o) => ssTabs.act('settings', o).catch(() => {});
  const SECS = [['you', 'You'], ['computer', 'This computer'], ['studio', 'Studio'], ['devices', 'Devices'], ['advanced', 'Advanced']];
  const pages = {}, shown = {};
  for (const [name, label] of SECS) {
    const p = mk('section', 'settings ssset-' + name);
    p.setAttribute('aria-label', label);
    pages[name] = p;
    ssTabs.sub('settings', name, label, p, (on) => { shown[name] = on; if (on) { want(); last = null; draw(); } });
  }
  const any = () => Object.values(shown).some(Boolean);
  let wantAt = 0;
  function want() { if (Date.now() - wantAt > 9000) { wantAt = Date.now(); act({ want: true }); } }
  setInterval(() => { if (any()) want(); }, 10000);

  // ---- one row --------------------------------------------------------------------------------------------------------------------------
  function send(r, value) {
    const ask = value === true ? r.confirm_on : value === false ? r.confirm_off : null;
    if (ask && !window.confirm(ask)) return false;
    act({ set: { id: r.id, value, sure: ask ? true : undefined } });
    return true;
  }
  function drawRow(r) {
    const li = mk('div', 'prow ssrow');
    li.dataset.id = r.id;
    const off = remote() || !r.may || !!r.error;
    const why = remote() ? 'Only on ' + computer() + '’s own screen.' : !r.may ? 'Only the studio’s owner' + (r.id === 'public_links' ? '' : ' or an admin') + ' changes this.' : '';
    let ctl;
    if (r.kind === 'bool') {
      const box = mk('input');
      box.type = 'checkbox';
      box.checked = !!r.value;
      box.addEventListener('change', () => { if (!send(r, box.checked)) box.checked = !box.checked; });
      ctl = mk('label', 'pfield');
      ctl.append(box, document.createTextNode(' ' + r.label));
      box.disabled = off;
    } else if (r.kind === 'choice') {
      const sel = mk('select');
      (r.choices || []).forEach((c, i) => { const o = mk('option', '', c[1]); o.value = String(i); if (c[0] === r.value) o.selected = true; sel.append(o); });
      sel.addEventListener('change', () => { const c = (r.choices || [])[Number(sel.value)]; if (c) send(r, c[0]); });
      sel.disabled = off;
      sel.setAttribute('aria-label', r.label);
      ctl = mk('label', 'pfield');
      ctl.append(document.createTextNode(r.label + ' '), sel);
    } else if (r.kind === 'number') {
      const n = mk('input');
      n.type = 'number';
      if (r.lo != null) n.min = r.lo;
      if (r.hi != null) n.max = r.hi;
      n.value = r.value != null ? r.value : '';
      n.disabled = off;
      n.addEventListener('change', () => { if (n.value !== '') send(r, Number(n.value)); });
      ctl = mk('label', 'pfield');
      ctl.append(document.createTextNode(r.label + ' '), n);
    } else if (r.kind === 'text') {
      const t = mk('input');
      t.type = 'url';
      t.value = r.value || '';
      t.placeholder = 'https://…';
      t.setAttribute('aria-label', r.label);
      t.style.minWidth = '16em';
      t.disabled = off;
      const save = button('Save', 'sssave');
      save.disabled = off;
      save.addEventListener('click', () => send(r, t.value.trim()));
      ctl = mk('label', 'pfield');
      ctl.append(document.createTextNode(r.label + ' '), t, save);
    } else {
      ctl = button(r.label, 'pgo');
      ctl.disabled = off;
      ctl.addEventListener('click', () => send(r, true));
    }
    if (why) ctl.title = why;
    li.append(ctl);
    if (r.help) li.append(mk('span', 'dim', r.help));
    if (r.error) li.append(mk('span', 'dim', '(' + r.error + ')'));
    if (r.note) li.append(mk('p', 'pnote ssnote', r.note));
    if (r.fix) {
      const f = button(r.fix.label, 'ssfix');
      f.disabled = off;
      f.addEventListener('click', () => send(r, r.fix.value));
      li.append(f);
    }
    return li;
  }
  function drawSec(p, m, sec) {
    let grp = null;
    for (const r of (m.rows || []).filter((x) => x.sec === sec)) {
      if (r.grp !== grp) { grp = r.grp; p.append(mk('h3', '', grp)); }
      p.append(drawRow(r));
    }
  }

  // ---- the pages ------------------------------------------------------------------------------------------------------------------------
  function you(p) {
    const e = ssTabs.topics.env || {}, m = ssTabs.topics.settings || {};
    p.append(mk('h2', '', 'You'));
    const who = e.user || m.user;
    if (who) p.append(mk('p', '', 'You’re ' + who + (e.computer && e.computer !== who ? ' on ' + e.computer : '') + '.'));
    if (window.ssProfiles && ssProfiles.edit) {
      const b = button('Your picture, name and colour', 'pgo ssprofile');
      b.addEventListener('click', () => ssProfiles.edit());
      p.append(b);
    }
    const st = e.studios || [];
    if (st.length) {
      p.append(mk('h3', '', 'Your studios'));
      const ul = mk('ul', 'ssstudios');
      for (const s of st) ul.append(mk('li', '', s.name + (s.role ? ' · ' + s.role : '')));
      p.append(ul);
    }
    p.append(mk('h3', '', 'Look on this device'));
    const theme = mk('select'), size = mk('select');
    for (const [v, l] of [['', 'As the system'], ['light', 'Light'], ['dark', 'Dark']]) { const o = mk('option', '', l); o.value = v; theme.append(o); }
    theme.value = root.dataset.theme || '';
    theme.className = 'sstheme';
    theme.addEventListener('change', () => { if (theme.value) root.dataset.theme = theme.value; else delete root.dataset.theme; store('ss-theme', theme.value || null); });
    for (const v of ['80', '90', '100', '110', '125', '140', '160']) { const o = mk('option', '', v + '%'); o.value = v; size.append(o); }
    size.value = stored('ss-text') || '100';
    size.className = 'sstext';
    size.addEventListener('change', () => { store('ss-text', size.value === '100' ? null : size.value); zoom(size.value); });
    const l1 = mk('label', 'pfield'), l2 = mk('label', 'pfield');
    l1.append(document.createTextNode('Theme '), theme);
    l2.append(document.createTextNode('Text size '), size);
    const row = mk('div', 'prow');
    row.append(l1, l2);
    p.append(row, mk('p', 'dim', 'Only in this browser or window: each device keeps its own.'));
  }
  const STATE = { this: 'this computer', yours: 'yours: shows as you', waiting: 'waiting for it to say the same', asks: 'says it’s yours', other: '' };
  function devices(p, m) {
    p.append(mk('h2', '', 'Devices'));
    drawSec(p, m, 'devices');
    p.append(mk('h3', '', 'Open on your phone'));
    if (m.tailnet) p.append(mk('p', 'dim', 'This computer on Tailscale: ' + m.tailnet));
    const row = mk('div', 'prow');
    const ask = button('Show the phone link', 'ssphone');
    ask.disabled = remote();
    ask.addEventListener('click', () => act({ phone: true }));
    row.append(ask);
    if (m.phone) {
      const a = mk('code', 'ssphonelink', m.phone);
      const c = button('Copy', 'ssphonecopy');
      c.addEventListener('click', () => { const t = mk('textarea'); t.value = m.phone; document.body.append(t); t.select(); try { document.execCommand('copy'); } catch (e) {} t.remove(); c.textContent = 'Copied'; });
      row.append(a, c);
    } else if (m.phone_why) row.append(mk('span', 'dim', 'No link: ' + m.phone_why + '.'));
    p.append(row, mk('p', 'dim', 'Open it on a phone signed in to the studio’s Tailscale. It carries the studio’s web key: send it only to yourself.'));
    p.append(mk('h3', '', 'Your computers'));
    const ul = mk('ul', 'sscomputers');
    for (const c of m.computers || []) {
      const li = mk('li', 'prow');
      li.append(mk('span', '', c.user), mk('span', 'dim', STATE[c.state] || ''));
      if (c.state !== 'this') {
        const mine = c.state === 'yours' || c.state === 'waiting';
        const b = button(mine ? 'Not mine' : 'Mine too', 'ssmine');
        b.disabled = remote();
        b.addEventListener('click', () => act({ computer: { user: c.user, on: !mine } }));
        li.append(b);
      }
      ul.append(li);
    }
    if (!ul.children.length) ul.append(mk('li', 'dim', 'Only this computer in the studio so far.'));
    p.append(ul, mk('p', 'dim', 'Press Mine too here and on your other computer: once both say so, the studio shows them as one person.'));
  }
  const TITLES = { computer: 'This computer', studio: 'Studio', advanced: 'Advanced' };
  let last = null, lastEnv = null;
  function draw() {
    const m = ssTabs.topics.settings;
    if (!any() || (m === last && ssTabs.topics.env === lastEnv)) return;
    // (not while someone is typing in one of these pages: the next topic would wipe it)
    const a = document.activeElement;
    if (a && a.closest && a.closest('section.settings') && /^(INPUT|SELECT)$/.test(a.tagName) && a.type !== 'checkbox') return;
    last = m;
    lastEnv = ssTabs.topics.env;
    for (const [name] of SECS) {
      const p = pages[name];
      if (!shown[name]) continue;
      p.replaceChildren();
      if (name === 'you') { you(p); continue; }
      if (!m) { p.append(mk('h2', '', TITLES[name] || 'Devices'), mk('p', 'dim', 'Asking Live sync… (it answers while a studio project is open in REAPER here)')); continue; }
      if (m.said) { const s = mk('p', 'pnote psaid' + (m.said.bad ? ' bad' : ''), m.said.text); s.setAttribute('role', 'status'); p.append(s); }
      if (name === 'devices') { devices(p, m); continue; }
      p.append(mk('h2', '', TITLES[name]));
      if (name === 'studio') p.append(mk('p', 'dim', 'For everyone in ' + (m.studio || 'the studio') + '. Only the owner and admins change these' +
        (m.role ? ' (you’re ' + (m.role === 'open' ? 'in a studio from before owners' : 'the ' + m.role) + ')' : '') + '; never from a phone.'));
      if (remote()) p.append(mk('p', 'dim', 'Read only here: change these on ' + computer() + '’s own screen.'));
      drawSec(p, m, name);
      if (name === 'advanced') p.append(mk('p', 'dim', 'Keep selected tracks local: REAPER’s action “StudioSync: Keep selected tracks local” (every action shows with the switch above).'));
    }
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
  document.addEventListener('focusout', () => setTimeout(draw, 0));
})();
