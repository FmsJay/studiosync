# The NINJAM server

`ninjamsrv` (Windows 64-bit and macOS) is Cockos's NINJAM server, unchanged, a separate program that StudioSync starts.
© Cockos Incorporated. GPL v2: https://github.com/justinfrankel/ninjam (built from commit `f4c0eff3a1d8d5f3ead470d0c7405c3ee37da24e`).
How it's built: `tools/ninjam-server` in StudioSync's repository.

`bandsync.cfg` lets in this computer and Tailscale addresses only.

`njrelay` (macOS only, StudioSync's own, GPL-3.0-or-later, source in `tools/ninjam-relay`): ReaNINJAM on a Mac connects through it, so a server
that goes away doesn't leave ReaNINJAM's "Disconnected from host!" alert holding every script.
