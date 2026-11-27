// The shell (rt-ui1: docs/rt/ui-web-plan.md Phase 1), driven in headless Chromium against a stand-in server:
//   node tests/rt_ui1_browser.mjs            (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The real lib/webui/index.html with every real page file, served from lib/webui with stand-in topics over /api/events (as the extension
// sends them); actions the page POSTs are recorded. For each environment (in REAPER with a stand-in WebView2 channel, a browser on this
// computer, another device on the tailnet as a wide window and as a phone): which tabs and sub-tabs show, their names, deep links, the
// phone's bar, the pop-out route, the strip, the nav topic, loading, and no tab without what it needs. Nothing reaches REAPER or the
// network: its own Chrome profile in a temp folder, a random localhost port ("studio.test" mapped to it), no devices.
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
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui1-chrome-'));
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

// ---- a browser on this computer, no Live sync: Studio, Health, Settings ------------------------------------------------------------------
state = { engine: false, topics: {} };
await open(LOCAL);
ok(await tabsShown() === 'Studio,Health,Settings', 'no project open: Studio, Health, Settings (' + await tabsShown() + ')');
ok(await route() === 'studio/overview' && await visible('.sstab[data-tab="studio"] #home'), 'Studio shows the studio overview (home.js)');
ok(await okSubs('settings') === 'you,computer,studio,devices,advanced', 'this computer: every Settings sub-tab');
ok(await ev('document.querySelector("link[rel=icon]").getAttribute("href")') === 'icon.svg' && await ev('document.querySelector(".sslogo img").naturalWidth > 0'), 'the StudioSync icon: favicon and logo');
ok(await ev('document.body.classList.contains("ss-local") && document.getElementById("dock").hidden'), 'a browser: no Dock button');

// ---- a project opens: the project tabs, with today's pages under the new names -------------------------------------------------------------
await push(PROJECT);
ok(await tabsShown() === 'Studio,Session,Project,Chat,History,Plug-ins,Health,Settings', 'a project open: the tabs but AI (' + await tabsShown() + ')');
await push({ topics: { env: Object.assign({}, PROJECT.topics.env, { ai: true }) } });
ok(await tabsShown() === 'Studio,Session,Project,Chat,History,Plug-ins,AI,Health,Settings', 'the studio\'s AI on: all nine');
ok(await ev('document.getElementById("where").textContent') === 'Chilio▸Cross Test', 'the breadcrumb: Studio ▸ Project');
{
  const L = await list(), sub = (t, s) => L.find((x) => x.name === t).subs.find((x) => x.name === s);
  ok(!sub('session', 'play').coming && sub('session', 'play').label === 'Play together', 'play.js is Session > Play together');
  ok(!sub('session', 'here').coming && sub('session', 'here').label === 'Who’s here', 'Who\'s here is Session\'s');
  ok(['arrange', 'mixer', 'sheet', 'beat'].every((s) => !sub('project', s).coming), 'Project > Arrange, Mixer, Sheet, Beat (daw.js, mixer.js, sheet.js, visuals.js)');
  ok(['changes', 'versions', 'playback', 'mixes'].every((s) => !sub('history', s).coming), 'History’s four sub-tabs are built (history.js, histhear.js: rt-ui3)');
  ok(!sub('plugins', 'try').coming && sub('plugins', 'try').label === 'Try a bandmate’s', 'tryfx.js is Plug-ins > Try a bandmate\'s');
  ok(!sub('health', 'checks').coming && !sub('ai', 'ai').coming, 'health.js and ai.js in their tabs');
}
await ev('ssTabs.go("session"); 1');
await sleep(100);
ok(await visible('.sstab[data-tab="session"] #here'), 'Session shows Who\'s here');
ok(await ev('document.querySelector("#studiomain").hidden'), 'the studio overview is put away');
await ev('ssTabs.go("chat"); 1');
await sleep(100);
ok(await visible('#msgs') && !(await ev('document.getElementById("chatmain").hidden')) && await ev('ssTabs.route()') === 'chat/chat', 'Chat shows the chat (its own main, which chat.js watches)');
ok(await ev('document.getElementById("sstabs").querySelectorAll(".sssubs").length === 0 && document.querySelector(".sstab[data-tab=chat] .sssubs").hidden'), 'one page: no sub-tab row');
// a click on a tab button
await ev('[...document.querySelectorAll("#sstabs .tab")].find((b) => b.textContent === "History").click(); 1');
await sleep(150);
ok(await route() === 'history/changes' && await visible('.sspage.hchanges'), 'History opens on Changes, its first sub-tab');
ok(await ev('[...document.querySelectorAll(".sstab[data-tab=history] .sssubs button")].filter((b) => !b.hidden).map((b) => b.textContent).join(",")') === 'Changes,Versions,Playback,Mixes', 'its sub-tabs');
await ev('[...document.querySelectorAll(".sstab[data-tab=history] .sssubs button")].find((b) => b.textContent === "Playback").click(); 1');
await sleep(100);
ok(await route() === 'history/playback' && await visible('.sspage.history'), 'Playback: the time lapse');
ok(await ev('location.hash') === '#history/playback', 'the address follows: a deep link to here');
// (whichever part isn't built yet: they get built one by one. rt-ui6 built Session > Rooms, which this used)
const soon = await ev('(() => { for (const t of ssTabs.list()) for (const s of t.subs) if (t.ok && s.ok && s.coming) return t.name + "/" + s.name; return ""; })()');
if (soon) {
  await ev('location.hash = "#' + soon + '"; 1');
  await sleep(150);
  ok(await route() === soon && (await ev('document.querySelector(".sstab[data-tab=' + soon.split('/')[0] + '] .sscoming:not([hidden])").textContent')).includes('Coming here'), 'a part not built yet says it’s coming, and where it is meanwhile (' + soon + ')');
} else console.log('  (every part is built: no "coming" page left to check)');

// a project closes while you're on it: Studio meanwhile; it opens again: back where you were
await ev('ssTabs.go("project/mixer"); 1');
await sleep(100);
await push(NOPROJECT);
ok(await route() === 'studio/overview' && await tabsShown() === 'Studio,Health,Settings', 'Live sync stops: no tab without its need, Studio shown');
await push(PROJECT);
ok(await route() === 'project/mixer', 'Live sync back: Project > Mixer again');
// loading (findings item 14)
await push({ topics: { env: Object.assign({}, PROJECT.topics.env, { front: Object.assign({}, PROJECT.topics.env.front, { loading: true, tracks: 120 }) }) } });
ok(await ev('document.body.classList.contains("ssloading")') && (await ev('document.querySelector(".ssloadnote").textContent')).includes('Loading Cross Test.rpp (120 tracks)'), 'loading: said, and the pages greyed');
ok(await ev('getComputedStyle(document.getElementById("sspages")).pointerEvents') === 'none', 'nothing on the pages can be pressed meanwhile');
await push(PROJECT);
ok(!(await ev('document.body.classList.contains("ssloading")')), 'loaded: back to normal');
// the menu on this computer's browser: Open in REAPER (the nav action)
await ev('document.getElementById("ssmenu").click(); 1');
await sleep(100);
const items = await ev('[...document.querySelectorAll(".ssmenulist:not([hidden]) button")].map((b) => b.textContent).join("|")');
ok(items.includes('Open in REAPER') && !items.includes('Open in the browser') && items.includes('Pop out this page'), 'the menu here: Open in REAPER, Pop out (' + items + ')');
await ev('[...document.querySelectorAll(".ssmenulist:not([hidden]) button")].find((b) => b.textContent === "Open in REAPER").click(); 1');
await sleep(200);
ok(await until(() => actions.some((a) => a.topic === 'nav' && a.to === 'reaper' && a.page === 'project' && a.sub === 'mixer')), 'Open in REAPER asks this computer for the same page');
// a nav topic: only the REAPER view acts on it
await push({ topics: { nav: { page: 'chat', at: now(), id: 'n1' } } });
ok(await route() === 'project/mixer', 'a browser leaves a REAPER action\'s nav alone');
// rail on a wide window
ok(await ev('document.body.classList.contains("ssrail")') && await ev('getComputedStyle(document.getElementById("sstabs")).flexDirection') === 'column', 'wide and landscape: the tabs as a rail');

// ---- deep links ------------------------------------------------------------------------------------------------------------------------------
state = { engine: PROJECT.engine, topics: JSON.parse(JSON.stringify(PROJECT.topics)) };
await open(LOCAL + '#project/beat');
ok(await route() === 'project/beat' && await visible('.sstab[data-tab="project"] .sspage:not([hidden])'), '#project/beat opens Project > Beat');
await open(LOCAL + '#history');
ok(await route() === 'history/changes', '#history opens History on Changes');
await open(LOCAL + '#nope/x');
ok(await route() === 'studio/overview', 'a link to no tab: Studio');
// narrow (a docker): More
await open(LOCAL, { w: 330, h: 700 });
ok(await ev('!document.querySelector(".ssmore").hidden && document.querySelectorAll("#sstabs .tab[data-more]").length > 0'), 'a narrow docker: the last tabs in More');
await ev('document.querySelector(".ssmore").click(); 1');
await sleep(100);
const moreItems = await ev('[...document.querySelectorAll(".ssmenulist:not([hidden]) button")].map((b) => b.textContent)');
ok(moreItems.includes('Settings') && !moreItems.includes('Studio'), 'More lists the ones that didn\'t fit (' + moreItems.join(',') + ')');
await ev('[...document.querySelectorAll(".ssmenulist:not([hidden]) button")].find((b) => b.textContent === "Settings").click(); 1');
await sleep(150);
ok(await route() === 'settings/you' && (await ev('document.querySelector(".ssmore").textContent')).startsWith('Settings'), 'and opens it, named on More');
// pop-out
await open(LOCAL + '?pop=chat');
ok(await route() === 'chat/chat' && await ev('document.body.classList.contains("sspop")') && await ev('getComputedStyle(document.getElementById("sstabs")).display') === 'none', '?pop=chat: the chat alone, no tab row');
ok(await ev('!!document.querySelector(".ssback")'), 'with a way back into the main window');
await open(LOCAL + '?pop=share&call=x');
ok(await ev('ssTabs.route()') === '' && await ev('[...document.querySelectorAll(".sstab")].every((t) => t.hidden)'), 'another file’s pop-out (call.js’s ?pop=share): no tab shown in it');
// the strip
await open(LOCAL + '?win=strip');
ok(await visible('.ssstrip') && !(await visible('header')) && (await ev('document.querySelector(".sswords").textContent')).startsWith('Sync on · James-Main in control'), 'the strip: only it, its words (' + await ev('document.querySelector(".sswords").textContent') + ')');
await open(LOCAL + '?win=button');
ok(await visible('.ssstrip .sslogoimg') && !(await visible('.sswords')), 'the button: the logo only');

// ---- in REAPER (docked) ------------------------------------------------------------------------------------------------------------------------
await open(LOCAL + '?host=docked', { reaper: true });
ok(await ev('document.body.classList.contains("ss-reaper")') && await ev('ssEnv.where') === 'reaper', 'in REAPER');
ok(await ev('!document.getElementById("dock").hidden && document.getElementById("dock").textContent') === 'Undock', 'Undock shows');
ok(await ev('[...document.querySelectorAll("header .ssico")].length === 3 && [...document.querySelectorAll("header .ssico")].every((b) => b.hidden)'), 'strip, button, full screen hidden until the window says it can');
await ev('document.getElementById("dock").click(); 1');
ok((await ev('window.__sent')).includes('dock'), 'Undock sends "dock"');
await ev('document.getElementById("ssmenu").click(); 1');
await sleep(100);
const ritems = await ev('[...document.querySelectorAll(".ssmenulist:not([hidden]) button")].map((b) => b.textContent).join("|")');
ok(ritems.includes('Open in the browser') && !ritems.includes('Open in REAPER'), 'the menu in REAPER: Open in the browser (' + ritems + ')');
await ev('[...document.querySelectorAll(".ssmenulist:not([hidden]) button")].find((b) => b.textContent === "Open in the browser").click(); 1');
await sleep(200);
ok(await until(() => actions.some((a) => a.topic === 'nav' && a.to === 'browser' && a.page === 'studio')), 'Open in the browser asks for this page');
await push({ topics: { nav: { page: 'history', sub: 'playback', at: now(), id: 'n2' } } });
ok(await route() === 'history/playback', 'a REAPER action\'s nav: the view goes there');
await push({ topics: { nav: { page: 'chat', at: now() - 60, id: 'n3' } } });
ok(await route() === 'history/playback', 'a stale nav: left alone');
await ev('window.__ls.forEach((f) => f({ data: JSON.stringify({ win: "strip" }) })); 1');
await sleep(100);
ok(await ev('document.body.dataset.win') === 'strip' && await visible('.ssstrip'), 'the window says strip: the strip');
await ev('window.__ls.forEach((f) => f({ data: { win: "full" } })); 1');
await sleep(100);
ok(!(await ev('"win" in document.body.dataset')) && await ev('[...document.querySelectorAll("header .ssico")].every((b) => !b.hidden)'), 'back to the whole view; its strip, button and full screen buttons now show');

// ---- another device on the tailnet: a wide window ----------------------------------------------------------------------------------------------
await open(REMOTE);
ok(await ev('ssEnv.where') === 'remote' && await ev('document.getElementById("dock").hidden'), 'another device: no window buttons');
ok(await tabsShown() === 'Studio,Session,Project,Chat,History,Plug-ins,Health,Settings', 'its tabs (' + await tabsShown() + ')');
ok(await okSubs('plugins') === 'project,pack' && await okSubs('settings') === 'you' && await okSubs('health') === 'checks', 'only what works from there: no Try or Find, Settings > You only, Health\'s checks');
ok(await ev('document.getElementById("ssmenu").hidden'), 'no menu where nothing in it would work');
await ev('ssTabs.go("plugins/try"); 1');
await sleep(100);
ok(await route() === 'plugins/project', 'a sub-tab that can\'t work there isn\'t opened');

// ---- another device: a phone ---------------------------------------------------------------------------------------------------------------------
await open(REMOTE, { phone: true, w: 390, h: 800 });
const barShown = () => ev('[...document.querySelectorAll("#ssbar .ssbarb")].filter((b) => !b.hidden).map((b) => b.textContent).join(",")');
ok(await ev('document.body.classList.contains("ssphone")') && await visible('#ssbar') && !(await visible('#sstabs')), 'a phone: the bottom bar, no tab row');
ok(await barShown() === 'Session,Project,Record,Chat,More', 'the bar: Session, Project, Record, Chat, More (' + await barShown() + ')');
await ev('[...document.querySelectorAll("#ssbar .ssbarb")].find((b) => b.textContent === "More").click(); 1');
await sleep(100);
const pitems = await ev('[...document.querySelectorAll(".ssmenulist:not([hidden]) button")].map((b) => b.textContent).join(",")');
ok(pitems === 'Studio,History,Plug-ins,Health,Settings', 'More: the rest (' + pitems + ')');
await ev('[...document.querySelectorAll("#ssbar .ssbarb")].find((b) => b.textContent === "Project").click(); 1');
await sleep(100);
ok(await route() === 'project/arrange', 'Project from the bar');
await push(NOPROJECT);
ok(await barShown() === 'Studio,More', 'no project: Studio, More (' + await barShown() + ')');

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
