// The Studio tab and the lobby (rt-ui2: docs/rt/ui-web-plan.md Phase 2), driven in headless Chromium against a stand-in server:
//   node tests/rt_ui2_browser.mjs            (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The real lib/webui/index.html with every real page file, served from lib/webui with stand-in topics over /api/events, as Autostart publishes
// them with no studio project in front (lib/weblobby.lua: env with no project, an empty presence, home, lobby, invite) and as Live sync does
// with one; the actions the page POSTs are recorded. Checks: the tabs with no project, the lobby's note and "Share with", your studios (Open
// on another, Start a studio and Paste a join code on this computer only), the project cards (pinned first, Archived folded, search, the
// Folders and Stage views, Open, Ask... and Link, the menu's pin, stage, folder, archive), another device's limits, a project open again.
// Nothing reaches REAPER or the network: its own Chrome profile in a temp folder, a random localhost port ("studio.test" mapped to it), no
// devices. (The harness is tests/rt_ui1_browser.mjs's.)
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'webui');
const CHROMES = ['C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'];
const chrome = CHROMES.find((p) => fs.existsSync(p));
if (!chrome) { console.log('note: no Chrome or Edge here, so the page checks were not run'); console.log('ok'); process.exit(0); }

// ---- the stand-in server ------------------------------------------------------------------------------------------------------------------
let state = { engine: false, topics: {} };
const clients = new Set();
const actions = [];
const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.svg': 'image/svg+xml', '.png': 'image/png' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/api/state') { res.setHeader('Content-Type', 'application/json'); return res.end(JSON.stringify(state)); }
  if (u.pathname === '/api/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
    res.write('data: ' + JSON.stringify(state) + '\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  if (u.pathname === '/api/action') {
    let b = '';
    req.on('data', (c) => { b += c; });
    req.on('end', () => { try { actions.push(JSON.parse(b)); } catch (e) { actions.push({ bad: b }); } res.setHeader('Content-Type', 'application/json'); res.end('{}'); });
    return;
  }
  const f = path.join(root, u.pathname === '/' ? 'index.html' : path.basename(u.pathname));
  if (fs.existsSync(f)) { res.setHeader('Content-Type', types[path.extname(f)] || 'application/octet-stream'); return res.end(fs.readFileSync(f)); }
  res.statusCode = 404; res.end();
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port0 = server.address().port;
const LOCAL = 'http://127.0.0.1:' + port0 + '/', REMOTE = 'http://studio.test:' + port0 + '/';
// what a computer would publish next (the changed topics only, as the extension sends them)
const push = async (s) => {
  state = { engine: 'engine' in s ? s.engine : state.engine, topics: Object.assign({}, state.topics, s.topics || {}) };
  for (const c of clients) c.write('data: ' + JSON.stringify({ engine: state.engine, topics: s.topics || {} }) + '\n\n');
  await sleep(250);
};

// ---- Chrome over the DevTools protocol (Node's own WebSocket, no packages) -----------------------------------------------------------------
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui2-chrome-'));
const proc = spawn(chrome, ['--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + prof, '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--window-size=1100,720', '--host-resolver-rules=MAP studio.test 127.0.0.1', 'about:blank'], { stdio: 'ignore' });
let fails = 0;
const done = async (code) => { try { proc.kill(); } catch (e) {} for (const c of clients) c.end(); server.close(); await new Promise((r) => setTimeout(r, 300)); try { fs.rmSync(prof, { recursive: true, force: true }); } catch (e) {} process.exit(code); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
process.on('uncaughtException', (e) => { console.log('FAIL the driver stopped: ' + (e && e.message)); done(1); });
let port = 0;
for (let i = 0; i < 100 && !port; i++) { await sleep(100); try { port = parseInt(fs.readFileSync(path.join(prof, 'DevToolsActivePort'), 'utf8').split('\n')[0], 10); } catch (e) {} }
if (!port) { console.log('FAIL Chrome did not start'); await done(1); }
const targets = await (await fetch('http://127.0.0.1:' + port + '/json/list')).json();
const ws = new WebSocket(targets.find((t) => t.type === 'page').webSocketDebuggerUrl);
await new Promise((r) => { ws.onopen = r; });
let nid = 0;
const wait = new Map();
const errors = [];
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
  else if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails.exception ? d.params.exceptionDetails.exception.description : d.params.exceptionDetails.text);
  else if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') errors.push(d.params.args.map((a) => a.value || a.description).join(' '));
};
const cdp = (method, params = {}) => new Promise((r) => { const id = ++nid; wait.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const ev = async (js) => {
  const r = await cdp('Runtime.evaluate', { expression: js, awaitPromise: true, returnByValue: true });
  if (r.result.exceptionDetails) throw new Error('page: ' + JSON.stringify(r.result.exceptionDetails.exception || r.result.exceptionDetails));
  return r.result.result.value;
};
const ok = (c, m) => { if (!c) { fails++; console.log('FAIL ' + m); } else console.log('  ok ' + m); };
await cdp('Runtime.enable');
await cdp('Page.enable');

// a fresh page: its size, a phone or not, in REAPER (a stand-in WebView2 channel recording what the page sends) or not, empty storage
let injected = null;
async function open(url, o = {}) {
  await cdp('Emulation.setDeviceMetricsOverride', { width: o.w || 1100, height: o.h || 720, deviceScaleFactor: 1, mobile: !!o.phone });
  await cdp('Emulation.setTouchEmulationEnabled', { enabled: !!o.phone });
  if (injected) await cdp('Page.removeScriptToEvaluateOnNewDocument', { identifier: injected });
  injected = null;
  if (o.reaper) {
    injected = (await cdp('Page.addScriptToEvaluateOnNewDocument', { source:
      'window.__sent = []; window.__ls = []; window.chrome = window.chrome || {}; window.chrome.webview = { postMessage: (m) => window.__sent.push(m), ' +
      'addEventListener: (t, f) => { if (t === "message") window.__ls.push(f); } };' })).result.identifier;
  }
  await cdp('Page.navigate', { url: 'about:blank' }); // (a fresh document, not a hash change in the last one)
  for (let t = 0; t < 3000 && await ev('location.href') !== 'about:blank'; t += 50) await sleep(50);
  await cdp('Storage.clearDataForOrigin', { origin: new URL(url).origin, storageTypes: 'local_storage' });
  await cdp('Page.navigate', { url });
  // (until the shell has shown its first page and had the first state: a loaded machine takes longer than an idle one)
  for (let t = 0; t < 8000; t += 100) { await sleep(100); try { if (await ev('location.href === ' + JSON.stringify(url) + ' && !!(window.ssTabs && (ssTabs.route() || ssEnv.pop)) && document.readyState === "complete"')) break; } catch (e) {} }
  await sleep(400);
}
const tabsShown = () => ev('[...document.querySelectorAll("#sstabs .tab:not(.ssmore)")].filter((b) => !b.hidden).map((b) => b.textContent).join(",")');
const route = () => ev('ssTabs.route()');
const visible = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return !!e && e.getClientRects().length > 0; })()');
const text = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return e ? e.textContent : null; })()');
const click = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); if (e) e.click(); return !!e; })()');
const until = async (f, ms = 2000) => { for (let t = 0; t < ms && !f(); t += 50) await sleep(50); return f(); }; // (a POST lands when it lands)
const last = (pred) => actions.filter(pred).pop();
const names = () => ev('[...document.querySelectorAll("#home .hprojects .hbody > .hprojlist > li .hpname")].map((e) => e.textContent).join(",")');
const iso = (minAgo) => new Date(Date.now() - minAgo * 60000).toISOString().replace(/\.\d+Z$/, 'Z');
const card = (name) => '[...document.querySelectorAll("#home .hproj")].find((l) => l.querySelector(".hpname").textContent === ' + JSON.stringify(name) + ')';
const setSearch = (v) => ev('(() => { const s = document.querySelector("#home .hpsearch"); s.value = ' + JSON.stringify(v) + '; s.dispatchEvent(new Event("input")); return 1; })()');
const seg = (label) => ev('[...document.querySelectorAll("#home .hseg button")].find((b) => b.textContent === ' + JSON.stringify(label) + ').click(), 1');
const groups = () => ev('[...document.querySelectorAll("#home .hgroup")].map((h) => h.textContent).join(",")');

// what Autostart publishes with no studio project in front (lib/weblobby.lua)
const HOME = { me: 'James-Main', studio: 'Chilio', stages: ['Idea', 'Writing', 'Tracking', 'Mixing', 'Done'], folders: ['Songs', 'Sketches'],
  projects: [
    { name: 'Cross Test', stage: 'Tracking', folder: 'Songs', rooms: 2, roomnames: ['main', 'try-chorus'], online: [{ user: 'Bo' }], last: { user: 'Bo', time: iso(12), what: 'added 3 takes' } },
    { name: 'Night Drive', stage: 'Mixing', folder: 'Songs', rooms: 1, online: [], last: { user: 'Sam', time: iso(60 * 26), what: 'rendered a mix' } },
    { name: 'Riff ideas', stage: 'Idea', folder: 'Sketches', pinned: true, rooms: 1, online: [], last: { user: 'James-Main', time: iso(60 * 72), what: 'changed the tempo' } },
    { name: 'Old Demo', rooms: 1, online: [], archived: true },
    { name: 'Open Here', rooms: 1, online: [], open: true },
  ], online: [{ user: 'Bo', song: 'Cross Test' }], takes: [], bounces: [], mentions: [], todos: [], recent: [] };
const LOBBY = { me: 'James-Main', current: 'chilio-1', studios: [
  { id: 'chilio-1', name: 'Chilio', role: 'owner', current: true, projects: 5, people: ['Bo', 'Sam'] },
  { id: 'other-2', name: 'Test Band', role: 'member', projects: 1, people: [] }] };
const INVITE = { me: 'James-Main', studio: 'chilio-1', port: 47281, people: ['Bo', 'Sam'], inside: [], asks: [] };
const LOBBYSTATE = { engine: true, topics: { env: { v: 1, computer: 'James-Main', user: 'James-Main', front: { name: 'Untitled 3.rpp', tracks: 2 },
  tabs: [{ name: 'Untitled 3.rpp', front: true }], studios: [{ name: 'Chilio', role: 'owner' }, { name: 'Test Band', role: 'member' }] },
  presence: { people: [], claims: [] }, home: HOME, lobby: LOBBY, invite: INVITE, profiles: { me: 'James-Main', people: {} } } };

// ---- this computer, no studio project in front: Autostart answers -------------------------------------------------------------------------
state = JSON.parse(JSON.stringify(LOBBYSTATE));
await open(LOCAL);
ok(await tabsShown() === 'Studio,Health,Settings', 'no project open: Studio, Health, Settings, no Chat yet (' + await tabsShown() + ')');
ok(await route() === 'studio/overview' && await visible('#home'), 'the Studio tab shows');
ok(await until(() => actions.some((a) => a.topic === 'home' && a.want)), 'the page asks for Home (Autostart builds it)');
ok((await text('#home .hlobby') || '').includes('No studio project is open in REAPER'), 'the lobby says no studio project is open');
ok((await text('#home .hshare') || '').includes('“Untitled 3” is open in REAPER and isn’t shared yet') && await visible('#home .hshare button'), 'the tab in front isn\'t shared: Share with Chilio');
await click('#home .hshare button');
ok(await until(() => !!last((a) => a.topic === 'home' && a.lobby && a.lobby.share)), 'Share sends the lobby\'s share');
// your studios
ok((await text('#home .hstudios .hstud.current') || '').includes('you’re working in this one'), 'your studios: the one you work in');
await click('#home .hstudios .hstud:not(.current) .hopen');
ok(await until(() => { const a = last((x) => x.lobby && x.lobby.use); return a && a.lobby.use === 'other-2' && a.topic === 'home'; }), 'Open on another studio switches to it');
await ev('(() => { document.querySelector("#home .hstudforms > button").click(); const f = document.querySelector("#home .hstudforms form"); f.querySelector("input").value = "New Band"; f.requestSubmit(); return 1; })()');
ok(await until(() => { const a = last((x) => x.lobby && x.lobby.start); return a && a.lobby.start === 'New Band'; }), 'Start a studio');
await ev('(() => { document.querySelectorAll("#home .hstudforms > button")[1].click(); const f = document.querySelectorAll("#home .hstudforms form")[1]; f.querySelector("textarea").value = "studiosync-join:ABC:band:Band"; f.requestSubmit(); return 1; })()');
ok(await until(() => { const a = last((x) => x.lobby && x.lobby.join); return a && a.lobby.join.startsWith('studiosync-join'); }), 'Paste a join code');
// projects: pinned first, archived folded, last worked on kept
ok(await names() === 'Riff ideas,Cross Test,Night Drive,Open Here', 'pinned first, then last worked on; archived not in the list (' + await names() + ')');
ok((await text('#home .harch summary')) === 'Archived (1)' && await ev('!document.querySelector("#home .harch").open'), 'Archived folded at the end, with its count');
ok(await ev(card('Open Here') + '.querySelector(".hopen").textContent') === 'Switch to it', 'one open in another tab: Switch to it');
// Ask... and Link on the cards (invite.js)
ok(await ev('(() => { const s = document.querySelector("#home .hproj .hpinv"); return !!s.querySelector(".iaskp") && !!s.querySelector(".ilink"); })()'), 'Ask… and Link beside Open on each card');
await ev('document.querySelector("#home .hproj .ilink").click(); 1');
ok(((await ev('(() => { const i = document.querySelector("#home .hproj .ilinkbox input"); return i ? i.value : ""; })()')) || '').startsWith('studiosync://join?s=chilio-1&p=Riff%20ideas'), 'Link: the project\'s studiosync:// link');
await click('#home .hproj .hopen');
ok(await until(() => { const a = last((x) => x.open); return a && a.open.song === 'Riff ideas' && a.open.room === 'main'; }), 'Open asks to open it here');
// search
await setSearch('sam');
ok(await names() === 'Night Drive', 'search finds by who worked on it (' + await names() + ')');
await setSearch('demo');
ok(await names() === '' && await ev('document.querySelector("#home .harch").open') && await ev('document.querySelector("#home .harch .hpname").textContent') === 'Old Demo', 'and in the archive, opened to show it');
await setSearch('');
// views
await seg('Folders');
ok(await groups() === 'Songs (2),Sketches (1),No folder (1)', 'Folders: the studio\'s folders in order, then none (' + await groups() + ')');
await seg('Stage');
ok(await groups() === 'Idea (1),Tracking (1),Mixing (1),No stage (1)', 'Stage: in the stages\' order (' + await groups() + ')');
ok(await ev('localStorage.getItem("ss-studio-view")') === 'stage', 'the view is remembered');
await seg('Recent');
// the card's menu
await ev('(() => { ' + card('Cross Test') + '.querySelector(".hpmore").open = true; return 1; })()');
ok(await ev(card('Cross Test') + '.querySelector(".hpmenu").getClientRects().length > 0'), 'the ⋯ menu opens');
await ev('(() => { ' + card('Cross Test') + '.querySelector(".hpmenu button").click(); return 1; })()');
ok(await until(() => { const a = last((x) => x.lobby && 'pin' in x.lobby); return a && a.lobby.song === 'Cross Test' && a.lobby.pin === true; }), 'Pin to the top');
await ev('(() => { const s = ' + card('Cross Test') + '.querySelectorAll(".hpmenu select")[0]; s.value = "Mixing"; s.dispatchEvent(new Event("change")); return 1; })()');
ok(await until(() => { const a = last((x) => x.lobby && 'stage' in x.lobby); return a && a.lobby.stage === 'Mixing'; }), 'a stage');
await ev('(() => { const s = ' + card('Cross Test') + '.querySelectorAll(".hpmenu select")[1]; s.value = "Sketches"; s.dispatchEvent(new Event("change")); return 1; })()');
ok(await until(() => { const a = last((x) => x.lobby && 'folder' in x.lobby); return a && a.lobby.folder === 'Sketches'; }), 'into a folder');
ok(await ev(card('Cross Test') + '.querySelector(".hpmenu").textContent.includes("Open room try-chorus")'), 'its rooms');
await ev('(() => { [...' + card('Cross Test') + '.querySelectorAll(".hpmenu button")].find((b) => b.textContent === "Archive").click(); return 1; })()');
ok(await until(() => { const a = last((x) => x.lobby && 'archive' in x.lobby); return a && a.lobby.archive === true && a.lobby.song === 'Cross Test'; }), 'Archive');
await ev('(() => { document.querySelector("#home .hnewfolder").click(); const f = document.querySelector("#home .hprojects .hform"); f.querySelector("input").value = "Live"; f.requestSubmit(); return 1; })()');
ok(await until(() => { const a = last((x) => x.lobby && x.lobby.newfolder); return a && a.lobby.newfolder === 'Live'; }), 'New folder');
// a menu open stays open over a redraw
await ev('(() => { ' + card('Night Drive') + '.querySelector(".hpmore").open = true; return 1; })()');
await push({ topics: { home: Object.assign({}, HOME, { takes: [{ user: 'Bo', song: 'Cross Test', time: iso(1) }] }) } });
ok(await ev(card('Night Drive') + '.querySelector(".hpmore").open'), 'an open menu stays open when Home is drawn again');
// the last action's words
await push({ topics: { lobby: Object.assign({}, LOBBY, { said: { ok: false, text: 'That isn\'t a join code', at: 1 } }) } });
ok((await text('#home .hsaid')) === 'That isn\'t a join code' && await ev('document.querySelector("#home .hsaid").classList.contains("bad")'), 'what the computer said back');

// ---- another device: no Start, Join or Share --------------------------------------------------------------------------------------------------
state = JSON.parse(JSON.stringify(LOBBYSTATE));
await open(REMOTE);
ok(await ev('ssEnv.where') === 'remote', 'another device');
ok(!(await visible('#home .hstudforms')), 'no Start a studio or Paste a join code from another device');
ok((await text('#home .hshare') || '').includes('is open on James-Main') && !(await visible('#home .hshare button')), 'the unshared project named, no Share button');
ok((await text('#home .hlobby') || '').includes('No studio project is open on James-Main'), 'the lobby names the computer');

// ---- a studio project opens again (Live sync answers) -------------------------------------------------------------------------------------------
await push({ engine: true, topics: { env: { v: 1, studio: 'Chilio', computer: 'James-Main', front: { name: 'Cross Test.rpp', project: 'Cross Test', room: 'main', live: true, shared: true } },
  presence: { song: 'Cross Test', room: 'main', people: [{ user: 'James-Main', me: true, armed: [] }], claims: [] },
  home: Object.assign({}, HOME, { song: 'Cross Test', projects: HOME.projects.map((p) => (p.name === 'Cross Test' ? Object.assign({}, p, { current: true }) : p)) }) } });
ok(await tabsShown() === 'Studio,Session,Project,Chat,History,Plug-ins,Health,Settings', 'a project open: its tabs come back (' + await tabsShown() + ')');
ok(await ev('document.querySelector("#home .hlobby").hidden && document.querySelector("#home .hshare").hidden'), 'no lobby note, no Share bar');
ok(await ev(card('Cross Test') + '.querySelector(".hopen").textContent') === 'Project view', 'the project you\'re in: Project view');

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
