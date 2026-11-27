// Chat and pop-outs, web side (rt-ui9: docs/rt/ui-web-plan.md Phase 9, 4.4), driven in headless Chromium against a stand-in server:
//   node tests/rt_ui9_browser.mjs            (not part of tests/run.py: it needs Chrome or Edge; prints "ok" last, or FAIL and a non-zero exit)
// The real lib/webui/index.html with every real page file, served from lib/webui with stand-in topics over /api/events (as the extension
// sends them); the actions pages POST are recorded, and the "rtc" ones a page here sends come back to this computer's pages as the
// extension's out-echo would. Several pages of one Chrome at once (the main window, ?pop=chat, ?pop=call), as REAPER's main window and its
// pop-outs share one browser: read once per newest message, Notes and Likes in All, the top bar's call controls (live audio's Mute and
// Deafen, the ring, the call held in another window), one call per computer over the channel, Pop out where it can work. Nothing reaches
// REAPER or the network: its own Chrome profile in a temp folder, a random localhost port, Chromium's fake camera and microphone only.
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
const ME = 'a'.repeat(16), CHILIO = 'c'.repeat(16);
const iso = (s) => new Date(Date.now() - s * 1000).toISOString().replace(/\.\d+Z$/, 'Z');
let seq = 0;
const rtcMsgs = [];
const rtc = (o = {}) => Object.assign({ boot: '1', me: { user: 'James-Main', dev: ME }, open: [{ user: 'chilio', dev: CHILIO, host: 'chilio-pc' }], msgs: rtcMsgs.slice(-16) }, o);
let rtcExtra = { live: true, la: {} };
let state = { engine: true, topics: {
  env: { v: 1, studio: 'Chilio', front: { name: 'Cross Test.rpp', project: 'Cross Test', room: 'main', live: true, shared: true } },
  presence: { song: 'Cross Test', room: 'main', people: [{ user: 'James-Main', me: true, armed: [] }], claims: [] },
  chat: { scope: 'song', msgs: [{ id: 'm1', user: 'chilio', text: 'hi from chilio', time: iso(60) }], todo: [], links: [] },
  chat_index: { me: 'James-Main', people: ['chilio'], convs: [{ scope: 'song', n: 1 }], total: 1 },
  rtc: rtc(rtcExtra) } };
const clients = new Set();
const actions = [];
const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.svg': 'image/svg+xml', '.png': 'image/png' };
const send = (topics) => { for (const c of clients) c.write('data: ' + JSON.stringify({ engine: state.engine, topics }) + '\n\n'); };
const pushRtc = () => { state.topics.rtc = rtc(rtcExtra); send({ rtc: state.topics.rtc }); };
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
    req.on('end', () => {
      let a = null;
      try { a = JSON.parse(b); } catch (e) { a = { bad: b }; }
      actions.push(a);
      // (what a page here sent to a bandmate comes back to this computer's pages, no SDP: lib/webcall.lua's out-echo)
      if (a.topic === 'rtc' && ['offer', 'answer', 'bye', 'busy'].includes(a.t)) { rtcMsgs.push({ t: a.t, call: a.call, to: a.to, out: true, seq: ++seq }); pushRtc(); }
      res.setHeader('Content-Type', 'application/json'); res.end('{}');
    });
    return;
  }
  const f = path.join(root, u.pathname === '/' ? 'index.html' : path.basename(u.pathname));
  if (fs.existsSync(f)) { res.setHeader('Content-Type', types[path.extname(f)] || 'application/octet-stream'); return res.end(fs.readFileSync(f)); }
  res.statusCode = 404; res.end();
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const LOCAL = 'http://127.0.0.1:' + server.address().port + '/';
const push = async (topics) => { Object.assign(state.topics, topics); send(topics); await sleep(250); };

// ---- Chrome over the DevTools protocol (Node's own WebSocket, no packages) -----------------------------------------------------------------
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'rt-ui9-chrome-'));
const proc = spawn(chrome, ['--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + prof, '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--autoplay-policy=no-user-gesture-required',
  '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', // (several pages at once: none is put to sleep)
  '--window-size=1100,760', 'about:blank'], { stdio: 'ignore' });
let fails = 0;
const done = async (code) => { try { proc.kill(); } catch (e) {} for (const c of clients) c.end(); server.close(); await new Promise((r) => setTimeout(r, 300)); try { fs.rmSync(prof, { recursive: true, force: true }); } catch (e) {} process.exit(code); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
process.on('uncaughtException', (e) => { console.log('FAIL the driver stopped: ' + (e && e.message)); done(1); });
let port = 0;
for (let i = 0; i < 100 && !port; i++) { await sleep(100); try { port = parseInt(fs.readFileSync(path.join(prof, 'DevToolsActivePort'), 'utf8').split('\n')[0], 10); } catch (e) {} }
if (!port) { console.log('FAIL Chrome did not start'); await done(1); }
const errors = [];
// a page of its own (a tab of the same Chrome, so the pages share one BroadcastChannel space as REAPER's windows do); reaper: a stand-in
// WebView2 channel recording what the page sends
async function page(url, o = {}) {
  const t = await (await fetch('http://127.0.0.1:' + port + '/json/new?about:blank', { method: 'PUT' })).json();
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((r) => { ws.onopen = r; });
  let nid = 0;
  const wait = new Map();
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
    else if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails.exception ? d.params.exceptionDetails.exception.description : d.params.exceptionDetails.text);
    else if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') errors.push(d.params.args.map((a) => a.value || a.description).join(' '));
  };
  const cdp = (method, params = {}) => new Promise((r) => { const id = ++nid; wait.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
  const ev = async (js) => {
    const r = await cdp('Runtime.evaluate', { expression: js, awaitPromise: true, returnByValue: true, userGesture: true });
    if (r.result.exceptionDetails) throw new Error('page: ' + JSON.stringify(r.result.exceptionDetails.exception || r.result.exceptionDetails));
    return r.result.result.value;
  };
  await cdp('Runtime.enable');
  await cdp('Page.enable');
  await cdp('Emulation.setDeviceMetricsOverride', { width: o.w || 1100, height: o.h || 760, deviceScaleFactor: 1, mobile: false });
  if (o.reaper) await cdp('Page.addScriptToEvaluateOnNewDocument', { source:
    'window.__sent = []; window.__ls = []; window.chrome = window.chrome || {}; window.chrome.webview = { postMessage: (m) => window.__sent.push(m), ' +
    'addEventListener: (t, f) => { if (t === "message") window.__ls.push(f); } };' });
  await cdp('Page.navigate', { url });
  for (let i = 0; i < 80; i++) { await sleep(100); try { if (await ev('document.readyState === "complete" && !!window.ssTabs && !!window.ssCallTest && !!window.ssCallTest.state().pid')) break; } catch (e) {} }
  await sleep(500);
  const p = { id: t.id, cdp, ev, ws };
  // a button by its words inside a part of the page, clicked as a real mouse click
  p.press = async (label, scope = 'body') => {
    const xy = await ev('(() => { const b = [...document.querySelectorAll(' + JSON.stringify(scope + ' button') + ')].find((x) => x.textContent === ' + JSON.stringify(label) +
      ' && !x.hidden && x.offsetParent); if (!b) return null; b.scrollIntoView({ block: "center" }); const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, off: b.disabled }; })()');
    if (!xy || xy.off) return false;
    await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: xy.x, y: xy.y, button: 'left', buttons: 1, clickCount: 1 });
    await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: xy.x, y: xy.y, button: 'left', buttons: 0, clickCount: 1 });
    await sleep(120);
    return true;
  };
  p.has = (label, scope = 'body') => ev('[...document.querySelectorAll(' + JSON.stringify(scope + ' button') + ')].some((x) => x.textContent === ' + JSON.stringify(label) + ' && !x.hidden && !!x.offsetParent)');
  p.text = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return e ? e.textContent : ""; })()');
  p.visible = (sel) => ev('(() => { const e = document.querySelector(' + JSON.stringify(sel) + '); return !!e && e.getClientRects().length > 0; })()');
  p.close = async () => { await (await fetch('http://127.0.0.1:' + port + '/json/close/' + t.id)).text(); ws.close(); };
  return p;
}
const ok = (c, m) => { if (!c) { fails++; console.log('FAIL ' + m); } else console.log('  ok ' + m); };
async function until(fn, ms = 6000) { const t = Date.now() + ms; for (;;) { const v = await fn(); if (v || Date.now() > t) return v; await sleep(100); } }
const count = (f) => actions.filter(f).length;

// ---- the main window: Chat, read once per newest message ------------------------------------------------------------------------------------
const main = await page(LOCAL + '#chat');
ok(await main.ev('ssTabs.route()') === 'chat/chat' && await main.visible('#msgs'), 'the main window opens on Chat');
ok(await until(() => count((a) => a.topic === 'chat' && a.seen === true && a.scope === 'song') === 1), 'Chat shown: "seen" said for the newest message');
await push({ presence: Object.assign({}, state.topics.presence, { driver: 'chilio' }) });
await push({ chat: Object.assign({}, state.topics.chat) }); // (the same newest, drawn again)
await sleep(300);
ok(count((a) => a.topic === 'chat' && a.seen === true) === 1, 'drawn again with the same newest: not said again (it was said on every draw)');
await push({ chat: { scope: 'song', msgs: state.topics.chat.msgs.concat([{ id: 'm2', user: 'chilio', text: 'and again', time: iso(5) }]), todo: [], links: [] } });
ok(await until(() => count((a) => a.topic === 'chat' && a.seen === true) === 2), 'a newer message shown: said once more');

// ---- Notes and Likes in All -----------------------------------------------------------------------------------------------------------------
await main.press('All', '.ckinds');
ok(await until(() => actions.some((a) => a.topic === 'chat' && a.notes === true && a.scope === 'song')), 'All on This project asks for the room’s notes and likes');
await push({ chat_notes: { song: 'Cross Test', room: 'main', notes: [
  { id: 'n1', type: 'note', user: 'chilio', text: 'Louder vox here', track: 'Vox', pos: 83.4, time: iso(30) },
  { id: 'n2', type: 'like', user: 'chilio', track: 'Bass', time: iso(20) }] } });
{
  const all = await main.text('.clist.call');
  ok(all.includes('note') && all.includes('Louder vox here · Vox (at 1:23.4)'), 'All shows a note, its track and where on the timeline (' + all.slice(0, 160) + ')');
  ok(all.includes('like') && all.includes('liked a take on Bass'), 'and a like');
  ok(all.indexOf('and again') < all.indexOf('liked a take'), 'newest first, with the messages');
}
await main.ev('document.querySelector(".cchip[data-scope=band]").click(); 1');
await sleep(300);
ok(!(await main.text('.clist.call')).includes('Louder vox'), 'Studio’s All: no room notes there (as with This room and This project only)');
await main.ev('document.querySelector(".cchip[data-scope=song]").click(); 1');
await main.press('Messages', '.ckinds');

// ---- the top bar's call controls ------------------------------------------------------------------------------------------------------------
ok(await main.ev('(() => { const t = document.getElementById("sscall"); return !!t && t.parentNode.tagName === "HEADER" && t.previousElementSibling.id === "sspill"; })()'), 'the call controls sit in the top bar, after the status pill');
ok(await main.has('Mic on', '#sscall') && await main.has('Deafen', '#sscall'), 'live audio running: Mic on and Deafen in the top bar');
ok(await main.ev('document.getElementById("call").hidden') && await main.has('Video', '#sscall'), 'the video section starts put away, with Video to open it');
await main.press('Mic on', '#sscall');
ok(await until(() => actions.some((a) => a.topic === 'rtc' && a.t === 'la' && a.k === 'mute' && a.on === true)), 'Mic on: asks Live sync to mute me');
rtcExtra = { live: true, la: { mute: true } }; pushRtc(); await sleep(300);
ok(await main.has('Muted', '#sscall'), 'muted: the button says so');
await main.press('Deafen', '#sscall');
ok(await until(() => actions.some((a) => a.topic === 'rtc' && a.t === 'la' && a.k === 'deaf' && a.on === true)), 'Deafen asks for it');
rtcExtra = { live: true, la: { deaf: true } }; pushRtc(); await sleep(300);
await main.press('Deafened', '#sscall');
ok(await until(() => actions.some((a) => a.topic === 'rtc' && a.t === 'la' && a.k === 'deaf' && a.on === false)), 'deafened, the mic button hears again (as the panel’s bar)');
rtcExtra = {}; pushRtc(); await sleep(300); // (no live audio from here on: call audio goes ticked, so the call has a mic)
ok(!(await main.has('Deafen', '#sscall')) && !(await main.text('#sscall')).includes('Live audio'), 'live audio stopped: its buttons go');
await main.press('Video', '#sscall');
ok(!(await main.ev('document.getElementById("call").hidden')) && await main.has('Call', '.call-people'), 'Video opens the section: chilio with Call');
ok(await main.has('Pop out', '#call'), 'a browser: the call can pop out');

// ---- the chat pops out ----------------------------------------------------------------------------------------------------------------------
const pchat = await page(LOCAL + '?pop=chat');
ok(await pchat.ev('ssTabs.route()') === 'chat/chat' && await pchat.ev('document.body.classList.contains("sspop")') && await pchat.visible('#msgs'), '?pop=chat: the chat alone');
ok(await pchat.ev('document.getElementById("call").hidden') && await pchat.visible('#sscall'), 'its video section put away, the call controls in its top bar');
await pchat.ev('document.getElementById("text").value = "from the pop-out"; document.querySelector("#say button[type=submit]").click(); 1');
ok(await until(() => actions.some((a) => a.topic === 'chat' && a.text === 'from the pop-out' && a.scope === 'song')), 'a message sent from the pop-out');
ok(await until(async () => (await main.ev('ssCallTest.state().peers.length')) >= 1), 'the main window hears the pop-out on this computer’s channel');

// ---- one call per computer: the call's own window holds it ----------------------------------------------------------------------------------
const pcall = await page(LOCAL + '?pop=call');
ok(await pcall.ev('document.documentElement.classList.contains("ss-pop-call") && !document.getElementById("call").hidden') && !(await pcall.visible('#sstabs')), '?pop=call: the video section alone');
ok(!(await pcall.has('Pop out', '#call')), 'no Pop out inside the pop-out');
ok(await until(async () => (await main.ev('ssCallTest.state().holder')) === (await pcall.ev('ssCallTest.state().pid'))), 'the main window says the call’s own window does the calls');
ok(await until(async () => (await pchat.ev('ssCallTest.state().holder')) === (await pcall.ev('ssCallTest.state().pid'))), 'and so does the chat’s');
const offers0 = count((a) => a.topic === 'rtc' && a.t === 'offer');
await main.press('Call', '.call-people');
ok(await until(async () => (await pcall.ev('ssCallTest.state().sessions.size')) === 1, 10000), 'Call in the main window: the call starts in the call’s window');
ok(await until(() => count((a) => a.topic === 'rtc' && a.t === 'offer' && a.to === CHILIO) === offers0 + 1, 10000), 'one offer to chilio');
ok(await main.ev('ssCallTest.state().sessions.size') === 0, 'none in the main window');
ok(await until(async () => (await main.text('#sscall')).includes('Call: chilio') && (await main.text('#sscall')).includes('(another window)')), 'the main window’s top bar shows the call held in another window');
ok(await until(async () => (await pchat.text('#sscall')).includes('Call: chilio')), 'so does the chat’s');
ok(await main.ev('[...document.querySelectorAll(".call-people button")].find((b) => b.textContent === "Call").disabled'), 'and Call chilio is greyed there (no second call)');
ok(await until(() => main.has('Mic', '#sscall')), 'with the call’s mic');
await main.press('Mic', '#sscall');
ok(await until(async () => (await pcall.ev('(() => { const s = [...ssCallTest.state().sessions.values()][0]; return !!s && !!s.pc && s.pc.getSenders().some((x) => x.track && x.track.kind === "audio" && !x.track.enabled); })()'))), 'Mic in the main window mutes the call’s mic in the call’s window');
ok(await until(() => main.has('Mic off', '#sscall')), 'and the main window says Mic off');
const byes0 = count((a) => a.topic === 'rtc' && a.t === 'bye');
await pchat.press('Hang up', '#sscall');
ok(await until(async () => (await pcall.ev('ssCallTest.state().sessions.size')) === 0), 'Hang up in the chat’s window ends it in the call’s window');
ok(await until(() => count((a) => a.topic === 'rtc' && a.t === 'bye' && a.to === CHILIO) === byes0 + 1), 'with one bye');
ok(await until(async () => !(await main.text('#sscall')).includes('Call: chilio')), 'gone from the main window’s top bar');

// ---- a ring: every window shows it, Answer goes to the call's window ------------------------------------------------------------------------
const sdp = await main.ev('(async () => { const pc = new RTCPeerConnection(); pc.addTransceiver("audio"); pc.addTransceiver("video"); const o = await pc.createOffer(); pc.close(); return o.sdp; })()');
const CALL = 'b'.repeat(32);
rtcMsgs.push({ t: 'offer', call: CALL, dev: CHILIO, user: 'chilio', kind: 'call', sdp, seq: ++seq }); pushRtc();
ok(await until(async () => (await main.has('Answer', '#sscall')) && (await pchat.has('Answer', '#sscall')) && (await pcall.has('Answer', '#sscall'))), 'chilio calls: Answer in every window’s top bar');
await main.press('Answer', '#sscall');
ok(await until(async () => { const s = await pcall.ev('(() => { const s = ssCallTest.state().sessions.get("' + CALL + '"); return s ? s.state : null; })()'); return s && s !== 'ringing'; }, 10000), 'Answer in the main window: answered in the call’s window');
ok(await until(() => actions.some((a) => a.topic === 'rtc' && a.t === 'answer' && a.call === CALL)), 'one answer sent');
ok(await until(async () => !(await main.has('Answer', '#sscall')) && !(await pchat.has('Answer', '#sscall'))), 'the ring stops in the other windows');
ok(await until(async () => (await main.text('#sscall')).includes('(another window)')), 'and the main window shows the call held there');
await pcall.press('Hang up', '#sscall');
ok(await until(async () => (await pcall.ev('ssCallTest.state().sessions.size')) === 0), 'hung up in its own window');

// ---- the call's window closed: calls go back to the main window -----------------------------------------------------------------------------
await pcall.close();
ok(await until(async () => (await main.ev('ssCallTest.state().holder')) === (await main.ev('ssCallTest.state().pid')), 8000), 'its window closed: the main window does the calls again');
ok(await until(async () => (await pchat.ev('ssCallTest.state().holder')) === (await main.ev('ssCallTest.state().pid'))), 'the chat’s window sends them there too');
await pchat.close();
await main.close();

// ---- in REAPER: Pop out only once the window says it opens pop-outs itself (rt-ui8) ---------------------------------------------------------
const rp = await page(LOCAL + '?host=docked#chat', { reaper: true });
if (await rp.ev('document.getElementById("call").hidden')) await rp.press('Video', '#sscall'); // (remembered open from the main window above)
ok(!(await rp.ev('document.getElementById("call").hidden')) && !(await rp.has('Pop out', '#call')), 'docked, before the window speaks: no Pop out (it would go to the browser)');
await rp.ev('window.__ls.forEach((f) => f({ data: { win: "full", focus: true, docked: true, pop: true } })); 1');
pushRtc(); await sleep(300);
ok(await rp.ev('ssEnv.winPop === true') && await rp.has('Pop out', '#call'), 'the window says it pops out: Pop out shows');
await rp.press('Pop out', '#call');
let popT = null;
for (let i = 0; i < 40 && !popT; i++) { await sleep(150); popT = (await (await fetch('http://127.0.0.1:' + port + '/json/list')).json()).find((t) => t.type === 'page' && t.url.includes('pop=call')); }
ok(!!popT, 'Pop out opens ?pop=call (in REAPER the window catches it and opens its own)');
if (popT) await (await fetch('http://127.0.0.1:' + port + '/json/close/' + popT.id)).text();
await rp.close();
// a REAPER pop-out of the chat: no ?host=, the window says pop
const rc = await page(LOCAL + '?pop=chat', { reaper: true });
await rc.ev('window.__ls.forEach((f) => f({ data: { win: "full", focus: true, docked: false, pop: true } })); 1');
await sleep(200);
ok(await rc.ev('ssTabs.route()') === 'chat/chat' && await rc.visible('#msgs') && await rc.ev('ssEnv.winPop === true'), 'the chat as a REAPER pop-out window: the chat, the window known');
await rc.close();

ok(!errors.length, 'no page errors' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
console.log(fails ? 'FAIL ' + fails : 'ok');
await done(fails ? 1 : 0);
