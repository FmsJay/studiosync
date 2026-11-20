# Third-party code in the extension

Each section is one library: where it came from, its version and its licence. Sections are kept separate so branches
that each add a library merge cleanly.

## WebView2 SDK (the docked web UI on Windows: extension/webui_dock.cpp)

- **Source:** the `Microsoft.Web.WebView2` NuGet package from nuget.org only
  (https://www.nuget.org/packages/Microsoft.Web.WebView2), downloaded with James's OK (2026-11-19).
- **Version:** 1.0.4314.35 (stable). Package SHA-256:
  `90778deb1b77e36292828b4b5833c9255c27533f40e0ddd55891ae718944edc4`.
- **Licence:** Microsoft's BSD-style licence in `webview2/LICENSE.txt` (redistribution in source and binary form allowed with
  the notice kept; GPL-compatible). `webview2/NOTICE.txt` is the package's third-party notice, kept beside it.
- **What's kept** (only what the build needs, byte for byte from the package):
  - `webview2/include/WebView2.h` (from `build/native/include/`)
  - `webview2/x64/WebView2LoaderStatic.lib` (from `build/native/x64/`): the static loader, so there's no `WebView2Loader.dll`
    to ship beside the extension.
  - `webview2/LICENSE.txt`, `webview2/NOTICE.txt`
- **Not kept:** WebView2EnvironmentOptions.h, the WinRT interop files, the x86/arm64 loaders, WebView2Loader.dll, the .NET
  assemblies. Add them from the same package version if a later build needs them.
- **At run time** the pages are drawn by the Microsoft Edge WebView2 Runtime installed on the computer (Windows 11 has it;
  Windows 10 may not): the extension says so and offers the browser when it's missing.
- macOS uses the system's WKWebView (WebKit.framework) and Linux has no view yet (the browser instead), so neither needs
  anything from here.

Compiled straight into `reaper_studiosync` (static: no extra DLL, dylib or .so) for live audio, `extension/rtaudio.cpp`
(docs/realtime-roadmap.md step 4). Only the files the build needs are kept; each is byte-for-byte the upstream file at the commit
below, except one patch: `aoo/aoo/src/codec/opus.cpp` passes `OPUS_SET_PREDICTION_DISABLED` to the encoder (marked "StudioSync's one
patch"), so a stream turned back on decodes at full level at once (the hub's live mix falling back to direct streams). No nested `.git`.
A `build\studiosync_deps-x64.lib` made before that patch still links and works, without it: delete `build\` once to rebuild it.

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
Linux: `build_unix.sh` here (cc/c++, symbols hidden so another plug-in's own AOO or Opus can't clash), run by
`.github/workflows/extension.yml`. The `AOO_*` defines must match the top of `extension/rtaudio.cpp`.

**Updating.** Fetch the new tag from the same place, copy the same folders over, check `sources.txt` against upstream's lists,
update the table above, delete `build/`, rebuild and run `tests/build_rtaudio_test.cmd`.

## libjuice and Monocypher (the connection without Tailscale: extension/nat.cpp, tests/nat_test.cpp, tests/nat_audio_test.cpp)

**In the shipped extension since stage 1 (2026-11-20).** `build_windows.cmd` here builds them once into `build/studiosync_nat-x64.lib`
(linked by `extension/build_windows.cmd`); `build_unix.sh` puts them in the same archive as AOO and Opus, symbols hidden. A release that
ships the extension ships `libjuice/LICENSE` and `monocypher/LICENCE.md` beside it, as AOO's and Opus's licences.
Design: docs/realtime-roadmap.md "Without Tailscale: design". Each file is byte for byte upstream's at the commit below (nothing patched),
no nested `.git`. Downloaded with `git clone --depth 1 --branch <tag>` from the official repositories only (2026-11-19).

| Folder | What | From | Version | Licence |
|---|---|---|---|---|
| `libjuice/` | ICE (RFC 8445) with STUN/TURN client, and a STUN/TURN server; C, no dependencies | https://github.com/paullouisageneau/libjuice (Paul-Louis Ageneau, the canonical repository) | tag `v1.7.4`, commit `b89c792e3612faf2f12cf35bcc56857313a06be3` (2026-09-27) | MPL-2.0, `libjuice/LICENSE` |
| `monocypher/` | X25519 and XChaCha20-Poly1305 (`crypto_x25519`, `crypto_aead_lock`/`unlock`), one C file | https://github.com/LoupVaillant/Monocypher (Loup Vaillant, the canonical repository) | tag `4.0.3`, commit `ab2b16dd619ad5f6979a4fbe69cfa324a6fcc35f` (2026-06-15) | CC0-1.0 or BSD-2-Clause (either), `monocypher/LICENCE.md` |

**GPL compatibility.** MPL-2.0 is a file-level copyleft that names the GPL as a "Secondary License" (section 3.3): MPL files may be part
of a larger GPL-3.0-or-later work unless a file carries Exhibit B's "Incompatible With Secondary Licenses" notice, and none of libjuice's
does (checked: the phrase is only in `LICENSE`'s own text). What MPL asks: these files stay under MPL-2.0 (changes to them too, and
then published), their source stays available (it's here), and the notices go with binaries (a release that ships this ships
`libjuice/LICENSE` beside the extension). Monocypher's CC0/BSD-2 is permissive (BSD-2's notice goes with binaries).

**Kept.** libjuice: `LICENSE`, `README.md`, `include/juice/juice.h`, `src/*.c` and `src/*.h` (all of upstream's `LIBJUICE_SOURCES`;
no `test/`, `fuzzer/`, CMake files). Built with `-DJUICE_STATIC` and `-I libjuice/include/juice`; Windows links `ws2_32` and `bcrypt`.
Monocypher: `LICENCE.md`, `README.md`, `monocypher.c`, `monocypher.h` (no `optional/`: SHA-512/Ed25519 aren't used).

**Updating.** Fetch the new tag from the same place, copy the same files over, check upstream's `LIBJUICE_SOURCES` in
`CMakeLists.txt` against `src/`, update the table above and run `tests/build_nat_test.cmd`.
