# REAPER's video in a shared project (rt-video2, 2026-11-20; Lua and native tests, a stand-in server in Chromium; not run in REAPER yet)

James: "Support for reapers video functions as well".

## What already worked (checked first, with a real clip)
A 3 s H.264 clip with sound (`tests/fixtures/tiny.mp4`, 96x54, ffmpeg's test pattern and a tone, 13.7 KB) went through the existing paths
unchanged:
- `mirror.share_media` copies a `<SOURCE VIDEO>` item's file into the room's media and points the item at `{media:<room>}/<hash>-tiny.mp4`; a
  file over `band.BIG` (a music video) is copied in the background and the item held until it's there, as a long recording is.
- `mirror.normalize_item` keeps the source and its lines; `streams.media_new` / `offer_media` send the copy over the link as media
  (`~media~<room>~<file>`, begun and ended at once: resumable, SHA-256 checked by the extension), the receiver puts it in place, and catch-up
  asks for videos as for audio. Size cap: 16 GB, as any file.
- The Video processor (`<VIDEO_EFFECT "Video processor" "">` with its code as `|` lines in `<CODE>`, then `CODEPARM`) travels as any plug-in
  block in the chain: its code arrives as written (only REAPER's indent taken off), `<` and `>` inside the code don't confuse the block parser,
  its window position stays each computer's, and normalizing twice gives the same text (no resend loop).
- The video window is each computer's own: REAPER keeps it in `reaper.ini` `[reaper_video]` (visible, position, fullscreen), never in the
  project, and StudioSync doesn't share any of it.

## Gaps found and fixed
- **The Video processor read as a missing plug-in.** It isn't on anyone's published plug-in list (`plugins.installed` lists VST/VST3/CLAP/
  AU/LV2/JS only), so `prints.lacking` printed every part on a track with one, `prints.has` said no bandmate could print it or render its
  stem, and Health's "who lacks" named everyone. `video.builtin_fx` (by `fx_type` or the original name) now counts it as everyone's in
  `prints.lacking`, `prints.has`, `prints.who_lacks` and `prints.fx_here`.
- **More video files over the link.** The link's list (`direct.lua` STREAM_EXT, `chatfiles.EXTS`, `extension/direct.cpp`
  `direct_stream_rel_ok`) gains `m4a` (audio REAPER plays through its video decoder: a YouTube download is often one), `m4v`, `mkv`, `avi`
  and `gif`. Needs extension 1.0.25 at both ends; with an older one these go through Syncthing as before (an older receiver refuses the name
  and counts a rejection).
- **The project's video settings** (Project settings > Video: `VIDEO_CONFIG w h flags`) travel with the other project settings:
  `band.PROJECT_CFG` gains `projvidw`, `projvidh`, `projvidflags` (SWS config names, found in reaper.exe beside the `VIDEO_CONFIG %d %d %d`
  format). `sync.TIMELINE_FORMAT` 4 -> 5 so the first look after updating isn't taken for an edit (a one-line constant in sync.lua).
- **Background renders:** the hidden REAPER's `reaper.ini` copy (`bgrender.profile_ini`) now has `[reaper_video] visible=0, fullscreen=0`,
  so a print or bounce of a project with video doesn't open a video window nobody sees. Prints and bounces set their own render format
  (FLAC / 24-bit WAV), so a project whose render format is a video format still prints audio; `band.render` puts the video format back after.
- **Big files say how far they've got:** Health's "direct streams" row shows an incoming media file as "12.00 of 480.00 MB (2%)" (the
  announced size), not only "so far".
- **Thumbnails on the Project page and the phone's Project view.** A video or picture item carries `v = { id, k, o, r }` (lib/dawview.lua via
  `video.take`): an id the web server knows, video or picture, where in the file the item starts, its playrate. Only files inside the studio's
  shared folder are offered (`StudioSync_WebUIOffer`, at most 16 at once, the least recently drawn withdrawn); an item of yours not shared
  yet, or an `.m4a`, shows its waveform as before. `lib/webui/video.js` reads frames in the page: one hidden `<video>` per file seeks to each
  wanted moment (a grid of power-of-two seconds in the file, so zoom and scroll reuse frames), keeps a small canvas per frame (400 at most),
  and daw.js / phonedaw.js draw them under a fainter waveform; a picture is tiled. A file the browser can't play shows no frames.
- **The web server answers byte ranges** (extension/webui.cpp `send_file`, extension 1.0.25): `Range: bytes=a-b | a- | -n` -> 206 with
  `Content-Range`, past the end -> 416, several ranges or a malformed header -> the whole file; `Accept-Ranges: bytes` always; offered video
  and pictures typed (`video/mp4`, `video/quicktime`, `video/webm`, `video/x-matroska`, `image/png|jpeg|gif`), everything else still
  `application/octet-stream` (never a type a browser runs). A `<video>` then fetches only what it seeks to, and Safari plays at all.
- **Found on the way (not video):** `lib/webui/phonedaw.js` had a real line break inside a string (`parts.join('` newline `')`, from
  44241b8), so the whole file failed to parse and the phone's Project, Sheet and Play views didn't work. Fixed to `'\n'`; every
  `lib/webui/*.js` now passes `node --check`.

## Files
- New: `lib/video.lua`, `lib/webui/video.js`, `tests/test_0_60_rt_video.lua`, `tests/fixtures/tiny.mp4`.
- Changed: `lib/dawview.lua` (item `v`, `video.root`), `lib/prints.lua`, `lib/band.lua` (PROJECT_CFG), `lib/sync.lua` (TIMELINE_FORMAT
  only), `lib/bgrender.lua` (profile_ini), `lib/streams.lua` (Health percent), `lib/direct.lua`, `lib/chatfiles.lua`,
  `extension/direct.cpp`, `extension/webui.cpp` (send_file, offer_type, byte_range, reason 206/416), `tests/direct_test.cpp`,
  `tests/webui_test.cpp`. Shared web files, additive lines only: `lib/webui/daw.js` (2 lines), `lib/webui/phonedaw.js` (2 lines + the
  fix), `lib/webui/index.html` and `record.html` (the script tag), `lib/webui/phone-sw.js` (video.js in the shell, cache ss-phone-4).

## Tests
- `tests/test_0_60_rt_video.lua`: the clip through share_media (small and 3 GB), normalize, media_new/offer/receive/place, catch-up, the
  link's names, the 16 GB cap, Health's percent, the Video processor chain round trip, prints with it, PROJECT_CFG, profile_ini, video.take's
  offers (studio only, sections, m4a, the 16 cap), dawview's item and chunk signature, the pages loading video.js.
- `tests/webui_test.cpp`: ranges (206, open-ended, suffix, cut to the end, 416, several/malformed -> 200, token still needed), types.
  On this desktop the stock ports were taken (REAPER's link and another agent's stand-in on 47391), so it ran from a copy on other ports: all ok.
- `tests/direct_test.cpp`: the new extensions on the stream list.
- Chromium (the desktop app's pane) against a stand-in server running the real `dawview.build` and `video.info` (lupa), serving the clip with
  ranges: the Project page drew frames on two video items (one at 2x) and a tiled picture, 8 frames read from one ranged fetch; the phone's
  Project view (375x812) drew them too. A blank first frame (seeking to the time it was already at, before any frame was decoded) was found
  this way and fixed.

## To check in REAPER (desktop + laptop)
1. Drag an .mp4 with sound onto a track on the desktop: the laptop gets the item and its file (Health shows "in media ...: x of y MB (n%)"
   for a big one), the video plays in the laptop's video window (View > Video), its audio plays.
2. A big video (1 GB+): the desktop doesn't hold still while it's copied into the room's media; the laptop's item waits, then appears; Syncthing
   leaves no temp beside it.
3. Add the Video processor on the video track, pick a preset (e.g. "Title text overlay"), change its text: the laptop's chain shows the same
   code and the same picture; nothing resends in a loop (Health's change counter quiet). Then: no prints made for that track's parts, and
   Health's plug-in rows don't name the Video processor.
4. Check what `TrackFX_GetNamedConfigParm(tr, i, "fx_type")` and `"fx_name"` say for a Video processor (the code accepts a type containing
   "video" or a name starting "Video processor").
5. Project settings > Video: change the size (e.g. 1280x720) and fit, as the driver: the laptop's project settings follow. As a non-driver:
   put back. After updating, the first look sends nothing (TIMELINE_FORMAT 5). Confirm `SNM_GetIntConfigVarEx(0, "projvidw", -1)` reads the
   width (if SWS doesn't know the names, they're simply left out).
6. Open/close/move the video window on one computer: nothing changes on the other.
7. With the video window open, make a print or a distributed bounce of a project with video: no video window appears from the hidden REAPER,
   the print/stems are audio as before.
8. Set the project's render format to a video format (Video (ffmpeg/libav) on Windows, Video (Mac native) on the Mac): see what the other
   computer shows in its render dialog (the format string is shared as-is; a sink that computer lacks may not render there).
9. Web UI Project page (desktop browser and the docked view): video items show frames, a picture item is tiled, zoom in and out; on the phone
   (Android Chrome, and an iPhone if there is one) the same in the Project view. An .mkv: frames in Chrome, none in Safari.
10. Drop an .m4a / .m4v into the chat and onto a track: goes over the link with extension 1.0.25 on both ends.

## Not built (on purpose)
- **A low-res proxy while the full file arrives:** no encoder every computer has (REAPER's video render needs FFmpeg's DLLs on Windows and
  Linux, AVFoundation on the Mac), and the link is resumable, so the item simply waits (grey stand-in) with Health's percent. If wanted
  later: the sender renders a small proxy with REAPER's own video sink where it has one, sends it first, and the real file replaces it in
  place ("fast first, lossless after").
- Sharing the Video processor's user presets file (`presets/builtin_video_processor.ini`): the code itself is in the chain, so the picture is
  the same everywhere; only the preset list differs per computer.
- More than 16 distinct video files on screen at once get no thumbnails beyond the 16 (the server's offers are shared with the phone's mixes
  and chat downloads, 64 in all). `shortcut:` raise MAX_OFFERS or offer on demand from the page if big video projects need it.

## Review later (security)
- Offered files: only paths inside the studio's shared folder with a video/picture extension, by an id the page can't choose; the page still
  needs the web token. A bandmate's file renamed `.mp4` but holding HTML is served as `video/mp4` with `nosniff`, so it isn't rendered as a
  page; worth a look in the security round.
- `byte_range`: one range only, digits only, 40 characters at most; `atoll` of a 19+ digit number saturates (then clamped to the file).
- The link list now takes m4a/m4v/mkv/avi/gif: still never anything that runs; media decoders (REAPER's, the browser's) parse bandmates'
  files, as with audio.
