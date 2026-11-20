// The drawing layer's anchoring math (lib/webui/anchor.js, shared with screen share's notes; rt-draw), run by tests/test_0_60_rt_draw.lua
// through Node when it's on this computer: a mark made on the Project page stays on its time and track however the view is zoomed or scrolled,
// one on the Mixer stays on its strip when the strips scroll or are reordered, and anchors that don't fit are refused. Prints "ok" last.
'use strict';
require('../lib/webui/anchor.js');
const A = globalThis.ssAnchor;
const assert = (c, m) => { if (!c) { console.log('FAIL ' + m); process.exit(1); } };
const near = (a, b, m, eps = 1e-6) => assert(Math.abs(a - b) <= eps, m + ': ' + a + ' vs ' + b);

// The Project page's view, as draw.js builds it from daw.js's: names column HEAD px, ruler TOP px, lanes of LANE px from y0 down.
function dawView(V, oids) {
  return { t0: V.x0, t1: V.x0 + (V.W - V.HEAD) / V.pps, aw: V.W - V.HEAD, ah: V.H - V.TOP,
    crop: { x: V.HEAD / V.W, y: V.TOP / V.H, w: (V.W - V.HEAD) / V.W, h: (V.H - V.TOP) / V.H },
    tracks: oids.map((k, i) => [k, i * V.LANE - V.y0, V.LANE, 'T' + i]) };
}
const at = (v, V, x, y) => A.fromPic(v, x / V.W, y / V.H);
const px = (v, V, a) => { const q = A.toPic(v, a); return q && { x: q.x * V.W, y: q.y * V.H }; };
const oids = ['T-JAMES-20261120101010-11234', 'T-BO-20261120101011-24567', 'T-JAMES-20261120101012-35678'];
const V1 = { W: 1000, H: 400, HEAD: 140, TOP: 34, LANE: 40, x0: 0, pps: 20, y0: 0 };
const v1 = dawView(V1, oids);
// a point at 0:15 on the second track, a quarter of the way down it
const p = at(v1, V1, 140 + 15 * 20, 34 + 40 + 10);
assert('t' in p, 'inside the arrange view gives a song place');
near(p.t, 15, 'time');
assert(p.k === oids[1], 'the track under it');
near(p.d, 0.25, 'place down the track');
assert(A.anchorOk(p), 'a mirror-sync oid passes (80 characters allowed)');
// zoomed in 4x and scrolled 10 s and a lane down: still 0:15 on the same track, a quarter down
const V2 = Object.assign({}, V1, { pps: 80, x0: 10, y0: 40 });
const q = px(dawView(V2, oids), V2, p);
near(q.x, 140 + (15 - 10) * 80, 'x after zoom and scroll');
near(q.y, 34 + 40 - 40 + 10, 'y after scrolling a lane');
// a different window size (a phone): same place
const V3 = { W: 375, H: 600, HEAD: 84, TOP: 34, LANE: 52, x0: 12, pps: 10, y0: 0 };
const q3 = px(dawView(V3, oids), V3, p);
near(q3.x, 84 + 3 * 10, 'x on the phone');
near(q3.y, 34 + 52 + 13, 'y on the phone');
// a track not in the view: not drawn; the names column and the ruler aren't song places
assert(px(dawView(V1, [oids[0]]), V1, p) === null, 'its track not shown: nowhere');
assert(!('t' in at(v1, V1, 100, 200)), 'the names column is not a place on the song');
assert(!('t' in at(v1, V1, 500, 10)), 'the ruler is not a place on the song');
// below the last track: the nearest (the last) one, further down
const below = at(v1, V1, 500, 34 + 3 * 40 + 20);
assert(below.k === oids[2] && below.d > 1, 'below the last track: the last, past its foot');
// anchors that don't fit are refused
assert(!A.anchorOk({ t: 1, k: 'x'.repeat(81), d: 0 }), 'an over-long track id');
assert(!A.anchorOk({ t: Infinity, k: 'T-A-1-1', d: 0 }), 'a time that isn\'t a number');
assert(!A.anchorOk({ t: 1, k: 'T-A-1-1', d: 2000 }), 'a place far off the track');

// The Mixer: strips across, so draw.js swaps the axes. A strip is a "track" along x, the place down it the "time".
function mixView(strips, W, H, top, sh) {
  return { t0: 0, t1: 1, aw: sh, ah: W, crop: { x: top / H, y: 0, w: sh / H, h: 1 }, tracks: strips };
}
const mAt = (v, W, H, x, y) => A.fromPic(v, y / H, x / W);
const mPx = (v, W, H, a) => { const q = A.toPic(v, a); return q && { x: q.y * W, y: q.x * H }; };
const W = 600, H = 500;
// three strips 92 px wide, 8 px apart, from x = 0; each from y 6 to 486
let strips = [['T-A-1-1', 0, 92, ''], ['T-B-1-2', 100, 92, ''], ['T-C-1-3', 200, 92, '']];
let mv = mixView(strips, W, H, 6, 480);
const m = mAt(mv, W, H, 100 + 46, 6 + 120);
assert(m.k === 'T-B-1-2', 'the strip under the pointer');
near(m.t, 0.25, 'a quarter of the way down the strip');
near(m.d, 0.5, 'the middle of the strip');
// scrolled 70 px, and the strips reordered (B now first): the mark follows its strip
strips = [['T-B-1-2', 0 - 70, 92, ''], ['T-C-1-3', 100 - 70, 92, ''], ['T-A-1-1', 200 - 70, 92, '']];
mv = mixView(strips, W, H, 6, 480);
const mq = mPx(mv, W, H, m);
near(mq.x, -70 + 46, 'x on its strip after a scroll and a reorder');
near(mq.y, 6 + 120, 'y down its strip');
// a narrower window: the strips are shorter, the mark is still a quarter down
const mq2 = mPx(mixView([['T-B-1-2', 0, 80, '']], 300, 300, 6, 280), 300, 300, m);
near(mq2.x, 40, 'the middle of a narrower strip');
near(mq2.y, 6 + 70, 'a quarter down a shorter strip');
console.log('ok');
