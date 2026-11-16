# StudioSync test plan: laptop, Mac, Linux, then a band

Written 2026-11-15 for 0.58.68, from four review passes (code, a first band session on paper, Mac/Linux, security) and the clean-VM run.
Hand a section to whoever (or whatever AI) is at that computer. Anything that fails: note the step, what the screen said, and the
installer log (Windows: the console; Mac: the Terminal window), plus StudioSync's Console page.

## 1. Windows laptop (a second real computer)

1. Update REAPER to 7.86 first (StudioSync's Settings > Updates, or REAPER's own notice), so both PCs match.
2. On the desktop: Studios > Invite on a throwaway studio. Send the message to the laptop by email or Discord (not iMessage: it can change quotes).
3. On the laptop: run the Windows line from the invitation. Watch for: Windows permission prompts, the Syncthing firewall prompt
   (press **Allow**: this is a real computer), REAPER's first-start questions.
4. Desktop: press **Let them in** (not *Guest, for a day*). Laptop: the studio card goes from "Waiting to be let in" to its projects.
5. Health on both: every row green, and **Connections to the others are direct**. If it says *relay*, a firewall is in the way.
6. Share a song on the desktop; open it on the laptop. Record 30 s on the laptop; time how long until the desktop has it.
7. Edit on the laptop while the desktop drives (the project starts on *Anyone*); then Take control on the laptop.
8. Real time mode with headphones: can each hear the other? Talk button.
9. Sync and exit on the laptop; reopen; it catches up.
10. Desktop: Render current mix. The laptop's Mixes tab shows it.

## 2. Mac (the first real Mac run)

Before: `sw_vers`, `uname -m`, `xcode-select -p` (developer tools or not), `ls /Applications | grep -i -e tailscale -e reaper`.
Remove an App Store Tailscale if there is one (the installer adds the standalone one; Tailscale says never both).

1. Run the Mac line from an invitation (or `curl ... install_mac.sh | bash` and press Return for "later"). Watch and note each macOS prompt:
   your password, REAPER's disk image licence (agree in the Terminal), Syncthing's *Local Network*, Tailscale's system extension and VPN
   configuration, REAPER's microphone.
2. Pick a ReaPersona DAW. With developer tools installed, REAPER quits and comes back by itself with that DAW's shortcuts (this was broken
   on Macs until 0.58.68: if REAPER does not come back, open it by hand and say so). Without them, the end list says ReaPersona's Home has
   one step.
3. Panel: Health green; the studio card; Let them in from the PC.
4. Record a take: no "save recorded media?" box should appear (0.58.68 turns it off). It reaches the PC.
5. A print (a MIDI part through a plug-in): `~/Library/Caches/StudioSync/` gets a REAPER-render copy, no window flashes, the print lands.
   If not: Console.app, filter REAPER, look for codesign or dyld.
6. Play/Jam as host (Tailscale signed in): `pgrep ninjamsrv`; the PC connects.
7. Listening page: Mixes tab > share; open it on the phone over Tailscale; seek inside a mix.
8. Projects > free up space on a song: with and without Full Disk Access, the Trash message is honest.
9. Quit REAPER with a studio tab open; reopen: tabs come back with no boxes.
10. Run the installer again: "already installed", nothing redone.

## 3. Linux (supported from 0.58.74)

Tested in a VMware Ubuntu 24.04 VM (`J:\VMs\LinuxBox`, REAPER 7.86 portable, distro Syncthing 1.27): `install_linux.sh` with an
invitation, Let them in, the song matching the PC and Mac byte for byte, takes both ways in ~5 s, a claimed track's rename going in as
a suggestion, NINJAM server + relay + ReaNINJAM, the listening page (range requests, no symlinks or `..`), the Trash (`gio trash`),
reopening tabs after a quit, the View/Extensions menus, Ctrl+Z, ReaPersona with its shortcut install and relaunch, the installer run
again ("already in"), and being taken out of the studio. No Google Drive client on Linux (the Drive tickbox says so).
Known gaps: needs netcat for NINJAM checks (Ubuntu has it), distro Syncthing older than 1.27 keeps its config where StudioSync doesn't
look, Flatpak/AppImage REAPER isn't detected, background prints are off (prints render in front), NINJAM binaries need glibc 2.34+.

## 4. Before the band test

Host: REAPER 7.86 (what the installer fetches); a studio made; the test song built only from the plug-in pack and REAPER's own plug-ins
(anyone without a commercial plug-in gets it offline); Syncthing allowed in the firewall; REAPER and the panel left open while everyone
installs; **Let them in**, never *Guest, for a day*, for band members.

Everyone: wired internet if possible, headphones, the audio interface plugged in before running the line; Windows 11 (or 10 with App
Installer); Mac password ready; press Allow on Local Network, Microphone and Firewall; after REAPER's "audio device?" question, pick the
interface in Preferences > Audio; skip Tailscale and Google Drive sign-in unless asked; plug-in pack: yes. Use Discord or Zoom to talk
(the panel's Call button), Real time mode for hearing each other play, Play/Jam off.

Before anyone opens the song: every computer on the newest StudioSync (Health shows each person's version; an older one replays the
tempo map on every open and resends beat-timebase items). Claim your track before recording on it, arm it to be heard in Real time mode,
and on a Mac pick a plug-in's VST3 (or CLAP) rather than its AU, so Windows and Linux count it as the same plug-in.

Agree beforehand: who drives, who records first, that the driver doesn't render a mix mid-session (rendering holds up their REAPER and
others are told the driver's away), that "put back" banners mean someone else owns that part.

Watch and write down: install time per computer and where it stalled; seconds from stopping a recording to the take landing elsewhere,
and whether Health said *direct* or *relay*; every "put back" banner and whether its person understood it; SonoBus joins and latency; a
deliberate REAPER kill mid-session and the recovery; Sync and exit times; any `.sync-conflict` file; everything a newcomer asked aloud.

## Results, 2026-11-15 (0.58.68; fixes in 0.58.69 and ReaPersona 5.8.2)

Laptop (Windows, REAPER updated 7.85 -> 7.86, silently): take on the desktop 4 s after stopping; a rename ~5 s; Take control ~5 s;
Real time mode joined; Sync and exit 15 s and caught up on reopen within 6 s; a rendered mix on the laptop within seconds; every
connection direct. Found: running the invitation again moved a member onto a new, empty folder (fixed: the folder Syncthing already
has is used); REAPER's installer leaves a public desktop shortcut (removed by hand).

Mac (macOS 26.5.1, arm64, REAPER 7.84): update and installer re-run pass; Health all green, direct; a take reached the PC's
index the same second; no "save recorded media?" box; a print with no window shown. Found and fixed: setup looked for ReaPersona
before ReaPack had brought it; ReaPersona never found Python on a Mac (REAPER runs a bare `python3` as nothing: full paths now);
quitting with studio tabs open lost the reopen plan (tabs closed one by one with scripts running); a re-run opened Tailscale's page
every time, told a member to be let in, and printed the Google account. REAPER's own "new version" box held the first update sync.

## Known and left for after the test

- Fixed in 0.58.69: roles, removals and closing count only from the owner's or an admin's computer, as Syncthing records who changed the
  file (`lib/trust.lua`; the Console says when one is set aside). Left: someone in charge on a computer nobody has pinned yet (a new one
  of theirs) isn't believed until they act from a known one; identity is still a chosen name; claims (`given-*`) still trust their `by`.
- Fixed in 0.58.69: joiners pair with the inviter as an *introducer* without auto-accept (existing computers switch it off at the next
  Live sync start), so nobody can add a folder to someone else's computer unasked.
- Fixed in 0.58.69: the Tailscale API token is encrypted for the Windows account (DPAPI) or kept in the Mac Keychain; Linux keeps it in
  REAPER's settings.
- Fixed in 0.58.69: taking someone out gives the phone alerts a new channel; everyone else's StudioSync says to subscribe again.
- A take marker's length may be dropped by a collaborator on REAPER 7.85 or older when they re-save that item. Left: restoring it on
  7.86 would make the item differ between the two versions and risk the item syncing back and forth; everyone on 7.86 avoids it.
- ReaPersona 5.8.1 fixed its own Install button's Mac relaunch; 5.8.2 finds Python on a Mac.

## Reviews, 2026-11-16 (0.58.75; fixes in 0.58.76 and ReaPersona 5.9.3)

Seven read-only reviews (UX, ReaPersona, sync engine, plug-ins and data, security, installers, cross-platform) and a Linux stress test.
Fixed: the Windows installer couldn't start or join a studio (a comment swallowed the folder line, 0.58.69) and fetched a release that
doesn't exist (the menus package's 1.0.1); removals, roles and closing never counted on Syncthing 1.27 (REST now); a recording on a
track nobody claimed stayed "(yours, not sent)"; older tempo maps replayed during catch-up and went out as item edits; held changes
undone by a landing item or a heal; two edits made alone outvoted a claimant's own; FX containers read as loaded whatever was inside;
window and lane-view lines inside containers and FX envelopes counted as chain edits; plug-in files under AppData/Library could be
copied out, or written by a bandmate's event; an invitation could name any Syncthing folder; curly quotes in a file name could run
code in the Recycle Bin script; rescans of songs with spaces on Windows; Trim Volume applied twice on prints; preload saved every
open; the Mac and Linux installers ran when the whole invitation was pasted on the other system, a Mac guest's Tailscale key was tried
before macOS let Tailscale run, and plug-ins already installed still used up GitHub lookups. Put-backs now say what differed.

Left for after the test (by area):
- Plug-ins: AU and VST3 of one plug-in count as the same (prints and stand-ins miss it); installed-but-missing content (a Kontakt
  library, an EZX) can make a silent print; prints lose multi-out instruments and sidechains; automation items on plug-in parameters
  point at each machine's own pool; take FX get none of the restless/readback protections; ReaInsert and ReaStream travel live;
  offline-by-choice plug-ins block printing; media files edited in place, subprojects and video are copied once and whole.
- Security (matters for strangers, not a trusted band): `band.json` id and devices files aren't authenticated; first-use trust takes
  whatever roles are on disk; the listening page is served from the synced folder; the introducer flag stays on; the invitation is a
  shell line from unpinned `main`; Tailscale guests reach the whole tailnet unless the tag policy is set.
- Installers: GitHub's 60-requests-an-hour limit (plug-ins already installed no longer ask; Syncthing and SonoBus still do); an existing Syncthing with its
  config elsewhere (SyncTrayzor, snap, Homebrew); REAPER in a custom or portable folder; Windows without winget; macOS 11 and older;
  the 6-minute wait for REAPER's first plug-in scan; non-English letters in names.
- Cross-platform: non-ASCII Windows user names in `.cmd` files; Linux without netcat, older distro Syncthing, Flatpak/AppImage REAPER.
- ReaPersona: no uninstall (its startup block errors once removed); built-in personas share key layers with your own; trimming the
  Actions list doesn't look at mouse modifiers or SWS cycle actions; Linux can't open .zip/.rar theme packs.
