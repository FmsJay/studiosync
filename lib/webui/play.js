// StudioSync's Session tab (docs/rt/ui-web-plan.md Phase 6, 2.1-2.3; rt-ui6), two of its sub-tabs (Rooms is rooms.js):
// - Who's here (#here, index.html): each person (a person's computers as one: lib/persons.lua) with a ⋯ menu (Follow, hand over, Give them
//   control of, Make admin / member / owner, Remove from the studio), the asks on your claims (Release / Keep), Who can edit (the room's mode,
//   Take control, Always follow whoever is in control, "View only"), and Claims (claim what's selected in REAPER, release yours).
// - Play together: the one Follow (rt-follow, findings 2026-11-27 items 5 and 12): you follow a person (their active computer, or one you pick),
//   everyone (whoever plays) or the driver: their play, pause, stop, jumps and Record, and their REAPER view. To record together, the one you
//   follow arms and presses Record: you record with them on your armed tracks, or play along. Then How I hear (Local mixing) and Live ideas.
// Reads the "presence", "play" and "session" topics (lib/webui.lua, lib/webpages.lua: "play" only while a page shows it, said every 10 s;
// lib/websession.lua); sends on "play" and "session". Live sync decides every action and refuses what the panel would (lib/follow.lua
// set_choice, lib/websession.lua). Names go in as text, never HTML. GPL-3.0-or-later. (James, rt; rt-ui6)
'use strict';

// ---- Who's here (moved from app.js: rt-ui6) -----------------------------------------------------------------------------------------------
// (app.js's $, el and mmss: the page's shared helpers)
const ssNameOf = (u) => (window.ssProfiles ? ssProfiles.name(u) : u);
const ssSession = (o) => (window.ssTabs ? ssTabs.act('session', o) : Promise.reject(new Error('no tabs')));
function presence(p) {
  if (!p) return;
  const s = (window.ssTabs && ssTabs.topics.session) || {};
  const ul = $('people');
  ul.replaceChildren();
  for (const x of p.people || []) {
    const li = el('li', x.me ? 'me' : '');
    li.dataset.avUser = x.user; // (profile.js puts their picture in front)
    // (a person's computers are one entry, each listed under it: lib/persons.lua, rt-people)
    const devs = (x.devices || []).map((d) => d.user);
    li.append(el('span', 'name', ssNameOf(x.user) + (x.me ? ' (you)' : '')));
    if (devs.length) li.append(el('span', 'dim', ' on ' + devs.join(', ')));
    const role = !x.me && s.people && s.people[x.user] && s.people[x.user].role;
    if (role === 'owner' || role === 'admin' || role === 'guest') li.append(el('span', 'badge', role));
    if (x.user === p.driver || devs.includes(p.driver)) li.append(el('span', 'badge drv', 'in control')); // (James, 2026-11-27: "In control" replaces "driver")
    if (x.recording) li.append(el('span', 'badge rec', 'recording'));
    else if (x.playing) li.append(el('span', 'badge play', 'playing'));
    if (x.live === 'rt') li.append(el('span', 'badge', 'real time'));
    else if (x.live === 'ts') li.append(el('span', 'badge', 'time-sync'));
    if (x.call) li.append(el('span', 'badge', 'on the call'));
    // the person menu (rt-ui6): what you may do about them, the panel's right-click menu
    const mb = el('button', 'pmenu-b', '⋯');
    mb.type = 'button';
    mb.title = x.me ? 'Your name and colour' : 'Follow, hand over, give them control, their role';
    mb.setAttribute('aria-label', 'Menu for ' + ssNameOf(x.user));
    mb.setAttribute('aria-haspopup', 'menu');
    mb.addEventListener('click', (e) => { e.stopPropagation(); personMenu(x, mb); });
    li.append(mb);
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
    const cn = ssNameOf(c.user); // (the person, and the computer when it differs: rt-people)
    const li = el('li', '', cn + (cn !== c.user ? ' (' + c.user + ')' : '') + ': ' + what + (c.auto ? ' (while editing)' : ''));
    if (s.me && c.user === s.me) { // (yours: let go of it, the panel's x on the chip)
      const b = el('button', 'prel', 'Release');
      b.type = 'button';
      b.title = 'Let go of it: it follows whoever is in control again';
      const kind = { track: 'tracks', region: 'regions', time: 'times' }[c.kind];
      b.addEventListener('click', () => { b.disabled = true; ssSession({ release: c.kind === 'time' ? { kind, from: c.from, to: c.to } : { kind, name: c.name } }).catch(() => { b.disabled = false; }); });
      li.append(' ', b);
    }
    cl.append(li);
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
  // StudioSync's own questions to this computer's person (a big deletion, an Undo: the panel's bar): Yes / No here too, from a page on this
  // computer only; elsewhere the words and where to answer. (rt-askweb)
  const away = !!(window.ssEnv && window.ssEnv.where === 'remote');
  for (const q of a.local_asks || []) {
    const li = el('li', 'ask localask', q.text + ' (');
    li.dataset.kind = q.kind;
    li.append(askTill(q.till), ') ');
    if (away) { li.append(el('span', 'dim', 'Answer this in StudioSync on the computer itself.')); ul.append(li); continue; }
    for (const [label, yes, tip] of q.kind === 'delete' ? [['Yes', true, 'Delete them for everyone'], ['No', false, 'Keep them: they come back here, and nothing goes to the others']]
      : [['Yes', true, 'Go ahead: it goes to everyone'], ['No', false, 'Nothing changes']]) {
      const b = el('button', '', label);
      b.type = 'button';
      b.title = tip;
      b.addEventListener('click', () => {
        for (const x of li.querySelectorAll('button')) x.disabled = true;
        fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
          body: JSON.stringify({ topic: 'claimask', ask: q.kind, id: q.id, yes }) }).catch(() => { for (const x of li.querySelectorAll('button')) x.disabled = false; });
      });
      li.append(b);
    }
    ul.append(li);
  }
}

// ---- the person menu (rt-ui6): the panel's right-click menu on a name, confirmed in the page -----------------------------------------------
const pmenu = el('div', 'ssmenulist pmenu');
pmenu.setAttribute('role', 'menu');
pmenu.hidden = true;
document.body.append(pmenu);
const closeP = () => { pmenu.hidden = true; pmenu.replaceChildren(); };
addEventListener('click', (e) => { if (!pmenu.hidden && !pmenu.contains(e.target)) closeP(); });
addEventListener('keydown', (e) => { if (e.key === 'Escape' && !pmenu.hidden) closeP(); });
function pItem(text, fn, tip, off) {
  const b = el('button', '', text);
  b.type = 'button';
  b.setAttribute('role', 'menuitem');
  if (tip) b.title = tip;
  b.disabled = !!off;
  b.addEventListener('click', (e) => { e.stopPropagation(); fn(); });
  pmenu.append(b);
}
function pAsk(q, yes, fn) { pmenu.replaceChildren(el('p', '', q)); pItem(yes, () => { closeP(); fn(); }); pItem('Cancel', closeP); }
function personMenu(x, btn) {
  const s = (window.ssTabs && ssTabs.topics.session) || {};
  const who = ssNameOf(x.user);
  pmenu.replaceChildren(el('p', 'dim', who));
  if (x.me) {
    pItem('Change my name, colour…', () => { closeP(); if (window.ssProfiles) ssProfiles.edit(); });
  } else {
    const users = (x.devices || []).map((d) => d.user).filter((u) => u !== s.me);
    if (!users.length) users.push(x.user);
    const can = (k) => users.filter((u) => s.people && s.people[u] && s.people[u].can && s.people[u].can[k]);
    const here = !window.ssEnv || ssEnv.where !== 'remote'; // (roles and removal: this computer's own page only, decision 4)
    const key = (s.people && s.people[users[0]] && s.people[users[0]].key) || x.user;
    let any = false;
    pItem('Follow ' + who, () => { closeP(); ssTabs.act('play', { choice: key, computer: '' }).catch(() => {}); }, 'Their play, stop, Record and view: Play together');
    if (can('handover').length) {
      any = true;
      pItem('Hand over control…', () => pAsk('Make ' + who + ' in control?', 'Hand over', () => ssSession({ handover: can('handover')[0] })));
    }
    if (can('give').length) {
      any = true;
      const sel = s.sel || {}, t = sel.tracks || [], r = sel.regions || [];
      const give = (what, words) => pAsk('Give ' + who + ' ' + words + ' to change? If someone else has it claimed, it moves to ' + who + '.', 'Give',
        () => ssSession({ give: { user: can('give')[0], what } }));
      pmenu.append(el('p', 'dim', 'Give them control of (what’s selected in REAPER):'));
      pItem(t.length ? (t.length === 1 ? 'Selected track: ' : 'Selected tracks: ') + t.join(', ') : 'Selected tracks (none selected)', () => give('tracks', t.join(', ')), null, !t.length);
      pItem(r.length ? 'Selected region: ' + r.join(', ') : 'Selected region (click one in the ruler)', () => give('regions', 'the region ' + r.join(', ')), null, !r.length);
      pItem(sel.time ? 'Time selection: ' + mmss(sel.time.from) + ' to ' + mmss(sel.time.to) : 'Time selection (drag across the ruler)', () => give('time', 'the time selection'), null, !sel.time);
    }
    const adm = can('admin');
    if (adm.length && here) {
      any = true;
      const on = s.people[adm[0]].can.admin === 'admin';
      pItem(on ? 'Make admin…' : 'Make member…', () => pAsk(on ? 'Make ' + who + ' an admin? They can let people in, rename the studio, remove members and give claims. Only you can close it.'
        : 'Make ' + who + ' a member again? They can’t let people in, rename the studio or remove anyone any more.', on ? 'Make admin' : 'Make member',
        () => { for (const u of adm) ssSession({ admin: { user: u, on } }); }));
    }
    if (can('owner').length && here) {
      any = true;
      pItem('Make owner…', () => pAsk('Make ' + who + ' the owner of the studio? You stay on as an admin. Only they can give it back.', 'Make owner', () => ssSession({ owner: can('owner')[0] })));
    }
    if (can('keep').length) { any = true; pItem('Keep them', () => { closeP(); for (const u of can('keep')) ssSession({ keep: u }); }, 'Changed your mind: nothing has happened yet'); }
    if (can('remove').length && here) {
      any = true;
      pItem('Remove from the studio…', () => pAsk('Take ' + who + ' out of the studio? Within a few minutes every computer stops syncing with theirs. Their claims go free; what they made stays. ' +
        'They keep the copy they have. You have a minute to change your mind.', 'Remove', () => { for (const u of can('remove')) ssSession({ remove: u }); }));
    }
    if (!any) pmenu.append(el('p', 'dim', here ? 'Nothing more here for you: the owner and admins manage the studio.' : 'Roles and removing someone: on the studio computer’s own page.'));
  }
  const r = btn.getBoundingClientRect();
  pmenu.hidden = false;
  pmenu.style.left = Math.max(4, Math.min(r.left, innerWidth - pmenu.offsetWidth - 8)) + 'px';
  pmenu.style.top = Math.min(r.bottom + 4, Math.max(4, innerHeight - pmenu.offsetHeight - 8)) + 'px';
}

(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const field = (label, input, cls) => { const l = mk('label', 'pfield' + (cls ? ' ' + cls : '')); l.append(input, document.createTextNode(' ' + label)); return l; };
  const num = (v, max) => { const i = mk('input'); i.type = 'number'; i.min = '0'; i.max = String(max); i.step = '1'; i.value = String(v); i.inputMode = 'numeric'; return i; };
  const box = (on) => { const i = mk('input'); i.type = 'checkbox'; i.checked = on; return i; };
  const button = (text, cls) => { const b = mk('button', cls, text); b.type = 'button'; return b; };
  const MAX = 16;
  const bars = (i) => Math.max(0, Math.min(MAX, Math.floor(Number(i.value) || 0)));

  // ---- Who's here's own parts: Who can edit and Claims' buttons, in #here (rt-ui6) ------------------------------------------------------
  const here = document.getElementById('here');
  const wce = mk('div', 'pwce'), cbtn = mk('div', 'pclaim'), ssaid = mk('p', 'pnote psaid');
  ssaid.setAttribute('role', 'status');
  const vo = mk('p', 'pnote pdue pviewonly');
  vo.setAttribute('role', 'status');
  if (here) {
    const h3 = here.querySelector('h3'), cl = document.getElementById('claims');
    here.insertBefore(vo, here.querySelector('h2').nextSibling);
    here.insertBefore(mk('h3', '', 'Who can edit'), h3);
    here.insertBefore(wce, h3);
    if (cl) cl.after(cbtn, ssaid);
  }
  const modeSel = mk('select'), modeL = mk('label', 'prow');
  modeSel.setAttribute('aria-label', 'Who can edit');
  modeL.append('Who can edit ', modeSel);
  const drvLine = mk('p', 'pnote'), takeB = button('Take control', 'pgo'), anyB = button('Take control anyway', 'pgo'), takeRow = mk('div', 'prow');
  anyB.hidden = true;
  takeRow.append(takeB, anyB);
  const fdBox = box(false), fdF = field('Always follow whoever is in control', fdBox, 'pfollow');
  fdF.title = 'Your playhead, view and mix follow whoever is in control: they press play, you play along, hearing what they hear. Only they record.';
  wce.append(modeL, drvLine, takeRow, fdF);
  modeSel.addEventListener('change', () => ssSession({ mode: modeSel.value }).catch(() => {}));
  takeB.addEventListener('click', () => ssSession({ take: true }).catch(() => {}));
  anyB.addEventListener('click', () => { anyB.hidden = true; ssSession({ take: true, anyway: true }).catch(() => {}); });
  fdBox.addEventListener('change', () => ssSession({ followdriver: fdBox.checked }).catch(() => {}));
  const cT = button('Claim selected tracks'), cR = button('Claim selected region'), cS = button('Claim time selection'), cA = button('Release all claims');
  cT.title = 'The tracks you’ve selected in REAPER become yours: only you change them, whoever is in control.';
  cR.title = 'Click a region in REAPER’s ruler, then this: what’s in it is yours.';
  cS.title = 'Drag across REAPER’s ruler, then this: whatever starts inside it is yours (a track someone claimed still wins).';
  const lockN = mk('span', 'dim', 'Admins only here: an admin can give you tracks to work on.'), relFor = mk('span');
  cbtn.append(cT, cR, cS, cA, lockN, relFor);
  cT.addEventListener('click', () => ssSession({ claim: 'tracks' }).catch(() => {}));
  cR.addEventListener('click', () => ssSession({ claim: 'regions' }).catch(() => {}));
  cS.addEventListener('click', () => ssSession({ claim: 'time' }).catch(() => {}));
  let relAsk = 0; // (the panel asks first: a second press within 4 s here)
  cA.addEventListener('click', () => {
    if (Date.now() - relAsk > 4000) { relAsk = Date.now(); cA.textContent = 'Release all: sure?'; setTimeout(() => { cA.textContent = 'Release all claims'; }, 4000); return; }
    relAsk = 0; cA.textContent = 'Release all claims';
    ssSession({ release: 'all' }).catch(() => {});
  });
  const fillSel = (sel, opts) => { // (only when they change: an open list would close)
    const want = opts.map((o) => o[0] + '\t' + o[1]).join('\n');
    if (want !== [...sel.options].map((o) => o.value + '\t' + o.textContent).join('\n')) sel.replaceChildren(...opts.map(([v, t]) => { const o = mk('option', '', t); o.value = v; return o; }));
  };
  let lastSess = null, lastPres = null;
  function session() {
    const s = ssTabs.topics.session, p = ssTabs.topics.presence;
    if (p !== lastPres || s !== lastSess) { lastPres = p; presence(p); }
    if (s === lastSess) return;
    lastSess = s;
    if (!s || s.error) { wce.hidden = cbtn.hidden = true; vo.textContent = ''; return; }
    wce.hidden = cbtn.hidden = false;
    if (document.activeElement !== modeSel) { fillSel(modeSel, (s.modes || []).map((m) => [m.id, m.name])); modeSel.value = s.mode; }
    modeSel.disabled = !s.may_set;
    const m = (s.modes || []).find((x) => x.id === s.mode);
    modeL.title = (m ? m.tip : '') + (s.may_set ? '' : '\nThe studio’s owner or an admin picks this.');
    const dn = s.driver ? ssNameOf(s.driver) : 'Nobody';
    drvLine.textContent = s.alone ? 'Nobody else is here: you have full control. Everything you change goes to the others, and reaches them when they’re back.'
      : s.driving ? 'You’re in control.' : s.away ? ssNameOf(s.away) + ' is in control but isn’t here. Take control to carry on (they can take it back when they return).'
      : dn + ' is in control.';
    takeB.hidden = !!s.driving;
    takeB.textContent = s.away ? 'Take control now' : 'Take control';
    takeB.title = 'Tell them first, then take control: ' + (s.take || '') + '.';
    anyB.hidden = !(s.said && s.said.take && !s.driving);
    fdBox.checked = !!s.followdriver;
    vo.textContent = s.viewonly === 'driver' ? 'View only: ' + dn + ' is in control. Your changes are put back; what you record stays on this computer.'
      : s.viewonly === 'admins' ? 'View only: admins only here. Your changes are put back; what you record stays on this computer.' : '';
    const sel = s.sel || {};
    cT.textContent = 'Claim selected tracks' + ((sel.tracks || []).length ? ' (' + sel.tracks.length + ')' : '');
    for (const b of [cT, cR, cS]) b.hidden = !!s.locked;
    cT.disabled = !(sel.tracks || []).length; cR.disabled = !(sel.regions || []).length; cS.disabled = !sel.time;
    cA.disabled = !(s.claims || []).length;
    lockN.hidden = !s.locked;
    relFor.replaceChildren();
    for (const u of s.release || []) { // (whoever is in control lets go of what someone away holds, the panel's)
      const b = button('Release ' + ssNameOf(u) + '’s claims');
      b.title = u + ' isn’t here: their claims keep those parts locked for everyone until released. They’re told when they’re back.';
      b.addEventListener('click', () => ssSession({ release_for: u }).catch(() => {}));
      relFor.append(b);
    }
    ssaid.textContent = s.said ? s.said.text : '';
    ssaid.classList.toggle('pok', !!(s.said && s.said.ok));
    drawHear(s);
  }

  // ---- Play together: the one Follow ----------------------------------------------------------------------------------------------------
  const page = mk('section', 'play');
  page.setAttribute('aria-label', 'Play and follow');
  // who's here
  const whoH = mk('h2', '', 'Who’s here'), who = mk('ul', 'pwho');
  // the one Follow
  const followH = mk('h2', '', 'Follow');
  const pick = mk('select'), computer = mk('select'), resume = button('Resume', 'pgo');
  pick.setAttribute('aria-label', 'Follow');
  computer.setAttribute('aria-label', 'Which of their computers');
  computer.hidden = true;
  resume.hidden = true;
  resume.title = 'You scrolled or zoomed in REAPER, so your view stopped following theirs (their play and stop still come). Resume: back to theirs.';
  const behind = num(2, MAX), behindF = field('bars behind whoever plays', behind);
  behindF.hidden = true;
  const recAlong = box(true), recF = field('Record with them on my armed tracks (off: play along)', recAlong, 'pfollow');
  const state = mk('p', 'pnote pstate'), note = mk('p', 'dim pnote'), due = mk('p', 'dim pnote'), lastGo = mk('p', 'dim pnote'), said = mk('p', 'pnote psaid');
  state.setAttribute('role', 'status');
  said.setAttribute('role', 'status');
  note.textContent = 'Press play, pause, stop or record in REAPER as usual: whoever follows you does the same and sees your view. ' +
    'To record together, arm your tracks and press Record: everyone following you who has a track armed records with you; the others play along.';
  const row = mk('div', 'prow');
  row.append(pick, computer, resume);
  // How I hear: Local mixing (rt-ui6; each person's volume is the call's)
  const hearH = mk('h2', '', 'How I hear'), lmBox = box(false), lmF = field('Local mixing (your faders and pan stay yours)', lmBox, 'pfollow');
  lmF.title = 'Nobody else’s faders and pan reach you, and yours don’t go out. Also as the action StudioSync - Local mixing.';
  const lmAsk = mk('div', 'plmask'), lmTheirs = button('Use the studio’s mix'), lmMine = button('Send my faders and pan to everyone'), lmNo = button('Keep Local mixing on');
  lmTheirs.title = 'Your faders and pan follow the studio’s again';
  lmMine.title = 'Your faders and pan go to everyone (the tracks you may change)';
  lmAsk.append(mk('span', '', 'Local mixing off: whose mix?'), lmTheirs, lmMine, lmNo);
  lmAsk.hidden = true;
  const hearNote = mk('p', 'dim pnote', 'Each person’s volume and mute: the call’s controls (Chat > Call).');
  lmBox.addEventListener('change', () => {
    if (lmBox.checked) { lmAsk.hidden = true; ssSession({ localmix: true }).catch(() => {}); return; }
    lmBox.checked = true; lmAsk.hidden = false; // (named choices, as the panel's: a plain off sent your mix to everyone)
  });
  lmTheirs.addEventListener('click', () => { lmAsk.hidden = true; ssSession({ localmix: false, keep: 'theirs' }).catch(() => {}); });
  lmMine.addEventListener('click', () => { lmAsk.hidden = true; ssSession({ localmix: false, keep: 'mine' }).catch(() => {}); });
  lmNo.addEventListener('click', () => { lmAsk.hidden = true; });
  // Live ideas: what you heard in Time-sync, until the real takes arrive
  const ideasH = mk('h2', '', 'Live ideas'), ideas = mk('ul', 'pwho pideas'), ideasRow = mk('div', 'prow');
  const keepB = button('Keep selected'), dropB = button('Dismiss all');
  keepB.title = 'The selected placeholders in REAPER stay for good (no take replaces them). Send them to main if the studio should have them.';
  ideasRow.append(keepB, dropB);
  keepB.addEventListener('click', () => ssSession({ ideas: 'keep' }).catch(() => {}));
  dropB.addEventListener('click', () => ssSession({ ideas: 'dismiss' }).catch(() => {}));
  const ideasNote = mk('p', 'dim pnote', 'What you heard in Time-sync, until the real takes arrive.');
  page.append(whoH, who, followH, row, behindF, recF, state, note, due, lastGo, said, hearH, lmF, lmAsk, hearNote, ideasH, ideasNote, ideas, ideasRow);
  function drawHear(s) {
    if (document.activeElement !== lmBox && lmAsk.hidden) lmBox.checked = !!s.localmix;
    const list = s.ideas || [];
    ideasH.hidden = ideasNote.hidden = ideas.hidden = ideasRow.hidden = !list.length;
    ideas.replaceChildren(...list.map((i) => {
      const li = mk('li', '', ssNameOf(i.who) + ': ' + i.n + ' ');
      const b = button('Dismiss');
      b.addEventListener('click', () => ssSession({ ideas: 'dismiss', who: i.who }).catch(() => {}));
      li.append(b);
      return li;
    }));
  }
  addEventListener('ss-state', session);
  addEventListener('ss-tabs', session);
  session(); // (a state that came before this file ran: app.js drew it at once, rt-ui6 draws what tabs.js kept)

  let shown = false;
  const want = () => { if (shown && !document.hidden) ssTabs.act('play', { want: true }).catch(() => {}); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  ssTabs.add('play', 'Play', page, (on) => { shown = on; if (on) { want(); draw(); } });

  const send = (o) => ssTabs.act('play', o).then(() => { said.textContent = ''; }).catch(() => { said.textContent = 'Couldn’t reach Live sync.'; });
  pick.addEventListener('change', () => send({ choice: pick.value, computer: '', bars: bars(behind) }));
  computer.addEventListener('change', () => send({ choice: pick.value, computer: computer.value }));
  behind.addEventListener('change', () => { behind.value = String(bars(behind)); if (pick.value === '*') send({ choice: '*', bars: bars(behind) }); });
  recAlong.addEventListener('change', () => send({ norec: !recAlong.checked }));
  resume.addEventListener('click', () => send({ resume: true }));

  const same = (sel, opts) => opts.map((o) => o[0] + '\t' + o[1]).join('\n') === [...sel.options].map((o) => o.value + '\t' + o.textContent).join('\n');
  function fill(sel, opts) { // (only when they change: an open list would close)
    if (!same(sel, opts)) sel.replaceChildren(...opts.map(([v, t]) => { const o = mk('option', '', t); o.value = v; return o; }));
  }
  let lastP = null, lastS = null, dueAt = 0, tick = 0;
  function people(p) {
    who.replaceChildren();
    for (const x of (p && p.people) || []) {
      const li = mk('li', x.me ? 'me' : '');
      li.append(mk('span', 'name', ssNameOf(x.user) + (x.me ? ' (you)' : '')));
      if (x.user === p.driver) li.append(mk('span', 'badge drv', 'in control'));
      if (x.recording) li.append(mk('span', 'badge rec', 'recording'));
      else if (x.playing) li.append(mk('span', 'badge play', 'playing'));
      if (x.live === 'rt') li.append(mk('span', 'badge', 'real time'));
      else if (x.live === 'ts') li.append(mk('span', 'badge', 'time-sync'));
      who.append(li);
    }
    if (!p || (p.people || []).length < 2) who.append(mk('li', 'dim', 'Nobody else is here right now.'));
  }
  function countdown() {
    const left = (dueAt - performance.now()) / 1000;
    due.textContent = left > 0 ? 'Starting in ' + left.toFixed(1) + ' s…' : '';
    due.classList.toggle('pdue', left > 0);
    if (left <= 0 && tick) { clearInterval(tick); tick = 0; }
  }
  function draw() {
    if (!shown) return;
    const p = ssTabs.topics.presence, s = ssTabs.topics.play;
    if (p !== lastP) { lastP = p; people(p); }
    if (s === lastS) return;
    lastS = s;
    if (!s) { state.textContent = 'Asking Live sync…'; return; }
    const list = s.people || [];
    const opts = [['', 'Nobody'], ['*', 'Everyone (whoever plays)'], ['@driver', 'Whoever is in control']].concat(list.map((x) => [x.key, x.label || x.key]));
    const c = s.choice || '';
    if (c && !opts.some((o) => o[0] === c)) opts.push([c, c + ' (not here now)']);
    if (document.activeElement !== pick) { fill(pick, opts); pick.value = c; }
    const person = list.find((x) => x.key === c);
    computer.hidden = !(person && person.users.length > 1);
    if (!computer.hidden && document.activeElement !== computer) {
      fill(computer, [['', 'Their active computer' + (person.active ? ' (' + person.active + ')' : '')]].concat(person.users.map((u) => [u, u])));
      computer.value = s.pinned && person.users.includes(s.pinned) ? s.pinned : '';
    }
    resume.hidden = s.state !== 'paused';
    behindF.hidden = c !== '*';
    if (document.activeElement !== behind && s.bars != null) behind.value = String(s.bars);
    behind.disabled = !!s.rt;
    recAlong.checked = !s.norec;
    // (said only as it really is: "Connecting" until their view arrives naming you. lib/follow.lua words)
    // (and following everyone, how you hear each other: the studio's own live audio is on by default. rt-audit §3)
    const hear = s.ninjam ? 'Time-sync / Jam is connected.' : s.liveaudio ? 'You hear each other through the studio’s live audio (Call has each person’s volume).'
      : s.sonobus ? 'Real time is on.' : 'To hear each other, switch on Real time mode on the panel’s Home.';
    state.textContent = (s.line || '') + (c === '*' ? ' ' + hear : '');
    state.classList.toggle('pdue', s.state === 'waiting');
    dueAt = s.due ? performance.now() + s.due * 1000 : 0; // (a start from someone's older StudioSync: its count-down)
    countdown();
    if (s.due && !tick) tick = setInterval(countdown, 100);
    lastGo.textContent = s.last ? 'Last: ' + s.last : '';
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
})();
