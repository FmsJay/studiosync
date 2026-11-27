// The Session tab (rt-ui6: docs/rt/ui-web-plan.md Phase 6), driven in headless Chromium against a stand-in server:
//   node tests/rt_ui6_browser.mjs            (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The real lib/webui/index.html with every real page file, served from lib/webui with stand-in topics over /api/events as Live sync publishes
// them (presence, play, session, rooms: lib/websession.lua, lib/webrooms.lua); the actions the page POSTs are recorded. Checks: Who's here
// (roles, the person menu and its in-page confirms, Give them control of, Make admin, hand over), Who can edit (the mode, Take control and
// Take control anyway, Always follow), View only on the page and in the strip, Claims (claim, release yours, Release all asks first), Play
// together's How I hear (Local mixing's named choices) and Live ideas, Rooms (the list only asked for while shown, Go, Create, Archive with a
// confirm, the come-and-see asks on Who's here, a side room's Bring into), another device's menu (no roles, no removing). Nothing reaches REAPER
// or the network: its own Chrome profile in a temp folder, a random localhost port ("studio.test" mapped to it), no devices. (The harness is
// tests/rt_ui1_browser.mjs's.)
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
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui6-chrome-'));
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
  for (let t = 0; t < 8000; t += 100) { await sleep(100); try { if (await ev('location.href === ' + JSON.stringify(url) + ' && !!(window.ssTabs && (ssTabs.route() || ssEnv.pop)) && document.readyState === "complete"')) break; } catch (e) {} }
  await sleep(400);
}
const tabsShown = () => ev('[...document.querySelectorAll("#sstabs .tab:not(.ssmore)")].filter((b) => !b.hidden).map((b) => b.textContent).join(",")');
const route = () => ev('ssTabs.route()');
const visible = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return !!e && e.getClientRects().length > 0; })()');
const text = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return e ? e.textContent : null; })()');
const click = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); if (e) e.click(); return !!e; })()');
const until = async (f, ms = 20000) => { for (let t = 0; t < ms && !f(); t += 50) await sleep(50); return f(); }; // (a POST lands when it lands)
const last = (pred) => actions.filter(pred).pop();

const sess = (o) => last((a) => a.topic === 'session' && (!o || Object.keys(o).every((k) => JSON.stringify(a[k]) === JSON.stringify(o[k]))));
const menuItems = () => ev('[...document.querySelectorAll(".pmenu button")].map((b) => b.textContent + (b.disabled ? " (off)" : "")).join("|")');
const menuClick = (label) => ev('(() => { const b = [...document.querySelectorAll(".pmenu button")].find((x) => x.textContent.startsWith(' + JSON.stringify(label) + ')); if (b) b.click(); return !!b; })()');
const openMenu = (who) => ev('(() => { const li = [...document.querySelectorAll("#people li")].find((l) => l.dataset.avUser === ' + JSON.stringify(who) + '); li.querySelector(".pmenu-b").click(); return 1; })()');
const roomLi = (name) => '[...document.querySelectorAll(".prooms li")].find((l) => l.querySelector(".name") && l.querySelector(".name").textContent === ' + JSON.stringify(name) + ')';

const PRESENCE = { song: 'Cross Test', room: 'main', driver: 'Bo', mode: 'driver', people: [
  { user: 'James-Main', me: true, armed: [] }, { user: 'Bo', armed: ['Bass'], playing: true }, { user: 'Cy', armed: [] }],
  claims: [{ user: 'James-Main', kind: 'track', name: 'Keys' }, { user: 'Bo', kind: 'track', name: 'Bass' }], granted: [] };
const MODES = [{ id: 'open', name: 'Claims', tip: 'a' }, { id: 'everyone', name: 'Open', tip: 'b' }, { id: 'driver', name: 'Driver only', tip: 'c' }, { id: 'admins', name: 'Admins only', tip: 'd' }];
const SESSION = { me: 'James-Main', role: 'owner', mode: 'driver', modes: MODES, may_set: true, driver: 'Bo', take: 'only your changes reach everyone', viewonly: 'driver',
  claims: [{ kind: 'tracks', name: 'Keys' }], sel: { tracks: ['Keys', 'Pad'], regions: [], time: { from: 2, to: 6 } },
  people: { Bo: { role: 'admin', key: 'Bo', can: { admin: 'member', owner: true, give: true, remove: true } }, Cy: { role: 'member', key: 'Cy', can: { admin: 'admin', owner: true, give: true, remove: true } } },
  ideas: [{ who: 'Bo', n: 2 }], localmix: true };
const ROOMS = { room: 'main', invites: [{ from: 'Bo', room: 'chorus', time: 't1' }] };
const ROOMSFULL = Object.assign({}, ROOMS, { rooms: [
  { name: 'main', here: true, main: true, came: 'main room', people: [{ user: 'James-Main', me: true, here: true }, { user: 'Bo', here: true }] },
  { name: 'chorus', came: 'side room of main', people: [] }, { name: 'alt', came: 'fork of main', people: [{ user: 'Cy' }] }], archived: [{ name: 'old', by: 'Bo' }] });
const STATE = { engine: true, topics: { env: { v: 1, studio: 'Chilio', computer: 'James-Main', user: 'James-Main', front: { name: 'Cross Test.rpp', project: 'Cross Test', room: 'main', live: true, shared: true } },
  presence: PRESENCE, session: SESSION, rooms: ROOMS, profiles: { me: 'James-Main', people: {} } } };

// ---- this computer: Who's here ------------------------------------------------------------------------------------------------------------
state = JSON.parse(JSON.stringify(STATE));
await open(LOCAL + '#session/here');
ok(await route() === 'session/here', 'Session > Who\'s here');
ok(await ev('document.querySelectorAll("#people li .pmenu-b").length') === 3, 'everyone has a ⋯ menu');
ok((await ev('[...document.querySelectorAll("#people li")].find((l) => l.dataset.avUser === "Bo").textContent')).includes('admin'), 'roles show beside names');
ok((await text('.pviewonly')).startsWith('View only: Bo is in control'), 'View only: Bo is in control (Driver only, not you)');
ok((await ev('ssShell.words().words')).includes('View only: Bo is in control'), 'and in the strip (decision 6)');
// Who can edit
ok(await ev('[...document.querySelectorAll(".pwce select option")].map((o) => o.textContent).join(",")') === 'Claims,Open,Driver only,Admins only' && await ev('document.querySelector(".pwce select").value') === 'driver', 'the four modes, Driver only picked');
await ev('(() => { const s = document.querySelector(".pwce select"); s.value = "open"; s.dispatchEvent(new Event("change")); return 1; })()');
ok(await until(() => !!sess({ mode: 'open' })), 'a mode picked is sent');
ok((await text('.pwce .pnote')) === 'Bo is in control.', 'who is in control');
await ev('[...document.querySelectorAll(".pwce button")].find((b) => b.textContent === "Take control").click(), 1');
ok(await until(() => !!sess({ take: true })), 'Take control is sent');
await push({ topics: { session: Object.assign({}, SESSION, { said: { text: 'not everyone is in sync yet: Bo hasn\'t got every take yet', take: true, n: 1 } }) } });
ok(await ev('[...document.querySelectorAll(".pwce button")].some((b) => b.textContent === "Take control anyway" && !b.hidden)') && (await text('#here .psaid')).includes('not everyone is in sync'), 'not in sync: said, with Take control anyway');
await ev('[...document.querySelectorAll(".pwce button")].find((b) => b.textContent === "Take control anyway").click(), 1');
ok(await until(() => !!sess({ take: true, anyway: true })), 'Take control anyway');
await ev('document.querySelector(".pwce input[type=checkbox]").click(), 1');
ok(await until(() => !!sess({ followdriver: true })), 'Always follow whoever is in control');
// the person menu
await openMenu('Cy');
ok(await visible('.pmenu'), 'the ⋯ menu opens');
const items = await menuItems();
ok(items.includes('Follow Cy') && items.includes('Selected tracks: Keys, Pad') && items.includes('Selected region (click one in the ruler) (off)') && items.includes('Time selection: 0:02 to 0:06')
  && items.includes('Make admin…') && items.includes('Make owner…') && items.includes('Remove from the studio…') && !items.includes('Hand over'), 'what you may do about Cy (' + items + ')');
await menuClick('Make admin');
ok((await text('.pmenu p')).startsWith('Make Cy an admin?'), 'asks first, in the page');
await menuClick('Make admin');
ok(await until(() => !!sess({ admin: { user: 'Cy', on: true } })) && !(await visible('.pmenu')), 'Make admin sent, the menu closed');
await openMenu('Cy');
await menuClick('Selected tracks');
await menuClick('Give');
ok(await until(() => !!sess({ give: { user: 'Cy', what: 'tracks' } })), 'Give them control of the selected tracks');
await openMenu('Bo');
ok((await menuItems()).includes('Make member…'), 'an admin can be made a member again');
await menuClick('Follow Bo');
ok(await until(() => { const a = last((x) => x.topic === 'play' && 'choice' in x); return a && a.choice === 'Bo'; }), 'Follow from the menu: the one Follow');
await push({ topics: { session: Object.assign({}, SESSION, { driver: 'James-Main', driving: true, viewonly: null, people: Object.assign({}, SESSION.people, { Cy: { role: 'member', key: 'Cy', can: { handover: true } } }) }) } });
ok((await text('.pviewonly')) === '' && !(await ev('ssShell.words().words')).includes('View only'), 'in control: no View only');
await openMenu('Cy');
ok((await menuItems()) === 'Follow Cy|Hand over control…', 'only hand over and Follow when that\'s all (' + await menuItems() + ')');
await menuClick('Hand over');
await menuClick('Hand over');
ok(await until(() => !!sess({ handover: 'Cy' })), 'hand over, asked first');
await openMenu('James-Main');
ok((await menuItems()) === 'Change my name, colour…', 'your own menu: your name');
await ev('document.body.click(), 1');
ok(!(await visible('.pmenu')), 'a click elsewhere closes it');
// Claims
await push({ topics: { session: SESSION } });
await ev('document.querySelector("#claims .prel").click(), 1');
ok(await until(() => !!sess({ release: { kind: 'tracks', name: 'Keys' } })), 'Release on your own claim');
ok(await ev('document.querySelectorAll("#claims .prel").length') === 1, 'only yours have it');
ok((await text('.pclaim button')) === 'Claim selected tracks (2)', 'how many are selected');
await ev('document.querySelector(".pclaim button").click(), 1');
ok(await until(() => !!sess({ claim: 'tracks' })), 'Claim selected tracks');
ok(await ev('document.querySelectorAll(".pclaim button")[1].disabled'), 'no region selected: greyed');
await ev('[...document.querySelectorAll(".pclaim button")].find((b) => b.textContent.startsWith("Release all")).click(), 1');
ok(!sess({ release: 'all' }) && (await ev('[...document.querySelectorAll(".pclaim button")].some((b) => b.textContent === "Release all: sure?")')), 'Release all asks first');
await ev('[...document.querySelectorAll(".pclaim button")].find((b) => b.textContent.startsWith("Release all")).click(), 1');
ok(await until(() => !!sess({ release: 'all' })), 'then releases');
await push({ topics: { session: Object.assign({}, SESSION, { locked: true, mode: 'admins', viewonly: 'admins' }) } });
ok(!(await visible('.pclaim button')) && (await text('.pclaim .dim')).startsWith('Admins only here'), 'Admins only, a member: no Claim buttons, said why');
ok((await ev('ssShell.words().words')).includes('View only: admins only here'), 'the strip: admins only');
await push({ topics: { session: SESSION } });
// the come-and-see ask on Who's here
ok((await text('#here .pinvite')).startsWith('Bo asks you to come and see ‘chorus’'), 'Bo\'s come-and-see ask on Who\'s here');
await ev('document.querySelector("#here .pinvite .pgo").click(), 1');
ok(await until(() => { const a = sess(); return a && a.rooms && a.rooms.go === 'chorus'; }) && !(await visible('#here .pinvite')), 'Go: to the room, and the ask goes');

// ---- Play together: How I hear, Live ideas --------------------------------------------------------------------------------------------------
await ev('ssTabs.go("session/play"); 1');
await sleep(150);
const lmBox = '[...document.querySelectorAll(".play label")].find((l) => l.textContent.includes("Local mixing")).querySelector("input")';
ok(!(await visible('.play .plmask')) && await ev(lmBox + '.checked'), 'Local mixing on');
await ev(lmBox + '.click(), 1');
ok(await visible('.play .plmask') && !sess({ localmix: false }), 'off asks whose mix first');
await ev('[...document.querySelectorAll(".play .plmask button")].find((b) => b.textContent === "Use the studio’s mix").click(), 1');
ok(await until(() => !!sess({ localmix: false, keep: 'theirs' })), 'the studio\'s mix');
ok((await text('.play .pideas li')).startsWith('Bo: 2'), 'Live ideas: Bo\'s two');
await ev('document.querySelector(".play .pideas li button").click(), 1');
ok(await until(() => !!sess({ ideas: 'dismiss', who: 'Bo' })), 'dismiss Bo\'s');

// ---- Rooms ----------------------------------------------------------------------------------------------------------------------------------
actions.length = 0;
await ev('ssTabs.go("session/rooms"); 1');
ok(await until(() => { const a = sess(); return a && a.rooms && a.rooms.want; }), 'Rooms asks for its list while shown');
await push({ topics: { rooms: ROOMSFULL } });
ok(await ev('[...document.querySelectorAll(".prooms > .pwho:not(.pinvites) > li .name")].map((e) => e.textContent).join(",")') === 'main,chorus,alt', 'the rooms, main first');
ok((await text('.prooms details summary')) === 'Archived rooms (1)', 'archived folded');
await ev(roomLi('chorus') + '.querySelector(".pgo").click(), 1');
ok(await until(() => { const a = sess(); return a && a.rooms && a.rooms.go === 'chorus'; }), 'Go');
ok(await ev('[...' + roomLi('alt') + '.querySelectorAll("button")].find((b) => b.textContent === "Archive").disabled'), 'Archive greyed while someone has it open');
await ev('[...' + roomLi('chorus') + '.querySelectorAll("button")].find((b) => b.textContent === "Archive").click(), 1');
ok(await visible('.prooms .pask') && !(sess() || {}).rooms.archive, 'Archive asks first');
await ev('document.querySelector(".prooms .pask .pgo").click(), 1');
ok(await until(() => { const a = sess(); return a && a.rooms && a.rooms.archive === 'chorus'; }), 'archived');
await ev('(() => { [...document.querySelectorAll(".prooms button")].find((b) => b.textContent === "Create a room").click(); const f = document.querySelector(".prooms form"); f.querySelector("input").value = "bridge"; f.requestSubmit(); return 1; })()');
ok(await until(() => { const a = sess(); return a && a.rooms && a.rooms.create === 'bridge' && a.rooms.fork === false; }), 'Create a room');
await ev('[...document.querySelectorAll(".prooms button")].find((b) => b.textContent === "Come see!").click(), 1');
ok(await until(() => { const a = sess(); return a && a.rooms && a.rooms.comesee; }), 'Come see!');
// a side room: the way back
await push({ topics: { rooms: Object.assign({}, ROOMSFULL, { room: 'chorus', parent: 'main', parent_driver: 'Bo', merge: { bring: 2, clash: 1, tracks: [{ name: 'Keys', fork: 2, theirs: 0, both: 1 }] } }) } });
ok((await text('.prooms h2')) === 'Back to main', 'a side room: back to main');
ok(await ev('[...document.querySelectorAll(".prooms button")].find((b) => b.textContent === "Bring into main").disabled'), 'Bring into greyed: Bo is in control of main');
await push({ topics: { rooms: Object.assign({}, ROOMSFULL, { room: 'chorus', parent: 'main', parent_driver: 'James-Main', may_bring: true, merge: { bring: 2, clash: 0, tracks: [] } }) } });
await ev('[...document.querySelectorAll(".prooms button")].find((b) => b.textContent === "Bring into main").click(), 1');
await ev('document.querySelector(".prooms .pask .pgo").click(), 1');
ok(await until(() => { const a = sess(); return a && a.rooms && a.rooms.bring; }), 'Bring into main, asked first');

// ---- another device: no roles, no removing ---------------------------------------------------------------------------------------------------
state = JSON.parse(JSON.stringify(STATE));
await open(REMOTE + '#session/here');
ok(await ev('ssEnv.where') === 'remote', 'another device');
await openMenu('Cy');
const ri = await menuItems();
ok(ri.includes('Follow Cy') && ri.includes('Selected tracks') && !ri.includes('Make admin') && !ri.includes('Make owner') && !ri.includes('Remove'), 'no roles or removing from another device (' + ri + ')');

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
