#!/bin/bash
# StudioSync lab: give a CLONED lab VM its own identity. Runs INSIDE the clone as root (lab.sh identity x2 NAME does it).
#   vm_identity.sh NAME
# Idempotent: it records NAME in /var/lib/lab-identity; a repeat with the same NAME changes nothing and just prints the identities.
# What a clone shares with its parent, and what this resets:
#   hostname, /etc/hosts     -> NAME
#   /etc/machine-id          -> new (DHCP's client id and journald follow it after the next boot; a shared one made VMware's DHCP treat
#                               the clone and its parent as one client)
#   ssh host keys            -> new
#   Syncthing device id      -> new cert.pem/key.pem (from `syncthing generate`); Syncthing is NOT started or enabled by this script
#   StudioSync device key    -> ~/.studiosync/device-key removed; the extension makes a new Ed25519 key (and so a new key-made id) the
#                               first time REAPER runs StudioSync. The clone is not in any studio until the joining steps in docs/rt/rt-lab.md.
# Refuses (changes nothing) if Syncthing or Tailscale is running in the clone: a clone must not carry a live identity of its parent.
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"
NAME="${1:-}"; [[ "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "usage: vm_identity.sh NAME (lowercase letters, digits, dashes)"; exit 2; }
U=studio; H=/home/$U; ST=$H/.local/state/syncthing; MARK=/var/lib/lab-identity
if pgrep -x syncthing >/dev/null || systemctl is-active --quiet tailscaled 2>/dev/null; then
  echo "refused: syncthing or tailscaled is running here. This is a clone: stop it only if it is meant to keep that identity."; exit 3; fi
if [ "$(cat $MARK 2>/dev/null)" != "$NAME" ]; then
  hostnamectl set-hostname "$NAME" && echo "changed: hostname -> $NAME"
  grep -q '^127.0.1.1' /etc/hosts && sed -i "s/^127.0.1.1.*/127.0.1.1 $NAME/" /etc/hosts || echo "127.0.1.1 $NAME" >> /etc/hosts
  rm -f /etc/machine-id /var/lib/dbus/machine-id; systemd-machine-id-setup >/dev/null && echo "changed: new machine-id $(cat /etc/machine-id) (DHCP client id follows after a reboot)"
  rm -f /etc/ssh/ssh_host_*; ssh-keygen -A >/dev/null && systemctl restart ssh && echo "changed: new ssh host keys"
  rm -f "$H/.studiosync/device-key" && echo "changed: StudioSync device key removed (the extension makes a new one at first run)"
  rm -rf "$ST"; sudo -u $U mkdir -p "$ST"; sudo -u $U syncthing generate --home="$ST" >/dev/null 2>&1 && echo "changed: new Syncthing keys in $ST"
  echo "$NAME" > $MARK
else echo "already: identity $NAME was set (remove $MARK to redo)"; fi
echo "== identities now"
echo "hostname:   $(hostname)"; echo "machine-id: $(cat /etc/machine-id)"
echo "ssh host:   $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f2)"
echo "syncthing:  $(sudo -u $U syncthing --device-id --home="$ST" 2>/dev/null || echo none)"
echo "studiosync: $([ -f $H/.studiosync/device-key ] && echo 'device-key present' || echo 'no device-key yet (made at first run)')"
grep -qs '^\[BandSync\]' $H/REAPER/reaper-extstate.ini && echo "WARNING: REAPER ExtState has a [BandSync] section: this VM already knows a studio (the clone came from a joined VM?)"
