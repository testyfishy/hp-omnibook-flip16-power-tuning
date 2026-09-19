#!/bin/bash
# Restore the pre-step58 power-switch config + script (latest backup) and re-apply.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "Run with: sudo bash $0" >&2; exit 1; }
B=$(ls -d $(dirname "$0")/backup/step58-* | tail -1); echo "restoring from $B"
cp -a "$B/power-switch.conf" /etc/power-switch.conf; cp -a "$B/power-switch.sh" /usr/local/sbin/power-switch.sh
/usr/local/sbin/power-switch.sh; journalctl -t power-switch -n 1 --no-pager -o cat
