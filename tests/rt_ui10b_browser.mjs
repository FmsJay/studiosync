// Settings in the web UI (rt-ui10b: docs/rt/ui-web-plan.md Phase 10b, 2.9), driven in headless Chromium against a stand-in server:
//   node tests/rt_ui10b_browser.mjs          (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The harness is tests/rt_ui1_browser.mjs's (as rt_ui4's): the real lib/webui/index.html and every page file, stand-in topics over
// /api/events, the actions the page POSTs recorded. Checks: Settings' sub-tabs here and on another device; the rows drawn from the settings
// topic (a switch, a choice, a number, a link, a button) and what each sends; the focus rule's choices, strip first; a studio row a member may
// not change is greyed; a row that asks first sends nothing on No and `sure` on Yes; the talk mic's note and its fix; Devices (the phone link,
// Your computers); You (profile, studios, this device's theme and text size); another device: You only. Nothing reaches REAPER or the network.
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
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui10b-chrome-'));
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

const q = (s) => JSON.stringify(s);
const ENVC = Object.assign({}, PROJECT.topics.env, { computer: 'James-Main', user: 'James-Main', studios: [{ name: 'Chilio', role: 'owner' }, { name: 'Side', role: 'member' }] });
const FOCUS = [['strip', 'Shrink to the strip'], ['button', 'Shrink to the button'], ['stay', 'Stay as it is'], ['behind', 'Go behind REAPER'], ['fade', 'Fade']];
const SETTINGS = { v: 1, user: 'James-Main', studio: 'Chilio', role: 'admin', may: true, tailnet: 'james-main',
  said: { text: 'the studio’s call link is set', at: 1 },
  computers: [{ user: 'James-Laptop', state: 'asks' }, { user: 'James-Main', state: 'this' }, { user: 'Bo', state: 'other' }],
  rows: [
    { id: 'focus', sec: 'computer', grp: 'Window', kind: 'choice', label: 'When REAPER takes the focus', choices: FOCUS, value: 'strip', may: true },
    { id: 'lock', sec: 'computer', grp: 'Window', kind: 'bool', label: 'Lock the strip and button', value: false, may: true },
    { id: 'stream_bars', sec: 'computer', grp: 'Sync', kind: 'number', label: 'Bars behind', lo: 1, hi: 16, value: 1, may: true },
    { id: 'talk_input', sec: 'devices', grp: 'Talk mic', kind: 'choice', label: 'Talk mic', choices: [[0, 'In 1  ·  Guitar (armed)'], [1, 'In 2']], value: 0, may: true,
      note: 'Your talk mic is what Guitar records from', fix: { label: 'Talk on In 2 instead', value: 1 } },
    { id: 'ai', sec: 'studio', grp: 'Studio', kind: 'bool', label: 'AI tools', value: true, may: true },
    { id: 'public_links', sec: 'studio', grp: 'Public links', kind: 'bool', label: 'Public links', value: false, confirm_on: 'WARNING: public' },
    { id: 'tailscale_only', sec: 'studio', grp: 'Connection', kind: 'bool', label: 'Sync only through Tailscale', value: false, may: true, confirm_on: 'Sure?' },
    { id: 'call', sec: 'studio', grp: 'Studio call', kind: 'text', label: 'The studio’s call link', value: '', may: true },
    { id: 'all_actions', sec: 'advanced', grp: 'Advanced', kind: 'bool', label: 'Every StudioSync action', value: false, may: true },
    { id: 'debug_report', sec: 'advanced', grp: 'Debug', kind: 'button', label: 'Save a debug report now', value: false, may: true },
  ] };
const page = (n) => '.sstab[data-tab="settings"] .ssset-' + n;
const setSent = (id, v, sure) => sent((a) => a.topic === 'settings' && a.set && a.set.id === id && a.set.value === v && (sure === undefined ? true : a.set.sure === sure));
const text = (sel) => ev('(() => { const e = document.querySelector(' + q(sel) + '); return e ? e.textContent : ""; })()');
const fire = (sel, value, prop = 'value') => ev('(() => { const e = document.querySelector(' + q(sel) + '); e.' + prop + ' = ' + q(value) + '; e.dispatchEvent(new Event("change")); return 1; })()');

// ---- this computer -------------------------------------------------------------------------------------------------------------------------
state = { engine: false, topics: {} };
await open(LOCAL + '#settings/computer');
await push(PROJECT);
await push({ topics: { env: ENVC } });
ok(await route() === 'settings/computer', 'the deep link opens Settings > This computer');
ok(await okSubs('settings') === 'you,computer,studio,devices,advanced', 'this computer: all five (' + await okSubs('settings') + ')');
ok(!(await list()).find((t) => t.name === 'settings').subs.some((s) => s.coming), 'none of them says “coming” any more');
ok(await until(() => sent((a) => a.topic === 'settings' && a.want === true)), 'Settings says it shows');
ok((await text(page('computer'))).includes('Asking Live sync'), 'before the topic: asking Live sync');
await push({ topics: { settings: SETTINGS } });
ok(await ev('[...document.querySelectorAll(' + q(page('computer') + ' h3') + ')].map((h) => h.textContent).join(",")') === 'Window,Sync', 'This computer: Window, then Sync');
const focusSel = page('computer') + ' [data-id=focus] select';
ok(await ev('[...document.querySelector(' + q(focusSel) + ').options].map((o) => o.textContent).join("|")') === FOCUS.map((f) => f[1]).join('|'), 'the focus rule’s five choices, strip first');
ok(await ev('document.querySelector(' + q(focusSel) + ').selectedOptions[0].textContent') === 'Shrink to the strip', 'strip selected');
clear();
await fire(focusSel, '4');
ok(await until(() => setSent('focus', 'fade')), 'picking Fade sends focus = fade');
await fire(page('computer') + ' [data-id=lock] input', true, 'checked');
ok(await until(() => setSent('lock', true)), 'a switch sends true');
await fire(page('computer') + ' [data-id=stream_bars] input', '3');
ok(await until(() => setSent('stream_bars', 3)), 'a number sends the number');
ok(await text(page('computer') + ' .psaid') === SETTINGS.said.text, 'what the last change said');

// ---- Studio --------------------------------------------------------------------------------------------------------------------------------
await ev('ssTabs.go("settings/studio"); 1');
await sleep(200);
ok((await text(page('studio'))).includes('you’re the admin'), 'Studio says who may change it');
ok(await ev('document.querySelector(' + q(page('studio') + ' [data-id=public_links] input') + ').disabled'), 'Public links greyed for an admin (the owner’s)');
ok(!(await ev('document.querySelector(' + q(page('studio') + ' [data-id=ai] input') + ').disabled')), 'AI tools open to an admin');
clear();
await ev('window.confirm = () => false; 1');
await fire(page('studio') + ' [data-id=tailscale_only] input', true, 'checked');
await sleep(300);
ok(!sent((a) => a.set && a.set.id === 'tailscale_only') && !(await ev('document.querySelector(' + q(page('studio') + ' [data-id=tailscale_only] input') + ').checked')), 'No to the question: nothing sent, the switch back');
await ev('window.confirm = () => true; 1');
await fire(page('studio') + ' [data-id=tailscale_only] input', true, 'checked');
ok(await until(() => setSent('tailscale_only', true, true)), 'Yes: sent with sure');
await ev('document.querySelector(' + q(page('studio') + ' [data-id=call] input') + ').value = " https://discord.gg/x "; 1');
await click(page('studio') + ' [data-id=call] .sssave');
ok(await until(() => setSent('call', 'https://discord.gg/x')), 'the call link’s Save sends it, trimmed');

// ---- Devices -------------------------------------------------------------------------------------------------------------------------------
await ev('ssTabs.go("settings/devices"); 1');
await sleep(200);
ok((await text(page('devices') + ' [data-id=talk_input] .ssnote')).includes('Guitar'), 'the talk mic says it clashes with an armed track');
clear();
await click(page('devices') + ' [data-id=talk_input] .ssfix');
ok(await until(() => setSent('talk_input', 1)), 'and its fix moves it to the free input');
await click(page('devices') + ' .ssphone');
ok(await until(() => sent((a) => a.topic === 'settings' && a.phone === true)), 'Show the phone link asks for it');
await push({ topics: { settings: Object.assign({}, SETTINGS, { phone: 'http://james-main:47281/?t=ab12' }) } });
ok(await text(page('devices') + ' .ssphonelink') === 'http://james-main:47281/?t=ab12', 'the link shows');
const rows = await ev('[...document.querySelectorAll(' + q(page('devices') + ' .sscomputers li') + ')].map((l) => l.textContent).join(" | ")');
ok(rows.includes('James-Laptopsays it’s yoursMine too') && rows.includes('James-Mainthis computer') && !rows.includes('this computerMine'), 'Your computers: Mine too where it says it’s yours, none on this one (' + rows + ')');
await click(page('devices') + ' .sscomputers li .ssmine');
ok(await until(() => sent((a) => a.topic === 'settings' && a.computer && a.computer.user === 'James-Laptop' && a.computer.on === true)), 'Mine too sends it');

// ---- Advanced ------------------------------------------------------------------------------------------------------------------------------
await ev('ssTabs.go("settings/advanced"); 1');
await sleep(200);
clear();
await click(page('advanced') + ' [data-id=debug_report] button');
ok(await until(() => setSent('debug_report', true)), 'a button row sends true');

// ---- You -----------------------------------------------------------------------------------------------------------------------------------
await ev('ssTabs.go("settings/you"); 1');
await sleep(200);
ok(!!(await ev('!!document.querySelector(' + q(page('you') + ' .ssprofile') + ')')), 'You: the picture, name and colour button');
ok(await ev('[...document.querySelectorAll(' + q(page('you') + ' .ssstudios li') + ')].map((l) => l.textContent).join(",")') === 'Chilio · owner,Side · member', 'your studios and roles');
await fire(page('you') + ' .sstheme', 'dark');
await fire(page('you') + ' .sstext', '125');
ok(await ev('document.documentElement.dataset.theme') === 'dark' && await ev('localStorage.getItem("ss-theme")') === 'dark', 'Theme: dark, kept on this device');
ok(await ev('document.documentElement.style.zoom') === '1.25' && await ev('localStorage.getItem("ss-text")') === '125', 'Text size 125 %, kept on this device');

// ---- another device on the tailnet: You only ------------------------------------------------------------------------------------------------
state = { engine: true, topics: { env: ENVC, presence: PROJECT.topics.presence, settings: SETTINGS } };
await open(REMOTE + '#settings/studio');
ok(await okSubs('settings') === 'you', 'another device: You only (' + await okSubs('settings') + ')');
ok(await ev('!!document.querySelector(' + q(page('you') + ' .ssprofile') + ')'), 'with the profile button');

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
