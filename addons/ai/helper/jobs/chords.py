"""Chords and key (docs/ai-research.md section 5).
Would use the Chordino / NNLS Chroma Vamp plug-in through sonic-annotator (GPL-2+) for chords and libKeyFinder (GPL-3) for the key:
both CPU-only and GPL-compatible. They're programs, not pip packages: the check looks for sonic-annotator on PATH.
Result contract: data = {"key": "A minor", "chords": [{"start": s, "end": s, "label": "Am"}, ...]}."""
import shutil
from . import common

NAME = "chords"
PACKAGES = []
MODEL = "Chordino / NNLS Chroma (through sonic-annotator) + libKeyFinder"
LICENCE = "Chordino: GPL-2+; libKeyFinder: GPL-3"
ESTIMATE = "seconds, on the CPU (no graphics memory)"
CLOUD = ""


def where(opts):
    return "cpu"


def example(inp, out, opts):
    secs = common.wav_seconds(inp)
    names, chords, t, i = ["Am", "F", "C", "G"], [], 0.0, 0
    while t < secs:
        chords.append({"start": t, "end": min(t + 2.0, secs), "label": names[i % 4]})
        t, i = t + 2.0, i + 1
    return {"status": "ok", "files": [], "data": {"key": "A minor", "chords": chords}}


def run(inp, out, opts, dry_run=False):
    if dry_run:
        return example(inp, out, opts)
    if not shutil.which("sonic-annotator"):
        return {"status": "missing", "packages": ["sonic-annotator (with the NNLS Chroma Vamp plug-in)"],
                "message": "sonic-annotator isn't installed: it's a separate program, not something pip can add"}
    return common.not_built(NAME)
