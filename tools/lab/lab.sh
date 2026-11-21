#!/bin/bash
# StudioSync lab: VMs and recipes from the desktop. VMware Workstation, headless. Only the lab VMs; never a real PC's firewall.
#   lab.sh vms                          which lab VMs run, and their IPs
#   lab.sh start|stop|ip x|x2           power (stop is a soft guest shutdown), guest IP
#   lab.sh clone NAME                   a linked clone of LinuxBox's "clean-reaper" snapshot into J:\VMs\NAME (7 MB; needs the console steps in docs/rt/rt-lab.md for first boot)
#   lab.sh net x|x2 block|unblock|shape|undo|status ...      netlab.sh inside that VM (see netlab.sh's header)
#   lab.sh identity x2 NAME             vm_identity.sh inside the clone
# x = LinuxBox (J:\VMs\LinuxBox, key-made ssh as studio), x2 = LinuxBox2. IPs come from VMware (vmrun getGuestIPAddress), else set X_IP / X2_IP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VMRUN="/c/Program Files/VMware/VMware Workstation/vmrun.exe"
declare -A VMX=([x]='J:\VMs\LinuxBox\LinuxBox.vmx' [x2]='J:\VMs\LinuxBox2\LinuxBox2.vmx')
vmip() { local v="$1" e; e=$(echo "${v^^}_IP"); [ -n "${!e:-}" ] && { echo "${!e}"; return; }; "$VMRUN" -T ws getGuestIPAddress "${VMX[$v]}" 2>/dev/null; }
ssh_() { local v="$1"; shift; ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "studio@$(vmip "$v")" "$@"; }
known() { [ -n "${VMX[${1:-}]:-}" ] || { echo "VM is x or x2"; exit 2; }; }
c="${1:-}"; shift || true
case "$c" in
  vms)   "$VMRUN" -T ws list; for v in x x2; do echo "$v: $(vmip $v)"; done;;
  start) known "$1"; "$VMRUN" -T ws start "${VMX[$1]}" nogui;;
  stop)  known "$1"; "$VMRUN" -T ws stop "${VMX[$1]}" soft;;
  ip)    known "$1"; vmip "$1";;
  net)   known "$1"; v="$1"; shift; ssh_ "$v" "sudo bash -s -- $*" < "$HERE/netlab.sh";;
  identity) known "$1"; [ "$1" != x ] || { echo "refused: never on LinuxBox itself"; exit 3; }; v="$1"; shift; ssh_ "$v" "sudo bash -s -- $*" < "$HERE/vm_identity.sh";;
  clone) n="${1:?name}"; "$VMRUN" -T ws clone "${VMX[x]}" "J:\VMs\$n\$n.vmx" linked -snapshot=clean-reaper -cloneName="$n";;
  *) sed -n '2,10p' "$0"; exit 2;;
esac
