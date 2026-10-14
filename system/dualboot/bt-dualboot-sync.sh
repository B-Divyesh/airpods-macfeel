#!/bin/bash
# Runs before bluetoothd (bt-dualboot-sync.service). If Windows re-paired a
# Bluetooth device since the last boot, import its new link key into BlueZ so
# the device keeps working in both OSes. Windows is only ever mounted read-only.
#   bt-dualboot-sync.sh            import keys Windows changed (what the service runs)
#   bt-dualboot-sync.sh --seed     remember Windows' current keys, import nothing
#   bt-dualboot-sync.sh --dry-run  show what would happen
set -u
LIB=/usr/local/lib/airpods-macfeel
STATE=/var/lib/bt-dualboot-sync
WINDOWS_PART=     # set in /etc/bt-dualboot-sync.conf by the installer; empty = search
[ -r /etc/bt-dualboot-sync.conf ] && . /etc/bt-dualboot-sync.conf

MODE=--apply
case "${1:-}" in
    --seed) MODE=--seed ;;
    --dry-run) MODE= ;;
esac

MNT=$(mktemp -d /run/bt-dualboot.XXXXXX)
WORK=$(mktemp -d /run/bt-dualboot-hive.XXXXXX)
trap 'umount -q "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; rm -rf "$WORK"' EXIT

mount_ro() {
    mount -t ntfs3 -o ro,noatime "$1" "$MNT" 2>/dev/null || mount -t ntfs-3g -o ro "$1" "$MNT" 2>/dev/null
}
system_hive() {
    local p
    for p in Windows/System32/config/SYSTEM WINDOWS/system32/config/SYSTEM; do
        [ -f "$MNT/$p" ] && { echo "$MNT/$p"; return 0; }
    done
    return 1
}

if [ -n "$WINDOWS_PART" ]; then
    [ -e "$WINDOWS_PART" ] || { echo "$WINDOWS_PART not present, skipping"; exit 0; }
    mount_ro "$WINDOWS_PART" || { echo "cannot mount $WINDOWS_PART read-only, skipping"; exit 0; }
    SYS=$(system_hive) || { echo "no SYSTEM hive on $WINDOWS_PART"; exit 0; }
else
    SYS=
    for dev in $(lsblk -rpno PATH,FSTYPE | awk '$2 == "ntfs" {print $1}'); do
        mount_ro "$dev" || continue
        SYS=$(system_hive) && { echo "Windows found on $dev"; break; }
        umount -q "$MNT"
    done
    [ -n "$SYS" ] || { echo "no Windows installation found, skipping"; exit 0; }
fi

# Windows only rewrites its hive (or its logs) when it runs; skip the parse otherwise.
mkdir -p "$STATE"
STAMP="$(stat -c '%Y %s' "$SYS" "$SYS.LOG1" "$SYS.LOG2" 2>/dev/null | tr '\n' ' ')"
if [ "$MODE" = --apply ] && [ "$(cat "$STATE/hive.stamp" 2>/dev/null)" = "$STAMP" ]; then
    echo "Windows has not run since the last check"; exit 0
fi
cp "$SYS" "$WORK/SYSTEM"
for l in LOG1 LOG2; do [ -f "$SYS.$l" ] && cp "$SYS.$l" "$WORK/SYSTEM.$l"; done
umount "$MNT"
"$LIB/venv/bin/python" "$LIB/bt-dualboot-sync.py" --hive "$WORK/SYSTEM" \
    --log1 "$WORK/SYSTEM.LOG1" --log2 "$WORK/SYSTEM.LOG2" --state "$STATE/state.json" $MODE \
    && [ -n "$MODE" ] && echo "$STAMP" > "$STATE/hive.stamp"
exit 0
