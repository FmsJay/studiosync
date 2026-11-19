"""Stem separation (docs/ai-research.md section 1).
Would use python-audio-separator (MIT, v0.44.x): BS-RoFormer or Mel-RoFormer for vocals, Demucs v4 htdemucs_ft for drums, bass, other.
Cloud alternative: LALAL.AI (about $0.06/min); audio leaves the computer, so it needs its own OK.
Result contract: files = the stem WAVs; data = {"stems": [{"name": "Vocals", "file": "vocals.wav"}, ...]}, each as long as the input
and starting where it starts."""
from . import common

NAME = "stems"
PACKAGES = [("audio-separator", "audio_separator")]
MODEL = "BS-RoFormer (vocals) + Demucs htdemucs_ft (drums, bass, other), through python-audio-separator"
LICENCE = "audio-separator and Demucs: MIT code (Demucs weights MIT too). Many community RoFormer weights state no licence: downloaded on demand, never shared"
ESTIMATE = "about 15-60 s per 4-minute song, 4-8 GB of graphics memory (RTX 4080 estimate)"
CLOUD = "LALAL.AI"


def where(opts):
    return "cloud" if opts.get("cloud") else "gpu"


def example(inp, out, opts):
    names = ["Vocals", "Drums", "Bass", "Other"]
    files = common.copy_as(inp, out, [n.lower() + ".wav" for n in names])
    return {"status": "ok", "files": files, "data": {"stems": [{"name": n, "file": f} for n, f in zip(names, files)]}}


def run(inp, out, opts, dry_run=False):
    return example(inp, out, opts) if dry_run else common.not_built(NAME)
