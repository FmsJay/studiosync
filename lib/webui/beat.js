// Where the song is, for the Sheet and Beat pages (sheet.js, visuals.js; lib/songsheet.lua builds the topics): window.ssBeat. The "beat"
// topic is a line (pos at `at` on the computer's link clock, moving at `rate`), "beatmap" every beat's time by the project's tempo map; this
// page measures its own clock against the computer's (GET api/time, NTP's way: the quickest of 8 round trips, as the Record page does), so
// the position, bar and beat are worked out here each frame and the computer sends only what changed. Nothing runs, and Live sync builds
// nothing, unless one of the pages is showing (ssBeat.show). GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs) return;
  let clock = null, timer = 0, syncing = false;
  const showing = new Set();
  async function syncClock(n) {
    let best = null;
    for (let i = 0; i < n; i++) {
      const t0 = performance.now();
      const r = await fetch('api/time', { cache: 'no-store' });
      if (!r.ok) throw new Error(String(r.status));
      const j = await r.json();
      const t1 = performance.now();
      if (!best || t1 - t0 < best.rtt) best = { rtt: t1 - t0, off: j.now * 1000 - (t0 + t1) / 2 };
    }
    return best;
  }
  function resync(n) {
    if (syncing || !showing.size || document.hidden) return;
    syncing = true;
    syncClock(n).then((c) => { clock = c; }).catch(() => {}).finally(() => { syncing = false; });
  }
  const want = () => { if (showing.size && !document.hidden) ssTabs.act('sheet', { want: true }).catch(() => {}); };
  document.addEventListener('visibilitychange', () => { want(); resync(clock ? 4 : 8); });

  // the index of the last beat at or before x in the map's sorted times (-1 before the first)
  function upto(b, x) {
    let lo = 0, hi = b.length - 1, at = -1;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (b[m] <= x) { at = m; lo = m + 1; } else hi = m - 1; }
    return at;
  }
  const B = window.ssBeat = {
    // name: the page's; on: shown or not. The first page shown starts the clock and the "want"; the last one hidden stops them.
    show(name, on) {
      if (on) showing.add(name); else showing.delete(name);
      if (showing.size && !timer) {
        want(); resync(8);
        timer = setInterval(() => { want(); resync(4); }, 10000); // (the clocks drift a little over minutes)
      } else if (!showing.size && timer) { clearInterval(timer); timer = 0; }
    },
    // the computer's link clock now (seconds), or null until it's measured; and how far off it can be (ms)
    now: () => (clock ? (performance.now() + clock.off) / 1000 : null),
    err: () => (clock ? clock.rtt / 2 : null),
    // the song's position now (seconds), or null with nothing from Live sync yet
    pos() {
      const s = ssTabs.topics.beat, t = B.now();
      if (!s || s.pos == null) return null;
      return s.playing && t != null ? s.pos + (t - s.at) * (s.rate || 1) : s.pos;
    },
    // pos -> { bar, beat, beats (in this bar), frac (through this beat, 0-1) }, or null without a map. Past the map's end it goes on at the last
    // beat's spacing and the last bar's length.
    where(pos) {
      const m = ssTabs.topics.beatmap, b = m && m.b, bars = m && m.bars;
      if (!b || b.length < 2 || !bars || !bars.length || pos == null) return null;
      const n = b.length, last = b[n - 1] - b[n - 2];
      let i = upto(b, pos), t0, t1;
      if (i < 0) i = 0;
      if (i === n - 1 && pos >= b[n - 1] + last) { const k = Math.floor((pos - b[n - 1]) / last); i = n - 1 + k; t0 = b[n - 1] + k * last; t1 = t0 + last; }
      else { t0 = b[i]; t1 = i + 1 < n ? b[i + 1] : b[i] + last; }
      let lo = 0, hi = bars.length - 1, k = 0;
      while (lo <= hi) { const mid = (lo + hi) >> 1; if (bars[mid][0] <= i) { k = mid; lo = mid + 1; } else hi = mid - 1; }
      const [first, num0, beats] = bars[k], into = i - first;
      return { bar: num0 + Math.floor(into / beats), beat: (into % beats) + 1, beats, frac: Math.max(0, Math.min(1, (pos - t0) / (t1 - t0 || 1))) };
    },
    // bar number -> its start (seconds), or null
    barTime(bar) {
      const m = ssTabs.topics.beatmap;
      for (const [first, num] of (m && m.bars) || []) if (num === bar) return m.b[first];
      return null;
    },
    // beats left in a count-in now (4, 3, 2, 1), or 0 when there's none going
    countin(pos) {
      const s = ssTabs.topics.beat, c = s && s.cin, m = ssTabs.topics.beatmap, t = B.now();
      if (!s || !s.playing || !c || !m || !m.b || pos == null || t == null) return 0;
      if (pos < c.to - c.len - 0.05 || pos >= c.to || t > c.fire + c.len + 2) return 0;
      return Math.max(1, upto(m.b, c.to + 0.001) - upto(m.b, pos));
    },
    // seconds to a start that's coming, or null
    due() {
      const s = ssTabs.topics.beat, t = B.now();
      return s && s.due && t != null && s.due > t ? s.due - t : null;
    },
    // the sections with times: the sheet's (a region's own; one added by hand from its start bar to the next section), else the map's regions
    timeline() {
      const sh = ssTabs.topics.sheet, m = ssTabs.topics.beatmap;
      if (!sh || !(sh.sections || []).length) return ((m && m.regions) || []).map((r) => Object.assign({}, r));
      const out = sh.sections.map((s) => Object.assign({}, s, s.region ? {} : { pos: s.bar != null ? B.barTime(s.bar) : null }));
      const starts = out.filter((s) => s.pos != null).map((s) => s.pos).sort((a, z) => a - z);
      for (const s of out) if (!s.region && s.pos != null) { const nx = starts.find((p) => p > s.pos); s.rend = nx != null ? nx : Infinity; }
      return out;
    },
    // the section the position is in, and the next one: sections { name, pos, rend } (timeline's)
    sections(list, pos) {
      let cur = null, next = null;
      for (const s of list || []) {
        if (s.pos == null) continue;
        if (pos >= s.pos && pos < s.rend) cur = s;
        else if (s.pos > pos && (!next || s.pos < next.pos)) next = s;
      }
      return { cur, next };
    },
  };
})();
