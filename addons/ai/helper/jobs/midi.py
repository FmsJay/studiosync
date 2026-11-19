"""Audio to MIDI (docs/ai-research.md section 3).
Would use Spotify Basic Pitch (Apache-2.0 code and model, CPU) per stem, and ADTOF-pytorch for drums (five classes, GM channel 10).
--in is one WAV or a folder of them (one per track); one MIDI file each.
Result contract: files = the .mid files; data = {"midi": [{"name": "Bass", "file": "bass.mid"}, ...]}, each starting where its input does."""
import os, struct
from . import common

NAME = "midi"
PACKAGES = [("basic-pitch", "basic_pitch")]
MODEL = "Spotify Basic Pitch (ADTOF for drums)"
LICENCE = "Apache-2.0 (code and model)"
ESTIMATE = "near-instant, on the CPU (no graphics memory)"
CLOUD = ""


def where(opts):
    return "cpu"


def tiny_midi(path, notes):
    """A one-track MIDI file (480 ticks per beat, 120 BPM): `notes` as (start beat, length in beats, pitch)."""
    ev = []
    for start, length, pitch in notes:
        ev += [(int(start * 480), 0x90, pitch, 100), (int((start + length) * 480), 0x80, pitch, 0)]
    ev.sort()
    body, now = b"", 0

    def vlq(n):
        out = [n & 0x7F]
        n >>= 7
        while n:
            out.insert(0, (n & 0x7F) | 0x80)
            n >>= 7
        return bytes(out)

    for tick, status, pitch, vel in ev:
        body += vlq(tick - now) + bytes([status, pitch, vel])
        now = tick
    body += b"\x00\xff\x2f\x00"
    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480) + b"MTrk" + struct.pack(">I", len(body)) + body)


def example(inp, out, opts):
    wavs = [os.path.join(inp, f) for f in sorted(os.listdir(inp)) if f.lower().endswith(".wav")] if os.path.isdir(inp) else [inp]
    items = []
    for w in wavs:
        name = os.path.splitext(os.path.basename(w))[0]
        f = f"{name}.mid"
        tiny_midi(os.path.join(out, f), [(0, 1, 60), (1, 1, 64), (2, 2, 67)])
        items.append({"name": name, "file": f})
    return {"status": "ok", "files": [i["file"] for i in items], "data": {"midi": items}}


def run(inp, out, opts, dry_run=False):
    return example(inp, out, opts) if dry_run else common.not_built(NAME)
