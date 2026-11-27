// History (rt-ui3: docs/rt/ui-web-plan.md Phase 3), driven in headless Chromium against a stand-in server:
//   node tests/rt_ui3_browser.mjs            (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The real lib/webui/index.html with every real page file (tests/rt_ui1_browser.mjs's harness), stand-in hchanges / hmixes / hhear topics,
// the actions the page POSTs recorded. On this computer and on another device (wide and as a phone): Changes, Versions and Mixes as History's
// sub-tabs; the filters going out with "I'm looking"; Undo and Restore asking first, the confirm showing Live sync's words, and only "Yes"
// sending { yes: id, confirm: true } (a phone too); what opens or plays in REAPER shown only on this computer; Play through REAPER and Open this
// point in REAPER on Playback. Nothing reaches REAPER or the network: its own Chrome profile in a temp folder, a random localhost port, no devices.
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
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui3-chrome-'));
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
  // (the last page's event streams ended here: Chrome kept old ones open at times, and at its six connections a host the next page's files waited, rt-ui10a)
  for (const c of clients) c.end();
  clients.clear();
  await cdp('Storage.clearDataForOrigin', { origin: new URL(url).origin, storageTypes: 'local_storage' });
  await cdp('Page.navigate', { url });
  // (until the shell has shown its first page and had the first state: a loaded machine takes longer than an idle one)
  for (let t = 0; t < 8000; t += 100) { await sleep(100); try { if (await ev('location.href === ' + JSON.stringify(url) + ' && !!(window.ssTabs && (ssTabs.route() || (ssEnv.pop && document.body.classList.contains("sspop")))) && document.readyState === "complete"')) break; } catch (e) {} }
  await sleep(400);
}
const tabsShown = () => ev('[...document.querySelectorAll("#sstabs .tab:not(.ssmore)")].filter((b) => !b.hidden).map((b) => b.textContent).join(",")');
const list = () => ev('ssTabs.list()');
const okSubs = async (tab) => (await list()).find((t) => t.name === tab).subs.filter((s) => s.ok).map((s) => s.name).join(',');
const route = () => ev('ssTabs.route()');
const visible = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return !!e && e.getClientRects().length > 0; })()');
const now = () => Math.floor(Date.now() / 1000);
const until = async (f, ms = 20000) => { for (let t = 0; t < ms && !f(); t += 50) await sleep(50); return f(); }; // (a POST lands when it lands)
const PROJECT = { engine: true, topics: { env: { v: 1, studio: 'Chilio', front: { name: 'Cross Test.rpp', project: 'Cross Test', room: 'main', live: true, shared: true } },
  presence: { song: 'Cross Test', room: 'main', driver: 'James-Main', people: [{ user: 'James-Main', me: true, armed: [] }], claims: [] } } };
const NOPROJECT = { engine: false, topics: { env: { v: 1 }, presence: null } };

// ---- History's topics, standing in for lib/webrestore.lua, lib/webmixes.lua and lib/histhear.lua -------------------------------------------
const T0 = now() - 3600;
const KINDS = ['Every kind', 'Items (recordings, MIDI, moves, edits)', 'Tracks (names, lanes, mute, folders)', 'Plug-ins', 'Automation, sends and track settings', 'Deletes'];
const CH = { key: 'Cross Test/main', kinds: KINDS, f: { who: '', kind: 1, track: '', text: '' }, driver: true, tracks_now: [['T-A', 'Guitar'], ['T-B', 'Bass']],
  rows: [{ id: 'e3', t: T0 + 300, who: 'Bo', words: 'Bo’s take on <b>Guitar</b>', undo: true }, { id: 'e2', t: T0 + 200, who: 'James-Main', words: 'deleted Bass', tint: 'gone', undo: true, n: 2 },
    { id: 'n1', t: T0 + 100, who: 'Bo', words: 'a note' }],
  users: ['Bo', 'James-Main'], tracks: ['Guitar', 'Bass'], more: 0,
  versions: [{ file: 'v1.json', t: T0 + 150, label: 'before solo', by: 'Bo', keep: true }, { file: 'v0.json', t: T0 - 99999, label: 'old', by: 'Bo', old: true }],
  before: true, kept: [{ id: 'k1.json', name: 'Guitar', t: T0, here: true }] };
const MIXA = 'Cross Test 2026-11-26 090000 Bo.wav', MIXB = 'Cross Test 2026-11-27 090000 James-Main.wav';
const MX = { mixes: [{ name: MIXB, who: 'James-Main', t: T0 + 50 }, { name: MIXA, who: 'Bo', t: T0 }], stems: [{ name: '2026-11-27 0900 Bo', who: 'Bo', t: T0 }], sws: true, ab: {} };
const HIST = { users: ['Bo'], cols: [false], kinds: ['take', 'edit', 'mix', 'midi', 'time'], tracks: [['Guitar', 0]], frames: [{ t: T0 + 150, s: 0, n: 1, ta: [0] }],
  sessions: [{ a: T0 + 150, z: T0 + 150, n: 1, f: 0, u: [0] }], who: [[1, 0, 0, 0, 0, 0, 0, T0, T0]], days: [], versions: [], changes: 1, per: 1, read: { done: true }, lengths: {} };
const HH = { sws: true, driver: true, tracks: [['T-A', 'Guitar']], then: { t: T0 + 150, state: 'ready', file: '0123456789abcdef0123456789abcdef', len: 90 } };
const WITH = (extra) => ({ engine: true, topics: Object.assign({}, PROJECT.topics, { hchanges: CH, hmixes: MX, hist: HIST, hhear: HH }, extra || {}) });
const mark = () => actions.length;
// (a loaded machine's first topic can take a few seconds)
const waitFor = async (js, ms = 20000) => { for (let t = 0; t < ms; t += 100) { if (await ev(js)) return true; await sleep(100); } return false; };
const sent = (m, f) => actions.slice(m).filter((a) => a.topic === 'history' && f(a));
const click = (sel, text) => ev('(() => { const b = [...document.querySelectorAll(' + JSON.stringify(sel) + ')].find((x) => x.textContent === ' + JSON.stringify(text) + ' && !x.closest("[hidden]")); if (!b) return false; b.click(); return true; })()');
const texts = (sel) => ev('[...document.querySelectorAll(' + JSON.stringify(sel) + ')].filter((x) => !x.closest("[hidden]")).map((x) => x.textContent).join("|")');
const shown = (sel, text) => ev('(() => { const b = [...document.querySelectorAll(' + JSON.stringify(sel) + ')].find((x) => x.textContent === ' + JSON.stringify(text) + '); return !!b && b.getClientRects().length > 0; })()');
const disabled = (sel, text) => ev('(() => { const b = [...document.querySelectorAll(' + JSON.stringify(sel) + ')].find((x) => x.textContent === ' + JSON.stringify(text) + '); return !!b && b.disabled; })()');

// ---- this computer: Changes ---------------------------------------------------------------------------------------------------------------
state = WITH();
await open(LOCAL + '#history');
ok(await route() === 'history/changes', 'History opens on Changes now it\'s built');
ok(await ev('[...document.querySelectorAll(".sstab[data-tab=history] .sssubs button")].filter((b) => !b.hidden).map((b) => b.textContent).join(",")') === 'Changes,Versions,Playback,Mixes', 'its four sub-tabs');
ok(!(await visible('.sstab[data-tab=history] .sscoming')) && (await list()).find((t) => t.name === 'history').subs.every((s) => !s.coming), 'none of them "coming" any more');
let m = 0;
ok(await until(() => sent(0, (a) => a.changes && a.changes.want === true).length > 0), 'Changes says it\'s looking');
await waitFor('document.querySelectorAll(".hchanges .hcrow").length === 3');
ok((await texts('.hchanges .hcrow')).split('|').length === 3, 'every change, one row each');
ok(await ev('document.querySelector(".hchanges .hcrow").textContent.includes("<b>Guitar</b>") && !document.querySelector(".hchanges .hcrow b + span b")'), 'names go in as text, never HTML');
ok(await ev('document.querySelectorAll(".hchanges .hcgone").length') === 1, 'a delete is marked');
ok(await texts('.hchanges .hcfilters select:first-child option') === 'Everyone|Bo|James-Main', 'the people to filter by');
m = mark();
await ev('(() => { const s = document.querySelector(".hchanges .hcfilters select"); s.value = "Bo"; s.dispatchEvent(new Event("change")); })()');
ok(await until(() => sent(m, (a) => a.changes && a.changes.want && a.changes.filter.who === 'Bo').length > 0), 'a filter goes out with "I\'m looking"');
ok(await shown('.hchanges button', 'Clear filters'), 'and Clear filters shows');
await click('.hchanges .hchead', (await texts('.hchanges .hchead')).split('|')[0]);
await sleep(100);
ok(await texts('.hchanges .hcopts button') === 'Go to it|Undo this change|Restore the whole project to here|Restore chosen tracks to here…', 'a change\'s options, Go to it here');
m = mark();
await click('.hchanges .hcopts button', 'Undo this change');
ok(await until(() => sent(m, (a) => a.changes && a.changes.undo === 'e3').length === 1), 'Undo asks Live sync first');
ok(!(await visible('.hcask')), 'no confirm before Live sync answers');
await push({ topics: { hchanges: Object.assign({}, CH, { ask: { id: 'A1', what: 'undo', words: 'Undo Bo’s take. Everything else stays.', n: 1 } }) } });
ok(await visible('.hcask') && (await ev('document.querySelector(".hcask p").textContent')) === 'Undo Bo’s take. Everything else stays.', 'the confirm, with Live sync\'s words, under the row');
ok(sent(m, (a) => a.changes && a.changes.yes).length === 0, 'nothing done yet');
await click('.hcask button', 'Yes, do it');
ok(await until(() => sent(m, (a) => a.changes && a.changes.yes === 'A1' && a.changes.confirm === true).length === 1), 'Yes sends the ask\'s id with confirm');
await push({ topics: { hchanges: CH } });
ok(!(await visible('.hcask')), 'done: the confirm goes');
m = mark();
await click('.hchanges .hcopts button', 'Restore the whole project to here');
ok(await until(() => sent(m, (a) => a.changes && a.changes.restore && a.changes.restore.to === 'e3' && !a.changes.restore.tracks).length === 1), 'Restore the whole project asks');
await push({ topics: { hchanges: Object.assign({}, CH, { ask: { id: 'A2', what: 'whole', words: 'Brings back 1 item.', n: 1 } }) } });
await click('.hcask button', 'Not now');
await sleep(150);
ok(!(await visible('.hcask')) && sent(m, (a) => a.changes && a.changes.yes).length === 0, 'Not now: nothing sent');
await click('.hchanges .hcopts button', 'Restore chosen tracks to here…');
await sleep(100);
ok(await texts('.hchanges .hctracks label') === ' Guitar| Bass', 'the tracks now, to tick');
await click('.hchanges .hctracks button', 'Check what changes');
await sleep(100);
ok((await ev('document.querySelector(".hchanges .hcsaid").textContent')).includes('Tick the tracks'), 'none ticked: said');
m = mark();
await ev('document.querySelector(".hchanges .hctracks input").click(); 1');
await click('.hchanges .hctracks button', 'Check what changes');
ok(await until(() => sent(m, (a) => a.changes && a.changes.restore && JSON.stringify(a.changes.restore.tracks) === '["T-A"]' && a.changes.restore.to === 'e3').length === 1), 'chosen tracks: their ids go with the ask');
await push({ topics: { hchanges: Object.assign({}, CH, { driver: false }) } });
ok(await disabled('.hchanges .hcopts button', 'Restore the whole project to here'), 'not in control: no whole-project restore');
await click('.hchanges .hchead', (await texts('.hchanges .hchead')).split('|')[2]);
await sleep(100);
ok(await disabled('.hchanges .hcopts button', 'Undo this change'), 'a note: no Undo of its own');

// ---- this computer: Versions ---------------------------------------------------------------------------------------------------------------
await push({ topics: { hchanges: CH } });
await ev('location.hash = "#history/versions"; 1');
await sleep(300);
ok(await route() === 'history/versions' && await visible('.hversions'), 'Versions');
ok(await shown('.hversions button', 'Open it as it was before StudioSync'), 'Open it as it was before StudioSync, on this computer');
m = mark();
await ev('(() => { const p = document.querySelector(".hversions"); p.querySelector("input[type=text]").value = "chorus"; p.querySelector("input[type=checkbox]").checked = true; })()');
await click('.hversions button', 'Save this version');
ok(await until(() => sent(m, (a) => a.changes && a.changes.save && a.changes.save.label === 'chorus' && a.changes.save.keep === true).length === 1), 'Save this version, permanently');
await click('.hversions button', 'Open it as it was before StudioSync');
ok(await until(() => sent(m, (a) => a.changes && a.changes.before === true).length === 1), 'Open it as it was before StudioSync');
ok((await texts('.hversions .hclist .hchead')).includes('before solo (kept)'), 'saved versions listed');
await click('.hversions .hchead', (await texts('.hversions .hclist .hchead')).split('|')[0]);
await sleep(100);
m = mark();
await click('.hversions .hcopts button', 'Restore the whole project to here');
ok(await until(() => sent(m, (a) => a.changes && a.changes.restore && a.changes.restore.file === 'v1.json').length === 1), 'a saved version: Restore asks');
await click('.hversions .hclist .hchead', (await texts('.hversions .hclist .hchead')).split('|')[1]);
await sleep(100);
ok(await disabled('.hversions .hcopts button', 'Restore chosen tracks to here…'), 'one older than History: no restore');
m = mark();
await click('.hckept button', 'Put mine back');
await click('.hckept button', 'Let it go');
ok(await until(() => sent(m, (a) => a.changes && a.changes.putback === 'k1.json').length === 1 && sent(m, (a) => a.changes && a.changes.letgo === 'k1.json').length === 1), 'kept automation: Put mine back; Let it go asks');

// ---- this computer: Mixes -----------------------------------------------------------------------------------------------------------------
m = mark();
await ev('location.hash = "#history/mixes"; 1');
await sleep(300);
ok(await route() === 'history/mixes' && await until(() => sent(m, (a) => a.mixes && a.mixes.want === true).length > 0), 'Mixes says it\'s looking');
ok(await shown('.hmixes button', 'Render current mix') && await shown('.hmixes button', 'Play A'), 'Render and A/B on this computer');
ok((await texts('.hmixes .hclist .hcrow')).split('|').length === 3, 'every mix and stems folder');
await click('.hmixes button', 'Play B');
ok(await until(() => sent(m, (a) => a.mixes && a.mixes.ab && a.mixes.ab.play === 'b' && a.mixes.ab.a === MIXA && a.mixes.ab.b === MIXB).length === 1), 'A/B: B, the newest, against the one before');
await push({ topics: { hmixes: Object.assign({}, MX, { ab: { a: MIXA, b: MIXB, play: 'b', pos: 61, len: 200, on: true } }) } });
ok(await ev('(() => { const b = [...document.querySelectorAll(".hmixes button")].find((x) => x.textContent === "Play B"); return b.getAttribute("aria-pressed"); })()') === 'true'
  && (await texts('.hmixes .hswhen')) === '1:01 / 3:20', 'what plays, and where');
await click('.hmixes button', 'Render current mix');
await ev('[...document.querySelectorAll(".hmixes label")].find((l) => l.textContent.includes("Time selection")).querySelector("input").click(); 1');
await click('.hmixes button', 'each folder');
await click('.hmixes button', 'Save as studio template');
await sleep(100);
ok((await ev('document.querySelector(".hmixes .hcsaid").textContent')).includes('Give the template a name'), 'a template needs a name');
await ev('document.querySelector(".hmixes input[placeholder=\'template name\']").value = "Kit"; 1');
await click('.hmixes button', 'Save as studio template');
ok(await until(() => sent(m, (a) => a.mixes && a.mixes.render === true).length === 1 && sent(m, (a) => a.mixes && a.mixes.bounce && a.mixes.bounce.what === 'folder' && a.mixes.bounce.sel === true).length === 1
  && sent(m, (a) => a.mixes && a.mixes.template && a.mixes.template.name === 'Kit').length === 1), 'Render, the idle computers (time selection only), a template');

// ---- this computer: Playback through REAPER, Open this point ---------------------------------------------------------------------------------
await ev('location.hash = "#history/playback"; 1');
await sleep(500);
ok(await route() === 'history/playback', 'Playback');
ok(await ev('(() => { const l = [...document.querySelectorAll(".hhopt")].find((x) => x.textContent.includes("Play through REAPER")); return !!l && !l.hidden && l.querySelector("input").checked; })()'), 'Play through REAPER: shown with SWS, on by default');
ok(!(await visible('.hhplayer audio')) && await visible('.hhrp'), 'its own player instead of this window\'s');
m = mark();
await click('.hhrp button', 'Play');
ok(await until(() => sent(m, (a) => a.rplay && a.rplay.slot === 'then' && a.rplay.pos === 0).length === 1), 'Play goes to REAPER');
await push({ topics: { hhear: Object.assign({}, HH, { rp: { key: 'then', pos: 12.3, len: 90, on: true } }) } });
ok((await texts('.hhrp button')) === 'Pause' && (await texts('.hhrp .hhstate')) === '0:12 / 1:30', 'REAPER playing: Pause, and where it is');
await click('.hhopts button', 'Open this point in REAPER');
ok(await until(() => sent(m, (a) => a.open && a.open.t === T0 + 150).length === 1), 'Open this point in REAPER');
await ev('[...document.querySelectorAll(".hhopt")].find((x) => x.textContent.includes("Play through REAPER")).querySelector("input").click(); 1');
await sleep(150);
ok(await until(() => sent(m, (a) => a.rstop === true).length === 1) && await visible('.hhplayer audio') && !(await visible('.hhrp')), 'switched off: REAPER stops, this window\'s player back');

// ---- another device, wide: nothing that opens or plays in REAPER --------------------------------------------------------------------------------
state = WITH();
await open(REMOTE + '#history/changes');
ok(await route() === 'history/changes', 'another device: History > Changes');
await click('.hchanges .hchead', (await texts('.hchanges .hchead')).split('|')[0]);
await sleep(100);
ok(await texts('.hchanges .hcopts button') === 'Undo this change|Restore the whole project to here|Restore chosen tracks to here…', 'no Go to it');
await ev('location.hash = "#history/versions"; 1');
await sleep(300);
ok(!(await shown('.hversions button', 'Open it as it was before StudioSync')), 'no Open it as it was before StudioSync');
await ev('location.hash = "#history/mixes"; 1');
await sleep(300);
ok(!(await shown('.hmixes button', 'Render current mix')) && !(await shown('.hmixes button', 'Play A')) && !(await shown('.hmixes button', 'Save a copy outside the studio')), 'no Render, A/B or copy outside');
ok(await shown('.hmixes button', 'Render stems: each track') && await shown('.hmixes button', 'Credits draft'), 'the idle computers and credits stay');
ok(await ev('[...document.querySelectorAll(".hmixes p.dim")].some((p) => p.textContent.includes("compare there"))'), 'A/B: says where');
await ev('location.hash = "#history/playback"; 1');
await sleep(500);
ok(!(await ev('(() => { const l = [...document.querySelectorAll(".hhopt")].find((x) => x.textContent.includes("Play through REAPER")); return !!l && l.getClientRects().length > 0; })()')) && !(await shown('.hhopts button', 'Open this point in REAPER')), 'Playback: no Play through REAPER, no Open in REAPER');

// ---- a phone: restore with the in-page confirm (James, 2026-11-27) --------------------------------------------------------------------------------
state = WITH();
await open(REMOTE + '#history/changes', { phone: true, w: 390, h: 800 });
ok(await route() === 'history/changes', 'a phone: History > Changes');
await click('.hchanges .hchead', (await texts('.hchanges .hchead')).split('|')[0]);
await sleep(100);
m = mark();
await click('.hchanges .hcopts button', 'Undo this change');
await until(() => sent(m, (a) => a.changes && a.changes.undo === 'e3').length === 1);
await push({ topics: { hchanges: Object.assign({}, CH, { ask: { id: 'P1', what: 'undo', words: 'Undo Bo’s take.', n: 1 } }) } });
ok(await visible('.hcask') && sent(m, (a) => a.changes && a.changes.yes).length === 0, 'the confirm on a phone, nothing done yet');
await click('.hcask button', 'Yes, do it');
ok(await until(() => sent(m, (a) => a.changes && a.changes.yes === 'P1' && a.changes.confirm === true).length === 1), 'Yes from a phone: the id and confirm');
ok(await ev('document.documentElement.scrollWidth <= innerWidth + 1'), 'no sideways scroll on a phone');

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
