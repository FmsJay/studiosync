"""Session talk and lyrics, with who is speaking (docs/ai-research.md section 2).
Would use faster-whisper large-v3-turbo (MIT code and weights), and pyannote speaker-diarization-community-1 for speakers (MIT code,
CC-BY-4.0 weights behind a Hugging Face login). Mac: whisper.cpp or parakeet-mlx. Cloud alternative: AssemblyAI (speaker labels included).
Result contract: files = ["transcript.txt"]; data = {"segments": [{"start": s, "end": s, "speaker": "Speaker 1", "text": "..."}, ...]}."""
import os
from . import common

NAME = "transcribe"
PACKAGES = [("faster-whisper", "faster_whisper"), ("pyannote.audio", "pyannote.audio")]
MODEL = "faster-whisper large-v3-turbo, with pyannote community-1 for who is speaking"
LICENCE = "faster-whisper: MIT code and weights. pyannote: MIT code, CC-BY-4.0 weights (needs a Hugging Face login)"
ESTIMATE = "roughly 50x realtime, 3-6 GB of graphics memory (RTX 4080 estimate)"
CLOUD = "AssemblyAI"


def where(opts):
    return "cloud" if opts.get("cloud") else "gpu"


def example(inp, out, opts):
    segs = [{"start": 0.0, "end": 3.5, "speaker": "Speaker 1", "text": "(dry run) Let's take it from the chorus."},
            {"start": 4.0, "end": 6.0, "speaker": "Speaker 2", "text": "(dry run) Okay, one more."}]
    with open(os.path.join(out, "transcript.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(f"{s['speaker']}: {s['text']}" for s in segs) + "\n")
    return {"status": "ok", "files": ["transcript.txt"], "data": {"segments": segs}}


def run(inp, out, opts, dry_run=False):
    return example(inp, out, opts) if dry_run else common.not_built(NAME)
