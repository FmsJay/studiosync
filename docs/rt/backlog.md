# Backlog for the realtime branch (rt-backlog, 2026-11-20)

Gathered from every note in `docs/rt/`, from `docs/realtime-roadmap.md` and from the commit log, at 4ed39be. Nothing here was run or
re-tested: each line is what its source says, with the source in brackets. Where a later note or commit fixed something, it is left out
or marked done. Lines marked "roadmap, older" come from rounds 1 and 2 and were not re-checked against every later commit.

## 1. Bugs and limits known but not fixed (most harmful first)

The first six lines are the ones judged most harmful. After them, lines are grouped by area, edits first.

**Edits and the timeline**
- A marker you add in the first seconds after opening is lost when a newer timeline then lands: it replaces the whole timeline, and
  the log doesn't say so. (rt-edits fix I; `lib/sync.lua`)
- A computer on a StudioSync from before the rename fix can still rename a claimed track for everyone: only the sender judges a
  rename, receivers take it by its new name. Gone once every computer is updated. (rt-claims; `sync.obj_allowed`)
- Track order is only put right when a project opens (`mirror.keep_order`). A track move that never landed isn't healed during a
  session, and StudioSync's own Undo and Restore still move a track under its old version's `after`. (rt-undo; `lib/mirror.lua`)
- `mirror.settled` can still merge an old pair of versions from before track merging; with a real, different old loser the track
  would change everywhere, a day late. (rt-undo)
- A note moved by both people (or moved by one, changed by the other) ends up doubled; the same for an envelope point. A pitch
  change counts as a move. (rt-merge §6; `lib/mirror.lua` merge_midi, merge_env)
- On a heavy session every track's chunk is still read at least every 10 s, colour parity walks every item every 5 s, the Mixer
  reads its strips every 0.25 s and the Project page costs about 12% of REAPER's time while editing. The cost with real plug-ins is
  unknown. (rt-bigproj "Left as it is", rt-look "Untested")
- A timeline edit made right after updating, before Live sync's first look in the new version, is taken in and not sent. (rt-edits fix E)
- StudioSync's Undo doesn't step back an act that is only a timeline change (a marker added and nothing else). (rt-edits fix G)
- Undo grouping: an act spread over several looks is still two steps, and so is a script's edit to unselected items on two tracks.
  (rt-edits "Untested / limits")
- Heal's own changes still make undo points on top of your list. Health goes red only after 30 s of the same difference. (rt-undo)
- "Play (skip time selection)" and region playlists aren't carried: in a band Play together the followers play through. (rt-edits)
- A computer still running main's Live sync has the old colour hold and can send a stale track colour once at each restart. (rt-edits fix Q)
- Track deletion against a track edit: newest wins. Plug-in chains don't merge: one stands. Dense CC drawn by two keeps the winner's
  points where ticks coincide. (rt-merge §6)
- Claims: deleting or moving several claimed things at once uses the older suggestion path, not asks. The web countdown only moves
  when presence changes. `room_mode == "claims"` in `lib/mirror.lua` is dead code. (rt-claims)
- Web Project page and phone still ask for any edit to an auto-claimed track; they can't tell a clash from a different piece. (rt-merge §3b)
- Colour try: Put back leaves the tried colour on a region that had none; a bandmate's change on a tried item replaces the tried
  colour. (rt-nohold)
- `lib/files.txt` in the repo still lists `StudioSync - Hold my changes.lua`; `tools/make_index.py` rewrites it at release. (rt-nohold)

**Live audio, jam and plug-ins**
- A computer neither side lists for live audio still waits for a status file or heartbeat. A sender who only uses talkback to
  someone else drops off a peer's list after 15 s. (rt-roomlist, rt-hubfix)
- The song's home still moves with whoever last wrote session.json; the hub is chosen without asking whether everyone can reach
  it. (rt-hubfix part 2; `lib/hub.lua`)
- The desktop's status file is rewritten every 2 s while it can't reach the Mac (Syncthing traffic). (rt-hubfix part 2)
- Full-quality copy: no drift correction (about 7 ms over 5 minutes at 20 ppm); play rates other than 1 split into many items; MIDI
  and instrument tracks aren't copied; a no-transport jam's place depends on the anchoring computer's project end. (rt-double)
- Jam: someone arriving mid-run hears a player only from their next play; stereo 16-bit WAV only (about 1.5 Mbit/s per listener);
  sent to everyone, Jam on or not. (rt-jam)
- Their time: takes recorded in it land late by the delay and nothing moves them. Produce: the first second of a take can be heard
  twice. The mix host's `net` probe misreads a computer with Ethernet and Wi-Fi both up. (rt-sonox)
- Hops: a note-off lost twice hangs a note until the try stops; Print's first 0.5 s is dry when the selection starts at 0; only the
  first 256 knobs; switching tabs on the owner's computer drops the try. (rt-hopvst, rt-ci3)
- Two hops at once on one internet link lost more (one went back at 2.7%). (roadmap, older: step 4b "Still")
- No drift-correcting resampler in listening links, browser guests or the share's REAPER mix: a small skip now and then. (rt-audience,
  rt-browserjoin, rt-share)

**Web, phone, guests**
- Listening links: the live indicator ignores a bandmate playing while this computer's live audio is off; browser guests aren't in
  what listeners hear; only the web UI's Home has the controls. (rt-audience)
- Browser guests: must be on the studio's Tailscale; guests don't hear each other; two at most; one take held per guest. (rt-browserjoin)
- History playback: the preview uses today's tempo map and markers, and doesn't rebuild the master's automation and sends or track
  order; `.opus` is served as octet-stream until an extension build adds the type. (rt-history; `extension/webui.cpp` offer_type)
- Drawing: a removal over the link hides a file for 10 minutes, and it shows again if Syncthing's deletion never comes. (rt-draw)
- Screen share: a master routed off the first output pair isn't heard; duck mutes both of a bandmate's computers; system audio
  can't be turned on mid-share. (rt-share)
- Phone MIDI: one track at a time per computer; other armed tracks on "All MIDI inputs" also hear it; program changes are dropped;
  step input makes one undo point per note. (rt-vmidi)
- Home: notifications don't work over the phone link; Open from a page may show its usual boxes on the computer; mix times use the
  renderer's local clock. (rt-home)
- Chat: an upload is held in memory (up to 150 MB) and hashed on REAPER's main thread. (rt-chat2)
- Video: more than 16 distinct video files on screen get no thumbnails. (rt-video2)
- Web UI chat chips' duplicate accessibility nodes: not reproduced, nothing changed. (rt-small 4)

**Joining, link, cloud**
- First copy over the link: only the current song's main room; band.json and session.json must fit in 30 KB or there's no first
  copy; a Windows joiner without the firewall rule hears neither the welcome nor the copy. (rt-joinlink)
- Link-first studio files: the overlay lives only in Live sync, so the ImGui panel waits for Syncthing (about 3 s); studio-wide
  files reach only the peers in Live sync's room. (rt-linkfirst)
- NAT links: Health keeps a "can't reach" row for a bandmate swapped from Tailscale to `nat:` until REAPER restarts; no SACK, so a
  loss stalls a stream. (rt-nat2; `extension/direct.cpp`)
- Relay: a hub behind CGNAT is never detected; the role can move to a computer without the port forward; a relay that answers STUN
  and then stops relaying breaks links until the next 10-minute probe. (rt-nat3)
- Invite links: only for someone already on the studio's Tailscale; one pending link at a time; Linux keeps the `xdg-mime` default
  after untick. (rt-invite)
- Cloud modes: Standard has no "last mixes" (the cloud copy carries none); Essentials keeps every take of a multi-take item; a
  member without a cloud folder can leave the cloud's version older; lowering the size limit doesn't ask. (rt-cloudmodes)
- Cloud worker: `sessionfile.catch_up` and `streams.lua`'s cloud check still run on REAPER's thread; each worker start leaves an
  empty file in temp until REAPER quits. (rt-drivebg)
- Other scripts: `startup.keep_open_mode` can be overwritten by Autostart's own copy at the next tab change; `PreventUIRefresh`
  left on by a script can't be detected. (rt-compat)
- Efficiency pass list "for James to pick" (arrange redraw every pass, unlimited stream trace log, presence `last_time` by user
  only, and more). Two look handled since (`seen_ev` is pruned, claims files cached); the rest not re-checked. (roadmap, older)

## 2. Built but never checked in REAPER or on real hardware

Each line: what to check, then what it needs. The step lists are in each note's "Check in REAPER" section.

**Needs James present (sound, a microphone or an instrument)**
- Live audio by ear: since extension 1.0.30 it really sends inputs and plays bandmates for the first time; counters confirmed on
  three computers, not sound. The desktop's input is a Voicemeeter bus. Then the hour-long gate. (rt-audience, roadmap) Two computers,
  a mic or instrument on each.
- Jam, 14 steps: one interval late on the bar, click at source swaps, tempo change, loop. (rt-jam) Two or three computers, instruments.
- Full-quality copy, 11 steps: claps line up, note the offset in ms. (rt-double) Two computers, two mics.
- Solo, Their time, Produce over live audio, mix host with shared CPU. (rt-sonox) Two computers; four for the mix host.
- Hub fixes: start order, hand the hub over, no flapping for an hour. (rt-hubfix, rt-roomlist, rt-small) Three or four computers.
- Try a plug-in you don't have, Hop 0.2.0 budget, dry on loss, MIDI over a hop, Print's PDC. (rt-hopvst) Two computers; a long link.
- Browser guest: join with an interface, loopback measure, record a take. (rt-browserjoin) Laptop browser with the UR22, a cable.
- Screen share with REAPER's sound, no echo of your own voice, full screen crop, notes. (rt-share) Two computers; the Mac for 2x pixels.

**Needs two or three computers, no sound**
- Edit matrix, 29 steps, and the 8-step Undo check. (rt-edits, rt-undo) Desktop, laptop, LinuxBox; the Mac for the late joiner.
- Merge checks 1 to 10; the set-back fix (c7eed9d) has no recorded re-check. (rt-merge §8) Two computers.
- Claims: a whole `mirror.watch` holding an item 30 s; the web Release and Keep buttons. (rt-claims) Two computers.
- Hold removed, colour try, restart mid-try. (rt-nohold) Two computers; a Mac for the `B` colour suffix.
- Quick looks rounds 2 and 4 timings; ReaScript edits with nothing selected. (rt-look) Two computers.
- Signed studio files, 8 steps: grant and mode at once with Syncthing paused. (rt-linkfirst) Two computers.
- First copy over the link, 7 steps. (rt-joinlink) A scratch studio only, never Chilio's; LinuxBox as the joiner.
- Ask to join, invite links, the `studiosync://` handler; `reaper.exe -nonewinst` behaviour. (rt-invite) Two computers; Windows,
  Mac and Linux for the handler; no handler was installed anywhere.
- Chat: DMs, channels, file drops, 150 MB uploads, a real Syncthing round trip. (rt-chat2) Two computers and a phone. The roadmap
  records one DM reaching the laptop in 12 s.
- Drawing on the web pages and the phone. (rt-draw) Two computers and a phone.
- Video: Video processor, big files, video settings, thumbnails, `fx_type` and SWS config names. (rt-video2) Two computers; an iPhone.
- Big project measurements, steps 3 to 8. (rt-bigproj) Three computers. The roadmap records step 2's desktop numbers.
- Other scripts: undo names, persona switch timing, window sets, `netstat`/`lsof` output per system. (rt-compat)

**Needs a phone or real services**
- Listening links on a phone (Safari 26+, Firefox 130+ untried), revoke, cap, sample-rate change. (rt-audience) A phone on the tailnet.
- Phone keys, pads, Web MIDI, stuck-note safety. (rt-vmidi) A phone, a USB MIDI keyboard.
- History playback after the fixes (891dd04, 442a2aa): the note records no second run. (rt-history) Desktop; a phone; the Mac.
- The phone's Project view with the fix deployed inside Live sync. (rt-phonefix) A phone.
- Cloud storage modes: the panel section has never been drawn; real trash and rate limits. (rt-cloudmodes) A test studio, Google Drive.
- Cloud worker: laptop with its cloud copy on, the worker killed mid-copy. (rt-drivebg) Desktop, laptop, Google Drive.
- AI tools: no model was run or called. (rt-ai) James's OK for each model run; a phone for the "yes from a phone" check.

**Needs a router or network change**
- Connect without Tailscale, stages 1 to 3: real NATs, symmetric NAT, CGNAT, hairpin, a network change, the hour-long gate with
  Tailscale off on one side. (rt-nat2, rt-nat3, roadmap) Laptop off the tailnet or tethered; a router port forward (James's call).
- Guest without Tailscale. (rt-sonox) A computer off the tailnet.
- Public listening. (rt-audience) Funnel allowed in the tailnet policy; a phone off the tailnet; only if James decides.

**Needs the Mac (unavailable for now)**
- Jam and full-quality copy on SWELL builds; history's background render; the cloud worker's `stat -f` branch on a real Google
  Drive folder; the handler's applet and Gatekeeper; the docked view. (rt-jam, rt-double, rt-history, rt-drivebg, rt-invite, roadmap)

## 3. Features designed or half built

- Voice channels: design only, 4 steps (voice flag and join files, peer set switch, pages, hub for 4+). (rt-chat2; `lib/liveaudio.lua`)
- Fewer dependencies (rt-lite's stages):
  - A, No Tailscale: built, off by default (`nat` in band.json). Left: its REAPER checks, invitations over a NAT link, the hub's
    TURN for video-call pages, Health naming the Tailscale-only features, phone pages without Tailscale.
  - B, signed writes: done (rt-linkfirst, 36f90ae), except the welcome handing over the newest sequence numbers and signing
    session.json and `hub/<person>.json`.
  - C, key-made device ids: not done. D, No Syncthing with a cloud: not done (8 to 10 sessions). E, Minimal: not done.
  - The secret sealed in the join welcome: done (rt-joinlink, 2563d80). Sealing it again after a removal: not done.
- Still on Syncthing and could move to the link: catch-up's need list, restore points, mixes and stems, the update code, given
  claims, profile pictures, `released/*` and other own files, NAT first contact. (rt-linkfirst inventory)
- Public listening: built, switched off behind the owner's switch. (rt-audience)
- AI add-on: built against stand-ins, off per studio, no key support. (rt-ai)
- Remote control of a shared screen: design note only. (roadmap, step 5)
- The pointer and notes over the sharer's real REAPER window: not done, preview only. (rt-share, roadmap)
- Low-res video proxy while the full file arrives; sharing the Video processor's preset file: not built on purpose. (rt-video2)
- Home proposals, not built: project cover art, a status line, phone push for mentions, "since you were last here", read receipts.
  Wished-for chat functions: a to-do assignee, mentions for several names, a cheap "newest messages" read. (rt-home)
- ReaPersona's four suggested changes: written down only, its repo not edited. (rt-compat §2)
- Audit recommendations not done: stretch the timed pass to about 10 s while playing and the link carries; a passive "everything's
  out" tick for Sync and exit; stop growing the panel's duplicate pages. (rt-audit §10, §12, §14)
- Hub ranking by who reaches whom (`sees` is published): not built. (rt-hubfix part 2)
- Carrying "Play (skip time selection)" in the start cue: not built. (rt-edits)
- Per-plug-in merging by FXID. (rt-merge) Per-page MIDI channels so two phones play two tracks. (rt-vmidi)
- Drawing: no Line, Box or Highlighter and no undo on the web; share notes aren't saved to the room's layer; Mixer drawings aren't
  on the time lapse. (rt-draw)
- History: the time lapse doesn't follow the audio's position; time lapse gaps (comp areas, markers, tempo, track moves). (rt-history,
  rt-timelapse)
- Jam over Opus or FLAC; drift stamps every second for the full-quality copy. (rt-jam, rt-double)
- No panel (ImGui) UI for listening links or browser guests. (rt-audience, rt-browserjoin)
- Cloud: the cloud copy doesn't carry session.json, room.json or band.json; filter an item's inactive takes. (rt-cloudmodes)
- Snapshots plus changes, native hot paths, the Studio browser, a studio preference set: planned, not built. (roadmap, older)
- Web UI pages' "not yet" lists (deleting items, fades, sends, automation items, CC lanes). (roadmap, older: "Web UI: what remains")
- "One copy per file across songs". (roadmap, older: "Proposed next")
- SonoBus, ReaNINJAM, "Private live audio" and "Invite a SonoBus guest" stay until James's gates. (rt-audit "Left", rt-sonox)

## 4. Open questions that are James's to answer

1. Should "Play (skip time selection)" be carried in a band Play together? Carry it in the start cue, or leave followers playing
   through. (rt-edits checklist 9)
2. Public listening: turn it on at all? It needs Funnel allowed for JAMES-MAIN in the tailnet policy. (rt-audience)
3. Forward UDP 47298-47314 on the home router to the hub for the relay, and make that computer the preferred hub? (rt-nat3)
4. What should decide a song's home: something only the sharer writes, or as now (whoever last wrote session.json)? (rt-hubfix part 2)
5. The three "Follow"s: rename the transport one "Play and stop together" and the view one "Watch <name>", or keep the words? (rt-audit §8)
6. In what order should the ImGui panel's pages retire? First candidates: Home, Chat, Play together. (rt-audit §14)
7. "Open collaborators' MIDI edits as they happen": remove it (the audit's guess) or keep it? (rt-audit §15; `lib/midiview.lua`)
8. The gates: when do SonoBus, ReaNINJAM, Syncthing, ReaImGui and SWS/JS retire? Each is James's call. (roadmap, rt-lite, rt-audit §9)
9. Is Minimal mode wanted (only if bands ask), and phone pages without Tailscale (LAN listener, no microphone)? (rt-lite)
10. Which AI models to run, if any: every run asks first. (rt-ai)
11. Should a startup script that writes the grid keep making the grid per computer? Reversible in `compat.run_check`. (rt-compat §6)
12. Which of the efficiency pass's "problems found, not fixed" to take on? (roadmap, older)
13. Is a low-res video proxy wanted later? (rt-video2)
14. The BandSync rename shims: keep until a "drop pre-0.5 projects" release, if ever? (rt-audit §15)
- Answered since (left here so nobody asks again): the live mix's host (rt-hubfix asked, rt-sonox built James's answer); edit
  holds, the number of modes, SonoBus's extras, classic Jam (rt-audit 6, 7, 9, 10; built by rt-merge, rt-claims, rt-sonox, rt-jam).

## 5. Security: review later

Collected as written, not judged. James deferred reviews until every feature is in.

**Link and signing**
- First use: a computer takes the first validly signed copy, however old. (rt-linkfirst, rt-lite)
- Keys are learnt from Syncthing's `modifiedBy`; a forged Syncthing client could bind its key to a computer once. (rt-linkfirst)
- A writer with a slow clock sends an older sequence number and its link copy is refused. The seqs store forgets past 600 files. (rt-linkfirst)
- Own files (profiles, colours, recaps) over the link are unsigned. (rt-linkfirst)
- band.json carries the secret over the link; a removed member whose mark hasn't arrived could still get it. (rt-linkfirst)
- The outbox is a non-persisted ExtState. (rt-linkfirst)
- A stolen device key signs until that computer is taken out. A clock a day ahead pushes sequence numbers. Two ids per computer. (rt-lite)
- The secret in band.json must be sealed before a cloud carries `_band`. (rt-lite)
- Signed updates: band.lua, json.lua and the entry script are read before the check; a downgrade is accepted; no key rotation; an
  admin can set the first key. (roadmap, "Signed updates: still open")
- A merged version's state is signed by nobody; a hostile event with many tiny events costs a sort per merge. (rt-merge)
- `undoes`, `redoes` and `base_ev` are the sender's word: a changed client could mark an edit as an undo to pass an auto-claim. (rt-edits)
- A marker's render row isn't length-capped. A start cue's `loop` sets your loop. (rt-edits)
- Hop `set` and `params` trust the `user` field inside a signed message; network MIDI goes straight to the instrument. (rt-hopvst)
- A peer's early anchor can move where this computer's no-transport parts land. (rt-double)
- A peer can make a receiver write up to an hour of WAV per jam run; streams have no per-peer budget. (rt-jam)
- Draw messages carry the author's name in the data: another name, or a removal "by" an admin, can be claimed. (rt-draw)
- A forged 'H' can make peers send directly (bandwidth). `ext` and `sees` are a member's own word. (rt-hubfix)
- A studio computer with the secret can make itself heard in a room it isn't in, 15 s at a time. (rt-roomlist)
- Status fields `net`, `lrtt`, `scpu`, `lmix` are self-reported: a member can claim to be the best mix host. (rt-sonox)
- Removing SonoBus must not remove band.json's `sonobus` secret. (rt-audit)

**Web UI and tokens**
- The studio-wide web token lets any member use your web UI as you. Needs per-person tokens. (rt-chat2) Through it a phone can: read
  and send DMs (rt-chat2), make AI asks (rt-ai), open projects (rt-home), start history renders (rt-history), make the computer
  scan every script and run `netstat` (rt-compat), arm a track and sound its instrument, possibly loudly (rt-vmidi), draw and
  remove (rt-draw).
- DMs are plain files readable by everyone with the studio folder. (rt-chat2)
- Channel admin rights are checked only on the acting computer. DM ids are FNV-1a-64. (rt-chat2)
- `StudioSync_FileHash` reads whole files on the main thread. Received files: only programs are blocked. (rt-chat2)
- `chat_index.people` and DM names aren't verified with `trust.user_file`. (rt-chat2)
- Profiles aren't checked against who wrote the file; pictures are validated, not decoded. (rt-home)
- Scanned scripts' names and paths show on the web page. (rt-compat)
- `/api/mix` gives REAPER's output to any page served from 127.0.0.1 with the right Host. A watcher can draw on the sharer's preview. (rt-share)
- A file renamed `.mp4` holding HTML is served as video with `nosniff`; byte-range parsing; media decoders parse bandmates' files. (rt-video2)
- `prep.lua` is loaded by the hidden REAPER from the per-user temp folder. (rt-history)
- History reads a huge event file whole, with no size cap of its own. (rt-timelapse)
- A future module that trusts `a.gid` from a host page. (rt-browserjoin)
- No per-page rate limit on phone notes beyond the 64-action queue; `sid` is page-chosen. (rt-vmidi)

**Listening links, public listening and browser guests**
- Codes are bearer secrets in URLs, made from `band.secret` (REAPER's GUIDs, not a documented CSPRNG). (rt-audience, rt-browserjoin)
- Listening codes are kept in ExtState on disk. (rt-audience)
- Rate limits are per way in, not per listener: one abuser can lock real listeners out for a minute. (rt-audience)
- Public listeners can't be told apart or removed one by one. (rt-audience)
- The session mix goes out whole to listeners and guests, talkback included; the band isn't warned. (rt-audience, rt-browserjoin)
- Funnel publishes the machine's name and stays configured if REAPER closes or crashes. (rt-audience)
- A public link's latest mix may be an unreleased render. (rt-audience)
- The page files are read from `lib/webui` on each request. `/listen/` bypasses the token by design. (rt-audience)
- The guest cookie is bound to nothing else; sessions last 4 h. (rt-browserjoin)
- A chat app's link preview could redeem a guest link first; consider a confirm step. (rt-browserjoin)
- Guest uploads hold memory (160 MB each) and write WAVs into the project's folder. (rt-browserjoin)
- Guest audio isn't authenticated per frame beyond the session cookie. (rt-browserjoin)
- `tailscale serve` is shared with the phone link: turning the phone link off doesn't stop guest links. (rt-browserjoin)

**Join and invite**
- A join request's phone alert goes to the studio-wide ntfy channel. (rt-invite)
- Invite codes sit in plain ExtState. (rt-invite)
- The redeem channel's key is public; the 30-refusals pause is a cheap way to block real links for 10 minutes. (rt-invite)
- The answer goes to whatever Tailscale name the asker claims; whoever sees a link first wins its single use. (rt-invite)
- Member links open projects without asking, and can switch studio and start Live sync. (rt-invite)
- Join requests aren't authenticated beyond the DM. The launcher's pending file is writable by any program. (rt-invite)
- The Windows handler runs wscript.exe. `chat.post`'s `extra` lets a caller add fields. (rt-invite)
- The joiner's trust root is the token plus its inviter: the first user of a token gets the secret. (rt-joinlink)
- Bandmates' keys come from the inviter's map; a wrong binding is passed on. (rt-joinlink)
- The song's changes and media in the first copy are not sealed (HMAC plus Tailscale). (rt-joinlink)
- Refused welcomes aren't rate-limited. Boot copies outlive a deletion for up to 2 days. (rt-joinlink)
- The seal construction is unreviewed. Media is placed before Syncthing indexes it. (rt-joinlink)

**Relay and NAT**
- The SSN1 handshake is unreviewed; the signal parser and `nat_open` aren't fuzzed. Both before `nat` is on by default. (roadmap, rt-lite)
- Streams trust the link's sealing: a bandmate could hold 16 x 256 KB per link or ack data it never got. (rt-nat2)
- `loop_pair`'s listener on 127.0.0.1 can be made to fail by a local process. (rt-nat2)
- `direct_adopt` skips the Tailscale address check by design; a flood costs a connection slot (32). No per-stream rate limit. (rt-nat2)
- Relay passwords are derivable by every member: quotas are fairness, not authentication. (rt-nat3)
- The relay is an open STUN responder on 17 UDP ports. (rt-nat3)
- The `-Dudp_sendto` shim depends on libjuice 1.7.4's server.c: check on any update. (rt-nat3)
- A member can replay a fresh "restart" (300 s) to make a link start over. (rt-nat3)
- `nat_relay_sendto` returns success for a capped datagram. (rt-nat3)
- The relay listens on any address: on a hub with several addresses, replies can leave from the wrong one and be dropped. (rt-macrelay)
- `juice_destroy` can run inside a libjuice callback; `loop_pair` accepts with no time limit under a lock; `nat_set_rx(h, nullptr)`
  waits without limit. (rt-macrelay)
- A guest without Tailscale inherits the NAT and guest-invitation lists above. (rt-sonox)

**AI add-on** (all rt-ai)
- A tool gets the take's whole source file; any program at the set path runs with the user's rights and its output is synced.
- Text to a non-local address over plain http is unencrypted.
- Credentials in the address sit in `run.ps1` and on curl's command line. No key support.
- Stems and MIDI tracks added by a yes skip per-room claims and driver rules.
- Answers go through `chat.post`: alerts carry the model's text, and an @ could ping someone.
- Job folders are never pruned. `ai_mix.lua` is loaded with `dofile` when present.

**Files and paths**
- Cloud worker: plans and scripts sit in the per-user temp folder; the worker trusts any path in a plan; the `j` check is
  structural; the `slow` file is a test hook. (rt-drivebg)
- The cloud copy's events aren't signed: a planted newer-looking change makes the sweep remove the real newest from the cloud. (rt-cloudmodes)
- A manager's Essentials removes data from the cloud copy for everyone; the owner's computer removes others' files after an
  in-memory hour; the size readout can download cloud-only files. (rt-cloudmodes)
- The startup re-assert writes `__startup.lua` without asking. (rt-compat)
- The colour try's ExtState is trusted and uncapped; a local script could withhold or put back colours. (rt-nohold)
- A bounce helper's sampler state may name any file on the helper. (roadmap, older: bounces)

**Claims and permissions**
- `mode.json` is read without a writer check. (rt-claims)
- A grant names a person by display name: renaming yourself to it gets the grant. (rt-claims)
- `claim_ask.from` and `claim_answer.from` are unauthenticated: a fake release, or a wrong name shown. (rt-claims)
- Ask names go to the studio's ntfy channel. Auto-claim times use each computer's own clock. (rt-claims)
- A rename is judged only by its sender; judging on receive is left for the security pass. (rt-claims)

## 6. Test rig and CI notes

- Offline tests passed channel counts in directly, so none saw that REAPER gives the audio hook 0 channels. Green offline did not
  mean it worked in REAPER. (rt-audience)
- The stand-in REAPER says every file exists and has no plug-ins through the API: the media copy path isn't exercised. (rt-edits)
- The big test project's plug-ins are missing-plug-in stand-ins, cheaper than real synths serialising. (rt-bigproj)
- Offline timings were taken on the desktop while other agents were busy. (rt-bigproj, rt-look)
- GitHub's Mac runner: `sleep_ms(1)` runs about 9 ms and the process stalls 15 to 250 ms. Timing checks are passed over there unless
  SS_TIMING_STRICT. hopnet_test still fails some attempts (94.48% against 95%). (rt-ci, rt-ci3, rt-macrelay)
- macOS answers a loopback alias from the alias: relay tests need 127.0.0.2 and .3, and print SKIP without them. (rt-macrelay)
- One Mac quota-check stall and one Linux "a spike isn't drift" failure have no known cause. (rt-macrelay, rt-ci)
- nat_test has a 600 s watchdog; CI jobs and steps have timeouts. `SS_TEST_PORT` moves direct_test off 47391. (rt-macrelay)
- LinuxBox is a VM: its audio clock reads about +5000 ppm and stalls, and its REAPER writes item text differently. (roadmap, rt-edits fix K)
- The desktop's WASAPI through Voicemeeter runs on a 10 ms timer and drops a tick about once a minute (about -102 ppm). (roadmap)
- The laptop's clock ran 908 ms off the desktop's: subtract the DirectClock offset in cross-computer timings. (rt-look §7)
- The desktop at times couldn't reach the Mac over Tailscale (`rx 0`); the Mac's extension was 1.0.23. (rt-roomlist, rt-hubfix)
- The desktop may still start main's Live sync first (old colour hold, no signing). The laptop has no cloud folder. (rt-edits, rt-lite)
- An extension function called with the wrong argument count shows a modal error even inside pcall and blocks REAPER. (rt-small)
- Other agents' uncommitted files in the shared worktree can fail `test_0_60_rt_webpages.lua`. (rt-nohold)
- Use a scratch or test studio for cloud modes and join tests, never Chilio's. (rt-cloudmodes, rt-joinlink)

## Stale or contradictory in the notes

- "Needs a new extension" or "version not raised" (rt-jam, rt-double, rt-browserjoin, rt-joinlink, rt-nat2, rt-nat3, rt-hubfix,
  rt-roomlist): all released since, 1.0.24 to 1.0.31 (`tools.EXT_WANT` is 1.0.31).
- rt-timelapse, rt-home, rt-chat2 and rt-bigproj say "not run in REAPER"; the roadmap's round 3 records REAPER checks for each.
- rt-look, rt-claims and rt-merge say "nothing ran in REAPER" in one section and report REAPER findings in another. The findings are newer.
- rt-timelapse and the roadmap say song playback is "designed only"; rt-history built it (8d753db).
- The roadmap's "Open: a marker-colour echo, and session.json written by several computers": fixed by rt-edits L and M (0ae5fbf).
- rt-edits §2 and checklist 17 (Hold after a colour try) describe Hold; rt-nohold removed it (6db9e1b).
- rt-ci3's nat_test hang and missing timeouts: fixed (b700cfc). rt-macrelay's 64 KB refusal race: fixed (f469e6b).
- rt-look's "the cloud copy still holds REAPER": fixed by rt-drivebg (8cd4273). The roadmap's hop "Still" list (silence on a lost
  frame, 170 ms budget): fixed by rt-hopvst (67c5b4c).
- The roadmap's round 1 and 2 headings still say "not run in REAPER yet" above sections that later record checks.
