// The Project tab's View / Edit switch (rt-ui7, docs/rt/ui-web-plan.md 2.6 and James's decision 3), driven in headless Chromium against a
// stand-in server:   node tests/rt_ui7_browser.mjs   (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL)
// The real shell.js, tabs.js, daw.js, pianoroll.js, autolanes.js and mixer.js run in a page served from lib/webui with a fixed project. The
// server records every action the page POSTs. Checked: the page opens in View and sends nothing however it's clicked, dragged, keyed or
// menued (the arrange, the piano roll, the sends panel, the Mixer); in Edit each edit carries edit: true (the arrange's, a send's, the
// Mixer's); back to View after the idle time and each time the Project tab opens again (not when moving between its sub-tabs); track heights,
// fixed-lane rows and the ruler's format from the topic. Nothing reaches REAPER or the network: its own Chrome profile in a temp folder, a
// random localhost port, no devices.
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

// ---- the stand-in project: Bass twice as tall as the others in REAPER, Keys with two fixed lanes, the ruler in m:ss ----------------------
const KEY = 'S/main';
const bars = Array.from({ length: 31 }, (_, i) => i * 2);
const project = () => ({
  daw: { key: KEY, len: 60, chunks: 1, per: 4, snap: 1, grid: 0.25, bars, sigs: [[0, 4, 4]], tempo: [[0, 120]], rf: 0,
    tracks: [{ n: 'Drums', c: '#cc4444', h: 60 }, { n: 'Bass', c: '#4477cc', h: 120 }, { n: 'Keys', c: '#44aa66', h: 60, nl: 2 }],
    markers: [{ p: 2, n: 'A', i: 1 }] },
  dawc0: { key: KEY, k: 0, from: 0, tr: [[{ p: 0, l: 8, k: '8888888888888888' }], [{ p: 4, l: 6, k: '4444444444' }, { p: 12, l: 4, k: '4444' }],
    [{ p: 2, l: 6, x: 1, nt: [0, 500, 60, 1000, 500, 64], ln: 0, n: 'Top' }, { p: 2, l: 6, k: '444444', ln: 1, n: 'Low' }]] },
  dawcur: { me: { user: 'James', cur: 1 }, people: [] },
  dawsend: { key: KEY, lane: 1, name: 'Bass', sends: [{ i: 0, to: 2, n: 'Keys', v: 1, p: 0 }] },
  dawmidi: { key: KEY, asked: { lane: 2, idx: 0, p: 2, l: 6 }, ref: { lane: 2, idx: 0, p: 2, l: 6 }, name: 'Top', track: 'Keys', notes: [[0, 0, 60, 100, 0, 0.5]], ccs: [] },
  mix: { strips: [{ o: 'T1', name: 'Drums', v: 1, p: 0, fx: [{ i: 0, n: 'ReaEQ', on: true }], sends: [{ i: 0, to: 'T2', name: 'Bass', v: 1 }] }], master: { v: 1 } },
  env: { v: 1, front: { project: 'S', room: 'main' } },
});
const state = { engine: true, topics: project() };
const actions = [];
const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/') {
    res.setHeader('Content-Type', 'text/html');
    return res.end('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><link rel="stylesheet" href="style.css"><link rel="stylesheet" href="daw.css"><link rel="stylesheet" href="mixer.css"><link rel="stylesheet" href="shell.css">' +
      '<header><div class="title">StudioSync</div></header><main>home</main><script src="shell.js"></script><script src="tabs.js"></script><script src="daw.js"></script><script src="pianoroll.js"></script><script src="autolanes.js"></script><script src="mixer.js"></script>');
  }
  if (u.pathname === '/api/state') { res.setHeader('Content-Type', 'application/json'); return res.end(JSON.stringify(state)); }
  if (u.pathname === '/api/action') {
    let b = '';
    req.on('data', (c) => { b += c; });
    req.on('end', () => { try { actions.push(JSON.parse(b)); } catch (e) { actions.push({ bad: b }); } res.setHeader('Content-Type', 'application/json'); res.end('{}'); });
    return;
  }
  const f = path.join(root, path.basename(u.pathname));
  if (fs.existsSync(f)) { res.setHeader('Content-Type', types[path.extname(f)] || 'application/octet-stream'); return res.end(fs.readFileSync(f)); }
  res.statusCode = 404; res.end();
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = 'http://127.0.0.1:' + server.address().port + '/';

// ---- Chrome over the DevTools protocol (Node's own WebSocket, no packages) -----------------------------------------------------------------
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui7-chrome-'));
const proc = spawn(chrome, ['--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + prof, '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--window-size=1100,720', 'about:blank'], { stdio: 'ignore' });
let fails = 0;
const done = async (code) => { try { proc.kill(); } catch (e) {} server.close(); await new Promise((r) => setTimeout(r, 300)); try { fs.rmSync(prof, { recursive: true, force: true }); } catch (e) {} process.exit(code); };
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
const mouse = async (type, x, y, extra) => cdp('Input.dispatchMouseEvent', Object.assign({ type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1 }, extra));
const click = async (x, y, n = 1) => {
  for (let i = 1; i <= n; i++) { await mouse('mousePressed', x, y, { clickCount: i }); await mouse('mouseReleased', x, y, { clickCount: i }); }
  await sleep(80);
};
const rclick = async (x, y) => { await mouse('mousePressed', x, y, { button: 'right', buttons: 2 }); await mouse('mouseReleased', x, y, { button: 'right', buttons: 0 }); await sleep(80); };
const drag = async (x0, y0, x1, y1) => {
  await cdp('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x0, y: y0 });
  await mouse('mousePressed', x0, y0);
  for (let i = 1; i <= 8; i++) await cdp('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x0 + (x1 - x0) * i / 8, y: y0 + (y1 - y0) * i / 8, buttons: 1 });
  await mouse('mouseReleased', x1, y1);
  await sleep(80);
};
const key = async (k, code, vk) => {
  await cdp('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk });
  await cdp('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk });
  await sleep(80);
};
// canvas time and track -> viewport (dy: px below the lane's top)
const at = async (t, lane, dy = 20) => ev('(() => { const r = document.querySelector(".dcv").getBoundingClientRect(), D = window.ssDaw; return [r.left + D.xOf(' + t + '), r.top + D.laneY(' + lane + ') + ' + dy + ']; })()');
const text = (sel) => ev('(document.querySelector(' + JSON.stringify(sel) + ') || {}).textContent || ""');
const editing = () => ev('window.ssDaw.editing()');
const edits = () => actions.filter((a) => (a.topic === 'daw' && (a.edit || a.note || a.auto || a.send)) || (a.topic === 'mixer' && (a.set || a.fx || a.send)));
const go = async (r) => { await ev('ssTabs.go(' + JSON.stringify(r) + '); 1'); await sleep(250); };
const pressed = (sel) => ev('(document.querySelector(' + JSON.stringify(sel) + ') || {}).getAttribute && document.querySelector(' + JSON.stringify(sel) + ').getAttribute("aria-pressed")');

await cdp('Runtime.enable');
await cdp('Page.enable');
await cdp('Page.navigate', { url: base });
await sleep(700);
await go('project/arrange');
ok(await ev('!!window.ssDaw && !!window.ssDaw.head && window.ssDaw.head.tracks.length === 3'), 'the page drew the stand-in project');

// ---- it opens in View, and View sends nothing --------------------------------------------------------------------------------------
{
  ok(!(await editing()) && await pressed('.song .dmode .dmv') === 'true' && await pressed('.song .dmode .dme') === 'false', 'the Project tab opens in View');
  ok(await ev('document.querySelector(".song .dbar").firstElementChild.classList.contains("dmode")'), 'the switch is at the left of the bar');
  ok(await ev('!document.querySelector(".song").classList.contains("ssediting") && document.querySelector(".song .dmnote").hidden'), 'no orange frame, no "Editing" line');
  ok(await ev('[...document.querySelectorAll(".dedit .eonly")].every((b) => getComputedStyle(b).display === "none" && b.disabled)'), 'the edit row’s changing controls are hidden and off');
  ok((await text('.dfollow')).startsWith('Follow'), 'the follow select says Follow (the switch says View)');
  const n0 = actions.length;
  let [x, y] = await at(14, 1);
  await click(x, y);
  ok((await text('.esel')).includes('Bass'), 'a click still selects (Bass)');
  await key('Delete', 'Delete', 46);
  const x0 = await ev('window.ssDaw.view().x0');
  await drag(x, y, x - 120, y);
  ok(await ev('window.ssDaw.view().x0') > x0 + 1, 'a drag on an item scrolls the view');
  [x, y] = await at(14, 1);
  await rclick(x, y);
  const menu = await ev('[...document.querySelectorAll(".song > .dwrap > .dmenu button, .dwrap > .dmenu button")].map((b) => b.textContent)');
  ok(!menu.some((t) => /Delete|Split|Mute|Colour|Region/.test(t)), 'the menu offers nothing that changes things (' + menu.join(' | ') + ')');
  await ev('(() => { const b = [...document.querySelectorAll(".dmenu button")].find((x) => x.textContent === "Close"); if (b) b.click(); })(); 1');
  // a marker drag: nothing
  const mx = await ev('(() => { const r = document.querySelector(".dcv").getBoundingClientRect(); return [r.left + window.ssDaw.xOf(2), r.top + 24]; })()');
  await drag(mx[0], mx[1], mx[0] + 60, mx[1]);
  // the sends panel opens to look; its controls are off
  [x, y] = await at(5, 1);
  await click(x, y);
  await ev('[...document.querySelectorAll(".dedit button")].find((b) => b.textContent === "Sends").click(); 1');
  await sleep(150);
  ok(await ev('!document.querySelector(".dsends").hidden && [...document.querySelectorAll(".dsends .srow input, .dsends .srow button")].every((e) => e.disabled) && document.querySelector(".dsends .sadd button").disabled'),
    'the sends panel opens with every control off');
  await ev('document.querySelector(".dsends .shead button").click(); 1');
  // a page script trying anyway: refused before anything is posted
  const tried = await ev('window.ssDaw.act({ edit: { id: "x1", op: "delete", lane: 0, idx: 0, p: 0, l: 8 } }).then(() => "sent", (e) => e.message)');
  ok(tried === 'View', 'ssDaw.act refuses an edit in View (' + tried + ')');
  // the piano roll opens read only
  [x, y] = await at(4, 2, 6); // (Keys' upper row: the MIDI item)
  await click(x, y, 2);
  await sleep(200);
  ok(await ev('(() => { const p = document.querySelector(".proll"); return !!p && !p.hidden; })()'), 'a double-click opens the piano roll to look');
  ok((await text('.pmsg')).startsWith('View'), 'which says it is to look at (' + (await text('.pmsg')) + ')');
  ok(await ev('document.querySelector(".pstep").disabled && document.querySelector(".pvel").disabled'), 'step input and velocity are off');
  const pr = await ev('(() => { const c = document.querySelector(".pcv").getBoundingClientRect(); return [c.left + c.width * 0.6, c.top + c.height * 0.4]; })()');
  await click(pr[0], pr[1], 2);
  await key('Escape', 'Escape', 27);
  // the Mixer: the song's controls locked, solo still yours
  await go('project/mixer');
  ok(!(await editing()), 'moving to the Mixer keeps View');
  await sleep(200);
  ok(await ev('!!document.querySelector(".mixer .dmode")') && await pressed('.mixer .dmode .dmv') === 'true', 'the Mixer shows the same switch, in View');
  ok(await ev('document.querySelector(".mixer .mxm").disabled && document.querySelector(".mixer .mxfxb").disabled'), 'mute and plug-in bypass are off in View');
  await ev('document.querySelector(".mixer .mxs").click(); 1');
  await sleep(100);
  const solo = actions.slice(n0).filter((a) => a.topic === 'mixer' && a.set && a.set.k === 's');
  ok(solo.length === 1 && solo[0].set.edit === undefined, 'solo (only yours) still goes, as before');
  ok(edits().filter((a) => !(a.set && a.set.k === 's')).length === 0, 'View sent no edit at all (' + JSON.stringify(edits().slice(0, 2)) + ')');
  await go('project/arrange');
}

// ---- Edit: the frame, and every edit carries the flag --------------------------------------------------------------------------------
{
  await ev('document.querySelector(".song .dmode .dme").click(); 1');
  ok(await editing() && await pressed('.song .dmode .dme') === 'true', 'Edit switches it');
  ok(await ev('document.querySelector(".song").classList.contains("ssediting") && !document.querySelector(".song .dmnote").hidden') && (await text('.song .dmnote')) === 'Editing: changes go to everyone',
    'the orange frame and "Editing: changes go to everyone"');
  ok(await ev('[...document.querySelectorAll(".dedit .eonly")].some((b) => getComputedStyle(b).display !== "none")'), 'the edit row shows its controls');
  const n = edits().length;
  const [x, y] = await at(14, 1);
  await click(x, y);
  await key('Delete', 'Delete', 46);
  const a = edits()[n];
  ok(a && a.edit && a.edit.op === 'delete' && a.edit.edit === true && a.edit.idx === 1, 'Delete sends the edit with edit: true (' + JSON.stringify(a && a.edit) + ')');
  await ev('dispatchEvent(new CustomEvent("ss-state", { detail: { engine: true, topics: { dawedit: { id: ' + JSON.stringify(a && a.edit.id) + ', ok: true } } } })); 1');
  // a send's level, from the sends panel
  const [x2, y2] = await at(5, 1);
  await click(x2, y2);
  await ev('[...document.querySelectorAll(".dedit button")].find((b) => b.textContent === "Sends").click(); 1');
  await sleep(150);
  await ev('(() => { const r = document.querySelector(".dsends .srow input[type=range]"); r.value = "-30"; r.dispatchEvent(new Event("change")); })(); 1');
  await sleep(100);
  const s = edits().filter((e) => e.send).pop();
  ok(s && s.send.op === 'vol' && s.send.edit === true, 'a send change carries it too (' + JSON.stringify(s && s.send) + ')');
  await ev('document.querySelector(".dsends .shead button").click(); 1');
  // the Mixer: moving to it keeps Edit, and its mute carries the flag
  await go('project/mixer');
  ok(await editing() && await pressed('.mixer .dmode .dme') === 'true' && await ev('document.querySelector(".mixer").classList.contains("ssediting")'), 'the Mixer is in Edit too (moving between Project’s sub-tabs keeps it)');
  await sleep(150);
  ok(await ev('!document.querySelector(".mixer .mxm").disabled'), 'its mute is on');
  await ev('document.querySelector(".mixer .mxm").click(); 1');
  await sleep(100);
  const m = edits().filter((e) => e.topic === 'mixer' && e.set && e.set.k === 'm').pop();
  ok(m && m.set.edit === true, 'the Mixer’s mute carries edit: true (' + JSON.stringify(m && m.set) + ')');
  await go('project/arrange');
}

// ---- back to View after the idle time, and each time the tab opens ---------------------------------------------------------------------
{
  await ev('window.ssDaw.EDIT_IDLE_MS = 1500; 1');
  ok(await editing(), 'still in Edit');
  await sleep(3200);
  ok(!(await editing()) && (await text('.dmsg')).includes('Back to View'), 'after the idle time without an edit: View, and it says so (' + (await text('.dmsg')) + ')');
  const n = edits().length;
  const [x, y] = await at(14, 1); // (Bass' second item: the view was scrolled past Drums' above)
  await click(x, y);
  ok((await text('.esel')).includes('Bass'), 'selected in View');
  await key('Delete', 'Delete', 46);
  ok(edits().length === n, 'and nothing is sent then');
  // an edit keeps it awake
  await ev('document.querySelector(".song .dmode .dme").click(); 1');
  await sleep(900);
  await click(x, y);
  await key('Delete', 'Delete', 46);
  await sleep(900);
  ok(await editing(), 'an edit restarts the idle time');
  await ev('window.ssDaw.EDIT_IDLE_MS = 5 * 60 * 1000; 1');
  // leaving the Project tab and coming back
  await go('studio');
  await go('project/arrange');
  ok(!(await editing()) && await pressed('.song .dmode .dmv') === 'true', 'opening the Project tab again: View');
  await ev('document.querySelector(".song .dmode .dme").click(); 1');
  await go('studio');
  await go('project/mixer');
  ok(!(await editing()) && await pressed('.mixer .dmode .dmv') === 'true', 'opening it again on the Mixer: View');
  await go('project/arrange');
}

// ---- REAPER-likeness: heights, fixed-lane rows, the ruler ---------------------------------------------------------------------------
{
  const [a, b, c] = await ev('[0, 1, 2].map((i) => window.ssDaw.laneH(i))');
  ok(b === 2 * a && c === a, 'Bass is twice as tall as Drums, as in REAPER (' + [a, b, c].join(', ') + ')');
  ok(await ev('window.ssDaw.laneY(2) - window.ssDaw.laneY(1)') === b, 'the next track starts under it');
  const [x, y] = await at(4, 2, Math.round(c * 0.8)); // (Keys' lower row)
  await click(x, y);
  ok((await text('.esel')).includes('Low'), 'a click on Keys’ lower row selects its item there (' + (await text('.esel')) + ')');
  const [x2, y2] = await at(4, 2, Math.round(c * 0.2));
  await click(x2, y2);
  ok((await text('.esel')).includes('Top'), 'and the upper row its own');
  ok(/^\d+:\d\d\.\d$/.test((await text('.dtime')).trim()), 'the ruler in m:ss: the time reads m:ss alone (' + (await text('.dtime')) + ')');
  const h = project().daw;
  h.rf = 2;
  await ev('dispatchEvent(new CustomEvent("ss-state", { detail: { engine: true, topics: { daw: ' + JSON.stringify(h) + ' } } })); 1');
  await sleep(100);
  ok(/^\d+\.\d+$/.test((await text('.dtime')).trim()), 'in bars.beats: bar.beat alone (' + (await text('.dtime')) + ')');
}

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
