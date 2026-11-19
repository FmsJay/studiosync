"""Song sections, beats and tempo (docs/ai-research.md section 5).
Would use All-In-One (allin1, MIT): BPM, beats, downbeats and labelled sections in one pass. Known issue: half or double the real tempo
sometimes, so the Lua side asks before writing a tempo map. Windows needs NATTEN installed separately.
Result contract: data = {"bpm": 120.0, "beats_per_bar": 4, "beats": [s...], "downbeats": [s...],
"segments": [{"start": s, "end": s, "label": "verse"}, ...]}, times in seconds from the start of the input."""
from . import common

NAME = "sections"
PACKAGES = [("allin1", "allin1")]
MODEL = "All-In-One (allin1)"
LICENCE = "MIT"
ESTIMATE = "not measured here yet; a GPU run, minutes at most per song"
CLOUD = ""


def where(opts):
    return "gpu"


def example(inp, out, opts):
    secs, bpm = common.wav_seconds(inp), 120.0
    bar = 4 * 60.0 / bpm
    labels = ["intro", "verse", "chorus", "verse", "chorus", "outro"]
    segs, t, i = [], 0.0, 0
    while t < secs:
        segs.append({"start": t, "end": min(t + 4 * bar, secs), "label": labels[i % len(labels)]})
        t, i = t + 4 * bar, i + 1
    downbeats = [k * bar for k in range(int(secs // bar) + 1)]
    return {"status": "ok", "files": [], "data": {"bpm": bpm, "beats_per_bar": 4, "downbeats": downbeats, "segments": segs}}


def run(inp, out, opts, dry_run=False):
    return example(inp, out, opts) if dry_run else common.not_built(NAME)
