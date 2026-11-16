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

## 3. Linux (not supported yet)

What works as is: Syncthing, Tailscale, REAPER, SWS, ReaImGui, ReaPack, js_ReaScriptAPI and SonoBus all have Linux builds. What does not:
every OS branch treats anything that isn't Windows as a Mac (`GetOS()` says "Other" on Linux), so port checks (`nc -G`), opening links
(`open`), the Trash, the NINJAM server binary (Mac build shipped) and the REAPER relaunch path go wrong; there is no installer and no
Google Drive client (rclone would stand in). Roughly 3-4 days: an `IS_LINUX` pass over about a dozen branches (half a day), `xdg-open` /
`gio trash` / `nc -w` swaps, Linux NINJAM builds, an `install_linux.sh` from the Mac one (1-2 days), tests.
Test it in a VMware Ubuntu 24.04 VM (bridged network, 3D acceleration on); WSL2 has no real audio and fights Tailscale.

## 4. Before the band test

Host: REAPER 7.86 (what the installer fetches); a studio made; the test song built only from the plug-in pack and REAPER's own plug-ins
(anyone without a commercial plug-in gets it offline); Syncthing allowed in the firewall; REAPER and the panel left open while everyone
installs; **Let them in**, never *Guest, for a day*, for band members.

Everyone: wired internet if possible, headphones, the audio interface plugged in before running the line; Windows 11 (or 10 with App
Installer); Mac password ready; press Allow on Local Network, Microphone and Firewall; after REAPER's "audio device?" question, pick the
interface in Preferences > Audio; skip Tailscale and Google Drive sign-in unless asked; plug-in pack: yes. Use Discord or Zoom to talk
(the panel's Call button), Real time mode for hearing each other play, Play/Jam off.

Agree beforehand: who drives, who records first, that the driver doesn't render a mix mid-session (rendering holds up their REAPER and
others are told the driver's away), that "put back" banners mean someone else owns that part.

Watch and write down: install time per computer and where it stalled; seconds from stopping a recording to the take landing elsewhere,
and whether Health said *direct* or *relay*; every "put back" banner and whether its person understood it; SonoBus joins and latency; a
deliberate REAPER kill mid-session and the recovery; Sync and exit times; any `.sync-conflict` file; everything a newcomer asked aloud.

## Known and left for after the test

- Roles, removals and closing a studio are files any member can write (trusted bands only). Identity is a chosen name.
- A joiner pairs with the inviter as a Syncthing *introducer* with auto-accept: how a joiner meets the rest of the band, and also how a
  hostile inviter could push folders. Fine between people who know each other.
- The Tailscale API token lives in REAPER's settings in plain text; use a short-lived token.
- The phone-alert channel isn't changed when someone is removed (changing it means everyone re-subscribes their phone).
- A take marker's length may be dropped by a collaborator on REAPER 7.85 or older when they re-save that item.
- ReaPersona's own Install button has the same Mac relaunch bug fixed here in StudioSync (separate repo).
