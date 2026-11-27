// StudioSync's Session > Rooms (docs/rt/ui-web-plan.md Phase 6; the panel's Rooms page; rt-ui6): this project's rooms as cards (who's in
// each, where it came from, Go), Create a room, Fork, Come see!, Archive / Bring back, and in a side room Send selected to, Compare / Bring
// into and Adopt as the room it came from. Bandmates' "come and see" asks show here and at the top of Who's here, with Go and Not now. Reads the
// "rooms" topic (lib/webrooms.lua: the list only while this shows, said every 10 s; the asks always); sends on the "session" topic as
// { rooms: { ... } }. Live sync decides and refuses what the panel would; this page asks first where the panel does. Names go in as text,
// never HTML. GPL-3.0-or-later. (James, rt-ui6)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, cls) => { const b = mk('button', cls, text); b.type = 'button'; return b; };
  const nameOf = (u) => (window.ssProfiles ? ssProfiles.name(u) : u);
  const act = (o) => ssTabs.act('session', { rooms: o }).catch(() => { said.textContent = 'Couldn’t reach Live sync.'; });

  const page = mk('section', 'play prooms');
  page.setAttribute('aria-label', 'Rooms');
  const inv = mk('ul', 'pwho pinvites'), top = mk('div', 'prow'), form = mk('form'), list = mk('ul', 'pwho'), arch = mk('details'), side = mk('div'), ask = mk('div', 'pask'), said = mk('p', 'pnote psaid');
  said.setAttribute('role', 'status'); // (no .prow on the form and the question: its display: flex beats hidden)
  const newB = button('Create a room'), forkB = button('Fork project'), seeB = button('Come see!');
  newB.title = 'A copy of this room as it is now, in its own tab; you’re in control of it. Try your own edits there, then bring back what works.';
  forkB.title = 'Another arrangement of the project as it is now, in its own tab. It shares the recordings (nothing copied): compare it, bring back what you pick, or adopt it as the main version.';
  seeB.title = 'Everyone with this project open is asked to come and see the room you’re in.';
  top.append(newB, forkB, seeB);
  const nameIn = mk('input'), makeB = button('Create'), cancelB = button('Cancel');
  nameIn.maxLength = 30;
  nameIn.placeholder = 'a name (e.g. chorus ideas)';
  nameIn.setAttribute('aria-label', 'Room name');
  makeB.type = 'submit';
  form.append(nameIn, makeB, cancelB);
  form.hidden = true;
  ask.hidden = true;
  arch.append(mk('summary', '', 'Archived rooms'));
  arch.hidden = true;
  const how = mk('p', 'dim pnote', 'Each room is its own project tab: Go switches to it (it opens once). A side room starts as a copy of the room you’re in; ' +
    'from it, send over the items you pick or bring in everything that changed. History there can undo it.');
  page.append(inv, top, form, ask, list, arch, side, said, how);

  let forking = false;
  newB.addEventListener('click', () => { forking = false; makeB.textContent = 'Create'; form.hidden = false; nameIn.value = ''; nameIn.focus(); });
  forkB.addEventListener('click', () => { forking = true; makeB.textContent = 'Fork'; form.hidden = false; nameIn.value = ''; nameIn.focus(); });
  cancelB.addEventListener('click', () => { form.hidden = true; });
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const n = nameIn.value.trim();
    if (!n) return;
    form.hidden = true;
    act({ create: n, fork: forking });
  });
  seeB.addEventListener('click', () => act({ comesee: true }));
  // (the panel's yes/no boxes, in the page: one question at a time)
  function confirmIt(q, yes, o) {
    ask.replaceChildren(mk('span', '', q));
    const y = button(yes, 'pgo'), n = button('Cancel');
    y.addEventListener('click', () => { ask.hidden = true; act(o); });
    n.addEventListener('click', () => { ask.hidden = true; });
    ask.append(y, n);
    ask.hidden = false;
  }

  // the come-and-see asks, here and at the top of Who's here (until Go or Not now, in this page)
  const gone = new Set();
  const here = document.getElementById('here'), hereInv = mk('ul', 'pwho pinvites');
  if (here) here.insertBefore(hereInv, here.querySelector('h2').nextSibling);
  function invites(r) {
    const rows = ((r && r.invites) || []).filter((v) => !gone.has(v.from + '|' + v.time));
    for (const ul of [inv, hereInv]) {
      ul.replaceChildren(...rows.map((v) => {
        const li = mk('li', 'pinvite', nameOf(v.from) + ' asks you to come and see ‘' + v.room + '’ ');
        const go = button('Go', 'pgo'), no = button('Not now');
        go.addEventListener('click', () => { gone.add(v.from + '|' + v.time); act({ go: v.room }); draw(true); });
        no.addEventListener('click', () => { gone.add(v.from + '|' + v.time); draw(true); });
        li.append(go, no);
        return li;
      }));
    }
  }

  let last = null;
  function draw(force) {
    const r = ssTabs.topics.rooms;
    if (r === last && !force) return;
    last = r;
    invites(r);
    if (!r || !r.rooms) { list.replaceChildren(mk('li', 'dim', r && r.error ? 'Couldn’t read the rooms: ' + r.error : 'Asking Live sync…')); return; }
    list.replaceChildren(...r.rooms.map((x) => {
      const li = mk('li', x.here ? 'me' : '');
      li.append(mk('span', 'name', x.name), mk('span', 'dim', ' ' + (x.here ? '(this tab) · ' : '') + x.came));
      if (x.main) li.append(mk('span', 'badge drv', 'main'));
      const ppl = mk('div', 'armed', x.people.length ? x.people.map((p) => nameOf(p.user) + (p.me ? ' (you)' : '') + (p.here ? '' : ': tab open')).join(', ') : 'nobody');
      li.append(ppl);
      if (!x.here) {
        const go = button('Go', 'pgo');
        go.title = 'Go to ' + x.name + ' (its own tab in REAPER)';
        go.addEventListener('click', () => act({ go: x.name }));
        li.append(go);
      }
      if (!x.main && !x.here) {
        const ab = button('Archive');
        ab.disabled = x.people.length > 0;
        ab.title = x.people.length ? 'Someone has it open: it can be archived once its tabs are closed.' : 'Takes this idea off the list for everyone. Nothing is deleted.';
        ab.addEventListener('click', () => confirmIt('Take ‘' + x.name + '’ off the list for everyone? Nothing is deleted: it can be brought back here.', 'Archive', { archive: x.name }));
        li.append(' ', ab);
      }
      return li;
    }));
    arch.hidden = !(r.archived || []).length;
    arch.querySelector('summary').textContent = 'Archived rooms (' + (r.archived || []).length + ')';
    const al = mk('ul', 'pwho');
    for (const a of r.archived || []) {
      const li = mk('li', '', a.name + ' ');
      li.append(mk('span', 'dim', '(archived by ' + nameOf(a.by) + ') '));
      const bb = button('Bring back');
      bb.addEventListener('click', () => confirmIt('Bring room ‘' + a.name + '’ back for everyone?', 'Bring back', { unarchive: a.name }));
      li.append(bb);
      al.append(li);
    }
    const old = arch.querySelector('ul');
    if (old) old.replaceWith(al); else arch.append(al);
    // from a side room: the way back to the room it came from
    side.replaceChildren();
    if (r.parent) {
      const p = r.parent;
      side.append(mk('h2', '', 'Back to ' + p));
      const row = mk('div', 'prow');
      const send = button('Send selected to ' + p), look = button((r.fork ? 'Compare with ' : 'Bring into ') + p + '…');
      send.title = 'The items selected in REAPER go to ‘' + p + '’ as they are here (new changes there, so History there can undo them).';
      look.title = 'Compares this room, ‘' + p + '’ and how this room started: everything changed here comes over, except what ‘' + p + '’ changed too since.';
      send.addEventListener('click', () => confirmIt('Send the selected items to ‘' + p + '’, as they are here? (Any of their tracks ‘' + p + '’ doesn’t have yet go too.)', 'Send', { send: true }));
      look.addEventListener('click', () => act({ look: true }));
      row.append(send, look);
      if (r.fork) {
        const ad = button('Adopt as ' + p + '…');
        ad.title = 'This fork becomes the main version: ‘' + p + '’ is kept as it is now as a fork, then made exactly as this one. Needs ‘' + p + '’ open here, and you in control of it.';
        ad.addEventListener('click', () => confirmIt('Make ‘' + p + '’ exactly as this fork is, for everyone? ‘' + p + '’ as it is now is kept first, as a fork of its own.', 'Adopt', { adopt: true }));
        row.append(ad);
      }
      side.append(row);
      const m = r.merge;
      if (m) {
        const ul = mk('ul', 'pwho');
        for (const t of m.tracks || []) ul.append(mk('li', '', t.name + ': ' + t.fork + ' changed here, ' + t.theirs + ' in ‘' + p + '’ since, ' + t.both + ' in both'));
        side.append(mk('p', 'pnote', m.bring + ' change(s) to bring into ‘' + p + '’' + (m.clash ? '; ' + m.clash + ' also changed there since (it keeps its own)' : '') + '.'), ul);
        const bring = button('Bring into ' + p, 'pgo');
        bring.disabled = !r.may_bring || !m.bring;
        bring.title = r.may_bring ? 'They go to everyone there as new changes, so History there can undo them.' : nameOf(r.parent_driver || '?') + ' is in control of ‘' + p + '’: they bring it in (or take control there).';
        bring.addEventListener('click', () => confirmIt('Bring ' + m.bring + ' change(s) into ‘' + p + '’?', 'Bring in', { bring: true }));
        side.append(bring);
        if (!r.may_bring) side.append(mk('span', 'dim', ' ' + nameOf(r.parent_driver || '?') + ' is in control of ‘' + p + '’: they bring it in.'));
      }
    }
    said.textContent = r.said ? r.said.text : '';
  }
  let shown = false;
  const want = () => { if (shown && !document.hidden) act({ want: true }); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  ssTabs.sub('session', 'rooms', null, page, (on) => { shown = on; if (on) { want(); draw(true); } });
  addEventListener('ss-state', () => draw());
  addEventListener('ss-tabs', () => draw(true));
})();
