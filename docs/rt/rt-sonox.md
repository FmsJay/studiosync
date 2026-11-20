# SonoBus's extras on the studio's own live audio, and who mixes while shared CPU runs (rt-sonox, 2026-11-20)

James, 2026-11-20: (a) "Rebuild the useful ones on built-in audio" (Solo, Their time, the SonoBus guest, and Produce if it still earns its
place; SonoBus stays until they match). (b) The live mix's host: "only when on shared cpu mode" the best-connected computer mixes; otherwise
the song's hub, as today. Lua tests with a stand-in REAPER. **Not run in REAPER or between real computers. No C++ changed: no extension
release needed.**

New: `lib/livex.lua`, `tests/test_0_60_rt_sonox.lua`, this doc.

## The extras, one by one

| SonoBus extra | What it did | Built-in now |
|---|---|---|
| Solo | Only one bandmate in your ears, through SonoBus's per-person pairs on the master's live mix JSFX. With Follow off it asked their computer to send its whole mix. | **Rebuilt.** The cue mix the extension already has: everyone else's Talk and Play muted, here only. |
| Their time | Delayed your backing by a delay timed with bursts on SonoBus's right channel, so the others lined up with it. | **Rebuilt.** The same delay, measured all the time from the extension's own per-stream latency, with Play together on the shared clock. |
| SonoBus guest | Someone with only the SonoBus app (no REAPER, no Tailscale) heard your mix and was recorded on the Real time track. | **Rebuilt as a REAPER guest without Tailscale,** over the connection without Tailscale (NAT links, the hub's relay). |
| Produce (stamp mode) | Hear a performer on your grid a moment behind, via SonoBus position bursts (or ReaNINJAM); talk to them; run their transport. | **Kept, on a new "live" route:** takes stream onto your grid, their live Play quiet meanwhile, Talk is built-in talkback. Stamp mode is dropped for built-in users. |

### Solo
- **Where:** Who's here, the same **Solo / Soloed** button (shown with Settings > Advanced > Show advanced controls, as before). With the
  studio's live audio on (`live.builtin_audio`) it no longer starts SonoBus. A SonoBus Solo still on from before keeps its old button until
  it's turned off.
- **How:** ExtState `live audio solo` (not kept: it ends with REAPER). `liveaudio.apply` mutes every other bandmate through
  `StudioSync_LiveAudioPeerSet`, so Talk and Play both go quiet. The hub's mix gets the same mutes, because they travel with each
  listener's 'R' request. Solo counts only while that bandmate is one of the live audio's peers here (`livex.solo_in`): someone who leaves
  doesn't silence everyone. Your own per-person mutes stay as they were.
- **Not carried over:** SonoBus's "their whole mix" (when you weren't following them, their computer sent its whole mix). Built in, Follow
  plus In time, or their armed tracks' Play, covers it.

### Their time
- **What's possible.** You can't hear anyone sooner than the network brings them. If they play to their copy of the song at time *t* on
  the shared clock, their sound reaches you at *t + L*. Delaying your own backing by *L* lines them up with it. That's Their time, and it
  gives you their performance in time with the song.
  - It's one-way. What you play reaches them *L* later again (a round trip, more if they're in Their time too), so it suits lead/follow:
    one person leads, the others listen or play along.
  - For everyone playing at once in time, In time (NINJAM style) is the built-in way.
  - What you record in Their time lands *L* late on your grid. Move it earlier by the delay, or record in My time / In time.
  - The metronome isn't delayed.
  - Your own monitoring through REAPER is delayed too. The interface's direct monitoring isn't.
- **How:**
  - Home's Real time mode has a **Their time** way again when the studio's live audio is on (`livex.offered`: SonoBus's Their time is hidden
    then, the built-in one shown).
  - Turning it on (`livex.set_their`) sets Play together (`side` 0: everyone's transport starts at the same moment on the shared clock),
    keeps the bars behind from before (`side before their`), and puts StudioSync's live mix JSFX on the master (`hear.mix`, never sent:
    `mirror.live_fx`). That JSFX delays your backing by up to 1 s.
  - Live sync's live audio tick (`livex.their_tick`, every 2 s) sets the delay from the extension's status:
    - whom you line up with: the soloed bandmate; else whoever sends Play (an armed track); else the latest of those heard;
    - how late: `latency_ms` (half the round trip + jitter buffer + both codecs), or the hub mix's own latency for a bandmate heard in it;
    - steps under 10 ms are left alone (a delay change clicks);
    - plus a **nudge** (Home, ±300 ms) for what the measurement can't see, such as their interface's own latency.
  - Home shows "Your backing 142 ms later: Bo arrives 130 ms late, +12 ms nudge".
  - Turning it off puts the bars behind back and the delay to 0. If Play together goes off another way (another way picked, or the project
    reopened, where `live.all_off` clears `side`), the next tick turns Their time off too, so a reopened project never keeps a delayed backing.

### A guest without Tailscale (the SonoBus guest's place)
- **Which path, and why:**
  - **Browser guests over the NAT links or relay:** not feasible within the design. A browser can't speak the sealed `SSN1` UDP links, so
    it needs a WebSocket/HTTPS endpoint reachable from the internet. That means a public endpoint (Tailscale Funnel, or a port forward to
    the web UI), and the rule is tailnet-only links.
  - **A REAPER guest by invitation, reached with a NAT link:** almost all there already. A guest invitation without a Tailscale key, then
    Let them in (Syncthing needs no Tailscale), then `nat.pair_needs` makes a link because one side isn't on the tailnet. Live audio, the
    direct link and the clock go over it, relayed by the studio hub where both NATs are strict.
- **Built:**
  - With the studio's live audio on, Who's here shows **Invite a guest without Tailscale** in place of "Invite a SonoBus guest".
  - It checks `livex.guest_ready`. If "Connect without Tailscale" is off, an owner or admin is asked once to turn it on (`groups.set_nat`).
    A member is told who can. An extension without the NAT code is told to update.
  - It then opens the existing guest window (`tools.open_guest_invite(..., no_ts)`): the same end date and project picks, with a line
    saying nothing joins their computer to the tailnet. The invitation leaves out the Tailscale key even when this computer has a token.
- **Guest limits, unchanged:**
  - in until the day picked (`removal.add_invite`), then every computer stops syncing with theirs;
  - only the projects ticked;
  - never a hub (lib/hub.lua) or the live mix's host (below);
  - never anyone's shared CPU (`hops.offload_pick`);
  - the room's own rules for what they may change.
- **The difference from SonoBus's guest:** they need REAPER. The invitation installs it, StudioSync and Syncthing in about 15 minutes.

### Produce: kept, on the studio's live audio
- **Decision: keep it, drop stamp mode for built-in users.**
  - **Why it earns its place:** a producer-led session is a real workflow (rt-audit §7). Producing someone means following them a few
    seconds behind, their take landing on your grid as they record, talking between takes, and running their transport (`producer.remote`).
    None of that needs SonoBus except the sound.
  - **Why stamp mode goes:** with built-in live audio, SonoBus (and the NINJAM route) would send everyone's sound twice. Their takes
    already stream onto your grid over the direct link (lib/streams.lua, by the shared clock), at better quality than an Opus stream with
    position bursts.
- **The live route (`producer.via` = "live" whenever the studio's live audio runs here):**
  - Start follows them `LAG.live` = 5 s behind (a FLAC take reaches the link in 2-5 s steps; the lag drag still changes it). Nothing starts
    on their side: their computer sees `produce_via = "live"` and starts no SonoBus or stamps (`producer.tick`).
  - While they record, their live Play is quiet here (ExtState `live audio duck play`, read by `liveaudio.apply`), because the take streams
    onto your grid instead. Between takes you hear them live. Talk is never ducked.
  - Home's Producing box says "Through the studio's live audio". Its **Talk** is built-in talkback to them, latched: it reaches them at
    once, even mid-take, and nothing is recorded here. Its lines say "Hearing their take as it streams, on your grid" or "Between takes:
    you hear them live, and Talk".
  - Without the studio's live audio, SonoBus's and NINJAM's routes are exactly as before.
- **Watch for:** Parts play set to "Show only (muted)" (Settings > Options) mutes streamed takes, so the producer would hear nothing while
  they record. The Producing tooltip says so.

## The live mix's host while shared CPU runs (James's (b))
- **When:** shared CPU is in use anywhere in the room. That's any computer whose status has `scpu` (one of the song's tracks has its
  effects offloaded, `hops.records` with `offload`). Only then is the hub's live mix (from `live_hub` people, 4 by default) moved.
  Otherwise the song's hub mixes (lib/hub.lua), as today.
- **Who (`livex.mix_pick`, the same answer on every computer from the same status files):**
  - candidates: those live audio reaches here, plus this computer, whose extension mixes (`lhub`), not a guest, not handed on (Health's
    Hand it on);
  - shared CPU's own busy line first: a computer over 75% `cpu` only if all are;
  - then wired over Wi-Fi (`net`: a background probe every 5 min of the default route's adapter: PowerShell `Get-NetAdapter` on Windows,
    `networksetup` on macOS, `/sys/class/net/*/wireless` on Linux);
  - then the lowest round trip to the others (`lrtt`, the mean of the extension's per-stream round trips, in tens of ms; ranked in 20 ms
    bands);
  - then CPU headroom (`cpu`, in tens);
  - then the song's hub, then the name.
- **Held steady:**
  - The computer mixing now (`lmix` in its status) keeps it unless another is clearly better: wired against its Wi-Fi, 20 ms or more lower
    round trip, or it went past the busy line.
  - A new pick is taken once it has been the pick for 4 s (statuses arrive at different moments on each computer), or at once when the one
    before can't mix any more.
- **Handed over cleanly:**
  - The new host starts mixing as soon as it picks itself.
  - Everyone else stays on their own streams until the new host's status says it mixes, then asks it. They don't ask a computer that isn't
    mixing yet and sit out rt-hubfix's 5 s join fallback.
  - The old host stops mixing when it sees the new pick. Its listeners fall back to their own streams within a jitter buffer (the extension).
  - rt-hubfix's 'H' membership keeps anyone the new mix doesn't have yet heard directly.
  - If statuses disagree for a moment, the audio stays two-way (rt-hubfix).
- **Health** (the live audio row) adds why: "shared CPU is on in this room, so desk mixes the live audio: wired, 22 ms round trip to the
  others, CPU 30% (the best-connected computer here)". It says "(it was mixing already and nobody here is clearly better connected)" when
  holding. During a handover: "the hub's mix: handing the live mix to lap ... your own streams until it mixes".
- **Status fields** (Live sync's `P.status`): `net` ("wired"/"wifi"), `lrtt` (ms, tens), `scpu` (true), `lmix` (true).

## Files touched
- New: `lib/livex.lua`, `tests/test_0_60_rt_sonox.lua`.
- `lib/liveaudio.lua`:
  - `apply`: Solo's mutes, Produce's duck;
  - `hub_tick`: `livex.mix_host`, the handover wait, `S.hub.pick`;
  - `hub_text`: the pick's words;
  - `tick`: `livex.their_tick`.
- `lib/producer.lua`: the live route (`via`, `LAG.live`, `DUCK`, start, stop, tick both sides, lines).
- `lib/page_hear.lua`: the Producing box's live route and talkback.
- `lib/tools.lua`: `open_guest_invite` and `no_ts`.
- Shared files, small additive edits:
  - `StudioSync - Panel.lua`: Solo's built-in branch; RT_KINDS' built-in Their time; `ui.rt_kind`/`set_rt_kind`/`rt_switch`; Home's
    `livex.offered`, the delay line, `sb` without built-in Their time; the guest button.
  - `StudioSync - Live sync.lua`: one status line.
- `tests/test_0_60_rt_prune.lua`: one assertion now reads `livex.offered`.

## Tests
`tests/test_0_60_rt_sonox.lua` covers:
- **Solo:** the cue mix's mutes as the extension gets them; un-Solo; Solo of someone who left; your own mutes kept.
- **Produce's duck:** their Play at 0 while they record.
- **Their time:**
  - whom to line up with (Play first, the latest, the hub mix's latency, the soloed one) and the step, clamp and nudge;
  - Home's line;
  - on and off with the bars behind kept and restored;
  - the tick following a measurement, and turning itself off when Play together went off;
  - refused cleanly with no live mix.
- **The ways Home offers,** live audio on and off.
- **The guest's readiness,** four cases.
- **The network probe's words** on all three systems; the round trip and its tens.
- **The pick:**
  - wired over Wi-Fi, round trip bands, CPU, the song's hub, no guests, handed-on or old extensions, the busy line;
  - holding (12 ms better kept; 20 ms, wired, or busy hand over; two claiming);
  - Health's words;
  - candidates only from those on the link;
  - deciding: no shared CPU means the song's hub; settling; the handover wait; this computer at once; a flip back doesn't reuse an old
    clock; off again.
- **Health's live audio words** with the pick.
- **Produce's live route:** no SonoBus on either side, the duck only while recording, the lines, an older SonoBus producer as before.
- **The wiring** in the panel, Live sync, live audio, tools and the Producing box.

Results:
- `python tests/run.py --no-luals`: fails 0.
- `tools/luals_check.py Warning --gate`: passes.
- No C++ changed, so no native tests or build.

## For James to check in REAPER (after a release; no extension release needed)
1. **Solo:** in a room with two bandmates, Settings > Advanced > Show advanced controls, then Solo one on their card. Only they are heard
   (Chat > Call's meters show the others muted). Click again: everyone's back. SonoBus mustn't start: no "Real time" track, no SonoBus.
2. **Their time:** Home > Real time mode > Their time (two computers, live audio on). Home shows "Your backing N ms later: X arrives N ms
   late". Press Play on either: both start together.
   - With the other playing an armed guitar to the song, their part should sit on your backing.
   - Turn it off: the delay goes, and the bars behind are back (Settings > Options).
   - Close and reopen the project: Their time is off and the backing is on time.
   - Check that the master's FX list shows "StudioSync live mix" and the other computer's master doesn't.
3. **Guest without Tailscale:** Who's here > Invite a guest without Tailscale.
   - With Connect without Tailscale off: asked once (owner); Yes turns it on.
   - The window says "Without Tailscale" and the invitation has no "Tailscale key" line.
   - With a computer off the tailnet let in as a guest: Health shows "Without Tailscale: <guest>: direct/relayed", and live audio both ways.
   - Their card has no hub role, and Offload never picks them.
4. **Produce (live):** Advanced on, Produce a bandmate.
   - Home says "Through the studio's live audio".
   - Their computer starts no SonoBus.
   - They record: you hear the take on your grid ~5 s behind and not their live sound; between takes you hear them live.
   - Talk reaches them mid-take.
   - Their Play/Record/Stop from your side still work.
5. **Mix host with shared CPU:** four computers (live hub from 4), one track offloaded (Offload this track's FX).
   - Health's live audio row names who mixes and why (wired, round trip, CPU) on every computer, the same one everywhere.
   - Bring the offload back: within seconds the song's hub mixes again.
   - `underrun.lua`: no peer silent for more than a jitter buffer during either handover.

## Not done / limits
- None of it was run in REAPER or on real networks: the Windows PowerShell and macOS `networksetup` probes, the JSFX delay with a real
  device, streams under the live Produce route.
- **Their time:** takes recorded in it land late by the delay; nothing moves them automatically.
- **Solo:** doesn't ask the soloed computer for its whole mix (SonoBus's listener mode); SonoBus's "Listening to you" note isn't shown
  for built-in Solo.
- **Produce:** the duck goes by their status's `recording`, read once a second, so the first second of a take can be heard twice. The 5 s
  lag suits FLAC; a WAV-recording performer could use less.
- **Mix host:** the `net` probe can misread a computer with Ethernet and Wi-Fi both up (it takes the lowest-metric default route), and a
  phone's USB tethering on macOS reads as wired. A computer can't be preferred by hand for the live mix while shared CPU runs (the
  studio's preferred hub only sets the song/studio hub).
- `livex.BUSY` copies `hops.BUSY` (75).
- SonoBus's code is untouched, still used where the studio's live audio is off.

## Review later (security)
- New status fields `net`, `lrtt`, `scpu`, `lmix` are self-reported, like `cpu`. A member could claim "wired, 0 ms" to become the live
  mix's host while shared CPU runs. That gets them the room's live audio streams (which they already receive peer to peer) and the cost of
  mixing. Guests are excluded by the studio's guest marks, not by their own status.
- The guest without Tailscale uses the existing guest invitation and NAT links unchanged: their review-later lists (rt-nat2/3,
  removal/joins) apply. Turning on "Connect without Tailscale" from the guest button is the same `groups.set_nat` the Settings checkbox
  uses (owner/admin only, checked with `groups.may_manage` before asking).
- Solo, Their time and the duck are this computer's own (ExtState/ProjExtState, the master's live mix is never sent).
