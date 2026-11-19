"""The job registry: one module per tool, by name. A new tool is a new module here plus a row in addons/ai/lib/ai_jobs.lua."""
from . import chords, feedback, master, midi, sections, stems, transcribe

REGISTRY = {m.NAME: m for m in (stems, sections, transcribe, midi, master, chords, feedback)}
