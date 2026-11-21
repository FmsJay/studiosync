# tools/lab: the VM test lab

Scripts for the lab VMs (VMware Workstation on the desktop): **LinuxBox** (`J:\VMs\LinuxBox`, in Smiley Studios' test studio) and **LinuxBox2**
(`J:\VMs\LinuxBox2`, a linked clone with its own identity, in no studio). Full write-up, the steps waiting for James and the plan for the
router VM and the S23: `docs/rt/rt-lab.md`.

Rule (James, 2026-11-21): a blocked link, lost packets or latency are made **inside the VMs only**. Never in the real PCs' firewalls.

| File | Runs on | What |
|---|---|---|
| `lab.sh` | desktop (Git Bash) | `vms`, `start`/`stop`/`ip` `x`/`x2`, `clone NAME`, `net x/x2 ...`, `identity x2 NAME`. `x` = LinuxBox, `x2` = LinuxBox2. IPs from `vmrun getGuestIPAddress`, or set `X_IP` / `X2_IP`. |
| `netlab.sh` | inside a VM (root) | `block`, `unblock`, `shape` (netem delay, jitter, loss, rate, reorder), `undo`, `status`. Idempotent; every change prints a `changed:` line, a repeat prints `already ...`. |
| `vm_identity.sh` | inside the clone (root) | hostname, machine-id, ssh host keys, Syncthing keys, StudioSync device key. Refuses if Syncthing or Tailscale runs there; `lab.sh` refuses to run it on LinuxBox. |

```bash
cd tools/lab
export X_IP=192.168.86.129 X2_IP=192.168.86.130          # or leave unset: vmrun finds them (VMware Tools must be running)
./lab.sh net x2 block 192.168.86.129 47281/udp            # LinuxBox2 drops the direct-link port to LinuxBox, both directions
./lab.sh net x2 block 192.168.86.129                      # every packet to and from it
./lab.sh net x2 shape 192.168.86.129 --delay 80 --jitter 20 --loss 2   # egress to that peer only (round trip = both VMs' delays added)
./lab.sh net x2 shape all --delay 150 --rate 500          # the whole interface
./lab.sh net x2 status
./lab.sh net x2 undo                                      # always safe, any number of times
```

Notes
- Recipes act on IPv4 addresses. LinuxBox has two: its VMware NAT address (192.168.86.x) and its Tailscale 100.x address (StudioSync's direct link
  uses the Tailscale one on LinuxBox). Block each address you mean to cut; shaping goes on the interface (`--dev tailscale0`).
- Prefer running recipes on LinuxBox2. They need `sudo` (the `studio` user has it passwordless); LinuxBox gets the same script when a test needs it
  there, always followed by `undo`.
- Tested 2026-11-21 between the two VMs: baseline ping 0.2 ms; with `block` 100 % loss and with `unblock`/`undo` back to 0.2 ms; `shape ... --delay 80
  --jitter 20 --loss 2` gave 58-110 ms (one direction shaped); a ping to another address (the VMware gateway) stayed 0.2 ms.
