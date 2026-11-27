// StudioSync's own asks on the web view (rt-askweb, docs/rt/rt-askweb.md): the big deletion's ask and the Undo ask, carried in the presence topic's
// asks.local_asks (lib/claimask.lua), shown on Session > Who's here beside the claim asks with their countdown and Yes / No; a page on this computer
// sends { topic: 'claimask', ask, id, yes }, a page on another device (a phone) gets the words and where to answer, no buttons. The real page files
// over a stand-in server, as rt-uifix1's: two pages only (Chrome allows six connections to a host).
//   node tests/rt_askweb_browser.mjs         (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
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
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-askweb-chrome-'));
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
const text = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return e ? e.textContent : null; })()');
const btns = (sel) => ev('[...document.querySelectorAll(' + JSON.stringify(sel + ' button') + ')].map((b) => b.textContent).join(",")');
const last = (f) => { for (let i = actions.length - 1; i >= 0; i--) if (f(actions[i])) return actions[i]; return null; };
const MODES = [{ id: 'open', name: 'Claims', tip: 'a' }, { id: 'everyone', name: 'Open', tip: 'b' }, { id: 'driver', name: 'Driver only', tip: 'c' }, { id: 'admins', name: 'Admins only', tip: 'd' }];
const route = () => ev('ssTabs.route()');
const now = () => Math.floor(Date.now() / 1000);
const until = async (f, ms = 20000) => { for (let t = 0; t < ms && !(await f()); t += 50) await sleep(50); return f(); };
const PRESENCE = (asks) => ({ song: 'Cross Test', room: 'main', driver: 'James-Main', mode: 'open', people: [{ user: 'James-Main', me: true, armed: [] }, { user: 'Bo', armed: [] }],
  claims: [{ user: 'James-Main', kind: 'track', name: 'Keys' }], granted: [], asks });
const SESSION = { me: 'James-Main', role: 'owner', mode: 'open', modes: MODES, may_set: true, driver: 'James-Main', claims: [], sel: { tracks: [], regions: [] }, people: {} };
const topics = (asks) => ({ engine: true, topics: { env: { v: 1, studio: 'Chilio', computer: 'James-Main', user: 'James-Main', front: { name: 'Cross Test.rpp', project: 'Cross Test', room: 'main', live: true, shared: true } },
  presence: PRESENCE(asks), session: SESSION, profiles: { me: 'James-Main', people: {} } } });
const DEL = { kind: 'delete', id: 'big-1', text: 'Delete 2 of the song’s 3 tracks for everyone?', till: now() + 30 };
const UND = { kind: 'undo', id: '77', text: 'Undo: Bo’s Keys? It goes to everyone.', till: now() + 30 };
const ask = (o) => ({ incoming: [], waiting: [], local_asks: o });
const tillOf = () => ev('Number(document.querySelector("#asks li.localask .asktill").textContent.replace(" s", ""))');

// ---- a page on this computer -------------------------------------------------------------------------------------------------------------
state = topics(ask([]));
await open(LOCAL + '#session/here');
ok(await until(async () => (await route()) === 'session/here'), 'Session > Who’s here');
ok(await ev('document.querySelectorAll("#asks li").length') === 0, 'nothing asked: nothing listed');
await push({ topics: { presence: PRESENCE({ incoming: [{ id: 'c1', from: 'Bo', what: 'Pad', till: now() + 30 }], waiting: [], local_asks: [DEL, UND] }) } });
ok(await ev('document.querySelectorAll("#asks li").length') === 3, 'a claim ask and the two local asks are listed together');
ok((await text('#asks li.localask[data-kind=delete]')).startsWith('Delete 2 of the song’s 3 tracks for everyone? ('), 'the delete ask’s words');
ok((await text('#asks li.localask[data-kind=undo]')).startsWith('Undo: Bo’s Keys?'), 'the Undo ask’s words');
ok(await btns('#asks li.localask[data-kind=delete]') === 'Yes,No' && await btns('#asks li.localask[data-kind=undo]') === 'Yes,No', 'each with Yes and No');
ok(await btns('#asks li:not(.localask)') === 'Release,Keep', 'the claim ask keeps its Release / Keep');
const left = await tillOf();
ok(left > 25 && left <= 30, 'the seconds left show: ' + left);
await sleep(2200);
ok(await tillOf() < left, 'and count down on their own');
await ev('document.querySelector("#asks li.localask[data-kind=delete] button").click(); 1');
ok(await until(() => !!last((a) => a.topic === 'claimask' && a.ask === 'delete' && a.id === 'big-1' && a.yes === true)), 'Yes to the deletion is sent with its id');
ok(await ev('[...document.querySelectorAll("#asks li.localask[data-kind=delete] button")].every((b) => b.disabled)'), 'and its buttons rest meanwhile');
await ev('[...document.querySelectorAll("#asks li.localask[data-kind=undo] button")][1].click(); 1');
ok(await until(() => !!last((a) => a.topic === 'claimask' && a.ask === 'undo' && a.id === '77' && a.yes === false)), 'No to Undo is sent');
ok(actions.filter((a) => a.topic === 'claimask').length === 2, 'two answers, nothing else');
// the panel answered first (or the ask ran out): Live sync stops listing it, and this page clears
await push({ topics: { presence: PRESENCE(ask([UND])) } });
ok(await ev('document.querySelectorAll("#asks li.localask").length') === 1 && (await text('#asks li.localask')).startsWith('Undo:'), 'an ask answered elsewhere leaves the list');
await push({ topics: { presence: PRESENCE(ask([])) } });
ok(await ev('document.querySelectorAll("#asks li").length') === 0, 'and the list empties');

// ---- a phone: the words, no buttons --------------------------------------------------------------------------------------------------------
const before = actions.length;
state = topics(ask([DEL, UND]));
await open(REMOTE + '#session/here', { w: 390, h: 800, phone: true });
ok(await until(async () => (await route()) === 'session/here'), 'a phone: Session > Who’s here');
ok(await ev('window.ssEnv.where') === 'remote' && await ev('document.querySelectorAll("#asks li.localask").length') === 2, 'two local asks are listed');
ok((await text('#asks li.localask[data-kind=delete]')).startsWith('Delete 2 of the song’s 3 tracks for everyone? (') && (await text('#asks li.localask[data-kind=delete]')).includes('on the computer itself'), 'with the words and where to answer');
ok(await btns('#asks li.localask') === '', 'but no buttons');
ok(!actions.slice(before).some((a) => a.topic === 'claimask'), 'nothing sent from the phone');

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
