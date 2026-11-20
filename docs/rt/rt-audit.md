# What StudioSync may not need now that it's real time (rt-audit, 2026-11-20)

James, after deciding to remove Hold my changes: "Keep an eye out for other things like this that maybe we don't need anymore. If we do need
it still let me know".

This is a read-only audit of the `realtime` branch at 3036ffc. No code was changed, and nothing was run in REAPER. Each finding comes from
reading the code and the docs (`docs/realtime-roadmap.md`, `docs/rt/*.md`, "Fewer things to press"). Line numbers are from that commit.

The question asked of each feature: did it exist because sync used to take seconds (Syncthing) or because something wasn't built in yet, and
is it now unnecessary, confusing or harmful? Hold my changes is left out, since another agent is removing it. "Send now" (`StudioSync -
Panel.lua:3001`, `lib/sync.lua:1055`) and Hold's lines in Sync and exit (`lib/leave.lua:77-90`) go along with it.

## Summary, most useful first

**Clear wins (do these):**

1. **Two live-audio systems run side by side, and both are offered.** Built-in live audio (AOO) is on by default for every studio. The
   SonoBus "Real time mode" on Home and the SonoBus "Join the call" in Chat > Call are still there, and nothing stops both from running. With
   both on, everyone hears you twice at two different delays. Chat > Call shows two calls one above the other, with two mic pickers and two
   Talk buttons. Health shows a yellow "SonoBus isn't set up yet", and both "Set up everything I can" and the Prepare checklist install
   SonoBus. **Simplify now:** when the studio's live audio is on, hide the SonoBus paths. Keep the code until James's SonoBus gate (§1).
2. **Home recommends the external NINJAM path.** "Time-sync (recommended)" is ReaNINJAM plus a NINJAM server, and REAPER has to be restarted
   when its mode changes. The built-in "In time (NINJAM style)" is checked in REAPER, but it's hidden in Settings > Options. **Point Home at
   the built-in one** and leave ReaNINJAM on the Play/Jam tab (§2).
3. **Old words send people to the old tools.** The web Play page says "To hear each other, connect on the panel's Play/Jam page". At project
   open the log says "live audio starts off" when it means SonoBus and NINJAM. The call-app help says to use "Real time mode's Talk".
   **Reword** (§3).
4. **"While you were away" and the credits never count today's takes.** They read a `takes/*.json` manifest folder that nothing has written
   since v0.x. **Count takes from item events**, as the session recap already does (§4).
5. **"Render prints in the background" is a setting about how StudioSync works inside, not a choice anyone needs.** It already has a
   per-computer default and falls back by itself. **Remove the checkbox** and keep the retry line (§5).

**Ask James (choices about the music or the workflow):**

6. **Edit holds put your edit back for 15 s** after a bandmate touches the same thing. The rule was made for multi-second sync. Now each
   side's edits arrive in about 0.25 s, and the live "is editing" tint shows who's on what within about 100 ms. Shorten the hold while the
   link reaches everyone, or show it only (§6).
7. **Five editing modes.** Two of them, "Driver + claims" and "Anyone (claims ignored)", are hard to tell apart from the others. Three
   would do (§7).
8. **Three different "Follow"s**: Follow each other (transport), Follow a bandmate (view) and Always follow the driver. Real time mode
   quietly turns the first one on at 0 bars (§8).
9. **SonoBus-only extras**: Produce (stamp mode), Solo, Their time, the SonoBus guest and Measure guest delay. Each has a built-in
   replacement except one case: browser guests need the studio's Tailscale, and a SonoBus guest doesn't (§9).
10. **Classic NINJAM Jam** (everyone plays at once and hears each other one interval late, with no recording) has no built-in twin (§2).

**Keep, with the reasons in each section:** the 2 s fallback pass (simplify it while playing, §10), the quiet windows (§11), Sync and exit
(§12), conflict-copy handling (§13), prints and background renders (§5), the ReaImGui panel for now (§14), reading old take manifests (§4),
Live set (§11), and cue and claim files as the record (§10).

**Nothing to remove:** no polling-rate setting is shown to users anywhere. The cadence is all internal (`lib/sync.lua:1266`).

**Don't break this:** the studio secret is stored as band.json `sonobus` (`groups.sonobus_secret`, `lib/groups.lua`). The direct link and
built-in live audio use it too (`lib/liveaudio.lua:593`). Retiring SonoBus must keep that field, or at least rename it carefully.

---

## 1. SonoBus "Real time mode" and "Join the call" beside built-in live audio

- **What it does.** Home's Real time mode switch (`StudioSync - Panel.lua:1556-1610`) puts SonoBus on a hidden "StudioSync Real time" track
  that the armed tracks feed (`lib/live.lua:442-470`, `rt_sends` at `:602`). It also sets Follow each other to 0 bars (`Panel.lua:1172`,
  "side" = "0"). It has two ways: My time, and Their time, which delays your own backing (`lib/hear.lua`, `lib/page_hear.lua`).
  - Chat > Call's "Join the call" (`Panel.lua:1478`) is SonoBus carrying only the talk mic (`live.talk_only`, `lib/live.lua:596`).
  - It has its own Talk track and mic picker (ExtState "talk input", `lib/live.lua:482-500`).
  - It has a Settings > Advanced card, "Real time buffer" / "What you send" (`Panel.lua:2592-2620`), and a "Can't hear each other?" card
    about SonoBus's public server and UDP port forwarding (`Panel.lua:2622-2640`).
  - Settings > Studio has "Private live audio" (SonoBus's server on this computer, `Panel.lua:2245-2272`).
  - Health has a row for it (`lib/page_health.lua:97`), "Set up everything I can" adds it (`page_health.lua:403-407`), and so does the
    Prepare checklist (`lib/prep.lua:218-221`).
  - The radial menu has its own switch (`StudioSync - Radial menu.lua:27,43`).
- **Why it existed.** There was no built-in audio. SonoBus was the low-latency path (roadmap §4: "replace SonoBus").
- **Still needed?** Mostly no.
  - Built-in live audio is **on unless the owner turns it off** (`lib/groups.lua:210`; roadmap "Live audio on by default", James
    2026-11-19). It sends Talk (the call mic) and Play (every armed track post-FX, `lib/liveaudio.lua`, roadmap §4).
  - Its Chat > Call section has Mute me, Deafen, Hold to talk, push-to-talk, talkback and a volume per person (`liveaudio.call_ui`,
    `lib/liveaudio.lua:916`). The panel draws it straight under the SonoBus call (`Panel.lua:1496`).
  - Nothing in `live.lua`, `setup.lua` or the panel's Real time code checks `liveaudio.enabled`. The two only meet in the studio switch's
    "off" text (`lib/liveaudio.lua:868`: "SonoBus carries Real time mode").
  - So, with both on:
    - an armed guitar goes out twice: once through AOO's Play and again through SonoBus, at different delays;
    - the call mic goes out twice;
    - "Each person's volume" (`Panel.lua:1584-1586`, `:1490`) opens SonoBus's window, which doesn't touch the AOO stream you actually hear;
    - there are two mic settings: "talk input" (SonoBus) and "live audio input" (AOO, `lib/liveaudio.lua:50-53`).
  - That's the Hold pattern: two mechanisms for one job, which fight.
  - The web UI's video call already does the right thing: call audio is unticked while StudioSync's live audio runs ("Fewer things to
    press").
- **Risk of removing.** The roadmap's SonoBus gate (an hour of glitch-free audio desktop <-> laptop) isn't recorded as passed. The last
  entry is "Next: an audible check... then the hour-long run that's the roadmap's gate" (roadmap "Round 2 merged and checked"). SonoBus also
  works without Tailscale through its public server, which matters for people outside the tailnet. NAT stage 1 now covers that for AOO, but
  it isn't run in REAPER yet.
- **Recommendation: simplify now, remove at the gate.**
  - While `liveaudio.enabled(root)` is true:
    - Real time mode keeps only its transport half (Follow each other at 0 bars) or goes away; My time / Their time are hidden;
    - "Join the call" and its Talk/mic picker are hidden; the AOO section is the call;
    - "Each person's volume" points at Chat > Call's per-person sliders;
    - the Real time buffer card, the SonoBus half of "Can't hear each other?", Health's SonoBus row, and SonoBus in Set up everything and
      Prepare are hidden;
    - the call-app help points at built-in Talk.
  - Studios that turned live audio off keep SonoBus exactly as now. That's one guard in a handful of places, with no deletions.
  - At James's gate, delete `lib/sonobus.lua`, `lib/stamp.lua`, the SonoBus halves of `lib/live.lua`/`hear.lua`/`page_hear.lua`/
    `guest.lua`, and the cards above. Keep band.json's secret.

## 2. The external NINJAM / ReaNINJAM path ("Time-sync", "Jam")

- **What it does.** Home's third way, "Time-sync (recommended)" (`Panel.lua:1510-1514`, `ui.set_rt_kind`), connects ReaNINJAM on the
  master to a NINJAM server.
  - It starts one on whichever computer needs it (`lib/page_play.lua:184-275`, `services.ninjam_for`).
  - It ships `ninjamsrv` and a Mac relay (`lib/ninjam/`, `services.lua:1457-1520`).
  - It has its own server box, Test it and Host it here (`page_play.lua:105-140`), and "live ideas" on Home from what ReaNINJAM saved.
  - Its own help says: "ReaNINJAM reads its mode once per REAPER session: after changing it, restart REAPER" (`page_play.lua:180`).
- **Why it existed.** Hearing someone in time over the internet needed NINJAM's intervals before the link existed.
- **Still needed?** Mostly not.
  - Built-in interval streaming (`lib/streams.lua`) does "In time (NINJAM style)": your playback runs N bars behind the recorder's on the
    shared clock, and their take is a real take at stop. It was checked in REAPER (roadmap "Step 2 checked": laptop 1.85-1.87 s behind at
    1 bar).
  - It's offered only as a radio button in Settings > Options > Parts play (`streams.lua:266-345`, called from `Panel.lua:2127`). Home still
    recommends the outside path.
  - Two honest gaps:
    - streams in time follow **a take being recorded**, while ReaNINJAM's session mode streams whatever an armed, monitored track plays
      with no recording;
    - **classic Jam** (everyone at once, each hearing the others one interval late) has no built-in equivalent. Built-in live audio's Play
      stream is immediate, not interval-delayed.
- **Risk of removing.** Losing play-along without recording, and Jam. NINJAM is also James's gate (roadmap "Things that can go").
- **Recommendation: simplify now, ask James about Jam.**
  - Home's "Time-sync" becomes the built-in In time (streams `in_time` plus Follow each other at its bars). The recording-format hint
    (`streams.format_hint`) already covers the FLAC delay.
  - ReaNINJAM stays on the Play/Jam tab, which is already hidden by default (`Panel.lua:2570`).
  - Ask James whether no-record jamming / classic Jam is still wanted. If yes, a built-in "interval delay" on the AOO Play stream would
    replace it; if no, delete `lib/ninjam/`, the relay and the server code at the gate.

## 3. Stale words that point at the old tools

- The web Play page: "To hear each other, connect on the panel's Play/Jam page" (`lib/webui/play.js:114`). Built-in live audio is
  already on.
- At project open: "live audio starts off when a project opens: Real time mode (and Time-sync) and the call are off" (`StudioSync - Live
  sync.lua:1020-1026`). That's SonoBus and ReaNINJAM. AOO starts on.
- Call apps: "Talk through StudioSync instead: Real time mode's Talk button" and "With Real time mode on too, the music already goes to the
  others" (`lib/callapps.lua:78-89`). The same in Home's Video call tooltip (`Panel.lua:1597-1598`) and Chat > Call (`Panel.lua:1502`).
- The studio switch's off text: "SonoBus carries Real time mode" (`lib/liveaudio.lua:868`).
- The name "Real time mode" itself, for a SonoBus switch, in a product that is now real time everywhere.
- **Recommendation: reword**, together with §1. No risk.

## 4. Old take manifests (`<room>/takes/*.json`)

- **What it does.** Takes used to travel as a file plus a JSON manifest named `<user>-<date>Z-<n>` (`lib/drive.lua:205-222`). Today's takes
  are item events and `media/` files. A search finds **no writer** of `takes/*.json` in `lib/` or the entry scripts. The format dates from
  v0.4.0 (`git log -S"takes_dir(cfg"`). Readers remain:
  - `extras.lua:176` (per-person takes in the credits/stats);
  - `extras.lua:259` and `:225` ("While you were away: Bo: 3 takes");
  - `recall.lua:228` (take entries in Restore);
  - `chooser.lua:30` (members of an old song with no receipts);
  - `drive.lua:585-623` (manifests in the cloud copy);
  - `band.lua:1991` (0.2's item tag).
- **Why it existed.** The pre-mirror take system.
- **Still needed?**
  - The readers that only show history from old songs cost nothing: Restore, chooser, drive and band.lua.
  - The "while you were away" and stats takes counts are wrong today: they count only those old manifests, so a current take never shows.
    `lib/recap.lua:116-121` already counts takes correctly from item events.
- **Risk.** None in fixing the counts. Deleting the old readers would hide old songs' takes in Restore.
- **Recommendation: simplify.** Count takes in `extras.away_counts`/stats the way recap does. Keep the old readers for old songs. Not run:
  inferred from the code.

## 5. Prints and background renders

- **What it does.** Whoever changes a part renders a print (a wet second take) when someone lacks a plug-in on it or it's a sample player
  (`prints.midi_prints`, `lib/prints.lua:420`), in a hidden second REAPER (`lib/bgrender.lua:1-12`). Chained prints hand the sound between
  computers (`prints.hops_ui`). Settings > Options has "Render prints in the background" (`prints.options`, `lib/prints.lua:1128-1145`).
- **Why it existed.** Bandmates without a plug-in hear the part as its maker did, at Syncthing speed, without the maker online.
- **Still needed? Yes.**
  - Live hops ("Try a plug-in you don't have", `lib/hoptry.lua`; 4b) need the plug-in's owner online and saying yes each session, and they
    add a network round trip.
  - A print is what plays when the owner is away, in the cloud copy, in end-of-session projects, and in stems and mixes rendered on
    another computer.
  - The roadmap's own expectation is "far fewer prints needed once remote plug-ins play live; the hub renders what's left", not none.
- **The checkbox.** It isn't a music choice. `bgrender.default_on()` already picks per computer, and failures already fall back to
  rendering in front with a retry button (`bgrender.lua:9-12`, GIVE_UP).
- **Recommendation: keep prints and the background renderer; remove the "Render prints in the background" checkbox.** Keep the "failed,
  rendering in front / Try in the background again" line. Low risk: a computer where hiding fails already defaults off.

## 6. Edit holds ("X is editing that right now")

- **What it does.** Anything you changed in the last `presence.HOLD` = 15 s is yours (`lib/presence.lua:1-10,232`). A bandmate's change
  to it is put back with "Not sent: X is editing ... right now. Try again in a few seconds", and a copy of their edit is kept
  (`lib/mirror.lua:4263-4270`). The web Project page and phone DAW refuse the same way (`lib/dawedit.lua:151`, `lib/phonedaw.lua:93`).
- **Why it existed.** At 2-3 s Syncthing plus a 2 s pass, two people on one item played tug of war (presence.lua's header).
- **Still needed? Partly.**
  - Status changes now travel over the link at once (roadmap "Presence, heartbeat ... become link messages"), so holds are fresh.
  - But the edits themselves land in about 0.25 s, and `lib/follow.lua` shows "<name> is editing" on the item within about 100 ms without
    blocking anyone (`follow.lua:9-13`).
  - A 15 s window now outlasts the conflict by far: you see their edit land, touch the item, and your change is put back for up to 15 s.
  - The roadmap lists it: "edit holds and 'X is editing that' ... reviewed at the end of the branch and dropped where the link makes them
    unnecessary".
- **Risk.** Without any hold, two people dragging one item at once each see the other's version land, and the newest wins.
  "Use mine" still exists for that.
- **Recommendation: ask James.** My suggestion is about 3 s while `presence.link_carries` (everyone here is reached by the link) and 15 s
  otherwise, keeping the copy. The other option is show-only, relying on follow's live tint. James set "keep the rule, keep a copy" in
  Round 1, so it's his call.

## 7. Editing modes and the driver

- **What it does.** Five room modes (`lib/sync.lua:413-420`, `lib/live.lua:35-46`): Anyone (claims hold; default), Driver + claims, Driver
  only, Anyone (claims ignored) and Admins only. There's also Take control, "Always follow the driver" (`Panel.lua:1873`) and "Banner over
  REAPER while someone else drives".
- **Why it existed.** Driver sync (v0.4.0) kept one person's edits authoritative while sync was slow. Claims were added on top.
- **Still needed?**
  - Claims already travel over the link (the `claim` handler, `StudioSync - Live sync.lua:1038`), so claims aren't slow any more.
  - Driver only and Admins only are still real workflow choices: a lesson, a producer-led session, a client.
  - Driver + claims and Anyone (claims ignored) differ from their neighbours in ways that need a paragraph each (`live.DRIVING`). The
    Round 1 review found Driver + claims described wrongly everywhere.
- **Risk.** A studio set to a removed mode needs a mapping (`sync.mode` falls back to the default for unknown names already).
- **Recommendation: ask James.** Collapse to three: Anyone (claims hold), Driver only and Admins only. Map "claims" to "driver" and
  "everyone" to "open". Keep claims.

## 8. Three "Follow"s, and Real time mode switching one on

- **What they do.**
  - **Follow each other** is transport following: whoever presses play, stop or record drives everyone, N bars behind (ProjExtState
    "side", `lib/page_play.lua:294`, web Play page).
  - **Follow <bandmate>** is their view, cursors, selection and open editor at 5 a second (`lib/follow.lua`, the web Project page's
    Follow select, the panel's card).
  - **Always follow the driver** covers playhead, view and mix (`Panel.lua:1873`).
  - Real time mode also sets "side" = "0" behind the switch (`Panel.lua:1172`), and while it's on, the Follow each other box and the web
    Play page's bars are greyed out or refused (`page_play.lua:292-311`, `lib/webpages.lua:115`).
- **Why.** Each was added at a different time. The 0-bar coupling was there because SonoBus is immediate.
- **Still needed?** All three do different things. The coupling to SonoBus goes with §1. The names collide: "Follow" means two unrelated
  things on one web page (Play's Follow each other, Project's Follow).
- **Recommendation: simplify, and ask James for the words.** Uncouple Follow each other from Real time mode with §1. Rename the transport
  one to say what it does ("Play and stop together") and the view one "Watch <name>". "Always follow the driver" could become Watch +
  Play-and-stop-together aimed at the driver.

## 9. SonoBus-only extras: Produce, Solo, Their time, the SonoBus guest

- **Produce (stamp)** (`lib/producer.lua:1-20`, `lib/stamp.lua`): hears a performer "lined up, a moment behind", over SonoBus with
  position bursts, or over ReaNINJAM. Built in, the same thing is streams "As it comes" or "In time" plus "their takes' level here", which
  is explicitly called "Producer listen" (`lib/streams.lua:276-279`), plus AOO's Play stream.
- **Solo / Listening to one person** (`live.sonobus_wanted`, `lib/live.lua:589-593`; `lib/hear.lua`): the AOO cue mix already has a
  per-person volume and mute.
- **Their time** (SonoBus delays your backing so the others line up): built-in In time does this properly, on the shared clock.
- **SonoBus guest + Measure guest delay** (`lib/guest.lua`, `StudioSync - Measure guest delay.lua`, "Uncompressed from them", "Line up their
  takes"): browser guests (`docs/rt/rt-browserjoin.md`) record lossless takes in the browser, place them in time and measure loopback.
  **But** a browser guest must be on the studio's Tailscale. A SonoBus guest needs only the SonoBus app.
- **Recommendation: ask James**, at the SonoBus gate. Produce moves to streams plus AOO (simplify). Solo and Their time go. The SonoBus
  guest stays only if guests without Tailscale matter (or until NAT covers browser guests: rt-lite §2 lists phone/browser pages without
  Tailscale as a gap).

## 10. The 2 s pass and other cadence leftovers

- **What it does.** Live sync's tick runs a pass every `every` s: 2 while playing or idle, 0.5 just after a recording or with a print on
  its way (`StudioSync - Live sync.lua:1352-1353`).
  - Your edits now go out 0.1 s after they settle (`sync.look_now`), link arrivals are taken in as the quiet window ends
    (`sync.receive_now`, `lib/sync.lua:1266-1295`), and cue looks are 0.25 s with someone here (`Live sync.lua:1173`).
  - A full look runs at least every 10 s for what REAPER doesn't count as a change (`Live sync.lua:460-470`).
  - Cue files and claim files are still written as the record, next to their link messages.
- **Why.** Syncthing delivered everything, so polling was the only way to notice.
- **Still needed? Yes, as the fallback.**
  - Anyone here the link doesn't reach still gets changes only through Syncthing (the status path already makes the same split:
    `presence.link_carries`).
  - The 10 s look catches changes that don't move REAPER's change count.
  - The files are the record that offline catch-up and the cloud copy read.
- **One thing worth trimming.** While **playing**, the timed 2 s pass "can stall REAPER ~0.5 s (seen on the laptop)" (the comment at
  `:1352`). When the link reaches everyone, link arrivals already trigger a pass (`receive_now`), so the timed one only catches Syncthing
  stragglers.
- **Recommendation: keep; simplify while playing.** While `presence.link_carries` and the transport plays, stretch the timed pass to about
  10 s. Keep 2 s otherwise. Low risk: the fallback is unchanged whenever anyone isn't on the link.

## 11. Quiet windows and waits

| Window | Where | Verdict |
|---|---|---|
| Your edit holds the band's changes 0.4 s (link) / 2 s (Syncthing only), never more than 10 s | `lib/sync.lua:1266,1280,1290` | **Keep.** Stops a change landing mid-drag; already shortened for the link. |
| Redo waits 30 s after you undo a StudioSync change | `Live sync.lua:355-359,1370` | **Keep.** REAPER's undo list, not sync speed. |
| Cloud pass waits 3 s after any edit | `sync.DRIVE_QUIET`, `lib/sync.lua:1273` | **Keep.** A listing holds REAPER 0.2-1 s. |
| Edit holds 15 s | §6 | **Ask James.** |
| Local transport quiet 1 s after a remote start | `Live sync.lua:1267` | **Keep.** Echo guard. |
| Live set: nothing synced while playing | `Panel.lua:2128`, `Live sync.lua:1372` | **Keep.** For gigs, where a stall is worse than a delay; one checkbox. |

## 12. Sync and exit

- **What it does.** It saves, waits for Live sync's outbox (prints too), asks Syncthing until each online holder needs 0 bytes, says who
  has it, uploads a last cloud copy when nobody is on, then lets you close (`lib/leave.lua:1-120`, the panel's top bar at
  `Panel.lua:3128`).
- **Why.** Closing REAPER mid-Syncthing stranded work on one computer.
- **Still needed? Yes.**
  - Edits leave in about 0.25 s, but media and takes still reach the record through the shared folder (or the link placing files, then
    Syncthing agreeing).
  - Prints may still be rendering.
  - Someone who's the only holder of a take still needs "not safe to shut down" before turning the computer off.
- **Recommendation: keep; simplify later.** Drop its Hold lines with Hold. Optionally show a passive "everything's out" tick in the top
  bar, so people press it only when something is pending.

## 13. Conflict copies

- **What it does.** `band.is_conflict_copy` skips Syncthing's `.sync-conflict-` and Drive's `x (1).json` files (`lib/band.lua:368-370`;
  a twin at `lib/drivebg.lua:56`, which is likely because the background worker runs without band.lua). Health lists real conflicts
  (`lib/page_health.lua:44-55,102`).
- **Still needed? Yes.** Syncthing and the cloud folder still carry the record. Step 3's media placement was shown to make no conflict
  copies, but other files (session.json, chats) can still clash.
- **Recommendation: keep.**

## 14. ReaImGui panel pages the web UI now has

- **Duplicated today:**
  - Home: panel Home vs web Home (rt-home).
  - Chat (rt-chat2).
  - Health: web shows the rows, but their buttons stay on the panel.
  - Play together (web Play) vs panel Play/Jam's Start together.
- **Panel-only:** Projects, Rooms, Restore (the web has History), Mixes, Plugins, Settings (Studio, Options, Advanced, Console, Updates)
  (`Panel.lua:2692-2702`).
- **Still needed? Yes, for now.** The roadmap's rule is "the ReaImGui panel stays until each page matches". Every Settings card, Health's
  buttons, Rooms and Restore exist only there.
- **Recommendation: keep, and stop growing the duplicates.**
  - New features go on the web page only. The panel's Home/Chat/Play get no new controls.
  - Ask James for the retirement order. The first candidates are Home, Chat and Play together, once Health's buttons work on the web.
  - The §1 and §2 changes shrink the panel's Home the most, so do them first.

## 15. Smaller items

- **"Open collaborators' MIDI edits as they happen"** (`lib/midiview.lua:81-86`, off by default). It opens the MIDI editor on every
  bandmate's MIDI change. At 0.25 s per change it would keep pulling the editor around, and Follow <bandmate> already opens the editor of
  whoever you watch. **Ask James**, but it's probably a remove.
- **"Show the Play/Jam tab"** (`Panel.lua:2570`): fine while NINJAM stays. After §2 the tab's remaining content (Start together) is on
  the web Play page.
- **The BandSync rename shims** (about 40 string checks for "BandSync" names). They cost little and protect very old projects. **Keep**
  until a "drop pre-0.5 projects" release, if James ever wants one.

---

## What wasn't checked

- Nothing was run, in REAPER or in tests. The double-audio finding (§1) comes from reading the code. Nothing in it guards against it, but
  it's unconfirmed by ear.
- The takes-count finding (§4) comes from a search: no writer of `takes/*.json` was found.
- I didn't audit `lib/mirror.lua`'s held-back / retry machinery for media still arriving. The roadmap says it "shrinks as media streams
  over the link". It's self-adjusting (no setting), so there's nothing for James to decide.

## Review-later security notes

- Removing SonoBus must not remove band.json's `sonobus` secret. It's the direct link's HMAC key and live audio's key
  (`groups.sonobus_secret`).
- Shortening edit holds (§6) doesn't touch `sync.authority`, claims or `dawview.may_*`. Holds were never a permission, only a courtesy.
