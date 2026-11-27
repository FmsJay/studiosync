// Health and Log, and the AI trim (rt-ui4: docs/rt/ui-web-plan.md Phases 4 and 5), driven in headless Chromium against a stand-in server:
//   node tests/rt_ui4_browser.mjs            (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The harness is tests/rt_ui1_browser.mjs's: the real lib/webui/index.html and every page file, stand-in topics over /api/events, the actions
// the page POSTs recorded. Checks: Health's sub-tabs here and on another device; which rows show with Show hidden and "Show messages about
// other scripts" (red ones always); Hide, Show again, the switch and a row's button send the right action; on another device a button only
// that computer may press is greyed and says where; Log (the log topic, Copy, Log files); Updates; Can't hear? with and without the studio's
// own live audio; Send feedback; the AI page lists what the topic carries. Nothing reaches REAPER or the network: its own Chrome profile in a
// temp folder, a random localhost port ("studio.test" mapped to it), no devices.
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
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui4-chrome-'));
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
const list = () => ev('ssTabs.list()');
const okSubs = async (tab) => (await list()).find((t) => t.name === tab).subs.filter((s) => s.ok).map((s) => s.name).join(',');
const route = () => ev('ssTabs.route()');
const visible = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return !!e && e.getClientRects().length > 0; })()');
const now = () => Math.floor(Date.now() / 1000);
const until = async (f, ms = 2000) => { for (let t = 0; t < ms && !f(); t += 50) await sleep(50); return f(); }; // (a POST lands when it lands)
const PROJECT = { engine: true, topics: { env: { v: 1, studio: 'Chilio', front: { name: 'Cross Test.rpp', project: 'Cross Test', room: 'main', live: true, shared: true } },
  presence: { song: 'Cross Test', room: 'main', driver: 'James-Main', people: [{ user: 'James-Main', me: true, armed: [] }], claims: [] } } };
const NOPROJECT = { engine: false, topics: { env: { v: 1 }, presence: null } };

const sent = (pred) => actions.some(pred);
const clear = () => { actions.length = 0; };
const shownRows = (sel = '.sstab[data-tab="health"] .health:not([hidden]) .hrows') => ev('[...document.querySelectorAll(' + JSON.stringify(sel + ' > li.hrow') + ')].map((l) => l.dataset.id).join(",")');
const click = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); if (!e) return false; e.click(); return true; })()');
const HEALTH = { ver: '0.60.1', ext: '1.0.40', worst: 'red', hidden: 1, other: 0, show_other: true, said_n: 1, said: 'Set up: nothing more to do here, from the web page', rows: [
  { id: 'folder', level: 'red', text: 'Syncthing isn’t running' },
  { id: 'compat red', level: 'red', text: 'X breaks sync', other: true },
  { id: 'conflicts', level: 'yellow', text: '2 files', act: 'Show it', here: true },
  { id: 'skipped', level: 'yellow', text: '1 change', act: 'Try again' },
  { id: 'relay', level: 'yellow', text: 'through a relay', hidden: true },
  { id: 'compat script X', level: 'yellow', text: 'X clashes', other: true },
  { id: 'tailscale stays', level: 'yellow', text: 'signs out', copy: 'tailscale up' },
  { id: 'update 0.61.0', level: 'yellow', text: 'StudioSync 0.61.0 is in use in the studio' },
  { id: 'compat', ok: true, text: 'Other scripts: checks pass', act: 'Check again', other: true },
  { id: 'audio', ok: true, text: 'Audio device is running' } ] };
const ENVC = Object.assign({}, PROJECT.topics.env, { computer: 'James-Main', ai: true });
const q = (s) => JSON.stringify(s);

// ---- this computer: Health's sub-tabs and Checks -------------------------------------------------------------------------------------------
state = { engine: false, topics: {} };
await open(LOCAL + '#health/checks');
await push(PROJECT);
await push({ topics: { env: ENVC, health: HEALTH } });
ok(await route() === 'health/checks', 'the deep link opens Health > Checks');
ok(await okSubs('health') === 'checks,log,updates,hear,feedback', 'this computer: Checks, Log, Updates, Can’t hear?, Send feedback (' + await okSubs('health') + ')');
ok(await until(() => sent((a) => a.topic === 'health' && a.want === true)), 'Health says it shows');
ok(await shownRows() === 'folder,compat red,conflicts,skipped,compat script X,tailscale stays,update 0.61.0,compat,audio', 'the switch on: every row but the hidden one (' + await shownRows() + ')');
ok(await ev('document.querySelector(".hother").checked') && await ev('document.querySelector(".hshowhidden").textContent') === 'Show hidden (1)', 'the switch is on; Show hidden (1)');
ok(await ev('document.querySelector(".sstab[data-tab=health] .psaid").textContent') === HEALTH.said, 'what the last button said');
await click('.hshowhidden');
await sleep(100);
ok((await shownRows()).includes('relay') && await ev('!!document.querySelector("li[data-id=relay] .hunhide")'), 'Show hidden: the hidden row, with Show again');
clear();
await click('li[data-id=relay] .hunhide');
ok(await until(() => sent((a) => a.topic === 'health' && a.show === 'relay')), 'Show again sends show');
await click('.hshowhidden');
await sleep(100);
ok(!(await shownRows()).includes('relay'), 'and Hide them again');
clear();
await click('li[data-id="tailscale stays"] .hhide');
ok(await until(() => sent((a) => a.topic === 'health' && a.hide === 'tailscale stays')), 'Hide on an amber row sends hide');
ok(!(await ev('!!document.querySelector("li[data-id=folder] .hhide")')), 'no Hide on a red row');
await click('li[data-id=conflicts] .hact');
ok(await until(() => sent((a) => a.topic === 'health' && a.act === 'conflicts')), 'a row’s button sends its id');
ok(await ev('!document.querySelector("li[data-id=conflicts] .hact").textContent.includes("(on")'), 'this computer: no “on …” note');
await click('li[data-id=compat] .hact');
ok(await until(() => sent((a) => a.act === 'compat')), 'a fine row’s Check again');
await click('.hsetup');
ok(await until(() => sent((a) => a.act === '@setup')), 'Set up everything I can');
await ev('(() => { const b = document.querySelector(".hother"); b.checked = false; b.dispatchEvent(new Event("change")); })()');
ok(await until(() => sent((a) => a.topic === 'health' && a.other === false)), 'the switch sends other: false');
await push({ topics: { health: Object.assign({}, HEALTH, { show_other: false, other: 2 }) } });
ok(await shownRows() === 'folder,compat red,conflicts,skipped,tailscale stays,update 0.61.0,audio', 'switched off: other scripts’ rows go, the red one stays (' + await shownRows() + ')');
ok(await ev('document.querySelector(".hothercount").textContent') === '(2 hidden)' && !(await ev('document.querySelector(".hother").checked')), 'with their count');
ok(await ev('!!document.querySelector(' + q('li[data-id="tailscale stays"] .hcopyb') + ')'), 'Copy the line');

// ---- Log ---------------------------------------------------------------------------------------------------------------------------------------
clear();
await ev('ssTabs.go("health/log"); 1');
ok(await until(() => sent((a) => a.topic === 'health' && a.log === 'want')), 'the Log says it shows');
await push({ topics: { log: { lines: ['10:01 sent the drums', '10:00 started'], days: 14 } } });
ok(await ev('document.querySelector(".hlog").textContent') === '10:01 sent the drums\n10:00 started', 'the log, newest first');
await click('.hlogfiles');
ok(await until(() => sent((a) => a.topic === 'health' && a.log === 'files')), 'Log files');
await click('.hlogcopy');
await sleep(200);
ok(await ev('document.querySelector(".hlogcopy").textContent') === 'Copied', 'Copy');

// ---- Updates, Can't hear?, Send feedback --------------------------------------------------------------------------------------------------------
await ev('ssTabs.go("health/updates"); 1');
await sleep(150);
ok(await ev('document.querySelector(".hupdates .hvers").textContent') === 'StudioSync 0.60.1 · extension 1.0.40', 'Updates: the versions');
ok(await ev('[...document.querySelectorAll(".hupdates .hrows li")].map((l) => l.dataset.id).join(",")') === 'update 0.61.0', 'and the newer StudioSync in the studio');
clear();
await click('.hupdate'); await click('.hupreaper');
ok(await until(() => sent((a) => a.act === '@update') && sent((a) => a.act === '@update reaper')), 'Update StudioSync, Update REAPER');
await ev('ssTabs.go("health/hear"); 1');
await sleep(150);
const hear = () => ev('[...document.querySelectorAll(".hhearlist li")].map((l) => l.textContent).join(" | ")');
ok((await hear()).includes('SonoBus'), 'Can’t hear?: the SonoBus half without the studio’s own live audio');
await push({ topics: { health: Object.assign({}, HEALTH, { builtin: true }) } });
ok(!(await hear()).includes('SonoBus') && (await hear()).includes('Wired internet'), 'and without it when the studio’s own live audio runs');
await ev('ssTabs.go("health/feedback"); 1');
await sleep(150);
clear();
await click('.hfbsend');
ok((await ev('document.querySelector(".hfbsaid").textContent')).includes('Write a subject') && !sent((a) => a.feedback), 'nothing written: nothing sent');
await ev('document.querySelector(".hfbkind").value = "feature"; document.querySelector(".hfbkind").dispatchEvent(new Event("change")); document.querySelector(".hfbsubject").value = "Pop out"; document.querySelector(".hfbbody").value = "the mixer"; 1');
await click('.hfbsend');
ok(await until(() => sent((a) => a.feedback && a.feedback.kind === 'feature' && a.feedback.subject === 'Pop out' && a.feedback.body === 'the mixer' && a.feedback.log === false)), 'Save it sends the report (a feature: no log by default)');
await push({ topics: { health: Object.assign({}, HEALTH, { builtin: true, said_n: 2, said: 'feedback saved in the studio’s feedback folder, from the web page' }) } });
ok((await ev('document.querySelector(".hfbsaid").textContent')).startsWith('feedback saved') && await ev('document.querySelector(".hfbsubject").value') === '', 'the answer shows, the form empties');

// ---- AI: only what the topic carries (Phase 5) --------------------------------------------------------------------------------------------------
await push({ topics: { ai: { on: true, me: 'James-Main', features: [{ id: 'stems', label: 'Split into stems', input: 'audio', provider: 'tool', where: 'here' },
  { id: 'midi', label: 'Audio to MIDI', input: 'take', provider: 'none', why: 'Basic Pitch isn’t set up' }], asks: [], jobs: [] } } });
await ev('ssTabs.go("ai/ai"); 1');
await sleep(200);
ok(await ev('[...document.querySelectorAll(".aifeats > li strong")].map((s) => s.textContent).join(",")') === 'Split into stems,Audio to MIDI', 'AI: the two tools');
ok(!(await ev('document.querySelector(".aipage").textContent')).includes('chat model'), 'no chat model words on the AI page');

// ---- another device on the tailnet ------------------------------------------------------------------------------------------------------------
state = { engine: true, topics: { env: ENVC, presence: PROJECT.topics.presence, health: HEALTH } };
await open(REMOTE + '#health/checks');
ok(await okSubs('health') === 'checks', 'another device: Checks only (' + await okSubs('health') + ')');
ok(await ev('document.querySelector("li[data-id=conflicts] .hact").disabled') && (await ev('document.querySelector("li[data-id=conflicts] .hact").textContent')).includes('(on James-Main)'),
  'a button only that computer may press: greyed, says where');
ok(!(await ev('document.querySelector("li[data-id=skipped] .hact").disabled')), 'a safe one works from here');
clear();
await click('li[data-id=skipped] .hact');
ok(await until(() => sent((a) => a.act === 'skipped')), 'and sends');
await click('li[data-id=conflicts] .hact');
await sleep(200);
ok(!sent((a) => a.act === 'conflicts'), 'the greyed one sends nothing');
ok(await ev('document.querySelector(".hsetup").disabled'), 'Set up everything I can: only on that computer');

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
