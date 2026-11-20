// StudioSync's Beat page (docs/realtime-roadmap.md "Synced visuals"): a big count-in, bar.beat and the section you're in for everyone, so
// nobody misses an entry recording together. Drawn each frame from ssBeat (beat.js: the computer's play position on its link clock and the
// project's tempo map), so every phone, tablet and computer in the studio shows the same beat within a few ms; Full screen for a music stand
// (the screen kept awake where the browser allows). Reads only; nothing is drawn while it's hidden. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs || !window.ssBeat) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const page = mk('section', 'beatpage');
  page.setAttribute('aria-label', 'Beat');
  const state = mk('div', 'bstate'), big = mk('div', 'bbig'), dots = mk('div', 'bdots'), sec = mk('div', 'bsec'), next = mk('div', 'bnext dim');
  const foot = mk('div', 'bfoot'), full = mk('button', '', 'Full screen'), note = mk('span', 'dim bnote');
  const jamline = mk('div', 'bnext bjam'); // (Jam: the interval you're in and who's heard. lib/jam.lua beat_info, rt-jam)
  full.type = 'button';
  big.setAttribute('aria-live', 'off');
  foot.append(full, note);
  page.append(state, big, dots, sec, next, jamline, foot);

  let shown = false, raf = 0, lock = null;
  const set = (e, v) => { if (e.textContent !== v) e.textContent = v; };
  function frame() {
    raf = shown && !document.hidden ? requestAnimationFrame(frame) : 0;
    const s = ssTabs.topics.beat;
    if (!s) { set(state, 'Asking Live sync…'); return; }
    if (s.noclock) { set(state, 'This needs a newer StudioSync extension (Extensions > ReaPack > Synchronize packages).'); return; }
    if (ssBeat.now() == null) { set(state, 'Setting the clock…'); return; }
    const pos = ssBeat.pos(), w = ssBeat.where(pos), due = ssBeat.due(), cin = ssBeat.countin(pos);
    const mode = due != null ? 'due' : cin ? 'cin' : s.rec ? 'rec' : s.playing ? 'play' : 'stop';
    if (page.dataset.mode !== mode) page.dataset.mode = mode;
    set(state, due != null ? 'Starting together' : cin ? (s.rec ? 'Count-in: recording next' : 'Count-in') : s.rec ? 'Recording' : s.playing ? 'Playing' : 'Stopped');
    set(big, due != null ? String(Math.ceil(due)) : cin ? String(cin) : w ? w.bar + '.' + w.beat : '–');
    // (one dot a beat, the one you're on lit; the bar's first a little bigger)
    const n = w ? Math.min(w.beats, 16) : 0;
    if (dots.childElementCount !== n) dots.replaceChildren(...Array.from({ length: n }, (_, i) => mk('span', i === 0 ? 'one' : '')));
    for (let i = 0; i < n; i++) dots.children[i].classList.toggle('on', !!w && w.beat === i + 1);
    const { cur, next: nx } = ssBeat.sections(ssBeat.timeline(), pos == null ? -1 : pos);
    set(sec, cur ? cur.name : '');
    let then = '';
    if (nx) {
      const a = ssBeat.where(nx.pos);
      const bars = a && w ? a.bar - w.bar : null;
      then = 'Next: ' + nx.name + (bars != null && bars >= 0 && s.playing ? (bars === 0 ? ' (this bar)' : ' in ' + bars + (bars === 1 ? ' bar' : ' bars')) : '');
    }
    set(next, then);
    // (Jam: interval N, bar b of its L, counted from bar 1 as the others count it; whom you hear one interval late)
    const j = s.jam;
    let jt = '';
    if (j && j.bars >= 1) {
      jt = 'Jam, every ' + j.bars + (j.bars === 1 ? ' bar' : ' bars');
      if (w && w.bar >= 1) jt += ': interval ' + (Math.floor((w.bar - 1) / j.bars) + 1) + (j.bars > 1 ? ', bar ' + (((w.bar - 1) % j.bars) + 1) + ' of ' + j.bars : '');
      jt += Array.isArray(j.who) && j.who.length ? ' · hearing ' + j.who.join(', ') + ' an interval late' : ' · nobody else jamming yet';
    }
    set(jamline, jt);
  }
  function go() { if (!raf && shown && !document.hidden) raf = requestAnimationFrame(frame); }
  document.addEventListener('visibilitychange', go);
  addEventListener('ss-state', go);

  async function awake(on) { // (a phone on a music stand mustn't dim: only on a secure page, and only while full screen)
    try {
      if (on && !lock && navigator.wakeLock) lock = await navigator.wakeLock.request('screen');
      else if (!on && lock) { await lock.release(); lock = null; }
    } catch (e) { lock = null; }
  }
  full.addEventListener('click', () => {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    else if (page.requestFullscreen) page.requestFullscreen().catch(() => {});
  });
  document.addEventListener('fullscreenchange', () => {
    const on = document.fullscreenElement === page;
    set(full, on ? 'Leave full screen' : 'Full screen');
    awake(on);
  });
  page.addEventListener('dblclick', () => full.click());

  ssTabs.add('beat', 'Beat', page, (on) => {
    shown = on;
    ssBeat.show('beat', on);
    set(note, 'Every computer and phone here shows the same beat, from the studio’s shared clock.');
    if (on) go();
  });
})();
