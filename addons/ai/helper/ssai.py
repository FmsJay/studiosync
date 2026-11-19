"""StudioSync AI helper. Python 3.11+, run from the add-on's own venv, never imported into StudioSync.

  ssai.py <job> --in <wav|folder|json> --out <run folder> [--opts <json or file>] --consent <token> [--install] [--dry-run]
  ssai.py check --out <folder>        which jobs are here and what each still needs (no consent needed: it changes nothing)

Jobs: stems, sections, transcribe, midi, master, chords, feedback (helper/jobs/). Every job but check needs --consent, the token from
<out>/consent.json, which StudioSync AI writes only after you said yes; --install (pip installs the job's packages, which may then
download model weights) is refused unless that consent included the install. --dry-run makes the result's shape with no model.

Always ends by writing <out>/result.json: {"job", "status": ok|error|refused|missing, "message", "files": [names in <out>],
"data": {job-specific}, "timings": {"total_s"}, "helper_version", "packages" (when missing)}. Exit code 0 only for ok."""
import argparse, json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jobs import REGISTRY, common  # noqa: E402

VERSION = "0.1.0"


def load_opts(text):
    if text.lstrip().startswith("{"):
        opts = json.loads(text)
    else:
        with open(text, encoding="utf-8") as f:
            opts = json.load(f)
    if not isinstance(opts, dict):
        raise ValueError("--opts must be a JSON object")
    return opts


def run_job(a):
    if a.job == "check":
        return {"status": "ok", "data": {"python": sys.version.split()[0], "jobs": {n: common.describe(m) for n, m in REGISTRY.items()}}}
    mod, opts = REGISTRY[a.job], load_opts(a.opts)
    why = common.consent_problem(a.out, mod, opts, a.consent, a.install)
    if why:
        return {"status": "refused", "message": why}
    if not a.inp or not os.path.exists(a.inp):
        return {"status": "error", "message": f"no input at {a.inp!r}"}
    if a.dry_run and hasattr(mod, "example"):  # (feedback has none: its dry run builds the real request and doesn't send it)
        return mod.example(a.inp, a.out, opts)
    if a.install:
        common.install(mod, a.out)
    gone = common.missing(mod)
    if gone:
        return {"status": "missing", "packages": gone, "message": "not installed yet: " + ", ".join(gone)}
    return mod.run(a.inp, a.out, opts, dry_run=a.dry_run)


def main(argv=None):
    p = argparse.ArgumentParser(prog="ssai.py", description="StudioSync AI helper")
    p.add_argument("job", choices=sorted(REGISTRY) + ["check"])
    p.add_argument("--in", dest="inp")
    p.add_argument("--out", required=True)
    p.add_argument("--opts", default="{}")
    p.add_argument("--consent", default="")
    p.add_argument("--install", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "pid.txt"), "w") as f:  # (so StudioSync AI can stop a run that went past its time)
        f.write(str(os.getpid()))
    t0 = time.time()
    try:
        res = run_job(a)
    except Exception as e:  # (any failure still ends in a result.json, or the Lua side waits out its whole timeout)
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    res.setdefault("files", [])
    res.setdefault("data", {})
    res.setdefault("message", "")
    res.setdefault("timings", {})["total_s"] = round(time.time() - t0, 3)
    res["job"], res["helper_version"] = a.job, VERSION
    common.write_result(a.out, res)
    return 0 if res["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
