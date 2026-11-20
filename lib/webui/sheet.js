// StudioSync's Sheet page (docs/realtime-roadmap.md "Song sheet"): the project's lyrics and chords ("[Am]" inline, ChordPro's way) and who
// plays what, section by section: a section for each of the project's regions, in order, and any added here (from a bar, for a project with
// no regions). Shared and editable live: an edit is saved a moment after typing stops (or on leaving the box) into this person's own file in
// the project's shared folder and sent to those here over the direct link (lib/songsheet.lua). Per section the latest edit wins; whoever made
// it is shown, and anyone else's version that lost stays under the section, one press from being taken back. A newer edit arriving while you
// type doesn't replace your words: it's offered. Teleprompter: the sheet big, following the play position (the section you're in lit,
// scrolled on through it), for a phone or tablet on a music stand. Everything a bandmate wrote goes in as text (textContent), never as HTML.
// GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs || !window.ssBeat) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, cls) => { const b = mk('button', cls, text); b.type = 'button'; return b; };
  const SAVE_AFTER = 1500; // ms after typing stops (each save rewrites the file Syncthing shares)
  const time = (at) => { try { return new Date(at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); } catch (e) { return ''; } };

  const page = mk('section', 'sheetpage');
  page.setAttribute('aria-label', 'Sheet');
  const bar = mk('div', 'prow'), tpOn = button('Teleprompter', 'pgo'), add = button('Add a section'), said = mk('p', 'pnote psaid');
  said.setAttribute('role', 'status');
  bar.append(tpOn, add);
  const hint = mk('p', 'dim pnote', 'Chords go in square brackets where they fall: [Am]Here comes the [F]sun. Each region in the project is a section.');
  const list = mk('div', 'slist');
  // the teleprompter
  const tp = mk('div', 'tp'), tpTop = mk('div', 'tptop'), tpWhere = mk('span', 'tpwhere'), tpFull = button('Full screen'), tpDone = button('Done', 'pgo');
  const tpBody = mk('div', 'tpbody'), tpBig = mk('div', 'tpbig');
  tpTop.append(tpWhere, tpFull, tpDone);
  tp.append(tpTop, tpBody, tpBig);
  tp.hidden = tpBig.hidden = true;
  page.append(bar, hint, said, list, tp);

  const send = (set) => ssTabs.act('sheet', { set }).then(() => { said.textContent = ''; return true; })
    .catch(() => { said.textContent = 'Couldn’t reach Live sync: not saved yet (it tries again).'; return false; });
  let me = '', focusId = null;

  // ---- ChordPro lines: a line with [chords] as chord-over-word pieces ------------------------------------------------------------------------
  function lines(into, text) {
    into.replaceChildren();
    for (const line of String(text || '').split('\n')) {
      const row = mk('div', 'cline');
      if (/^\s*\{.*\}\s*$/.test(line)) { row.classList.add('dim'); row.textContent = line.trim(); into.append(row); continue; } // (a ChordPro directive, shown as it is)
      const parts = line.split(/\[([^\]\n]{1,16})\]/);
      if (parts.length === 1) { row.textContent = line || ' '; into.append(row); continue; }
      if (parts[0]) { const p = mk('span', 'cseg'); p.append(mk('span', 'ch', ' '), mk('span', 'ly', parts[0])); row.append(p); }
      for (let i = 1; i < parts.length; i += 2) {
        const p = mk('span', 'cseg');
        p.append(mk('span', 'ch', parts[i]), mk('span', 'ly', parts[i + 1] || ' '));
        row.append(p);
      }
      into.append(row);
    }
  }

  // ---- editing --------------------------------------------------------------------------------------------------------------------------
  const cards = new Map(); // id -> card
  function card(s) {
    const c = { id: s.id, region: !!s.region, el: mk('div', 'scard'), dirty: false, timer: 0, base: s.at || 0, s };
    const head = mk('div', 'shead');
    c.name = mk('input', 'sname'); c.name.maxLength = 80; c.name.setAttribute('aria-label', 'Section name');
    c.title = mk('strong', 'stitle');
    c.where = mk('span', 'dim swhere');
    c.bar = mk('input', 'sbar'); c.bar.type = 'number'; c.bar.step = '1'; c.bar.inputMode = 'numeric'; c.bar.placeholder = 'bar';
    c.bar.title = 'The bar it starts at: the teleprompter and the Beat page follow it there';
    c.del = button('Delete', 'cdel');
    if (c.region) head.append(c.title, c.where); else head.append(c.name, mk('span', 'dim', 'from bar'), c.bar, c.del);
    c.meta = mk('div', 'dim smeta');
    c.text = mk('textarea', 'stext'); c.text.maxLength = 20000; c.text.setAttribute('aria-label', 'Lyrics and chords'); c.text.placeholder = 'Lyrics and [C]chords';
    c.plays = mk('input', 'splays'); c.plays.maxLength = 2000; c.plays.setAttribute('aria-label', 'Who plays what');
    c.plays.placeholder = 'Who plays what: Bee bass, James guitar and backing vocal';
    c.clash = mk('div', 'sclash'); c.clash.hidden = true;
    c.alts = mk('div', 'salts');
    c.el.append(head, c.meta, c.text, c.plays, c.clash, c.alts);
    const touched = () => { c.dirty = true; clearTimeout(c.timer); c.timer = setTimeout(() => save(c), SAVE_AFTER); };
    for (const f of [c.name, c.bar, c.text, c.plays]) { f.addEventListener('input', touched); f.addEventListener('blur', () => { if (c.dirty) save(c); }); }
    c.text.addEventListener('input', () => grow(c.text));
    c.del.addEventListener('click', () => { if (confirm('Delete the section “' + (c.name.value || 'untitled') + '” for everyone?')) send(Object.assign(collect(c), { del: true })); });
    return c;
  }
  const grow = (t) => { t.rows = Math.max(3, Math.min(24, t.value.split('\n').length + 1)); };
  function collect(c) {
    const b = c.bar.value.trim() === '' ? null : Math.floor(Number(c.bar.value));
    return { id: c.id, name: c.region ? c.s.name : c.name.value, text: c.text.value, plays: c.plays.value, bar: Number.isFinite(b) ? b : null, ord: c.s.ord };
  }
  function save(c) {
    clearTimeout(c.timer); c.dirty = false; c.sentAt = performance.now();
    // (not taken: still yours to send, so a copy from Live sync never puts the old words back over it)
    send(collect(c)).then((ok) => { if (!ok && !c.dirty) { c.dirty = true; c.sentAt = 0; c.timer = setTimeout(() => save(c), 5000); } });
  }
  function fill(c, s) {
    c.s = s;
    if (!c.region) { c.name.value = s.name || ''; c.bar.value = s.bar != null ? String(s.bar) : ''; } else { c.title.textContent = s.name; }
    c.text.value = s.text || ''; c.plays.value = s.plays || ''; grow(c.text);
    c.base = s.at || 0; c.sentAt = 0; c.clash.hidden = true;
  }
  // (being typed in, or just sent and not back yet: an older copy arriving meanwhile would put the old words back for a moment)
  function busy(c) { return c.dirty || c.el.contains(document.activeElement) || (c.sentAt && performance.now() - c.sentAt < 5000); }
  function update(c, s) {
    if (c.region) {
      const w = ssBeat.where(s.pos);
      c.where.textContent = w ? 'bar ' + w.bar : '';
    }
    c.meta.textContent = s.by ? 'Edited by ' + (s.by === me ? 'you' : s.by) + (s.at ? ', ' + time(s.at) : '') : 'Nobody has written here yet.';
    if (c.sentAt && s.by === me && (s.at || 0) > c.base) { c.sentAt = 0; c.base = s.at; } // (ours is back)
    if (!busy(c)) fill(c, s);
    else if (s.by && s.by !== me && s.at > c.base) { // (someone else's, newer than what you started from: offered, never put over your words)
      c.clash.replaceChildren(mk('span', '', s.by + ' changed this while you were typing. '), button('Use theirs'));
      c.clash.lastChild.addEventListener('click', () => { clearTimeout(c.timer); c.dirty = false; fill(c, s); });
      c.clash.hidden = false;
    } else c.s = s;
    c.alts.replaceChildren();
    for (const a of s.alts || []) {
      const d = mk('details', 'salt'), sum = mk('summary', 'dim', (a.by === me ? 'Your' : a.by + '’s') + ' version, ' + time(a.at) + ' (replaced by a later edit)');
      const body = mk('pre', 'saltbody', a.text + (a.plays ? '\n\n' + a.plays : '')), use = button('Use this version');
      use.addEventListener('click', () => send(Object.assign(collect(c), { text: a.text, plays: a.plays })));
      d.append(sum, body, use);
      c.alts.append(d);
    }
  }
  function drawList() {
    const sh = ssTabs.topics.sheet;
    if (!sh) { list.replaceChildren(mk('p', 'dim', 'Asking Live sync…')); return; }
    me = sh.me || me;
    const secs = sh.sections || [], keep = new Set(secs.map((s) => s.id));
    for (const [id, c] of cards) if (!keep.has(id) && !busy(c)) { c.el.remove(); cards.delete(id); }
    const want = [];
    for (const s of secs) {
      let c = cards.get(s.id);
      if (!c) { c = card(s); cards.set(s.id, c); fill(c, s); }
      update(c, s);
      want.push(c.el);
    }
    if (!secs.length) want.push(mk('p', 'dim', 'No sections yet. Add regions in REAPER (each becomes a section), or add one here.'));
    // (in order, moving only what's out of place: a box being typed in keeps its focus)
    want.forEach((e, i) => { if (list.children[i] !== e) list.insertBefore(e, list.children[i] || null); });
    while (list.children.length > want.length) list.lastChild.remove();
    if (focusId && cards.get(focusId)) { cards.get(focusId).name.focus(); focusId = null; }
  }
  add.addEventListener('click', () => {
    const secs = (ssTabs.topics.sheet && ssTabs.topics.sheet.sections) || [];
    const ord = secs.reduce((m, s) => Math.max(m, s.ord || 0), 0) + 1;
    focusId = 'h:' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
    send({ id: focusId, name: 'Section ' + (secs.length + 1), text: '', plays: '', ord });
  });

  // ---- the teleprompter -----------------------------------------------------------------------------------------------------------------
  let tpShown = false, raf = 0, drawnSheet = null, manualUntil = 0, lock = null;
  const tpEls = new Map(); // id -> its block
  function drawTp() {
    const sh = ssTabs.topics.sheet;
    if (sh === drawnSheet) return;
    drawnSheet = sh;
    tpBody.replaceChildren();
    tpEls.clear();
    for (const s of (sh && sh.sections) || []) {
      const blk = mk('div', 'tpsec'), h = mk('h3', 'tpname', s.name), body = mk('div', 'tplines');
      blk.append(h);
      if (s.plays) blk.append(mk('div', 'tpplays dim', s.plays));
      lines(body, s.text);
      blk.append(body);
      tpBody.append(blk);
      tpEls.set(s.id, blk);
    }
    if (!tpEls.size) tpBody.append(mk('p', 'dim', 'Nothing on the sheet yet.'));
  }
  const set = (e, v) => { if (e.textContent !== v) e.textContent = v; };
  function frame() {
    raf = tpShown && !document.hidden ? requestAnimationFrame(frame) : 0;
    drawTp();
    const s = ssTabs.topics.beat || {}, pos = ssBeat.pos(), w = ssBeat.where(pos), due = ssBeat.due(), cin = ssBeat.countin(pos);
    const { cur } = ssBeat.sections(ssBeat.timeline(), pos == null ? -1 : pos);
    set(tpWhere, (w ? w.bar + '.' + w.beat : '') + (cur ? '  ·  ' + cur.name : ''));
    tpWhere.classList.toggle('rec', !!s.rec); // (red while recording)
    set(tpBig, due != null ? String(Math.ceil(due)) : cin ? String(cin) : '');
    tpBig.hidden = !(due != null || cin);
    for (const [id, blk] of tpEls) blk.classList.toggle('now', !!cur && cur.id === id);
    // (scrolled on through the section you're in while playing; your own scroll holds it for a few seconds)
    const blk = cur && tpEls.get(cur.id);
    if (!blk || !s.playing || performance.now() < manualUntil) return;
    const vh = tpBody.clientHeight, span = Math.max(0, blk.offsetHeight - vh * 0.5);
    const into = cur.rend > cur.pos && Number.isFinite(cur.rend) ? Math.max(0, Math.min(1, (pos - cur.pos) / (cur.rend - cur.pos))) : 0;
    const target = blk.offsetTop - tpBody.offsetTop - vh * 0.2 + into * span;
    tpBody.scrollTop += (target - tpBody.scrollTop) * 0.12;
  }
  for (const ev of ['wheel', 'touchmove', 'keydown']) tpBody.addEventListener(ev, () => { manualUntil = performance.now() + 4000; }, { passive: true });
  async function awake(on) { // (the screen kept on while the teleprompter shows, where the browser allows: a secure page)
    try {
      if (on && !lock && navigator.wakeLock) lock = await navigator.wakeLock.request('screen');
      else if (!on && lock) { await lock.release(); lock = null; }
    } catch (e) { lock = null; }
  }
  function teleprompter(on) {
    tpShown = on;
    tp.hidden = !on;
    for (const e of [bar, hint, said, list]) e.hidden = on;
    page.classList.toggle('tpmode', on);
    awake(on);
    drawnSheet = null;
    if (on && !raf) raf = requestAnimationFrame(frame);
    if (!on && document.fullscreenElement === page) document.exitFullscreen().catch(() => {});
  }
  tpOn.addEventListener('click', () => teleprompter(true));
  tpDone.addEventListener('click', () => teleprompter(false));
  tpFull.addEventListener('click', () => {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    else if (page.requestFullscreen) page.requestFullscreen().catch(() => {});
  });
  document.addEventListener('fullscreenchange', () => set(tpFull, document.fullscreenElement === page ? 'Leave full screen' : 'Full screen'));
  document.addEventListener('visibilitychange', () => { if (tpShown && !raf && !document.hidden) raf = requestAnimationFrame(frame); if (tpShown) awake(!document.hidden); });

  let shown = false;
  ssTabs.add('sheet', 'Sheet', page, (on) => {
    shown = on;
    ssBeat.show('sheet', on);
    if (on) drawList(); else if (tpShown) teleprompter(false);
  });
  let lastSheet = null, lastMap = null; // (the map too: a region's bar is worked out from it)
  const changed = () => {
    const sh = ssTabs.topics.sheet, bm = ssTabs.topics.beatmap;
    if (shown && (sh !== lastSheet || bm !== lastMap)) { lastSheet = sh; lastMap = bm; drawList(); }
  };
  addEventListener('ss-state', changed);
  addEventListener('ss-tabs', changed);
})();
