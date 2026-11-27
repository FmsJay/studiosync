// StudioSync's Play page: who's here, and the one Follow (rt-follow, findings 2026-11-27 items 5 and 12). You follow a person (their active
// computer, or one you pick), everyone (whoever plays) or the driver: their play, pause, stop, jumps and Record, and their REAPER view. To record
// together, the one you follow arms and presses Record: you record with them on your armed tracks, or play along. Reads the "presence" and
// "play" topics (lib/webui.lua, lib/webpages.lua: "play" only while a page shows this, said every 10 s); sends on the "play" topic. Live sync
// decides (lib/follow.lua set_choice). Names go in as text, never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const field = (label, input, cls) => { const l = mk('label', 'pfield' + (cls ? ' ' + cls : '')); l.append(input, document.createTextNode(' ' + label)); return l; };
  const num = (v, max) => { const i = mk('input'); i.type = 'number'; i.min = '0'; i.max = String(max); i.step = '1'; i.value = String(v); i.inputMode = 'numeric'; return i; };
  const box = (on) => { const i = mk('input'); i.type = 'checkbox'; i.checked = on; return i; };
  const button = (text, cls) => { const b = mk('button', cls, text); b.type = 'button'; return b; };
  const MAX = 16;
  const bars = (i) => Math.max(0, Math.min(MAX, Math.floor(Number(i.value) || 0)));

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
  page.append(whoH, who, followH, row, behindF, recF, state, note, due, lastGo, said);

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
      li.append(mk('span', 'name', x.user + (x.me ? ' (you)' : '')));
      if (x.user === p.driver) li.append(mk('span', 'badge drv', 'driver'));
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
    const opts = [['', 'Nobody'], ['*', 'Everyone (whoever plays)'], ['@driver', 'The driver']].concat(list.map((x) => [x.key, x.label || x.key]));
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
