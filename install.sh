#!/usr/bin/env bash
# airpods-macfeel — build and install LibrePods (macfeel branch) + librepods-popup
# for the current user. No root needed; the BlueZ part is system/setup-bluez.sh.
#
#   ./install.sh              build, install, (re)start the service
#   ./install.sh --no-build   reinstall what's already built
#   ./install.sh --no-start   don't touch the running service
#
# Environment: LIBREPODS_SRC=path  build another checkout of the fork
#              JOBS=N              cargo parallelism (default: all cores)
#              FORCE=1             build even when running on battery
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${LIBREPODS_SRC:-$HERE/librepods}"
FORK=https://github.com/B-Divyesh/librepods.git
BRANCH=macfeel
BIN="$HOME/.local/bin"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
JOBS="${JOBS:-$(nproc)}"
build=1 start=1
for a in "$@"; do
    case $a in
        --no-build) build=0 ;;
        --no-start) start=0 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done

say()  { printf '\033[1;38;5;215m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── source ──────────────────────────────────────────────────────────────────
if [[ ! -f $SRC/linux-rust/Cargo.toml ]]; then
    if [[ -e $HERE/.git && $SRC == "$HERE/librepods" ]]; then
        say "fetching the LibrePods fork (git submodule)"
        git -C "$HERE" submodule update --init --depth 1 librepods
    else
        say "cloning the LibrePods fork into $SRC"
        git clone --depth 1 --branch "$BRANCH" "$FORK" "$SRC"
    fi
fi
RS="$SRC/linux-rust"
[[ -f $RS/Cargo.toml ]] || die "no linux-rust/ in $SRC"

# ── build ───────────────────────────────────────────────────────────────────
if (( build )); then
    missing=()
    command -v cargo >/dev/null || missing+=("cargo/rustc (https://rustup.rs)")
    command -v pkg-config >/dev/null || missing+=(pkg-config)
    for pc in dbus-1 libpulse libavcodec libavformat libavutil libswresample; do
        pkg-config --exists "$pc" 2>/dev/null || missing+=("$pc (dev package)")
    done
    command -v clang >/dev/null || missing+=("clang/libclang")
    if (( ${#missing[@]} )); then
        warn "missing build dependencies:"; printf '      %s\n' "${missing[@]}"
        cat >&2 <<'EOF'
      Arch:          sudo pacman -S --needed rust clang pkgconf dbus libpulse ffmpeg
      Debian/Ubuntu: sudo apt install clang pkg-config libdbus-1-dev libpulse-dev \
                       libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev \
                       libavdevice-dev libswresample-dev libswscale-dev   (+ rustup)
      Fedora:        sudo dnf install clang pkgconf dbus-devel pulseaudio-libs-devel \
                       ffmpeg-free-devel   (+ rustup)
EOF
        exit 1
    fi
    rv=$(rustc --version | awk '{print $2}')
    if [[ $(printf '%s\n1.89.0\n' "$rv" | sort -V | head -1) != 1.89.0 ]]; then
        die "rustc $rv is too old (need ≥ 1.89) — install via rustup"
    fi

    for ac in /sys/class/power_supply/*/; do
        [[ $(cat "$ac/type" 2>/dev/null) == Mains ]] || continue
        if [[ $(cat "$ac/online" 2>/dev/null) == 0 && ${FORCE:-} != 1 ]]; then
            die "on battery — the Rust build is heavy. Plug in, or run with FORCE=1."
        fi
    done

    say "building librepods (release, $JOBS jobs — the first build takes a while)"
    ( cd "$RS" && cargo build --release --locked -j "$JOBS" )
    say "building librepods-popup"
    ( cd "$RS/popup" && cargo build --release --locked -j "$JOBS" )
fi

[[ -x $RS/target/release/librepods ]] || die "not built yet (run without --no-build)"

# ── install ─────────────────────────────────────────────────────────────────
say "installing into ~/.local"
install -Dm755 "$RS/target/release/librepods" "$BIN/librepods"
if [[ -x $RS/popup/target/release/librepods-popup ]]; then
    install -Dm755 "$RS/popup/target/release/librepods-popup" "$BIN/librepods-popup"
else
    warn "librepods-popup not built — you'll get plain notifications instead of the card"
fi
install -Dm755 "$HERE/scripts/airpods-repair" "$BIN/airpods-repair"
install -Dm644 "$RS/assets/icon.png" "$DATA/icons/hicolor/256x256/apps/me.kavishdevar.librepods.png"
# picture used in notifications
[[ -f $DATA/librepods/airpods.png ]] || install -Dm644 "$RS/assets/devices/pro2_case.png" "$DATA/librepods/airpods.png"
mkdir -p "$DATA/applications" "$CONF/systemd/user"
sed "s|@BIN@|$BIN|g" "$HERE/config/applications/me.kavishdevar.librepods.desktop" \
    > "$DATA/applications/me.kavishdevar.librepods.desktop"
sed "s|@BIN@|$BIN|g" "$HERE/config/systemd/librepods.service" > "$CONF/systemd/user/librepods.service"

# WirePlumber: stem presses → media keys (takes effect after the next login)
wp="$CONF/wireplumber/wireplumber.conf.d/51-airpods.conf"
[[ -f $wp ]] || install -Dm644 "$HERE/config/wireplumber/51-airpods.conf" "$wp"

systemctl --user daemon-reload

# ── start ───────────────────────────────────────────────────────────────────
if (( start )); then
    if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
        vars=(WAYLAND_DISPLAY XDG_CURRENT_DESKTOP)
        [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && vars+=(HYPRLAND_INSTANCE_SIGNATURE)
        [[ -n ${SWAYSOCK:-} ]] && vars+=(SWAYSOCK)
        systemctl --user import-environment "${vars[@]}"
        systemctl --user restart librepods.service
        say "librepods.service restarted"
    else
        warn "not in a Wayland session — start it from your compositor (see README → Autostart)"
    fi
fi
pkill -SIGUSR2 -x waybar 2>/dev/null || true

say "installed $("$BIN/librepods" --version 2>/dev/null || echo librepods)"
cat <<EOF

  Next:
    1. BlueZ (once, as root):   sudo ./system/setup-bluez.sh
    2. Autostart + keybinds:    config/hyprland/  or  config/sway/
    3. Waybar module:           config/waybar/airpods.jsonc + airpods.css
    4. iPhone handoff:          README → "Switching between iPhone and this computer"
    5. Dual boot with Windows?  sudo ./system/dualboot/install.sh

  Try:  librepods ctl status   ·   librepods ctl open
EOF
case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN is not in your PATH" ;; esac
