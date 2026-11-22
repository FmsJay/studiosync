# rt-lab (T2): the VM test lab (2026-11-21)

Package T2 of `docs/rt/backlog.md` "Plan to finish". James's direction: tests that need a blocked link, or "hub ranking with a firewall", go in VMs
(LinuxBox plus another VM), never the real PCs' firewalls; network shaping happens only inside VMs. Scripts and usage: `tools/lab/README.md`.

> **Warning: never use a VM's audio input for a test** (rt-fix7, from rt-r2). LinuxBox2's PulseAudio input may be the desktop's **real** input
> passed through VMware's sound device: the desktop's microphone or a Voicemeeter bus. Test signals must come from a source generated inside
> the VM, such as a PulseAudio null sink with a tone played into it and its `.monitor` as the input (recipe in `tools/lab/README.md`). Check
> the VM's selected input before any sound test; with no generated source set up, keep Deafen on and run no sound tests there.

## What exists now

| Thing | State |
|---|---|
| **LinuxBox2** `J:\VMs\LinuxBox2\LinuxBox2.vmx` | A **linked clone** of LinuxBox's `clean-reaper` snapshot (taken 2026-11-16, powered off, before StudioSync, Syncthing and Tailscale were set up on LinuxBox). Ubuntu 24.04, REAPER 7.86 portable with ReaPack, SWS, ReaImGui, js_ReaScriptAPI and the dev-eval hook, same `studio` user and ssh key. 4 vCPU, 8 GB RAM, VMware NAT (vmnet8, 192.168.86.x; it had .130), VNC 127.0.0.1:5973. **Left powered off.** |
| Disk used | **287 MB** (the delta disk after three boots; 7.6 MB when created) on J: (891 GB free, 77 % used). Its base is LinuxBox's snapshot disk `LinuxBox-disk1.vmdk` (4.2 GB, shared, read-only): **never delete or consolidate LinuxBox's `clean-reaper` snapshot**, the clone would lose its disk. A full clone would be about 14 GB (LinuxBox is 4.2 GB base + 9.5 GB delta) and would copy LinuxBox's studio state, so it was not used. |
| LinuxBox | Untouched: still running, REAPER and StudioSync as they were. I took no snapshot of it and ran only read-only `ssh` checks on it (ip, ps, ls, hostname), plus pings from the clone to it. |
| Own identity | hostname `linuxbox2`; new machine-id (the clone and LinuxBox shared one, and VMware's DHCP saw the same client id); new ssh host keys; new Syncthing keys, device id `L6QCBAS-XTWETY7-M2VB3S6-63XSQT5-H6DYDBG-BZWDC6Q-GRO3GWC-XUFY4QP` (`~/.local/state/syncthing`; Syncthing is **not started or enabled** and has never run); no `~/.studiosync/device-key` (see below). New MAC (VMware generated `00:0c:29:35:7d:e6`). |
| Not in any studio | No Syncthing running, no Tailscale installed, no StudioSync scripts, no `[BandSync]` ExtState. REAPER was not started in it. It cannot reach Smiley Studios or any real studio. |
| `tools/lab/` | `lab.sh`, `netlab.sh`, `vm_identity.sh`, `README.md`. |

### How a computer's identity is made (read in `lib/signed.lua`, `lib/services.lua`)
- **Syncthing device id** = the cert of `~/.local/state/syncthing` (Linux). A clone shares the parent's if it was copied after the first run, so
  `vm_identity.sh` makes new keys with `syncthing generate`, in the clone only.
- **StudioSync's own identity** = an Ed25519 key `~/.studiosync/device-key`, created by the extension (`StudioSync_KeyCreate`) the first time StudioSync
  runs; its public key becomes the "key-made id" (`sw.device_id(key)`) and each studio's devices file carries it. A copied key would make two computers
  sign as one, so the script deletes it (the extension makes a new one at first run). Which studios a computer knows sit in REAPER's ExtState section
  `BandSync`; the script warns if that exists. I did not check `~/.studiosync/nat-key` (the key invitations are sealed to) beyond the folder
  being absent in this clone; if a clone is ever made from a joined VM, delete that folder's keys as well.
- Run again any time: `./lab.sh identity x2 linuxbox2` does nothing the second time (marker `/var/lib/lab-identity`).

### Making the clone, and one snag worth knowing
`./lab.sh clone NAME` runs `vmrun -T ws clone ... linked -snapshot=clean-reaper -cloneName=NAME`. VMware gives the clone a new MAC and BIOS UUID, but
**the guest's netplan matches the parent's MAC** (`/etc/netplan/50-cloud-init.yaml`, `match: macaddress`), so a clone boots with no network and no
VMware Tools IP. I fixed it through the VNC console (`127.0.0.1:5973`, keystrokes into a terminal) by rewriting netplan to `ens192: dhcp4: true`,
then did everything else over ssh. The two helpers I used (`vnctype`, `vncshot`) are in my scratchpad, not committed. Clones of LinuxBox2 get the fixed
netplan for free (take a powered-off snapshot of LinuxBox2 and clone that).

## Recipes (`tools/lab/netlab.sh`), tested 2026-11-21 on LinuxBox2 against LinuxBox's NAT address
| Recipe | Result |
|---|---|
| baseline | ping 0.15 to 0.22 ms |
| `block <ip> 47281/udp` twice | first call: chain made, hooked into INPUT and OUTPUT, 4 rules added; second: four `already:` lines |
| `block <ip>` (everything) | ping 100 % loss; `unblock` brings it back; `unblock` again prints `already absent` |
| `shape <ip> --delay 80 --jitter 20 --loss 2` | rtt 58 to 110 ms (one direction shaped); another address unaffected; a repeat leaves the same state |
| `undo` twice | first: unhooks, deletes the chain, removes the qdisc; second: nothing left to do |

Port 47281 (the direct link) is the one to cut for rt-hubrank 2 and 6. On LinuxBox the link runs over its Tailscale address, so block that address
(or run the recipe between two VMs that use their LAN addresses, as in the NAT plan). Syncthing's port is 22000 (tcp and udp), discovery 21027/udp.
Not tested: the recipes on LinuxBox itself (I did not shape the VM that is in the test studio), `tailscale0` shaping, and a real StudioSync hub run through them.

## Steps waiting for James's approval (not run)
Joining LinuxBox2 to the test studio (backlog 6.16: Smiley Studios, "Cross Test"; never Chilio's). Nothing here was done.

1. **Decide how it reaches the others.** StudioSync's link addresses are Tailscale names and addresses, and LinuxBox2 has no Tailscale. Choose:
   (a) put LinuxBox2 on the tailnet as a new node: needs the Tailscale package (not downloaded; LinuxBox's copy might still be in
   `/var/cache/apt/archives`, otherwise a download from Tailscale's apt repository) and a login of a new device, which is an account change; or
   (b) keep it off the tailnet and use the studio's `nat` mode (band.json `nat`, off by default, rt-nat2/rt-nat3). That is the router-VM plan below and
   the better test of it. For first tests that only need LinuxBox and LinuxBox2 on the VMware LAN, (b) is enough.
2. **Put the software in** (no download): `scp` LinuxBox's `~/REAPER/UserPlugins/reaper_studiosync-x86_64.so` (extension 1.0.33) and the Hop plug-in
   files from LinuxBox to LinuxBox2 through the desktop. StudioSync's scripts arrive with the studio through Syncthing; the first time, copy
   `~/StudioSync Smiley Studios/_tools/studiosync` once from LinuxBox.
3. **Start Syncthing in the clone** (as LinuxBox runs it: `syncthing serve --no-browser`), read its device id (above), add it on the desktop's
   Syncthing for the test studio's folder only, and accept the one folder offer on LinuxBox2. This changes the desktop's Syncthing, so it is yours to do
   or approve; I did not touch it.
4. **Join through StudioSync's own invitation** (rt-joinlink): on the desktop open Smiley Studios, Invite a collaborator, copy the token. On LinuxBox2
   start REAPER (`DISPLAY=:0 ~/start-reaper.sh`), start the realtime Live sync from the studio's `_tools/studiosync` (as `/tmp/vm_open.lua` does on
   LinuxBox), Paste join code. Within seconds its log reports the first copy. Set Deafen first (`BandSync / live audio deaf` = 1).
5. Before step 3, take a powered-off snapshot of LinuxBox2 (`vmrun snapshot`) so a bad join reverts to "no studio".

Also pending: whether LinuxBox2 stays up between tests (it takes 8 GB of the desktop's RAM; it is off now), and the downloads below.

## Plan (not built)

### 1. Router VM: cone, symmetric and double NAT, hairpin, network change (P13, R7: backlog 2.29, 2.30)
- **Shape:** a "RouterBox" VM (a linked clone of LinuxBox2, XFCE off, about 300 MB) with two NICs on VMware **LAN segments**, which touch none of the
  desktop's own network adapters or firewall. `lan-a`: a client VM behind the router; `wan`: the "internet" side, where the other client and a
  STUN/relay host sit. Clients: LinuxBox2 behind `lan-a`, LinuxBox on `wan` (a second NIC on LinuxBox means editing its vmx while off, which is a James
  step; the alternative that leaves LinuxBox alone is a third clone, LinuxBox3, for the other side).
- **NAT kinds with nftables in the router VM:**
  - full cone: static `dnat` per mapped port plus `masquerade`;
  - address- and port-restricted cone: `masquerade` with an input rule that only passes back sources the inside host sent to (conntrack's default);
  - symmetric: `masquerade fully-random` (a new external port per destination);
  - CGNAT / double NAT: a second router VM (or a network namespace) in series, each masquerading;
  - hairpin on and off: `dnat` of the external address to the inside host, with or without the matching `snat` for same-side clients;
  - network change: move a client between segments (`vmrun` NIC reattach, or `ip addr` / `nmcli` flip) during a call.
- `netlab.sh` runs on the router too, for loss and latency on the "internet" leg.
- **Needs (ask first):** two or three more clones (about 300 MB each); `nftables` is in Ubuntu 24.04; `conntrack` (apt, a download) for inspecting mappings; a STUN
  responder (`coturn` from apt, or the relay in `tools/ninjam-relay`). Nothing is built.
- **Gate (backlog 2.29):** an hour with Tailscale off on one side, over each NAT kind.

### 2. The S23 over adb (backlog 2.26 to 2.28, P5, P11, R6)
Read-only checks run now (no tap, no app started):
- `adb devices -l`: `jamess-s23-ultra:5555 device product:dm3quew model:SM_S918U1` (wireless adb over the tailnet); `ssh s23` answers (aarch64, Android 17).
- Chrome (`com.android.chrome`) is installed and running with its DevTools socket (`/proc/net/unix` lists `devtools_remote`); Termux, Termux:API and Termux:X11 are there.
- On the desktop: `adb` (platform-tools), `scrcpy 5.0.1`, Chrome at `C:\Program Files\Google\Chrome\Application\chrome.exe`.

The driver, to build in a later round (`tools/lab/s23_cdp.py`):
1. `adb -s jamess-s23-ultra:5555 forward tcp:9222 localabstract:chrome_devtools_remote` (remove with `adb forward --remove tcp:9222`; rt-p5 uses the same line).
2. Playwright `chromium.connect_over_cdp("http://127.0.0.1:9222")`. Python Playwright is not installed on the desktop (a pip package and a browser: a download, **ask**).
   Open the studio page by its Tailscale name in a **new tab**, drive it by DOM, close the tab after; never touch James's own tabs.
3. No fake microphone on Android Chrome, so the S23's pages are listen-only ones (listening links, phone keys, Project view). Where a page asks for the
   microphone, answer Block through DevTools (`Browser.setPermission`); never a real recording.
4. **Audio capture with scrcpy, nothing installed on the phone:** `scrcpy -s jamess-s23-ultra:5555 --no-video --no-control --audio-source=playback --audio-dup
   --record=<scratch>/s23.opus` (`--audio-dup` keeps the sound on the phone; Android 11+; if `playback` is refused use `--audio-source=output`). Convert with ffmpeg
   (on PATH) and read it with `tools/ears` for tone, level and dropouts. The adb link is wireless, so use it for presence, level and gaps, not latency. The
   test tone goes to the phone at a very low level.
5. The S23 is James's daily phone: one run at a time with his OK, never during calls; no taps from an agent (UI automation of the phone is a separate decision).

### 3. Chromium fake devices for browser guests
- Desktop (exists): Chrome with `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream --use-file-for-fake-audio-capture=<tone.wav>
  --remote-debugging-port=9333 --user-data-dir=<scratch dir> --autoplay-policy=no-user-gesture-required` (`--headless=new` for unattended), driven by CDP as in
  rt-browserjoin and rt-ears. A launcher `tools/lab/browser_guest.sh <url> <wav> <port>` is the small build for next round.
- In a VM: LinuxBox already has Playwright's Chromium 1255 in `~/.cache/ms-playwright` (and no Python Playwright module). The same flags work with its
  `chrome` binary, headless. For a second guest on LinuxBox2 copy that folder over with `scp` (no download). Each guest gets its own `--user-data-dir`, debug port and WAV.
- Shaping a VM's traffic with `netlab.sh` shapes its browser guest too, which is how a guest on a bad link is tested.
- Never a real microphone or camera; the WAV is generated (`ffmpeg -f lavfi -i sine=frequency=1000:duration=60 tone.wav`).

## What I need from James (all optional)
- Approve or change the joining steps (and how LinuxBox2 reaches the studio: tailnet node or `nat` mode).
- Approve downloads for the plans: `conntrack` and maybe `coturn` (apt, a few MB), Python Playwright on the desktop (pip plus a browser, about 200 MB).
- Say whether LinuxBox2 may stay up between tests, and whether LinuxBox may get a second adapter for the router lab (or use a clone).

## Review later (security)
- LinuxBox and LinuxBox2 share the `studio` ssh key and passwordless sudo: fine for a lab on VMware's NAT network, not for anything reachable from outside.
- `netlab.sh` and `vm_identity.sh` run as root inside the VMs through key-only ssh from the desktop; `lab.sh identity` refuses LinuxBox itself.
- A forwarded DevTools port exposes the phone's Chrome on the desktop's `127.0.0.1:9222`; remove the forward after each run.
- `vm_identity.sh` deletes `~/.studiosync/device-key` and the Syncthing state of the VM it runs on: a wrong target loses that VM's identity.

## LinuxBox2 joined to the test studio without Tailscale (rt-r1, 2026-11-21, James's OK; 0.59.49.93 + extension 1.0.35)

Done as the waiting steps above, with (b): no Tailscale on LinuxBox2, and **nat mode not switched on** (band.json `nat` untouched): the
join and Cross Test's convergence didn't need it (Syncthing carries everything when the link can't reach a computer).

1. Powered-off snapshot `pre-studio-rt-r1` of LinuxBox2 (vmrun), then `vmrun -T ws start ... nogui` (192.168.86.130).
2. Copied in by scp: `extension/reaper_studiosync-x86_64.so` from 7e4e388 (md5 d11fe87a..., the same as LinuxBox's) to `~/REAPER/UserPlugins`,
   and LinuxBox's `~/.vst3/StudioSync Hop.vst3` and `~/.clap/StudioSync Hop.clap`; LinuxBox's `_tools/studiosync` (0.59.49.93) to
   `~/studiosync-boot/studiosync` (outside the studio's folder, which join_band makes), only to run the join.
3. Syncthing started in the clone (`syncthing serve --no-browser --no-restart --logflags=0`, first run, device `L6QCBAS-...`).
4. Desktop: Invite a collaborator as the Invitation window does for someone who has StudioSync (`joins.make(root, "member")` + `invite_text(...,
   "has", token)`): a signed invitation (record `_band/joins/1c75332c...json`).
5. LinuxBox2 (first run: name "LinuxBox2", ExtState `sync_root` ~/StudioSync as ReaPack's first run makes it, Deafen = 1 set first): Paste join code
   > Join as the panel does (`services.parse_join`, `services.join_band`, `joins.request`): folder `~/StudioSync Smiley Studios` added with the
   desktop as introducer; the invitation's ask goes over the link, which can't reach the desktop from here (no Tailscale names), so:
6. Desktop: the panel's join request appeared (`services.join_asks`: `linuxbox2`, no folder yet) and Let them in (`tools.let_in`) added the device;
   20 s later its folder offer appeared and the second Let them in shared **only** `studiosync-smiley-studios-a963` (the desktop's
   `reapersona-sync` and `studiosync-chilio-8bbf` don't list it; checked with `syncthing cli config folders <id> devices list`).
7. LinuxBox2 synced the studio (idle, need 0, 60 MB: the songs as listings) and was introduced to the studio's other devices; LinuxBox logged
   "LinuxBox2's computer (L6QCBAS) is in Smiley Studios: this one syncs with it directly now".
8. LinuxBox2 opened Cross Test with the studio's own "Open session" (quiet) at 01:06:32: "opened 'Cross Test' (hosted by James), Live sync started".

**Converges: pass.** Cross Test compared on all four (rt-check2's cmp.lua): LinuxBox2 = the desktop = the laptop at once (only the desktop's
and laptop's local "StudioSync live out" track differs, as it does on LinuxBox). A move on the desktop (XT Keys C to 8.0) and one on
LinuxBox2 (XT Drums A to 2.5) were on all four within 15-20 s; put back after (the second from LinuxBox2, see below), all four alike again.

**Found:**
- **A claim ask can't reach a computer off the link.** LinuxBox2's move auto-claimed XT Drums A; the desktop's put-back move asked LinuxBox2
  to release it, "Not sent: LinuxBox2 didn't answer about XT Drums A in 30 s. Your edit is put back". Without Tailscale (or nat mode) a
  bandmate's claimed track can't be edited by anyone until the claim's 10 minutes run out; Syncthing doesn't carry the ask.
- **Log spam:** LinuxBox2 logs "live audio didn't start: Tailscale isn't up here (no 100.64.0.0/10 address)" every ~10 s for as long as Live
  sync runs.
- **Syncthing's first tune on a fresh Syncthing:** "Syncthing didn't answer within 8 s: StudioSync leaves it alone for a minute" and
  "couldn't set fswatcher-delays: -1005" at the first Live sync start (the set took over 8 s), on top of the `fswatcher-timeouts` key that
  Syncthing 1.27 doesn't have (rt-linkmove's check E).
- LinuxBox's earlier "XT R1 take (yours, not sent)" (rt-linkmove's check C) showed up in this compare; removed there.

**Not done:** the P10 joining checks (rt-joinlink / rt-invite round 2: their commits come after 7e4e388, not deployed); live audio, Hop and the
link with LinuxBox2 (they need Tailscale or nat mode); a second join. **State after:** LinuxBox2 is in Smiley Studios (its devices file and the
desktop's Syncthing device and share stay), Cross Test open, Deafen 1, and suspended (`vmrun suspend`). To undo the join: revert to snapshot
`pre-studio-rt-r1`, remove device `L6QCBAS` from the desktop's Syncthing and take LinuxBox2 out in the panel (Settings > Studio).

### Re-checks after rt-fix6a (docs/rt/rt-fix6a.md, parts 3 and 4)

- [ ] **No claim without an edit.** Open Cross Test on LinuxBox2 and touch nothing for two minutes. Pass: no claim of LinuxBox2's in Who
  controls or its claims file, even if "change(s) went to the others" shows (its REAPER read XT Rec A's lane names its own way: that still goes
  out, see rt-fix6a "Left"). Then move an item there: its track is claimed.
- [ ] **Claim asks off the link.** LinuxBox2 (no Tailscale) moves an item on XT Drums A (auto-claim). On the desktop move the same item: it goes
  out at once with "can't reach them to ask", nobody is asked, all four end alike (within a minute where both moved it). Then Claim XT Drums A
  by hand on LinuxBox2 and edit it on the desktop: put back at once with the "can't reach them" words, no 30 s wait.

## rt-r2 notes (rt-r2, 2026-11-21 evening MT / 11-22 UTC, StudioSync 0.59.49.94 from 905f000 + extension 1.0.36 on the desktop, laptop, LinuxBox and LinuxBox2; Deafen 1 everywhere, no sound tests)

- LinuxBox2 resumed 01:35 UTC, extension 1.0.36 installed (`rel36_for_lb2.so`, sha256 ee32e29b..., the 1.0.35 .so moved to
  `~/.local/share/Trash/files/reaper_studiosync-x86_64.so.1035-1795311354`), its tools reached 0.59.49.94 by Syncthing, REAPER restarted
  (`pkill -TERM -x reaper; ~/start-reaper.sh -new`), Cross Test opened with the studio's Open session; Deafen 1. **Suspended at 03:37 UTC**, Cross
  Test open, Syncthing running, nothing paused or blocked.
- Blocking the desktop from a VM: see rt-hubrank's R2 "Lab lessons" (UDP only, every desktop address including its Tailscale address, and IPv6).
- LinuxBox2's web UI from the desktop: `ssh -L 47290:127.0.0.1:47281 studio@192.168.86.130`, then requests with `Host: localhost:47281`
  (`/api/state`, `/api/action` with `X-StudioSync: 1`); a browser can't, as it sends its own Host.
