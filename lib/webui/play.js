// StudioSync's Play together page: who's here, Follow each other (side by side) and Start together, as the panel's Play/Jam page has them.
// Reads the "presence" and "play" topics (lib/webui.lua, lib/webpages.lua: "play" only while a page shows this, said every 10 s); sends on
// the "play" topic. Live sync decides: following is left alone while Real time mode is on, and Play, Record and Stop together are refused for
// whoever the room doesn't let start (the same rule as the Song page's Play). Names go in as text, never HTML. GPL-3.0-or-later. (James, rt)
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
  page.setAttribute('aria-label', 'Play together');
  // who's here
  const whoH = mk('h2', '', 'Who’s here'), who = mk('ul', 'pwho');
  // follow each other
  const sideH = mk('h2', '', 'Play, stop and record together');
  const follow = box(false), behind = num(2, MAX);
  const sideNote = mk('p', 'dim pnote');
  // start together
  const startH = mk('h2', '', 'Start together');
  const from = mk('select'), countin = num(1, MAX), click = box(true), lag = num(0, MAX);
  from.setAttribute('aria-label', 'Start from');
  const bPlay = button('Play together', 'pgo'), bRec = button('Record together', 'pgo rec'), bStop = button('Stop together', 'pgo');
  bRec.title = 'Everyone records on the tracks they have armed.';
  const due = mk('p', 'dim pnote'), lastGo = mk('p', 'dim pnote'), said = mk('p', 'pnote psaid');
  said.setAttribute('role', 'status');
  const fromRow = mk('div', 'prow');
  fromRow.append(mk('span', 'dim', 'Start from'), from);
  const opts = mk('div', 'prow');
  opts.append(field('count-in bars', countin), field('click', click), field('bars later for listeners', lag));
  lag.title = 'Time-sync only: the others start this many bars after you (one NINJAM interval), so what they hear of you lines up. Leave 0 for everything else.';
  click.parentNode.title = 'The metronome plays during the count-in, then goes back off.';
  const goes = mk('div', 'prow');
  goes.append(bPlay, bRec, bStop);
  // follow a bandmate: your REAPER's view, cursors and selection go where theirs are (lib/follow.lua); a scroll or zoom there pauses it
  const mateH = mk('h2', '', 'Follow a bandmate'), mate = mk('select'), resume = button('Resume', 'pgo'), mateNote = mk('p', 'dim pnote');
  mate.setAttribute('aria-label', 'Follow a bandmate');
  resume.hidden = true;
  resume.title = 'You scrolled or zoomed in REAPER, so your view stopped following theirs. Resume: it goes back to theirs.';
  const mateRow = mk('div', 'prow');
  mateRow.append(mate, resume);
  page.append(whoH, who, mateH, mateRow, mateNote, sideH, field('Follow each other: press play, stop and record as usual', follow, 'pfollow'), field('bars behind whoever plays', behind),
    sideNote, startH, fromRow, opts, goes, due, lastGo, said);

  let shown = false;
  const want = () => { if (shown && !document.hidden) ssTabs.act('play', { want: true }).catch(() => {}); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  ssTabs.add('play', 'Play', page, (on) => { shown = on; if (on) { want(); draw(); } });

  const send = (o) => ssTabs.act('play', o).then(() => { said.textContent = ''; }).catch(() => { said.textContent = 'Couldn’t reach Live sync.'; });
  follow.addEventListener('change', () => send({ follow: follow.checked, bars: bars(behind) }));
  behind.addEventListener('change', () => { behind.value = String(bars(behind)); if (follow.checked) send({ bars: bars(behind) }); });
  const go = (what) => send({ go: what, from: from.selectedIndex, countin: bars(countin), click: click.checked, lag: bars(lag) });
  bPlay.addEventListener('click', () => go('play'));
  bRec.addEventListener('click', () => go('record'));
  bStop.addEventListener('click', () => go('stop'));
  mate.addEventListener('change', () => send({ mate: mate.value }));
  resume.addEventListener('click', () => send({ resume: true }));

  let lastP = null, lastS = null, lastM = null, dueAt = 0, tick = 0;
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
  function mates(p, s) { // (the list only when it changes: an open list would close)
    const want = [''].concat(((p && p.people) || []).filter((x) => !x.me).map((x) => x.user));
    const at = (s && s.mate) || '';
    if (at && !want.includes(at)) want.push(at);
    if (want.join('\n') !== [...mate.options].map((o) => o.value).join('\n')) {
      mate.replaceChildren(...want.map((u) => { const o = mk('option', '', u || 'Nobody'); o.value = u; return o; }));
    }
    mate.value = at;
    resume.hidden = !(s && s.mate && s.paused);
    mateNote.textContent = !at ? 'Your REAPER’s view, edit and play cursor and selection go where theirs are, and you see which editor they have open.'
      : s.seen ? s.seen : 'Following ' + at + ': their view arrives once their StudioSync sends it (the direct link).';
  }
  function countdown() {
    const left = (dueAt - performance.now()) / 1000;
    due.textContent = left > 0 ? 'Starting in ' + left.toFixed(1) + ' s…' : 'From the spot picked, 5 s after the click, on every computer with this project open.';
    due.classList.toggle('pdue', left > 0);
    if (left <= 0 && tick) { clearInterval(tick); tick = 0; }
  }
  function draw() {
    if (!shown) return;
    const p = ssTabs.topics.presence, s = ssTabs.topics.play;
    if (p !== lastP) { lastP = p; people(p); }
    if (s === lastS && p === lastM) return;
    lastM = p;
    if (document.activeElement !== mate) mates(p, s);
    if (s === lastS) return;
    lastS = s;
    if (!s) { sideNote.textContent = 'Asking Live sync…'; return; }
    // (not while someone is typing in it: their number would jump back)
    if (document.activeElement !== behind && s.bars != null) behind.value = String(s.bars);
    follow.checked = !!s.follow;
    follow.disabled = behind.disabled = !!s.rt;
    const n = s.bars || 0;
    // (the studio's own live audio is on by default: the panel's Play/Jam page was only for NINJAM. rt-audit §3)
    const hear = s.ninjam ? 'Time-sync / Jam is connected.' : s.liveaudio ? 'You hear each other through the studio’s live audio (Call has each person’s volume).'
      : s.sonobus ? 'Real time is on.' : 'To hear each other, switch on Real time mode on the panel’s Home.';
    sideNote.textContent = s.rt ? 'Real time mode is on (the panel’s Home): everyone follows at the same spot, 0 bars behind. Switch it off there to follow later.'
      : s.follow ? 'On: you follow ' + (n === 0 ? 'right along' : n + (n === 1 ? ' bar' : ' bars')) + ' behind whoever plays. ' + hear
      : 'Whoever presses play, stop or record (or jumps somewhere while playing), everyone following follows.';
    const labels = s.from || [];
    if (labels.join('\n') !== [...from.options].map((o) => o.textContent).join('\n')) { // (only when they change: an open list would close)
      const at = from.selectedIndex;
      from.replaceChildren(...labels.map((t) => mk('option', '', t)));
      from.selectedIndex = at >= 0 && at < from.options.length ? at : 0;
    }
    for (const b of [bPlay, bRec, bStop]) { b.disabled = !s.may; b.title = s.may ? (b === bRec ? 'Everyone records on the tracks they have armed.' : '') : 'In this room ' + (s.why || 'you may not') + '.'; }
    if (!s.may) said.textContent = 'In this room ' + (s.why || 'you may not start or stop') + '.';
    else if (said.textContent.startsWith('In this room')) said.textContent = '';
    dueAt = s.due ? performance.now() + s.due * 1000 : 0;
    countdown();
    if (s.due && !tick) tick = setInterval(countdown, 100);
    lastGo.textContent = s.last ? 'Last: ' + s.last : '';
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
})();
