# New-bandmate test in Windows Sandbox

A throwaway Windows (wiped when its window closes) installing StudioSync from a real invitation, the way a new bandmate would.
Needs Windows Sandbox turned on (Windows Pro, admin, once): `Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -All`.

1. Make a throwaway studio and a guest invitation in StudioSync (Studios page), and save the invitation's Windows line, alone, as
   `ss\invite.txt` next to `ss\setup.ps1` (the folder `studiosync-guest.wsb` maps; edit its HostFolder). The Sandbox deletes it once read.
2. Open `studiosync-guest.wsb`. `setup.ps1` installs winget, runs the invitation's line with answers to the installer's questions,
   then every 10 s writes `ss\status.txt` and a screenshot of the Sandbox's own screen (`ss\shot.png`), and runs any `ss\cmd-*.ps1`
   dropped in (output in `cmd-*.out`), so the test can be driven without touching the host's screen.
3. On a first start REAPER asks about the audio device and ReaPack shows Manage repositories: until they're answered the setup step waits.
4. Afterwards: `tailscale logout` inside it (the guest leaves the network at once), close it, and in StudioSync forget the studio and
   its join requests.

Found with it (2026-11-10): the installer's REAPER launch glued `-nonewinst` to the script's path (0.58.37), a guest's Tailscale
sign-in came after the REAPER step (0.58.36), the first-start questions weren't named (0.58.38). A real guest reached the host on
22000 and 2049 only, as Set up the tags' guest rule says.
