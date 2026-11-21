# rt-lab (T2): the VM test lab (2026-11-21)

Package T2 of `docs/rt/backlog.md` "Plan to finish". James's direction: tests that need a blocked link, or "hub ranking with a firewall", go in VMs
(LinuxBox plus another VM), never the real PCs' firewalls; network shaping happens only inside VMs. Scripts and usage: `tools/lab/README.md`.

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
