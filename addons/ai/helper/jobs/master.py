"""Reference mastering (docs/ai-research.md section 4).
Would use Matchering 2 (GPL-3.0, CPU): matches the mix to a reference track's loudness, EQ and stereo width. opts["reference"] is the
reference WAV. Cloud alternative: RoEx Tonn (about $1.76-2.20 per master).
Result contract: files = ["master.wav"]; data = {"stems": [{"name": "Master (matched)", "file": "master.wav"}]} (imported like a stem)."""
from . import common

NAME = "master"
PACKAGES = [("matchering", "matchering")]
MODEL = "Matchering 2"
LICENCE = "GPL-3.0 (the same as StudioSync)"
ESTIMATE = "seconds, on the CPU (no graphics memory)"
CLOUD = "RoEx Tonn"


def where(opts):
    return "cloud" if opts.get("cloud") else "cpu"


def example(inp, out, opts):
    files = common.copy_as(inp, out, ["master.wav"])
    return {"status": "ok", "files": files, "data": {"stems": [{"name": "Master (matched)", "file": "master.wav"}]}}


def run(inp, out, opts, dry_run=False):
    return example(inp, out, opts) if dry_run else common.not_built(NAME)
