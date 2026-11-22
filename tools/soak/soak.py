"""The convergence soak (docs/rt/rt-soak.md; docs/REVIEW-FULL-2026-11-18.md "the one investment").

Three computers, each the real sync code in its own Lua 5.4 state (tools/soak/node.lua: lib/mirror.lua, lib/sync.lua, lib/undo.lua ... against
the stand-in REAPER), each with its own folder. A shim carries what each writes in the studio's folder to the others as Syncthing would (late,
out of order, half-written, twice; a computer's Syncthing paused a while) and what each sends on the direct link (late, twice, or never). A
seeded driver makes edits on all three. Then the faults stop, everything is let through, and the oracle checks:
  converged   every object, the track order, the tempo map and markers read the same on all three
  doubles     no id twice, no two items alike in all but their ids on one track
  errors      nothing raised or logged as an error inside StudioSync
  log         a late joiner opening the song and reading every change ends the same as the three
  undo        an Undo then a Redo on each computer, after it, leaves all three the same and as they were
A failing seed is shrunk to the fewest edits that still fail the same way, and printed.

  python tools/soak/soak.py --quick                 # about 60 s: a few seeds (what tests/run.py could call)
  python tools/soak/soak.py --long --minutes 45     # seeds until the time is up; every failure shrunk and written to tools/soak/out/
  python tools/soak/soak.py --seed 17               # one seed, with its trace
  python tools/soak/soak.py --seed 17 --shrink      # one seed, shrunk to the fewest edits that still fail the same way
  python tools/soak/soak.py --seed 17 --keep 3,9,12 # only those edits of seed 17 (what a shrink prints)
Exit 0 when every seed passed. From the repo root or anywhere; Lua 5.4 through lupa, as tests/run.py.
"""
import argparse, gc, heapq, json, os, random, re, sys, threading, time

import lupa.lua54 as lupa

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(REPO)
NODE_LUA = open(os.path.join(REPO, "tools", "soak", "node.lua"), encoding="utf-8").read()
USERS = ["James", "Bee", "Cee"]
# simulated s with nothing but presence moving before the oracle runs: Live sync's heal waits 60 s of a bandmate differing, and its order
# heal mirror.ORDER_WAIT (120 s) from a bandmate's track move landing plus a status round: at 90 the oracle ran before the order heal could
QUIET = 140
FIRST_EDIT = DEFAULT_FIRST = 20.0  # simulated seconds after the song is shared (--first-edit)

# The edits the driver makes, and how often (weights).
EDITS = [("item_move", 14), ("item_resize", 6), ("item_mute", 4), ("item_delete", 5), ("item_new", 5), ("item_copy", 4), ("item_to_track", 3),
         ("track_add", 2), ("track_rename", 3), ("track_delete", 1), ("track_volume", 3), ("track_move", 2), ("tempo", 2), ("marker", 4),
         ("notes", 6), ("cc", 3), ("fx", 5), ("envelope", 3), ("claim", 2), ("undo", 6), ("redo", 3), ("restore", 1)]


class Faults:
    """How bad the network is. quick/long use these; --clean turns them all off (a check of the soak itself)."""
    def __init__(self, clean=False):
        on = 0 if clean else 1
        self.clean = clean
        self.st_min, self.st_max = 0.5, 6.0          # Syncthing: a file reaches each other computer this many s later
        self.st_late = 0.12 * on                      # ... or late: 15-90 s (another order than the link's, and than other files')
        self.st_twice = 0.05 * on                     # a file brought again a little later (the same version)
        self.st_half = 0.03 * on                      # a file seen half-written first (a cloud drive's copy, a crash mid-copy)
        self.pause = 0.004 * on                       # each second, the chance a computer's Syncthing pauses for 20-120 s
        self.link_drop = 0.04 * on                    # per message, the chance its lane goes down for 0.5-8 s (what it carries then is lost)
        self.link_twice = 0.02 * on                   # a link message delivered twice (resent after a reconnect)
        self.link_min, self.link_max = 0.02, 0.4      # a link message's delay
        self.skew = 1.5 * on                          # each computer's clock off by up to this many s (the laptop ran 0.9 s ahead)


class Node:
    def __init__(self, user, seed, skew):
        self.user = user
        self.L = lupa.LuaRuntime(unpack_returned_tuples=True)
        g = self.L.globals()
        self.out = []
        g.print = lambda *a: self.out.append(" ".join(str(x) for x in a))
        g.SOAK_USER, g.SOAK_SEED, g.SOAK_SKEW = user, seed, skew
        self.L.execute(NODE_LUA)
        self.N = g.NODE

    def call(self, t, fn, *a):
        self.N.set_time(t)
        return getattr(self.N, fn)(*a)


class Sim:
    def __init__(self, seed, edits, faults, trace=False, steps_s=0.1):
        self.seed, self.edits, self.f, self.trace = seed, edits, faults, trace
        self.rng = random.Random(seed * 7919 + 1)   # the network's and the passes' randomness (the edits are a fixed list)
        skews = [0.0] + [self.rng.uniform(-faults.skew, faults.skew) for _ in USERS[1:]]
        self.nodes = [Node(u, seed * 10 + i + 1, skews[i]) for i, u in enumerate(USERS)]
        self.q, self.qn = [], 0
        self.version = {}        # path -> (time, writer index): Syncthing's newest version of each file
        self.applied = {}        # (dst, path) -> version applied there
        self.writers = {}        # path -> set of writer indices (a file several computers write: Syncthing conflicts)
        self.paused = [0.0] * len(self.nodes)
        self.down, self.lane_t = {}, {}  # (from, to) -> the link lane is down until; the last delivery time on it (in order)
        self.meaningful = 0
        self.heals_seen = {}
        self.quiescing, self.quiet_logged = False, 0
        self.t = 0.0
        self.dt = steps_s
        self.lines = []
        self.stats = {"files": 0, "link": 0, "dropped": 0, "late": 0, "twice": 0, "half": 0, "pauses": 0, "passes": 0}

    def log(self, s):
        self.lines.append("%7.1f %s" % (self.t, s))
        if self.trace:
            print("%7.1f %s" % (self.t, s), flush=True)

    def push(self, at, what):
        self.qn += 1
        heapq.heappush(self.q, (at, self.qn, what))

    # ---- what a computer wrote or sent goes into the shim ----
    @staticmethod
    def chatter(e):  # (who's here: written and sent all the time, never a change of the song's)
        return (e[0] == "link" and e[1] in ("presence", "heartbeat")) or (e[0] != "link" and "/status/" in e[1])

    def drain(self, i, healing=False):
        out = json.loads(self.nodes[i].call(self.t, "drain"))
        f = self.f
        self.meaningful += sum(1 for e in out if not self.chatter(e))
        if self.quiescing:  # (what still moves after the edits stopped: a settle failure's trace)
            for e in out:
                if not self.chatter(e) and self.quiet_logged < 200:
                    self.quiet_logged += 1
                    self.log("%s %s %s" % (USERS[i] if i < len(USERS) else "?", e[0], e[1].rsplit("/", 2)[-2:] if e[0] != "link" else e[1] + " " + e[2][:160]))
        for e in out:
            if e[0] == "link":
                # (the extension's link is one TCP lane per peer: in order, or lost while the lane is down; a frame resent after a
                # reconnect comes twice, right after itself. extension/direct.cpp direct_msg)
                self.stats["link"] += 1
                for j in range(len(self.nodes)):
                    if j == i:
                        continue
                    lane = (i, j)
                    if not healing and self.down.get(lane, 0) <= self.t and self.rng.random() < f.link_drop:
                        self.down[lane] = self.t + self.rng.uniform(0.5, 8)
                    if not healing and self.down.get(lane, 0) > self.t:
                        self.stats["dropped"] += 1
                        continue
                    at = max(self.t + self.rng.uniform(f.link_min, f.link_max), self.lane_t.get(lane, 0) + 0.001)
                    self.lane_t[lane] = at
                    self.push(at, ("link", j, e[1], e[2], self.chatter(e)))
                    if not healing and self.rng.random() < f.link_twice:
                        self.stats["twice"] += 1
                        self.lane_t[lane] = at + 0.002
                        self.push(at + 0.002, ("link", j, e[1], e[2], self.chatter(e)))
            else:
                path, data = e[1], (e[2] if e[0] == "put" else None)
                self.stats["files"] += 1
                ver = (self.t, i)
                self.version[path] = max(self.version.get(path, ver), ver)
                self.writers.setdefault(path, set()).add(i)
                for j in range(len(self.nodes)):
                    if j == i:
                        continue
                    d = self.rng.uniform(f.st_min, f.st_max)
                    if not healing and self.rng.random() < f.st_late:
                        d = self.rng.uniform(15, 90)
                        self.stats["late"] += 1
                    if not healing and data is not None and self.rng.random() < f.st_half and len(data) > 20:
                        self.stats["half"] += 1
                        self.push(self.t + d * 0.5, ("file", j, path, data[: len(data) // 2], ver, True, self.chatter(e)))
                    self.push(self.t + d, ("file", j, path, data, ver, False, self.chatter(e)))
                    if not healing and self.rng.random() < f.st_twice:
                        self.stats["twice"] += 1
                        self.push(self.t + d + self.rng.uniform(1, 20), ("file", j, path, data, ver, False, self.chatter(e)))

    def deliver(self, what, healing):
        kind, j = what[0], what[1]
        if kind == "link":
            self.nodes[j].call(self.t, "link", what[2], what[3])
            return
        _, j, path, data, ver, half, _ = what
        src = ver[1]
        if not healing and (self.paused[j] > self.t or self.paused[src] > self.t):  # (Syncthing paused at either end: when it's back)
            self.push(max(self.paused[j], self.paused[src]) + self.rng.uniform(0.5, 5), what)
            return
        have = self.applied.get((j, path))
        if have is not None and have > ver:  # (Syncthing never puts an older version over a newer)
            return
        if half and have is not None and have >= ver:
            return
        if not half:
            self.applied[(j, path)] = ver
        self.nodes[j].call(self.t, "put", path, data)

    # ---- the run ----
    def run(self, quiesce_max=400.0):
        n = self.nodes
        self.mode = "open" if self.seed % 5 < 3 else "everyone"  # (Claims, the default, three seeds in five; Open the others)
        n[0].call(0, "set_mode", self.mode)
        n[0].call(0, "share")
        for x in n:
            x.call(0, "open")
        for x in n:
            self.drain(n.index(x), healing=True)
        for i, x in enumerate(n):
            x.call(0, "status")
        next_pass = [self.rng.uniform(0.1, 0.5) for _ in n]
        self.next_status = [self.rng.uniform(1, 5) for _ in n]
        edits = sorted(self.edits, key=lambda e: e["t"])
        k, end = 0, (edits[-1]["t"] if edits else 0) + 1.0
        while self.t < end:
            self.t = round(self.t + self.dt, 6)
            self.step(next_pass, healing=False)
            while k < len(edits) and edits[k]["t"] <= self.t:
                e = edits[k]
                k += 1
                did = n[e["node"]].call(self.t, "edit", e["kind"], json.dumps(e["r"]))
                e["did"] = did
                self.log("%s #%d %s: %s" % (USERS[e["node"]], e["i"], e["kind"], did or "(nothing to do)"))
                self.drain(e["node"])
            for i in range(len(n)):
                if self.paused[i] <= self.t and self.rng.random() < self.f.pause * self.dt:
                    self.paused[i] = self.t + self.rng.uniform(20, 120)
                    self.stats["pauses"] += 1
                    self.log("%s: Syncthing paused until %.0f" % (USERS[i], self.paused[i]))
        # quiesce: no more edits or faults; everything still on its way arrives; passes until nothing moves for 40 s
        self.log("quiesce")
        self.quiescing = True
        self.paused = [0.0] * len(n)
        quiet_since, t0 = self.t, self.t
        while self.t - t0 < quiesce_max:
            self.t = round(self.t + self.dt, 6)
            moved = self.step(next_pass, healing=True)
            if moved or any(not w[2][-1] for w in self.q):
                quiet_since = self.t
            if self.t - quiet_since >= QUIET:
                return True
        return False

    def step(self, next_pass, healing):
        moved = False
        while self.q and self.q[0][0] <= self.t:
            _, _, what = heapq.heappop(self.q)
            self.deliver(what, healing)
            moved = moved or not what[-1]
        for i, x in enumerate(self.nodes):
            if self.next_status[i] <= self.t:
                self.next_status[i] = self.t + 5
                x.call(self.t, "status")
                self.drain(i, healing)
            if next_pass[i] <= self.t:
                next_pass[i] = self.t + self.rng.uniform(0.4, 1.2)
                r = json.loads(x.call(self.t, "pass"))
                self.stats["heals"] = self.stats.get("heals", 0) + max(0, r.get("heals", 0) - self.heals_seen.get(i, 0))
                self.heals_seen[i] = r.get("heals", 0)
                self.stats["passes"] += 1
                before = self.meaningful
                self.drain(i, healing)
                if r["got"] or r["more"] or self.meaningful != before:
                    moved = True
        return moved

    # ---- the oracle ----
    def state(self, i):
        return json.loads(self.nodes[i].call(self.t, "state"))

    def check(self, undo_probe=True):
        """-> list of (category, detail). Empty: passed."""
        bad = []
        for i, x in enumerate(self.nodes):
            for e in json.loads(x.call(self.t, "errors")):
                bad.append(("errors", "%s: %s" % (USERS[i], e.splitlines()[0][:400])))
        sts = [self.state(i) for i in range(len(self.nodes))]
        for i, s in enumerate(sts):
            for d in s["dup"]:
                bad.append(("doubles", "%s: %s" % (USERS[i], d)))
        bad += self.compare(sts, "converged")
        if bad:
            return bad
        # a late joiner: the song as shared (its markers), the studio's folder as Syncthing brings it, every change read
        d = Node("Dee", self.seed * 10 + 9, 0.0)
        d.call(self.t, "open")
        for path, data in json.loads(self.nodes[0].call(self.t, "shared_files")):
            d.call(self.t, "put", path, data)
        self.dee = d
        # (until nothing has landed for 70 s: a change that looks refused by the claims waits a minute where it arrives, then lands
        # (sync.receive), and a late joiner that stopped at its first quiet pass was compared before those had. rt-converge)
        quiet = 0
        for _ in range(800):
            self.t = round(self.t + 0.5, 6)
            r = json.loads(d.call(self.t, "pass"))
            json.loads(d.call(self.t, "drain"))
            quiet = 0 if (r["got"] or r["more"]) else quiet + 1
            if quiet >= 140:
                break
        ds = json.loads(d.call(self.t, "state"))
        for e in json.loads(d.call(self.t, "errors")):
            bad.append(("errors", "Dee (late joiner): %s" % e.splitlines()[0][:400]))
        bad += [("log", x[1]) for x in self.compare([sts[0], ds], "the late joiner", names=["James", "Dee"])]
        if bad or not undo_probe:
            return bad
        # Undo then Redo on each computer: all three the same after each, and as they were after the Redo
        next_pass = [self.t + 0.1 * i for i in range(len(self.nodes))]
        for i in range(len(self.nodes)):
            base = self.state(0)
            res = []
            for kind in ("undo", "redo"):
                self.t = round(self.t + 1.0, 6)
                res.append(self.nodes[i].call(self.t, "edit", kind, "[]"))
                self.log("%s probe %s: %s" % (USERS[i], kind, res[-1]))
                self.drain(i, healing=True)
                for _ in range(int(60 / self.dt)):
                    self.t = round(self.t + self.dt, 6)
                    self.step(next_pass, healing=True)
                    if not any(not w[2][-1] for w in self.q) and self.t > next_pass[0] + 3:
                        break
                for _ in range(int(20 / self.dt)):
                    self.t = round(self.t + self.dt, 6)
                    self.step(next_pass, healing=True)
                sts = [self.state(j) for j in range(len(self.nodes))]
                bad += [("undo", "after %s's %s (%s): %s" % (USERS[i], kind, res[-1][:120], x[1])) for x in self.compare(sts, "")]
                for j, x in enumerate(self.nodes):
                    for e in json.loads(x.call(self.t, "errors")):
                        bad.append(("errors", "%s, during the undo probe: %s" % (USERS[j], e.splitlines()[0][:400])))
                if bad:
                    return bad
            if all(r.startswith(("undo: ", "redo: ")) and "nothing (" not in r for r in res):
                after = sts[0]
                bad += [("undo", "%s's Undo then Redo didn't bring the song back: %s" % (USERS[i], x[1])) for x in self.compare([base, after], "", names=["before", "after"])]
                if bad:
                    return bad
        return bad

    def compare(self, sts, what, names=None):
        names = names or USERS
        bad, a = [], sts[0]
        for k, b in enumerate(sts[1:], 1):
            diff = [o for o in set(a["hashes"]) | set(b["hashes"]) if a["hashes"].get(o) != b["hashes"].get(o) and not self.noise(o, names, k)]
            for o in sorted(diff)[:6]:
                ha, hb = a["hashes"].get(o), b["hashes"].get(o)
                why = "missing on %s" % names[k] if hb is None else "missing on %s" % names[0] if ha is None else "differs"
                bad.append((what, "%s %s (%s vs %s): %s" % (o, why, names[0], names[k], self.detail(o, names, k))))
            if len(diff) > 6:
                bad.append((what, "... and %d more objects differ" % (len(diff) - 6)))
            if not diff and a["order"] != b["order"]:
                bad.append((what, "track order differs (%s vs %s): %s / %s" % (names[0], names[k], a["order"], b["order"])))
            if a["timeline"] != b["timeline"]:
                bad.append((what, "tempo map / markers differ (%s vs %s): %s / %s" % (names[0], names[k], a["timeline"][:300], b["timeline"][:300])))
        return bad

    def node_of(self, name):
        return self.nodes[USERS.index(name)] if name in USERS else getattr(self, "dee", None) if name == "Dee" else None

    def noise(self, oid, names, k):
        """Two readings that differ only past the 9th decimal of a number (a time REAPER moved for a tempo map and back, written to its
        14th digit, against the event's text): not a difference anyone could hear. Counted in stats."""
        a, b = self.node_of(names[0]), self.node_of(names[k])
        if not (a and b):
            return False
        sa, sb = a.call(self.t, "show", oid), b.call(self.t, "show", oid)
        def num9(m):  # (and a whole number as one: "0.99999999999997" against "1", a rate that went to another map and back)
            s = ("%.9f" % float(m.group(0))).rstrip("0").rstrip(".")
            return "0" if s == "-0" else s
        r = lambda s: re.sub(r"-?\d+\.\d+(e-?\d+)?", num9, s)
        if sa != "(not here)" and sb != "(not here)" and r(sa) == r(sb):
            self.stats["float_noise"] = self.stats.get("float_noise", 0) + 1
            return True
        return False

    def detail(self, oid, names, k):
        a, b = self.node_of(names[0]), self.node_of(names[k])
        if not (a and b):
            return ""
        sa, sb = a.call(self.t, "show", oid), b.call(self.t, "show", oid)
        return "\n      %s: %s\n      %s: %s" % (names[0], sa[:500].replace("\n", " | "), names[k], sb[:500].replace("\n", " | "))


def rss():
    try:
        import psutil
        return ", %.0f MB" % (psutil.Process().memory_info().rss / 1048576)
    except ImportError:
        return ""


def make_edits(seed, n, span, first=None):
    """The seed's edits: n of them over `span` simulated seconds, in bursts (someone working) and gaps; each with its own random numbers."""
    r = random.Random(seed)
    kinds = [k for k, w in EDITS for _ in range(w)]
    out, t = [], 0.0
    for i in range(n):
        t += r.expovariate(1 / 0.6) if r.random() < 0.8 else r.uniform(3, 12)
        out.append({"i": i, "t": t, "node": r.randrange(len(USERS)), "kind": r.choice(kinds), "r": [round(r.random(), 6) for _ in range(6)]})
    scale = min(1.0, span / max(t, 1))
    for e in out:  # (from FIRST_EDIT s: everyone has the song by then, and the 15 s after a tempo map lands (the song's, as it opens) are over)
        e["t"] = round((FIRST_EDIT if first is None else first) + e["t"] * scale, 1)
    return out


def run_once(seed, edits, faults, trace=False, undo_probe=True):  # -> list of (category, detail), the Sim
    gc.collect()  # (the last run's Lua states sit in reference cycles Python's collector only reaches when asked: 15 MB a run otherwise)
    sim = Sim(seed, [dict(e) for e in edits], faults, trace=trace)
    try:
        ok = sim.run()
        bad = sim.check(undo_probe=undo_probe) if ok else [("settle", "never went quiet within 400 s of the last edit")]
    except Exception as e:  # (a Lua error outside StudioSync's own pcalls: the soak's or the code's)
        bad = [("raised", str(e).splitlines()[0][:400])]
    return bad, sim


def signature(bad):
    """What a failure is, for the shrink: its category, the kind of object or what the first line says (ids and numbers taken out), so a
    shrink doesn't wander onto another bug."""
    cat, detail = bad[0]
    shape = re.sub(r"[0-9A-F]{6,}|\d+(\.\d+)?", "#", detail.split("\n")[0])
    if cat in ("errors", "raised", "settle"):
        return cat + ":" + shape.split(": ", 1)[-1][:80]
    m = re.match(r"([A-Z])-\S+ (missing on \w+|differs)", detail)
    if m:
        return "%s:%s %s" % (cat, m.group(1), "differs" if m.group(2) == "differs" else "missing")
    return cat + ":" + shape[:40]


def shrink(seed, edits, faults, sig, budget_s, undo_probe):
    """ddmin over the edits, then one at a time: the fewest that still fail with the same signature (the network's randomness and the
    computers' clocks stay the seed's, drawn in the same order for what remains)."""
    t_end = time.monotonic() + budget_s
    tries = [0]

    def fails(cand):
        tries[0] += 1
        bad, _ = run_once(seed, cand, faults, undo_probe=undo_probe)
        return bool(bad) and signature(bad) == sig

    cur, n = list(edits), 2
    while len(cur) >= 2 and time.monotonic() < t_end:
        size = -(-len(cur) // n)
        chunks = [cur[i:i + size] for i in range(0, len(cur), size)]
        for c in chunks:  # a chunk alone, then everything but it
            if time.monotonic() > t_end:
                break
            if len(c) < len(cur) and fails(c):
                cur, n = c, 2
                break
            comp = [e for e in cur if e not in c]
            if comp and fails(comp):
                cur, n = comp, max(n - 1, 2)
                break
        else:
            if n >= len(cur):
                break
            n = min(len(cur), n * 2)
    for e in list(cur):  # (ddmin can stop short of 1-minimal on a timing-sensitive failure)
        if len(cur) > 1 and time.monotonic() < t_end:
            cand = [x for x in cur if x is not e]
            if fails(cand):
                cur = cand
    return cur, tries[0]


def print_shrunk(seed, edits, faults, sig, budget_s, probe, n):
    """Shrinks a failing seed and prints the minimal sequence: the command that replays it, each edit as the driver made it, and the trace."""
    small, tries = shrink(seed, edits, faults, sig, budget_s, probe)
    bad2, sim2 = run_once(seed, small, faults, undo_probe=probe)
    print("  shrunk to %d edit(s) in %d tries (%s): python tools/soak/soak.py --seed %d --edits %d --keep %s%s%s%s" % (
        len(small), tries, sig, seed, n, ",".join(str(e["i"]) for e in small), " --clean" if faults.clean else "",
        "" if probe else " --no-undo-probe", "" if FIRST_EDIT == DEFAULT_FIRST else " --first-edit %g" % FIRST_EDIT), flush=True)
    for e in sim2.edits:
        print("    %6.1f %s #%d %s %s -> %s" % (e["t"], USERS[e["node"]], e["i"], e["kind"], e["r"], e.get("did", "")))
    for cat, d in bad2[:4]:
        print("    [%s] %s" % (cat, d[:600]))
    return {"keep": [e["i"] for e in small], "tries": tries, "signature_small": signature(bad2) if bad2 else "passed", "bad_small": bad2[:12], "trace": sim2.lines}


def report(seed, bad, sim, keep=None):
    lines = ["seed %d FAILED (%s)%s" % (seed, bad[0][0], (" with edits " + ",".join(str(e["i"]) for e in keep)) if keep is not None else "")]
    for cat, d in bad[:12]:
        lines.append("  [%s] %s" % (cat, d))
    return "\n".join(lines)


def selfcheck():
    """The soak's own parts that could lie: node.lua's plug-in model (the chain's text through the API) and the driver's plug-in edits (a
    chain with nested blocks once came out unbalanced and made a track out of an item). Raises on a failure."""
    n = Node("James", 1, 0.0)
    ok = n.call(1, "eval", r'''
local t = F.add_track("X")
t.body = "<VOLENV2\nPT 0 1 0\n>\n<FXCHAIN\nSHOW 0\nLASTSEL 0\nDOCKED 0\nBYPASS 0 0 0\n<VST \"VST: ReaEQ (Cockos)\" reaeq.dll 0 \"\" 1<5>\nQUFB250AAAA\n>\nFLOATPOS 0 0 0 0\nFXID {A}\nWAK 0 0\nBYPASS 1 0 0\n<JS utility/volume \"\"\nQUFB900AAAA\n>\nWAK 0 0\n>\n<AUXVOLENV\n>\n"
assert(reaper.TrackFX_GetCount(t) == 2, "two plug-ins")
assert(math.abs(reaper.TrackFX_GetParamNormalized(t, 1, 0) - 0.9) < 1e-9, "the second one's knob")
assert(select(2, reaper.TrackFX_GetFXName(t, 1)) == "utility/volume" and not reaper.TrackFX_GetEnabled(t, 1), "its name, bypassed")
return "ok"''')
    assert ok == "true\tok", "soak self-check, the plug-in model: " + ok
    n.call(1, "share")
    for i in range(60):
        n.call(2 + i, "edit", "fx", json.dumps([((i * 0.137 + k * 0.29) % 1) for k in range(6)]))
    ok = n.call(70, "eval", r'''
for _, t in ipairs(F.tracks) do
  local d = 0
  for l in (t.body or ""):gmatch("[^\n]+") do if l:sub(1, 1) == "<" then d = d + 1 elseif l == ">" then d = d - 1 end; assert(d >= 0, "unbalanced: " .. t.name) end
  assert(d == 0 and select(2, (t.body or ""):gsub("<FXCHAIN", "")) <= 1, "one balanced chain: " .. t.name)
end
return "ok"''')
    assert ok == "true\tok", "soak self-check, the driver's plug-in edits: " + ok
    assert not json.loads(n.call(70, "errors")), "soak self-check: errors " + n.call(70, "errors")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="about 60 s: a few short seeds")
    ap.add_argument("--long", action="store_true", help="seeds until --minutes is up")
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--first", type=int, default=1, help="the first seed of a quick or long run")
    ap.add_argument("--edits", type=int, help="edits per seed (quick 40, long 150)")
    ap.add_argument("--keep", help="with --seed: only these edits (by number)")
    ap.add_argument("--clean", action="store_true", help="no network faults (checks the soak itself)")
    ap.add_argument("--first-edit", type=float, default=DEFAULT_FIRST, help="simulated s before the first edit (2: inside the song's first 15 s)")
    ap.add_argument("--no-undo-probe", action="store_true")
    ap.add_argument("--no-shrink", action="store_true")
    ap.add_argument("--shrink", action="store_true", help="with --seed: shrink a failure to its fewest edits")
    ap.add_argument("--shrink-secs", type=float, default=600)
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--selfcheck", action="store_true", help="only the soak's own self-check (--quick runs it first too)")
    a = ap.parse_args()
    global FIRST_EDIT
    FIRST_EDIT = a.first_edit
    faults = Faults(clean=a.clean)
    probe = not a.no_undo_probe
    mem_cap = int(os.environ.get("STUDIOSYNC_TEST_MEM_MB", "4096"))

    def watch():  # (as tests/run.py: past the memory cap the whole run ends at once)
        try:
            import psutil
        except ImportError:
            return
        p = psutil.Process()
        while True:
            time.sleep(1)
            mb = p.memory_info().rss / 1048576
            if mb > mem_cap:
                print("soak: stopped at %.0f MB of memory (cap %d)" % (mb, mem_cap), flush=True)
                os._exit(2)
    threading.Thread(target=watch, daemon=True).start()

    out_dir = os.path.join(REPO, "tools", "soak", "out")
    if a.seed is not None:
        n = a.edits or 150
        edits = make_edits(a.seed, n, n * 0.9)
        if a.keep:
            want = {int(x) for x in a.keep.split(",") if x.strip()}
            edits = [e for e in edits if e["i"] in want]
        t0 = time.monotonic()
        bad, sim = run_once(a.seed, edits, faults, trace=a.trace, undo_probe=probe)
        print("seed %d: %d edits, %.0f simulated s, %.1f s, %s" % (a.seed, len(edits), sim.t, time.monotonic() - t0, sim.stats))
        if not bad:
            print("ok seed %d" % a.seed)
            return 0
        print(report(a.seed, bad, sim))
        if not a.trace:
            print("\n".join(sim.lines[-60:]))
        if a.shrink:
            print_shrunk(a.seed, edits, faults, signature(bad), a.shrink_secs, probe, n)
        return 1

    if a.selfcheck or a.quick:
        selfcheck()
        print("soak self-check ok", flush=True)
        if a.selfcheck:
            return 0
    budget = 55 if a.quick else a.minutes * 60
    n = a.edits or (40 if a.quick else 150)
    t_end = time.monotonic() + budget
    seed, passed, failed = a.first, 0, []
    while time.monotonic() < t_end:
        t0 = time.monotonic()
        edits = make_edits(seed, n, n * 0.9)
        bad, sim = run_once(seed, edits, faults, undo_probe=probe)
        took = time.monotonic() - t0
        if not bad:
            passed += 1
            print("seed %d ok (%d edits, %.0f sim s, %.1f s%s)" % (seed, len(edits), sim.t, took, rss()), flush=True)
        else:
            sig = signature(bad)
            print(report(seed, bad, sim) + "\n  (%.1f s%s)" % (took, rss()), flush=True)
            entry = {"seed": seed, "signature": sig, "bad": bad[:12], "edits": len(edits)}
            if not a.no_shrink and not a.quick:
                entry.update(print_shrunk(seed, edits, faults, sig, min(a.shrink_secs, max(0, t_end - time.monotonic())), probe, n))
            failed.append(entry)
            os.makedirs(out_dir, exist_ok=True)
            with open(os.path.join(out_dir, "seed-%d.json" % seed), "w", encoding="utf-8") as fh:
                json.dump(entry, fh, indent=1)
        seed += 1
    print("soak: %d seeds, %d passed, %d failed%s" % (passed + len(failed), passed, len(failed), (": " + ", ".join(str(f["seed"]) for f in failed)) if failed else ""))
    if a.quick:
        print("ok soak" if not failed else "soak FAILED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
