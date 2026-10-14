#!/usr/bin/env bash
# Install the dual-boot key sync (only useful if you also run Windows on this machine).
#   sudo ./system/dualboot/install.sh [--part /dev/nvme0n1p3]
#
# Pair the AirPods in Linux at least once first. The service then runs before
# bluetoothd on every boot, and when Windows has re-paired a device since the
# last boot it copies Windows' new link key into BlueZ. Needs python3 (a venv
# with regipy is created) and the ntfs3 kernel driver or ntfs-3g. BitLocker-
# encrypted Windows partitions can't be read.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=/usr/local/lib/airpods-macfeel
CONF=/etc/bt-dualboot-sync.conf

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0 $*" >&2; exit 1; }

part=
[[ ${1:-} == --part ]] && part=${2:?--part needs a device}

if [[ -z $part ]]; then
    mnt=$(mktemp -d /run/bt-dualboot-probe.XXXXXX)
    for dev in $(lsblk -rpno PATH,FSTYPE | awk '$2 == "ntfs" {print $1}'); do
        if mount -t ntfs3 -o ro "$dev" "$mnt" 2>/dev/null || mount -t ntfs-3g -o ro "$dev" "$mnt" 2>/dev/null; then
            [[ -f $mnt/Windows/System32/config/SYSTEM ]] && part=$dev
            umount "$mnt"
            [[ -n $part ]] && break
        fi
    done
    rmdir "$mnt"
fi
[[ -n $part ]] || { echo "no readable Windows partition found (BitLocker? pass --part DEVICE)" >&2; exit 1; }
uuid=$(lsblk -no UUID "$part" | head -1)
ref=${uuid:+/dev/disk/by-uuid/$uuid}
ref=${ref:-$part}
echo "Windows partition: $part → $ref"

install -d -m 755 "$LIB"
install -m 755 "$HERE/bt-dualboot-sync.sh" "$LIB/bt-dualboot-sync.sh"
install -m 644 "$HERE/bt-dualboot-sync.py" "$LIB/bt-dualboot-sync.py"
[[ -x $LIB/venv/bin/python ]] || python3 -m venv "$LIB/venv"
"$LIB/venv/bin/pip" install -q --disable-pip-version-check regipy
printf '# written by airpods-macfeel system/dualboot/install.sh\nWINDOWS_PART=%s\n' "$ref" > "$CONF"
install -m 644 "$HERE/bt-dualboot-sync.service" /etc/systemd/system/bt-dualboot-sync.service
systemctl daemon-reload
systemctl enable bt-dualboot-sync.service

# Remember Windows' current (possibly stale) keys, so the pairing you have in
# Linux right now is kept. From now on only a *new* Windows pairing is imported.
echo "-- seeding with the keys Windows has now"
"$LIB/bt-dualboot-sync.sh" --seed
echo "done. Status after a reboot: journalctl -b -u bt-dualboot-sync"
