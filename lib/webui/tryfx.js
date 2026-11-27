// StudioSync's Try tab (lib/hoptry.lua, rt-hopvst): try a bandmate's plug-in you don't have, live on the selected track, with its knobs
// here, and add it to the track for real (rt-borrow); for your own plug-ins, who asks to try them (Allow / Deny) and who is trying them
// (Stop). Reads the "tryfx" topic (built only while this page says it's looking, every 10 s) and, on every tab, "tryask" (asks for your
// plug-ins: a toast with Allow / Deny); sends "tryfx" actions. Everything from a topic goes in as text, never HTML.
// The Plug-ins tab's other subs (This project, Find a plug-in, Plug-in pack) are at the end (rt-ui10a).
// GPL-3.0-or-later. (James, rt-hopvst, rt-borrow, rt-ui10a)
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
  const answered = {}, woke = {};
  function drawToast() {
    const asks = ((ssTabs.topics.tryask || {}).asks || []).filter((a) => !answered[a.token]);
    toast.hidden = !asks.length;
    // (a new ask brings the REAPER window back from the strip or the button, where the toast can't show: ui-web-plan 4.5, rt-ui10a)
    const E = window.ssEnv || {};
    if (asks.some((a) => !woke[a.token]) && E.where === 'reaper' && document.body.dataset.win && window.ssShell && E.send) { ssShell.setWin(''); E.send('win:full'); }
    for (const a of asks) woke[a.token] = true;
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
      // (its own window, shared by its owner once they say yes; control of it can then be asked for: rt-share, lib/webui/call.js)
      const win = btn('Show its window', () => window.ssShare.askWindow({ user: t.user, token: t.token, fx: t.fx }));
      win.title = 'Asks ' + t.user + ' to share the plug-in’s own window with you (they say yes each time); then you can ask for control of it.';
      bx.head.replaceChildren(mk('strong', 'tfname', t.fx), mk('span', 'dim', where), ...(t.borrowed ? [] : [keep, print]),
        ...(window.ssShare && window.ssShare.canWatch && t.token ? [win] : []), btn(t.borrowed ? 'Stop the hop' : 'Stop', () => act({ stop: t.id })));
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

// ---- The Plug-ins tab's other subs (docs/rt/ui-web-plan.md Phase 10a, rt-ui10a): This project (each plug-in, who lacks it, the studio's
// stand-ins, drum maps, the folder of what everyone has), Find a plug-in (REAPER's categories, only what everyone has, Add) and Plug-in pack,
// from the "plugins" topic (lib/webplugins.lua: the panel's own models, built while one of these says it shows, every 10 s). What changes the
// project, writes a file or opens a REAPER window works from this computer's page only (Live sync refuses it from anywhere else); another
// device sees the lists read only. ?pop=plugins pops the whole tab out with its sub-tabs.
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const btn = (text, fn, cls) => { const b = mk('button', cls || '', text); b.type = 'button'; b.addEventListener('click', fn); return b; };
  const E = window.ssEnv || { where: 'local' };
  const remote = E.where === 'remote';
  const act = (o) => ssTabs.act('plugins', o).catch(() => {});
  const computer = () => (ssTabs.topics.env && ssTabs.topics.env.computer) || 'the computer serving this page';
  const HERE = ['reaper', 'local'];
  if (E.pop === 'plugins') document.body.classList.add('tfpoptab'); // (tryfx.css shows the sub-tabs in this pop-out)

  const shown = {};
  const anyShown = () => Object.values(shown).some(Boolean);
  const want = () => { if (anyShown() && !document.hidden) act({ want: true }); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  let last = null, removing = null, rmt = 0;
  const onShow = (name) => (v) => { shown[name] = v; if (v) { act({ want: true }); last = null; draw(); } };
  // (a press that would change something: hidden on another device, with a line saying where it's done)
  const roNote = () => { const p = mk('p', 'dim tfnote tfro'); p.hidden = !remote; return p; };
  const saidLine = () => { const p = mk('p', 'pnote tfsaid'); p.setAttribute('role', 'status'); return p; };
  const head = (text, id) => { const h = mk('h2', '', text); if (id) h.id = id; return h; };
  const field = (label, el) => { const l = mk('label', 'pfield'); l.append(document.createTextNode(label + ' '), el); return l; };

  // ---- This project ---------------------------------------------------------------------------------------------------------------------
  const pPage = mk('section', 'tfp');
  pPage.setAttribute('aria-labelledby', 'tfp-h');
  const pRo = roNote(), pSaid = saidLine();
  const apply = btn('Apply stand-ins here', () => act({ apply: true }), 'tfyes tfapply');
  apply.title = 'Adds the studio’s stand-in right after each plug-in this computer doesn’t have, so you hear something close. Only on this computer; the original stays in the project for everyone who has it.';
  apply.hidden = true;
  const rows = mk('ul', 'tflist tfrows'), pEmpty = mk('p', 'dim tfnote');
  rows.setAttribute('aria-live', 'polite');
  // the stand-in picker: a plain search of this computer's plug-ins (the panel's right-click list; REAPER's own Add FX window stays the panel's)
  const picker = mk('div', 'tfpicker');
  picker.hidden = true;
  const pickFor = mk('p', 'tfnote'), pickQ = mk('input', 'tfsearch'), pickList = mk('ul', 'tflist tfpicks'), pickMore = mk('p', 'dim tfnote');
  pickQ.type = 'search'; pickQ.placeholder = 'Type to search your plug-ins'; pickQ.maxLength = 80; pickQ.setAttribute('aria-label', 'Search your plug-ins for a stand-in');
  let picking = null, pqt = 0;
  pickQ.addEventListener('input', () => { clearTimeout(pqt); pqt = setTimeout(() => act({ pick: pickQ.value }), 300); });
  picker.append(pickFor, pickQ, pickList, pickMore, btn('Cancel', () => { picking = null; picker.hidden = true; }));
  function openPicker(r) {
    picking = r;
    pickFor.textContent = 'Something close to ' + r.name + ', from your plug-ins:';
    pickQ.value = '';
    pickList.replaceChildren();
    picker.hidden = false;
    act({ pick: '' });
    pickQ.focus();
  }
  // drum maps (the panel's: on the tracks selected in REAPER; the maps themselves are the studio's files)
  const dSel = mk('p', 'tfnote'), dStat = mk('p', 'dim tfnote');
  const dFrom = mk('select'), dTo = mk('select');
  dFrom.className = 'tfdfrom'; dTo.className = 'tfdto';
  dFrom.addEventListener('change', () => act({ drum: { from: dFrom.value } }));
  dTo.addEventListener('change', () => act({ drum: { to: dTo.value } }));
  const dRow = mk('div', 'prow');
  dRow.append(field('Written for', dFrom), field('Played here on', dTo));
  const make = mk('details', 'tfmake');
  make.hidden = remote;
  const makeName = mk('input', 'tfsearch'), makeKit = mk('div', 'tfkit'), makeWhy = mk('p', 'pnote tfsaid');
  makeName.placeholder = 'The drum plug-in’s name'; makeName.maxLength = 64; makeName.setAttribute('aria-label', 'The drum plug-in’s name');
  const kitInputs = {};
  make.append(mk('summary', '', 'Make a map…'), mk('p', 'dim tfnote', 'Name a drum plug-in and say which note plays what (its manual lists them, or play it and watch). Everyone in the studio can use the map once it’s made; only the choice above is yours.'),
    makeName, makeKit, btn('Save', () => {
      const notes = {};
      for (const k in kitInputs) notes[k] = Number(kitInputs[k].value);
      const n = makeName.value.trim();
      if (!n || n.toLowerCase() === 'gm') { makeWhy.textContent = 'Give it the plug-in’s name.'; return; }
      makeWhy.textContent = '';
      act({ map: { name: n, notes } });
      make.open = false;
    }, 'tfyes tfsave'), makeWhy);
  const fInfo = mk('p', 'tfnote'), fBtn = btn('Update the folder now', () => act({ folder: true }), 'tffolder');
  fBtn.title = 'Send your plug-in list and rebuild the FX browser folder of what everyone has now.';
  fBtn.hidden = remote;
  const fAbout = mk('p', 'dim tfnote');
  pPage.append(head('This project’s plug-ins', 'tfp-h'), mk('p', 'dim tfnote', 'Plug-ins in this project, who doesn’t have them, and the studio’s stand-in for them.'),
    pRo, pSaid, apply, rows, pEmpty, picker,
    head('Drum maps (this computer only)'), mk('p', 'dim tfnote', 'Every drum plug-in has kick, snare and hats on its own notes. If a part was written for a different plug-in than yours, say which: the notes reach your plug-in on the right drums. Nobody else’s project changes, and the part stays as written.'),
    dSel, dRow, dStat, make,
    head('Plug-ins everyone has'), fAbout, fInfo, fBtn);
  ssTabs.sub('plugins', 'project', 'This project', pPage, onShow('project'));

  // ---- Find a plug-in (this computer only, as the panel's: Add opens the plug-in's window in REAPER) ------------------------------------
  const fPage = mk('section', 'tfp');
  fPage.setAttribute('aria-labelledby', 'tff-h');
  const fq = mk('input', 'tfsearch tffq'), fcat = mk('select'), fonly = mk('input'), fTarget = mk('p', 'dim tfnote'), fRows = mk('ul', 'tflist tffound'), fCount = mk('p', 'dim tfnote'), fSaid = saidLine();
  fq.type = 'search'; fq.placeholder = 'Search plug-ins'; fq.maxLength = 80; fq.setAttribute('aria-label', 'Search plug-ins');
  fcat.className = 'tfcat';
  fcat.title = 'REAPER’s own categories (its FX browser’s Category list), and Instruments.';
  fonly.type = 'checkbox'; fonly.checked = true; fonly.className = 'tfonly';
  const fonlyL = field('Only what everyone has', fonly);
  fonlyL.title = 'On: only plug-ins every computer in the studio has (and JSFX), so the part sounds the same everywhere. Off: all of yours, the ones everyone has marked.';
  let fqt = 0;
  const findNow = () => act({ find: { q: fq.value, cat: fcat.value || 'All', only: fonly.checked } });
  fq.addEventListener('input', () => { clearTimeout(fqt); fqt = setTimeout(findNow, 300); });
  fcat.addEventListener('change', findNow);
  fonly.addEventListener('change', findNow);
  const fBar = mk('div', 'prow');
  fBar.append(fq, field('Category', fcat), fonlyL);
  fPage.append(head('Find a plug-in', 'tff-h'), fBar, fTarget, fSaid, fRows, fCount);
  ssTabs.sub('plugins', 'find', 'Find a plug-in', fPage, onShow('find'), { envs: HERE });

  // ---- Plug-in pack -----------------------------------------------------------------------------------------------------------------------
  const kPage = mk('section', 'tfp');
  kPage.setAttribute('aria-labelledby', 'tfk-h');
  const kRo = roNote(), kSaid = saidLine(), kRows = mk('div', 'tfpackrows'), kOthers = mk('p', 'tfnote tfwarn'), kList = mk('ul', 'tflist tfpack');
  const kWhat = mk('details');
  kWhat.append(mk('summary', '', 'What’s in them'), kList);
  kPage.append(head('The plug-in pack', 'tfk-h'), mk('p', 'dim tfnote', 'Free, open-source plug-ins, each from its maker’s own release, so a part made with one plays and can be changed on every computer in the studio. Get opens StudioSync’s installer in a window of its own: only the plug-ins, nothing else.'),
    kRo, kSaid, kRows, kOthers, kWhat);
  ssTabs.sub('plugins', 'pack', 'Plug-in pack', kPage, onShow('pack'));

  // ---- drawing ------------------------------------------------------------------------------------------------------------------------------
  function said(el, s) { el.textContent = s && s.text && Date.now() / 1000 - (s.at || 0) < 120 ? s.text : ''; }
  function options(sel, list, cur, words) {
    const key = list.join('\n');
    if (sel.dataset.k !== key) {
      sel.replaceChildren(...list.map((v) => { const o = mk('option', '', words(v)); o.value = v; return o; }));
      sel.dataset.k = key;
    }
    if (document.activeElement !== sel) sel.value = cur;
  }
  const mapWords = (n) => (n === '' ? 'not set' : n === 'gm' ? 'General MIDI' : n);
  function drawProject(m) {
    pRo.textContent = 'Read only here: stand-ins, drum maps and the folder are set in REAPER on ' + computer() + '.';
    said(pSaid, m.said);
    const list = m.project || [];
    apply.hidden = remote || !list.some((r) => r.standin && r.missing.length);
    rows.replaceChildren(...list.map((r) => {
      const li = mk('li', 'tfitem tfrow');
      const who = r.js ? mk('span', 'dim', 'everyone has it (JSFX)') : r.missing.length ? mk('span', 'tfwarn', 'Missing for ' + r.missing.join(', ')) : mk('span', 'dim', 'everyone has it');
      const info = mk('span', 'tfinfo');
      info.append(mk('span', 'tfname', r.name), mk('span', 'dim', ' · ' + (r.tracks || []).join(', ')), mk('br'), who);
      if (r.standin) info.append(mk('br'), mk('span', 'tfstand', 'Stand-in: ' + r.standin.to + (r.standin.by ? ' (set by ' + r.standin.by + ')' : '')));
      li.append(info);
      if (!remote) {
        li.append(btn(r.standin ? 'Change' : 'Set a stand-in', () => openPicker(r), 'tfset'));
        if (r.standin) {
          const sure = removing === r.key;
          const rm = btn(sure ? 'Remove it? Yes' : 'Remove', () => {
            if (!sure) { removing = r.key; clearTimeout(rmt); rmt = setTimeout(() => { removing = null; last = null; draw(); }, 4000); last = null; draw(); return; }
            removing = null; act({ unstandin: r.key });
          }, 'tfrm');
          rm.title = 'Remove the studio’s stand-in for ' + r.name + ' (for everyone in the studio)';
          li.append(rm);
        }
      }
      return li;
    }));
    pEmpty.textContent = 'No plug-ins in this project yet.';
    pEmpty.hidden = !!list.length;
    if (picking && m.pick) {
      pickList.replaceChildren(...m.pick.names.map((n) => {
        const li = mk('li', 'tfitem');
        li.append(mk('span', '', n), btn('Use it', () => { act({ standin: { key: picking.key, to: n } }); picking = null; picker.hidden = true; }, 'tfyes'));
        return li;
      }));
      pickMore.textContent = m.pick.total > m.pick.names.length ? 'Showing ' + m.pick.names.length + ' of ' + m.pick.total + ': type to narrow it down.' : m.pick.total ? '' : 'Nothing here matches.';
    }
    const d = m.drums || {};
    dSel.textContent = !d.n ? 'Select a drum track in REAPER.' : d.n === 1 ? 'Track: ' + d.track : d.n + ' tracks selected';
    dSel.className = 'tfnote' + (d.n ? '' : ' tfwarn');
    dRow.hidden = !d.n;
    dFrom.disabled = dTo.disabled = remote;
    const maps = [''].concat(d.maps || []);
    options(dFrom, maps, d.from || '', mapWords);
    options(dTo, maps, d.to || '', mapWords);
    dStat.textContent = d.moved != null ? 'On: ' + d.moved + ' note' + (d.moved === 1 ? '' : 's') + ' moved, here only.' : d.same ? 'Those two use the same notes: nothing to move.' : '';
    if (d.kit && !makeKit.children.length) {
      for (const k of d.kit) {
        const i = mk('input');
        i.type = 'number'; i.min = '0'; i.max = '127'; i.value = String(k.gm);
        kitInputs[k.id] = i;
        makeKit.append(field(k.label, i));
      }
    }
    fAbout.textContent = 'Each computer sends the studio its list of plug-ins (names only) when Live sync starts. What all of you have goes in the FX browser folder “' + (m.folder || '') + '”: use those and the project sounds the same on every computer.' + ((m.people || []).length ? ' Lists from ' + m.people.join(', ') + '.' : '');
    fInfo.textContent = m.folder_info || '';
  }
  function drawFind(m) {
    const f = m.find;
    if (!f) return;
    said(fSaid, m.said);
    options(fcat, f.cats || ['All'], f.cat || 'All', (c) => c);
    if (document.activeElement !== fq && fq.value !== f.q) fq.value = f.q || '';
    fonly.checked = !!f.only;
    fTarget.textContent = f.target ? 'Add puts it on ' + f.target + ', its window open.' + (f.master ? ' The master is never printed, so “Only what everyone has” comes back on for it.' : '') : 'Select a track in REAPER first: Add puts the plug-in on it.';
    fRows.replaceChildren(...(f.rows || []).map((r) => {
      const li = mk('li', 'tfitem' + (r.everyone || f.only ? '' : ' tfnotall'));
      const b = btn('Add', () => act({ add: r.key }), 'tfadd');
      b.disabled = !f.target;
      if (!f.only) li.title = r.everyone ? 'Everyone in the studio has it.' : 'Not everyone has it: their copy plays a print of the part.';
      li.append(mk('span', 'tfname', r.label), mk('span', 'dim', r.cats), b);
      return li;
    }));
    fCount.textContent = (f.shown || 0) + ' shown' + (f.shown > (f.rows || []).length ? ' (the first ' + f.rows.length + ' listed: type to narrow it down)' : '') + '. New plug-ins show after REAPER restarts (it lists them when it starts).';
  }
  function drawPack(m) {
    const k = m.pack;
    if (!k) return;
    kRo.textContent = 'Read only here: Get runs the installer on ' + computer() + ', from REAPER there.';
    said(kSaid, m.said);
    const row = (label, g, extras) => {
      const r = mk('div', 'prow');
      r.append(mk('span', '', label + ': ' + g.have + ' of ' + g.total + ' here'));
      if (g.missing.length) r.title = 'Not here: ' + g.missing.join(', ');
      if (!g.missing.length && (!extras || !k.pack.missing.length)) r.append(mk('span', 'dim', 'all here'));
      else if (!remote) {
        const b = btn(extras ? 'Get the extras' : 'Get the pack', () => act({ get: extras ? 'extras' : 'pack' }), 'tfyes tfget');
        if (extras) b.title = 'The extras, and whatever of the pack isn’t here. About 1.3 GB, most of it a grand piano and a drum kit.';
        r.append(b);
      }
      return r;
    };
    kRows.replaceChildren(row('Plug-in pack', k.pack, false), row('Extras', k.extras, true));
    const lack = k.others || [];
    kOthers.textContent = lack.length ? 'Others in the studio have ' + lack.map((x) => x.name + ' (' + x.who.join(', ') + ')').join(', ') + '. Without them you hear those parts, but can’t play or change them.' : '';
    kOthers.hidden = !lack.length;
    kList.replaceChildren(...(k.items || []).map((it) => {
      const li = mk('li', 'tfitem');
      li.append(mk('span', it.here ? 'tfname' : '', (it.here ? 'here · ' : '') + it.name + (it.alt ? ' (' + it.alt + ' on Linux)' : '')),
        mk('span', 'dim', it.none ? 'no Linux version' : it.what + (it.extras ? ' (extras)' : '')));
      return li;
    }));
  }
  function draw() {
    if (!anyShown()) return;
    const m = ssTabs.topics.plugins;
    if (m === last) return; // (the stream brings other topics many times a second)
    last = m;
    const pages = [pPage, fPage, kPage];
    if (!m || m.error) {
      for (const p of pages) {
        let e = p.querySelector('.tfwait');
        if (!e) { e = mk('p', 'dim tfwait'); p.append(e); }
        e.textContent = m ? 'Couldn’t read the plug-ins here: ' + m.error : 'Asking Live sync…';
        e.hidden = false;
      }
      return;
    }
    for (const p of pages) { const e = p.querySelector('.tfwait'); if (e) e.hidden = true; }
    drawProject(m);
    drawFind(m);
    drawPack(m);
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
})();
