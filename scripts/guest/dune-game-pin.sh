#!/usr/bin/env bash
# Keep Dune map-server containers on guest NUMA node 0 CPUs (rubberbanding, meta#99 / fork#1352).
# Pins at start-up and again on every container start (05:00 restart, dynamic maps).
# Undo: systemctl disable --now dune-game-pin; docker update --cpuset-cpus 0-59 <container>
set -u
CPUSET="${DUNE_PIN_CPUSET:-0-39}"
pin() {
  case "$1" in
    dune-server-gateway) return 0 ;;
    dune-server-*) docker update --cpuset-cpus "$CPUSET" "$1" >/dev/null 2>&1 && echo "pinned $1 to $CPUSET" ;;
  esac
}
for c in $(docker ps --format "{{.Names}}"); do pin "$c"; done
docker events --filter type=container --filter event=start --format "{{.Actor.Attributes.name}}" |
  while read -r name; do pin "$name"; done
