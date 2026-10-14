#!/usr/bin/env python3
"""Copy Bluetooth Classic link keys from a Windows SYSTEM hive into BlueZ.

Dual-booting with one Bluetooth adapter means Windows and Linux each pair the
AirPods separately, and the AirPods only remember the most recent key for the
adapter's address. Whichever OS paired last wins; the other gets
"br-connection-key-missing". Importing Windows' key into BlueZ makes both work.

Usage (as root):
  bt-dualboot-sync.py --hive SYSTEM [--log1 SYSTEM.LOG1 --log2 SYSTEM.LOG2]
                      [--adapter MAC] [--device MAC ...] [--apply]
Without --adapter every adapter under /var/lib/bluetooth is considered.
Without --device every device paired on both sides is considered.
Without --apply nothing is written (dry run).
--log1/--log2: Windows 10/11 keeps recent registry writes (a fresh pairing)
in the hive's transaction logs; they are replayed onto a copy first.
With --state FILE a key is only imported when Windows' key changed since the
last run (i.e. Windows re-paired), so a newer Linux pairing is never clobbered
by a stale Windows key. --seed records the current Windows keys without importing.
Keys are never printed, only their first two bytes.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile

from regipy.registry import RegistryHive

MAC_RE = re.compile(r"(?:[0-9A-F]{2}:){5}[0-9A-F]{2}")


def norm(mac):
    return mac.replace(":", "").lower()


def colon(mac12):
    return ":".join(mac12[i:i + 2] for i in range(0, 12, 2)).upper()


def open_hive(path, log1=None, log2=None):
    """The hive with its transaction logs replayed, when there are any."""
    logs = [p for p in (log1, log2) if p and os.path.exists(p) and os.path.getsize(p) > 0]
    if logs:
        try:
            from regipy.recovery import apply_transaction_logs

            out = tempfile.NamedTemporaryFile(prefix="bt-hive-", delete=False).name
            restored, pages = apply_transaction_logs(path, logs[0], logs[1] if len(logs) > 1 else None, out)
            print(f"windows: replayed {pages} dirty page(s) from the transaction logs")
            return RegistryHive(restored)
        except Exception as e:  # a damaged log must not stop the sync
            print(f"windows: transaction logs not applied ({e}); using the hive as is")
    return RegistryHive(path)


def windows_keys(hive, adapter):
    current = 1
    try:
        for v in hive.get_key("\\Select").iter_values():
            if v.name == "Current":
                current = int(v.value)
    except Exception:
        pass
    path = f"\\ControlSet{current:03d}\\Services\\BTHPORT\\Parameters\\Keys\\{norm(adapter)}"
    try:
        key = hive.get_key(path)
    except Exception:
        return path, {}
    keys = {}
    for v in key.iter_values():
        if re.fullmatch(r"[0-9a-f]{12}", v.name.lower()) and v.value:
            raw = v.value if isinstance(v.value, bytes) else bytes.fromhex(str(v.value))
            if len(raw) == 16:
                keys[colon(v.name.lower())] = raw.hex().upper()
    return path, keys


def read_linux_key(info_path):
    section = None
    with open(info_path) as f:
        for line in f:
            s = line.strip()
            if s.startswith("["):
                section = s
            elif section == "[LinkKey]" and s.startswith("Key="):
                return s[4:]
    return None


def write_linux_key(info_path, new_key):
    with open(info_path) as f:
        lines = f.readlines()
    section = None
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("["):
            section = s
        elif section == "[LinkKey]" and s.startswith("Key="):
            lines[i] = f"Key={new_key}\n"
            break
    else:
        raise RuntimeError("no [LinkKey] Key= line")
    tmp = info_path + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(lines)
    os.chmod(tmp, 0o600)
    os.replace(tmp, info_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hive", required=True)
    ap.add_argument("--log1")
    ap.add_argument("--log2")
    ap.add_argument("--adapter", action="append", default=[])
    ap.add_argument("--device", action="append", default=[])
    ap.add_argument("--bluez", default="/var/lib/bluetooth")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--state")
    ap.add_argument("--seed", action="store_true")
    a = ap.parse_args()

    state = {}
    if a.state and os.path.exists(a.state):
        with open(a.state) as f:
            state = json.load(f)
    digest = lambda k: hashlib.sha256(k.encode()).hexdigest()
    tag = lambda k: f"{k[:4]}…" if k else "none"

    adapters = [x.upper() for x in a.adapter]
    if not adapters and os.path.isdir(a.bluez):
        adapters = sorted(d for d in os.listdir(a.bluez) if MAC_RE.fullmatch(d))
    if not adapters:
        print(f"no Bluetooth adapters under {a.bluez}")
        return 0

    hive = open_hive(a.hive, a.log1, a.log2)
    changed = 0
    for adapter in adapters:
        path, win = windows_keys(hive, adapter)
        print(f"adapter {adapter}: windows {path}: {len(win)} classic key(s)")
        wanted = {d.upper() for d in a.device} or set(win)
        for mac in sorted(wanted):
            info = os.path.join(a.bluez, adapter, mac, "info")
            wk = win.get(mac)
            lk = read_linux_key(info) if os.path.exists(info) else None
            # state is keyed by device address (one adapter per machine is the norm)
            if a.state and wk:
                seen = state.get(mac)
                state[mac] = digest(wk)
                if a.seed:
                    print(f"  {mac}: recorded Windows key {tag(wk)} (seed)")
                    continue
                if seen == digest(wk):
                    print(f"  {mac}: Windows key unchanged since last boot -> leave Linux key")
                    continue
            if not wk:
                print(f"  {mac}: not paired in Windows (linux key {tag(lk)}) -> leave")
            elif not lk:
                print(f"  {mac}: paired in Windows but not in BlueZ -> pair once in Linux first")
            elif wk == lk:
                print(f"  {mac}: keys already match ({tag(lk)})")
            else:
                print(f"  {mac}: windows {tag(wk)} != linux {tag(lk)} -> "
                      f"{'importing Windows key' if a.apply else 'would import (dry run)'}")
                if a.apply:
                    write_linux_key(info, wk)
                    changed += 1
    if a.state and (a.apply or a.seed):
        os.makedirs(os.path.dirname(a.state) or ".", exist_ok=True)
        with open(a.state, "w") as f:
            json.dump(state, f)
        os.chmod(a.state, 0o600)
    print(f"changed={changed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
