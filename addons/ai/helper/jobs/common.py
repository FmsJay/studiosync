"""What every StudioSync AI job shares: the consent check, the package check, the opt-in install, and result.json.

A job module sets NAME, PACKAGES [(pip name, import name)], MODEL, LICENCE, ESTIMATE, CLOUD (the cloud service it can use instead,
or ""), where(opts) -> "gpu" | "cpu" | "cloud" | "none", run(inp, out, opts, dry_run) -> a result dict, and example(inp, out, opts)
(the result's shape with no model, for dry runs: the Lua side's import can be tried before anything is installed)."""
import hmac, importlib.util, json, os, shutil, subprocess, sys, time

CONSENT_MAX_AGE = 15 * 60  # seconds: a consent is for this run, not for later


def consent_problem(out, mod, opts, token, install):
    """Why this run may not go ahead, or None. The Lua side writes <out>/consent.json only after the person said yes, and passes its
    token: no token, a different one, another job, another place to run (a hub OK isn't a cloud OK), a stale one, or an install
    nobody agreed to are all refused."""
    if not token:
        return "no consent token: StudioSync AI asks you first, then passes one"
    try:
        with open(os.path.join(out, "consent.json"), encoding="utf-8") as f:
            c = json.load(f)
    except (OSError, ValueError):
        return "no consent record in the run folder"
    if not isinstance(c, dict) or not hmac.compare_digest(str(c.get("token", "")), token):
        return "the consent token doesn't match this run's record"
    if c.get("job") != mod.NAME:
        return f"consent was given for {c.get('job')!r}, not {mod.NAME!r}"
    if c.get("where") != mod.where(opts):
        return f"consent was given to run on {c.get('where')!r}, but this would run on {mod.where(opts)!r}"
    try:
        age = time.time() - float(c.get("at", 0))
    except (TypeError, ValueError):
        age = CONSENT_MAX_AGE + 1
    if age > CONSENT_MAX_AGE:
        return "that consent is more than 15 minutes old: ask again"
    if install and not c.get("install"):
        return "installing wasn't agreed to"
    return None


def missing(mod):
    """The pip packages of a job that aren't importable here."""
    def absent(name):
        try:
            return importlib.util.find_spec(name) is None
        except ModuleNotFoundError:  # (a dotted name whose parent isn't there: pyannote.audio without pyannote)
            return True
    return [pip for pip, imp in mod.PACKAGES if absent(imp)]


def install(mod, out):
    """pip install the job's packages into this Python (the add-on's own venv). Only ever called with --install, which the Lua side
    passes only after the person agreed to the download. Output goes to <out>/install.log."""
    pkgs = missing(mod)
    if not pkgs:
        return
    with open(os.path.join(out, "install.log"), "w", encoding="utf-8") as log:
        subprocess.run([sys.executable, "-m", "pip", "install", *pkgs], stdout=log, stderr=subprocess.STDOUT, check=False)


def describe(mod):
    return {"model": mod.MODEL, "licence": mod.LICENCE, "estimate": mod.ESTIMATE, "cloud": mod.CLOUD,
            "packages": [p for p, _ in mod.PACKAGES], "missing": missing(mod)}


def not_built(name):
    return {"status": "error", "message": f"the {name} job is an interface only so far: its model isn't wired in yet (dry run works)"}


def copy_as(inp, out, names):
    """Dry-run helper: the input copied under each name. -> the names written."""
    for n in names:
        shutil.copyfile(inp, os.path.join(out, n))
    return list(names)


def wav_seconds(path, default=32.0):
    """A WAV's length, for dry-run examples; `default` when the wave module can't read it (24-bit extensible on old Pythons)."""
    import wave
    try:
        with wave.open(path, "rb") as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        return default


def write_result(out, res):
    """result.json, written whole: to a temporary name, then renamed over, so the Lua side polling it never reads half a file."""
    path = os.path.join(out, "result.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, sort_keys=True)
    os.replace(tmp, path)
