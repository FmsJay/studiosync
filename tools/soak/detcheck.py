"""The soak's determinism check (docs/rt/rt-sync2a.md; rt-converge found bug 8's cause with it in minutes). A seed is run twice, each time in
fresh Lua states (Lua seeds its string hashes per state, so anything that follows `pairs` order shows up), and everything each computer wrote
or sent is compared: each file (its path and a hash of what was in it), each link message, then each computer's song at the end. With
--against <commit>, the second run is that commit's code (git archive of lib, tools/soak and tests/fixtures): a pure refactor (rt-sync2
phase 1) must write exactly what the commit before it wrote.
  python tools/soak/detcheck.py [--edits 60] [--against <commit>] [seed ...]   (no seed: the quick check, seeds 1 and 2 at 40 edits)
Exit 0 when every seed's two runs wrote the same. From the repo root or anywhere."""
import argparse, hashlib, importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TREE = os.path.dirname(os.path.dirname(HERE))


def load_soak(tree):
    spec = importlib.util.spec_from_file_location("soak_%d" % len(sys.modules), os.path.join(tree, "tools", "soak", "soak.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run(soak, tree, seed, n):
    """-> one line for each thing a computer wrote or sent (its time, who, what, where, a hash of its contents), each computer's song at
    the end, and how the seed ended."""
    os.chdir(tree)  # (node.lua finds lib/ from where it runs)
    log, orig = [], soak.Node.call

    def call(self, t, fn, *a):
        r = orig(self, t, fn, *a)
        if fn == "drain":
            for e in json.loads(r):
                if not soak.Sim.chatter(e):
                    body = e[2] if len(e) > 2 and isinstance(e[2], str) else ""
                    log.append("%.1f %s %s %s %s" % (t, self.user, e[0], e[1], hashlib.sha1(body.encode()).hexdigest()[:12]))
        return r
    soak.Node.call = call
    try:
        bad, sim = soak.run_once(seed, soak.make_edits(seed, n, n * 0.9), soak.Faults(), undo_probe=False)
        log += ["end %s %s" % (u, json.dumps(sim.state(i), sort_keys=True)) for i, u in enumerate(soak.USERS)]
    finally:
        soak.Node.call = orig
    return log, (bad[0][0] if bad else "ok")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("seeds", nargs="*", type=int)
    ap.add_argument("--edits", type=int)
    ap.add_argument("--against", help="a commit: compare this code's run with that commit's")
    a = ap.parse_args(argv)
    seeds, n = a.seeds or [1, 2], a.edits or (60 if a.seeds else 40)
    here = load_soak(TREE)
    there, other = (here, TREE), "a second run"
    if a.against:
        d, sha = here.git_tree(a.against, ("lib", "tools/soak", "tests/fixtures"))
        there, other = (load_soak(d), d), sha[:10]
    differ = 0
    for seed in seeds:
        x, ex = run(here, TREE, seed, n)
        y, ey = run(there[0], there[1], seed, n)
        if x == y:
            print("seed %d: the same %d things written as %s (%s)" % (seed, len(x), other, ex), flush=True)
            continue
        differ += 1
        k = next((i for i, (p, q) in enumerate(zip(x, y)) if p != q), min(len(x), len(y)))
        print("seed %d: DIFFERS from %s at entry %d of %d/%d (%s / %s)\n   here:  %s\n   there: %s" % (seed, other, k, len(x), len(y), ex, ey,
              (x[k] if k < len(x) else "(end)")[:600], (y[k] if k < len(y) else "(end)")[:600]), flush=True)
    os.chdir(TREE)
    print("ok detcheck" if not differ else "detcheck: %d of %d seeds differ" % (differ, len(seeds)))
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())
