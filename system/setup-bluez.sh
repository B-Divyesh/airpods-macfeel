#!/usr/bin/env bash
# BlueZ settings for AirPods. Safe to re-run.
#   sudo ./system/setup-bluez.sh              recommended: plain Bluetooth host
#   sudo ./system/setup-bluez.sh --apple-id   also pose as an Apple device (see below)
#   sudo ./system/setup-bluez.sh --revert     restore the main.conf from before the first run
#
# /etc/bluetooth/main.conf [General]:
#   FastConnectable = true   AirPods page this machine faster
#   Experimental = true      exposes BlueZ's AdvertisementMonitor API, which
#                            LibrePods uses to see the case lid, ear state and
#                            battery from the AirPods' broadcasts
#   DeviceID = bluetooth:004C:0000:0000   (--apple-id only) report Apple's vendor
#                            ID. Older AirPods firmware then unlocks multipoint and
#                            Apple-only settings; firmware 9A348 (Sept 2026) and
#                            later drops such hosts after ~40 s and can forget the
#                            pairing. Without it, this computer is a plain host:
#                            stable pairing, and LibrePods' handoff does the
#                            switching. Running without --apple-id removes it.
# Backups (main.conf and /var/lib/bluetooth) go to /var/backups/airpods-macfeel/.
set -euo pipefail

CONF=/etc/bluetooth/main.conf
BACKUP=/var/backups/airpods-macfeel
APPLE_ID=bluetooth:004C:0000:0000

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0 $*" >&2; exit 1; }

restart_bluetooth() {
    systemctl restart bluetooth
    sleep 3
    local modalias
    modalias=$(bluetoothctl show 2>/dev/null | awk '/Modalias/ {print $2; exit}')
    echo "adapter modalias: ${modalias:-unknown}"
    if busctl introspect org.bluez /org/bluez/hci0 2>/dev/null | grep -q AdvertisementMonitorManager1; then
        echo "AdvertisementMonitorManager1: available"
    else
        echo "AdvertisementMonitorManager1: missing (case-lid detection won't work)"
    fi
}

mode=plain
case "${1:-}" in
    --apple-id) mode=apple ;;
    --revert)
        first=$(ls -1 "$BACKUP"/main.conf.* 2>/dev/null | sort | head -1)
        [[ -n $first ]] || { echo "no backup in $BACKUP" >&2; exit 1; }
        cp -a "$first" "$CONF"
        echo "restored $CONF from $first"
        restart_bluetooth
        exit 0 ;;
    "") ;;
    *) echo "usage: $0 [--apple-id | --revert]" >&2; exit 1 ;;
esac

ts=$(date +%Y%m%d-%H%M%S)
install -d -m 700 "$BACKUP"
if [[ -f $CONF ]]; then
    cp -a "$CONF" "$BACKUP/main.conf.$ts"
else
    install -D -m 644 /dev/null "$CONF"
fi
[[ -d /var/lib/bluetooth ]] && cp -a /var/lib/bluetooth "$BACKUP/var-lib-bluetooth.$ts"
echo "backup: $BACKUP (*.$ts)"

grep -q '^\[General\]' "$CONF" || sed -i '1i [General]' "$CONF"
[[ -s $CONF ]] || echo '[General]' > "$CONF"   # sed '1i' does nothing on an empty file

in_general() { sed -n '/^\[General\]/,/^\[/p' "$CONF"; }
set_general() {  # key value — only touches the [General] section
    local key=$1 val=$2
    if in_general | grep -qE "^[[:space:]]*$key[[:space:]]*="; then
        sed -i -E "/^\[General\]/,/^\[/ s|^[[:space:]]*$key[[:space:]]*=.*|$key = $val|" "$CONF"
    else
        sed -i "0,/^\[General\]/ s|^\[General\]|&\n$key = $val|" "$CONF"
    fi
    echo "main.conf: $key = $val"
}
set_general FastConnectable true
set_general Experimental true
if [[ $mode == apple ]]; then
    set_general DeviceID "$APPLE_ID"
elif in_general | grep -qiE "^[[:space:]]*DeviceID[[:space:]]*=[[:space:]]*$APPLE_ID"; then
    # only our own Apple override; a DeviceID someone else set stays
    sed -i -E "/^\[General\]/,/^\[/ { /^[[:space:]]*DeviceID[[:space:]]*=[[:space:]]*bluetooth:004[Cc]:0000:0000/d }" "$CONF"
    echo "main.conf: DeviceID override removed (plain Bluetooth host)"
fi

restart_bluetooth
echo "done ($mode). Reconnect the AirPods; if they refuse, LibrePods offers to pair them again."
