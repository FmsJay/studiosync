# StudioSync AI (optional add-on)

AI tools for a StudioSync studio, kept apart from StudioSync itself. StudioSync works the same without it. Nothing in it runs until you
pick it, and every run that uses a model asks you first.

It has two halves:

- **`studiosync_ai.lua`**: a REAPER action that pops a menu at the mouse. It renders what a tool needs, asks before anything runs, and
  brings the results into the project.
- **`helper/ssai.py`**: a small Python program that runs the tools. It lives in its own Python folder (a venv), never inside REAPER or
  StudioSync's `lib`. StudioSync only starts it and reads the files it writes, so StudioSync's GPL-3 covers StudioSync's code, and model
  weights are never bundled.

## Install

1. Keep this folder where it is: `<StudioSync>/addons/ai/`, next to StudioSync's `lib` folder (the add-on uses StudioSync's own
   render, log and background-runner code).
2. In REAPER: *Actions > Show action list > New action > Load ReaScript*, and pick `addons/ai/studiosync_ai.lua`. Put it on a key or
   a toolbar if you like.
3. That's all for **Mix feedback**: it needs no Python and no model.

The first time you use anything else, StudioSync AI asks to make its Python folder at `<REAPER resource folder>/StudioSync/ai/venv`
(it needs Python 3.11 or newer from python.org; set its path in *Settings* if it isn't found). Making the folder downloads nothing.
Each tool's packages and model weights download only when you first run that tool, and only after a box that says what will download.

## What's in the menu

| Item | Runs on | What comes back |
|---|---|---|
| Mix feedback | REAPER only, nothing leaves the computer | notes in a message box and `feedback.md`; then, if an AI is set, an offer to ask it |
| Split the mix into stems | GPU | a new track per stem |
| Find sections and tempo | GPU | regions; a tempo map only if you say yes to a second question |
| Transcribe the talk | GPU | the transcript in the project notes; regions per line if you say yes |
| Selected tracks to MIDI | CPU | a MIDI track per selected track |
| Chords and key | CPU | chord markers, and the key in the project notes |
| Master to a reference track | CPU | a new track with the matched master |
| Settings | | where to send mix feedback, the hub's address and model, a Claude key, Python's path, dry run |

Every result comes in as **one undo step**. The only exception is project notes, which REAPER doesn't track in undo. Result files are
copied into the project's media folder, so they go to the band like any other media. Each tool works on the time selection if there
is one, otherwise the whole song.

**Dry run** (in Settings): no model runs. The helper makes an example result of the right shape, so you can try the import without
installing anything. Mix feedback's "ask an AI" step then builds the real request and writes it to `request.json` (with the key
replaced by `<redacted>`) without sending it.

## Mix feedback

StudioSync AI renders the master and each shared track (StudioSync's own tracks left out) to temporary WAVs, then measures them:

- **From REAPER**, over each whole file (`CalculateNormalization`): integrated loudness (LUFS), RMS, sample peak and true peak. Crest
  factor is peak minus RMS.
- **From samples it reads itself** (64 short stretches spread through each file): stereo phase coherence and width, spectrum balance
  (20–200 Hz, 200 Hz–2 kHz and 2–20 kHz), the 200–500 Hz against 500 Hz–2 kHz tilt, and DC offset.

Fixed rules turn the numbers into notes. The thresholds are the reaper-mcp-server analyzer's (`audio_analyzer.py`, MIT, David
Schuler): peaks above −0.3 dBFS; louder than −8 LUFS for streaming, against the −14 LUFS streaming services play at; phase
coherence under 0.5; crest factor under 6 dB; low mids more than 10 dB over the upper mids; DC offset above 0.001. Mono width is only
judged on the master.

The renders are deleted afterwards. The numbers stay in `StudioSync/ai/runs/<run>/stats.json`, and the notes in `feedback.md` next
to them.

If Settings names an AI, the notes box also offers to ask it. **Only `stats.json` is sent, never audio.** The helper refuses any input
bigger than a stats summary.

- **hub**: an OpenAI-compatible server, by default the owner's AI hub at `http://127.0.0.1:4000` with model `qwen-auto` (the hub
  sends it to whichever PC is free). This loads a model onto a graphics card, so the box says so and asks.
- **claude**: the Claude API (`claude-opus-5-5` by default), billed to your own key. This is a cloud service, so the box says so and
  asks every time.

## Privacy

- **Local runs** (GPU or CPU) keep audio on this computer. The box names the model, says it runs locally, and gives a rough time and
  how much graphics memory it needs.
- **Cloud runs** send audio off the computer: LALAL.AI for stems, AssemblyAI for transcription, RoEx Tonn for mastering. Their
  modules name the service, but none is wired up yet. Each cloud run needs its own OK, and the box says plainly that the audio leaves
  this computer.
- **Asking an AI about the mix** sends only the numbers, never audio.
- **Your Claude key**: if you type it in Settings it goes into `StudioSync/ai/claude_key.txt` in your own REAPER folder. Otherwise
  it's read from `ANTHROPIC_API_KEY`. It's never written to ExtState, a log, `result.json` or `request.json`. (For now it's a plain
  file. It moves to the same protected store StudioSync uses for its Tailscale token once StudioSync's security work resumes after
  testing.)

## How a run works

1. You pick a tool. For a tool that works on tracks, the tracks must be selected first. For mastering, you're asked for the
   reference file.
2. If StudioSync AI's Python folder doesn't exist yet, it asks to make it.
3. `ssai.py check` (no consent needed, it changes nothing) reports which packages each tool still lacks.
4. **The consent box** names the model, where it runs, the time and graphics memory, the licence, and anything to download. Say No,
   and nothing runs.
5. On Yes: it renders the input to `runs/<run>/` and writes `consent.json` (job, where, install yes or no, time, a random token).
   Then it starts the helper hidden, through StudioSync's background runner:
   `ssai.py <job> --in <wav|folder|json> --out <run> --opts <run>/opts.json --consent <token> [--install] [--dry-run]`
6. REAPER keeps working while a defer loop waits for `runs/<run>/result.json`. If a run goes past its time limit, the helper is stopped.
7. The result is checked: file names must be plain names inside the run folder, and times must be numbers. Then it comes into the
   project as one undo step. For a tempo map, or a transcript as regions, you're asked again first.

The helper refuses a job unless `consent.json` matches its token, its job and its place to run. A hub OK isn't a cloud OK. The
consent must also be less than 15 minutes old, and `--install` is refused unless the consent included the download.

`result.json` contains: `job`, `status` (`ok`, `error`, `refused` or `missing`), `message`, `files` (names in the run folder),
`data` (the job's own fields, described in each `helper/jobs/<job>.py`), `timings.total_s`, `helper_version`, and `packages` when
something is missing. The helper writes it whole, then renames it into place, so it's never read half-written.

## Status

| Part | State |
|---|---|
| Mix feedback (stats, rules, notes) | real |
| Asking the hub or Claude about the numbers | real (needs your OK; nothing is sent in tests or dry runs) |
| Helper CLI, job registry, consent gating, opt-in install, result.json | real |
| Importing stems, regions, tempo map, MIDI, transcript, chords | real, tried with dry-run results |
| Stems, sections, transcription, MIDI, chords, mastering models | interfaces only: each module names its package and model, checks whether it's installed, and makes a dry-run example; the model call itself isn't written yet |
| Cloud services | named, not wired up |

## Licences of the tools (docs/ai-research.md)

| Tool | Licence | Notes |
|---|---|---|
| python-audio-separator | MIT | runs the models below |
| Demucs v4 `htdemucs_ft` (adefossez/demucs) | MIT code and weights | |
| BS-RoFormer / Mel-RoFormer weights | often no stated licence | downloaded on demand, never redistributed |
| All-In-One (`allin1`) | MIT | Windows needs NATTEN installed separately |
| faster-whisper `large-v3-turbo` | MIT code and weights | |
| pyannote `speaker-diarization-community-1` | MIT code, CC-BY-4.0 weights | needs a Hugging Face login |
| Spotify Basic Pitch | Apache-2.0 code and model | |
| ADTOF-pytorch | see its repo | drums to MIDI |
| Chordino / NNLS Chroma (sonic-annotator) | GPL-2+ | a separate program, not pip |
| libKeyFinder | GPL-3 | |
| Matchering 2 | GPL-3.0 | |
| LALAL.AI, AssemblyAI, RoEx Tonn, Claude API | the service's terms | cloud, each run asks |

To avoid: MuScriptor (weights CC-BY-NC), MMS alignment weights (CC-BY-NC), Essentia (AGPL-3, mostly NC models), madmom's models
(CC-BY-NC-SA).

The add-on's own code is GPL-3.0-or-later, like StudioSync.

## Tests

From the worktree root: `python tests/run.py` runs them with everything else. On their own:

```
python -m unittest discover -s addons/ai/tests      # helper: registry, result.json, consent gating, dry runs, feedback request
python tests/run.py --no-luals                      # includes addons/ai/tests/test_ai.lua (consent text, notes, WAV reading, import plans)
```

None of them downloads, installs or runs a model, or sends anything over the network.

## Adding a tool

Add a module to `helper/jobs/` with `NAME`, `PACKAGES`, `MODEL`, `LICENCE`, `ESTIMATE`, `CLOUD`, `where(opts)`, `run(...)` and
`example(...)`. Register it in `helper/jobs/__init__.py`. Add a row to `lib/ai_jobs.lua`, and if its result is a new kind, a branch
in `lib/ai_import.lua`'s `plan`.
