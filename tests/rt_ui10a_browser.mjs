// Plug-ins in the web UI (rt-ui10a: docs/rt/ui-web-plan.md Phase 10a), driven in headless Chromium against a stand-in server:
//   node tests/rt_ui10a_browser.mjs          (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The real lib/webui/index.html with every real page file (the harness of tests/rt_ui1_browser.mjs), stand-in "plugins" topics as
// lib/webplugins.lua builds them; actions the page POSTs are recorded. In REAPER (a stand-in WebView2 channel): This project (rows, who lacks
// each, stand-ins, the picker, Remove's in-page ask, drum maps, Make a map, the folder), Find a plug-in (categories, Only, Add), Plug-in pack
// (Get); a new Try ask brings the window back from the strip; ?pop=plugins keeps its sub-tabs; another device sees it all read only. Nothing
// reaches REAPER or the network: its own Chrome profile in a temp folder, a random localhost port ("studio.test" mapped to it), no devices.
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
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui10a-chrome-'));
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
const until = async (f, ms = 2000) => { for (let t = 0; t < ms && !f(); t += 50) await sleep(50); return f(); }; // (a POST lands when it lands)
const PROJECT = { engine: true, topics: { env: { v: 1, studio: 'Chilio', front: { name: 'Cross Test.rpp', project: 'Cross Test', room: 'main', live: true, shared: true } },
  presence: { song: 'Cross Test', room: 'main', driver: 'James-Main', people: [{ user: 'James-Main', me: true, armed: [] }], claims: [] } } };
const NOPROJECT = { engine: false, topics: { env: { v: 1 }, presence: null } };

// ---- the plugins topic, as lib/webplugins.lua builds it ---------------------------------------------------------------------------------------
const SAID = (text) => ({ text, at: now() });
const MODEL = () => ({
  project: [
    { key: 'superior drummer 3 (toontrack)', name: 'Superior Drummer 3 (Toontrack)', tracks: ['Drums'], missing: [] },
    { key: 'serum (xfer records)', name: 'Serum (Xfer Records)', tracks: ['Bass', 'Lead'], missing: ['James-Main'], standin: { to: 'Surge XT (Surge Synth Team)', by: 'Bo' } },
    { key: 'kontakt 7 (native instruments)', name: 'Kontakt 7 (Native Instruments)', tracks: ['Keys'], missing: ['Bo'] },
    { key: 'utility/volume', name: 'Utility/volume', tracks: ['Master'], missing: ['Bo'], js: true },
  ],
  people: ['Bo', 'James-Main'],
  drums: { n: 1, track: 'Drums', from: 'gm', to: 'Superior', moved: 4, maps: ['gm', 'Superior'], kit: [{ id: 'kick', label: 'Kick', gm: 36 }, { id: 'snare', label: 'Snare', gm: 38 }] },
  folder: 'StudioSync (everyone has)',
  find: { q: '', cat: 'All', only: true, target: 'Bass', cats: ['All', 'Instruments', 'EQ'], shown: 2,
    rows: [{ key: 'reaeq (cockos)', label: 'ReaEQ (Cockos)', cats: 'EQ', everyone: true }, { key: 'utility/volume', label: 'Utility/volume', cats: 'JSFX', everyone: true }] },
  pack: { pack: { have: 10, total: 11, missing: ['Dexed'] }, extras: { have: 8, total: 8, missing: [] }, others: [{ name: 'Dexed', who: ['Bo'] }],
    items: [{ name: 'Surge XT', what: 'synth and effects', here: true }, { name: 'Dexed', what: 'FM synth' }, { name: 'Odin 2', what: 'synth', extras: true, here: true }] },
  os: 'win',
});
const WITH = (o) => ({ engine: true, topics: Object.assign({}, PROJECT.topics, { plugins: Object.assign(MODEL(), o || {}) }) });
const sent = (f) => actions.filter((a) => a.topic === 'plugins' && f(a));
const vis = (sel) => ev('[...document.querySelectorAll(' + JSON.stringify(sel) + ')].filter((e) => e.getClientRects().length > 0).length');
const text = (sel) => ev('(() => { const e = [...document.querySelectorAll(' + JSON.stringify(sel) + ')].find((x) => x.getClientRects().length > 0); return e ? e.textContent : null; })()');
const click = (sel, label) => ev('(() => { const b = [...document.querySelectorAll(' + JSON.stringify(sel) + ')].find((x) => x.getClientRects().length > 0' +
  (label ? ' && x.textContent === ' + JSON.stringify(label) : '') + '); if (!b) return false; b.click(); return true; })()');

// ---- in REAPER (this computer): This project ------------------------------------------------------------------------------------------------
state = WITH();
await open(LOCAL + '?host=docked#plugins/project', { reaper: true });
ok(await route() === 'plugins/project', 'Plug-ins > This project opens');
ok(await okSubs('plugins') === 'project,try,find,pack', 'in REAPER: all four Plug-ins sub-tabs (' + await okSubs('plugins') + ')');
{
  const L = await list(), subs = L.find((t) => t.name === 'plugins').subs;
  ok(subs.every((s) => !s.coming) && subs.map((s) => s.label).join(',') === 'This project,Try a bandmate’s,Find a plug-in,Plug-in pack', 'no "coming" page left: ' + subs.map((s) => s.label).join(','));
}
ok(await until(() => sent((a) => a.want).length > 0), 'the page says it shows (want)');
ok(await vis('.tfrows .tfrow') === 4, 'every plug-in of the project is a row');
ok((await text('.tfrows .tfrow:nth-child(2) .tfwarn')) === 'Missing for James-Main' && (await text('.tfrows .tfrow:nth-child(2) .tfstand')) === 'Stand-in: Surge XT (Surge Synth Team) (set by Bo)', 'who lacks it, its stand-in and who set it');
ok((await text('.tfrows .tfrow:nth-child(4) .tfinfo')).includes('everyone has it (JSFX)'), 'a JSFX: everyone has it');
ok(await vis('.tfapply') === 1, 'Apply stand-ins here (a stand-in exists for something someone lacks)');
await click('.tfapply');
ok(await until(() => sent((a) => a.apply).length === 1), 'Apply stand-ins here sends {apply}');
// the stand-in picker
await click('.tfrow:nth-child(3) .tfset', 'Set a stand-in');
ok(await vis('.tfpicker') === 1 && await until(() => sent((a) => a.pick === '').length === 1), 'Set a stand-in opens the picker and asks for the list');
ok((await text('.tfpicker .tfnote')).includes('Kontakt 7'), 'the picker names the plug-in');
await push({ topics: { plugins: Object.assign(MODEL(), { pick: { q: '', names: ['VST3: Surge XT (Surge Synth Team)', 'VST3: ReaEQ (Cockos)'], total: 140 } }) } });
ok(await vis('.tfpicks .tfitem') === 2 && (await text('.tfpicker .tfnote.dim')).includes('2 of 140'), 'the picker lists this computer’s plug-ins, and says when there are more');
await ev('(() => { const i = document.querySelector(".tfpicker .tfsearch"); i.value = "surge"; i.dispatchEvent(new Event("input")); })()');
ok(await until(() => sent((a) => a.pick === 'surge').length === 1, 1500), 'typing searches (debounced)');
await click('.tfpicks button', 'Use it');
ok(await until(() => sent((a) => a.standin && a.standin.key === 'kontakt 7 (native instruments)' && a.standin.to === 'VST3: Surge XT (Surge Synth Team)').length === 1), 'Use it sends {standin: {key, to}}');
ok(await vis('.tfpicker') === 0, 'and the picker closes');
// Remove asks once in the page
await click('.tfrow:nth-child(2) .tfrm', 'Remove');
ok((await text('.tfrow:nth-child(2) .tfrm')) === 'Remove it? Yes' && sent((a) => a.unstandin).length === 0, 'Remove asks first (in the page), nothing sent');
await click('.tfrow:nth-child(2) .tfrm', 'Remove it? Yes');
ok(await until(() => sent((a) => a.unstandin === 'serum (xfer records)').length === 1), 'the second press removes it');
// drum maps
ok((await text('.tfp .tfnote:not(.dim)')) !== null && await ev('document.querySelector(".tfdfrom").value') === 'gm' && await ev('document.querySelector(".tfdto").value') === 'Superior', 'drum maps: the selected track’s choices');
ok(await ev('[...document.querySelector(".tfdfrom").options].map((o) => o.textContent).join(",")') === 'not set,General MIDI,Superior', 'the maps, General MIDI named');
await ev('(() => { const s = document.querySelector(".tfdto"); s.value = ""; s.dispatchEvent(new Event("change")); })()');
ok(await until(() => sent((a) => a.drum && a.drum.to === '').length === 1), 'a choice sends {drum: {to}}');
ok((await text('.tfp .dim.tfnote')) !== null && (await ev('document.body.textContent')).includes('On: 4 notes moved, here only.'), 'how many notes move');
await ev('document.querySelector(".tfmake").open = true; 1');
await ev('(() => { const i = document.querySelector(".tfmake .tfsearch"); i.value = "My Kit"; const n = document.querySelector(".tfkit input"); n.value = "24"; })()');
await click('.tfsave');
ok(await until(() => sent((a) => a.map && a.map.name === 'My Kit' && a.map.notes.kick === 24 && a.map.notes.snare === 38).length === 1), 'Make a map: Save sends the name and every note');
await click('.tffolder');
ok(await until(() => sent((a) => a.folder).length === 1), 'Update the folder now');
await push({ topics: { plugins: Object.assign(MODEL(), { folder_info: '42 plug-ins everyone has (lists from Bo, James-Main).', said: SAID('42 plug-ins everyone has') }) } });
ok((await ev('document.body.textContent')).includes('42 plug-ins everyone has (lists from Bo') && (await text('.tfsaid')) === '42 plug-ins everyone has', 'what it did is said');

// ---- Find a plug-in ---------------------------------------------------------------------------------------------------------------------------
await ev('ssTabs.go("plugins/find"); 1');
await sleep(150);
ok(await route() === 'plugins/find' && await vis('.tffound .tfitem') === 2, 'Find: its rows');
ok(await ev('[...document.querySelector(".tfcat").options].map((o) => o.value).join(",")') === 'All,Instruments,EQ' && await ev('document.querySelector(".tfonly").checked'), 'REAPER’s categories, Only what everyone has');
await ev('(() => { const i = document.querySelector(".tffq"); i.value = "eq"; i.dispatchEvent(new Event("input")); })()');
ok(await until(() => sent((a) => a.find && a.find.q === 'eq' && a.find.cat === 'All' && a.find.only === true).length === 1, 1500), 'searching sends {find}');
await click('.tffound .tfadd');
ok(await until(() => sent((a) => a.add === 'reaeq (cockos)').length === 1), 'Add sends {add: key}');
await push({ topics: { plugins: Object.assign(MODEL(), { find: Object.assign(MODEL().find, { target: null }) }) } });
ok(await ev('[...document.querySelectorAll(".tffound .tfadd")].every((b) => b.disabled)') && (await ev('document.body.textContent')).includes('Select a track in REAPER first'), 'no track selected: Add is off, and says why');
await push({ topics: { plugins: Object.assign(MODEL(), { find: Object.assign(MODEL().find, { only: false, master: true, target: 'Master', shown: 450 }) }) } });
ok((await ev('document.body.textContent')).includes('The master is never printed') && (await ev('document.body.textContent')).includes('450 shown (the first 2 listed'), 'the master named, and more than are listed');

// ---- Plug-in pack -------------------------------------------------------------------------------------------------------------------------
await ev('ssTabs.go("plugins/pack"); 1');
await sleep(150);
ok((await ev('document.querySelector(".tfpackrows").textContent')).includes('Plug-in pack: 10 of 11 here') && (await ev('document.querySelector(".tfpackrows").textContent')).includes('Extras: 8 of 8 here'), 'the pack’s counts');
ok(await vis('.tfget') === 2, 'Get the pack, and the extras (the pack isn’t all here)');
await click('.tfget', 'Get the pack');
ok(await until(() => sent((a) => a.get === 'pack').length === 1), 'Get the pack sends {get}');
ok((await text('.tfp .tfwarn')).includes('Dexed (Bo)'), 'what others have that this computer doesn’t');
ok(await ev('document.querySelectorAll(".tfpack .tfitem").length') === 3, 'What’s in them');

// ---- the Try notification: a new ask brings the window back from the strip -------------------------------------------------------------------
await open(LOCAL + '?host=docked&win=strip', { reaper: true });
ok(await ev('document.body.dataset.win') === 'strip', 'shrunk to the strip');
await push({ topics: { tryask: { asks: [{ token: 7, user: 'Bo', key: 'serum (xfer records)' }] } } });
ok(await ev('window.__sent.includes("win:full")') && await ev('!document.body.dataset.win'), 'an ask for your plug-in opens the window (win:full)');
ok(await vis('.tftoast .tfask') === 1, 'and its toast shows');
await ev('window.__sent.length = 0; 1');
await ev('ssShell.setWin("strip"); 1');
await push({ topics: { tryask: { asks: [{ token: 7, user: 'Bo', key: 'serum (xfer records)' }], n: 1 } } });
ok(!(await ev('window.__sent.includes("win:full")')), 'the same ask again: no second wake');
await push({ topics: { tryask: { asks: [] } } });

// ---- pop out the whole tab ----------------------------------------------------------------------------------------------------------------
state = WITH();
await open(LOCAL + '?pop=plugins');
ok(await ev('document.body.classList.contains("sspop")') && await route() === 'plugins/project', '?pop=plugins: Plug-ins alone, This project first');
ok(await vis('.sstab[data-tab="plugins"] > .sssubs') === 1 && await vis('#sstabs') === 0, 'its sub-tabs still there, no tab row');
await click('.sstab[data-tab="plugins"] > .sssubs button', 'Find a plug-in');
ok(await route() === 'plugins/find', 'and they switch inside the pop-out');
await open(LOCAL + '#plugins/project');
ok(await ev('ssTabs.canPop("plugins/project") && ssTabs.canPop("plugins/find") && ssTabs.canPop("plugins/pack") && ssTabs.canPop("plugins/try")'), 'every Plug-ins sub can pop out (the ⋯ menu offers it)');

// ---- another device: read only --------------------------------------------------------------------------------------------------------------
await open(REMOTE + '#plugins/project');
ok(await okSubs('plugins') === 'project,pack', 'another device: This project and the pack only');
ok(await vis('.tfrows .tfrow') === 4 && await vis('.tfro') >= 1 && (await text('.tfro')).includes('Read only here'), 'the rows, read only, saying where it’s done');
ok(await vis('.tfapply') === 0 && await vis('.tfset') === 0 && await vis('.tfrm') === 0 && await vis('.tffolder') === 0 && await vis('.tfmake') === 0, 'no Apply, Set, Remove, folder or Make a map');
ok(await ev('document.querySelector(".tfdfrom").disabled && document.querySelector(".tfdto").disabled'), 'the drum map choices are shown but can’t change');
await ev('ssTabs.go("plugins/pack"); 1');
await sleep(150);
ok(await route() === 'plugins/pack' && await vis('.tfget') === 0 && (await text('.tfro')).includes('installer'), 'the pack: no Get here');

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
