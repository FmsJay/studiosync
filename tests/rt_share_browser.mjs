// The screen share's pointer, control, pop-out and "Show its window" (rt-share, docs/rt/rt-share.md), in headless Chromium:
//   node tests/rt_share_browser.mjs          (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The real lib/webui/call.js runs in two pages, A (James, sharing) and B (chilio, watching), each its own stand-in computer: this server
// relays the "rtc" messages between them as lib/webcall.lua would, and answers A's POST api/input as the extension would (a stand-in of
// extension/remotectl.cpp's policy: the share, status with the pointer, grant, stop, and a log of every input). A's screen is a drawn canvas
// (getDisplayMedia replaced in the page), never this computer's; the microphone is Chromium's fake device. Nothing reaches REAPER, the
// network or a real device: its own Chrome profile in a temp folder, a random localhost port.
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

// ---- two stand-in computers ---------------------------------------------------------------------------------------------------------------
const devOf = (c) => (c.repeat(7) + '-').repeat(7) + c.repeat(7);
const node = (user, dev, host) => ({ user, dev, host, seq: 0, msgs: [], open: {}, actions: [], answers: [], fxwin: null });
const A = node('James', devOf('A'), 'james-main'), B = node('chilio', devOf('B'), 'chilio-pc');
const other = (n) => (n === A ? B : A);
const now = () => Date.now() / 1000;
function push(n, m) { n.seq++; n.msgs.push(Object.assign({}, m, { seq: n.seq, time: now() })); if (n.msgs.length > 16) n.msgs.shift(); }
function rtc(n) {
  const t = now();
  return { boot: '1', me: { user: n.user, dev: n.dev }, open: Object.entries(n.open).filter(([, o]) => t - o.at < 25).map(([dev, o]) => ({ user: o.user, dev, host: o.host })),
    msgs: n.msgs.filter((m) => t - m.time < 30), answers: n.answers.length ? n.answers : undefined, fxwin: n.fxwin || undefined };
}
// the extension's side of api/input on A (a stand-in of remotectl.cpp's policy)
const ext = { area: null, can: false, on: false, who: '', why: '', cur: null, log: [] };
function input(m) {
  ext.log.push(m);
  if (m.t === 'share') { if (!ext.area || ext.area.target !== m.target || ext.area.track !== m.track) { ext.on = false; ext.who = ''; } ext.area = m; ext.can = m.target !== 'monitor'; }
  else if (m.t === 'unshare') { ext.area = null; ext.can = false; ext.on = false; ext.who = ''; }
  else if (m.t === 'grant') { if (ext.can) { ext.on = true; ext.who = m.who; ext.why = ''; } else ext.why = 'nothing is shared'; }
  else if (m.t === 'stop') { if (ext.on) ext.why = 'you took control back'; ext.on = false; ext.who = ''; }
  return { sys: true, area: !!ext.area, can: ext.can, on: ext.on, who: ext.who, why: ext.why, cur: ext.area && ext.cur ? ext.cur : null };
}
const inputs = () => ext.log.filter((m) => /^(move|down|up|wheel|key)$/.test(m.t));

const page = (n) => '<!doctype html><meta charset="utf-8"><title>' + n.user + '</title><link rel="stylesheet" href="style.css"><link rel="stylesheet" href="call.css">' +
  '<script>try { localStorage.setItem("ss-share-sound", "none"); } catch (e) {}' + // (no REAPER mix in this stand-in)
  // A's screen: a drawn canvas, said to be a window (or what the page asked the picker for)
  'navigator.mediaDevices.getDisplayMedia = async (c) => { window.__gdm = (window.__gdm || 0) + 1; const cv = document.createElement("canvas"); cv.width = 960; cv.height = 540;' +
  ' const g = cv.getContext("2d"); let k = 0; setInterval(() => { g.fillStyle = "#234"; g.fillRect(0, 0, 960, 540); g.fillStyle = "#fc0"; g.fillRect((k++ * 9) % 900, 240, 60, 60); }, 40);' +
  ' const st = cv.captureStream(15), t = st.getVideoTracks()[0], gs = t.getSettings.bind(t); t.getSettings = () => Object.assign(gs(), { displaySurface: "window" }); return st; };' +
  // what app.js would do: the state, as the ss-state event
  'setInterval(() => fetch("api/state").then((r) => r.json()).then((s) => dispatchEvent(new CustomEvent("ss-state", { detail: s }))).catch(() => {}), 100);</script>' +
  '<div id="sharebar" role="status" hidden></div><section id="call" hidden></section><script src="anchor.js"></script><script src="call.js"></script>';

const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x'), parts = u.pathname.split('/'), n = parts[1] === 'a' ? A : parts[1] === 'b' ? B : null, rest = '/' + parts.slice(2).join('/');
  const json = (o, code = 200) => { res.statusCode = code; res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(o)); };
  if (!n) { res.statusCode = 404; return res.end(); }
  if (rest === '/' || rest === '/index.html') { res.setHeader('Content-Type', 'text/html'); return res.end(page(n)); }
  if (rest === '/api/state') return json({ engine: true, topics: { rtc: rtc(n) } });
  if (rest === '/api/mix') { res.statusCode = 503; return res.end(); }
  if (req.method === 'POST' && (rest === '/api/action' || rest === '/api/input')) {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      if (req.headers['x-studiosync'] !== '1') return json({}, 403);
      let a;
      try { a = JSON.parse(body); } catch (e) { return json({}, 400); }
      if (rest === '/api/input') return n === A ? json(input(a)) : json({}, 404);
      n.actions.push(a);
      if (a.topic === 'rtc') {
        const o = other(n);
        if (a.t === 'here') o.open[n.dev] = { user: n.user, host: n.host, at: now() };
        else if (['offer', 'answer', 'bye', 'busy', 'ask'].includes(a.t)) {
          const m = {};
          for (const k of ['t', 'call', 'kind', 'audio', 'sdp', 're', 'what', 'token', 'fx']) if (k in a) m[k] = a[k];
          push(o, Object.assign(m, { user: n.user, dev: n.dev }));
          push(n, { t: a.t, call: a.call, to: a.to, out: true });
        } else if (a.t === 'fxwin' && a.token === 77) n.fxwin = [{ token: 77, track: '{0A1B2C3D-0000-0000-0000-000000000000}', fxi: 1, fx: 'VST3: Serum (Xfer)' }];
      }
      json({ ok: true }, 202);
    });
    return;
  }
  const f = path.join(root, path.basename(rest));
  if (fs.existsSync(f)) { res.setHeader('Content-Type', types[path.extname(f)] || 'application/octet-stream'); return res.end(fs.readFileSync(f)); }
  res.statusCode = 404; res.end();
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = 'http://127.0.0.1:' + server.address().port;

// ---- Chrome over the DevTools protocol (Node's own WebSocket, no packages) ----------------------------------------------------------------
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-share-chrome-'));
const proc = spawn(chrome, ['--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + prof, '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--autoplay-policy=no-user-gesture-required',
  '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', // (two pages at once: neither is put to sleep)
  '--window-size=1100,800', 'about:blank'], { stdio: 'ignore' });
let fails = 0;
const done = async (code) => { try { proc.kill(); } catch (e) {} server.close(); await new Promise((r) => setTimeout(r, 300)); try { fs.rmSync(prof, { recursive: true, force: true }); } catch (e) {} process.exit(code); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
process.on('uncaughtException', (e) => { console.log('FAIL the driver stopped: ' + (e && e.message)); done(1); });
let port = 0;
for (let i = 0; i < 100 && !port; i++) { await sleep(100); try { port = parseInt(fs.readFileSync(path.join(prof, 'DevToolsActivePort'), 'utf8').split('\n')[0], 10); } catch (e) {} }
if (!port) { console.log('FAIL Chrome did not start'); await done(1); }
const errors = [];
async function attach(url) {
  const t = await (await fetch('http://127.0.0.1:' + port + '/json/new?' + encodeURI(url), { method: 'PUT' })).json();
  return connect(t);
}
async function connect(t) {
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((r) => { ws.onopen = r; });
  let nid = 0;
  const wait = new Map();
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
    else if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails.exception ? d.params.exceptionDetails.exception.description : d.params.exceptionDetails.text);
  };
  const cdp = (method, params = {}) => new Promise((r) => { const id = ++nid; wait.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
  const ev = async (js) => {
    const r = await cdp('Runtime.evaluate', { expression: js, awaitPromise: true, returnByValue: true, userGesture: true });
    if (r.result.exceptionDetails) throw new Error('page: ' + JSON.stringify(r.result.exceptionDetails.exception || r.result.exceptionDetails));
    return r.result.result.value;
  };
  await cdp('Runtime.enable');
  return { id: t.id, cdp, ev, ws };
}
const ok = (c, m) => { if (!c) { fails++; console.log('FAIL ' + m); } else console.log('  ok ' + m); };
async function until(fn, ms = 20000) { const t = Date.now() + ms; for (;;) { const v = await fn(); if (v || Date.now() > t) return v; await sleep(100); } }
// a button by its words (in rings, the bar or the board), clicked as a real mouse click
async function press(p, label, scope = 'body') {
  const xy = await p.ev('(() => { const b = [...document.querySelectorAll(' + JSON.stringify(scope + ' button') + ')].find((x) => x.textContent === ' + JSON.stringify(label) +
    ' && !x.hidden && x.offsetParent); if (!b) return null; b.scrollIntoView({ block: "center" }); const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, off: b.disabled }; })()');
  if (!xy || xy.off) return false;
  await p.cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: xy.x, y: xy.y, button: 'left', buttons: 1, clickCount: 1 });
  await p.cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: xy.x, y: xy.y, button: 'left', buttons: 0, clickCount: 1 });
  await sleep(80);
  return true;
}
const has = (p, label, scope = 'body') => p.ev('!![...document.querySelectorAll(' + JSON.stringify(scope + ' button') + ')].find((x) => x.textContent === ' + JSON.stringify(label) + ' && !x.hidden && x.offsetParent && !x.disabled)');
const text = (p, sel) => p.ev('(document.querySelector(' + JSON.stringify(sel) + ') || {}).textContent || ""');
// a place on B's watched picture (0-1) -> the viewport
const onPic = (p, x, y) => p.ev('(() => { const s = [...window.ssCallTest.state().sessions.values()].find((s) => s.kind === "screen" && s.role === "callee" && s.tile); if (!s) return null;' +
  ' const v = s.tile.video, r = v.getBoundingClientRect(), k = Math.min(r.width / v.videoWidth, r.height / v.videoHeight), w = v.videoWidth * k, h = v.videoHeight * k;' +
  ' return { x: r.left + (r.width - w) / 2 + ' + x + ' * w, y: r.top + (r.height - h) / 2 + ' + y + ' * h }; })()');
const bSession = (p) => p.ev('(() => { const s = [...window.ssCallTest.state().sessions.values()].find((s) => s.kind === "screen" && s.role === "callee"); return s ? { id: s.id, state: s.state, cur: s.cur || null, ctl: s.ctl || null, tile: !!s.tile } : null; })()');
const close = (a, b) => Math.abs(a - b) < 0.02;

const pa = await attach(base + '/a/'), pb = await attach(base + '/b/');
await sleep(500);
// (the fake microphone allowed once in each page first: a background tab's first ask otherwise waits, and the call's address step asks)
for (const p of [pa, pb]) await p.ev('navigator.mediaDevices.getUserMedia({ audio: true }).then((s) => { s.getTracks().forEach((t) => t.stop()); return 1; })');
ok(await until(() => pa.ev('[...document.querySelectorAll(".call-people .name")].some((x) => x.textContent === "chilio")')), 'A sees chilio’s page open');
ok(await until(() => pb.ev('[...document.querySelectorAll(".call-people .name")].some((x) => x.textContent === "James")')), 'B sees James’s');

// ---- a share, its pointer ---------------------------------------------------------------------------------------------------------------
await press(pa, 'Share screen', '.call-people');
// (each page's first RTCPeerConnection took ~9 s here: Chrome lists the network adapters, Tailscale's and VMware's among them)
ok(await until(() => has(pb, 'Watch', '.ring'), 40000), 'B is asked to watch');
await press(pb, 'Watch', '.ring');
ok(await until(async () => { const s = await bSession(pb); return s && s.state === 'live' && s.tile; }, 40000), 'B watches A’s screen');
ok(await until(() => ext.log.some((m) => m.t === 'share' && m.target === 'reaper' && m.pw === 960 && m.ph === 540)), 'A tells its extension a window is shared, the picture 960x540');
ok(await until(() => ext.log.filter((m) => m.t === 'status').length > 10, 3000), 'A asks its extension every 50 ms meanwhile');
ext.cur = [0.25, 0.5];
ok(await until(async () => { const s = await bSession(pb); return s.cur && close(s.cur.x, 0.25) && close(s.cur.y, 0.5); }), 'B gets the sharer’s pointer, 0-1 of the picture');
ext.cur = null;
ok(await until(async () => (await bSession(pb)).cur === null), 'and none when it leaves the shared window');
ext.cur = [0.6, 0.4];

// ---- asking for control --------------------------------------------------------------------------------------------------------------------
ok(await until(() => has(pb, 'Ask for control', '.board-bar')), 'B may ask for control (a REAPER window is shared)');
ok(!(await until(() => has(pb, 'Stop controlling', '.board-bar'), 300)), 'and isn’t in control yet');
await press(pb, 'Ask for control', '.board-bar');
ok(await until(() => has(pa, 'Allow', '.ring')), 'A is asked: Allow / Deny');
ok(await until(() => A.actions.some((a) => a.topic === 'rtc' && a.t === 'ctlask' && a.user === 'chilio' && a.on === true)), 'and A’s Live sync is told, for the panel’s bar');
ok(inputs().length === 0 && !ext.log.some((m) => m.t === 'grant'), 'nothing granted before the yes');
await press(pa, 'Allow', '.ring');
ok(await until(() => ext.log.some((m) => m.t === 'grant' && m.who === 'chilio')), 'Allow: A’s extension grants chilio');
ok(await until(async () => { const s = await bSession(pb); return s.ctl && s.ctl.you; }), 'B is in control');
ok(await pb.ev('!!document.querySelector(".tile.in-control")'), 'B’s picture is outlined');
ok(await until(async () => (await text(pa, '#sharebar')).includes('chilio is in control')), 'A’s bar says who is in control');
ok(await has(pa, 'Take back', '#sharebar'), 'with Take back');
ok(A.actions.some((a) => a.t === 'ctlask' && a.on === false), 'the bar’s ask is taken off');
// B's mouse, wheel and keys reach A's extension, as places in the picture
let xy = await onPic(pb, 0.5, 0.5);
await pb.cdp('Input.dispatchMouseEvent', { type: 'mouseMoved', x: xy.x, y: xy.y });
await pb.cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: xy.x, y: xy.y, button: 'left', buttons: 1, clickCount: 1 });
await pb.cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: xy.x, y: xy.y, button: 'left', buttons: 0, clickCount: 1 });
ok(await until(() => inputs().some((m) => m.t === 'down' && m.b === 0 && close(m.x, 0.5) && close(m.y, 0.5)) && inputs().some((m) => m.t === 'up' && m.b === 0)), 'a click in the middle: down and up at 0.5, 0.5');
const xy2 = await onPic(pb, 0.75, 0.25);
for (let i = 1; i <= 10; i++) await pb.cdp('Input.dispatchMouseEvent', { type: 'mouseMoved', x: xy.x + (xy2.x - xy.x) * i / 10, y: xy.y + (xy2.y - xy.y) * i / 10 });
ok(await until(() => inputs().some((m) => m.t === 'move' && close(m.x, 0.75) && close(m.y, 0.25))), 'moves follow, to 0.75, 0.25');
await pb.cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: xy2.x, y: xy2.y, button: 'right', buttons: 2, clickCount: 1 });
await pb.cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: xy2.x, y: xy2.y, button: 'right', buttons: 0, clickCount: 1 });
ok(await until(() => inputs().some((m) => m.t === 'down' && m.b === 2)), 'a right click');
await pb.cdp('Input.dispatchMouseEvent', { type: 'mouseWheel', x: xy2.x, y: xy2.y, deltaX: 0, deltaY: 100 });
ok(await until(() => inputs().some((m) => m.t === 'wheel' && m.dy === 100)), 'the wheel');
await pb.cdp('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, text: 'a' });
await pb.cdp('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65 });
ok(await until(() => inputs().some((m) => m.t === 'key' && m.code === 'KeyA' && m.down === true) && inputs().some((m) => m.t === 'key' && m.code === 'KeyA' && m.down === false)), 'a key, by its place');
const moves = inputs().filter((m) => m.t === 'move').length;
ok(moves <= 11, 'moves are merged and paced (' + moves + ' for 10)');
// A takes it back (its extension says so: its own mouse moved)
ext.on = false; ext.who = ''; ext.why = 'you moved your mouse';
ok(await until(async () => { const s = await bSession(pb); return s.ctl && !s.ctl.you && !s.ctl.on; }), 'control back with A: B is told');
ok(await until(async () => !(await text(pa, '#sharebar')).includes('in control')), 'A’s bar no longer says anyone is');
ok(await until(async () => (await text(pa, '.call-note')).includes('Control came back to you: you moved your mouse')), 'A’s page says why');
const n0 = inputs().length;
await pb.cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: xy.x, y: xy.y, button: 'left', buttons: 1, clickCount: 1 });
await pb.cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: xy.x, y: xy.y, button: 'left', buttons: 0, clickCount: 1 });
await sleep(400);
ok(inputs().length === n0, 'after that, B’s clicks go nowhere (they point, as before)');
// Deny, and the panel's bar's yes
await press(pb, 'Ask for control', '.board-bar');
ok(await until(() => has(pa, 'Deny', '.ring')), 'asked again');
await press(pa, 'Deny', '.ring');
ok(await until(async () => (await text(pb, '.call-note')).includes('James said no')), 'Deny: B is told no');
ok(!ext.on, 'and nothing was granted');
await press(pb, 'Ask for control', '.board-bar');
ok(await until(() => has(pa, 'Allow', '.ring')), 'asked a third time');
const aid = await pa.ev('[...window.ssCallTest.state().sessions.values()].find((s) => s.asking).askId');
ok(A.actions.some((a) => a.t === 'ctlask' && a.call === aid && a.on === true), 'the bar is told this ask, by its own id');
A.answers = [{ call: A.actions.filter((a) => a.t === 'ctlask' && a.call !== aid)[0].call, yes: true, seq: 1, time: now() }];
await sleep(600);
ok(!ext.on, 'a yes to an earlier ask doesn’t answer this one');
A.answers = [{ call: aid, yes: true, seq: 2, time: now() }];
ok(await until(() => ext.on && ext.who === 'chilio'), 'the panel’s Allow (through Live sync’s model) grants it too');
ok(await until(async () => (await bSession(pb)).ctl.you), 'B is in control again');
A.answers = [];
await press(pb, 'Stop controlling', '.board-bar');
ok(await until(() => !ext.on && ext.log.some((m) => m.t === 'stop')), 'B’s Stop controlling hands it back');

// ---- pop out and back ---------------------------------------------------------------------------------------------------------------------
ok(await has(pb, 'Full screen', '.board-bar'), 'Full screen is there');
await press(pb, 'Pop out', '.board-bar');
let popT = null;
for (let i = 0; i < 40 && !popT; i++) { await sleep(150); popT = (await (await fetch('http://127.0.0.1:' + port + '/json/list')).json()).find((t) => t.type === 'page' && t.url.includes('pop=share')); }
ok(!!popT, 'Pop out opens its own window (?pop=share)');
if (popT) {
  const pp = await connect(popT);
  ok(await until(() => pp.ev('!!document.querySelector(".pop-share .tile video") && document.documentElement.classList.contains("ss-pop-share")')), 'the share moved there');
  ok(await until(() => pb.ev('!document.querySelector(".call-big .tile")')), 'and out of the main page');
  ok(await pp.ev('[...document.querySelectorAll(".pop-share .board-bar button")].some((b) => b.textContent === "Ask for control")'), 'with its tools');
  await (await fetch('http://127.0.0.1:' + port + '/json/close/' + popT.id)).text();
  ok(await until(() => pb.ev('!!document.querySelector(".call-big .tile video")')), 'closing it brings the share back');
}

// ---- Show its window (the Try tab's button) ------------------------------------------------------------------------------------------------
await press(pa, 'Stop', '#sharebar');
ok(await until(() => ext.log.some((m) => m.t === 'unshare')), 'Stop: the extension is told the share ended');
ok(await until(async () => !(await bSession(pb))), 'B’s watching ends');
ok(await pb.ev('window.ssShare && window.ssShare.canWatch === true'), 'the Try tab can offer Show its window');
await pb.ev('window.ssShare.askWindow({ user: "James", token: 77, fx: "Serum" }); 1');
ok(await until(() => has(pa, 'Show it', '.ring')), 'A is asked to show its Serum window');
ok((await text(pa, '.ring')).includes('asks to see your Serum window'), 'saying which');
const g0 = await pa.ev('window.__gdm');
await press(pa, 'Show it', '.ring');
ok(await until(() => A.actions.some((a) => a.t === 'fxwin' && a.token === 77)), 'Show it: A’s Live sync opens the plug-in’s window');
ok(await until(async () => (await pa.ev('window.__gdm')) === g0 + 1), 'and the browser asks which window to share');
ok(await until(async () => { const s = await bSession(pb); return s && s.state === 'live' && s.tile; }, 15000), 'B watches it at once (it asked: no Watch to press)');
ok(await until(() => ext.log.some((m) => m.t === 'share' && m.target === 'fx' && m.track === '{0A1B2C3D-0000-0000-0000-000000000000}' && m.fxi === 1)), 'A’s extension is told it’s that plug-in’s window');
ok((await text(pa, '#sharebar')).includes('You’re sharing your Serum window'), 'A’s bar says what it shares');
ok(await until(() => has(pb, 'Ask for control', '.board-bar')), 'and B can ask for control of it, the same way');
await press(pa, 'Stop', '#sharebar');
await until(async () => !(await bSession(pb)));
await pb.ev('window.ssShare.askWindow({ user: "James", token: 77, fx: "Serum" }); 1');
ok(await until(() => has(pa, 'No thanks', '.ring')), 'asked again');
await press(pa, 'No thanks', '.ring');
ok(await until(async () => (await text(pb, '.call-note')).includes('James said no to showing Serum’s window')), 'No thanks: B is told');
await pb.ev('window.ssShare.askWindow({ user: "Nobody", token: 77, fx: "Serum" }); 1');
ok((await text(pb, '.call-note')).includes('isn’t open'), 'asking someone whose page isn’t open says so');

ok(!errors.length, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
