#!/usr/bin/env bash
# Remove what install.sh put in your home directory.
#   ./uninstall.sh           keep settings and paired-device keys
#   ./uninstall.sh --purge   also delete ~/.config/librepods and ~/.local/share/librepods
# Root parts: sudo ./system/setup-bluez.sh --revert, sudo ./system/dualboot/uninstall.sh
set -euo pipefail
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

systemctl --user disable --now librepods.service 2>/dev/null || true
rm -f "$HOME/.local/bin/librepods" "$HOME/.local/bin/librepods-popup" "$HOME/.local/bin/airpods-repair" \
      "$CONF/systemd/user/librepods.service" \
      "$DATA/applications/me.kavishdevar.librepods.desktop" \
      "$DATA/icons/hicolor/256x256/apps/me.kavishdevar.librepods.png"
systemctl --user daemon-reload
if [[ ${1:-} == --purge ]]; then
    rm -rf "$CONF/librepods" "$DATA/librepods"
    rm -f "$CONF/wireplumber/wireplumber.conf.d/51-airpods.conf"
fi
echo "LibrePods removed. Remove the Waybar/compositor snippets you added by hand."
