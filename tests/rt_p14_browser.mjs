// The Project page's edits (rt-p14: delete, fades, sends, automation items, CC lanes), driven in headless Chromium against a stand-in server:
//   node tests/rt_p14_browser.mjs            (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The real lib/webui/daw.js, pianoroll.js and autolanes.js run in a page served from lib/webui with a fixed project (the topics a
// computer would publish); the server records each action the page POSTs and the driver answers as Live sync would (the dawedit topic,
// the changed chunk). Nothing reaches REAPER or the network: its own Chrome profile in a temp folder, a random localhost port, no devices.
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

// ---- the stand-in project ---------------------------------------------------------------------------------------------------------------
const KEY = 'S/main';
const bars = Array.from({ length: 31 }, (_, i) => i * 2);
const state = { engine: true, topics: {} };
function project(extra) {
  const top = {
    daw: { key: KEY, len: 60, chunks: 1, per: 4, snap: 1, grid: 0.25, bars, sigs: [[0, 4, 4]], tempo: [[0, 120]],
      tracks: [{ n: 'Drums', c: '#cc4444' }, { n: 'Bass', c: '#4477cc', e: 2 }, { n: 'Keys', c: '#44aa66' }],
      markers: [{ p: 10, e: 30, n: 'Verse', i: 1 }, { p: 2, n: 'A', i: 1 }] },
    dawc0: { key: KEY, k: 0, from: 0, tr: [[{ p: 0, l: 8, k: '8888888888888888' }], [{ p: 4, l: 6, k: '4444444444' }, { p: 12, l: 4, k: '4444' }], [{ p: 2, l: 6, x: 1, nt: [0, 500, 60, 1000, 500, 64] }]] },
    dawcur: { me: { user: 'James', cur: 1 }, people: [] },
  };
  return Object.assign(top, extra || {});
}
state.topics = project();
const actions = [];
const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/') {
    res.setHeader('Content-Type', 'text/html');
    return res.end('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><link rel="stylesheet" href="style.css"><link rel="stylesheet" href="daw.css">' +
      '<header><div class="title">StudioSync</div></header><main>home</main><script src="daw.js"></script><script src="pianoroll.js"></script><script src="autolanes.js"></script>');
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
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-p14-chrome-'));
const proc = spawn(chrome, ['--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + prof, '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--window-size=1100,720', 'about:blank'], { stdio: 'ignore' });
let fails = 0;
const done = async (code) => { try { proc.kill(); } catch (e) {} server.close(); await new Promise((r) => setTimeout(r, 300)); try { fs.rmSync(prof, { recursive: true, force: true }); } catch (e) {} process.exit(code); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
process.on('uncaughtException', (e) => { console.log('FAIL the driver stopped: ' + (e && e.message)); done(1); }); // (a check that throws is a failure, not a crash)
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
// the topics a computer would publish next, as the page's 'ss-state' event brings them
const push = (topics) => ev('dispatchEvent(new CustomEvent("ss-state", { detail: { engine: true, topics: ' + JSON.stringify(topics) + ' } })); 1');
const click = async (x, y, n = 1) => {
  for (let i = 1; i <= n; i++) {
    await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: i });
    await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: i });
  }
  await sleep(60);
};
const drag = async (x0, y0, x1, y1) => {
  await cdp('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x0, y: y0 });
  await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: x0, y: y0, button: 'left', buttons: 1, clickCount: 1 });
  for (let i = 1; i <= 8; i++) await cdp('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x0 + (x1 - x0) * i / 8, y: y0 + (y1 - y0) * i / 8, buttons: 1 });
  await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x1, y: y1, button: 'left', buttons: 0, clickCount: 1 });
  await sleep(60);
};
const key = async (k, code, vk) => {
  await cdp('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk });
  await cdp('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk });
  await sleep(60);
};
// canvas pixel -> viewport
const at = async (t, lane, dy = 0) => ev('(() => { const r = document.querySelector(".dcv").getBoundingClientRect(), D = window.ssDaw; return [r.left + D.xOf(' + t + '), r.top + D.laneY(' + lane + ') + 20 + ' + dy + ']; })()');
const markerXY = async (t) => ev('(() => { const r = document.querySelector(".dcv").getBoundingClientRect(); return [r.left + window.ssDaw.xOf(' + t + '), r.top + 24]; })()');
const lastAction = () => actions[actions.length - 1] || {};
const edits = () => actions.filter((a) => a.edit || a.note || a.auto);
const button = (label) => ev('(() => { const b = [...document.querySelectorAll(".dedit button")].find((x) => x.textContent === ' + JSON.stringify(label) + '); return b ? { disabled: b.disabled, x: b.getBoundingClientRect().left + 4, y: b.getBoundingClientRect().top + 4 } : null; })()');
const text = (sel) => ev('(document.querySelector(' + JSON.stringify(sel) + ') || {}).textContent || ""');

await cdp('Runtime.enable');
await cdp('Page.enable');
await cdp('Page.navigate', { url: base });
await sleep(600);
await ev('[...document.querySelectorAll(".tabs .tab")].find((b) => b.textContent === "Project").click(); 1');
await sleep(300);
ok(await ev('!!window.ssDaw && !!window.ssDaw.head && window.ssDaw.head.tracks.length === 3'), 'the page drew the stand-in project');
ok((await text('.dfollow')).startsWith('View') && await ev('document.querySelector(".dfollow select").getAttribute("aria-label")') === 'Watch a bandmate', 'the watch select reads as P7 words it');

// ---- delete ---------------------------------------------------------------------------------------------------------------------------
{
  const [x, y] = await at(14, 1); // Bass's second item (12 to 16 s)
  await click(x, y);
  ok((await text('.esel')).includes('Bass'), 'a click selects the Bass item');
  let b = await button('Delete');
  ok(b && !b.disabled, 'Delete is on with an item selected');
  await click(b.x, b.y);
  let a = lastAction();
  ok(a.topic === 'daw' && a.edit && a.edit.op === 'delete' && a.edit.lane === 1 && a.edit.idx === 1 && a.edit.p === 12 && a.edit.l === 4 && /^[\w-]+$/.test(a.edit.id), 'Delete sends a delete naming the item as drawn');
  await push({ dawedit: { id: a.edit.id, why: 'Chilio has claimed Bass there' } });
  ok((await text('.dmsg')).includes('Not changed: Chilio has claimed Bass there'), 'a refusal says why');
  ok((await text('.esel')).includes('Bass') && !(await button('Delete')).disabled, 'and the item is still selected');
  const n = edits().length;
  await key('Delete', 'Delete', 46);
  a = lastAction();
  ok(edits().length === n + 1 && a.edit.op === 'delete' && a.edit.idx === 1, 'the Delete key does the same');
  const t = project().dawc0;
  t.tr[1] = [t.tr[1][0]];
  await push({ dawedit: { id: a.edit.id, ok: true }, dawc0: t });
  await sleep(100);
  ok(await ev('window.ssDaw.lanes[1].length === 1') && (await button('Delete')).disabled, 'its chunk comes back without it: gone, nothing selected');
  // a marker: click it in the ruler, Delete
  const [mx, my] = await markerXY(2);
  await click(mx, my);
  ok((await text('.esel')).startsWith('Marker A'), 'a click on a marker selects it');
  await key('Delete', 'Delete', 46);
  a = lastAction();
  ok(a.edit && a.edit.op === 'delete_marker' && a.edit.i === 1 && a.edit.r === false && a.edit.p === 2, 'Delete sends delete_marker with its number and place');
  const h = project().daw;
  h.markers = h.markers.filter((m) => m.n !== 'A');
  await push({ dawedit: { id: a.edit.id, ok: true }, daw: h });
  await sleep(100);
  ok((await button('Delete')).disabled && await ev('window.ssDaw.head.markers.length === 1'), 'the header comes back without it');
  // a region, from the right-click menu
  const [rx, ry] = await markerXY(20);
  await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: rx, y: ry, button: 'right', buttons: 2, clickCount: 1 });
  await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: rx, y: ry, button: 'right', buttons: 0, clickCount: 1 });
  await sleep(100);
  const items = await ev('[...document.querySelectorAll(".dmenu button")].map((b) => b.textContent)');
  ok(items.includes('Delete') && items.includes('Rename…'), 'the region’s menu offers Delete');
  await ev('[...document.querySelectorAll(".dmenu button")].find((b) => b.textContent === "Delete").click(); 1');
  await sleep(150);
  a = lastAction();
  ok(a.edit && a.edit.op === 'delete_marker' && a.edit.r === true && a.edit.p === 10, 'and sends it as a region');
  await push({ dawedit: { id: a.edit.id, why: 'only the driver changes markers' } });
  state.topics = project();
  await push(project());
}

// ---- fades ----------------------------------------------------------------------------------------------------------------------------
{
  const topY = async (lane) => ev('(() => { const r = document.querySelector(".dcv").getBoundingClientRect(); return r.top + window.ssDaw.laneY(' + lane + ') + 6; })()');
  const [x8] = await at(8, 0), [x0] = await at(0, 0), y = await topY(0), t2 = (await at(2.1, 0))[0], t6 = (await at(6.1, 0))[0];
  await drag(x0 + 3, y, t2, y + 1); // the top-left corner of Drums' item: the fade-in handle (not a move, not a trim)
  let a = lastAction();
  ok(a.edit && a.edit.op === 'fade' && a.edit.side === 'in' && Math.abs(a.edit.len - 2) < 1e-6 && a.edit.lane === 0 && a.edit.p === 0 && a.edit.l === 8, 'dragging the top-left corner sends a fade in, snapped to the grid (' + JSON.stringify(a.edit) + ')');
  await push({ dawedit: { id: a.edit.id, why: 'only the driver changes things in this room' } });
  ok(await ev('!window.ssDaw.lanes[0][0].fi') && (await text('.dmsg')).includes('Not changed'), 'a refusal leaves the item as it was');
  await drag(x0 + 3, y, t2, y + 1);
  a = lastAction();
  let c0 = project().dawc0;
  c0.tr[0][0].fi = 2;
  await push({ dawedit: { id: a.edit.id, ok: true }, dawc0: c0 });
  await sleep(100);
  ok(await ev('window.ssDaw.lanes[0][0].fi === 2'), 'its chunk comes back with the fade');
  await drag(x8 - 3, y, t6, y + 1); // the fade-out handle: the top-right corner
  a = lastAction();
  ok(a.edit.op === 'fade' && a.edit.side === 'out' && Math.abs(a.edit.len - 2) < 1e-6, 'the top-right corner sends a fade out (' + JSON.stringify(a.edit) + ')');
  c0.tr[0][0].fo = 2;
  await push({ dawedit: { id: a.edit.id, ok: true }, dawc0: c0 });
  await sleep(100);
  // the shape boxes show and set the shapes
  await click(...(await at(4, 0)));
  const n = edits().length;
  await ev('(() => { const s = document.querySelector("select[aria-label=\\"Fade in shape\\"]"); s.value = "3"; s.dispatchEvent(new Event("change")); })()');
  await sleep(100);
  a = lastAction();
  ok(edits().length === n + 1 && a.edit.op === 'fade' && a.edit.side === 'in' && a.edit.shape === 3 && a.edit.len === undefined, 'a shape box sends the shape alone (' + JSON.stringify(a.edit) + ')');
  c0.tr[0][0].fis = 3;
  await push({ dawedit: { id: a.edit.id, ok: true }, dawc0: c0 });
  await sleep(100);
  ok(await ev('document.querySelector("select[aria-label=\\"Fade in shape\\"]").value') === '3' && await ev('document.querySelector("select[aria-label=\\"Fade out shape\\"]").value') === '0', 'and they show what the item has');
  // a click in the middle still selects and drag still moves (the corner is only the corner)
  await drag(...(await at(4, 0)), ...(await at(5, 0)));
  a = lastAction();
  ok(a.edit.op === 'move' && Math.abs(a.edit.to - 1) < 1e-6, 'the middle still moves the item (' + JSON.stringify(a.edit) + ')');
  await push({ dawedit: { id: a.edit.id, why: 'again' } });
  state.topics = project();
  await push(project());
}

// ---- sends ----------------------------------------------------------------------------------------------------------------------------
{
  const panelOpen = () => ev('(() => { const p = document.querySelector(".dsends"); return !!p && !p.hidden; })()');
  const lastLook = () => [...actions].reverse().find((a) => a.look && a.look.send !== undefined);
  ok(!(await panelOpen()), 'the sends panel starts closed');
  await click(...(await at(40, 2))); // (an empty spot: nothing selected)
  ok((await button('Sends')).disabled, 'Sends is off with nothing selected');
  await click(...(await at(14, 1))); // Bass's item
  let b = await button('Sends');
  ok(!b.disabled, 'Sends is on with an item selected');
  await click(b.x, b.y);
  ok(await panelOpen() && (await text('.dsends .stitle')) === 'Sends from Bass', 'it opens for the item’s track');
  await sleep(100);
  ok(lastLook() && lastLook().look.send === 1, 'and says it is looking at that track (' + JSON.stringify(lastLook() && lastLook().look) + ')');
  ok((await text('.dsends .slist')).includes('Loading'), 'until the sends come');
  const sendTopic = (extra) => Object.assign({ key: KEY, lane: 1, name: 'Bass', sends: [{ i: 0, to: 2, n: 'Keys', v: 1, p: 0 }, { i: 1, to: 0, n: 'Drums', v: 0.5, p: -0.25, m: 1 }] }, extra || {});
  await push({ dawsend: sendTopic() });
  await sleep(100);
  ok(await ev('document.querySelectorAll(".dsends .srow").length') === 2, 'a row a send');
  ok((await text('.dsends .srow:nth-child(2) .sval')).startsWith('-6.0 dB') && (await text('.dsends .srow:nth-child(2) .smute input')) === '' &&
    await ev('document.querySelector(".dsends .srow:nth-child(2) .smute input").checked') === true && (await ev('document.querySelectorAll(".dsends .sval")[3].textContent')) === '25% left', 'their level, mute and pan as published');
  ok(await ev('document.querySelector(".dsends .srow .sval").textContent') === '0.0 dB', 'unity reads 0.0 dB');
  // the level: a change event sends the value, linear (-6.0 dB here)
  const setRange = (row, n, v) => ev('(() => { const r = document.querySelectorAll(".dsends .srow")[' + row + '].querySelectorAll("input[type=range]")[' + n + ']; r.value = "' + v + '"; r.dispatchEvent(new Event("input")); r.dispatchEvent(new Event("change")); })()');
  await setRange(0, 0, -60);
  await sleep(100);
  let a = lastAction();
  ok(a.send && a.send.op === 'vol' && a.send.lane === 1 && a.send.to === 2 && a.send.i === 0 && Math.abs(a.send.v - Math.pow(10, -0.3)) < 1e-9 && /^[\w-]+$/.test(a.send.id), 'a level change sends vol for that send (' + JSON.stringify(a.send) + ')');
  await push({ dawedit: { id: a.send.id, why: 'Chilio has claimed Keys there' } });
  ok((await text('.dmsg')).includes('Not changed: Chilio has claimed Keys there') && await ev('document.querySelectorAll(".dsends .srow")[0].querySelector("input[type=range]").value') === '0', 'a refusal says why and puts the slider back');
  await setRange(0, 0, -600);
  await sleep(100);
  a = lastAction();
  ok(a.send.op === 'vol' && a.send.v === 0, 'the far left is off (0)');
  await setRange(1, 1, 50);
  await sleep(100);
  a = lastAction();
  ok(a.send.op === 'pan' && a.send.i === 1 && a.send.to === 0 && a.send.p === 0.5, 'pan sends -1 to 1 (' + JSON.stringify(a.send) + ')');
  await ev('(() => { const c = document.querySelectorAll(".dsends .srow")[0].querySelector("input[type=checkbox]"); c.checked = true; c.dispatchEvent(new Event("change")); })()');
  await sleep(100);
  a = lastAction();
  ok(a.send.op === 'mute' && a.send.on === true && a.send.i === 0, 'mute');
  await ev('[...document.querySelectorAll(".dsends .srow")[1].querySelectorAll("button")].find((x) => x.textContent === "Remove").click(); 1');
  await sleep(100);
  a = lastAction();
  ok(a.send.op === 'remove' && a.send.i === 1 && a.send.to === 0, 'remove');
  // the add list leaves out the track itself
  ok(await ev('[...document.querySelectorAll(".dsends select option")].map((o) => o.textContent).join(",")') === 'Drums,Keys', 'the add list is every other track');
  await ev('(() => { const s = document.querySelector(".dsends select"); s.value = "2"; })()');
  await ev('[...document.querySelectorAll(".dsends button")].find((x) => x.textContent === "Add send").click(); 1');
  await sleep(100);
  a = lastAction();
  ok(a.send.op === 'add' && a.send.lane === 1 && a.send.to === 2 && a.send.i === undefined, 'add sends the destination (' + JSON.stringify(a.send) + ')');
  // a send changed under the panel: updated in place, not rebuilt (a hand on a slider keeps it)
  await push({ dawedit: { id: a.send.id, ok: true }, dawsend: sendTopic({ sends: [{ i: 0, to: 2, n: 'Keys', v: 2, p: 0 }, { i: 1, to: 0, n: 'Drums', v: 0.5, p: -0.25, m: 1 }] }) });
  await sleep(100);
  ok((await ev('document.querySelectorAll(".dsends .sval")[0].textContent')) === '+6.0 dB', 'a new level shows');
  // the right-click menu on a track's name
  const [hx, hy] = await ev('(() => { const r = document.querySelector(".dcv").getBoundingClientRect(), D = window.ssDaw; return [r.left + 30, r.top + D.laneY(0) + 20]; })()');
  await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: hx, y: hy, button: 'right', buttons: 2, clickCount: 1 });
  await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: hx, y: hy, button: 'right', buttons: 0, clickCount: 1 });
  await sleep(100);
  ok((await ev('[...document.querySelectorAll(".dmenu button")].map((x) => x.textContent)')).includes('Sends…'), 'a track’s name has Sends… in its menu');
  await ev('[...document.querySelectorAll(".dmenu button")].find((x) => x.textContent === "Sends…").click(); 1');
  await sleep(100);
  ok((await text('.dsends .stitle')) === 'Sends from Drums' && lastLook().look.send === 0, 'it opens that track’s');
  await ev('[...document.querySelectorAll(".dsends button")].find((x) => x.textContent === "Close").click(); 1');
  await sleep(100);
  ok(!(await panelOpen()) && lastLook().look.send === false, 'Close says it stopped looking');
  state.topics = project();
  await push(project());
}

ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
