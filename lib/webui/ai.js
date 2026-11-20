// StudioSync's AI page (lib/ai.lua): optional AI tools that ask before every run. Reads the "ai" topic (the studio's switch, each tool and
// where it runs on this computer, the takes and newest mix while the page shows, the asks waiting for a yes, recent jobs); sends on the "ai"
// topic: want (every 10 s while shown), ask, yes, no, cancel. Asking only makes an ask: it shows what goes where and what comes back, and
// nothing runs until Yes. A yes from a phone counts only if that computer allows it (Live sync says so). Everything from Live sync goes in
// as text (textContent), never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, cls) => { const b = mk('button', cls, text); b.type = 'button'; return b; };
  const clock = (s) => { s = Math.max(0, Math.floor(Number(s) || 0)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };

  const page = mk('section', 'aipage');
  page.setAttribute('aria-labelledby', 'ai-h');
  const h = mk('h2', '', 'AI tools (optional)');
  h.id = 'ai-h';
  const state = mk('p', 'pnote'), privacy = mk('p', 'dim pnote');
  privacy.textContent = 'Every run asks first and shows exactly what goes where. “This computer”: nothing leaves it (a tool may use the ' +
    'graphics card for a few minutes). “Sent away”: the text leaves this computer for the address set there. No audio is ever sent to a chat model.';
  const asksH = mk('h2', '', 'Waiting for your yes'), asks = mk('ul', 'aiasks');
  asks.setAttribute('aria-live', 'polite');
  const featsH = mk('h2', '', 'Tools'), feats = mk('ul', 'aifeats');
  const jobsH = mk('h2', '', 'Runs'), jobs = mk('ul', 'aijobs');
  const said = mk('p', 'pnote psaid');
  said.setAttribute('role', 'status');
  page.append(h, state, privacy, said, asksH, asks, featsH, feats, jobsH, jobs);

  let shown = false;
  const want = () => { if (shown && !document.hidden) ssTabs.act('ai', { want: true }).catch(() => {}); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  ssTabs.add('ai', 'AI', page, (on) => { shown = on; if (on) { want(); draw(true); } });
  // (what happened comes back as the topic's note: clearing the line here raced it and wiped a refusal)
  const send = (o) => ssTabs.act('ai', o).catch(() => { said.textContent = 'Couldn’t reach Live sync.'; });

  // (the pickers keep what's chosen across redraws: a redraw comes with every change of the topic)
  const picks = {};
  function takeSelect(f, m) {
    const sel = mk('select');
    sel.setAttribute('aria-label', f.label + ': which take');
    if (f.id === 'stems') sel.append(new Option(m.mix ? 'The newest mix (' + m.mix + ')' : 'The newest mix (none yet)', 'mix'));
    for (const t of m.takes || []) sel.append(new Option((t.track || '?') + ': ' + (t.name || '(no name)') + ' @ ' + clock(t.pos), t.g));
    if (!sel.options.length) sel.append(new Option('No takes yet', ''));
    if (picks[f.id] != null && [...sel.options].some((o) => o.value === picks[f.id])) sel.value = picks[f.id];
    sel.addEventListener('change', () => { picks[f.id] = sel.value; });
    return sel;
  }
  const WHERE = { here: 'this computer', away: 'sent away' };
  let last = null;
  function draw(force) {
    const m = ssTabs.topics.ai;
    if (!shown || (m === last && !force)) return;
    last = m;
    if (!m) { state.textContent = 'Asking Live sync…'; return; }
    state.textContent = m.on ? 'On for this studio. Runs happen on ' + (m.me || 'this') + '’s computer.'
      : 'Off for this studio' + (m.may ? ': turn it on in the panel, Settings > Studio > AI.' : ': the owner or an admin turns it on in the panel (Settings > Studio > AI).');
    if (m.note) said.textContent = m.note;
    // asks
    asks.replaceChildren();
    for (const a of m.asks || []) {
      const li = mk('li', 'aiask ' + (a.here ? 'here' : 'away'));
      li.append(mk('strong', '', a.label + '?'), mk('span', 'badge ' + (a.here ? 'play' : 'rec'), a.here ? 'this computer' : 'sent away'),
        mk('pre', 'aisends', a.sends), mk('p', 'dim pnote', 'Comes back: ' + a.result + ' (This ask runs out 2 minutes after it was made.)'));
      const yes = button('Yes, run it', 'pgo'), no = button('No');
      yes.addEventListener('click', () => { yes.disabled = no.disabled = true; send({ yes: a.id }); });
      no.addEventListener('click', () => { yes.disabled = no.disabled = true; send({ no: a.id }); });
      const row = mk('div', 'prow');
      row.append(yes, no);
      li.append(row);
      if (!m.phone_yes) li.append(mk('p', 'dim pnote', 'From a phone this yes only counts if ' + (m.me || 'that') + '’s computer allows it.'));
      asks.append(li);
    }
    asksH.hidden = asks.hidden = !(m.asks || []).length;
    // tools
    feats.replaceChildren();
    for (const f of m.features || []) {
      const li = mk('li', 'aifeat');
      const head = mk('div', 'prow');
      head.append(mk('strong', '', f.label));
      if (f.provider === 'none') head.append(mk('span', 'badge', 'not set up'));
      else head.append(mk('span', 'badge ' + (f.where === 'here' ? 'play' : 'rec'), WHERE[f.where] || f.where));
      li.append(head);
      if (f.provider === 'none') { li.append(mk('p', 'dim pnote', f.why || '')); feats.append(li); continue; }
      const row = mk('div', 'prow');
      let sel = null, tracks = null;
      if (f.input === 'take' || f.input === 'audio') { sel = takeSelect(f, m); row.append(sel); }
      if (f.id === 'stems') {
        tracks = mk('input'); tracks.type = 'checkbox'; tracks.checked = picks.stemsTracks !== false;
        tracks.addEventListener('change', () => { picks.stemsTracks = tracks.checked; });
        const l = mk('label', 'pfield'); l.append(tracks, document.createTextNode(' also as new tracks'));
        row.append(l);
      }
      const go = button('Ask…', 'pgo');
      go.disabled = !m.on;
      go.addEventListener('click', () => {
        const ask = { feature: f.id };
        if (sel) { if (sel.value === 'mix') ask.mix = true; else if (sel.value) ask.take = sel.value; }
        if (tracks) ask.tracks = tracks.checked;
        send({ ask });
      });
      row.append(go);
      li.append(row);
      feats.append(li);
    }
    // runs
    jobs.replaceChildren();
    for (const j of m.jobs || []) {
      const li = mk('li', 'aijob ' + j.state);
      li.append(mk('strong', '', j.label), mk('span', 'badge' + (j.state === 'failed' ? ' rec' : j.state === 'done' ? ' play' : ''), j.state),
        mk('span', 'dim', j.secs != null ? ' ' + clock(j.secs) : ''));
      if (j.msg) li.append(mk('p', 'pnote', j.msg));
      if (j.state === 'running') {
        const c = button('Cancel');
        c.addEventListener('click', () => { c.disabled = true; send({ cancel: j.id }); });
        li.append(c);
      }
      jobs.append(li);
    }
    if (!(m.jobs || []).length) jobs.append(mk('li', 'dim', 'None yet.'));
  }
  addEventListener('ss-state', () => draw(false));
  addEventListener('ss-tabs', () => draw(false));
})();
