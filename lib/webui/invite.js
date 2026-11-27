// Ask to join (lib/invite.lua, topic "invite"): on Home, "Ask to join" on each bandmate online (your project and room) and "Ask…" on each
// project row (pick who), "Link" for a studiosync:// link to it (and the web UI's own join.html for a computer without the link handler);
// join requests for you at the top of Home with Join and Decline; window.ssInvite.joinBox(m, scope, mine) for chat.js's messages carrying
// `join`. Home's own file (home.js) is not changed: its cards are found by class and added to after each draw. Everything from other people
// goes in as text. GPL-3.0-or-later. (James, rt-invite)
'use strict';
(() => {
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const btn = (text, title, cls) => { const b = mk('button', cls || 'ibtn', text); b.type = 'button'; if (title) b.title = title; return b; };
  const T = () => (window.ssTabs && ssTabs.topics.invite) || {};
  const act = (o) => (window.ssTabs ? ssTabs.act('invite', o) : Promise.reject(new Error('no tabs')));
  const nameOf = (u) => (window.ssProfiles ? ssProfiles.name(u) : u);
  const pct = (s) => encodeURIComponent(String(s)).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
  function memberLink(song, room) {
    const t = T();
    if (!t.studio) return null;
    return 'studiosync://join?s=' + pct(t.studio) + '&p=' + pct(song) + (room && room !== 'main' ? '&r=' + pct(room) : '');
  }
  const webLink = (link) => 'http://127.0.0.1:' + (T().port || 47281) + '/join.html?' + link.split('?')[1];
  const where = (song, room) => song + (room && room !== 'main' ? ' (' + room + ')' : '');
  function flash(b, text) {
    const was = b.textContent;
    b.disabled = true; b.textContent = text;
    setTimeout(() => { b.disabled = false; b.textContent = was; }, 3000);
  }
  function ask(to, song, room, b) {
    act({ ask: { to, song, room: room || 'main' } }).then(() => flash(b, 'Asked')).catch(() => flash(b, 'Couldn’t reach Live sync'));
  }

  // ---- chat: a join request's buttons --------------------------------------------------------------------------------------------------
  function joinBox(m, scope, mine) {
    const j = m.join, box = mk('div', 'ijoinbox');
    if (!j) return box;
    if (mine || j.mine) { box.append(mk('span', 'dim', 'You asked them to join ' + where(j.song, j.room))); return box; }
    if (j.answered) { box.append(mk('span', 'dim', 'Answered')); return box; }
    if (j.inside) { box.append(mk('span', 'dim', 'You’re in ' + where(j.song, j.room) + ' already')); return box; } // (here or on another of your computers: rt-people)
    if (j.expired) { box.append(mk('span', 'dim', 'This request has run out')); return box; }
    const go = btn('Join', 'Open ' + where(j.song, j.room) + ' here and start Live sync', 'ibtn igo');
    const no = btn('Decline', 'Tell them you can’t join right now');
    const send = (yes) => {
      go.disabled = no.disabled = true;
      act({ answer: { scope, id: m.id, go: yes } }).then(() => { box.replaceChildren(mk('span', 'dim', yes ? 'Opening…' : 'Declined')); })
        .catch(() => { go.disabled = no.disabled = false; });
    };
    go.addEventListener('click', () => send(true));
    no.addEventListener('click', () => send(false));
    box.append(go, no);
    return box;
  }
  window.ssInvite = { joinBox, memberLink, webLink };

  // ---- Home: added to its cards after each draw -----------------------------------------------------------------------------------------
  function linkBox(li, song) {
    let box = li.querySelector('.ilinkbox');
    if (box) { box.remove(); return; }
    const link = memberLink(song, 'main');
    if (!link) return;
    box = mk('div', 'ilinkbox');
    for (const [label, v] of [['Link', link], ['Without the link handler', webLink(link)]]) {
      const row = mk('label', 'ilinkrow');
      const inp = mk('input');
      inp.readOnly = true; inp.value = v; inp.setAttribute('aria-label', label);
      inp.addEventListener('focus', () => inp.select());
      row.append(mk('span', 'dim', label), inp);
      box.append(row);
    }
    box.append(mk('div', 'dim', 'For people in this studio: it opens the project in their REAPER. Someone new needs an invitation (Settings > Studio > Invitations).'));
    li.append(box);
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(link).catch(() => {});
  }
  function pickBox(li, song) {
    let box = li.querySelector('.ipickbox');
    if (box) { box.remove(); return; }
    box = mk('div', 'ipickbox');
    const sel = mk('select');
    sel.setAttribute('aria-label', 'Who to ask');
    for (const u of T().people || []) { const o = mk('option', '', nameOf(u)); o.value = u; sel.append(o); }
    if (!sel.options.length) { box.append(mk('span', 'dim', 'Nobody else is in this studio yet.')); li.append(box); return; }
    const send = btn('Ask to join', 'They get a message with Join and Decline, and a phone alert if the studio has them');
    send.addEventListener('click', () => ask(sel.value, song, 'main', send));
    box.append(sel, send);
    li.append(box);
  }
  function decorate() {
    const home = document.getElementById('home');
    if (!home) return;
    const t = T();
    for (const li of home.querySelectorAll('.honline li.hchip:not(.me)')) {
      if (li.querySelector('.iask')) continue;
      const u = li.querySelector('[data-av-user]');
      if (!u || !t.song) continue;
      if ((t.inside || []).includes(u.dataset.avUser) || !(t.people || []).includes(u.dataset.avUser)) continue; // (in it already, or yours: rt-people)
      const b = btn('Ask to join', 'Ask ' + nameOf(u.dataset.avUser) + ' to join ' + where(t.song, t.room), 'ibtn iask');
      b.addEventListener('click', () => ask(u.dataset.avUser, t.song, t.room, b));
      li.append(b);
    }
    for (const li of home.querySelectorAll('.hprojects li.hproj')) {
      // (the Studio tab's project cards keep a place for them beside Open, .hpinv: rt-ui2)
      const top = li.querySelector('.hpinv') || li.querySelector('.hptop'), nm = li.querySelector('.hpname');
      if (!top || !nm || li.querySelector('.iaskp')) continue;
      const song = nm.textContent;
      const a = btn('Ask…', 'Ask someone in the studio to join this project', 'ibtn iaskp');
      a.addEventListener('click', () => pickBox(li, song));
      const l = btn('Link', 'A studiosync:// link to this project (copied when the browser allows)', 'ibtn ilink');
      l.addEventListener('click', () => linkBox(li, song));
      top.append(a, l);
    }
    // join requests for you, at the top
    let bar = home.querySelector('.ijoinbar');
    if (!bar) { bar = mk('div', 'ijoinbar'); bar.setAttribute('role', 'status'); const head = home.querySelector('.hhead'); if (head) head.after(bar); else home.prepend(bar); }
    const key = JSON.stringify([t.asks || [], t.last || null]);
    if (bar.dataset.key === key) return;
    bar.dataset.key = key;
    bar.replaceChildren();
    for (const x of t.asks || []) {
      const row = mk('div', 'ijoinrow');
      row.append(mk('span', 'ijointext', nameOf(x.user) + ' asks you to join ' + where(x.song, x.room)));
      row.append(joinBox({ id: x.id, join: { song: x.song, room: x.room } }, x.scope, false));
      bar.append(row);
    }
    if (t.last && t.last.text && Date.now() / 1000 - t.last.at < 20) bar.append(mk('div', t.last.ok ? 'dim' : 'iwarn', t.last.text));
    bar.hidden = !bar.childNodes.length;
  }
  let mo = null;
  function hook() {
    const home = document.getElementById('home');
    if (!home || mo) return;
    mo = new MutationObserver(() => decorate());
    mo.observe(home, { childList: true, subtree: true });
    decorate();
  }
  addEventListener('DOMContentLoaded', hook);
  addEventListener('ss-state', () => { hook(); decorate(); });
  addEventListener('ss-tabs', () => { hook(); decorate(); });
})();
