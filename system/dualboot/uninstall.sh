#!/usr/bin/env bash
# Remove the dual-boot key sync.   sudo ./system/dualboot/uninstall.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
systemctl disable bt-dualboot-sync.service 2>/dev/null || true
rm -f /etc/systemd/system/bt-dualboot-sync.service /etc/bt-dualboot-sync.conf
rm -rf /usr/local/lib/airpods-macfeel /var/lib/bt-dualboot-sync
systemctl daemon-reload
echo "removed bt-dualboot-sync (BlueZ pairings are untouched)"
