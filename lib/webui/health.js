// StudioSync's Health tab (docs/rt/ui-web-plan.md 2.8, Phase 4; findings item 16; rt-ui4): Checks, Log, Updates, Can't hear each other? and
// Send feedback. Checks: the rows the panel's Settings > Health shows, from the "health" topic lib/webpages.lua builds out of
// lib/page_health.lua's own rows, red first; Show hidden (n) with Show again, Hide on an amber row, "Show messages about other scripts" (the
// rows lib/compat.lua adds; red ones always show); each row's button runs the panel's own function on that computer (lib/page_health.lua
// web_act: a phone may press only the safe ones, the rest say where they run). Log: the "log" topic (lib/weblog.lua), Copy, Log files. Each
// page says it shows every 10 s while shown. Everything from Live sync goes in as text (textContent), never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, cls) => { const b = mk('button', cls, text); b.type = 'button'; return b; };
  const remote = () => !!(window.ssEnv && window.ssEnv.where === 'remote');
  const computer = () => { const e = ssTabs.topics.env; return (e && e.computer) || 'that computer'; };
  const act = (o) => ssTabs.act('health', o).catch(() => {});
  // (the clipboard API only in a secure context: 127.0.0.1 is one, a tailnet address isn't)
  function copy(text, btn) {
    const was = btn.textContent;
    const fallback = () => { const t = mk('textarea'); t.value = text; document.body.append(t); t.select(); try { document.execCommand('copy'); } catch (e) {} t.remove(); };
    (navigator.clipboard && window.isSecureContext ? navigator.clipboard.writeText(text) : Promise.reject()).catch(fallback)
      .finally(() => { btn.textContent = 'Copied'; setTimeout(() => { btn.textContent = was; }, 1500); });
  }
  // the switches: Show hidden is this page's own; other scripts is the computer's (it also keeps their amber rows off Health's dot)
  let showHidden = false;
  let last = {}, lastLog = {}; // (a fresh object: the first draw always runs, even before any topic)
  // Whether a row shows: the same rule as webpages.health_shows.
  const shows = (r, other) => (r.hidden ? showHidden : !(r.other && !other && r.level !== 'red'));

  // ---- Checks ---------------------------------------------------------------------------------------------------------------------------
  const page = mk('section', 'health');
  page.setAttribute('aria-labelledby', 'health-h');
  const h = mk('h2', '', 'Set up and health');
  h.id = 'health-h';
  const vers = mk('p', 'dim hvers'), list = mk('ul', 'hrows'), foot = mk('p', 'dim hfoot');
  list.setAttribute('aria-live', 'polite');
  const said = mk('p', 'pnote psaid');
  said.setAttribute('role', 'status');
  const bar = mk('div', 'prow hswitches');
  const hiddenBtn = button('Show hidden', 'hshowhidden');
  hiddenBtn.setAttribute('aria-pressed', 'false');
  hiddenBtn.addEventListener('click', () => { showHidden = !showHidden; last = {}; draw(); });
  const otherBox = mk('input');
  otherBox.type = 'checkbox';
  otherBox.className = 'hother';
  otherBox.addEventListener('change', () => act({ other: otherBox.checked }));
  const otherLabel = mk('label', 'pfield');
  const otherCount = mk('span', 'dim hothercount');
  otherLabel.append(otherBox, document.createTextNode(' Show messages about other scripts '), otherCount);
  bar.append(otherLabel, hiddenBtn);
  // (other scripts and extensions: StudioSync's self-check, run now and through every script in the Actions list. lib/compat.lua)
  const recheck = button('Check other scripts now', 'hcompat');
  recheck.addEventListener('click', () => {
    recheck.disabled = true;
    ssTabs.act('health', { compat: true }).catch(() => {}).finally(() => setTimeout(() => { recheck.disabled = false; }, 10000));
  });
  const setupAll = button('Set up everything I can', 'pgo hsetup');
  setupAll.addEventListener('click', () => { setupAll.disabled = true; act({ act: '@setup' }).finally(() => setTimeout(() => { setupAll.disabled = remote(); }, 3000)); });
  const tail = mk('div', 'prow');
  tail.append(setupAll, recheck);
  page.append(h, vers, said, bar, list, foot, tail);

  // ---- Log ------------------------------------------------------------------------------------------------------------------------------
  const logPage = mk('section', 'health hlogpage');
  logPage.setAttribute('aria-label', 'Log');
  const logBar = mk('div', 'prow');
  const logCopy = button('Copy', 'hlogcopy'), logFiles = button('Log files', 'hlogfiles');
  logCopy.title = 'Copy the whole log, to paste it in a message when something went wrong.';
  logFiles.title = 'The folder with a log file per day: everything here, and every error with where it happened.';
  logCopy.addEventListener('click', () => { const m = ssTabs.topics.log; copy(((m && m.lines) || []).join('\n'), logCopy); });
  logFiles.addEventListener('click', () => act({ log: 'files' }));
  logBar.append(logCopy, logFiles);
  const logList = mk('pre', 'hlog');
  Object.assign(logList.style, { whiteSpace: 'pre-wrap', maxHeight: '65vh', overflow: 'auto', fontSize: '12px' });
  const logNote = mk('p', 'dim hfoot');
  logPage.append(logBar, logList, logNote);

  // ---- Updates --------------------------------------------------------------------------------------------------------------------------
  const upPage = mk('section', 'health hupdates');
  upPage.setAttribute('aria-label', 'Updates');
  const upVers = mk('p', 'hvers'), upNews = mk('ul', 'hrows');
  const upSS = button('Update StudioSync', 'pgo hupdate'), upReaper = button('Update REAPER', 'hupreaper');
  upSS.title = 'StudioSync itself, to the newest version.';
  upReaper.title = 'Opens the REAPER Update Utility (free, by FeedTheCat), which finds the newest REAPER and installs it.';
  upSS.addEventListener('click', () => act({ act: '@update' }));
  upReaper.addEventListener('click', () => act({ act: '@update reaper' }));
  const upRow = mk('div', 'prow');
  upRow.append(upSS, upReaper);
  upPage.append(upVers, upNews, upRow);

  // ---- Can't hear each other? (the panel's card under Settings > Health) -----------------------------------------------------------------
  const hearPage = mk('section', 'health hhear');
  hearPage.setAttribute('aria-label', 'Can’t hear each other?');
  const hearList = mk('ul', 'hhearlist');
  hearPage.append(mk('h2', '', 'Can’t hear each other?'), hearList);
  function drawHear(m) {
    const sb = !(m && m.builtin); // (the SonoBus half: not while the studio's own live audio runs. rt-audit §1)
    const items = [];
    if (sb) items.push('Real time goes straight between your computers: SonoBus’s public server only introduces you. Volumes shows each person and how their connection is doing: disconnect and connect again.');
    items.push('Wired internet, rather than Wi-Fi.');
    if (sb) items.push('Forward a UDP port on your router to this computer. SonoBus’s options can fix the port it uses.');
    items.push('A strict router or a work network can stop computers reaching each other directly. A VPN between you gets around that: Tailscale comes with StudioSync (tailscale.com/download). Ask whoever runs the studio to invite you to its Tailscale network, and sign in from that invitation.');
    items.push('On a Mac: System Settings > Privacy & Security > Microphone, with REAPER switched on. Without it, Talk and Real time send silence.');
    hearList.replaceChildren(...items.map((t) => mk('li', '', t)));
  }
  drawHear(null);

  // ---- Send feedback (lib/feedback.lua's save: the studio's _band/feedback folder) -------------------------------------------------------
  const fbPage = mk('section', 'health hfeedback');
  fbPage.setAttribute('aria-label', 'Send feedback');
  const fbKind = mk('select', 'hfbkind');
  fbKind.setAttribute('aria-label', 'Kind');
  for (const [v, t] of [['bug', 'Bug report'], ['feedback', 'Feedback'], ['feature', 'Feature request']]) fbKind.append(new Option(t, v));
  const fbSubject = mk('input', 'hfbsubject');
  fbSubject.maxLength = 200;
  fbSubject.placeholder = 'Subject (or leave it: the first line below is used)';
  fbSubject.setAttribute('aria-label', 'Subject');
  const fbBody = mk('textarea', 'hfbbody');
  fbBody.maxLength = 8000;
  fbBody.rows = 8;
  fbBody.placeholder = 'What happened, and what you expected. Steps to make it happen again help most.';
  fbBody.setAttribute('aria-label', 'What happened');
  Object.assign(fbSubject.style, { width: '100%', boxSizing: 'border-box' });
  Object.assign(fbBody.style, { width: '100%', boxSizing: 'border-box' });
  const fbLog = mk('input', 'hfblog');
  fbLog.type = 'checkbox';
  fbLog.checked = true;
  fbKind.addEventListener('change', () => { fbLog.checked = fbKind.value === 'bug'; });
  const fbLogLabel = mk('label', 'pfield');
  fbLogLabel.append(fbLog, document.createTextNode(' Add what it was doing (versions, the audio system, the project’s name, the last activity lines)'));
  const fbSend = button('Save it', 'pgo hfbsend');
  const fbSaid = mk('p', 'pnote hfbsaid');
  fbSaid.setAttribute('role', 'status');
  let fbWait = null; // (the health topic's said_n when Save was pressed: the next one is the answer)
  fbSend.addEventListener('click', () => {
    if (!fbSubject.value.trim() && !fbBody.value.trim()) { fbSaid.textContent = 'Write a subject or what happened first.'; return; }
    fbSend.disabled = true;
    fbWait = (ssTabs.topics.health || {}).said_n || 0;
    fbSaid.textContent = 'Saving…';
    act({ feedback: { kind: fbKind.value, subject: fbSubject.value, body: fbBody.value, log: fbLog.checked } })
      .finally(() => setTimeout(() => { fbSend.disabled = false; }, 2000));
  });
  fbPage.append(mk('h2', '', 'Send feedback'), mk('p', 'dim pnote', 'Saved in the studio’s folder (_band/feedback) for whoever looks after StudioSync.'),
    fbKind, fbSubject, fbBody, fbLogLabel, fbSend, fbSaid);

  // ---- registering, wants -----------------------------------------------------------------------------------------------------------------
  const shown = { checks: false, log: false, updates: false, hear: false, feedback: false };
  const any = () => Object.values(shown).some(Boolean);
  const want = () => {
    if (document.hidden) return;
    if (any()) act({ want: true });
    if (shown.log) act({ log: 'want' });
  };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);
  const on = (k) => (v) => { shown[k] = v; if (v) { want(); last = lastLog = {}; draw(); } };
  const HERE = ['reaper', 'local'];
  ssTabs.sub('health', 'checks', 'Checks', page, on('checks'));
  ssTabs.sub('health', 'log', 'Log', logPage, on('log'));
  ssTabs.sub('health', 'updates', 'Updates', upPage, on('updates'));
  // (this computer only: the advice is about this computer's setup, and a report goes out under its name)
  ssTabs.sub('health', 'hear', 'Can’t hear?', hearPage, on('hear'), { envs: HERE });
  ssTabs.sub('health', 'feedback', 'Send feedback', fbPage, on('feedback'), { envs: HERE });

  // ---- drawing ----------------------------------------------------------------------------------------------------------------------------
  const LEVEL = { red: 'needs fixing', yellow: 'worth a look', grey: 'just so you know' };
  // a row's button: on another device, one only that computer may press says where it runs
  function rowButton(r) {
    const b = button(r.act, 'hact');
    b.dataset.id = r.id;
    if (r.here && remote()) { b.disabled = true; b.title = 'Only on ' + computer() + '’s own screen.'; b.textContent = r.act + ' (on ' + computer() + ')'; }
    else b.addEventListener('click', () => { b.disabled = true; act({ act: r.id }).finally(() => setTimeout(() => { b.disabled = false; }, 3000)); });
    return b;
  }
  function drawRow(r) {
    const li = mk('li', 'hrow ' + (r.ok ? 'ok' : r.level || 'yellow') + (r.hidden ? ' hhidden' : '') + (r.other ? ' hotherrow' : ''));
    li.dataset.id = r.id;
    const dot = mk('span', 'hdot');
    dot.setAttribute('role', 'img');
    dot.setAttribute('aria-label', r.ok ? 'fine' : LEVEL[r.level] || 'worth a look');
    li.append(dot, mk('span', 'htext', r.text));
    if (r.link) {
      const a = mk('a', 'hlink', r.link.label);
      a.href = r.link.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
      li.append(a);
    }
    if (r.copy) {
      const c = button('Copy the line', 'hcopyb');
      c.title = r.copy;
      c.addEventListener('click', () => copy(r.copy, c));
      li.append(mk('code', 'hcopy', r.copy), c);
    }
    if (r.act) li.append(rowButton(r));
    if (r.hidden) {
      const s = button('Show again', 'hunhide');
      s.addEventListener('click', () => act({ show: r.id }));
      li.append(s);
    } else if (!r.ok && r.level === 'yellow') {
      const s = button('Hide', 'hhide');
      s.title = 'Hide this one (it stops lighting up Health). Show hidden brings it back.';
      s.addEventListener('click', () => act({ hide: r.id }));
      li.append(s);
    }
    return li;
  }
  function draw() {
    if (shown.log) drawLog();
    const m = ssTabs.topics.health;
    if (!any() || m === last) return;
    last = m;
    drawHear(m);
    list.replaceChildren();
    if (!m) { list.append(mk('li', 'dim', 'Asking Live sync…')); return; }
    const v = 'StudioSync ' + (m.ver || '?') + ' · extension ' + (m.ext || 'not loaded');
    vers.textContent = v;
    upVers.textContent = v;
    if (m.said) said.textContent = m.said;
    if (fbWait !== null && (m.said_n || 0) !== fbWait) {
      fbSaid.textContent = m.said || '';
      fbWait = null;
      if (/^feedback saved/.test(m.said || '')) { fbSubject.value = ''; fbBody.value = ''; }
    }
    if (m.error) list.append(mk('li', 'hrow red', 'Health couldn’t be read here: ' + m.error));
    const other = m.show_other !== false;
    otherBox.checked = other;
    otherCount.textContent = !other && m.other ? '(' + m.other + ' hidden)' : '';
    hiddenBtn.hidden = !m.hidden && !showHidden;
    hiddenBtn.textContent = (showHidden ? 'Hide them again' : 'Show hidden') + ' (' + (m.hidden || 0) + ')';
    hiddenBtn.setAttribute('aria-pressed', String(showHidden));
    for (const r of m.rows || []) if (shows(r, other)) list.append(drawRow(r));
    if (!list.children.length && !m.error) list.append(mk('li', 'dim', 'Nothing to show.'));
    const far = remote();
    setupAll.disabled = far;
    setupAll.title = far ? 'Only on ' + computer() + '’s own screen.' : 'Starts Syncthing and Live sync. The rest needs you.';
    foot.textContent = far ? 'Buttons marked with a computer’s name run only there.' : '';
    // Updates: the rows about versions (a newer StudioSync in the studio, REAPER behind)
    upNews.replaceChildren(...(m.rows || []).filter((r) => !r.ok && (/^update /.test(r.id) || r.id === 'reaper')).map(drawRow));
  }
  function drawLog() {
    const m = ssTabs.topics.log;
    if (m === lastLog) return;
    lastLog = m;
    logList.textContent = m ? ((m.lines || []).join('\n') || 'Nothing yet.') : 'Asking Live sync…';
    logNote.textContent = m && m.days ? 'Newest first. The log files keep the last ' + m.days + ' days, with every error and where it happened.' : '';
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
})();
