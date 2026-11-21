// The History page's "hear it as it was" panel (lib/histhear.lua; rt-history): Listen renders the song as it stood at the point the time lapse
// shows, in a background REAPER that never touches the open project, and plays it here; Compare with now renders today's too and switches
// between the two at the same place (A/B); Restore this point puts the whole song, or chosen tracks, back as a new change everyone gets, after
// saying what would change. Reads the "hhear" topic; asks with { topic: "history", hear | cancel | restore }. Names go in as text, never HTML.
// GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const H = window.ssHistory;
  if (!window.ssTabs || !H) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const btn = (text, cls) => { const b = mk('button', cls, text); b.type = 'button'; return b; };
  const when = (t) => new Date(t * 1000).toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  const mmss = (s) => { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
  const act = (o) => ssTabs.act('history', o).catch(() => { said.textContent = 'Live sync didn’t answer: is it running?'; });

  // ---- the panel ------------------------------------------------------------------------------------------------------------------------
  const box = mk('section', 'hhbox');
  box.setAttribute('aria-label', 'Hear it as it was');
  const listen = btn('Listen to this point', 'hhlisten');
  const ab = btn('Compare with now', 'hhcmp');
  const stop = btn('Cancel');
  stop.hidden = true;
  const state = mk('span', 'hhstate');
  state.setAttribute('role', 'status');
  const row = mk('div', 'hhrow');
  row.append(listen, ab, stop, state);
  // A/B: two players kept in step; the one you hear shows its controls
  const pick = mk('span', 'hhab');
  pick.setAttribute('role', 'group');
  pick.setAttribute('aria-label', 'Which to hear');
  const pa = btn('A · Then'), pb = btn('B · Now');
  pick.append(pa, pb);
  const aThen = mk('audio'), aNow = mk('audio');
  for (const a of [aThen, aNow]) { a.controls = true; a.preload = 'auto'; a.hidden = true; }
  aThen.setAttribute('aria-label', 'The song as it was');
  aNow.setAttribute('aria-label', 'The song now');
  const player = mk('div', 'hhplayer');
  player.hidden = true;
  player.append(pick, aThen, aNow);
  // restore
  const det = mk('details', 'hhrestore');
  const sum = mk('summary', '', 'Restore this point…');
  const whole = mk('input'), chosen = mk('input');
  whole.type = chosen.type = 'radio';
  whole.name = chosen.name = 'hhscope';
  const lw = mk('label', 'hhopt'), lc = mk('label', 'hhopt');
  lw.append(whole, document.createTextNode(' The whole song'));
  lc.append(chosen, document.createTextNode(' Chosen tracks:'));
  const tracksBox = mk('div', 'hhtracks');
  const check = btn('Check what changes');
  const ask = mk('div', 'hhask');
  ask.hidden = true;
  ask.setAttribute('role', 'alertdialog');
  ask.setAttribute('aria-label', 'Restore this point?');
  const words = mk('p');
  const yes = btn('Restore now', 'hhyes'), no = btn('Not now');
  ask.append(words, yes, no);
  const said = mk('p', 'hhsaid');
  said.setAttribute('role', 'status');
  det.append(sum, mk('p', 'dim', 'Puts the song back the way it was at this point, as a new change everyone gets. Today’s version stays in History, and Undo takes it back.'),
    lw, lc, tracksBox, check, ask, said);
  box.append(mk('h3', '', 'Hear it as it was'), row, player, det);
  H.range.after(box);

  // ---- state ------------------------------------------------------------------------------------------------------------------------------
  let M = {}, cur = 'then', asked = null, lastAsk = null, files = { then: null, now: null };
  const point = () => H.point();
  function slotWords(s, name) {
    if (!s) return '';
    const st = s.state;
    if (st === 'queued') return name + ': waiting its turn' + (s.why ? ' (' + s.why + ')' : '') + '…';
    if (st === 'rendering') return name + ': rendering in the background' + (s.pass ? ', pass ' + s.pass + ' of ' + (s.passes || 2) : '') + (s.secs != null ? ' · ' + mmss(s.secs) : '') +
      (s.len ? ' (the song is ' + mmss(s.len) + ' long)' : '') + '…';
    if (st === 'failed') return name + ' couldn’t be made: ' + (s.why || 'something went wrong') + '.';
    if (st === 'cancelled') return name + ': cancelled.';
    if (st === 'ready') return name + ': ready' + (s.missing ? ' (' + s.missing + ' recording' + (s.missing === 1 ? ' isn’t' : 's aren’t') + ' on this computer yet: silent in it)' : '') +
      (s.tempo === 'unknown' ? ' (the tempo map then isn’t kept in History: it plays on today’s)' : '') + '.';
    return '';
  }
  function setSrc(a, id, slot) {
    if (files[slot] === id) return;
    files[slot] = id;
    if (id) { a.src = 'api/file?id=' + encodeURIComponent(id); a.load(); } else { a.removeAttribute('src'); a.load(); }
  }
  function showPick() {
    const hasNow = !!files.now, hasThen = !!files.then;
    if (cur === 'now' && !hasNow) cur = 'then';
    if (cur === 'then' && !hasThen && hasNow) cur = 'now';
    aThen.hidden = cur !== 'then' || !hasThen;
    aNow.hidden = cur !== 'now' || !hasNow;
    pa.setAttribute('aria-pressed', String(cur === 'then'));
    pb.setAttribute('aria-pressed', String(cur === 'now'));
    pa.disabled = !hasThen; pb.disabled = !hasNow;
    pick.hidden = !(hasThen && hasNow);
    player.hidden = !(hasThen || hasNow);
    if (M.then && M.then.t) pa.textContent = 'A · Then (' + when(M.then.t) + ')';
  }
  // (switching keeps the place and whether it plays: what A/B is for)
  function switchTo(slot) {
    if (slot === cur || !files[slot]) return;
    const from = cur === 'then' ? aThen : aNow, to = slot === 'then' ? aThen : aNow;
    const playing = !from.paused;
    try { to.currentTime = Math.min(from.currentTime, isFinite(to.duration) ? to.duration : from.currentTime); } catch (e) {}
    from.pause();
    if (playing) to.play().catch(() => {});
    cur = slot;
    showPick();
  }
  pa.addEventListener('click', () => switchTo('then'));
  pb.addEventListener('click', () => switchTo('now'));
  // (the time lapse follows the preview: at its point as it starts, its playhead where the audio is; today's goes to the last frame)
  let follow = 0;
  for (const [a, slot] of [[aThen, 'then'], [aNow, 'now']]) {
    a.addEventListener('play', () => {
      if (H.playhead) H.playhead(a.currentTime, slot === 'now' ? 'end' : M.then && M.then.t);
      cancelAnimationFrame(follow);
      const step = () => { if (a.paused || a.ended) return; if (H.playhead) H.playhead(a.currentTime); follow = requestAnimationFrame(step); };
      follow = requestAnimationFrame(step);
    });
    for (const ev of ['pause', 'ended', 'emptied']) a.addEventListener(ev, () => { if (aThen.paused && aNow.paused && H.playhead) H.playhead(null); });
  }

  function render() {
    const p = point();
    const th = M.then, nw = M.now;
    const same = p && th && th.t && Math.abs(th.t - p.t) < 1;
    listen.disabled = !p;
    listen.textContent = same && th.state === 'ready' ? 'Listen again from the start' : 'Listen to this point';
    const busy = [th, nw].some((s) => s && (s.state === 'queued' || s.state === 'rendering'));
    stop.hidden = !busy;
    state.textContent = [slotWords(th, th && th.t ? 'As it was ' + when(th.t) : 'As it was'), slotWords(nw, 'Now')].filter(Boolean).join(' ');
    setSrc(aThen, th && th.state === 'ready' ? th.file : null, 'then');
    setSrc(aNow, nw && nw.state === 'ready' ? nw.file : null, 'now');
    ab.setAttribute('aria-pressed', String(!!nw));
    showPick();
    // restore
    whole.disabled = !M.driver;
    lw.title = M.driver ? '' : 'Only the driver can restore the whole song: ask them, or take control.';
    if (whole.disabled && whole.checked) chosen.checked = true;
    if (M.tracks && !whole.checked && !chosen.checked) (M.driver ? whole : chosen).checked = true; // (once Live sync has said who drives)
    const have = new Set([...tracksBox.querySelectorAll('input')].map((i) => i.value));
    const list = Array.isArray(M.tracks) ? M.tracks : [];
    if (list.length !== have.size || list.some((t) => !have.has(t[0]))) {
      const was = new Set([...tracksBox.querySelectorAll('input:checked')].map((i) => i.value));
      tracksBox.replaceChildren();
      for (const [oid, name] of list) {
        const l = mk('label', 'hhtrack'), c = mk('input');
        c.type = 'checkbox'; c.value = oid; c.checked = was.has(oid);
        c.addEventListener('change', () => { chosen.checked = true; });
        l.append(c, document.createTextNode(' ' + (name || '(unnamed)')));
        tracksBox.append(l);
      }
    }
    check.disabled = !p;
    const a = M.ask;
    if (a && asked && a.id !== lastAsk) { lastAsk = a.id; asked = null; words.textContent = (a.whole ? 'The whole song' : 'The chosen tracks') + ' as at ' + when(a.t) + ': ' + a.words; ask.hidden = false; yes.disabled = !a.n; yes.focus(); }
    if (!a && !ask.hidden && !yes.dataset.sent) ask.hidden = true;
    said.textContent = M.said || '';
  }

  listen.addEventListener('click', () => {
    const p = point();
    if (!p) return;
    const th = M.then;
    if (th && th.state === 'ready' && Math.abs(th.t - p.t) < 1) { const a = cur === 'then' ? aThen : aNow; a.currentTime = 0; a.play().catch(() => {}); return; }
    cur = 'then';
    act({ hear: { t: p.t } });
  });
  ab.addEventListener('click', () => {
    const p = point();
    if (p && !(M.then && Math.abs((M.then.t || 0) - p.t) < 1)) act({ hear: { t: p.t } });
    act({ hear: { now: true } });
  });
  stop.addEventListener('click', () => act({ cancel: true }));
  check.addEventListener('click', () => {
    const p = point();
    if (!p) return;
    const r = { t: p.t };
    if (chosen.checked) {
      r.tracks = [...tracksBox.querySelectorAll('input:checked')].map((i) => i.value);
      if (!r.tracks.length) { said.textContent = 'Tick the tracks to put back first.'; return; }
    }
    asked = r; ask.hidden = true; delete yes.dataset.sent;
    act({ restore: r });
  });
  yes.addEventListener('click', () => {
    const a = M.ask;
    if (!a) return;
    yes.dataset.sent = '1';
    ask.hidden = true;
    act({ restore: { id: a.id, yes: true } }).finally(() => { delete yes.dataset.sent; });
  });
  no.addEventListener('click', () => { ask.hidden = true; });

  function onState() {
    const m = ssTabs.topics.hhear;
    if (m && m !== M) { M = m; render(); }
  }
  addEventListener('ss-state', onState);
  addEventListener('ss-tabs', onState);
  addEventListener('ss-hist-point', () => render());
  render();
})();
