// StudioSync's Try tab (lib/hoptry.lua, rt-hopvst): try a bandmate's plug-in you don't have, live on the selected track, with its knobs
// here, and add it to the track for real (rt-borrow); for your own plug-ins, who asks to try them (Allow / Deny) and who is trying them
// (Stop). Reads the "tryfx" topic (built only while this page says it's looking, every 10 s) and, on every tab, "tryask" (asks for your
// plug-ins: a toast with Allow / Deny); sends "tryfx" actions. Everything from a topic goes in as text, never HTML.
// GPL-3.0-or-later. (James, rt-hopvst, rt-borrow)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const btn = (text, fn, cls) => { const b = mk('button', cls || '', text); b.type = 'button'; b.addEventListener('click', fn); return b; };
  const act = (o) => ssTabs.act('tryfx', o).catch(() => {});
  const page = mk('section', 'tryfx');
  page.setAttribute('aria-labelledby', 'tryfx-h');
  // (the order: what waits on you, what you're trying, then finding another. rt-borrow: "a better UI on the Try screen")
  const ownH = mk('h2', '', 'Your plug-ins'), own = mk('ul', 'tflist');
  const triesH = mk('h2', '', 'On your tracks'), tries = mk('div', 'tftries'), ended = mk('ul', 'tflist dim');
  const h = mk('h2', '', 'Try a bandmate’s plug-in');
  h.id = 'tryfx-h';
  const intro = mk('p', 'dim tfnote', 'Plug-ins bandmates here have and you don’t. Pick one and it runs on their computer, live on your selected track, once they say yes; Add to track puts it in the project for real. Only audio, MIDI and its settings travel.');
  const search = mk('input', 'tfsearch');
  search.type = 'search'; search.placeholder = 'Part of its name'; search.setAttribute('aria-label', 'Search bandmates’ plug-ins'); search.maxLength = 80;
  const selnote = mk('p', 'dim tfnote'), found = mk('ul', 'tflist');
  tries.setAttribute('aria-live', 'polite'); own.setAttribute('aria-live', 'polite');
  page.append(ownH, own, triesH, tries, ended, h, intro, search, selnote, found);

  // Asks for your plug-ins on every tab (the "tryask" topic): Allow / Deny right there.
  const toast = mk('div', 'tftoast');
  toast.setAttribute('role', 'status'); toast.setAttribute('aria-live', 'polite'); toast.hidden = true;
  document.body.append(toast);
  const answered = {};
  function drawToast() {
    const asks = ((ssTabs.topics.tryask || {}).asks || []).filter((a) => !answered[a.token]);
    toast.hidden = !asks.length;
    toast.replaceChildren(...asks.map((a) => {
      const row = mk('div', 'tfask');
      const say = (o) => { answered[a.token] = true; act(o); drawToast(); };
      row.append(mk('span', '', a.user + ' asks to try your ' + a.key + ' on this computer (your licence; only audio, MIDI and its settings travel)'),
        btn('Allow', () => say({ allow: a.token }), 'tfyes'), btn('Deny', () => say({ refuse: a.token })));
      return row;
    }));
  }

  let shown = false, qt = 0;
  const want = () => { if (shown && !document.hidden) act({ want: true }); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  search.addEventListener('input', () => { clearTimeout(qt); qt = setTimeout(() => act({ q: search.value }), 300); });
  ssTabs.add('tryfx', 'Try', page, (on) => { shown = on; if (on) { act({ want: true, q: search.value }); draw(); } });

  // a knob being dragged sends at most every 80 ms, and its last value always
  const pend = {};
  function send(id, p, v) {
    const k = id + ':' + p;
    const o = pend[k] || (pend[k] = { t: 0 });
    o.v = v;
    if (o.t) return;
    act({ set: { id, p, v } });
    o.t = setTimeout(() => { o.t = 0; if (o.v !== v) act({ set: { id, p, v: o.v } }); }, 80);
  }
  const knobs = {}; // id -> { list element, rows: p -> { range, text } }, kept across draws so a knob being dragged isn't redrawn
  // Knobs come a page (256) at a time (rt-p4): Earlier / Later move through them; the filter looks through all of them (Live sync's side).
  function drawKnobs(t, box) {
    let k = knobs[t.id];
    if (!k || !box.contains(k.el)) {
      k = knobs[t.id] = { el: mk('div', 'tfknobs'), rows: {}, filter: mk('input', 'tffilter'), nav: mk('div', 'tfnav'), qt: 0 };
      k.filter.type = 'search'; k.filter.placeholder = 'Filter its knobs'; k.filter.setAttribute('aria-label', 'Filter knobs');
      k.filter.addEventListener('input', () => {
        for (const r of Object.values(k.rows)) r.row.hidden = !r.name.toLowerCase().includes(k.filter.value.toLowerCase());
        clearTimeout(k.qt); k.qt = setTimeout(() => act({ knobs: { id: t.id, q: k.filter.value } }), 300);
      });
      k.prev = btn('Earlier knobs', () => act({ knobs: { id: t.id, page: (k.page || 0) - 1 } }));
      k.next = btn('Later knobs', () => act({ knobs: { id: t.id, page: (k.page || 0) + 1 } }));
      k.where = mk('span', 'dim');
      k.where.setAttribute('aria-live', 'polite');
      k.nav.append(k.prev, k.where, k.next);
      box.append(k.filter, k.nav, k.el);
    }
    const pages = t.pages || 1, page = t.page || 0, shown = (t.params || []).length;
    k.page = page;
    k.nav.hidden = pages < 2 && !t.kq;
    k.prev.hidden = k.next.hidden = !!t.kq;
    k.prev.disabled = page < 1; k.next.disabled = page >= pages - 1;
    k.where.textContent = t.kq ? (t.matched || 0) + ' match' + (t.matched === 1 ? '' : 'es') + (t.matched > shown ? ', the first ' + shown + ' shown' : '')
      : ' Knobs ' + (shown ? page * 256 + 1 : 0) + '–' + (page * 256 + shown) + ' of ' + (t.total || shown) + ' ';
    const seen = {};
    let added = false;
    for (const prm of t.params || []) {
      seen[prm.i] = true;
      let r = k.rows[prm.i];
      if (!r) {
        added = true;
        const row = mk('label', 'tfknob'), name = mk('span', 'tfkname', prm.n || ('#' + prm.i)), range = mk('input'), text = mk('span', 'tfkval');
        range.type = 'range'; range.min = '0'; range.max = '1'; range.step = '0.001';
        range.addEventListener('input', () => send(t.id, prm.i, Number(range.value)));
        row.append(name, range, text);
        k.el.append(row);
        r = k.rows[prm.i] = { row, range, text, name: prm.n || '' };
        r.row.hidden = !r.name.toLowerCase().includes(k.filter.value.toLowerCase());
      }
      if (document.activeElement !== r.range) r.range.value = String(prm.v);
      r.text.textContent = prm.s;
    }
    for (const i of Object.keys(k.rows)) if (!seen[i] && document.activeElement !== k.rows[i].range) { k.rows[i].row.remove(); delete k.rows[i]; } // (another page now)
    if (added) for (const prm of t.params || []) k.el.append(k.rows[prm.i].row); // (in the knobs' order, new ones among the kept)
  }
  const boxes = {};
  function draw() {
    const m = ssTabs.topics.tryfx;
    if (!shown) return;
    if (!m) { found.replaceChildren(mk('li', 'dim', 'Asking Live sync…')); return; }
    if (m.error) { found.replaceChildren(mk('li', 'dim', 'Couldn’t read the plug-ins here: ' + m.error)); return; }
    if (!m.live) { found.replaceChildren(mk('li', 'dim', 'This needs StudioSync’s extension with live hops (Extensions > ReaPack > Synchronize packages).')); return; }
    selnote.textContent = m.sel ? 'It goes at the end of the selected track: ' + m.sel + '.' : 'Select a track in REAPER first (an instrument’s MIDI, or the audio to put through it).';
    found.replaceChildren();
    if (!(m.people || []).length) found.append(mk('li', 'dim', 'No bandmate is on the link now (Live sync on their computer too?).'));
    else if (!m.q) found.append(mk('li', 'dim', 'Type part of a name: ' + m.people.join(', ') + (m.people.length === 1 ? ' is' : ' are') + ' here.'));
    else if (!(m.matches || []).length) found.append(mk('li', 'dim', 'Nothing matches that you don’t have already.'));
    for (const f of m.matches || []) {
      const li = mk('li', 'tfitem');
      const b = btn('Try', () => act({ try: { user: f.user, key: f.key } }));
      b.disabled = !m.sel;
      li.append(mk('span', 'tfname', f.key), mk('span', 'dim', ' on ' + f.user + '’s computer'), b);
      found.append(li);
    }
    if ((m.matched || 0) > (m.matches || []).length) found.append(mk('li', 'dim', (m.matched - m.matches.length) + ' more: type more of the name.'));

    const seen = {};
    for (const t of m.tries || []) {
      seen[t.id] = true;
      let bx = boxes[t.id];
      if (!bx) {
        bx = boxes[t.id] = { el: mk('div', 'tftry'), head: mk('div', 'tfhead'), state: mk('p', 'tfstate'), knobBox: mk('div') };
        bx.el.append(bx.head, bx.state, bx.knobBox);
      }
      if (!tries.contains(bx.el)) tries.append(bx.el);
      // (a try: Add to track (borrow it for real), Print, Stop; one borrowed: it's in the project, the hop only plays it here. rt-borrow)
      const where = (t.borrowed ? ' · in the project, played live from ' : ' · trying it on ') + t.user + '’s computer · ' + (t.track || '') + (t.instrument ? ' · instrument (the track’s MIDI plays it)' : '');
      const keep = btn(t.keeping ? 'Adding…' : 'Add to track', () => act({ keep: t.id }), 'tfyes');
      keep.disabled = !!t.keeping || !t.params;
      keep.title = 'Puts it in the track’s chain for real: in the project for everyone. It runs on ' + t.user + '’s computer while you play; elsewhere the studio’s print of the track plays.';
      const print = btn(t.printing ? 'Printing…' : 'Print', () => act({ print: t.id }));
      print.disabled = !!t.printing;
      print.title = 'Records what it plays over the time selection onto a new track.';
      bx.head.replaceChildren(mk('strong', 'tfname', t.fx), mk('span', 'dim', where), ...(t.borrowed ? [] : [keep, print]),
        btn(t.borrowed ? 'Stop the hop' : 'Stop', () => act({ stop: t.id })));
      if (t.borrowed && t.keeping) bx.head.append(mk('span', 'dim', 'saving its settings into the track…'));
      bx.state.textContent = t.text || '';
      bx.state.className = 'tfstate ' + (t.ok ? 'ok' : 'warn');
      if (t.params) drawKnobs(t, bx.knobBox);
      else bx.knobBox.replaceChildren(mk('p', 'dim', 'Its knobs show here once it’s running there.'));
      if (t.params && (t.total || 0) > (t.pages || 1) * 256) { // (past the most StudioSync brings over: hoptry.PARAM_MAX)
        if (!bx.more) { bx.more = mk('p', 'dim'); bx.el.append(bx.more); }
        bx.more.textContent = 'The first ' + (t.pages || 1) * 256 + ' of its ' + t.total + ' knobs come here; the rest only in its own window there.';
      }
    }
    for (const id of Object.keys(boxes)) if (!seen[id]) { boxes[id].el.remove(); delete boxes[id]; delete knobs[id]; }
    triesH.hidden = tries.hidden = !(m.tries || []).length; // (nothing to show: no heading either)
    ended.replaceChildren(...(m.ended || []).map((x) => mk('li', '', x)));

    own.replaceChildren();
    for (const a of m.asks || []) {
      const li = mk('li', 'tfitem ask');
      li.append(mk('span', '', a.user + ' asks to try your ' + a.key + ' (your computer, your licence; a yes lasts until Live sync stops)'),
        btn('Allow', () => act({ allow: a.token }), 'tfyes'), btn('Deny', () => act({ refuse: a.token })));
      own.append(li);
    }
    for (const u of m.uses || []) {
      const li = mk('li', 'tfitem');
      li.append(mk('span', '', u.user + ' is trying your ' + u.key), btn('Stop', () => act({ end_use: u.token })));
      own.append(li);
    }
    ownH.hidden = own.hidden = !own.children.length;
  }
  addEventListener('ss-state', () => { drawToast(); draw(); });
  addEventListener('ss-tabs', draw);
})();
