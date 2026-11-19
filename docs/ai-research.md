# StudioSync optional AI features: tool survey (checked 2026-11-19)

**How they plug in (same for every job).** Run the AI tools as a separate Python program, not linked into StudioSync. Then GPL-3 only governs StudioSync's own code, and model weights download only after the user says OK, never bundled. Flow: Lua renders the region or stem to WAV, calls `reaper.ExecProcess` (or the extension) to run the tool, which writes WAV, MIDI or JSON. Lua then imports the result: stems with `InsertMedia`, MIDI files as items, sections with `AddProjectMarker2`, the tempo map with `SetTempoTimeSigMarker`, transcripts as region names or item notes. Cloud runs mean audio leaves the band's computers, so each needs its own consent prompt. Sending the LLM only the stats is the exception: no audio leaves.

Speed figures are my estimates from typical results on an RTX 4080, not benchmarks run on this machine.

## 1. Stem separation
- **Local pick: python-audio-separator** (MIT code; v0.44.x, mid-2026). One command-line tool runs the UVR model zoo:
  - Vocals: BS-RoFormer or Mel-RoFormer (~10.7–10.8 SDR vocals, ~17 instrumental on MVSEP Multisong).
  - Bass, drums and other: Demucs v4 `htdemucs_ft`. MVSEP still rates it best for those three.
  - Demucs's maintained home is now `adefossez/demucs` (v4.1.0, 2026-07-11, MIT code and weights). The facebookresearch repo is archived.
  - SCNet-Large (10.74 vocals) is similar in quality.
  - Speed: about 15–60 s per 4-minute song, 4–8 GB VRAM. Apple silicon runs it through MPS several times slower; `mlx-audio-separator` is a native Mac port.
  - Licence risk: many community RoFormer weights have no stated licence. Download them on demand and never redistribute them.
- **Cloud pick: LALAL.AI API**, about $0.06/min on the $300 / 5,000-minute pack, REST/OpenAPI.
  - AudioShake claims the top spot in Meta's evaluation, but costs about $1/min on demand (third-party figure).
  - Music.AI (the company behind Moises) is sales-quote only. StemSplit is $0.10/min.
  - The best local models are now close to the cloud services, so cloud is mainly useful for the Mac or laptop when the GPU is busy.

## 2. Transcription of talk and lyrics, plus who is speaking
- **Local pick:**
  - Windows: faster-whisper `large-v3-turbo` (MIT code and weights). About 3–6 GB VRAM, roughly 50x+ realtime.
  - Alternative: Parakeet-TDT-0.6B-v3 (CC-BY-4.0, about 6.0–6.2% WER, the fastest open model).
  - Mac: whisper.cpp (Metal) or `parakeet-mlx`.
  - Who is speaking: pyannote `speaker-diarization-community-1` (MIT code, CC-BY-4.0 weights, Hugging Face login gate).
  - Leaderboard (Oct 2026): Whisper large-v3 is about 7.2% WER, behind Qwen3-ASR-1.7B (~5.4%), Canary-Qwen-2.5B (~5.9%) and NVIDIA Nemotron 3.5 Transcribe (~5.3%, released 2026-10-28, OpenMDW licence, has speaker labels built in).
  - Nemotron 3.5 Transcribe is a large mixture-of-experts model, NVIDIA GPUs only. Too heavy for "talk notes".
- **Lyrics:** separate the vocals first (job 1), then run WhisperX (BSD) for word timings. Import as take markers or text items. Avoid MMS alignment weights (CC-BY-NC).
- **Cloud pick: AssemblyAI**, about $0.15–0.21/hr, speaker labels included.
  - Deepgram Nova-3: $0.0043/min batch.
  - OpenAI gpt-4o-transcribe: $0.006/min. Reported deprecated, with shutdown 2027-02-26.

## 3. Audio to MIDI
- **Local pick: Spotify Basic Pitch** (Apache-2.0 code and model, works on CPU, near-instant).
  - Best on one instrument at a time, so run it per stem. NeuralNote (Apache-2.0) is the same model as a plug-in.
  - Drums: ADTOF-pytorch, five classes (kick, snare, toms, hi-hat, cymbals), General MIDI channel 10. Still the best open option in 2026.
  - Whole-mix multi-instrument: YourMT3+ (strong, heavy GPU; check the weights licence).
  - Skip MuScriptor (2026): its weights are CC-BY-NC.
- **Cloud:** I found no strong API. Music.AI offers transcription modules on a sales quote. Local is the right default here.

## 4. Mastering and mix help
- **Local pick: Matchering 2** (GPL-3.0, the same licence as StudioSync, so it can ship inside). Matches a mix to a reference track's loudness, EQ and stereo width. Runs on CPU in seconds.
- **AI mix feedback (best value of anything here).** Send the loudness, spectrum, crest and phase stats StudioSync and the reaper MCP analyzer already compute to an LLM as JSON. Keep the analyzer's thresholds (-0.3 dBFS, -14 LUFS, 0.5 phase, 6 dB crest).
  - No audio leaves the band's computers.
  - Use the owner's hub (`qwen-desktop`) when he OKs a GPU run; otherwise Claude through the API.
  - A small model handles stats-only prompts fine.
- **Cloud pick: RoEx Tonn API**, self-serve: $1.76–2.20 per full master, plus multitrack mixing and a mix-analysis endpoint. LANDR's mastering API is sales-quote only.

## 5. Chords, key, tempo, beats, song sections
- **Local pick: All-In-One (`allin1`, MIT).** Gives BPM, beats, downbeats and labelled sections (intro, verse, chorus) in one pass.
  - Output maps directly onto REAPER regions and the tempo map.
  - Known issue: sometimes gives half or double the real tempo; let the user correct it.
  - Windows needs NATTEN installed separately.
- **Chords:** Chordino / NNLS Chroma Vamp plug-in (GPL-2+, so GPL-3 compatible), run through sonic-annotator.
- **Key:** libKeyFinder (GPL-3).
- **Avoid bundling:** Essentia (AGPL-3, mostly NC models) and madmom's models (CC-BY-NC-SA). BeatNet is a lighter real-time beat tracker.
- **Cloud:** Music.AI workflows (sales quote). Not worth the money for this job.

## 6. Other useful models
- **Search across takes ("find the take where..."):** CLAP audio–text embeddings. LAION-CLAP (CC0 repo) or MS-CLAP (MIT).
  - Embed every take once in the background (CPU is fine), store the vectors in project ExtState or a sidecar file, then search by text or by an example take.
  - Low cost and fits StudioSync's take sync.
- **Auto-comping:** needs no new model.
  - Pitch: Basic Pitch or torchcrepe (MIT) pitch contour against the guide or MIDI.
  - Timing: onset offset from the grid.
  - Combine them into a score for each take, highlight the best one per phrase, and let the user approve the comp.
- **Noise:** DeepFilterNet (MIT/Apache) for talkback and remote-call audio, realtime on CPU. Resemble Enhance (MIT) for damaged speech. For music hum, ReaFIR or notch filters beat neural models.
- **De-reverb and de-echo:** the UVR de-reverb RoFormer models through audio-separator, which costs nothing extra if job 1 ships.
- **Sample and sound-effect generation:** Stable Audio 3.0 Small and Medium (459M / 1.4B, open weights since 2026-05-20).
  - Community License: free commercial use under $1M annual revenue. Not open source, so never bundle it; download on demand.
- **Voice to instrument:** hum, run Basic Pitch, put the MIDI on any instrument (reuses job 3).
- **Lyric help:** the same LLM route as mix feedback, text only.

## Overall top 8 for StudioSync, ranked by value
1. **LLM mix feedback on existing stats.** Least new code, no audio leaves, works on all 4 machines.
2. **Stem separation (audio-separator: RoFormer + htdemucs_ft)**, with LALAL.AI as the cloud fallback.
3. **allin1 structure and tempo map into regions.** One pass gives the band shared section markers.
4. **Session-talk transcription.** faster-whisper turbo / Parakeet + pyannote, AssemblyAI as cloud. Searchable session notes.
5. **Basic Pitch + ADTOF audio to MIDI**, per stem (builds on #2).
6. **CLAP take search + scored auto-comping.**
7. **Matchering reference mastering.** GPL-3, can ship inside StudioSync. RoEx Tonn for a cloud master.
8. **Chordino + libKeyFinder chord/key track.** GPL-compatible, CPU-only.

Honourable mentions: DeepFilterNet for call audio; Stable Audio 3.0 Small for samples.

## Sources
- MVSEP algorithms: https://mvsep.com/algorithms
- AudioShake / Meta evaluation: https://www.audioshake.ai/post/meta-tested-the-leading-audio-separation-models-audioshake-came-out-on-top
- python-audio-separator: https://github.com/nomadkaraoke/python-audio-separator/releases
- mlx-audio-separator: https://pypi.org/project/mlx-audio-separator/
- Demucs (maintained): https://raw.githubusercontent.com/adefossez/demucs/main/README.md
- LALAL.AI pricing: https://aitoolsatlas.ai/tools/lalal-ai/pricing
- StemSplit API: https://stemsplit.io/blog/stemsplit-api-launch
- Music.AI FAQ: https://music.ai/docs/faq/
- Open ASR Leaderboard: https://github.com/huggingface/open_asr_leaderboard
- ASR roundup (Oct 2026): https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks
- Nemotron 3.5 Transcribe: https://fourweekmba.com/ai-nvidia-releases-a-free-speech-ai-model-rivaling-qwens-asr/ and https://www.digitalapplied.com/blog/nemotron-3-5-transcribe-vs-whisper-parakeet
- parakeet-mlx: https://pypi.org/project/parakeet-mlx/
- pyannote community-1: https://huggingface.co/pyannote/speaker-diarization-community-1
- Cloud ASR pricing: https://convertaudiototext.com/blog/deepgram-nova-3-explained, https://assemblyai.com/blog/speech-to-text-api-pricing, https://convertaudiototext.com/blog/speech-to-text-api-pricing-2026
- YourMT3+: https://arxiv.org/html/2407.04822v3
- MuScriptor: https://huggingface.co/MuScriptor/muscriptor-small/blob/main/README.md
- ADTOF: https://github.com/MZehren/ADTOF
- Drum stem ADT: https://www.themoonlight.io/review/enhanced-automatic-drum-transcription-via-drum-stem-source-separation
- RoEx Tonn pricing: https://tonn-portal.roexaudio.com/pricing
- LANDR API: https://costbench.com/software/ai-music-apis/landr-api/
- allin1: https://pypi.org/project/allin1
- Stable Audio 3.0: https://the-decoder.com/stability-ai-launches-stable-audio-3-0-with-up-to-six-minute-tracks-and-open-weights/
- Stability licence: https://stability.ai/license
