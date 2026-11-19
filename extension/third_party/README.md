# Third-party code in the extension

Compiled straight into `reaper_studiosync` (static: no extra DLL, dylib or .so) for live audio, `extension/rtaudio.cpp`
(docs/realtime-roadmap.md step 4). Only the files the build needs are kept; each is byte-for-byte the upstream file at the commit
below (nothing patched). No nested `.git`.

| Folder | What | From | Version | Licence |
|---|---|---|---|---|
| `aoo/` | AOO (audio over OSC) 2.0: the source/sink streaming engine inside SonoBus (jitter buffer, drift-correcting resampler, Opus and PCM codecs) | https://git.iem.at/aoo/aoo (IEM, the canonical repository) | tag `v2.0-pre4`, commit `dc2a5be2962ba02d6cebe297f31f2774f34e7bc7` (2024-10-11) | BSD-3-Clause style ("Standard Improved BSD License"), `aoo/LICENSE` |
| `aoo/deps/oscpack/` | oscpack, AOO's OSC message reader/writer (ships inside AOO) | the same AOO commit | as in AOO | MIT, `aoo/deps/oscpack/LICENSE` |
| `opus/` | libopus, the Opus codec | https://github.com/xiph/opus | tag `v1.6.1`, commit `22244de5a79bd1d6d623c32e72bf1954b56235be` (2026-01-13) | BSD-3-Clause, `opus/COPYING` (patent grants: `opus/LICENSE_PLEASE_READ.txt`) |

**GPL compatibility.** StudioSync is GPL-3.0-or-later. BSD-3-Clause and MIT are permissive licences the FSF lists as
GPL-compatible: their code may be combined into a GPL program, as long as their copyright notices and licence texts go with the
source and the binaries (the LICENSE/COPYING files here; a release ships this folder's licence files beside the extension). AOO's
"non-binding requests" (send changes upstream) are requests, not conditions.

**Kept.** AOO: `LICENSE`, `README.md`, `include/` (the public API), `aoo/src/` (the library without the server/client network
part: built with `AOO_NET=0`), `common/`, `deps/oscpack/`, `doc/aoo_protocol.md`. Opus: `COPYING`, `AUTHORS`, `README`,
`LICENSE_PLEASE_READ.txt`, `include/`, `celt/`, `silk/` and `silk/float/`, `src/` (no `dnn/`: no Deep PLC/DRED yet, no SIMD paths:
one plain-C build runs on every CPU).

**Built by.** `sources.txt` in each folder lists the files compiled (taken from upstream's `CMakeLists.txt` / `opus_sources.mk`,
`silk_sources.mk`, `celt_sources.mk` for a float build without SIMD). Windows: `build_windows.cmd` here (MSVC, /MT, into
`build/studiosync_deps-x64.lib`, kept out of git), called by `extension/build_windows.cmd` when the library is missing. macOS and
Linux: `.github/workflows/extension.yml` compiles the same lists. The `AOO_*` defines must match the top of `extension/rtaudio.cpp`.

**Updating.** Fetch the new tag from the same place, copy the same folders over, check `sources.txt` against upstream's lists,
update the table above, delete `build/`, rebuild and run `tests/build_rtaudio_test.cmd`.
