#!/bin/bash
# StudioSync lab: the router VM ("RouterBox", docs/rt/rt-nat3.md round 2). Runs INSIDE RouterBox only, as root, never on the real PCs.
# RouterBox has two NICs on VMware LAN segments (they touch none of the desktop's own adapters): WAN on "lab-wan" (the lab's "internet",
# where the other bandmate and tools/lab/stun.py sit) and LAN on "lab-lan" (the client behind this router: LinuxBox2).
#   routerlab.sh up WAN_IF WAN_CIDR LAN_IF [CLIENT_IP]   addresses (LAN side 10.77.0.1/24, the client 10.77.0.2 by default), forwarding on,
#                                                         the restricted (Linux's usual) NAT
#   routerlab.sh mode open|restricted|symmetric|cone      the NAT kind (open: routing only, the client's address is "public")
#   routerlab.sh forward on|stun|off                      the relay's port forward (UDP 47298-47314 to the client): James's router step;
#                                                         stun: 47298 only (a relay that answers STUN but can't relay)
#   routerlab.sh hairpin on|off                           the client reaching this router's own WAN address comes back in
#   routerlab.sh double on|off                            a carrier's NAT (CGNAT) in front: this router moves into a namespace "home" whose own
#                                                         WAN address is 100.64.77.2; the forward there can't be reached from outside
#   routerlab.sh wanip NEW_CIDR                           a new WAN address (the provider gave another: a network change for STUN)
#   routerlab.sh status | undo
# Idempotent: every change renders the whole nftables table "routerlab" from the state in /run/routerlab.env, so a repeat changes nothing.
# Every change prints a line starting "changed:". Not run yet (James builds RouterBox first: docs/rt/rt-nat3.md round 2, "The router VM").
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"
ST=/run/routerlab.env
say() { echo "$*"; }
need() { command -v "$1" >/dev/null || { say "missing tool: $1"; exit 2; }; }
need nft; need ip
WAN_IF="" WAN_CIDR="" LAN_IF="" CLIENT=10.77.0.2 MODE=restricted FORWARD=off HAIRPIN=off DOUBLE=off
[ -f "$ST" ] && . "$ST"
save() { printf 'WAN_IF=%q WAN_CIDR=%q LAN_IF=%q CLIENT=%q MODE=%q FORWARD=%q HAIRPIN=%q DOUBLE=%q\n' "$WAN_IF" "$WAN_CIDR" "$LAN_IF" "$CLIENT" "$MODE" "$FORWARD" "$HAIRPIN" "$DOUBLE" > "$ST"; }
ready() { [ -n "$WAN_IF" ] && [ -n "$LAN_IF" ] || { say "run 'routerlab.sh up WAN_IF WAN_CIDR LAN_IF' first"; exit 2; }; }
HOME_NS=home
in_home() { if [ "$DOUBLE" = on ]; then ip netns exec $HOME_NS "$@"; else "$@"; fi; }
# The home router's rules (in "home" when double, else here): the NAT kind, the forward, hairpin. out_if: its way out; its WAN address.
home_rules() {
  local out_if="$1" wan_ip="$2" nat=""
  case "$MODE" in
    open) nat="";;
    restricted) nat="oifname \"$out_if\" masquerade";;
    symmetric) nat="oifname \"$out_if\" masquerade fully-random";;
    cone) nat="oifname \"$out_if\" masquerade persistent";;
  esac
  echo "table ip routerlab {"
  echo "  chain pre { type nat hook prerouting priority dstnat; policy accept;"
  [ "$MODE" = cone ] && echo "    iifname \"$out_if\" udp dport 47282-47297 dnat to $CLIENT"
  [ "$FORWARD" = on ] && echo "    iifname \"$out_if\" udp dport 47298-47314 dnat to $CLIENT"
  [ "$FORWARD" = stun ] && echo "    iifname \"$out_if\" udp dport 47298 dnat to $CLIENT"
  [ "$HAIRPIN" = on ] && echo "    iifname \"$LAN_IF\" ip daddr $wan_ip udp dport 47282-47314 dnat to $CLIENT"
  echo "  }"
  echo "  chain post { type nat hook postrouting priority srcnat; policy accept;"
  [ "$HAIRPIN" = on ] && echo "    iifname \"$LAN_IF\" oifname \"$LAN_IF\" masquerade"
  [ -n "$nat" ] && echo "    $nat"
  echo "  }"
  echo "}"
}
render() {
  ready
  local wan_ip="${WAN_CIDR%/*}" home_out="$WAN_IF" home_wan="${WAN_CIDR%/*}"
  nft list table ip routerlab >/dev/null 2>&1 && nft delete table ip routerlab
  ip netns list 2>/dev/null | grep -qw $HOME_NS && ip netns exec $HOME_NS nft list table ip routerlab >/dev/null 2>&1 && ip netns exec $HOME_NS nft delete table ip routerlab
  if [ "$DOUBLE" = on ]; then
    home_out=veth-home; home_wan=100.64.77.2
    # the carrier: a plain restricted NAT for the home router's 100.64.77.0/24, and nothing forwarded in
    printf 'table ip routerlab {\n  chain post { type nat hook postrouting priority srcnat; policy accept;\n    ip saddr 100.64.77.0/24 oifname "%s" masquerade\n  }\n}\n' "$WAN_IF" | nft -f -
  fi
  home_rules "$home_out" "$home_wan" | in_home nft -f -
  say "changed: nat $MODE, forward $FORWARD, hairpin $HAIRPIN, double $DOUBLE (WAN $wan_ip)"
}
double_on() {
  ip netns list 2>/dev/null | grep -qw $HOME_NS && { say "already: double NAT"; return; }
  ip netns add $HOME_NS
  ip link add veth-isp type veth peer name veth-home
  ip link set veth-home netns $HOME_NS
  ip addr add 100.64.77.1/24 dev veth-isp; ip link set veth-isp up
  ip link set "$LAN_IF" netns $HOME_NS
  ip netns exec $HOME_NS ip addr add 10.77.0.1/24 dev "$LAN_IF"
  ip netns exec $HOME_NS ip link set "$LAN_IF" up
  ip netns exec $HOME_NS ip link set lo up
  ip netns exec $HOME_NS ip addr add 100.64.77.2/24 dev veth-home
  ip netns exec $HOME_NS ip link set veth-home up
  ip netns exec $HOME_NS ip route add default via 100.64.77.1
  ip netns exec $HOME_NS sysctl -qw net.ipv4.ip_forward=1
  ip route replace 10.77.0.0/24 via 100.64.77.2
  say "changed: double NAT: the home router is namespace '$HOME_NS' (WAN 100.64.77.2), this one the carrier"
}
double_off() {
  ip netns list 2>/dev/null | grep -qw $HOME_NS || { say "already: no double NAT"; return; }
  ip route del 10.77.0.0/24 via 100.64.77.2 2>/dev/null
  ip netns exec $HOME_NS ip link set "$LAN_IF" netns 1
  ip link del veth-isp 2>/dev/null
  ip netns del $HOME_NS
  ip addr replace 10.77.0.1/24 dev "$LAN_IF"; ip link set "$LAN_IF" up
  say "changed: double NAT off"
}
cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    [ $# -ge 3 ] || { sed -n '5,6p' "$0"; exit 2; }
    WAN_IF="$1"; WAN_CIDR="$2"; LAN_IF="$3"; CLIENT="${4:-10.77.0.2}"
    ip addr replace "$WAN_CIDR" dev "$WAN_IF"; ip link set "$WAN_IF" up
    ip addr replace 10.77.0.1/24 dev "$LAN_IF"; ip link set "$LAN_IF" up
    sysctl -qw net.ipv4.ip_forward=1
    save; render;;
  mode) case "${1:-}" in open|restricted|symmetric|cone) MODE="$1"; save; render;; *) say "mode: open, restricted, symmetric or cone"; exit 2;; esac;;
  forward|hairpin)
    case "$cmd:${1:-}" in forward:on|forward:stun|forward:off|hairpin:on|hairpin:off) ;; *) say "forward on|stun|off, hairpin on|off"; exit 2;; esac
    [ "$cmd" = forward ] && FORWARD="$1" || HAIRPIN="$1"; save; render;;
  double)
    ready
    case "${1:-}" in on) double_on; DOUBLE=on;; off) double_off; DOUBLE=off;; *) say "double on|off"; exit 2;; esac
    save; render;;
  wanip)
    ready; [ -n "${1:-}" ] || { say "wanip NEW_CIDR"; exit 2; }
    ip addr del "$WAN_CIDR" dev "$WAN_IF" 2>/dev/null; ip addr replace "$1" dev "$WAN_IF"; WAN_CIDR="$1"; save; render
    command -v conntrack >/dev/null && conntrack -F 2>/dev/null; say "changed: WAN address now $1 (old mappings dropped where conntrack is installed)";;
  status)
    [ -f "$ST" ] && cat "$ST"; nft list table ip routerlab 2>/dev/null
    ip netns list 2>/dev/null | grep -qw $HOME_NS && { say "== home"; ip netns exec $HOME_NS nft list table ip routerlab 2>/dev/null; };;
  undo)
    [ "$DOUBLE" = on ] && [ -n "$LAN_IF" ] && double_off
    nft list table ip routerlab >/dev/null 2>&1 && { nft delete table ip routerlab; say "changed: nftables table routerlab deleted"; }
    rm -f "$ST"; say "undo done (addresses stay; forwarding stays on)";;
  *) sed -n '2,18p' "$0"; exit 2;;
esac
