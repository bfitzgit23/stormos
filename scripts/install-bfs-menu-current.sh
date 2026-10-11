#!/usr/bin/env bash
# Revision: r77-0.9.0-release-hardening
# r75: preflight BIOS+GPT GRUB validation - require a BIOS Boot partition before installation starts
# r73: tracker source fixes - root ownership postflight, serial/LUKS console order, safe GRUB alias handling
# r71: deterministic equal /home + /var LVM split from one initial free-extent snapshot
# r70: GLib two-pass footprint lifecycle + early integrity setting propagation + r69 fixes
# r69: destructive-format checkpoint invalidation + r68 fixes
# r68: GLib/GObject-Introspection two-pass package preflight + r67 fixes
# r67: secure-default package integrity toggles (MD5/signatures/footprints) + r66 fixes
# r66: exact selected-kernel finalization/source-link policy + low-RAM tmpfs auto-disable
# r64: package dependency fixes - pciutils baseline and new-dependency preflight before sysup
# r60: deterministic MD reset discovery - snapshot active arrays before reset and explicitly preserve array-level signature candidates
# r59: storage-reset signature fix - preserve active MD arrays while selecting array-level LUKS/LVM/filesystem signatures for destruction
# r58: generic MD personality detection - Linear/JBOD and RAID arrays are handled consistently across storage selectors/reset/recovery/boot discovery
# r54: runtime regression fixes - status colors, MD/LUKS dedup, account validation/review, theme persistence, failure status
# r52: recovery UX ordering and completed-install state handling.
# BFSOS installer r43 - tracker consolidation / Dracut RAID / resume fixes
set -Eeuo pipefail


# The live environment may advertise a UTF-8 locale that is not generated
# inside the installer or target chroot. Use the guaranteed POSIX locale for
# installer execution while keeping BFS_LOCALE as the locale selected for the
# installed system.
force_posix_locale() {
        unset LC_ALL
        unset LC_ADDRESS
        unset LC_COLLATE
        unset LC_CTYPE
        unset LC_IDENTIFICATION
        unset LC_MEASUREMENT
        unset LC_MESSAGES
        unset LC_MONETARY
        unset LC_NAME
        unset LC_NUMERIC
        unset LC_PAPER
        unset LC_TELEPHONE
        unset LC_TIME

        export LANG=C
        export LC_ALL=C
        export LANGUAGE=C
}

force_posix_locale

# Synchronize the live environment clock before logs, archive extraction, or
# package builds. Prefer chrony (used by Gentoo LiveGUI), then systemd's time
# synchronization, followed by classic ntpd/ntpdate fallbacks. Failure is
# non-fatal so the installer can still be used in an offline environment.
sync_system_clock() {
        local synced=no
        local i=0

        [[ "${BFS_TIME_SYNC:-yes}" == yes ]] || {
                printf 'Automatic time synchronization disabled (BFS_TIME_SYNC=%s).\n' \
                        "${BFS_TIME_SYNC:-no}"
                return 0
        }

        printf '\nSynchronizing system clock...\n'

        if command -v chronyd >/dev/null 2>&1; then
                if chronyd -q; then
                        synced=yes
                        printf 'System clock synchronized with chronyd.\n'
                fi
        fi

        if [[ "$synced" != yes ]] &&
           command -v timedatectl >/dev/null 2>&1 &&
           [[ -d /run/systemd/system ]]; then
                if timedatectl set-ntp true >/dev/null 2>&1; then
                        for ((i=0; i<15; i++)); do
                                if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then
                                        synced=yes
                                        printf 'System clock synchronized with systemd time synchronization.\n'
                                        break
                                fi
                                sleep 1
                        done
                fi
        fi

        if [[ "$synced" != yes ]] && command -v ntpd >/dev/null 2>&1; then
                if ntpd -q -g; then
                        synced=yes
                        printf 'System clock synchronized with ntpd.\n'
                fi
        fi

        if [[ "$synced" != yes ]] && command -v ntpdate >/dev/null 2>&1; then
                if ntpdate -u pool.ntp.org; then
                        synced=yes
                        printf 'System clock synchronized with ntpdate.\n'
                fi
        fi

        if [[ "$synced" != yes ]]; then
                printf 'WARNING: Automatic time synchronization was unavailable or failed.\n' >&2
                printf 'WARNING: Verify the clock before building packages: %s\n' "$(date)" >&2
        fi

        return 0
}

# BFSOS installer - v50 tracker fixes r42 (console-font persistence + RC validation)
#
# Assumptions:
#   - Run from a Linux live environment as root.
#   - Partitions already exist; this script can optionally format them.
#   - A completed BFS rootfs archive is available.
#
# The installer resets /mnt/bfs, presents available partitions while each
# filesystem role is selected, optionally formats selected partitions, mounts
# the target layout, extracts BFS, configures the system, and installs GRUB.

TARGET="${BFS_TARGET:-/mnt/bfs}"
ARCHIVE="${BFS_ARCHIVE:-}"
ROOT_DEV="${BFS_ROOT_DEV:-}"
BOOT_DEV="${BFS_BOOT_DEV:-}"
EFI_DEV="${BFS_EFI_DEV:-}"
SWAP_DEV="${BFS_SWAP_DEV:-}"
HOME_DEV="${BFS_HOME_DEV:-}"
HOSTNAME="${BFS_HOSTNAME:-bfs}"
TIMEZONE="${BFS_TIMEZONE:-America/New_York}"
LOCALE="${BFS_LOCALE:-en_US.UTF-8}"
USERNAME="${BFS_USERNAME:-}"
ADDITIONAL_USERS=()
ADDITIONAL_USER_TYPES=()
ADDITIONAL_USER_GROUPS=()
STANDARD_USER_GROUPS="users,wheel,audio,video,optical,cdrom,plugdev,storage,input,render"
ROOT_PASSWORD_POLICY="${BFS_ROOT_PASSWORD_POLICY:-locked}"  # locked (default) or prompt during install
SSH_CONFIGURED=yes
BOOT_MODE="${BFS_BOOT_MODE:-}"
BOOT_DISK="${BFS_BOOT_DISK:-}"
NETWORK_IFACE="${BFS_NETWORK_IFACE:-}"
NETWORK_MAC="${BFS_NETWORK_MAC:-}"
NETWORK_TARGET_NAME="${BFS_NETWORK_TARGET_NAME:-eth0}"

ROOT_FORMAT="keep"
BOOT_FORMAT="keep"
EFI_FORMAT="keep"
SWAP_FORMAT="keep"
HOME_FORMAT="keep"

KERNEL_PACKAGE="${BFS_KERNEL_PACKAGE:-linux-lts}"
INSTALL_GRUB="${BFS_INSTALL_GRUB:-yes}"
SAVE_BASE_ARCHIVE="${BFS_SAVE_BASE_ARCHIVE:-yes}"
BASE_ARCHIVE_DIR="${BFS_BASE_ARCHIVE_DIR:-/var/cache/bfs/archives/base}"
ENABLE_OPENSSH="${BFS_ENABLE_OPENSSH:-${BFS_INSTALL_OPENSSH:-yes}}"
INSTALL_GIT="${BFS_INSTALL_GIT:-yes}"
INSTALL_SUDO="${BFS_INSTALL_SUDO:-yes}"
SUDO_MODE="${BFS_SUDO_MODE:-password}"  # default: authenticate with invoking user password
INSTALL_WGET="${BFS_INSTALL_WGET:-yes}"
INSTALL_WPA_SUPPLICANT="${BFS_INSTALL_WPA_SUPPLICANT:-no}"
INSTALL_WIRELESS_TOOLS="${BFS_INSTALL_WIRELESS_TOOLS:-no}"
INSTALL_GPM="${BFS_INSTALL_GPM:-no}"
INSTALL_LYNX="${BFS_INSTALL_LYNX:-no}"
INSTALL_LINKS="${BFS_INSTALL_LINKS:-no}"
INSTALL_NETWORKMANAGER="${BFS_INSTALL_NETWORKMANAGER:-no}"
# cryptsetup is installer-managed. It is installed automatically when the
# final selected storage topology contains a LUKS/crypt layer.
INSTALL_CRYPTSETUP=no
AUTO_CRYPTSETUP=no
AUTO_LVM2=no
AUTO_MDADM=no
KEEP_MOUNTS="${BFS_KEEP_MOUNTS:-no}"
FINAL_CHROOT="${BFS_FINAL_CHROOT:-no}"
GRUB_FALLBACK="${BFS_GRUB_FALLBACK:-no}"
ZRAM_SWAP="${BFS_ZRAM_SWAP:-no}"
ZRAM_SIZE_SPEC="${BFS_ZRAM_SIZE_SPEC:-200%}"
BUILD_JOBS="${BFS_BUILD_JOBS:-inherited}"
BUILD_OPT="${BFS_BUILD_OPT:-inherited}"
BUILD_CCACHE="${BFS_CCACHE:-inherited}"
BUILD_CCACHE_SIZE="${BFS_CCACHE_SIZE:-inherited}"
BUILD_TMPFS="${BFS_BUILD_TMPFS:-yes}"
BUILD_TMPFS_SIZE="${BFS_BUILD_TMPFS_SIZE:-auto}"
VERIFY_MD5="${BFS_VERIFY_MD5:-yes}"
VERIFY_SIGNATURE="${BFS_VERIFY_SIGNATURE:-yes}"
VERIFY_FOOTPRINT="${BFS_VERIFY_FOOTPRINT:-yes}"
CONSOLE_VIDEO_MODE="${BFS_CONSOLE_VIDEO_MODE:-1920x1080@60}"
CONSOLE_VIDEO_ARG=""
SERIAL_CONSOLE="${BFS_SERIAL_CONSOLE:-no}"
CLEAR_PACKAGE_CACHE="${BFS_CLEAR_PACKAGE_CACHE:-ask}"

DISKS_CONFIGURED=no
ARCHIVE_CONFIGURED=no
SYSTEM_CONFIGURED=no
BASIC_SYSTEM_CONFIGURED=no
USERS_CONFIGURED=no
KERNEL_CONFIGURED=no
NETWORK_CONFIGURED=no
PACKAGES_CONFIGURED=optional
SUDO_CONFIGURED=default
BOOTLOADER_CONFIGURED=no
PARTITIONING_VISITED=optional

# Whole disks whose partition tables were actually changed during this installer session.
declare -A PARTITION_DISKS_MODIFIED=()

LOG_ENABLED="${BFS_LOG_ENABLED:-yes}"
LOG_FILE="${BFS_LOG_FILE:-}"
LOG_FIFO=""
LOG_TEE_PID=""
LOG_STDOUT_FD=3
LOG_STDERR_FD=4

MOUNTED_BY_SCRIPT=()
OPENED_LUKS_BY_SCRIPT=()
ACTIVATED_VGS_BY_SCRIPT=()
CREATED_MD_ARRAYS_BY_SCRIPT=()
USED_DEVICES=()
EXTRA_DEVICES=()
EXTRA_MOUNTPOINTS=()
EXTRA_FORMATS=()
STORAGE_DEVICES=()
STORAGE_FORMATS=()
STORAGE_MOUNTPOINTS=()
BTRFS_DEVICES=()
BTRFS_MOUNTPOINTS=()
BTRFS_SUBVOLUMES=()
BTRFS_SNAPSHOT_SUBVOLUMES=()
BTRFS_CONFIG_NAMES=()
STORAGE_SUBVOLUMES=()

# Non-secret topology required to reconstruct a failed installation after the
# installer process has exited. Passphrases are never persisted.
RECOVERY_MD_ARRAYS=()
RECOVERY_MD_MEMBERS=()
RECOVERY_MD_UUIDS=()
RECOVERY_LUKS_DEVICES=()
RECOVERY_LUKS_MAPPINGS=()
RECOVERY_VGS=()
PROFILE_RECOVERY_MODE=no
RESUME_STATE_PRESENT=no
INSTALLATION_ALREADY_COMPLETE=no
SESSION_FAILURE_STATUS=0
AVAILABLE_PATHS=()
AVAILABLE_TYPES=()
AVAILABLE_SIZES=()
AVAILABLE_FSTYPES=()
AVAILABLE_LABELS=()
AVAILABLE_MOUNTPOINTS=()
AVAILABLE_NICS=()
AVAILABLE_NIC_MACS=()
AVAILABLE_NIC_STATES=()
AVAILABLE_NIC_DRIVERS=()
CHROOT_INSTALLER="/root/.bfs-install-chroot.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep installer logs beside the bootstrap logs, even when this script is
# stored in BFSOS/scripts/.
if [[ "$(basename "$SCRIPT_DIR")" == scripts ]]; then
        PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
        PROJECT_DIR="$SCRIPT_DIR"
fi

INSTALLER_LOG_DIR="$PROJECT_DIR/logs/installer"
INSTALLER_SETTINGS_FILE="$SCRIPT_DIR/.bfs-installer-settings"
INSTALLER_PROFILE_FILE="${BFS_INSTALLER_PROFILE:-$SCRIPT_DIR/bfs-installer-profile.conf}"
INSTALLER_RESUME_FILE="${BFS_INSTALLER_RESUME_FILE:-$SCRIPT_DIR/.bfs-installer-resume.conf}"
LOG_STARTED_EPOCH=""
LOG_CLOSED=no

mkdir -p "$INSTALLER_LOG_DIR"
DIALOGRC_FILE=""
ORIGINAL_DIALOGRC="${DIALOGRC-}"
BFS_THEME="${BFS_INSTALLER_THEME:-slackware}"
CONSOLE_FONT_PREFERENCE="default"
CONSOLE_FONT_SIZE="default"
CONSOLE_FONT_OVERRIDE="${BFS_CONSOLE_FONT:-}"
INSTALL_CONSOLE_FONT="${BFS_INSTALL_CONSOLE_FONT:-no}"
SELECTED_MENU_CHOICE=""
INSTALL_CONFIRMED=no

load_installer_settings() {
        [[ -f "$INSTALLER_SETTINGS_FILE" ]] || return 0

        while IFS='=' read -r key value; do
                case "$key" in
                        BFS_THEME) BFS_THEME="$value" ;;
                        CONSOLE_FONT_PREFERENCE) CONSOLE_FONT_PREFERENCE="$value" ;;
                        INSTALL_CONSOLE_FONT) INSTALL_CONSOLE_FONT="$value" ;;
                        LOG_ENABLED) LOG_ENABLED="$value" ;;
                        BUILD_JOBS) BUILD_JOBS="$value" ;;
                        BUILD_OPT) BUILD_OPT="$value" ;;
                        BUILD_CCACHE) BUILD_CCACHE="$value" ;;
                        BUILD_CCACHE_SIZE) BUILD_CCACHE_SIZE="$value" ;;
                        BUILD_TMPFS) BUILD_TMPFS="$value" ;;
                        BUILD_TMPFS_SIZE) BUILD_TMPFS_SIZE="$value" ;;
                        VERIFY_MD5) VERIFY_MD5="$value" ;;
                        VERIFY_SIGNATURE) VERIFY_SIGNATURE="$value" ;;
                        VERIFY_FOOTPRINT) VERIFY_FOOTPRINT="$value" ;;
                esac
        done < "$INSTALLER_SETTINGS_FILE"
}

save_installer_settings() {
        cat > "$INSTALLER_SETTINGS_FILE" <<EOF_SETTINGS
BFS_THEME=$BFS_THEME
CONSOLE_FONT_PREFERENCE=$CONSOLE_FONT_PREFERENCE
INSTALL_CONSOLE_FONT=$INSTALL_CONSOLE_FONT
LOG_ENABLED=$LOG_ENABLED
BUILD_JOBS=$BUILD_JOBS
BUILD_OPT=$BUILD_OPT
BUILD_CCACHE=$BUILD_CCACHE
BUILD_CCACHE_SIZE=$BUILD_CCACHE_SIZE
BUILD_TMPFS=$BUILD_TMPFS
BUILD_TMPFS_SIZE=$BUILD_TMPFS_SIZE
VERIFY_MD5=$VERIFY_MD5
VERIFY_SIGNATURE=$VERIFY_SIGNATURE
VERIFY_FOOTPRINT=$VERIFY_FOOTPRINT
EOF_SETTINGS
}

write_dialog_theme_classic() {
        cat > "$DIALOGRC_FILE" <<'EOF_DIALOGRC'
use_colors = ON
use_shadow = ON

# Classic Debian installer-inspired palette, translated from cdebconf/newt:
# newt default root is white-on-blue; windows are black-on-lightgray;
# titles are red-on-lightgray; selected list entries use yellow-on-blue.
screen_color = (WHITE,BLUE,OFF)
shadow_color = (WHITE,BLACK,OFF)
dialog_color = (BLACK,WHITE,OFF)
title_color = (RED,WHITE,ON)
border_color = (BLACK,WHITE,OFF)

button_active_color = (RED,WHITE,ON)
button_inactive_color = (BLACK,WHITE,OFF)
button_key_active_color = (RED,WHITE,ON)
button_key_inactive_color = (BLACK,WHITE,ON)
button_label_active_color = (RED,WHITE,ON)
button_label_inactive_color = (BLACK,WHITE,OFF)

inputbox_color = (YELLOW,BLUE,OFF)
inputbox_border_color = (BLACK,WHITE,OFF)
searchbox_color = (BLACK,WHITE,OFF)
searchbox_title_color = (RED,WHITE,ON)
searchbox_border_color = (BLACK,WHITE,OFF)

position_indicator_color = (YELLOW,BLUE,ON)
menubox_color = (BLACK,WHITE,OFF)
menubox_border_color = (BLACK,WHITE,OFF)
item_color = (BLACK,WHITE,OFF)
item_selected_color = (YELLOW,BLUE,ON)
tag_color = (RED,WHITE,ON)
tag_selected_color = (YELLOW,BLUE,ON)
tag_key_color = (RED,WHITE,ON)
tag_key_selected_color = (YELLOW,BLUE,ON)

check_color = (YELLOW,BLUE,OFF)
check_selected_color = (BLACK,WHITE,ON)
uarrow_color = (RED,WHITE,ON)
darrow_color = (RED,WHITE,ON)
gauge_color = (YELLOW,BLUE,ON)
EOF_DIALOGRC
}

write_dialog_theme_midnight() {
        cat > "$DIALOGRC_FILE" <<'EOF_DIALOGRC'
use_colors = ON
use_shadow = OFF
screen_color = (WHITE,BLACK,ON)
dialog_color = (BLACK,CYAN,ON)
title_color = (YELLOW,CYAN,ON)
border_color = (WHITE,CYAN,ON)
button_active_color = (WHITE,BLUE,ON)
button_inactive_color = (BLACK,CYAN,ON)
menubox_color = (BLACK,CYAN,ON)
menubox_border_color = (WHITE,CYAN,ON)
item_color = (BLACK,CYAN,ON)
item_selected_color = (WHITE,BLUE,ON)
tag_color = (YELLOW,CYAN,ON)
tag_selected_color = (YELLOW,BLUE,ON)
EOF_DIALOGRC
}

write_dialog_theme_light() {
        cat > "$DIALOGRC_FILE" <<'EOF_DIALOGRC'
use_colors = ON
use_shadow = OFF
screen_color = (BLACK,WHITE,ON)
dialog_color = (BLACK,WHITE,ON)
title_color = (BLUE,WHITE,ON)
border_color = (BLUE,WHITE,ON)
button_active_color = (WHITE,BLUE,ON)
button_inactive_color = (BLACK,WHITE,ON)
menubox_color = (BLACK,WHITE,ON)
menubox_border_color = (BLUE,WHITE,ON)
item_color = (BLACK,WHITE,ON)
item_selected_color = (WHITE,BLUE,ON)
tag_color = (BLUE,WHITE,ON)
tag_selected_color = (YELLOW,BLUE,ON)
EOF_DIALOGRC
}

write_dialog_theme_slackware() {
        cat > "$DIALOGRC_FILE" <<'EOF_DIALOGRC'
aspect = 0
separate_widget = ""
tab_len = 0
visit_items = OFF
use_scrollbar = OFF
use_shadow = ON
use_colors = ON

# Slackware's actual dialogrc palette.
screen_color = (WHITE,BLUE,OFF)
shadow_color = (WHITE,BLACK,OFF)
dialog_color = (BLACK,CYAN,OFF)
title_color = (YELLOW,CYAN,ON)
border_color = (CYAN,CYAN,ON)

button_active_color = (WHITE,BLUE,ON)
button_inactive_color = dialog_color
button_key_active_color = button_active_color
button_key_inactive_color = (RED,CYAN,OFF)
button_label_active_color = button_active_color
button_label_inactive_color = (BLACK,CYAN,ON)

inputbox_color = (BLUE,WHITE,OFF)
inputbox_border_color = border_color
searchbox_color = (YELLOW,WHITE,ON)
searchbox_title_color = (WHITE,WHITE,ON)
searchbox_border_color = (RED,WHITE,OFF)

position_indicator_color = button_key_inactive_color
menubox_color = dialog_color
menubox_border_color = border_color
item_color = dialog_color
item_selected_color = screen_color
tag_color = title_color
tag_selected_color = screen_color
tag_key_color = button_key_inactive_color
tag_key_selected_color = (RED,BLUE,ON)

check_color = dialog_color
check_selected_color = (WHITE,CYAN,ON)
uarrow_color = (GREEN,CYAN,ON)
darrow_color = uarrow_color
itemhelp_color = shadow_color
form_active_text_color = inputbox_color
form_text_color = (CYAN,BLUE,ON)
form_item_readonly_color = (CYAN,WHITE,ON)
gauge_color = (BLUE,WHITE,ON)

border2_color = dialog_color
inputbox_border2_color = dialog_color
searchbox_border2_color = dialog_color
menubox_border2_color = dialog_color
EOF_DIALOGRC
}

write_dialog_theme_monochrome() {
        cat > "$DIALOGRC_FILE" <<'EOF_DIALOGRC'
use_colors = OFF
use_shadow = OFF
EOF_DIALOGRC
}

theme_display_name() {
        case "$BFS_THEME" in
                classic) printf '%s' "Classic Debian" ;;
                midnight) printf '%s' "Midnight" ;;
                slackware) printf '%s' "Classic Slackware" ;;
                light) printf '%s' "Light" ;;
                monochrome) printf '%s' "Monochrome" ;;
                *) printf '%s' "$BFS_THEME" ;;
        esac
}

setup_installer_theme() {
        [[ -z "$DIALOGRC_FILE" ]] || rm -f "$DIALOGRC_FILE"
        DIALOGRC_FILE="$(mktemp /tmp/bfs-installer-dialogrc.XXXXXX)"

        case "$BFS_THEME" in
                classic) write_dialog_theme_classic ;;
                midnight) write_dialog_theme_midnight ;;
                slackware) write_dialog_theme_slackware ;;
                light) write_dialog_theme_light ;;
                monochrome) write_dialog_theme_monochrome ;;
                *) BFS_THEME=slackware; write_dialog_theme_slackware ;;
        esac

        export DIALOGRC="$DIALOGRC_FILE"
}

reset_terminal_ui() {
        # dialog can leave its full-screen background/colors painted on the
        # controlling terminal. Restore attributes, make the cursor visible,
        # and clear/redraw the terminal before returning to the shell.
        if { : </dev/tty; } 2>/dev/null; then
                printf '\033[0m\033[?25h\033[2J\033[H' >/dev/tty 2>/dev/null || true
                if command -v clear >/dev/null 2>&1; then
                        TERM="${TERM:-linux}" clear </dev/tty >/dev/tty 2>/dev/null || true
                fi
        else
                printf '\033[0m\033[?25h\033[2J\033[H' 2>/dev/null || true
        fi
}

report_installer_interface_mode() {
        local -a reasons=()

        if ! command -v dialog >/dev/null 2>&1; then
                reasons+=("dialog command is not installed or not in PATH")
        fi

        if [[ ! -e /dev/tty ]]; then
                reasons+=("/dev/tty does not exist")
        else
                [[ -r /dev/tty ]] || reasons+=("/dev/tty is not readable")
                [[ -w /dev/tty ]] || reasons+=("/dev/tty is not writable")
        fi

        if ((${#reasons[@]} == 0)); then
                printf '\nInstaller interface: dialog mode (%s theme)\n' \
                        "$(theme_display_name)"
                return 0
        fi

        printf '\nWARNING: Dialog interface unavailable.\n' >&2
        printf 'Reason(s):\n' >&2

        local reason
        for reason in "${reasons[@]}"; do
                printf '  - %s\n' "$reason" >&2
        done

        printf 'Continuing with the text-based installer interface.\n\n' >&2
        return 0
}

console_font_patterns_for_size() {
        local size="$1"
        case "$size" in
                # Prefer the exact fonts shipped by the BFSOS base system first.
                16) printf '%s\n' 'Lat2-Terminus16*' 'LatGrkCyr-8x16*' 'Uni2-Terminus16*' 'ter-v16n*' '*Terminus*16*' '*16*.psf*' ;;
                # BFSOS currently ships LatGrkCyr-12x22 as its practical ~20px font.
                # Put it first so a generic/wrong 16px fallback can never win.
                20) printf '%s\n' 'LatGrkCyr-12x22*' 'Lat2-Terminus20*' 'Uni2-Terminus20*' 'ter-v20n*' 'LatArCyrHeb-19*' 'lat4-19*' '*Terminus*20*' '*22*.psf*' '*20*.psf*' '*19*.psf*' ;;
                32) printf '%s\n' 'latarcyrheb-sun32*' '*sun32*' '*32*.psf*' ;;
                *) return 1 ;;
        esac
}

find_console_font_for_size() {
        local size="$1" dir="" candidate=""
        local -a dirs=(/usr/share/consolefonts /usr/share/kbd/consolefonts /lib/kbd/consolefonts)
        local -a patterns=()

        mapfile -t patterns < <(console_font_patterns_for_size "$size") || return 1
        for dir in "${dirs[@]}"; do
                [[ -d "$dir" ]] || continue
                for candidate in "${patterns[@]}"; do
                        find "$dir" -maxdepth 1 -type f -name "$candidate" -print -quit 2>/dev/null
                done
        done | head -n1
}

apply_console_font() {
        local size="${1:-$CONSOLE_FONT_SIZE}" font=""

        command -v setfont >/dev/null 2>&1 || {
                [[ "$size" == default ]] || warn "setfont is unavailable; console font size was not changed."
                return 0
        }

        case "$size" in
                default)
                        setfont >/dev/tty 2>/dev/tty || true
                        ;;
                16|20|32)
                        font="$(find_console_font_for_size "$size" || true)"
                        if [[ -z "$font" ]]; then
                                warn "No ${size}-pixel console font was found; keeping the current console font."
                                return 0
                        fi
                        if ! setfont "$font" >/dev/tty 2>/dev/tty; then
                                warn "Could not apply $font. This is normal over SSH or inside a graphical terminal."
                        fi
                        ;;
        esac
}

console_font_display_name() {
        case "$CONSOLE_FONT_SIZE" in
                default) printf '%s' "Default" ;;
                16) printf '%s' "Large 16" ;;
                20) printf '%s' "Large ~20" ;;
                32) printf '%s' "Extra Large 32" ;;
                *) printf '%s' "$CONSOLE_FONT_SIZE" ;;
        esac
}

select_console_font_size() {
        local choice="" status=0
        themed_menu choice "Console Font Size" \
                "Choose the Linux virtual-console font size for this installer session.\n\nLarge fonts are most useful on high-DPI/4K displays." \
                19 78 7 \
                default "Default console font" \
                16 "Large 16-pixel font" \
                20 "Large ~20-pixel font (19/20/22 fallback)" \
                32 "Extra Large 32-pixel font (recommended for high-DPI)"
        [[ -n "$choice" ]] || return 0
        CONSOLE_FONT_PREFERENCE="$choice"
        CONSOLE_FONT_SIZE="$choice"
        if [[ "$choice" == default ]]; then
                INSTALL_CONSOLE_FONT=no
        else
                INSTALL_CONSOLE_FONT=yes
        fi
        apply_console_font "$choice"
        save_installer_settings

        # Make the chosen/persistent value explicit so a mistaken selection is
        # visible immediately instead of being discovered only after reboot.
        if [[ "$choice" == default ]]; then
                dialog_message "Console font"                         "Console font selection: Default\n\nNo custom large-font selection will be persisted."
        else
                local selected_font=""
                selected_font="$(find_console_font_for_size "$choice" || true)"
                if [[ -n "$selected_font" ]]; then
                        dialog_message "Console font"                                 "Selected size: $(console_font_display_name)\nFont found: $(basename "$selected_font")\n\nThis size will be persisted to the installed system."
                else
                        dialog_message "Console font"                                 "Selected size: $(console_font_display_name)\n\nNo matching font was found in the live environment. The installed-system step will check again and warn if unavailable."
                fi
        fi
}

select_installer_theme() {
        local choice="" status=0

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                if choice="$(
                        dialog --stdout --clear \
                                --backtitle "BFSOS Installer" \
                                --title "Interface Theme" \
                                --cancel-label "Back" \
                                --radiolist \
                                "Choose the installer theme." \
                                20 82 7 \
                                Slackware "Classic Slackware setup-style cyan theme (default)" \
                                        "$([[ "$BFS_THEME" == slackware ]] && echo on || echo off)" \
                                Debian "Classic Debian installer/newt-style theme" \
                                        "$([[ "$BFS_THEME" == classic ]] && echo on || echo off)" \
                                Monochrome "Best compatibility for SSH and unusual palettes" \
                                        "$([[ "$BFS_THEME" == monochrome ]] && echo on || echo off)" \
                                Midnight "Midnight Commander-style theme" \
                                        "$([[ "$BFS_THEME" == midnight ]] && echo on || echo off)" \
                                Light "Black text on a light background" \
                                        "$([[ "$BFS_THEME" == light ]] && echo on || echo off)" \
                                </dev/tty
                )"; then
                        status=0
                else
                        status=$?
                fi
                [[ "$status" -eq 0 && -n "$choice" ]] || return 0
                case "$choice" in
                        Slackware) choice=slackware ;;
                        Debian) choice=classic ;;
                        Monochrome) choice=monochrome ;;
                        Midnight) choice=midnight ;;
                        Light) choice=light ;;
                esac
        else
                echo "  1) Slackware (Classic Slackware, default)"
                echo "  2) Debian (Classic Debian)"
                echo "  3) Monochrome"
                echo "  4) Midnight"
                echo "  5) Light"
                echo "  6) Back"
                read -r -p "Choose [1-6, current: $(theme_display_name)]: " choice
                case "$choice" in
                        1) choice=slackware ;;
                        2) choice=classic ;;
                        3) choice=monochrome ;;
                        4) choice=midnight ;;
                        5) choice=light ;;
                        6|"") return 0 ;;
                        *) warn "Invalid theme selection."; return 1 ;;
                esac
        fi

        BFS_THEME="$choice"
        setup_installer_theme
        save_installer_settings
}
profile_quote() { printf '%q' "$1"; }

append_unique() {
        local array_name="$1" value="$2" existing=""
        [[ -n "$value" ]] || return 0
        local -n array_ref="$array_name"
        for existing in "${array_ref[@]}"; do
                [[ "$existing" == "$value" ]] && return 0
        done
        array_ref+=("$value")
}

storage_subvolume_for_mountpoint() {
        local format="${1:-}" mountpoint="${2:-}" name=""
        [[ "$format" == btrfs ]] || return 0
        case "$mountpoint" in
                /) printf '%s' "@" ;;
                /home) printf '%s' "@home" ;;
                *)
                        name="${mountpoint#/}"
                        name="${name//\//-}"
                        name="${name//[^a-zA-Z0-9_.-]/-}"
                        [[ -n "$name" ]] || name=root
                        printf '@%s' "$name"
                        ;;
        esac
}

refresh_storage_subvolume_metadata() {
        local i subvol=""
        STORAGE_SUBVOLUMES=()
        for ((i=0; i<${#STORAGE_DEVICES[@]}; i++)); do
                subvol="$(storage_subvolume_for_mountpoint \
                        "${STORAGE_FORMATS[$i]:-}" "${STORAGE_MOUNTPOINTS[$i]:-}")"
                STORAGE_SUBVOLUMES+=("$subvol")
        done
}

capture_recovery_storage_topology() {
        local dev="" ancestor="" type="" array="" members="" mapping="" backing="" vg=""
        local -a selected=()

        RECOVERY_MD_ARRAYS=()
        RECOVERY_MD_MEMBERS=()
        RECOVERY_MD_UUIDS=()
        RECOVERY_LUKS_DEVICES=()
        RECOVERY_LUKS_MAPPINGS=()
        RECOVERY_VGS=()

        selected=("${STORAGE_DEVICES[@]}")
        for dev in "$ROOT_DEV" "$BOOT_DEV" "$EFI_DEV" "$SWAP_DEV" "$HOME_DEV" "${EXTRA_DEVICES[@]}"; do
                [[ -n "$dev" ]] && selected+=("$dev")
        done

        for dev in "${selected[@]}"; do
                [[ -b "$dev" ]] || continue

                # Canonical LV paths make the VG name available directly.
                if command -v lvs >/dev/null 2>&1; then
                        vg="$(lvs --noheadings -o vg_name "$dev" 2>/dev/null | xargs 2>/dev/null || true)"
                        [[ -n "$vg" ]] && append_unique RECOVERY_VGS "$vg"
                fi

                while read -r ancestor type; do
                        [[ -n "$ancestor" ]] || continue
                        case "$type" in
                                md|raid*|linear)
                                        array="$(readlink -f "$ancestor" 2>/dev/null || printf '%s' "$ancestor")"
                                        if ! printf '%s\n' "${RECOVERY_MD_ARRAYS[@]}" | grep -Fxq "$array"; then
                                                members=""
                                                if command -v mdadm >/dev/null 2>&1; then
                                                        members="$(mdadm --detail "$array" 2>/dev/null |
                                                                awk '$0 ~ /(active sync|spare|rebuilding)/ {print $NF}' |
                                                                paste -sd, - || true)"
                                                fi
                                                local md_uuid=""
                                                md_uuid="$(mdadm --detail "$array" 2>/dev/null |
                                                        sed -n 's/^[[:space:]]*UUID[[:space:]]*:[[:space:]]*//p' |
                                                        head -n1)"
                                                RECOVERY_MD_ARRAYS+=("$array")
                                                RECOVERY_MD_MEMBERS+=("$members")
                                                RECOVERY_MD_UUIDS+=("$md_uuid")
                                        fi
                                        ;;
                                crypt)
                                        mapping="$(dmsetup info -C --noheadings -o name "$ancestor" 2>/dev/null |
                                                xargs 2>/dev/null || true)"
                                        [[ -n "$mapping" ]] || mapping="$(basename "$ancestor")"
                                        backing="$(cryptsetup status "$mapping" 2>/dev/null |
                                                sed -n 's/^[[:space:]]*device:[[:space:]]*//p' |
                                                head -n1)"
                                        [[ -n "$backing" ]] || continue
                                        local seen=no j
                                        for ((j=0; j<${#RECOVERY_LUKS_MAPPINGS[@]}; j++)); do
                                                if [[ "${RECOVERY_LUKS_MAPPINGS[$j]}" == "$mapping" ]]; then
                                                        seen=yes
                                                        break
                                                fi
                                        done
                                        if [[ "$seen" == no ]]; then
                                                RECOVERY_LUKS_DEVICES+=("$backing")
                                                RECOVERY_LUKS_MAPPINGS+=("$mapping")
                                        fi
                                        ;;
                        esac
                done < <(lsblk -spno PATH,TYPE "$dev" 2>/dev/null || true)
        done

        # Also persist storage objects explicitly created/opened/activated by
        # this installer session. This is essential for multi-PV VGs: an LV may
        # not currently allocate extents from every PV, so walking only the
        # selected leaf devices can omit a valid MD -> LUKS -> PV branch.
        for array in "${CREATED_MD_ARRAYS_BY_SCRIPT[@]}"; do
                [[ -n "$array" && -b "$array" ]] || continue
                mdadm --detail "$array" >/dev/null 2>&1 || continue
                local already_md=no md_i="" md_uuid=""
                for ((md_i=0; md_i<${#RECOVERY_MD_ARRAYS[@]}; md_i++)); do
                        if [[ "$(readlink -f "${RECOVERY_MD_ARRAYS[$md_i]}" 2>/dev/null || printf '%s' "${RECOVERY_MD_ARRAYS[$md_i]}")" ==                               "$(readlink -f "$array" 2>/dev/null || printf '%s' "$array")" ]]; then
                                already_md=yes
                                break
                        fi
                done
                if [[ "$already_md" == no ]]; then
                        members="$(mdadm --detail "$array" 2>/dev/null |
                                awk '$0 ~ /(active sync|spare|rebuilding)/ {print $NF}' |
                                paste -sd, - || true)"
                        md_uuid="$(mdadm --detail "$array" 2>/dev/null |
                                sed -n 's/^[[:space:]]*UUID[[:space:]]*:[[:space:]]*//p' |
                                head -n1)"
                        RECOVERY_MD_ARRAYS+=("$array")
                        RECOVERY_MD_MEMBERS+=("$members")
                        RECOVERY_MD_UUIDS+=("$md_uuid")
                fi
        done

        for mapping in "${OPENED_LUKS_BY_SCRIPT[@]}"; do
                [[ -n "$mapping" ]] || continue
                cryptsetup status "$mapping" >/dev/null 2>&1 || continue
                backing="$(cryptsetup status "$mapping" 2>/dev/null |
                        sed -n 's/^[[:space:]]*device:[[:space:]]*//p' |
                        head -n1)"
                [[ -n "$backing" ]] || continue
                local already_luks=no luks_i=""
                for ((luks_i=0; luks_i<${#RECOVERY_LUKS_MAPPINGS[@]}; luks_i++)); do
                        if [[ "${RECOVERY_LUKS_MAPPINGS[$luks_i]}" == "$mapping" ]]; then
                                already_luks=yes
                                break
                        fi
                done
                if [[ "$already_luks" == no ]]; then
                        RECOVERY_LUKS_DEVICES+=("$backing")
                        RECOVERY_LUKS_MAPPINGS+=("$mapping")
                fi
        done

        for vg in "${ACTIVATED_VGS_BY_SCRIPT[@]}"; do
                append_unique RECOVERY_VGS "$vg"
        done
}

save_installer_profile() {
        local path="${1:-$INSTALLER_PROFILE_FILE}" quiet="${2:-no}" i
        refresh_storage_subvolume_metadata
        capture_recovery_storage_topology
        {
                echo '# BFSOS installer profile v3 - no passwords or LUKS passphrases are stored.'
                for name in HOSTNAME TIMEZONE LOCALE USERNAME ROOT_PASSWORD_POLICY BOOT_MODE BOOT_DISK NETWORK_IFACE NETWORK_MAC NETWORK_TARGET_NAME KERNEL_PACKAGE INSTALL_GRUB GRUB_FALLBACK SAVE_BASE_ARCHIVE BASE_ARCHIVE_DIR ENABLE_OPENSSH INSTALL_GIT INSTALL_SUDO SUDO_MODE INSTALL_WGET INSTALL_WPA_SUPPLICANT INSTALL_WIRELESS_TOOLS INSTALL_GPM INSTALL_LYNX INSTALL_LINKS INSTALL_NETWORKMANAGER CONSOLE_VIDEO_MODE SERIAL_CONSOLE ZRAM_SIZE_SPEC BUILD_JOBS BUILD_OPT BUILD_CCACHE BUILD_CCACHE_SIZE BUILD_TMPFS BUILD_TMPFS_SIZE ARCHIVE ROOT_DEV ROOT_FORMAT BOOT_DEV BOOT_FORMAT EFI_DEV EFI_FORMAT SWAP_DEV SWAP_FORMAT HOME_DEV HOME_FORMAT ZRAM_SWAP; do
                        printf '%s=' "$name"; profile_quote "${!name:-}"; printf '\n'
                done
                for ((i=0;i<${#ADDITIONAL_USERS[@]};i++)); do
                        printf 'ADDITIONAL_USER_ENTRY='
                        profile_quote "${ADDITIONAL_USERS[$i]}|${ADDITIONAL_USER_TYPES[$i]:-standard}|${ADDITIONAL_USER_GROUPS[$i]:-}"
                        printf '\n'
                done
                for ((i=0;i<${#STORAGE_DEVICES[@]};i++)); do
                        printf 'STORAGE='
                        profile_quote "${STORAGE_DEVICES[$i]}|${STORAGE_FORMATS[$i]}|${STORAGE_MOUNTPOINTS[$i]}|${STORAGE_SUBVOLUMES[$i]:-}"
                        printf '\n'
                done
                for ((i=0;i<${#RECOVERY_MD_ARRAYS[@]};i++)); do
                        printf 'RECOVERY_MD='
                        profile_quote "${RECOVERY_MD_ARRAYS[$i]}|${RECOVERY_MD_MEMBERS[$i]:-}|${RECOVERY_MD_UUIDS[$i]:-}"
                        printf '\n'
                done
                for ((i=0;i<${#RECOVERY_LUKS_MAPPINGS[@]};i++)); do
                        printf 'RECOVERY_LUKS='
                        profile_quote "${RECOVERY_LUKS_DEVICES[$i]}|${RECOVERY_LUKS_MAPPINGS[$i]}"
                        printf '\n'
                done
                for vg in "${RECOVERY_VGS[@]}"; do
                        printf 'RECOVERY_VG='; profile_quote "$vg"; printf '\n'
                done
        } >"$path"
        INSTALLER_PROFILE_FILE="$path"
        [[ "$quiet" == yes ]] || dialog_message "Configuration profile" "Saved installer configuration to:\n$path\n\nPasswords and LUKS passphrases were not saved."
}

deduplicated_missing_devices() {
        local dev="" canonical=""
        local -A seen=()
        for dev in "$@"; do
                [[ -n "$dev" ]] || continue
                canonical="$(readlink -m "$dev" 2>/dev/null || printf '%s' "$dev")"
                [[ -n "${seen[$canonical]:-}" ]] && continue
                seen["$canonical"]=1
                [[ -b "$dev" ]] || printf '%s\n' "$dev"
        done
}

rebuild_btrfs_layout_from_saved_plan() {
        local i subvol="" snapshot="" name="" mp="" dev="" fmt=""
        BTRFS_DEVICES=()
        BTRFS_MOUNTPOINTS=()
        BTRFS_SUBVOLUMES=()
        BTRFS_SNAPSHOT_SUBVOLUMES=()
        BTRFS_CONFIG_NAMES=()

        for ((i=0; i<${#STORAGE_DEVICES[@]}; i++)); do
                dev="${STORAGE_DEVICES[$i]}"
                fmt="${STORAGE_FORMATS[$i]}"
                mp="${STORAGE_MOUNTPOINTS[$i]}"
                [[ "$fmt" == btrfs ]] || continue
                subvol="${STORAGE_SUBVOLUMES[$i]:-}"
                [[ -n "$subvol" ]] || subvol="$(storage_subvolume_for_mountpoint "$fmt" "$mp")"
                case "$subvol" in
                        @) snapshot="@snapshots"; name=root ;;
                        @home) snapshot="@home-snapshots"; name=home ;;
                        @*) name="${subvol#@}"; snapshot="@${name}-snapshots" ;;
                        *) name="$(sanitize_btrfs_name "$mp")"; snapshot="@${name}-snapshots" ;;
                esac
                BTRFS_DEVICES+=("$dev")
                BTRFS_MOUNTPOINTS+=("$mp")
                BTRFS_SUBVOLUMES+=("$subvol")
                BTRFS_SNAPSHOT_SUBVOLUMES+=("$snapshot")
                BTRFS_CONFIG_NAMES+=("$name")
        done
}

# Enumerate active Linux MD arrays without assuming a particular MD personality.
# lsblk reports traditional RAID personalities as raid0/raid1/raid5/etc., while
# MD Linear/JBOD is commonly reported simply as "linear".  /sys/class/block/md*
# is therefore the authoritative personality-independent source.
list_active_md_arrays() {
        local md_sys="" base="" dev=""

        shopt -s nullglob
        for md_sys in /sys/class/block/md*/md; do
                base="${md_sys#/sys/class/block/}"
                base="${base%%/*}"
                dev="/dev/$base"
                [[ -b "$dev" ]] || continue
                printf '%s\n' "$dev"
        done
        shopt -u nullglob
}

is_md_block_device() {
        local dev="${1:-}" canonical="" base=""

        [[ -n "$dev" ]] || return 1
        canonical="$(readlink -f -- "$dev" 2>/dev/null || printf '%s' "$dev")"
        base="${canonical##*/}"
        [[ -d "/sys/class/block/$base/md" ]]
}

list_active_md_members() {
        local array="" canonical="" base="" slave="" member=""

        while IFS= read -r array; do
                [[ -n "$array" ]] || continue
                canonical="$(readlink -f -- "$array" 2>/dev/null || printf '%s' "$array")"
                base="${canonical##*/}"

                shopt -s nullglob
                for slave in "/sys/class/block/$base/slaves/"*; do
                        [[ -e "$slave" ]] || continue
                        member="/dev/${slave##*/}"
                        readlink -f -- "$member" 2>/dev/null || printf '%s\n' "$member"
                done
                shopt -u nullglob
        done < <(list_active_md_arrays)
}

is_active_md_member() {
        local dev="${1:-}" canonical="" member=""

        [[ -n "$dev" ]] || return 1
        canonical="$(readlink -f -- "$dev" 2>/dev/null || printf '%s' "$dev")"
        while IFS= read -r member; do
                [[ -n "$member" ]] || continue
                [[ "$canonical" == "$member" ]] && return 0
        done < <(list_active_md_members)
        return 1
}

md_array_uuid() {
        local array="$1"
        mdadm --detail "$array" 2>/dev/null |
                sed -n 's/^[[:space:]]*UUID[[:space:]]*:[[:space:]]*//p' |
                head -n1
}

md_array_members_sorted() {
        local array="$1"
        mdadm --detail "$array" 2>/dev/null |
                awk '$0 ~ /(active sync|spare|rebuilding)/ {print $NF}' |
                while IFS= read -r member; do
                        readlink -f "$member" 2>/dev/null || printf '%s\n' "$member"
                done |
                sort -u
}

saved_md_members_sorted() {
        local members_csv="$1" member=""
        local -a members=()
        IFS=',' read -r -a members <<<"$members_csv"
        for member in "${members[@]}"; do
                [[ -n "$member" ]] || continue
                readlink -f "$member" 2>/dev/null || printf '%s\n' "$member"
        done | sort -u
}

find_active_md_array() {
        local wanted_uuid="$1" members_csv="$2" candidate="" candidate_uuid=""
        local wanted_members="" candidate_members=""
        local -a candidates=()

        shopt -s nullglob
        candidates=(/dev/md[0-9]* /dev/md/*)
        shopt -u nullglob

        wanted_members="$(saved_md_members_sorted "$members_csv")"
        for candidate in "${candidates[@]}"; do
                [[ -b "$candidate" ]] || continue
                mdadm --detail "$candidate" >/dev/null 2>&1 || continue

                if [[ -n "$wanted_uuid" ]]; then
                        candidate_uuid="$(md_array_uuid "$candidate")"
                        if [[ -n "$candidate_uuid" && "$candidate_uuid" == "$wanted_uuid" ]]; then
                                printf '%s\n' "$candidate"
                                return 0
                        fi
                fi

                [[ -n "$wanted_members" ]] || continue
                candidate_members="$(md_array_members_sorted "$candidate")"
                if [[ -n "$candidate_members" && "$candidate_members" == "$wanted_members" ]]; then
                        printf '%s\n' "$candidate"
                        return 0
                fi
        done
        return 1
}

adopt_recovered_md_path() {
        local saved="$1" active="$2" i=""
        [[ -n "$saved" && -n "$active" ]] || return 0
        [[ "$saved" != "$active" ]] || return 0

        log "Resume: saved MD device $saved is active as $active; adopting active path"

        for ((i=0; i<${#RECOVERY_LUKS_DEVICES[@]}; i++)); do
                if [[ "${RECOVERY_LUKS_DEVICES[$i]}" == "$saved" ]] ||
                   [[ "$(readlink -m "${RECOVERY_LUKS_DEVICES[$i]}" 2>/dev/null || true)" == \
                      "$(readlink -m "$saved" 2>/dev/null || true)" ]]; then
                        RECOVERY_LUKS_DEVICES[$i]="$active"
                fi
        done
}

recover_saved_md_arrays() {
        local i array members_csv member wanted_uuid="" active_array=""
        local -a members=()
        command -v mdadm >/dev/null 2>&1 || return 0

        for ((i=0; i<${#RECOVERY_MD_ARRAYS[@]}; i++)); do
                array="${RECOVERY_MD_ARRAYS[$i]}"
                members_csv="${RECOVERY_MD_MEMBERS[$i]:-}"
                wanted_uuid="${RECOVERY_MD_UUIDS[$i]:-}"
                [[ -n "$array" ]] || continue

                # The kernel/live environment is free to auto-assemble an MD
                # array under a different node (for example saved md0 -> md127).
                # Adopt an already-active array by persistent UUID first, then
                # by the exact saved member set for older r49/r50 profiles.
                active_array="$(find_active_md_array "$wanted_uuid" "$members_csv" 2>/dev/null || true)"
                if [[ -n "$active_array" ]]; then
                        adopt_recovered_md_path "$array" "$active_array"
                        RECOVERY_MD_ARRAYS[$i]="$active_array"
                        continue
                fi

                if [[ -b "$array" ]] && mdadm --detail "$array" >/dev/null 2>&1; then
                        continue
                fi

                IFS=',' read -r -a members <<<"$members_csv"
                if ((${#members[@]} == 0)) || [[ -z "${members[0]:-}" ]]; then
                        dialog_message "Resume storage recovery" "Cannot safely assemble saved MD array $array because its member list was not persisted.\n\nNo destructive action was taken."
                        return 1
                fi
                for member in "${members[@]}"; do
                        [[ -b "$member" ]] || {
                                dialog_message "Resume storage recovery" "Saved MD member is unavailable:\n$member\n\nRequired array: $array"
                                return 1
                        }
                done

                log "Resume: assembling saved MD array $array"
                if ! mdadm --assemble "$array" "${members[@]}"; then
                        # A race with live-environment auto-assembly can make the
                        # members busy between discovery and assembly. Re-scan
                        # once for an equivalent active array before failing.
                        active_array="$(find_active_md_array "$wanted_uuid" "$members_csv" 2>/dev/null || true)"
                        if [[ -n "$active_array" ]]; then
                                adopt_recovered_md_path "$array" "$active_array"
                                RECOVERY_MD_ARRAYS[$i]="$active_array"
                                continue
                        fi
                        dialog_message "Resume storage recovery" "Could not assemble saved MD array:\n$array\n\nNo equivalent active MD array matching the saved UUID/member set was found.\n\nNo destructive action was taken."
                        return 1
                fi
        done
        command -v udevadm >/dev/null 2>&1 && udevadm settle || true
        return 0
}

recover_saved_luks_mappings() {
        local i backing mapping pass="" actual=""
        command -v cryptsetup >/dev/null 2>&1 || {
                ((${#RECOVERY_LUKS_MAPPINGS[@]} == 0)) && return 0
                dialog_message "Resume storage recovery" "cryptsetup is required to reopen the saved encrypted storage."
                return 1
        }

        for ((i=0; i<${#RECOVERY_LUKS_MAPPINGS[@]}; i++)); do
                backing="${RECOVERY_LUKS_DEVICES[$i]}"
                mapping="${RECOVERY_LUKS_MAPPINGS[$i]}"
                [[ -n "$backing" && -n "$mapping" ]] || continue

                if cryptsetup status "$mapping" >/dev/null 2>&1; then
                        actual="$(cryptsetup status "$mapping" 2>/dev/null |
                                sed -n 's/^[[:space:]]*device:[[:space:]]*//p' | head -n1)"
                        if [[ "$(readlink -f "$actual" 2>/dev/null || printf '%s' "$actual")" != \
                              "$(readlink -f "$backing" 2>/dev/null || printf '%s' "$backing")" ]]; then
                                dialog_message "Resume storage recovery" "Existing mapping /dev/mapper/$mapping does not point to the saved backing device $backing.\n\nRecovery stopped without changing it."
                                return 1
                        fi
                        continue
                fi

                [[ -b "$backing" ]] || {
                        dialog_message "Resume storage recovery" "Saved LUKS backing device is unavailable:\n$backing\n\nMapping: $mapping"
                        return 1
                }

                dialog_password pass "Resume encrypted storage" \
                        "Enter the passphrase to reopen:\n\n$backing\nas /dev/mapper/$mapping" || return 1
                if ! printf '%s' "$pass" | cryptsetup open --key-file - "$backing" "$mapping"; then
                        pass=""
                        dialog_message "Resume storage recovery" "Could not reopen $backing as /dev/mapper/$mapping.\n\nNo destructive action was taken."
                        return 1
                fi
                pass=""
                append_unique OPENED_LUKS_BY_SCRIPT "$mapping"
                command -v udevadm >/dev/null 2>&1 && udevadm settle || true
        done
        return 0
}

recover_saved_vgs() {
        local vg=""
        command -v vgchange >/dev/null 2>&1 || {
                ((${#RECOVERY_VGS[@]} == 0)) && return 0
                dialog_message "Resume storage recovery" "LVM tools are required to activate the saved volume groups."
                return 1
        }
        command -v vgscan >/dev/null 2>&1 && vgscan --mknodes >/dev/null 2>&1 || true
        for vg in "${RECOVERY_VGS[@]}"; do
                [[ -n "$vg" ]] || continue
                log "Resume: activating saved LVM volume group $vg"
                if ! vgchange -ay "$vg" >/dev/null; then
                        dialog_message "Resume storage recovery" "Could not activate saved LVM volume group:\n$vg\n\nNo destructive action was taken."
                        return 1
                fi
                append_unique ACTIVATED_VGS_BY_SCRIPT "$vg"
        done
        command -v udevadm >/dev/null 2>&1 && udevadm settle || true
        return 0
}

recover_saved_storage_stack() {
        local i backing=""
        log "Resume: reconstructing saved storage stack"

        # Older/incomplete profiles may contain a LUKS mapping backed by /dev/mdX
        # without a RECOVERY_MD record (notably Linear/JBOD, whose lsblk TYPE
        # may be "linear" instead of "raid*"). Refuse to skip that dependency silently.
        if ((${#RECOVERY_MD_ARRAYS[@]} == 0)); then
                for ((i=0; i<${#RECOVERY_LUKS_DEVICES[@]}; i++)); do
                        backing="${RECOVERY_LUKS_DEVICES[$i]:-}"
                        if [[ "$backing" == /dev/md* && ! -b "$backing" ]]; then
                                dialog_message "Resume storage recovery"                                         "The saved profile references encrypted storage on $backing, but the profile does not contain the MD member topology required to assemble it safely.\n\nThis can occur with a profile written before the Linear/JBOD recovery-topology fix. No destructive action was taken. Reassemble/open the existing stack once, then save/retry with the updated installer so complete recovery metadata is persisted."
                                return 1
                        fi
                done
        fi

        recover_saved_md_arrays || return 1
        recover_saved_luks_mappings || return 1
        recover_saved_vgs || return 1
        apply_storage_selections || return 1
        rebuild_btrfs_layout_from_saved_plan
        mount_or_reuse_target_filesystems || return 1
        return 0
}

load_installer_profile() {
        local path="${1:-$INSTALLER_PROFILE_FILE}" quiet="${2:-no}" line key raw value a b c d missing="" dev
        local -a missing_candidates=()

        [[ -f "$path" ]] || { dialog_message "Configuration profile" "Profile not found:\n$path"; return 1; }
        ADDITIONAL_USERS=()
        ADDITIONAL_USER_TYPES=()
        ADDITIONAL_USER_GROUPS=()
        STORAGE_DEVICES=(); STORAGE_FORMATS=(); STORAGE_MOUNTPOINTS=(); STORAGE_SUBVOLUMES=()
        RECOVERY_MD_ARRAYS=(); RECOVERY_MD_MEMBERS=(); RECOVERY_MD_UUIDS=()
        RECOVERY_LUKS_DEVICES=(); RECOVERY_LUKS_MAPPINGS=(); RECOVERY_VGS=()

        while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
                key="${line%%=*}"; raw="${line#*=}"
                [[ "$raw" != *'$('* && "$raw" != *'`'* ]] || continue
                eval "value=$raw"
                case "$key" in
                        HOSTNAME|TIMEZONE|LOCALE|USERNAME|ROOT_PASSWORD_POLICY|BOOT_MODE|BOOT_DISK|NETWORK_IFACE|NETWORK_MAC|NETWORK_TARGET_NAME|KERNEL_PACKAGE|INSTALL_GRUB|GRUB_FALLBACK|SAVE_BASE_ARCHIVE|BASE_ARCHIVE_DIR|ENABLE_OPENSSH|INSTALL_GIT|INSTALL_SUDO|SUDO_MODE|INSTALL_WGET|INSTALL_WPA_SUPPLICANT|INSTALL_GPM|INSTALL_LYNX|INSTALL_LINKS|INSTALL_NETWORKMANAGER|CONSOLE_VIDEO_MODE|SERIAL_CONSOLE|ZRAM_SIZE_SPEC|BUILD_JOBS|BUILD_OPT|BUILD_CCACHE|BUILD_CCACHE_SIZE|BUILD_TMPFS|BUILD_TMPFS_SIZE|ARCHIVE|ROOT_DEV|ROOT_FORMAT|BOOT_DEV|BOOT_FORMAT|EFI_DEV|EFI_FORMAT|SWAP_DEV|SWAP_FORMAT|HOME_DEV|HOME_FORMAT|ZRAM_SWAP)
                                printf -v "$key" '%s' "$value"
                                ;;
                        ADDITIONAL_USER)
                                # Backward-compatible profile entry: older profiles
                                # contained only regular/standard user names.
                                ADDITIONAL_USERS+=("$value")
                                ADDITIONAL_USER_TYPES+=("standard")
                                ADDITIONAL_USER_GROUPS+=("")
                                ;;
                        ADDITIONAL_USER_ENTRY)
                                IFS='|' read -r a b c <<<"$value"
                                ADDITIONAL_USERS+=("$a")
                                ADDITIONAL_USER_TYPES+=("${b:-standard}")
                                ADDITIONAL_USER_GROUPS+=("$c")
                                ;;
                        STORAGE)
                                IFS='|' read -r a b c d <<<"$value"
                                STORAGE_DEVICES+=("$a")
                                STORAGE_FORMATS+=("$b")
                                STORAGE_MOUNTPOINTS+=("$c")
                                STORAGE_SUBVOLUMES+=("$d")
                                ;;
                        RECOVERY_MD)
                                IFS='|' read -r a b c <<<"$value"
                                RECOVERY_MD_ARRAYS+=("$a")
                                RECOVERY_MD_MEMBERS+=("$b")
                                RECOVERY_MD_UUIDS+=("$c")
                                ;;
                        RECOVERY_LUKS)
                                IFS='|' read -r a b <<<"$value"
                                RECOVERY_LUKS_DEVICES+=("$a")
                                RECOVERY_LUKS_MAPPINGS+=("$b")
                                ;;
                        RECOVERY_VG) append_unique RECOVERY_VGS "$value" ;;
                esac
        done <"$path"

        # Profiles written by r48 and earlier did not store explicit subvolume
        # names. Reconstruct the deterministic BFSOS names for compatibility.
        while ((${#STORAGE_SUBVOLUMES[@]} < ${#STORAGE_DEVICES[@]})); do
                STORAGE_SUBVOLUMES+=("")
        done
        for ((a=0; a<${#STORAGE_DEVICES[@]}; a++)); do
                if [[ -z "${STORAGE_SUBVOLUMES[$a]}" ]]; then
                        STORAGE_SUBVOLUMES[$a]="$(storage_subvolume_for_mountpoint \
                                "${STORAGE_FORMATS[$a]}" "${STORAGE_MOUNTPOINTS[$a]}")"
                fi
        done

        if [[ "$PROFILE_RECOVERY_MODE" == yes ]]; then
                # New r49 profiles have enough non-secret topology to restore
                # inactive MD/LUKS/LVM layers. Old r48 profiles may not; if the
                # leaf devices are already active, recovery can still continue.
                if ((${#RECOVERY_MD_ARRAYS[@]} || ${#RECOVERY_LUKS_MAPPINGS[@]} || ${#RECOVERY_VGS[@]})); then
                        recover_saved_storage_stack || return 1
                else
                        apply_storage_selections >/dev/null 2>&1 || true
                        rebuild_btrfs_layout_from_saved_plan
                        if [[ -n "$ROOT_DEV" && -b "$ROOT_DEV" ]]; then
                                mount_or_reuse_target_filesystems || return 1
                        fi
                fi
        fi

        missing_candidates=("${STORAGE_DEVICES[@]}" "$ROOT_DEV" "$BOOT_DEV" "$EFI_DEV" "$SWAP_DEV" "$HOME_DEV")
        while IFS= read -r dev; do
                [[ -n "$dev" ]] && missing+="$dev\\n"
        done < <(deduplicated_missing_devices "${missing_candidates[@]}")

        if [[ -n "$missing" ]]; then
                dialog_message "Profile validation" "Loaded profile, but these saved block devices are not currently present:\n\n$missing\nReview Storage before installing."
                DISKS_CONFIGURED=no
        elif ((${#STORAGE_DEVICES[@]})); then
                apply_storage_selections || true
                rebuild_btrfs_layout_from_saved_plan
                DISKS_CONFIGURED=yes
        fi
        recalculate_configuration_status
        INSTALLER_PROFILE_FILE="$path"
        [[ "$quiet" == yes ]] || dialog_message "Configuration profile" "Loaded installer configuration from:\n$path\n\nReview all selections before installation. Secrets will still be requested when needed."
}

recalculate_configuration_status() {
        # Recompute menu state after loading a profile instead of trusting stale
        # status flags from a previous installer session.
        DISKS_CONFIGURED=no
        if ((${#STORAGE_DEVICES[@]})); then
                apply_storage_selections >/dev/null 2>&1 && DISKS_CONFIGURED=yes || true
        elif [[ -n "$ROOT_DEV" && -b "$ROOT_DEV" ]]; then
                DISKS_CONFIGURED=yes
        fi

        ARCHIVE_CONFIGURED=$([[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] && echo yes || echo no)
        BASIC_SYSTEM_CONFIGURED=$([[ -n "$HOSTNAME" && -n "$TIMEZONE" && -n "$LOCALE" ]] && echo yes || echo no)
        USERS_CONFIGURED=$([[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && echo yes || echo no)
        KERNEL_CONFIGURED=$([[ -n "$KERNEL_PACKAGE" ]] && echo yes || echo no)
        NETWORK_CONFIGURED=$([[ -n "$NETWORK_IFACE" && -n "$NETWORK_TARGET_NAME" ]] && echo yes || echo no)
        SSH_CONFIGURED=yes
        ROOT_ACCOUNT_CONFIGURED=yes
        if [[ "$BASIC_SYSTEM_CONFIGURED" == yes &&
              "$USERS_CONFIGURED" == yes &&
              "$NETWORK_CONFIGURED" == yes &&
              "$ROOT_ACCOUNT_CONFIGURED" == yes &&
              "$SSH_CONFIGURED" == yes ]]; then
                SYSTEM_CONFIGURED=yes
        else
                SYSTEM_CONFIGURED=no
        fi
        PACKAGES_CONFIGURED=optional
        SUDO_CONFIGURED=default
        BOOTLOADER_CONFIGURED=$([[ "$INSTALL_GRUB" == yes || "$INSTALL_GRUB" == no ]] && echo yes || echo no)
}

save_resume_state() {
        save_installer_profile "$INSTALLER_RESUME_FILE" yes
}

persistent_installation_complete() {
        local state=""
        target_has_valid_base_system || return 1

        for state in base_extracted accounts_configured packages_complete system_config_complete bootloader_complete; do
                [[ -f "$TARGET/var/lib/bfs-installer/$state" ]] || return 1
        done

        # A completed bootloader checkpoint must correspond to real boot files
        # when GRUB was selected. Avoid declaring stale markers complete.
        if [[ "$INSTALL_GRUB" == yes ]]; then
                [[ -s "$TARGET/boot/grub/grub.cfg" ]] || return 1
                if [[ "$BOOT_MODE" == uefi ]]; then
                        [[ -s "$TARGET/boot/efi/EFI/BFS/grubx64.efi" ]] || return 1
                fi
        fi

        return 0
}

clear_previous_install_state() {
        local device="" status=0

        log "Clearing previous installer state for a fresh start"
        mkdir -p "$TARGET"

        # Read the saved non-secret selections without entering recovery mode.
        # This gives us the exact target/swap devices to clean up without
        # reactivating MD/LUKS/LVM merely to tear them down again.
        PROFILE_RECOVERY_MODE=no
        if ! load_installer_profile "$INSTALLER_RESUME_FILE" yes; then
                log "Warning: resume profile could not be fully parsed; continuing with target-mount cleanup"
        fi

        if findmnt -Rrn "$TARGET" 2>/dev/null | grep -q .; then
                log "Unmounting all previous installer target mounts below $TARGET"
                umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET" 2>/dev/null || status=1
        fi

        # Disable only swap recorded by this installer profile. Never use
        # swapoff -a here because unrelated host/live swap is not installer state.
        if [[ -n "$SWAP_DEV" ]]; then
                log "Disabling previous installer swap: $SWAP_DEV"
                swapoff "$SWAP_DEV" 2>/dev/null || true
        fi
        for device in "${STORAGE_DEVICES[@]}"; do
                [[ -n "$device" ]] || continue
                if swapon --noheadings --raw --show=NAME 2>/dev/null | grep -Fxq -- "$device"; then
                        log "Disabling previous installer swap: $device"
                        swapoff "$device" 2>/dev/null || status=1
                fi
        done

        command -v udevadm >/dev/null 2>&1 && udevadm settle || true

        # Never remove through a still-mounted target. If even lazy unmount did
        # not detach everything, keep the tree intact and require review.
        if findmnt -Rrn "$TARGET" 2>/dev/null | grep -q .; then
                log "Previous installer target still has mounted filesystems; leaving $TARGET intact"
                status=1
        else
                rm -rf --one-file-system "$TARGET" 2>/dev/null || status=1
                mkdir -p "$TARGET" || status=1
        fi

        rm -rf "$INSTALL_CHECKPOINT_DIR" 2>/dev/null || true
        clear_resume_state

        # Reset in-memory selections so the next menu pass cannot silently
        # inherit values from the abandoned installation.
        STORAGE_DEVICES=(); STORAGE_FORMATS=(); STORAGE_MOUNTPOINTS=(); STORAGE_SUBVOLUMES=()
        RECOVERY_MD_ARRAYS=(); RECOVERY_MD_MEMBERS=(); RECOVERY_MD_UUIDS=()
        RECOVERY_LUKS_DEVICES=(); RECOVERY_LUKS_MAPPINGS=(); RECOVERY_VGS=()
        ROOT_DEV=""; ROOT_FORMAT=keep; BOOT_DEV=""; BOOT_FORMAT=keep
        EFI_DEV=""; EFI_FORMAT=keep; SWAP_DEV=""; SWAP_FORMAT=keep
        HOME_DEV=""; HOME_FORMAT=keep
        DISKS_CONFIGURED=no
        INSTALLATION_ALREADY_COMPLETE=no

        if ((status != 0)); then
                dialog_message "Clear previous install state" \
                        "The cached installer state was cleared, but one or more target mounts/swap devices could not be cleanly released.\n\nNo filesystem signatures were erased and no partition was formatted. Use Storage maintenance to review/deactivate the remaining stack before continuing."
        else
                dialog_message "Clear previous install state" \
                        "Previous installer cache/checkpoints were cleared, all installer target mounts were unmounted, and recorded target swap was disabled.\n\nNo filesystem signatures were erased. The installer will start fresh."
        fi
        return 0
}

choose_previous_install_action() {
        local choice=""
        themed_menu choice "Previous installation detected" \
                "A previous BFSOS installer state exists. Resume it, clear the cached state and unmount/deactivate its target storage, or cancel." \
                17 92 6 \
                1 "Resume previous installation" \
                2 "Clear previous install state and start fresh" \
                3 "Cancel"
        case "$choice" in
                1) printf '%s\n' resume ;;
                2)
                        confirm "Clear the previous installer cache/checkpoints and unmount/deactivate installer-managed target storage?\n\nThis does NOT format, wipe, or repartition storage." || { printf '%s\n' cancel; return 0; }
                        printf '%s\n' clear
                        ;;
                *) printf '%s\n' cancel ;;
        esac
}

load_resume_state_if_present() {
        local previous_action=""
        [[ -s "$INSTALLER_RESUME_FILE" ]] || return 0

        previous_action="$(choose_previous_install_action)"
        case "$previous_action" in
                clear)
                        clear_previous_install_state
                        return 0
                        ;;
                cancel)
                        log "Previous installation recovery cancelled by user"
                        exit 0
                        ;;
        esac

        RESUME_STATE_PRESENT=yes
        INSTALLATION_ALREADY_COMPLETE=no

        # Explain recovery before any storage work or LUKS password prompt.
        # This avoids surprising the user with a cryptsetup prompt before they
        # have been told that a previous installation is being restored.
        dialog_message "Previous installation detected" \
                "A previous BFSOS installation state was found.\n\nThe installer will now reconstruct its saved non-secret storage topology in dependency order (MD RAID -> LUKS -> LVM -> filesystems/Btrfs subvolumes).\n\nIf encrypted storage is closed, you will be asked for the required LUKS passphrase(s). Passphrases are never stored.\n\nNo formatting, repartitioning, RAID creation, or other destructive recovery action will be performed."

        PROFILE_RECOVERY_MODE=yes
        if ! load_installer_profile "$INSTALLER_RESUME_FILE" yes; then
                PROFILE_RECOVERY_MODE=no
                SESSION_FAILURE_STATUS=1
                dialog_message "Resume previous installation" \
                        "A previous installation was detected, but its saved storage stack could not be reconstructed automatically.\n\nNo destructive recovery action was taken. Review the storage error, reactivate the required layers if appropriate, and retry."
                return 0
        fi
        PROFILE_RECOVERY_MODE=no
        SESSION_FAILURE_STATUS=0

        ROOT_FORMAT=keep
        BOOT_FORMAT=keep
        EFI_FORMAT=keep
        SWAP_FORMAT=keep
        HOME_FORMAT=keep
        local i
        for ((i=0; i<${#EXTRA_FORMATS[@]}; i++)); do EXTRA_FORMATS[$i]=keep; done

        # The storage tree is now available. Restore the persistent checkpoint
        # view before deciding whether this is a real retry or merely stale
        # resume metadata left by a completed installation.
        restore_persistent_install_checkpoints

        if persistent_installation_complete; then
                INSTALLATION_ALREADY_COMPLETE=yes
                SESSION_FAILURE_STATUS=0
                clear_resume_state
                dialog_message "Installation already complete" \
                        "Storage recovery completed successfully.\n\nAll persistent installer completion checkpoints are present and the installed BFSOS base/boot files passed sanity checks.\n\nNo Install / Retry action is required. Stale resume metadata has been cleared.\n\nThe recovered target remains available for inspection or chroot during this installer session."
                return 0
        fi

        dialog_message "Recovery complete" \
                "The saved storage topology was restored successfully.\n\nExisting filesystems are forced to KEEP. The installation is incomplete, so use Install / Retry to continue from the first unfinished checkpoint."
}

clear_resume_state() {
        rm -f "$INSTALLER_RESUME_FILE"
        RESUME_STATE_PRESENT=no
}

profile_path_dialog() {
        local result_variable="$1" title="$2" value status=0
        value="$INSTALLER_PROFILE_FILE"
        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                value="$(dialog --stdout --clear --backtitle "BFSOS Installer" --title "$title" --inputbox "Configuration profile path:" 12 82 "$value" </dev/tty)" || status=$?
                ((status==0)) || return 1
        else
                read -r -p "Configuration profile [$value]: " value; value="${value:-$INSTALLER_PROFILE_FILE}"
        fi
        printf -v "$result_variable" '%s' "$value"
}

storage_device_is_protected() {
        local candidate="$1" source="" ancestor=""
        local -a protected_sources=()

        source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
        [[ -n "$source" ]] && protected_sources+=("$source")
        source="$(findmnt -T "$PROJECT_DIR" -n -o SOURCE 2>/dev/null || true)"
        [[ -n "$source" ]] && protected_sources+=("$source")
        source="$(findmnt -n -o SOURCE /run/initramfs/live 2>/dev/null || true)"
        [[ -n "$source" ]] && protected_sources+=("$source")

        for source in "${protected_sources[@]}"; do
                [[ "$candidate" == "$source" ]] && return 0
                while IFS= read -r ancestor; do
                        [[ "$candidate" == "$ancestor" ]] && return 0
                done < <(lsblk -s -prno PATH "$source" 2>/dev/null || true)
        done
        return 1
}

storage_reset_preview() {
        local tmp="$1"
        {
                echo "BFSOS storage maintenance preview"
                echo "================================"
                echo
                echo "Mounted filesystems below target:"
                findmnt -Rrn -o TARGET,SOURCE "$TARGET" 2>/dev/null || echo "  none"
                echo
                echo "Active swap:"
                swapon --show 2>/dev/null || echo "  none"
                echo
                echo "LVM:"
                pvs 2>/dev/null || true
                vgs 2>/dev/null || true
                lvs 2>/dev/null || true
                echo
                echo "LUKS/device-mapper mappings:"
                lsblk -prno PATH,TYPE,FSTYPE 2>/dev/null | awk '$2=="crypt" || $3=="crypto_LUKS"'
                echo
                echo "MD RAID:"
                cat /proc/mdstat 2>/dev/null || true
                echo
                echo "Detected MD metadata (active or inactive members):"
                if command -v mdadm >/dev/null 2>&1; then
                        mdadm --detail --scan 2>/dev/null || true
                        while IFS= read -r dev; do
                                [[ -b "$dev" ]] || continue
                                if mdadm --examine "$dev" >/dev/null 2>&1; then
                                        printf '  %s  %s\n' "$dev" "$(mdadm --examine "$dev" 2>/dev/null | awk -F: '/Raid Level|Array UUID|Name/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%s=%s ", $1, $2}')"
                                fi
                        done < <(lsblk -prno PATH,TYPE 2>/dev/null | awk '$2=="part"{print $1}')
                fi
        } >"$tmp"
}

storage_reset_deactivate() {
        local preserve_md="${1:-no}"
        local mapping="" array="" status=0 detail="" i=0
        local -a arrays=()

        # Unwind from the top of the storage stack downward.  Do not report
        # success if an MD array remains busy; that was masking the RAID6 test
        # failure and left the next installer run in an inconsistent state.
        if findmnt -Rrn "$TARGET" 2>/dev/null | grep -q .; then
                umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET" 2>/dev/null || status=1
        fi
        swapoff -a 2>/dev/null || status=1

        if command -v vgchange >/dev/null 2>&1; then
                vgchange -an 2>/dev/null || status=1
        fi

        if command -v cryptsetup >/dev/null 2>&1; then
                while IFS= read -r mapping; do
                        [[ -n "$mapping" ]] || continue
                        storage_device_is_protected "$mapping" && continue
                        if ! cryptsetup close "${mapping##*/}" 2>/dev/null; then
                                status=1
                                detail+="Could not close $mapping.\n"
                        fi
                done < <(lsblk -prno PATH,TYPE 2>/dev/null | awk '$2=="crypt"{print $1}' | tac)
        fi

        command -v udevadm >/dev/null 2>&1 && udevadm settle || true

        if [[ "$preserve_md" != yes ]] && command -v mdadm >/dev/null 2>&1; then
                # Include every active non-protected MD array. This maintenance
                # action is explicitly requested by the user; protected live/project
                # storage is still excluded by storage_device_is_protected().
                while IFS= read -r array; do
                        [[ -n "$array" ]] || continue
                        arrays+=("$array")
                done < <(list_active_md_arrays)

                for ((i=${#arrays[@]}-1; i>=0; i--)); do
                        array="${arrays[$i]}"
                        storage_device_is_protected "$array" && continue
                        if ! mdadm --stop "$array" 2>/dev/null; then
                                command -v udevadm >/dev/null 2>&1 && udevadm settle || true
                                if ! mdadm --stop "$array" 2>/dev/null; then
                                        status=1
                                        detail+="Could not stop $array; a filesystem, LVM VG, or dm-crypt mapping may still be using it.\n"
                                fi
                        fi
                done
        fi
        command -v udevadm >/dev/null 2>&1 && udevadm settle || true

        if ((status != 0)); then
                dialog_message "Storage deactivation incomplete" "One or more storage layers could not be deactivated.\n\n$detail\nInspect findmnt, pvs/vgs/lvs, cryptsetup status, and /proc/mdstat before retrying."
                return 1
        fi
        return 0
}

storage_reset_destroy_metadata() {
        local -a candidates=()
        local -a active_md_before=()
        local -A active_md_members_before=()
        local -A seen_candidates=()
        local dev="" member="" choice="" status=0
        local live_root="" project_source="" size="" fstype="" detail="" canonical=""

        # Snapshot the active MD topology BEFORE changing any upper storage layer.
        # This prevents array-level signatures (for example LUKS on /dev/md127)
        # from disappearing from discovery if udev/stack changes occur while
        # mounts, VGs, or dm-crypt mappings are being unwound.
        while IFS= read -r dev; do
                [[ -n "$dev" && -b "$dev" ]] || continue
                canonical="$(readlink -f -- "$dev" 2>/dev/null || printf '%s' "$dev")"
                active_md_before+=("$canonical")

                while IFS= read -r member; do
                        [[ -n "$member" ]] || continue
                        member="$(readlink -f -- "$member" 2>/dev/null || printf '%s' "$member")"
                        active_md_members_before["$member"]=1
                done < <(
                        local base="${canonical##*/}" slave=""
                        shopt -s nullglob
                        for slave in "/sys/class/block/$base/slaves/"*; do
                                [[ -e "$slave" ]] || continue
                                printf '/dev/%s\n' "${slave##*/}"
                        done
                        shopt -u nullglob
                )
        done < <(list_active_md_arrays)

        # Unmount filesystems, disable swap, deactivate VGs, and close dm-crypt
        # mappings, but deliberately keep MD arrays assembled. The array device
        # itself is what carries an array-level LUKS/LVM/filesystem signature.
        if ! storage_reset_deactivate yes; then
                return 0
        fi

        live_root="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
        project_source="$(findmnt -T "$PROJECT_DIR" -n -o SOURCE 2>/dev/null || true)"

        # First add the snapshotted active MD arrays explicitly. Do not depend on
        # lsblk TYPE strings, /proc/mdstat field positions, or a later rescan.
        for dev in "${active_md_before[@]}"; do
                [[ -b "$dev" ]] || continue
                storage_device_is_protected "$dev" && continue
                [[ "$dev" != "$live_root" && "$dev" != "$project_source" ]] || continue
                findmnt -rn -S "$dev" >/dev/null 2>&1 && continue

                size="$(lsblk -dnro SIZE "$dev" 2>/dev/null | head -n1)"
                fstype="$(lsblk -dnro FSTYPE "$dev" 2>/dev/null | head -n1)"
                detail="${fstype:-no-filesystem}"

                # An active MD array is useful here only when it actually exposes
                # wipeable array-level metadata. This keeps the checklist focused.
                if command -v wipefs >/dev/null 2>&1 &&
                   ! wipefs -n "$dev" 2>/dev/null | grep -q .; then
                        continue
                fi

                canonical="$(readlink -f -- "$dev" 2>/dev/null || printf '%s' "$dev")"
                [[ -z "${seen_candidates[$canonical]:-}" ]] || continue
                seen_candidates["$canonical"]=1
                candidates+=("$canonical" "${size:-?}  Active MD array; $detail")
        done

        # Then discover ordinary unmounted devices. Active MD member partitions
        # are intentionally suppressed while their array is assembled; wiping
        # their superblocks is a separate operation that requires stopping MD.
        while IFS= read -r dev; do
                [[ -b "$dev" ]] || continue
                canonical="$(readlink -f -- "$dev" 2>/dev/null || printf '%s' "$dev")"
                [[ -z "${seen_candidates[$canonical]:-}" ]] || continue
                [[ -z "${active_md_members_before[$canonical]:-}" ]] || continue
                storage_device_is_protected "$canonical" && continue
                [[ "$canonical" != "$live_root" && "$canonical" != "$project_source" ]] || continue
                findmnt -rn -S "$canonical" >/dev/null 2>&1 && continue

                size="$(lsblk -dnro SIZE "$canonical" 2>/dev/null | head -n1)"
                fstype="$(lsblk -dnro FSTYPE "$canonical" 2>/dev/null | head -n1)"
                detail="${fstype:-no-filesystem}"

                if command -v mdadm >/dev/null 2>&1 &&
                   mdadm --examine "$canonical" >/dev/null 2>&1; then
                        detail="MD RAID member; ${detail}"
                elif command -v pvs >/dev/null 2>&1 &&
                     pvs --noheadings "$canonical" >/dev/null 2>&1; then
                        detail="LVM PV; ${detail}"
                elif command -v wipefs >/dev/null 2>&1 &&
                     ! wipefs -n "$canonical" 2>/dev/null | grep -q .; then
                        continue
                fi

                seen_candidates["$canonical"]=1
                candidates+=("$canonical" "${size:-?}  $detail")
        done < <(
                lsblk -prno PATH,TYPE 2>/dev/null |
                        awk '$2=="part" || $2=="crypt" {print $1}'
        )

        ((${#candidates[@]})) || {
                local md_diag=""
                if ((${#active_md_before[@]})); then
                        md_diag="\n\nActive MD arrays were detected but none passed the safe-candidate checks:\n$(printf '  %s\n' "${active_md_before[@]}")"
                fi
                dialog_message "Storage reset" "No safe unmounted storage candidates were found.${md_diag}"
                return 0
        }

        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                local -a checklist=()
                local i
                for ((i=0;i<${#candidates[@]};i+=2)); do
                        checklist+=("${candidates[$i]}" "${candidates[$((i+1))]}" off)
                done
                choice="$(dialog --stdout --separate-output --clear \
                        --backtitle "BFSOS Installer" --title "Destroy storage metadata" \
                        --checklist "Select only devices whose old RAID/LUKS/LVM/filesystem metadata should be erased.\n\nActive MD arrays are kept assembled so array-level signatures can be selected safely. Active MD member partitions are hidden until the array is stopped.\n\nThe live root and BFSOS project filesystem are excluded automatically." \
                        26 112 15 "${checklist[@]}" </dev/tty)" || return 0
        else
                dialog_message "Storage reset" "Destructive metadata reset requires Dialog mode so devices can be selected explicitly."
                return 0
        fi

        [[ -n "$choice" ]] || return 0
        confirm "DESTROY signatures/metadata on these selected devices?\n\n$choice\n\nThis cannot be undone." || return 0

        status=0
        while IFS= read -r dev; do
                [[ -b "$dev" ]] || { status=1; continue; }

                if is_md_block_device "$dev"; then
                        # Selecting /dev/mdX means clear only the metadata exposed
                        # by the assembled array (LUKS/LVM/filesystem). Do NOT zero
                        # MD superblocks on its member devices.
                        pvremove -ff -y "$dev" 2>/dev/null || true
                        if ! wipefs -a "$dev"; then
                                status=1
                        fi
                else
                        # For an inactive member/non-array device, removing stale MD
                        # superblocks is appropriate when the user selected it.
                        mdadm --zero-superblock --force "$dev" 2>/dev/null || true
                        pvremove -ff -y "$dev" 2>/dev/null || true
                        if ! wipefs -a "$dev"; then
                                status=1
                        fi
                fi

                if wipefs -n "$dev" 2>/dev/null | grep -q .; then
                        status=1
                fi
        done <<<"$choice"

        refresh_storage_state
        if ((status != 0)); then
                dialog_message "Storage reset incomplete" \
                        "One or more selected devices still contain detectable metadata or could not be wiped.\n\nRe-scan with wipefs -n, lsblk, /proc/mdstat, and mdadm --examine before continuing."
                return 1
        fi

        dialog_message "Storage reset" \
                "Selected storage metadata was removed.\n\nActive MD arrays were preserved unless you previously stopped them. Re-scan with lsblk, /proc/mdstat, and mdadm --examine before starting a new install."
}

storage_reset_menu() {
        local choice="" tmp=""
        tmp="$(mktemp /tmp/bfs-storage-reset-preview.XXXXXX)"
        storage_reset_preview "$tmp"
        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear --backtitle "BFSOS Installer" --title "Existing storage state" \
                        --textbox "$tmp" 26 116 </dev/tty >/dev/tty 2>/dev/tty || true
        fi
        rm -f "$tmp"

        themed_menu choice "Storage maintenance" \
                "Choose a storage cleanup mode. Nothing destructive runs automatically." \
                17 86 6 \
                1 "Deactivate only — unmount, swapoff, deactivate VGs, close LUKS, stop MD" \
                2 "Destroy selected metadata — explicit device checklist + wipefs" \
                3 "Back"
        case "$choice" in
                1)
                        confirm "Deactivate currently active target storage now?\n\nNo signatures will be erased." || return 0
                        if storage_reset_deactivate; then
                                dialog_message "Storage maintenance" "Storage was deactivated, including active non-protected MD arrays."
                        fi
                        ;;
                2) storage_reset_destroy_metadata ;;
                *) return 0 ;;
        esac
}

physical_ram_gib() {
        local kb=0
        kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '0')"
        [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
        printf '%s\n' "$(( (kb + 1048575) / 1048576 ))"
}

recommended_build_tmpfs_size() {
        local gib=0
        gib="$(physical_ram_gib)"
        if ((gib < 16)); then
                printf '%s\n' "disabled"
        elif ((gib < 32)); then
                printf '%s\n' "8G"
        elif ((gib < 48)); then
                printf '%s\n' "16G"
        elif ((gib < 96)); then
                printf '%s\n' "32G"
        elif ((gib < 192)); then
                printf '%s\n' "64G"
        else
                printf '%s\n' "96G"
        fi
}

build_work_mode_display() {
        if [[ "$BUILD_TMPFS" != yes ]]; then
                printf '%s' "Disk-backed"
        elif [[ "$BUILD_TMPFS_SIZE" == auto ]]; then
                printf '%s' "Auto ($(recommended_build_tmpfs_size))"
        else
                printf '%s' "Custom tmpfs ($BUILD_TMPFS_SIZE)"
        fi
}

configure_build_work_mode() {
        local choice="" value="" recommended=""
        recommended="$(recommended_build_tmpfs_size)"
        themed_menu choice "Package build workspace" \
                "Choose how /var/cache/pkg/build-work is provided. Auto is based on physical RAM only (swap is not counted). tmpfs sizes are ceilings and are allocated on demand." \
                20 94 6 \
                1 "Auto (recommended: $recommended)" \
                2 "Disk-backed" \
                3 "Custom tmpfs size" \
                4 "Back"
        case "$choice" in
                1)
                        BUILD_TMPFS=yes
                        BUILD_TMPFS_SIZE=auto
                        ;;
                2)
                        BUILD_TMPFS=no
                        BUILD_TMPFS_SIZE=auto
                        ;;
                3)
                        themed_inputbox value "Custom build-work tmpfs" \
                                "Enter a tmpfs ceiling such as 8G, 16G, 32G, 64G, or 96G. This is not preallocated RAM. BFSOS will not include swap when choosing Auto." \
                                "$([[ "$BUILD_TMPFS_SIZE" == auto ]] && printf '%s' "$recommended" || printf '%s' "$BUILD_TMPFS_SIZE")" || return 0
                        [[ "$value" =~ ^[1-9][0-9]*[GgMm]$ ]] || {
                                dialog_message "Invalid tmpfs size" "Use a positive size ending in G or M, for example 32G."
                                return 0
                        }
                        BUILD_TMPFS=yes
                        BUILD_TMPFS_SIZE="$value"
                        ;;
                *) return 0 ;;
        esac
}

compiler_build_settings_menu() {
        local choice="" value="" recommended=""
        while true; do
                recommended="$(recommended_build_tmpfs_size)"
                themed_menu choice "Compiler / Build Settings" \
                        "Integrity checks are ON by default. Disable them only deliberately for development/testing. RAM build workspace affects only disposable pkgmk work files; sources, packages, and ccache stay persistent." \
                        30 108 13 \
                        1 "Build jobs: $BUILD_JOBS" \
                        2 "Optimization: $BUILD_OPT" \
                        3 "ccache: $BUILD_CCACHE" \
                        4 "ccache size: $BUILD_CCACHE_SIZE" \
                        5 "Build-work mode: $(build_work_mode_display)" \
                        6 "Verify MD5/checksums: $VERIFY_MD5" \
                        7 "Verify signatures: $VERIFY_SIGNATURE" \
                        8 "Verify footprints: $VERIFY_FOOTPRINT" \
                        9 "Restore inherited/default build values" \
                        10 "Back"
                case "$choice" in
                        1) themed_inputbox value "Build jobs" "Enter inherited, auto, or a positive job count." "$BUILD_JOBS" && BUILD_JOBS="$value" ;;
                        2) themed_menu value "Optimization" "Choose installed-system compiler tuning." 18 80 5 1 "inherited" 2 "portable (-O2 -march=x86-64 -pipe)" 3 "native (-O2 -march=native -mtune=native -pipe)" 4 "Back"; case "$value" in 1) BUILD_OPT=inherited;;2) BUILD_OPT=portable;;3) BUILD_OPT=native;;esac ;;
                        3) [[ "$BUILD_CCACHE" == yes ]] && BUILD_CCACHE=no || BUILD_CCACHE=yes ;;
                        4) themed_inputbox value "ccache size" "Enter inherited, auto, 20G, 64G, etc. Auto = 20G in VMs; physical-RAM-sized on bare metal." "$BUILD_CCACHE_SIZE" && BUILD_CCACHE_SIZE="$value" ;;
                        5) configure_build_work_mode ;;
                        6) [[ "$VERIFY_MD5" == yes ]] && VERIFY_MD5=no || VERIFY_MD5=yes ;;
                        7) [[ "$VERIFY_SIGNATURE" == yes ]] && VERIFY_SIGNATURE=no || VERIFY_SIGNATURE=yes ;;
                        8) [[ "$VERIFY_FOOTPRINT" == yes ]] && VERIFY_FOOTPRINT=no || VERIFY_FOOTPRINT=yes ;;
                        9) BUILD_JOBS=inherited; BUILD_OPT=inherited; BUILD_CCACHE=inherited; BUILD_CCACHE_SIZE=inherited; BUILD_TMPFS=yes; BUILD_TMPFS_SIZE=auto; VERIFY_MD5=yes; VERIFY_SIGNATURE=yes; VERIFY_FOOTPRINT=yes ;;
                        *) save_installer_settings; return 0 ;;
                esac
                save_installer_settings
        done
}

installer_settings_menu() {
        local choice="" status=0 path=""
        while true; do
                themed_menu choice "Installer Settings" \
                        "Configure interface, accessibility, logging, reusable profiles, and storage maintenance." \
                        25 92 11 \
                        1 "Theme: $(theme_display_name)" \
                        2 "Console / font: $(console_font_display_name); serial=$SERIAL_CONSOLE" \
                        3 "Logging: $LOG_ENABLED" \
                        4 "Compiler / build settings" \
                        5 "Save current configuration" \
                        6 "Save configuration as..." \
                        7 "Load configuration..." \
                        8 "Reset/deactivate existing storage..." \
                        9 "Back to main menu"
                [[ -n "$choice" ]] || return 0
                case "$choice" in
                        1) select_installer_theme ;;
                        2) configure_console_settings ;;
                        3)
                                [[ "$LOG_ENABLED" == yes ]] && LOG_ENABLED=no || LOG_ENABLED=yes
                                save_installer_settings
                                ;;
                        4) compiler_build_settings_menu ;;
                        5) save_installer_profile "$INSTALLER_PROFILE_FILE" ;;
                        6) path=""; profile_path_dialog path "Save configuration as" && save_installer_profile "$path" ;;
                        7) path=""; profile_path_dialog path "Load configuration" && load_installer_profile "$path" ;;
                        8) storage_reset_menu ;;
                        9) return 0 ;;
                        *) warn "Invalid settings selection."; sleep 1 ;;
                esac
        done
}

dialog_status() {
        case "$1" in
                yes) printf '%s' "CONFIGURED" ;;
                optional) printf '%s' "OPTIONAL" ;;
                default) printf '%s' "DEFAULT" ;;
                *) printf '%s' "PENDING" ;;
        esac
}

installer_ready() {
        # Only filesystem/mount-point assignment is required for storage.
        # Visiting cfdisk, RAID, LUKS, or LVM menus is never required.
        [[ "$DISKS_CONFIGURED" == yes &&
           "$ARCHIVE_CONFIGURED" == yes &&
           "$SYSTEM_CONFIGURED" == yes &&
           "$USERS_CONFIGURED" == yes &&
           "$KERNEL_CONFIGURED" == yes &&
           "$NETWORK_CONFIGURED" == yes &&
           "$BOOTLOADER_CONFIGURED" == yes ]]
}

target_chroot_available() {
        [[ -x "$TARGET/bin/bash" || -x "$TARGET/usr/bin/bash" ]]
}

available_status() {
        if "$@"; then
                printf '%s' "AVAILABLE"
        else
                printf '%s' "PENDING"
        fi
}

dialog_menu_description() {
        local label="$1" status="$2" rendered="$2"
        case "$status" in
                AVAILABLE|"RETRY AVAILABLE")
                        rendered="\Zb\Z3${status}\Zn"
                        ;;
                COMPLETE|CONFIGURED)
                        rendered="\Zb\Z2${status}\Zn"
                        ;;
                PENDING|INCOMPLETE|"NOT AVAILABLE")
                        rendered="\Zb\Z1${status}\Zn"
                        ;;
        esac
        printf '%-45s [%b]' "$label" "$rendered"
}

show_installer_help() {
        local topic="${1:-general}" text=""
        case "$topic" in
                storage)
                        text="Storage setup controls the target disk layout. Partitioning, RAID, LUKS, LVM, and formatting can destroy data. Existing partitions may be reused without formatting. Review the Filesystem plan before continuing and confirm that every device marked FORMAT is safe to erase."
                        ;;
                raid)
                        text="Software RAID combines multiple block devices into one /dev/md* device. Assemble existing arrays when you want to reuse them. Creating a new array can overwrite RAID metadata on selected members. Build the array first, then place LUKS, LVM, or a filesystem on the resulting /dev/md* device as needed."
                        ;;
                luks)
                        text="LUKS encrypts a block device and exposes an unlocked mapping under /dev/mapper. Creating a new LUKS container is destructive. Opening an existing container is non-destructive when the correct passphrase is supplied. Assign filesystems to the unlocked mapper device, not to the encrypted backing device."
                        ;;
                lvm)
                        text="LVM layers logical storage on top of physical volumes (PV), volume groups (VG), and logical volumes (LV). Typical order: create PVs, create a VG, then create LVs. Filesystems are assigned to the LV devices. Do not initialize a device as a PV unless its existing contents may be replaced."
                        ;;
                filesystem)
                        text="Each selected device needs a mount/use role and an action. Keep preserves the existing filesystem. Any Format action erases the selected device. A root filesystem mounted at / is required. UEFI installs normally use a FAT32 /boot/efi partition. Review the Filesystem plan before accepting it."
                        ;;
                zram)
                        text="ZRAM creates compressed swap in RAM. A percentage is the virtual ZRAM device size relative to physical RAM, not an immediate allocation of that amount of memory. Compression means values above 100% can be useful, but workloads and RAM size differ. ZRAM is optional and can be disabled."
                        ;;
                kernel)
                        text="linux-lts is the BFSOS default and prioritizes long-term stability. linux is the newer current kernel and may contain newer hardware support. Do not install a kernel only when you deliberately plan to provide and configure a kernel yourself."
                        ;;
                sudo)
                        text="Sudo lets authorized wheel-group users run administrative commands. Password mode requires the user's password and is the normal safer default. Passwordless wheel sudo is convenient but grants immediate root-level command access to wheel users. You may also choose not to install sudo."
                        ;;
                serial)
                        text="The serial troubleshooting console adds early-boot/kernel console output for debugging systems without a usable local display. Leave it disabled unless you use a serial console or need low-level boot diagnostics."
                        ;;
                base)
                        text="The base archive provides the BFSOS root filesystem. Download current fetches the active versioned base from the BFSOS SourceForge base/latest path and verifies its SHA256. Browse local is useful for offline installs or a maintainer-supplied archive."
                        ;;
                accounts)
                        text="A primary Standard user is required. Standard users receive the centralized BFSOS group policy. Root password login stays locked by default; choose the root password policy entry only if you want the installer to prompt for an optional root password. Blank password prompts always keep the account locked and never create an empty-password login."
                        ;;
                reset-storage)
                        text="Reset/deactivate existing storage is a maintenance/recovery action. It may unmount installer-managed filesystems and deactivate storage mappings. It must not format or wipe unrelated storage. Use it when stale installer state prevents a clean new installation."
                        ;;
                *)
                        text="Use Back to return one logical level. Destructive storage actions require confirmation. Review selections before installing."
                        ;;
        esac
        dialog_message "Help" "$text"
}

themed_menu() {
        local result_variable="$1"
        local title="$2"
        local prompt="$3"
        local height="$4"
        local width="$5"
        local menu_height="$6"
        shift 6

        # Do not call this local variable "choice". Bash uses dynamic scoping,
        # so a local choice here would hide the caller's choice variable and
        # prevent printf -v from returning the selected menu tag.
        local selected_value="" status=0 index=0
        local -a items=("$@")

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                if selected_value="$(
                        dialog --stdout --clear \
                                --backtitle "BFSOS Installer" \
                                --title "$title" \
                                --cancel-label "Back" \
                                --menu "$prompt" \
                                "$height" "$width" "$menu_height" \
                                "${items[@]}" \
                                </dev/tty
                )"; then
                        status=0
                else
                        status=$?
                fi

                if ((status != 0)); then
                        printf -v "$result_variable" '%s' ""
                        return 0
                fi
        else
                clear_screen
                printf '%s\n' "$title"
                printf '%*s\n\n' "${#title}" '' | tr ' ' '='
                printf '%s\n\n' "$prompt"

                for ((index=0; index<${#items[@]}; index+=2)); do
                        printf '  %s) %s\n' \
                                "${items[$index]}" \
                                "${items[$((index + 1))]}"
                done

                printf '\n'
                read -r -p "Choose: " selected_value
        fi

        selected_value="$(
                printf '%s' "$selected_value" |
                        tr -d '\r\n' |
                        sed -e 's/^[[:space:]]*//' \
                            -e 's/[[:space:]]*$//' \
                            -e 's/^"//' \
                            -e 's/"$//'
        )"

        printf -v "$result_variable" '%s' "$selected_value"
        return 0
}

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

clear_screen() {
        if command -v clear >/dev/null 2>&1; then
                clear
        else
                printf '\033[2J\033[H'
        fi
}

pause_screen() {
        printf '\n'
        read -r -p 'Press Enter to continue...' _
}


dialog_message() {
        local title="$1" message="$2"
        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear --backtitle "BFSOS Installer" --title "$title" \
                        --msgbox "$message" 18 84 </dev/tty >/dev/tty 2>/dev/tty || true
        else
                printf '\n%s\n%s\n\n%s\n' "$title" "$(printf '%*s' "${#title}" '' | tr ' ' '=')" "$message"
                pause_screen
        fi
}

dialog_password() {
        local result_variable="$1" title="$2" prompt="$3" value="" status=0
        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                set +e
                value="$(dialog --stdout --clear --insecure --backtitle "BFSOS Installer" \
                        --title "$title" --cancel-label "Back" --passwordbox "$prompt" 12 72 </dev/tty)"
                status=$?
                set -e
                ((status == 0)) || return 1
        else
                read -r -s -p "$prompt: " value </dev/tty
                printf '\n' >/dev/tty
        fi
        printf -v "$result_variable" '%s' "$value"
}

run_on_tty() {
        local status=0

        clear
        reset
        stty sane </dev/tty

        set +e
        "$@" </dev/tty >/dev/tty 2>/dev/tty
        status=$?
        set -e

        clear
        reset
        stty sane </dev/tty

        return "$status"
}

ask() {
        local variable="$1"
        local prompt="$2"
        local default="${3:-}"
        local answer=""
        local status=0

        [[ -n "${!variable:-}" ]] && return 0

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                if answer="$(
                        dialog --stdout --clear \
                                --backtitle "BFSOS Installer" \
                                --title "BFS configuration" \
                                --cancel-label "Back" \
                                --inputbox "$prompt" \
                                12 72 "$default" \
                                </dev/tty
                )"; then
                        status=0
                else
                        status=$?
                fi
                ((status == 0)) || return 1
        else
                if [[ -n "$default" ]]; then
                        read -r -p "$prompt [$default]: " answer
                        answer="${answer:-$default}"
                else
                        read -r -p "$prompt: " answer
                fi
        fi

        printf -v "$variable" '%s' "$answer"
}

ask_default() {
        local variable="$1"
        local prompt="$2"
        local default="$3"
        local answer=""
        local status=0

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                if answer="$(
                        dialog --stdout --clear \
                                --backtitle "BFSOS Installer" \
                                --title "BFS configuration" \
                                --cancel-label "Back" \
                                --inputbox "$prompt" \
                                12 72 "$default" \
                                </dev/tty
                )"; then
                        status=0
                else
                        status=$?
                fi
                ((status == 0)) || return 1
        else
                read -r -p "$prompt [$default]: " answer
                answer="${answer:-$default}"
        fi

        printf -v "$variable" '%s' "${answer:-$default}"
}

ask_yes_no() {
        local variable="$1"
        local prompt="$2"
        local default="${3:-no}"
        local answer=""
        local status=0

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                local -a default_button=()
                [[ "$default" == no ]] && default_button=(--defaultno)

                if dialog --clear \
                        --backtitle "BFSOS Installer" \
                        --title "BFS configuration" \
                        "${default_button[@]}" \
                        --yesno "$prompt" \
                        11 72 \
                        </dev/tty >/dev/tty 2>/dev/tty; then
                        printf -v "$variable" '%s' yes
                else
                        status=$?
                        case "$status" in
                                1) printf -v "$variable" '%s' no ;;
                                255) return 1 ;;
                                *) return 1 ;;
                        esac
                fi
        else
                local suffix="[y/N]"
                [[ "$default" == yes ]] && suffix="[Y/n]"
                read -r -p "$prompt $suffix: " answer
                answer="${answer,,}"
                if [[ -z "$answer" ]]; then
                        printf -v "$variable" '%s' "$default"
                elif [[ "$answer" == y || "$answer" == yes ]]; then
                        printf -v "$variable" '%s' yes
                else
                        printf -v "$variable" '%s' no
                fi
        fi
}

confirm() {
        local prompt="$1"
        local answer=""

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear \
                        --backtitle "BFSOS Installer" \
                        --title "Confirm" \
                        --defaultno \
                        --yesno "$prompt" \
                        11 76 \
                        </dev/tty >/dev/tty 2>/dev/tty
                return $?
        fi

        read -r -p "$prompt [y/N]: " answer
        [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

confirm_continue() {
        local prompt="$1" answer=""
        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear \
                        --backtitle "BFSOS Installer" \
                        --title "Ready to install" \
                        --yes-label "Continue" \
                        --no-label "Back" \
                        --defaultno \
                        --yesno "$prompt" 11 76 \
                        </dev/tty >/dev/tty 2>/dev/tty
                return $?
        fi
        read -r -p "$prompt [y/N]: " answer
        [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

usage() {
        cat <<'USAGE'
Usage: install-bfs-menu-current.sh [options]

The installer may be started as a regular user. It authenticates with sudo
once, then re-executes the full installer as root.

Options:
  --log                  Enable automatic logging (default)
  --no-log               Disable automatic logging
  --log-file PATH        Use PATH for the live-environment log
  --large-console        Use a 20-pixel console font for this run only
  --console-font SIZE    Runtime console font: default, 16, or 20
  --console-font=SIZE    Same as above
  -h, --help             Show this help
USAGE
}

parse_arguments() {
        while (($#)); do
                case "$1" in
                        --log)
                                LOG_ENABLED=yes
                                shift
                                ;;
                        --no-log)
                                LOG_ENABLED=no
                                shift
                                ;;
                        --log-file)
                                (($# >= 2)) || die "--log-file requires a path."
                                LOG_ENABLED=yes
                                LOG_FILE="$2"
                                shift 2
                                ;;
                        --large-console)
                                CONSOLE_FONT_OVERRIDE=20
                                shift
                                ;;
                        --console-font)
                                (($# >= 2)) || die "--console-font requires default, 16, or 20."
                                case "$2" in default|16|20) CONSOLE_FONT_OVERRIDE="$2" ;; *) die "Invalid console font size: $2" ;; esac
                                shift 2
                                ;;
                        --console-font=*)
                                case "${1#*=}" in default|16|20) CONSOLE_FONT_OVERRIDE="${1#*=}" ;; *) die "Invalid console font size: ${1#*=}" ;; esac
                                shift
                                ;;
                        -h|--help)
                                usage
                                exit 0
                                ;;
                        *)
                                die "Unknown option: $1"
                                ;;
                esac
        done
}

setup_logging() {
        [[ "$LOG_ENABLED" == yes ]] || return 0

        mkdir -p "$INSTALLER_LOG_DIR"

        if [[ -z "$LOG_FILE" ]]; then
                LOG_FILE="$INSTALLER_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
        elif [[ "$LOG_FILE" != /* ]]; then
                LOG_FILE="$INSTALLER_LOG_DIR/$LOG_FILE"
        fi

        mkdir -p "$(dirname "$LOG_FILE")"
        : > "$LOG_FILE"

        LOG_STARTED_EPOCH="$(date +%s)"
        LOG_CLOSED=no

        LOG_FIFO="$(mktemp -u /tmp/bfs-install-log.XXXXXX)"
        mkfifo "$LOG_FIFO"

        exec 3>&1 4>&2
        tee -a "$LOG_FILE" < "$LOG_FIFO" >&3 &
        LOG_TEE_PID=$!
        exec > "$LOG_FIFO" 2>&1

        printf '%s\n' '============================================================'
        printf '%s\n' 'BFSOS Installer'
        printf 'Started:        %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf 'Script:         %s\n' "${BASH_SOURCE[0]}"
        printf 'Script path:    %s\n' "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
        printf 'Log file:       %s\n' "$LOG_FILE"
        printf 'Host:           %s\n' "$(hostname 2>/dev/null || printf unknown)"
        printf 'Kernel:         %s\n' "$(uname -r 2>/dev/null || printf unknown)"
        printf 'Architecture:   %s\n' "$(uname -m 2>/dev/null || printf unknown)"
        printf 'Installer PID:  %s\n' "$$"
        printf 'Target:         %s\n' "$TARGET"
        printf 'Locale runtime: LANG=%s LC_ALL=%s LANGUAGE=%s\n' \
                "${LANG:-}" "${LC_ALL:-}" "${LANGUAGE:-}"
        printf '%s\n' '============================================================'
}

close_logging() {
        local status="${1:-0}"
        local ended_epoch=""
        local elapsed=0
        local result="SUCCESS"

        [[ "$LOG_ENABLED" == yes ]] || return 0
        [[ "$LOG_CLOSED" == no ]] || return 0
        [[ -n "$LOG_TEE_PID" ]] || return 0

        ended_epoch="$(date +%s)"
        if [[ -n "$LOG_STARTED_EPOCH" ]]; then
                elapsed=$((ended_epoch - LOG_STARTED_EPOCH))
        fi

        [[ "$status" -eq 0 ]] || result="FAILED"

        printf '\n%s\n' '============================================================'
        printf 'Finished:       %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf 'Result:         %s\n' "$result"
        printf 'Exit status:    %s\n' "$status"
        printf 'Elapsed:        %02d:%02d:%02d\n' \
                "$((elapsed / 3600))" \
                "$(((elapsed % 3600) / 60))" \
                "$((elapsed % 60))"
        printf '%s\n' '============================================================'

        exec 1>&3 2>&4
        wait "$LOG_TEE_PID" 2>/dev/null || true
        rm -f "$LOG_FIFO"

        LOG_FIFO=""
        LOG_TEE_PID=""
        LOG_CLOSED=yes
}

copy_log_to_installed_system() {
        local installed_dir=""
        local installed_log=""

        [[ "$LOG_ENABLED" == yes && -f "$LOG_FILE" ]] || return 0
        [[ -d "$TARGET" ]] || return 0

        installed_dir="$TARGET/var/log/bfs/installer"
        mkdir -p "$installed_dir"

        installed_log="$installed_dir/$(basename "$LOG_FILE")"
        cp -f "$LOG_FILE" "$installed_log"
        chmod 0600 "$installed_log"

        printf 'Installed-system log: /var/log/bfs/installer/%s\n' \
                "$(basename "$LOG_FILE")"
}

require_root() {
        if [[ $EUID -eq 0 ]]; then
                force_posix_locale
                return 0
        fi

        command -v sudo >/dev/null 2>&1 ||
                die "This installer requires root privileges and sudo is unavailable."

        printf '\nThis installer requires root privileges.\n'
        printf 'Authenticating with sudo before the installer starts...\n'
        printf 'The complete installer session will then run as root.\n\n'

        sudo -v || die "sudo authentication failed."

        exec sudo \
                --preserve-env=TERM,BFS_INSTALLER_THEME,BFS_LOG_ENABLED,BFS_LOG_FILE \
                env \
                LANG=C \
                LC_ALL=C \
                LANGUAGE=C \
                "$0" "$@"
}

require_commands() {
        local command
        for command in mount umount mountpoint findmnt lsblk swapoff swapon tar chroot blkid sed awk grep install readlink sha256sum find sort head cut tee mkfifo mktemp date cp dirname; do
                command -v "$command" >/dev/null 2>&1 || die "Missing host command: $command"
        done
}

prepare_target_environment() {
        log "Preparing clean installer mount state"

        # A previous failed run may have left bind mounts nested under TARGET.
        if findmnt -Rrn "$TARGET" 2>/dev/null | grep -q .; then
                warn "Existing mounts were found under $TARGET; unmounting them."
                umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET" 2>/dev/null || \
                        die "Could not unmount everything below $TARGET."
        fi

        if findmnt -Rrn "$TARGET" 2>/dev/null | grep -q .; then
                die "A filesystem is still mounted below $TARGET."
        fi

        # Live media normally does not need swap. Turning it all off prevents a
        # selected swap partition from remaining busy during mkswap.
        if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
                log "Disabling active swap before partition selection"
                swapoff -a || die "Could not disable all active swap devices."
        fi

        mkdir -p "$TARGET"
}

is_used_device() {
        local wanted="$1" used
        for used in "${USED_DEVICES[@]}"; do
                [[ "$used" == "$wanted" ]] && return 0
        done
        return 1
}

get_available_partitions() {
        local path type size fstype label mountpoints
        local lv_path=""
        local -A seen_paths=()

        AVAILABLE_PATHS=()
        AVAILABLE_TYPES=()
        AVAILABLE_SIZES=()
        AVAILABLE_FSTYPES=()
        AVAILABLE_LABELS=()
        AVAILABLE_MOUNTPOINTS=()
        AVAILABLE_NICS=()
        AVAILABLE_NIC_MACS=()
        AVAILABLE_NIC_STATES=()
        AVAILABLE_NIC_DRIVERS=()

        # First collect ordinary usable block devices. Do not show RAID-member
        # partitions or an MD device that has already become an LVM PV.
        #
        # LVM devices are intentionally excluded here because lsblk commonly
        # exposes the same LV through /dev/mapper/<vg>-<lv>. We add LVs once,
        # below, using the friendlier canonical paths reported by `lvs`
        # (for example /dev/bfs-vg/home).
        while read -r path type size fstype label mountpoints; do
                if [[ "$type" != part && "$type" != crypt && "$type" != raid* ]] &&
                   ! is_md_block_device "$path"; then
                        continue
                fi

                case "$fstype" in
                        linux_raid_member|LVM2_member|crypto_LUKS)
                                # A LUKS header is a storage layer, not a filesystem target.
                                # Format/mount the active /dev/mapper device (or descendants) instead.
                                continue
                                ;;
                esac

                # An assembled MD member is not an independent filesystem target.
                # This structural check also catches Linear/JBOD members whose
                # FSTYPE may appear blank while the array is active.
                is_active_md_member "$path" && continue

                is_used_device "$path" && continue
                [[ -n "${seen_paths[$path]:-}" ]] && continue
                seen_paths["$path"]=1

                AVAILABLE_PATHS+=("$path")
                AVAILABLE_TYPES+=("$type")
                AVAILABLE_SIZES+=("${size:--}")
                AVAILABLE_FSTYPES+=("${fstype:--}")
                AVAILABLE_LABELS+=("${label:--}")
                AVAILABLE_MOUNTPOINTS+=("${mountpoints:--}")
        done < <(
                lsblk -plno PATH,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS |
                awk '{p=$1;t=$2;s=$3;f=$4;l=$5;$1=$2=$3=$4=$5="";sub(/^ +/,"");print p,t,s,f,l,$0}'
        )

        # A previous installer run/cleanup may have deactivated an existing VG.
        # Activate discovered volume groups before enumerating LVs so their
        # /dev/<vg>/<lv> block-device nodes exist for filesystem assignment.
        if command -v vgchange >/dev/null 2>&1; then
                vgchange -ay >/dev/null 2>&1 || true
                command -v udevadm >/dev/null 2>&1 && udevadm settle || true
        fi

        # Query LVM directly and add each logical volume exactly once using
        # LVM's friendly /dev/<vg>/<lv> path. This avoids duplicate aliases such
        # as /dev/mapper/bfs--vg-home and /dev/bfs-vg/home appearing together.
        if command -v lvs >/dev/null 2>&1; then
                while IFS= read -r lv_path; do
                        lv_path="${lv_path#"${lv_path%%[![:space:]]*}"}"
                        lv_path="${lv_path%"${lv_path##*[![:space:]]}"}"
                        [[ -n "$lv_path" && -b "$lv_path" ]] || continue
                        is_used_device "$lv_path" && continue
                        [[ -n "${seen_paths[$lv_path]:-}" ]] && continue

                        path="$lv_path"
                        type="lvm"
                        size="$(lsblk -dnro SIZE "$lv_path" 2>/dev/null | head -n1)"
                        fstype="$(lsblk -dnro FSTYPE "$lv_path" 2>/dev/null | head -n1)"
                        label="$(lsblk -dnro LABEL "$lv_path" 2>/dev/null | head -n1)"
                        mountpoints="$(lsblk -dnro MOUNTPOINTS "$lv_path" 2>/dev/null | head -n1)"

                        seen_paths["$path"]=1
                        AVAILABLE_PATHS+=("$path")
                        AVAILABLE_TYPES+=("$type")
                        AVAILABLE_SIZES+=("${size:--}")
                        AVAILABLE_FSTYPES+=("${fstype:--}")
                        AVAILABLE_LABELS+=("${label:--}")
                        AVAILABLE_MOUNTPOINTS+=("${mountpoints:--}")
                done < <(
                        lvs --noheadings -o lv_path 2>/dev/null || true
                )
        fi
}

show_available_partitions() {
        local index
        get_available_partitions

        printf '\nAvailable partitions not yet assigned:\n'
        printf '  %-4s %-24s %-9s %-10s %-12s %-16s %s\n' \
                NUM DEVICE TYPE SIZE FSTYPE LABEL MOUNTPOINTS

        for ((index=0; index<${#AVAILABLE_PATHS[@]}; index++)); do
                printf '  %-4d %-24s %-9s %-10s %-12s %-16s %s\n' \
                        "$((index + 1))" \
                        "${AVAILABLE_PATHS[$index]}" \
                        "${AVAILABLE_TYPES[$index]}" \
                        "${AVAILABLE_SIZES[$index]}" \
                        "${AVAILABLE_FSTYPES[$index]}" \
                        "${AVAILABLE_LABELS[$index]}" \
                        "${AVAILABLE_MOUNTPOINTS[$index]}"
        done
        printf '\n'
}

select_partition() {
        local variable="$1"
        local prompt="$2"
        local optional="${3:-no}"
        local optional_label="${4:-Skip this partition}"
        local answer=""
        local selected_index=""
        local selected_device=""
        local status=0
        local index=0
        local -a menu_items=()

        if [[ -n "${!variable:-}" ]]; then
                USED_DEVICES+=("${!variable}")
                return 0
        fi

        while true; do
                get_available_partitions
                if ((${#AVAILABLE_PATHS[@]} == 0)); then
                        dialog_message "No usable partitions" \
                                "No usable partitions are currently available.\n\nCreate a partition table and partitions from the storage/partitioning menu, then rescan and try again."
                        return 2
                fi

                menu_items=()

                if [[ "$optional" == yes ]]; then
                        menu_items+=(0 "$optional_label")
                fi

                for ((index=0; index<${#AVAILABLE_PATHS[@]}; index++)); do
                        menu_items+=(
                                "$((index + 1))"
                                "${AVAILABLE_PATHS[$index]}  ${AVAILABLE_SIZES[$index]}  ${AVAILABLE_FSTYPES[$index]}  ${AVAILABLE_LABELS[$index]}"
                        )
                done
                menu_items+=(h "Help: filesystem assignment and formatting")

                set +e
                themed_menu answer \
                        "Filesystem device selection" \
                        "$prompt" \
                        22 92 14 \
                        "${menu_items[@]}"
                status=$?
                set -e

                if ((status != 0)); then
                        return 2
                fi

                if [[ -z "$answer" ]]; then
                        # Explicit Back/Cancel is a normal navigation event, not
                        # an installer failure.  Caller returns to Storage setup.
                        return 2
                fi

                if [[ "$answer" == h ]]; then
                        show_installer_help filesystem
                        continue
                fi

                if [[ "$optional" == yes && "$answer" == 0 ]]; then
                        printf -v "$variable" ''
                        return 0
                fi

                [[ "$answer" =~ ^[0-9]+$ ]] || {
                        warn "Choose a partition from the menu."
                        sleep 1
                        continue
                }

                ((answer >= 1 && answer <= ${#AVAILABLE_PATHS[@]})) || {
                        warn "That selection is outside the available range."
                        sleep 1
                        continue
                }

                selected_index=$((answer - 1))
                selected_device="${AVAILABLE_PATHS[$selected_index]}"
                printf -v "$variable" '%s' "$selected_device"
                USED_DEVICES+=("$selected_device")
                return 0
        done
}

choose_linux_format() {
        local variable="$1"
        local device="$2"
        local role="$3"
        local choice=""
        local status=0

        [[ -n "$device" ]] || return 0

        set +e
        themed_menu choice \
                "Filesystem format" \
                "Choose how to prepare $role on $device." \
                19 78 10 \
                1 "Keep the existing filesystem" \
                2 "Format as ext2" \
                3 "Format as ext4" \
                4 "Format as XFS" \
                5 "Format as Btrfs" \
                6 "Format as F2FS"
        status=$?
        set -e

        [[ -n "$choice" ]] || choice=1

        case "$choice" in
                1) printf -v "$variable" '%s' keep ;;
                2) printf -v "$variable" '%s' ext2 ;;
                3) printf -v "$variable" '%s' ext4 ;;
                4) printf -v "$variable" '%s' xfs ;;
                5) printf -v "$variable" '%s' btrfs ;;
                6) printf -v "$variable" '%s' f2fs ;;
                *) warn "Invalid filesystem selection; keeping the existing filesystem."
                   printf -v "$variable" '%s' keep ;;
        esac
}

choose_efi_format() {
        local choice=""
        local status=0

        [[ -n "$EFI_DEV" ]] || return 0

        set +e
        themed_menu choice \
                "EFI System Partition" \
                "Choose how to prepare $EFI_DEV." \
                15 72 6 \
                1 "Keep the existing filesystem" \
                2 "Format as FAT32 with mkfs.fat -F 32"
        status=$?
        set -e

        [[ -n "$choice" ]] || choice=1

        case "$choice" in
                2) EFI_FORMAT=vfat ;;
                *) EFI_FORMAT=keep ;;
        esac
}

choose_swap_format() {
        local choice=""
        local status=0

        [[ -n "$SWAP_DEV" ]] || return 0

        set +e
        themed_menu choice \
                "Swap partition" \
                "Choose how to prepare $SWAP_DEV." \
                15 72 6 \
                1 "Keep the existing swap signature" \
                2 "Reinitialize with mkswap"
        status=$?
        set -e

        [[ -n "$choice" ]] || choice=1

        case "$choice" in
                2) SWAP_FORMAT=swap ;;
                *) SWAP_FORMAT=keep ;;
        esac
}

collect_additional_partitions() {
        local answer="" device="" mountpoint="" format="" status=0
        while true; do
                if command -v dialog >/dev/null 2>&1 &&
                   [[ -r /dev/tty && -w /dev/tty ]]; then
                        set +e
                        dialog --clear \
                                --backtitle "BFSOS Installer" \
                                --title "Additional filesystem" \
                                --yesno "Add another filesystem partition?" \
                                9 54 \
                                </dev/tty >/dev/tty 2>/dev/tty
                        status=$?
                        set -e
                        ((status == 0)) || break
                else
                        read -r -p "Add another filesystem partition? [y/N]: " answer
                        [[ "${answer,,}" == y || "${answer,,}" == yes ]] || break
                fi
                device=""
                select_partition device "Device for the additional partition" no
                while true; do
                        read -r -p "Mount point (for example /var): " mountpoint
                        [[ "$mountpoint" == /* && "$mountpoint" != / && "$mountpoint" != /boot && "$mountpoint" != /boot/efi && "$mountpoint" != /home && "$mountpoint" != *'..'* ]] && break
                        warn "Use an absolute, non-reserved mount point such as /var or /srv."
                done
                format=keep
                choose_linux_format format "$device" "$mountpoint"
                EXTRA_DEVICES+=("$device")
                EXTRA_MOUNTPOINTS+=("$mountpoint")
                EXTRA_FORMATS+=("$format")
        done
}


get_available_nics() {
        local interface="" mac="" state="" driver=""

        AVAILABLE_NICS=()
        AVAILABLE_NIC_MACS=()
        AVAILABLE_NIC_STATES=()
        AVAILABLE_NIC_DRIVERS=()

        while IFS= read -r interface; do
                [[ "$interface" == lo ]] && continue
                [[ -d "/sys/class/net/$interface" ]] || continue

                mac="$(cat "/sys/class/net/$interface/address" 2>/dev/null || true)"
                state="$(cat "/sys/class/net/$interface/operstate" 2>/dev/null || printf '%s' unknown)"
                driver="$(basename "$(readlink -f "/sys/class/net/$interface/device/driver" 2>/dev/null || true)")"
                [[ -n "$driver" ]] || driver="-"

                AVAILABLE_NICS+=("$interface")
                AVAILABLE_NIC_MACS+=("${mac:--}")
                AVAILABLE_NIC_STATES+=("${state:--}")
                AVAILABLE_NIC_DRIVERS+=("$driver")
        done < <(
                find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null |
                sort
        )
}

show_available_nics() {
        local index=""

        get_available_nics
        printf '\nAvailable network interfaces:\n'
        printf '  %-4s %-16s %-20s %-12s %s\n' NUM INTERFACE MAC STATE DRIVER

        for ((index=0; index<${#AVAILABLE_NICS[@]}; index++)); do
                printf '  %-4d %-16s %-20s %-12s %s\n' \
                        "$((index + 1))" \
                        "${AVAILABLE_NICS[$index]}" \
                        "${AVAILABLE_NIC_MACS[$index]}" \
                        "${AVAILABLE_NIC_STATES[$index]}" \
                        "${AVAILABLE_NIC_DRIVERS[$index]}"
        done
        printf '\n'
}

select_network_interface() {
        local answer=""
        local selected_index=""
        local status=0
        local index=0
        local -a menu_items=()

        if [[ -n "$NETWORK_IFACE" ]]; then
                [[ -d "/sys/class/net/$NETWORK_IFACE" ]] ||
                        die "Configured network interface does not exist: $NETWORK_IFACE"
                NETWORK_MAC="$(cat "/sys/class/net/$NETWORK_IFACE/address" 2>/dev/null || true)"
                return 0
        fi

        while true; do
                get_available_nics
                ((${#AVAILABLE_NICS[@]} > 0)) ||
                        die "No usable network interfaces were found."

                menu_items=()
                for ((index=0; index<${#AVAILABLE_NICS[@]}; index++)); do
                        menu_items+=(
                                "$((index + 1))"
                                "${AVAILABLE_NICS[$index]}  ${AVAILABLE_NIC_MACS[$index]}  ${AVAILABLE_NIC_STATES[$index]}  ${AVAILABLE_NIC_DRIVERS[$index]}"
                        )
                done

                themed_menu answer \
                        "Network interface" \
                        "Select the interface BFS should configure." \
                        20 92 12 \
                        "${menu_items[@]}"

                [[ -n "$answer" ]] || return 1
                [[ "$answer" =~ ^[0-9]+$ ]] || continue
                ((answer >= 1 && answer <= ${#AVAILABLE_NICS[@]})) || continue

                selected_index=$((answer - 1))
                NETWORK_IFACE="${AVAILABLE_NICS[$selected_index]}"
                NETWORK_MAC="${AVAILABLE_NIC_MACS[$selected_index]}"
                return 0
        done
}


get_whole_disks() {
        lsblk -dpno NAME,SIZE,MODEL,TYPE |
        awk '$NF == "disk" {
                name=$1
                if (name ~ /^\/dev\/(fd|sr|loop)[0-9]+$/)
                        next
                type=$NF
                $NF=""
                sub(/[[:space:]]+$/, "")
                print
        }'
}

refresh_storage_state() {
        local disk="" failed=0

        sync

        # Ask the kernel to reread partition tables on all whole disks. Busy
        # devices are reported but do not abort the installer; the subsequent
        # inventory is always rebuilt from current kernel state.
        while IFS= read -r disk; do
                [[ -b "$disk" ]] || continue
                if command -v partprobe >/dev/null 2>&1; then
                        partprobe "$disk" >/dev/null 2>&1 || {
                                warn "Could not refresh the partition table for $disk (device may be busy)."
                                failed=1
                        }
                elif command -v blockdev >/dev/null 2>&1; then
                        blockdev --rereadpt "$disk" >/dev/null 2>&1 || {
                                warn "Could not reread the partition table for $disk (device may be busy)."
                                failed=1
                        }
                fi
        done < <(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^\/dev\/(fd|sr|loop)[0-9]+$/ {print $1}')

        command -v udevadm >/dev/null 2>&1 && udevadm settle || true
        command -v pvscan >/dev/null 2>&1 && pvscan --cache >/dev/null 2>&1 || true
        command -v vgscan >/dev/null 2>&1 && vgscan --mknodes >/dev/null 2>&1 || true

        # Rebuild the installer's cached device arrays; never carry a pre-change
        # inventory into the next storage screen.
        get_available_partitions
        return 0
}

partition_table_fingerprint() {
        local disk="${1:-}"
        [[ -b "$disk" ]] || { printf '%s' missing; return 0; }

        # Use kernel-visible partition geometry/identifiers so merely opening
        # cfdisk and exiting without Write does not mark the disk changed.
        lsblk -nrpo NAME,TYPE,START,SIZE,PARTTYPE,PARTUUID "$disk" 2>/dev/null |
                sha256sum | awk '{print $1}'
}

partition_disks() {
        local choice="" disk="" index="" line="" status=0 before="" after="" description=""
        local -a disk_paths=()
        local -a disk_descriptions=()
        local -a menu_items=()

        command -v cfdisk >/dev/null 2>&1 || {
                warn "cfdisk is not available in this live environment."
                pause_screen
                return 0
        }

        while true; do
                disk_paths=()
                disk_descriptions=()
                menu_items=()

                while IFS= read -r line; do
                        [[ -n "$line" ]] || continue
                        disk="${line%% *}"
                        disk_paths+=("$disk")
                        disk_descriptions+=("$line")
                done < <(get_whole_disks)

                ((${#disk_paths[@]} > 0)) || {
                        warn "No whole disks were found."
                        pause_screen
                        return 0
                }

                for ((index=0; index<${#disk_paths[@]}; index++)); do
                        disk="${disk_paths[$index]}"
                        description="${disk_descriptions[$index]}"
                        if [[ "${PARTITION_DISKS_MODIFIED[$disk]:-no}" == yes ]]; then
                                description+="  [MODIFIED THIS SESSION]"
                        fi
                        menu_items+=("$((index + 1))" "$description")
                done
                menu_items+=("$(( ${#disk_paths[@]} + 1 ))" "Finished partitioning")

                set +e
                themed_menu choice \
                        "Partition disks" \
                        "Choose a disk to open with cfdisk, or finish without changing partitions." \
                        20 88 12 \
                        "${menu_items[@]}"
                status=$?
                set -e
                [[ -n "$choice" ]] || return 0

                [[ "$choice" =~ ^[0-9]+$ ]] || {
                        warn "Choose a disk number from the menu."
                        sleep 1
                        continue
                }

                if ((choice == ${#disk_paths[@]} + 1)); then
                        return 0
                fi

                ((choice >= 1 && choice <= ${#disk_paths[@]})) || {
                        warn "That selection is outside the available range."
                        sleep 1
                        continue
                }

                disk="${disk_paths[$((choice - 1))]}"
                before="$(partition_table_fingerprint "$disk")"
                echo
                echo "Starting cfdisk for $disk..."
                echo "Changes are written only when you choose Write in cfdisk."
                echo

                if ! run_on_tty cfdisk "$disk"; then
                        warn "cfdisk exited with an error for $disk."
                        pause_screen
                fi

                refresh_storage_state
                after="$(partition_table_fingerprint "$disk")"
                if [[ "$before" != "$after" ]]; then
                        PARTITION_DISKS_MODIFIED["$disk"]=yes
                fi
                sleep 1
        done
}


list_raid_member_candidates() {
        # RAID creation in the installer is partition-oriented. Whole disks are
        # intentionally excluded so users do not see both /dev/vdb and
        # /dev/vdb1 for the same physical device after partitioning.
        lsblk -prno PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS |
        awk '
                $2 == "part" && $5 == "" {
                        print
                }
        '
}

choose_raid_level() {
        local variable="$1"
        local choice="" status=0

        set +e
        themed_menu choice \
                "Select RAID level" \
                "Choose the software RAID layout." \
                20 76 10 \
                1 "Linear / JBOD — combines disks, no redundancy" \
                2 "RAID 0 — striping, performance, no redundancy" \
                3 "RAID 1 — mirroring and redundancy" \
                4 "RAID 4 — striping with dedicated parity" \
                5 "RAID 5 — striping with distributed parity" \
                6 "RAID 6 — striping with dual parity" \
                7 "RAID 10 — striped mirrors" \
                8 "Cancel"
        status=$?
        set -e
        [[ -n "$choice" ]] || return 1

        case "$choice" in
                1) printf -v "$variable" '%s' linear ;;
                2) printf -v "$variable" '%s' 0 ;;
                3) printf -v "$variable" '%s' 1 ;;
                4) printf -v "$variable" '%s' 4 ;;
                5) printf -v "$variable" '%s' 5 ;;
                6) printf -v "$variable" '%s' 6 ;;
                7) printf -v "$variable" '%s' 10 ;;
                8) return 1 ;;
                *) warn "Choose a RAID level from the menu."; return 1 ;;
        esac
}


show_raid_level_summary() {
        local raid_level="$1" summary=""
        case "$raid_level" in
                linear) summary=$'RAID type     : Linear / JBOD\nMinimum disks : 2\nLayout        : Concatenation\nRedundancy    : None\nPerformance   : Similar to a single disk\nUsable space  : Sum of all member capacities' ;;
                0) summary=$'RAID type     : RAID 0\nMinimum disks : 2\nLayout        : Striping\nRedundancy    : None\nPerformance   : Excellent read and write performance\nUsable space  : Sum of all member capacities' ;;
                1) summary=$'RAID type     : RAID 1\nMinimum disks : 2\nLayout        : Mirroring\nRedundancy    : One complete mirrored copy\nPerformance   : Fast reads; writes similar to one disk\nUsable space  : Capacity of the smallest member' ;;
                4) summary=$'RAID type     : RAID 4\nMinimum disks : 3\nLayout        : Striping with dedicated parity\nRedundancy    : One drive may fail\nPerformance   : Fast reads; parity disk may limit writes\nUsable space  : Capacity of N-1 members' ;;
                5) summary=$'RAID type     : RAID 5\nMinimum disks : 3\nLayout        : Striping with distributed parity\nRedundancy    : One drive may fail\nPerformance   : Fast reads; good general-purpose writes\nUsable space  : Capacity of N-1 members' ;;
                6) summary=$'RAID type     : RAID 6\nMinimum disks : 4\nLayout        : Striping with dual distributed parity\nRedundancy    : Two drives may fail\nPerformance   : Fast reads; slower writes than RAID 5\nUsable space  : Capacity of N-2 members' ;;
                10) summary=$'RAID type     : RAID 10\nMinimum disks : 4\nLayout        : Striping across mirrored pairs\nRedundancy    : Multiple failures may be tolerated if mirrors remain intact\nPerformance   : Excellent read and write performance\nUsable space  : Approximately 50% of total capacity' ;;
                *) summary="Unknown RAID level: $raid_level" ;;
        esac
        dialog_message "RAID selection summary" "$summary"
}

minimum_raid_members() {
        case "$1" in
                linear|0|1) printf '%s\n' 2 ;;
                4|5)        printf '%s\n' 3 ;;
                6)          printf '%s\n' 4 ;;
                10)         printf '%s\n' 4 ;;
                *)          return 1 ;;
        esac
}

choose_raid_members() {
        local result_variable="$1"
        local minimum="$2"
        local choice=""
        local index=""
        local selected=""
        local candidate=""
        local status=0
        local line=""
        local description=""
        local fstype=""
        local -a candidates=()
        local -a descriptions=()
        local -a selected_members=()
        local -a menu_items=()
        local -a remaining_candidates=()
        local -a remaining_descriptions=()

        while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                candidate="${line%% *}"
                candidates+=("$candidate")
                descriptions+=("$line")
        done < <(list_raid_member_candidates)

        ((${#candidates[@]} >= minimum)) || {
                warn "At least $minimum unused RAID member partitions are required."
                return 1
        }

        # Preferred interface: one checklist showing only partitions. Space
        # toggles a member, Enter accepts the complete selection, and users can
        # correct a mistaken selection before continuing.
        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                while true; do
                        menu_items=()

                        for ((index=0; index<${#candidates[@]}; index++)); do
                                candidate="${candidates[$index]}"
                                description="${descriptions[$index]}"
                                # Remove the path from the descriptive text because
                                # the path is already the checklist tag.
                                description="${description#"$candidate"}"
                                description="${description#"${description%%[![:space:]]*}"}"
                                [[ -n "$description" ]] || description="RAID member partition"

                                menu_items+=(
                                        "$candidate"
                                        "$description"
                                        off
                                )
                        done

                        set +e
                        choice="$(
                                dialog --stdout --clear \
                                        --backtitle "BFSOS Installer" \
                                        --title "Select RAID member partitions" \
                                        --cancel-label "Cancel" \
                                        --separate-output \
                                        --checklist \
                                        "Use Up/Down to move, Space to select or unselect members, then Enter on OK.\n\nThis RAID level requires at least $minimum member(s)." \
                                        23 92 15 \
                                        "${menu_items[@]}" \
                                        </dev/tty
                        )"
                        status=$?
                        set -e

                        ((status == 0)) || return 1

                        selected_members=()
                        while IFS= read -r selected; do
                                [[ -n "$selected" ]] || continue
                                selected_members+=("$selected")
                        done <<< "$choice"

                        if ((${#selected_members[@]} < minimum)); then
                                dialog --clear \
                                        --backtitle "BFSOS Installer" \
                                        --title "Not enough RAID members" \
                                        --msgbox \
                                        "This RAID level requires at least $minimum member(s).\n\nYou selected ${#selected_members[@]}." \
                                        10 60 \
                                        </dev/tty >/dev/tty 2>/dev/tty || true
                                continue
                        fi

                        printf -v "$result_variable" '%s' "${selected_members[*]}"
                        return 0
                done
        fi

        # Text fallback: select one partition at a time, but remove each chosen
        # member from the displayed list so it cannot be selected twice.
        remaining_candidates=("${candidates[@]}")
        remaining_descriptions=("${descriptions[@]}")

        while true; do
                clear_screen
                echo "Select RAID member partitions"
                echo "============================="
                echo
                echo "Selected: ${selected_members[*]:-none}"
                echo

                for ((index=0; index<${#remaining_candidates[@]}; index++)); do
                        printf '  %d) %s\n' \
                                "$((index + 1))" \
                                "${remaining_descriptions[$index]}"
                done

                printf '  %d) Finished selecting members\n' \
                        "$(( ${#remaining_candidates[@]} + 1 ))"
                printf '  %d) Cancel\n\n' \
                        "$(( ${#remaining_candidates[@]} + 2 ))"

                read -r -p "Choose [1-$(( ${#remaining_candidates[@]} + 2 ))]: " choice

                [[ "$choice" =~ ^[0-9]+$ ]] || {
                        warn "Enter a number from the list."
                        sleep 1
                        continue
                }

                if ((choice == ${#remaining_candidates[@]} + 1)); then
                        if ((${#selected_members[@]} < minimum)); then
                                warn "This RAID level requires at least $minimum members."
                                sleep 2
                                continue
                        fi

                        printf -v "$result_variable" '%s' "${selected_members[*]}"
                        return 0
                fi

                if ((choice == ${#remaining_candidates[@]} + 2)); then
                        return 1
                fi

                ((choice >= 1 && choice <= ${#remaining_candidates[@]})) || {
                        warn "That selection is outside the available range."
                        sleep 1
                        continue
                }

                index=$((choice - 1))
                selected="${remaining_candidates[$index]}"
                selected_members+=("$selected")

                unset 'remaining_candidates[index]'
                unset 'remaining_descriptions[index]'
                remaining_candidates=("${remaining_candidates[@]}")
                remaining_descriptions=("${remaining_descriptions[@]}")
        done
}

assemble_raid_arrays() {
        local status_text="" assemble_status=0

        command -v mdadm >/dev/null 2>&1 || {
                dialog_message "Software RAID" "mdadm is not available in this live environment."
                return 0
        }

        # Run mdadm in an if-condition rather than under `set +e`.  The
        # installer has an ERR trap, and a bare non-zero mdadm exit can still
        # trigger that trap even when "no arrays exist" is a perfectly normal
        # result on a clean installation.
        if mdadm --assemble --scan; then
                assemble_status=0
        else
                assemble_status=$?
        fi

        refresh_storage_state

        status_text="$(cat /proc/mdstat 2>/dev/null || true)"

        if ((assemble_status == 0)); then
                dialog_message "Software RAID" "RAID assembly scan completed.\n\n$status_text"
        elif ! list_active_md_arrays | grep -q .; then
                dialog_message "Software RAID" "No existing RAID arrays were found.\n\nThis is normal on a clean installation. Choose 'Create a new array' to continue."
        else
                dialog_message "Software RAID" "One or more RAID arrays could not be assembled automatically.\n\nCurrent MD status:\n\n$status_text"
        fi
}

handle_new_md_signatures() {
        local array_device="${1:-}" signatures="" choice="" status=0 vg="" mounted=""
        local -a vgs=()

        [[ -b "$array_device" ]] || return 0
        command -v udevadm >/dev/null 2>&1 && udevadm settle || true

        signatures="$(wipefs -n "$array_device" 2>/dev/null | sed '1d' || true)"
        [[ -n "$signatures" ]] || return 0

        # A recreated MD array can expose valid old filesystem/LUKS/LVM
        # metadata from the data region. Never silently destroy it.
        set +e
        themed_menu choice \
                "Existing data found on new RAID array" \
                "$array_device was created successfully, but existing signatures were found on the array itself:

$signatures

This can be intentional recovery/reuse data. Choose what to do before continuing." \
                24 100 8 \
                1 "Keep existing signatures/data" \
                2 "Remove existing signatures from $array_device" \
                3 "Cancel / leave array unchanged"
        status=$?
        set -e
        ((status == 0)) || return 1

        case "$choice" in
                1) return 0 ;;
                3|"") return 1 ;;
                2) ;;
                *) return 1 ;;
        esac

        confirm "Remove the detected signatures from $array_device?

$signatures

This destroys the detected filesystem/LUKS/LVM metadata on the RAID array itself. The MD RAID array will remain active." || return 1

        # If the signature is LVM, udev/LVM may already have reactivated the
        # old VG. Refuse to wipe mounted descendants, then deactivate only VGs
        # whose PV is this MD device before clearing its signature.
        mounted="$(lsblk -nrpo PATH,MOUNTPOINTS "$array_device" 2>/dev/null | awk 'NF>1 && $2!="" {print}' || true)"
        if [[ -n "$mounted" ]]; then
                dialog_message "RAID signature cleanup blocked" "Mounted descendants of $array_device were detected:

$mounted

Unmount them before removing old signatures."
                return 1
        fi

        if command -v pvs >/dev/null 2>&1; then
                while IFS= read -r vg; do
                        vg="${vg//[[:space:]]/}"
                        [[ -n "$vg" ]] || continue
                        vgs+=("$vg")
                done < <(pvs --noheadings -o vg_name "$array_device" 2>/dev/null | sort -u || true)
        fi

        for vg in "${vgs[@]}"; do
                if ! vgchange -an "$vg" >/dev/null 2>&1; then
                        dialog_message "LVM deactivation failed" "Could not deactivate volume group '$vg' before clearing old LVM metadata from $array_device. Nothing was wiped."
                        return 1
                fi
        done

        # pvremove gives LVM a chance to invalidate its metadata cleanly;
        # wipefs then removes any remaining recognized signatures.
        if printf '%s\n' "$signatures" | grep -q 'LVM2_member'; then
                pvremove -ff -y "$array_device" >/dev/null 2>&1 || true
        fi
        if ! wipefs -a "$array_device" >/dev/null 2>&1; then
                dialog_message "RAID signature cleanup failed" "Could not clear old signatures from $array_device. The RAID array remains active and no further destructive action was taken."
                return 1
        fi
        command -v udevadm >/dev/null 2>&1 && udevadm settle || true
        command -v pvscan >/dev/null 2>&1 && pvscan --cache >/dev/null 2>&1 || true

        if wipefs -n "$array_device" 2>/dev/null | sed '1d' | grep -q .; then
                dialog_message "RAID signature cleanup incomplete" "One or more signatures are still visible on $array_device. Review the device before using it for LUKS/LVM/filesystems."
                return 1
        fi

        dialog_message "RAID signatures removed" "Old signatures were removed from $array_device. The MD array remains active and can now be used for LUKS, LVM, or a filesystem."
        return 0
}

create_raid_array() {
        local raid_level="" minimum="" member_string="" array_device="/dev/md0"
        local bitmap_choice=no status_text="" member="" holder="" holder_name="" busy_detail=""
        local signature_report="" sig=""
        local -a members=() bitmap_args=()

        command -v mdadm >/dev/null 2>&1 || { dialog_message "Software RAID" "mdadm is not available in this live environment."; return 0; }
        choose_raid_level raid_level || return 0
        minimum="$(minimum_raid_members "$raid_level")"
        show_raid_level_summary "$raid_level"
        choose_raid_members member_string "$minimum" || return 0
        read -r -a members <<< "$member_string"

        ask_default array_device "Array device (for example /dev/md0)" "/dev/md0" || return 0
        [[ "$array_device" =~ ^/dev/md[0-9]+$ ]] || { dialog_message "Invalid RAID device" "Use an array device such as /dev/md0."; return 0; }
        confirm "Create $array_device as RAID $raid_level using:

${members[*]}

Existing data on all selected members will be destroyed." || return 0

        if [[ "$raid_level" != linear && "$raid_level" != 0 ]]; then
                ask_yes_no bitmap_choice "Enable an internal write-intent bitmap?

This can improve recovery/resync behavior after an unclean shutdown." no || return 0
                [[ "$bitmap_choice" == yes ]] && bitmap_args=(--bitmap=internal) || bitmap_args=(--bitmap=none)
        fi

        # Refuse members that are actively consumed by another layer.
        for member in "${members[@]}"; do
                if findmnt -rn -S "$member" >/dev/null 2>&1; then
                        busy_detail+="$member is mounted or otherwise in use.\n"
                fi
                if [[ -d "/sys/class/block/${member##*/}/holders" ]]; then
                        for holder in /sys/class/block/${member##*/}/holders/*; do
                                [[ -e "$holder" ]] || continue
                                holder_name="${holder##*/}"
                                busy_detail+="$member is held by /dev/$holder_name.\n"
                        done
                fi
        done
        if [[ -n "$busy_detail" ]]; then
                dialog_message "RAID members are busy" "One or more selected RAID members are already in use:

$busy_detail
Stop/close the existing storage layer or choose different members, then retry. No new array was created."
                return 0
        fi

        # Signature handling MUST occur before mdadm --create.  The old flow
        # started /dev/mdX and then attempted wipefs -a on the active array,
        # which fails as busy and can also erase a newly exposed LUKS signature.
        for member in "${members[@]}"; do
                sig="$(wipefs -n "$member" 2>/dev/null | sed '1d' || true)"
                if mdadm --examine "$member" >/dev/null 2>&1; then
                        [[ -n "$sig" ]] || sig="existing MD RAID metadata"
                fi
                [[ -n "$sig" ]] && signature_report+="$member:
$sig

"
        done
        if [[ -n "$signature_report" ]]; then
                confirm "Existing signatures/RAID metadata were found on the selected RAID members:

$signature_report
Erase these member signatures before creating $array_device?" || return 0
                for member in "${members[@]}"; do
                        mdadm --zero-superblock --force "$member" 2>/dev/null || true
                        wipefs -a "$member" 2>/dev/null || {
                                dialog_message "RAID member cleanup failed" "Could not clear stale signatures from $member. No new array was created."
                                return 0
                        }
                done
                command -v udevadm >/dev/null 2>&1 && udevadm settle || true
        fi

        if [[ "$raid_level" == linear ]]; then
                if ! mdadm --create "$array_device" --run --force --level=linear --raid-devices="${#members[@]}" "${members[@]}"; then
                        dialog_message "RAID creation failed" "mdadm could not create $array_device.

Check whether any selected member still contains active RAID/LUKS/LVM state, then retry."
                        return 0
                fi
        else
                if ! mdadm --create "$array_device" --run --force --level="$raid_level" --raid-devices="${#members[@]}" "${bitmap_args[@]}" "${members[@]}"; then
                        dialog_message "RAID creation failed" "mdadm could not create $array_device.

Check whether any selected member still contains active RAID/LUKS/LVM state, then retry."
                        return 0
                fi
        fi
        CREATED_MD_ARRAYS_BY_SCRIPT+=("$array_device")
        if ! handle_new_md_signatures "$array_device"; then
                refresh_storage_state
                return 0
        fi
        refresh_storage_state
        status_text="$(cat /proc/mdstat 2>/dev/null || true)"
        dialog_message "RAID array created" "$array_device was created successfully.

$status_text"
}

show_raid_details() {
        local array="" tmp=""

        tmp="$(mktemp /tmp/bfs-raid-status.XXXXXX)"
        {
                printf '%s\n' "Software RAID status"
                printf '%s\n\n' "===================="
                cat /proc/mdstat 2>/dev/null || true

                if command -v mdadm >/dev/null 2>&1; then
                        while IFS= read -r array; do
                                [[ -n "$array" ]] || continue
                                printf '\n%s\n' "------------------------------------------------------------"
                                mdadm --detail "$array" 2>/dev/null || true
                        done < <(list_active_md_arrays)
                fi
        } >"$tmp"

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear \
                        --backtitle "BFSOS Installer" \
                        --title "Software RAID status" \
                        --textbox "$tmp" 28 110 \
                        </dev/tty >/dev/tty 2>/dev/tty || true
        else
                cat "$tmp"
                pause_screen
        fi

        rm -f "$tmp"
}

raid_menu() {
        local choice="" status=0

        while true; do
                set +e
                themed_menu choice \
                        "Software RAID" \
                        "Create, assemble, or inspect Linux software RAID arrays." \
                        17 74 7 \
                        1 "Assemble existing arrays" \
                        2 "Create a new array" \
                        3 "Show array status and details" \
                        4 "Help" \
                        5 "Return to Storage setup"
                status=$?
                set -e
                [[ -n "$choice" ]] || return 0

                case "$choice" in
                        1) assemble_raid_arrays ;;
                        2) create_raid_array ;;
                        3) show_raid_details ;;
                        4) show_installer_help raid ;;
                        5) return 0 ;;
                        *) warn "Choose a valid RAID option."; sleep 1 ;;
                esac
        done
}

list_luks_candidates() {
        local p="" t="" sz="" fs="" mp="" array=""
        local -A seen=()

        # Always enumerate active MD arrays explicitly.  Depending on util-linux
        # version and array state, lsblk may report an MD device as raid5,
        # raid6, raid10, or another MD-specific TYPE.  The LUKS selector should
        # never lose a valid assembled /dev/md* target because of that detail.
        if [[ -r /proc/mdstat ]]; then
                while IFS= read -r array; do
                        [[ -n "$array" && -b "$array" ]] || continue
                        sz="$(lsblk -dnro SIZE "$array" 2>/dev/null | head -n1)"
                        t="$(lsblk -dnro TYPE "$array" 2>/dev/null | head -n1)"
                        fs="$(lsblk -dnro FSTYPE "$array" 2>/dev/null | head -n1)"
                        mp="$(lsblk -dnro MOUNTPOINTS "$array" 2>/dev/null | head -n1)"
                        [[ -z "$mp" ]] || continue
                        case "$fs" in LVM2_member|crypto_LUKS) continue ;; esac
                        seen["$array"]=1
                        printf '%s|%s|%s|%s\n' "$array" "${sz:--}" "${t:-raid}" "${fs:--}"
                done < <(
                        awk '$2 == ":" {print "/dev/" $1}' /proc/mdstat
                )
        fi

        while read -r p t sz fs mp; do
                [[ -n "$p" ]] || continue
                p="$(readlink -f -- "$p" 2>/dev/null || printf '%s' "$p")"
                [[ -z "${seen[$p]:-}" ]] || continue
                if [[ "$t" != part && "$t" != raid* && "$t" != linear ]] &&
                   ! is_md_block_device "$p"; then
                        continue
                fi
                [[ -z "$mp" ]] || continue
                case "$fs" in linux_raid_member|LVM2_member|crypto_LUKS) continue ;; esac

                # Do not offer an individual device that is currently a member
                # of an assembled MD array.  Detect membership structurally via
                # /sys/class/block/md*/slaves so Linear/JBOD (TYPE=linear) and
                # every RAID personality behave the same way.
                if is_active_md_member "$p"; then
                        continue
                fi

                seen["$p"]=1
                printf '%s|%s|%s|%s\n' "$p" "$sz" "$t" "${fs:--}"
        done < <(
                lsblk -prno PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS |
                        awk '{print $1,$2,$3,$4,$5}'
        )
}

select_luks_device() {
        local result_variable="$1" title="$2" line p sz t fs choice="" status=0
        local -a items=() paths=()
        while IFS='|' read -r p sz t fs; do
                [[ -n "$p" ]] || continue
                paths+=("$p"); items+=("${#paths[@]}" "$p  $sz  $t  $fs")
        done < <(list_luks_candidates)
        ((${#paths[@]})) || { dialog_message "$title" "No eligible LUKS target devices were found."; return 1; }
        themed_menu choice "$title" "Select the block device." 22 92 14 "${items[@]}"
        [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#paths[@]})) || return 1
        printf -v "$result_variable" '%s' "${paths[$((choice-1))]}"
}

select_luks_existing_device() {
        local result_variable="$1" p="" sz="" fs="" choice=""
        local -a paths=() items=()
        local -A seen=()

        while read -r p sz fs; do
                [[ "$fs" == crypto_LUKS && -n "$p" ]] || continue
                [[ -z "${seen[$p]:-}" ]] || continue
                seen["$p"]=1
                paths+=("$p")
                items+=("${#paths[@]}" "$p  $sz  LUKS")
        done < <(lsblk -prno PATH,SIZE,FSTYPE)

        ((${#paths[@]})) || {
                dialog_message "Open LUKS" "No LUKS containers were found."
                return 1
        }

        themed_menu choice "Open LUKS container" "Select a LUKS device." 20 88 12 "${items[@]}"
        [[ "$choice" =~ ^[0-9]+$ ]] &&
                ((choice>=1 && choice<=${#paths[@]})) || return 1
        printf -v "$result_variable" '%s' "${paths[$((choice-1))]}"
}

ask_mapping_name() {
        local result_variable="$1" default="$2" selected_mapping=""
        while true; do
                ask_default selected_mapping "Mapper name (creates /dev/mapper/<name>)" "$default" || return 1
                [[ "$selected_mapping" =~ ^[A-Za-z0-9+_.-]+$ ]] || { dialog_message "Invalid mapper name" "Use letters, numbers, +, _, . or -. Spaces and / are not allowed."; continue; }
                [[ ! -e "/dev/mapper/$selected_mapping" ]] || { dialog_message "Mapper already exists" "/dev/mapper/$selected_mapping already exists. Choose another name."; continue; }

                # Bash uses dynamic scoping for local variables. Do not name this
                # helper-local value `mapping`, because the caller also asks us
                # to return into a variable named `mapping`; otherwise printf -v
                # updates the helper's local variable and the caller sees blank.
                printf -v "$result_variable" '%s' "$selected_mapping"
                return 0
        done
}

luks_menu() {
        local choice="" device="" mapping="" pass1="" pass2="" status=0 default_mapping="cryptroot"
        while true; do
                themed_menu choice "LUKS encryption" "Create, open, or close encrypted block-device mappings." 17 74 7 \
                        1 "Create a new LUKS container" 2 "Open an existing LUKS container" 3 "Close a mapped LUKS container" 4 "Help" 5 "Return to Storage setup"
                [[ -n "$choice" ]] || return 0
                case "$choice" in
                        1)
                                command -v cryptsetup >/dev/null 2>&1 || { dialog_message "LUKS encryption" "cryptsetup is unavailable."; continue; }
                                select_luks_device device "Create LUKS container" || continue
                                [[ "$device" == /dev/md* ]] && default_mapping="cryptraid" || default_mapping="cryptroot"
                                confirm "WARNING: This will permanently overwrite data on $device.\n\nCreate a new LUKS2 container?" || continue
                                while true; do
                                        dialog_password pass1 "LUKS passphrase" "Enter the new passphrase for $device." || { pass1=""; break; }
                                        dialog_password pass2 "Confirm LUKS passphrase" "Enter the same passphrase again." || { pass1=""; pass2=""; break; }
                                        [[ -n "$pass1" ]] || { dialog_message "LUKS passphrase" "The passphrase cannot be empty."; continue; }
                                        [[ "$pass1" == "$pass2" ]] || { dialog_message "LUKS passphrase" "The passphrases did not match. Try again."; pass1=""; pass2=""; continue; }
                                        break
                                done
                                [[ -n "$pass1" ]] || continue
                                if ! printf '%s' "$pass1" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$device"; then
                                        pass1=""; pass2=""; dialog_message "LUKS error" "cryptsetup luksFormat failed for $device."; continue
                                fi
                                ask_mapping_name mapping "$default_mapping" || { pass1=""; pass2=""; continue; }
                                if ! printf '%s' "$pass1" | cryptsetup open --key-file - "$device" "$mapping"; then
                                        pass1=""; pass2=""; dialog_message "LUKS error" "The new container was created, but /dev/mapper/$mapping could not be opened."; continue
                                fi
                                pass1=""; pass2=""
                                OPENED_LUKS_BY_SCRIPT+=("$mapping")
                                refresh_storage_state
                                if [[ -b "/dev/mapper/$mapping" ]] && cryptsetup status "$mapping" >/dev/null 2>&1; then
                                        dialog_message "LUKS ready" "$device is encrypted and open as /dev/mapper/$mapping."
                                else
                                        dialog_message "LUKS error" "The mapping /dev/mapper/$mapping did not remain active."
                                fi
                                ;;
                        2)
                                command -v cryptsetup >/dev/null 2>&1 || { dialog_message "LUKS encryption" "cryptsetup is unavailable."; continue; }
                                select_luks_existing_device device || continue
                                ask_mapping_name mapping "cryptroot" || continue
                                dialog_password pass1 "LUKS passphrase" "Enter the passphrase for $device." || continue
                                if printf '%s' "$pass1" | cryptsetup open --key-file - "$device" "$mapping"; then
                                        OPENED_LUKS_BY_SCRIPT+=("$mapping"); refresh_storage_state
                                        dialog_message "LUKS opened" "$device is open as /dev/mapper/$mapping."
                                else
                                        dialog_message "LUKS error" "Could not open $device."
                                fi
                                pass1=""
                                ;;
                        3)
                                ask_default mapping "Mapping name to close" "cryptroot" || continue
                                if cryptsetup close "$mapping"; then
                                        refresh_storage_state
                                        dialog_message "LUKS closed" "/dev/mapper/$mapping was closed."
                                else
                                        dialog_message "LUKS error" "Could not close $mapping."
                                fi
                                ;;
                        4) show_installer_help luks ;;
                        5) return 0 ;;
                esac
        done
}

select_pv_devices() {
        local result_variable="$1" p="" t="" sz="" fs="" mp="" choice="" status=0
        local -a paths=() items=()
        local -A seen=()

        while read -r p t sz fs mp; do
                [[ -n "$p" ]] || continue
                [[ -z "${seen[$p]:-}" ]] || continue
                seen["$p"]=1
                if [[ "$t" != part && "$t" != crypt && "$t" != raid* && "$p" != /dev/mapper/* ]] &&
                   ! is_md_block_device "$p"; then
                        continue
                fi
                [[ -z "$mp" ]] || continue
                case "$fs" in linux_raid_member|LVM2_member|crypto_LUKS) continue ;; esac
                is_active_md_member "$p" && continue
                paths+=("$p")
                items+=("$p" "$sz  $t  ${fs:--}" off)
        done < <(lsblk -prno PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS | awk '{print $1,$2,$3,$4,$5}')

        ((${#paths[@]})) || {
                dialog_message "LVM physical volume" "No eligible block devices were found."
                return 1
        }

        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                if choice="$(dialog --stdout --clear \
                        --backtitle "BFSOS Installer" \
                        --title "LVM physical volume" \
                        --cancel-label "Back" --separate-output --checklist \
                        "Use Up/Down to move and Space to select one or more devices." \
                        22 92 14 "${items[@]}" </dev/tty)"; then
                        status=0
                else
                        status=$?
                fi
                ((status==0)) || return 1
                choice="$(printf '%s\n' "$choice" | tr '\n' ' ')"
        else
                ask_default choice "Physical volume device(s), separated by spaces" "/dev/" || return 1
        fi

        [[ -n "${choice// /}" ]] || return 1
        printf -v "$result_variable" '%s' "$choice"
}

human_iec_bytes() {
        local bytes="${1:-0}"
        [[ "$bytes" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '%s' "?"; return 0; }
        awk -v b="$bytes" 'BEGIN {
                split("B KiB MiB GiB TiB PiB EiB", u, " ");
                i=1;
                while (b >= 1024 && i < 7) { b /= 1024; i++ }
                if (i == 1) printf "%.0f %s", b, u[i];
                else if (b >= 100) printf "%.0f %s", b, u[i];
                else if (b >= 10) printf "%.1f %s", b, u[i];
                else printf "%.2f %s", b, u[i];
        }'
}

lvm_vg_capacity_text() {
        local vg="$1" size_b="" free_b="" used_b=""
        IFS='|' read -r size_b free_b < <(vgs --noheadings --units b --nosuffix --separator '|' -o vg_size,vg_free "$vg" 3>&- 4>&- 2>/dev/null | head -n1)
        size_b="$(printf '%s' "$size_b" | xargs)"
        free_b="$(printf '%s' "$free_b" | xargs)"
        [[ "$size_b" =~ ^[0-9]+([.][0-9]+)?$ && "$free_b" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
        used_b="$(awk -v s="$size_b" -v f="$free_b" 'BEGIN { printf "%.0f", s-f }')"
        printf 'VG %s: total %s, used %s, free %s' "$vg" \
                "$(human_iec_bytes "$size_b")" \
                "$(human_iec_bytes "$used_b")" \
                "$(human_iec_bytes "$free_b")"
}

select_existing_pvs() {
        local result_variable="$1" pv="" size="" vg="" choice="" status=0
        local -a items=()
        local -A seen=()

        while IFS='|' read -r pv size vg; do
                pv="$(printf '%s' "$pv" | xargs)"
                size="$(printf '%s' "$size" | xargs)"
                vg="$(printf '%s' "$vg" | xargs)"
                [[ -n "$pv" && -z "$vg" ]] || continue
                [[ -z "${seen[$pv]:-}" ]] || continue
                seen["$pv"]=1
                items+=("$pv" "$(human_iec_bytes "${size:-0}")  unassigned PV" off)
        done < <(pvs --noheadings --units b --nosuffix --separator '|' -o pv_name,pv_size,vg_name 3>&- 4>&- 2>/dev/null || true)

        ((${#items[@]})) || {
                dialog_message "Create volume group" \
                        "No unassigned LVM physical volumes were found.\n\nCreate a physical volume first."
                return 1
        }

        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                if choice="$(dialog --stdout --clear \
                        --backtitle "BFSOS Installer" \
                        --title "Select physical volumes" \
                        --cancel-label "Back" --separate-output --checklist \
                        "Select one or more existing, unassigned physical volumes for the new volume group." \
                        22 92 14 "${items[@]}" </dev/tty)"; then
                        status=0
                else
                        status=$?
                fi
                ((status==0)) || return 1
                choice="$(printf '%s\n' "$choice" | tr '\n' ' ')"
        else
                ask_default choice "Existing physical volume(s), separated by spaces" "" || return 1
        fi

        [[ -n "${choice// /}" ]] || return 1
        printf -v "$result_variable" '%s' "$choice"
}

select_existing_vg() {
        local result_variable="$1" vg="" size="" free="" choice=""
        local -a names=() items=()
        local -A seen=()

        while IFS='|' read -r vg size free; do
                vg="$(printf '%s' "$vg" | xargs)"
                size="$(printf '%s' "$size" | xargs)"
                free="$(printf '%s' "$free" | xargs)"
                [[ -n "$vg" ]] || continue
                [[ -z "${seen[$vg]:-}" ]] || continue
                seen["$vg"]=1
                names+=("$vg")
                items+=("${#names[@]}" "$vg  total=$(human_iec_bytes "${size:-0}")  free=$(human_iec_bytes "${free:-0}")")
        done < <(vgs --noheadings --units b --nosuffix --separator '|' -o vg_name,vg_size,vg_free 3>&- 4>&- 2>/dev/null || true)

        ((${#names[@]})) || {
                dialog_message "Create logical volume" "No LVM volume groups were found."
                return 1
        }

        themed_menu choice "Select volume group" \
                "Choose the volume group in which to create the logical volume." \
                20 86 12 "${items[@]}"
        [[ "$choice" =~ ^[0-9]+$ ]] &&
                ((choice>=1 && choice<=${#names[@]})) || return 1
        printf -v "$result_variable" '%s' "${names[$((choice-1))]}"
}

lvm_review_text() {
        local pv="" vg="" size="" free="" lv="" path="" used=""
        local found=no

        printf 'Physical Volumes:\n'
        while IFS='|' read -r pv vg size free; do
                pv="$(printf '%s' "$pv" | xargs)"
                vg="$(printf '%s' "$vg" | xargs)"
                size="$(printf '%s' "$size" | xargs)"
                free="$(printf '%s' "$free" | xargs)"
                [[ -n "$pv" ]] || continue
                found=yes
                printf '  %-28s size=%-12s free=%-12s VG=%s\n' \
                        "$pv" "$(human_iec_bytes "${size:-0}")" \
                        "$(human_iec_bytes "${free:-0}")" "${vg:-unassigned}"
        done < <(pvs --noheadings --units b --nosuffix --separator '|' -o pv_name,vg_name,pv_size,pv_free 3>&- 4>&- 2>/dev/null || true)
        [[ "$found" == yes ]] || printf '  none\n'

        printf '\nVolume Groups:\n'
        found=no
        while IFS='|' read -r vg size free; do
                vg="$(printf '%s' "$vg" | xargs)"
                size="$(printf '%s' "$size" | xargs)"
                free="$(printf '%s' "$free" | xargs)"
                [[ -n "$vg" ]] || continue
                found=yes
                used="$(awk -v s="${size:-0}" -v f="${free:-0}" 'BEGIN { printf "%.0f", s-f }')"
                printf '  %-20s total=%-12s used=%-12s free=%s\n' \
                        "$vg" "$(human_iec_bytes "${size:-0}")" \
                        "$(human_iec_bytes "$used")" "$(human_iec_bytes "${free:-0}")"
        done < <(vgs --noheadings --units b --nosuffix --separator '|' -o vg_name,vg_size,vg_free 3>&- 4>&- 2>/dev/null || true)
        [[ "$found" == yes ]] || printf '  none\n'

        printf '\nLogical Volumes:\n'
        found=no
        while IFS='|' read -r vg lv path size; do
                vg="$(printf '%s' "$vg" | xargs)"
                lv="$(printf '%s' "$lv" | xargs)"
                path="$(printf '%s' "$path" | xargs)"
                size="$(printf '%s' "$size" | xargs)"
                [[ -n "$lv" ]] || continue
                found=yes
                printf '  %-24s %-28s size=%s\n' "$vg/$lv" "${path:-/dev/$vg/$lv}" "$(human_iec_bytes "${size:-0}")"
        done < <(lvs --noheadings --units b --nosuffix --separator '|' -o vg_name,lv_name,lv_path,lv_size 3>&- 4>&- 2>/dev/null || true)
        [[ "$found" == yes ]] || printf '  none\n'
}

show_lvm_status_dialog() {
        local text
        text="$(lvm_review_text)"
        dialog_message "LVM status" "$text"
}

lvm_menu() {
        local choice=""
        local device=""
        local pv_list=""
        local vg_name=""
        local lv_name=""
        local lv_size=""
        local normalized_size=""
        local status=0 index=""
        local -a pv_array=()

        # LVM reports inherited installer logging descriptors as "leaked".
        # Closing only fd 3/4 for LVM utilities keeps normal stdout/stderr logging
        # while preventing those harmless warnings.
        lvm_run() {
                "$@" 3>&- 4>&-
        }

        create_equal_home_var_lvs() {
                local split_vg="" home_name="home" var_name="var"
                local free_extents="" extent_bytes="" home_extents="" var_extents=""
                local home_bytes="" var_bytes="" actual_home="" actual_var=""
                local home_actual_extents="" var_actual_extents=""

                command -v lvcreate >/dev/null 2>&1 || {
                        dialog_message "LVM equal split" "LVM tools are unavailable."
                        return 1
                }

                select_existing_vg split_vg || return 1

                if lvs --noheadings -o lv_name "$split_vg" 3>&- 4>&- 2>/dev/null |
                        awk '{$1=$1};1' | grep -Fxq "$home_name"; then
                        dialog_message "LVM equal split"                                 "Logical volume '$home_name' already exists in '$split_vg'.\n\nThe equal-split preset will not overwrite existing logical volumes."
                        return 1
                fi
                if lvs --noheadings -o lv_name "$split_vg" 3>&- 4>&- 2>/dev/null |
                        awk '{$1=$1};1' | grep -Fxq "$var_name"; then
                        dialog_message "LVM equal split"                                 "Logical volume '$var_name' already exists in '$split_vg'.\n\nThe equal-split preset will not overwrite existing logical volumes."
                        return 1
                fi

                free_extents="$(vgs --noheadings --nosuffix -o vg_free_count "$split_vg" 3>&- 4>&- 2>/dev/null | awk '{print int($1)}')"
                extent_bytes="$(vgs --noheadings --units b --nosuffix -o vg_extent_size "$split_vg" 3>&- 4>&- 2>/dev/null | awk '{printf "%.0f", $1}')"

                [[ "$free_extents" =~ ^[0-9]+$ && "$extent_bytes" =~ ^[0-9]+$ ]] || {
                        dialog_message "LVM equal split" "Could not determine free extents for volume group '$split_vg'."
                        return 1
                }
                (( free_extents >= 2 )) || {
                        dialog_message "LVM equal split" "Volume group '$split_vg' does not have enough free extents to create both /home and /var logical volumes."
                        return 1
                }

                # Both allocations are calculated from the same initial free
                # extent snapshot.  This deliberately avoids two sequential
                # 50%FREE operations (50% + 25% of the original free space).
                home_extents=$(( free_extents / 2 ))
                var_extents=$(( free_extents - home_extents ))
                home_bytes=$(( home_extents * extent_bytes ))
                var_bytes=$(( var_extents * extent_bytes ))

                confirm "Create equal /home + /var logical volumes in '$split_vg'?\n\nInitial free extents: $free_extents\nExtent size: $(human_iec_bytes "$extent_bytes")\n\n/home -> LV '$home_name': $home_extents extents (~$(human_iec_bytes "$home_bytes"))\n/var  -> LV '$var_name': $var_extents extents (~$(human_iec_bytes "$var_bytes"))\n\nThe two sizes may differ by at most one physical extent when the free-extent count is odd. This preset consumes the currently free extents." || return 1

                if ! lvm_run lvcreate -l "$home_extents" -n "$home_name" "$split_vg"; then
                        dialog_message "LVM equal split" "Creating '$split_vg/$home_name' failed. No /var LV was attempted."
                        return 1
                fi

                if ! lvm_run lvcreate -l "$var_extents" -n "$var_name" "$split_vg"; then
                        # Keep the preset atomic where possible. If the second
                        # creation fails, remove the first LV we just created.
                        lvm_run lvremove -fy "$split_vg/$home_name" >/dev/null 2>&1 || true
                        dialog_message "LVM equal split"                                 "Creating '$split_vg/$var_name' failed. The newly created '$home_name' LV was rolled back where possible. Review LVM status before continuing."
                        refresh_storage_state
                        return 1
                fi

                actual_home="$(lvs --noheadings --units b --nosuffix -o lv_size "$split_vg/$home_name" 3>&- 4>&- 2>/dev/null | awk '{printf "%.0f", $1}')"
                actual_var="$(lvs --noheadings --units b --nosuffix -o lv_size "$split_vg/$var_name" 3>&- 4>&- 2>/dev/null | awk '{printf "%.0f", $1}')"
                home_actual_extents=$(( actual_home / extent_bytes ))
                var_actual_extents=$(( actual_var / extent_bytes ))

                if (( home_actual_extents < home_extents - 1 || home_actual_extents > home_extents + 1 ||
                      var_actual_extents < var_extents - 1 || var_actual_extents > var_extents + 1 )); then
                        dialog_message "LVM equal split"                                 "Post-create validation failed.\n\nPlanned: home=$home_extents extents, var=$var_extents extents\nActual: home=$home_actual_extents extents, var=$var_actual_extents extents\n\nStop and review the LVM layout before formatting."
                        refresh_storage_state
                        return 1
                fi

                refresh_storage_state
                dialog_message "LVM equal split"                         "Created and validated '$split_vg/$home_name' and '$split_vg/$var_name'.\n\n$(lvm_vg_capacity_text "$split_vg")"
                return 0
        }

        while true; do
                set +e
                themed_menu choice \
                        "LVM storage" \
                        "Create or inspect Linux Logical Volume Manager objects. Current capacity is shown in human-readable IEC units (KiB/MiB/GiB/TiB)." \
                        18 74 8 \
                        1 "Create a physical volume" \
                        2 "Create a volume group" \
                        3 "Create a logical volume" \
                        4 "Create equal /home + /var LVs" \
                        5 "Show LVM devices" \
                        6 "Help" \
                        7 "Return to Storage setup"
                status=$?
                set -e
                [[ -n "$choice" ]] || return 0

                case "$choice" in
                        1)
                                command -v pvcreate >/dev/null 2>&1 || {
                                        warn "LVM tools are unavailable."
                                        pause_screen
                                        continue
                                }
                                pv_list=""
                                select_pv_devices pv_list || continue
                                read -r -a pv_array <<< "$pv_list"
                                confirm "Initialize these device(s) as LVM physical volumes?\n\n${pv_array[*]}" || continue
                                if ! lvm_run pvcreate "${pv_array[@]}"; then
                                        dialog_message "LVM error" "pvcreate failed. Returning to the LVM menu."
                                        continue
                                fi
                                refresh_storage_state
                                dialog_message "LVM physical volume" "Physical volume creation completed successfully.\n\n${pv_array[*]}"
                                ;;
                        2)
                                command -v vgcreate >/dev/null 2>&1 || {
                                        warn "LVM tools are unavailable."
                                        pause_screen
                                        continue
                                }
                                vg_name=""
                                pv_list=""
                                ask_default vg_name "New volume-group name" "bfs-vg" || continue
                                select_existing_pvs pv_list || continue
                                [[ -n "$vg_name" && -n "$pv_list" ]] || {
                                        dialog_message "LVM volume group" "A volume-group name and at least one physical volume are required."
                                        continue
                                }
                                read -r -a pv_array <<< "$pv_list"
                                if ! lvm_run vgcreate "$vg_name" "${pv_array[@]}"; then
                                        warn "vgcreate failed. Returning to the LVM menu."
                                        pause_screen
                                        continue
                                fi
                                ACTIVATED_VGS_BY_SCRIPT+=("$vg_name")
                                refresh_storage_state
                                dialog_message "LVM volume group" "Volume group '$vg_name' created successfully."
                                ;;
                        3)
                                command -v lvcreate >/dev/null 2>&1 || {
                                        warn "LVM tools are unavailable."
                                        pause_screen
                                        continue
                                }
                                vg_name=""
                                lv_name=""
                                lv_size=""
                                select_existing_vg vg_name || continue
                                ask_default lv_name "Logical-volume name" "home" || continue
                                local vg_capacity
                                vg_capacity="$(lvm_vg_capacity_text "$vg_name")"
                                ask_default lv_size \
                                        "${vg_capacity}\n\nLV size: 10G, 50%FREE, 50%VG, or 100%FREE. Use %FREE for remaining free space; %VG means total VG size." \
                                        "50%FREE" || continue

                                [[ "$vg_name" =~ ^[A-Za-z0-9+_.-]+$ ]] || {
                                        warn "Invalid volume-group name: $vg_name"
                                        pause_screen
                                        continue
                                }
                                [[ "$lv_name" =~ ^[A-Za-z0-9+_.-]+$ ]] || {
                                        warn "Invalid logical-volume name: $lv_name"
                                        pause_screen
                                        continue
                                }

                                normalized_size="${lv_size^^}"
                                normalized_size="${normalized_size//[[:space:]]/}"

                                # Bare percentages were ambiguous and previously meant %VG,
                                # which produced surprising allocations when mixed with fixed-size
                                # LVs. Require the user to state whether a percentage applies to
                                # the total VG or the currently free extents.
                                if [[ "$normalized_size" =~ ^([1-9][0-9]?|100)%$ ]]; then
                                        dialog_message "LVM logical volume" \
                                                "Ambiguous size '$lv_size'.\n\nUse ${BASH_REMATCH[1]}%FREE for a percentage of the currently free space, or ${BASH_REMATCH[1]}%VG for a percentage of the entire volume group.\n\nNo logical volume was created."
                                        continue
                                fi

                                if [[ "$normalized_size" =~ ^([1-9][0-9]?|100)%(VG|FREE)$ ]]; then
                                        local extents_total extents_free requested_extents effective_bytes basis percent extent_bytes free_bytes
                                        extents_total="$(vgs --noheadings --nosuffix -o vg_extent_count "$vg_name" 2>/dev/null | awk '{print int($1)}')"
                                        extents_free="$(vgs --noheadings --nosuffix -o vg_free_count "$vg_name" 2>/dev/null | awk '{print int($1)}')"
                                        percent="${BASH_REMATCH[1]}"
                                        basis="${BASH_REMATCH[2]}"
                                        if [[ "$basis" == FREE ]]; then
                                                requested_extents=$(( extents_free * percent / 100 ))
                                        else
                                                requested_extents=$(( extents_total * percent / 100 ))
                                        fi
                                        (( requested_extents > 0 )) || {
                                                dialog_message "LVM logical volume" "The requested size resolves to zero allocatable extents. No logical volume was created."
                                                continue
                                        }
                                        if (( requested_extents > extents_free )); then
                                                dialog_message "LVM logical volume" \
                                                        "Requested size: $normalized_size\nAvailable free extents: $extents_free\nRequired extents: $requested_extents\n\nThe request does not fit. Nothing will be silently clamped; choose a smaller size."
                                                continue
                                        fi
                                        extent_bytes="$(vgs --noheadings --units b --nosuffix -o vg_extent_size "$vg_name" 2>/dev/null | awk '{printf "%.0f", $1}')"
                                        effective_bytes=$(( extent_bytes * requested_extents ))
                                        free_bytes=$(( extent_bytes * extents_free ))
                                        confirm "Create logical volume '$lv_name' in '$vg_name'?\n\n$(lvm_vg_capacity_text "$vg_name")\nRequested: $normalized_size\nEffective allocation: approximately $(human_iec_bytes "$effective_bytes") ($requested_extents extents)\nProjected free after: approximately $(human_iec_bytes "$((free_bytes-effective_bytes))")" || continue
                                        if ! lvm_run lvcreate -l "$requested_extents" -n "$lv_name" "$vg_name"; then
                                                warn "lvcreate failed. Check the requested percentage and free space; the installer will continue."
                                                pause_screen
                                                continue
                                        fi
                                elif [[ "$normalized_size" =~ ^[1-9][0-9]*([.][0-9]+)?[KMGTPE]$ ]]; then
                                        confirm "Create logical volume '$lv_name' in '$vg_name'?\n\n$(lvm_vg_capacity_text "$vg_name")\nRequested size: $normalized_size" || continue
                                        if ! lvm_run lvcreate -L "$normalized_size" -n "$lv_name" "$vg_name"; then
                                                warn "lvcreate failed. Check the requested size and free space; the installer will continue."
                                                pause_screen
                                                continue
                                        fi
                                else
                                        warn "Invalid LV size '$lv_size'. Use values such as 10G, 50%VG, 50%FREE, or 100%FREE."
                                        pause_screen
                                        continue
                                fi

                                refresh_storage_state
                                dialog_message "LVM logical volume" "Logical volume '$lv_name' created successfully in '$vg_name'.\n\n$(lvm_vg_capacity_text "$vg_name")"
                                ;;
                        4)
                                create_equal_home_var_lvs || true
                                ;;
                        5)
                                show_lvm_status_dialog
                                ;;
                        6) show_installer_help lvm ;;
                        7) return 0 ;;
                        *) warn "Choose a valid LVM option."; sleep 1 ;;
                esac
        done
}

show_current_storage_dialog() {
        local tmp zram_state="" zram_size=""
        tmp="$(mktemp /tmp/bfs-storage-devices.XXXXXX)"
        {
                lsblk -fp -o NAME,FSTYPE,FSVER,LABEL,UUID,FSAVAIL,FSUSE%,MOUNTPOINTS 2>&1 || true
                printf '\nInstaller ZRAM configuration\n-----------------------------\n'
                if [[ "$ZRAM_SWAP" == yes ]]; then
                        zram_state="configured"
                        zram_size="$ZRAM_SIZE_SPEC"
                        if [[ -b /dev/zram0 ]]; then
                                zram_state="active/configured"
                                zram_size="$(lsblk -dnro SIZE /dev/zram0 2>/dev/null | head -n1 || true) (device), $ZRAM_SIZE_SPEC (configured)"
                        fi
                        printf 'ZRAM swap: enabled, %s [%s]\n' "$zram_size" "$zram_state"
                else
                        printf 'ZRAM swap: disabled\n'
                fi
        } >"$tmp"
        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear --backtitle "BFSOS Installer" \
                        --title "Current storage devices" --exit-label "Return" --textbox "$tmp" 24 110 \
                        </dev/tty >/dev/tty 2>/dev/tty || true
        else
                cat "$tmp"
        fi
        rm -f "$tmp"
}

storage_menu() {
        local choice="" status=0

        while true; do
                set +e
                themed_menu choice \
                        "Storage setup" \
                        "Use only the storage tools you need. Existing partitions may be assigned directly." \
                        22 84 12 \
                        1 "Partition disks with cfdisk (optional)" \
                        2 "Create or assemble software RAID (optional)" \
                        3 "Configure LUKS encryption (optional)" \
                        4 "Configure LVM (optional)" \
                        5 "Assign filesystems and mount points (required)" \
                        6 "Configure ZRAM swap (optional) [$ZRAM_SWAP, $ZRAM_SIZE_SPEC]" \
                        7 "Show current storage devices" \
                        8 "Help / storage safety" \
                        9 "Return to main menu"
                status=$?
                set -e
                [[ -n "$choice" ]] || return 0

                case "$choice" in
                        1) partition_disks ;;
                        2) raid_menu ;;
                        3) luks_menu ;;
                        4) lvm_menu ;;
                        5) configure_disks ;;
                        6) configure_zram_menu ;;
                        7) show_current_storage_dialog ;;
                        8) show_installer_help storage ;;
                        9) return 0 ;;
                        *) warn "Choose a valid storage option."; sleep 1 ;;
                esac
        done
}


choose_storage_format() {
        local result_variable="$1"
        local device="$2"
        local selection=""
        local status=0

        set +e
        themed_menu selection \
                "Filesystem action" \
                "Choose whether to keep or format $device." \
                20 82 11 \
                1 "Do not format; keep the existing filesystem" \
                2 "Format as ext2" \
                3 "Format as ext4" \
                4 "Format as XFS" \
                5 "Format as Btrfs" \
                6 "Format as F2FS" \
                7 "Format as FAT32 (EFI or other VFAT use)" \
                8 "Initialize as swap"
        status=$?
        set -e

        [[ -n "$selection" ]] || return 1

        case "$selection" in
                1) printf -v "$result_variable" '%s' keep ;;
                2) printf -v "$result_variable" '%s' ext2 ;;
                3) printf -v "$result_variable" '%s' ext4 ;;
                4) printf -v "$result_variable" '%s' xfs ;;
                5) printf -v "$result_variable" '%s' btrfs ;;
                6) printf -v "$result_variable" '%s' f2fs ;;
                7) printf -v "$result_variable" '%s' vfat ;;
                8) printf -v "$result_variable" '%s' swap ;;
                *) return 1 ;;
        esac
}

ask_mountpoint_dialog() {
        local result_variable="$1"
        local device="$2"
        local format="$3"
        local value=""
        local status=0
        local default_value="/"
        local base="${device##*/}"

        # Suggest obvious mount points, but always leave the value editable.
        case "$base" in
                root|luksroot) default_value=/ ;;
                usr) default_value=/usr ;;
                opt) default_value=/opt ;;
                home) default_value=/home ;;
                var) default_value=/var ;;
                tmp) default_value=/tmp ;;
                srv) default_value=/srv ;;
                swap) default_value=swap ;;
                *)
                        if [[ "$format" == ext2 ]] && ! storage_mountpoint_in_use /boot; then
                                default_value=/boot
                        elif [[ "$format" == vfat ]] && ! storage_mountpoint_in_use /boot/efi; then
                                default_value=/boot/efi
                        fi
                        ;;
        esac

        if [[ "$format" == swap ]]; then
                printf -v "$result_variable" '%s' swap
                return 0
        fi

        while true; do
                if command -v dialog >/dev/null 2>&1 &&
                   [[ -r /dev/tty && -w /dev/tty ]]; then
                        if value="$(
                                dialog --stdout --clear \
                                        --backtitle "BFSOS Installer" \
                                        --title "Mount point" \
                                        --cancel-label "Back" \
                                        --inputbox \
                                        "Enter where $device should be mounted.\n\nExamples: /, /boot, /boot/efi, /home, /var" \
                                        14 76 "$default_value" \
                                        </dev/tty
                        )"; then
                                status=0
                        else
                                status=$?
                        fi
                        ((status == 0)) || return 1
                else
                        read -r -p "Mount point for $device: " value
                fi

                value="$(
                        printf '%s' "$value" |
                                tr -d '\r\n' |
                                sed -e 's/^[[:space:]]*//' \
                                    -e 's/[[:space:]]*$//'
                )"

                if [[ "$value" == /* &&
                      "$value" != *'..'* &&
                      "$value" != *' '* ]]; then
                        printf -v "$result_variable" '%s' "$value"
                        return 0
                fi

                warn "Use an absolute mount point such as /, /home, or /var."
                sleep 1
        done
}

storage_mountpoint_in_use() {
        local wanted="$1"
        local existing=""

        for existing in "${STORAGE_MOUNTPOINTS[@]}"; do
                [[ "$existing" == "$wanted" ]] && return 0
        done
        return 1
}

storage_selection_summary_text() {
        local index=0 action="" format="" dev=""
        printf '%s
' "Selected filesystems and mount points" "====================================" ""
        printf '%-4s %-38s %-22s %s
' NUM DEVICE ACTION MOUNTPOINT
        printf '%-4s %-38s %-22s %s
' --- ------ ------ ----------
        for ((index=0; index<${#STORAGE_DEVICES[@]}; index++)); do
                format="${STORAGE_FORMATS[$index]}"
                dev="${STORAGE_DEVICES[$index]}"
                if [[ "$format" == keep ]]; then
                        action="KEEP"
                else
                        action="FORMAT as $format"
                fi
                printf '%-4d %-38s %-22s %s
' \
                        "$((index + 1))" "$dev" "$action" "${STORAGE_MOUNTPOINTS[$index]}"
        done
}

confirm_storage_selection_plan() {
        local tmp="" choice="" status=0
        tmp="$(mktemp /tmp/bfs-filesystem-plan.XXXXXX)"
        storage_selection_summary_text >"$tmp"

        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear --backtitle "BFSOS Installer" \
                        --title "Filesystem plan" \
                        --yes-label "Continue" \
                        --no-label "Back" \
                        --yesno "$(cat "$tmp")" 28 118 \
                        </dev/tty >/dev/tty 2>/dev/tty
                status=$?
                rm -f "$tmp"
                ((status == 0))
                return
        fi

        cat "$tmp"
        rm -f "$tmp"
        read -r -p "Use these selections? [Y/n]: " choice
        [[ -z "$choice" || "${choice,,}" == y || "${choice,,}" == yes ]]
}

show_storage_selection_summary() {
        local text
        text="$(storage_selection_summary_text)"
        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear --backtitle "BFSOS Installer" \
                        --title "Filesystem plan" --msgbox "$text" 22 100 \
                        </dev/tty >/dev/tty 2>/dev/tty || true
        else
                clear_screen
                printf '%s\n' "$text"
        fi
}

apply_storage_selections() {
        local index=0
        local device=""
        local format=""
        local mountpoint=""

        ROOT_DEV=""
        BOOT_DEV=""
        EFI_DEV=""
        SWAP_DEV=""
        HOME_DEV=""

        ROOT_FORMAT=keep
        BOOT_FORMAT=keep
        EFI_FORMAT=keep
        SWAP_FORMAT=keep
        HOME_FORMAT=keep

        EXTRA_DEVICES=()
        EXTRA_MOUNTPOINTS=()
        EXTRA_FORMATS=()

        for ((index=0; index<${#STORAGE_DEVICES[@]}; index++)); do
                device="${STORAGE_DEVICES[$index]}"
                format="${STORAGE_FORMATS[$index]}"
                mountpoint="${STORAGE_MOUNTPOINTS[$index]}"

                case "$mountpoint" in
                        /)
                                ROOT_DEV="$device"
                                ROOT_FORMAT="$format"
                                ;;
                        /boot)
                                BOOT_DEV="$device"
                                BOOT_FORMAT="$format"
                                ;;
                        /boot/efi)
                                EFI_DEV="$device"
                                EFI_FORMAT="$format"
                                ;;
                        /home)
                                HOME_DEV="$device"
                                HOME_FORMAT="$format"
                                ;;
                        swap)
                                SWAP_DEV="$device"
                                SWAP_FORMAT="$format"
                                ;;
                        *)
                                EXTRA_DEVICES+=("$device")
                                EXTRA_MOUNTPOINTS+=("$mountpoint")
                                EXTRA_FORMATS+=("$format")
                                ;;
                esac
        done

        [[ -n "$ROOT_DEV" ]] || {
                warn "A root filesystem mounted at / is required."
                return 1
        }

        DISKS_CONFIGURED=yes
        return 0
}

configure_disks() {
        local device=""
        local format=""
        local mountpoint=""
        local choice=""
        local status=0
        local confirmed=no
        local index=0

        while true; do
                USED_DEVICES=()
                STORAGE_DEVICES=()
                STORAGE_FORMATS=()
                STORAGE_MOUNTPOINTS=()

                while true; do
                        get_available_partitions

                        if ((${#AVAILABLE_PATHS[@]} == 0)); then
                                if [[ ${#STORAGE_DEVICES[@]} -eq 0 ]]; then
                                        dialog_message "No usable partitions" \
                                                "No usable partitions were found.\n\nThis is normal for a blank or freshly wiped disk. Return to the storage menu, create a partition table and partitions, then rescan."
                                        log "No usable partitions found; returning to the previous storage menu"
                                        return 0
                                fi
                                break
                        fi

                        device=""
                        set +e
                        select_partition device \
                                "Select a device to add/edit its filesystem and mount point.\n\nCurrent selections: ${#STORAGE_DEVICES[@]}\nChoose Done when all filesystems are assigned." \
                                yes \
                                "Done selecting filesystems"
                        status=$?
                        set -e
                        if ((status == 2)); then
                                return 0
                        elif ((status != 0)); then
                                continue
                        fi

                        [[ -n "$device" ]] || break

                        format=""
                        if ! choose_storage_format format "$device"; then
                                continue
                        fi

                        mountpoint=""
                        if ! ask_mountpoint_dialog mountpoint "$device" "$format"; then
                                continue
                        fi

                        if storage_mountpoint_in_use "$mountpoint"; then
                                warn "The mount point $mountpoint has already been assigned."
                                sleep 1
                                continue
                        fi

                        STORAGE_DEVICES+=("$device")
                        STORAGE_FORMATS+=("$format")
                        STORAGE_MOUNTPOINTS+=("$mountpoint")

                        # Return to the same device-selection menu. The user
                        # chooses "Done selecting filesystems" when complete,
                        # instead of answering a repeated Add another? prompt.
                        continue
                done

                if ((${#STORAGE_DEVICES[@]} == 0)); then
                        dialog_message "Filesystem assignment" "No filesystem assignments were saved. Returning to Storage setup."
                        return 0
                fi

                if ! apply_storage_selections; then
                        dialog_message "Filesystem assignment" "The filesystem plan is incomplete or invalid. Review the assignments and try again."
                        continue
                fi

                if confirm_storage_selection_plan; then
                        confirmed=yes
                else
                        confirmed=no
                fi

                if [[ "$confirmed" == yes ]]; then
                        DISKS_CONFIGURED=yes
                        validate_zram_settings
                        return 0
                fi
        done
}


supported_base_archive() {
        local file="$1"
        [[ -f "$file" && -r "$file" ]] || return 1
        case "$file" in
                *.tar.xz|*.tar.zst|*.tar.gz) return 0 ;;
                *) return 1 ;;
        esac
}

archive_timestamp_key() {
        local file="$1" base="" mtime=""
        base="$(basename "$file")"
        if [[ "$base" =~ ([0-9]{8})[-_]?([0-9]{6}) ]]; then
                printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
                return 0
        fi
        mtime="$(stat -c '%Y' "$file" 2>/dev/null || printf '0')"
        printf 'mtime-%020d\n' "$mtime"
}

newest_base_archive() {
        local directory="$1" file="" key="" best="" best_key="" release=""
        [[ -d "$directory" ]] || return 1
        release="${BFS_INSTALL_RELEASE:-$(bfs_release_version)}"
        while IFS= read -r -d '' file; do
                supported_base_archive "$file" || continue
                # Automatic discovery must never silently cross release candidates.
                # A maintainer can still choose another archive explicitly via Browse.
                case "$(basename "$file")" in
                        "BFSOS-base-${release}-"*.tar.*|"bfs-rootfs-${release}-"*.tar.*) ;;
                        *) continue ;;
                esac
                key="$(archive_timestamp_key "$file")"
                if [[ -z "$best" || "$key" > "$best_key" ||
                      ( "$key" == "$best_key" && "$file" > "$best" ) ]]; then
                        best="$file"
                        best_key="$key"
                fi
        done < <(
                find "$directory" -maxdepth 1 -type f \
                        \( -name 'bfs-rootfs-*.tar.xz' -o \
                           -name 'bfs-rootfs-*.tar.zst' -o \
                           -name 'bfs-rootfs-*.tar.gz' -o \
                           -name 'BFSOS-base-*.tar.xz' -o \
                           -name 'BFSOS-base-*.tar.zst' -o \
                           -name 'BFSOS-base-*.tar.gz' \) \
                        -print0 2>/dev/null
        )
        [[ -n "$best" ]] || return 1
        printf '%s\n' "$best"
}

browse_base_archive() {
        local -n result_ref="$1"
        local start_path="$2" picked="" status=0
        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                [[ -d "$start_path" ]] || start_path="$(dirname "$start_path")"
                [[ -d "$start_path" ]] || start_path="/"
                set +e
                picked="$(
                        dialog --stdout --clear \
                                --backtitle "BFSOS Installer" \
                                --title "Select BFSOS base rootfs archive" \
                                --cancel-label "Back" \
                                --fselect "${start_path%/}/" \
                                22 100 \
                                </dev/tty 2>/dev/tty
                )"
                status=$?
                set -e
                ((status == 0)) || return 1
        else
                read -r -p "Path to BFSOS base rootfs archive: " picked
                [[ -n "$picked" ]] || return 1
        fi
        result_ref="$picked"
}

confirm_detected_archive() {
        local archive="$1" choice="" status=0 size="" stamp=""
        size="$(du -h "$archive" 2>/dev/null | awk '{print $1}')"
        stamp="$(date -r "$archive" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                set +e
                choice="$(
                        dialog --stdout --clear \
                                --backtitle "BFSOS Installer" \
                                --title "Base rootfs archive" \
                                --cancel-label "Back" \
                                --menu \
                                "Newest available BFSOS base archive:\n\n$archive\nSize: ${size:-unknown}\nTimestamp: ${stamp:-unknown}\n\nChoose an action." \
                                18 100 5 \
                                use "Use this archive" \
                                browse "Browse for a different archive" \
                                </dev/tty 2>/dev/tty
                )"
                status=$?
                set -e
                ((status == 0)) || return 2
                case "$choice" in
                        use) return 0 ;;
                        browse) return 1 ;;
                        *) return 2 ;;
                esac
        fi
        printf '\nNewest available BFSOS base archive:\n  %s\n  Size: %s\n  Timestamp: %s\n' \
                "$archive" "${size:-unknown}" "${stamp:-unknown}"
        read -r -p "Use this archive? [Y/n/b=browse]: " choice
        case "${choice,,}" in
                ""|y|yes) return 0 ;;
                b|browse|n|no) return 1 ;;
                *) return 2 ;;
        esac
}



validate_zram_settings() {
        [[ "$ZRAM_SWAP" == yes || "$ZRAM_SWAP" == no ]] || ZRAM_SWAP=no
        [[ "$ZRAM_SWAP" == no ]] && return 0
        [[ "$ZRAM_SIZE_SPEC" =~ ^([1-9][0-9]{0,2})%$ ||
           "$ZRAM_SIZE_SPEC" =~ ^[1-9][0-9]*([.][0-9]+)?[GM]$ ]] || {
                warn "Invalid ZRAM size '$ZRAM_SIZE_SPEC'; using 200%."
                ZRAM_SIZE_SPEC=200%
        }
}

configure_zram_menu() {
        local choice="" custom="" status=0 state_label="" action_label=""
        local label50="" label100="" label150="" label200="" labelcustom=""
        while true; do
                [[ "$ZRAM_SWAP" == yes ]] && state_label="Enabled" || state_label="Disabled"
                [[ "$ZRAM_SWAP" == yes ]] && action_label="Disable ZRAM" || action_label="Enable ZRAM"
                label50="Size: 50% of RAM"
                label100="Size: 100% of RAM"
                label150="Size: 150% of RAM"
                label200="Size: 200% of RAM"
                labelcustom="Custom size (for example 8G or 4096M)"
                if [[ "$ZRAM_SWAP" == yes ]]; then
                        case "$ZRAM_SIZE_SPEC" in
                                50%) label50+="  [CURRENT]" ;;
                                100%) label100+="  [CURRENT]" ;;
                                150%) label150+="  [CURRENT]" ;;
                                200%) label200+="  [CURRENT]" ;;
                                *) labelcustom="Custom size: $ZRAM_SIZE_SPEC  [CURRENT]" ;;
                        esac
                fi
                themed_menu choice \
                        "ZRAM swap" \
                        "Current status: $state_label    Current size: $ZRAM_SIZE_SPEC" \
                        19 82 9 \
                        1 "$action_label" \
                        2 "$label50" \
                        3 "$label100" \
                        4 "$label150" \
                        5 "$label200" \
                        6 "$labelcustom" \
                        7 "Help" \
                        8 "Return to Storage setup"
                [[ -n "$choice" ]] || return 0
                case "$choice" in
                        1) [[ "$ZRAM_SWAP" == yes ]] && ZRAM_SWAP=no || ZRAM_SWAP=yes ;;
                        2) ZRAM_SWAP=yes; ZRAM_SIZE_SPEC=50% ;;
                        3) ZRAM_SWAP=yes; ZRAM_SIZE_SPEC=100% ;;
                        4) ZRAM_SWAP=yes; ZRAM_SIZE_SPEC=150% ;;
                        5) ZRAM_SWAP=yes; ZRAM_SIZE_SPEC=200% ;;
                        6)
                                custom=""
                                set +e
                                themed_inputbox custom "ZRAM custom size" \
                                        "Enter a fixed ZRAM size such as 8G or 4096M." \
                                        "$ZRAM_SIZE_SPEC"
                                status=$?
                                set -e
                                ((status == 0)) || continue
                                custom="${custom^^}"
                                custom="${custom//[[:space:]]/}"
                                if [[ "$custom" =~ ^[1-9][0-9]*([.][0-9]+)?[GM]$ ]]; then
                                        ZRAM_SWAP=yes
                                        ZRAM_SIZE_SPEC="$custom"
                                else
                                        dialog_message "ZRAM size" "Invalid size '$custom'. Use values such as 8G or 4096M."
                                fi
                                ;;
                        7) show_installer_help zram ;;
                        8) return 0 ;;
                esac
        done
}


# Dedicated result channel for base-archive selection.  Do not use stdout or
# nested namerefs here: wget progress and Bash dynamic scoping have both caused
# the post-download pathname to be lost/contaminated in the live installer.
BASE_ARCHIVE_RESULT=""

bfs_release_version() {
        local release=""
        if [[ -r "$PROJECT_DIR/VERSION" ]]; then
                release="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
        fi
        if [[ -z "$release" && -r /etc/os-release ]]; then
                release="$(awk -F= '$1 == "VERSION_ID" {gsub(/^['"']|['"']$/, "", $2); print $2; exit}' /etc/os-release)"
        fi
        printf '%s\n' "${release:-0.9.0}"
}

fetch_sourceforge_base() {
        local archive_dir="$1"
        local release="${BFS_INSTALL_RELEASE:-$(bfs_release_version)}"
        local filename="${BFS_INSTALL_BASE_FILENAME:-BFSOS-base-${release}-x86_64.tar.zst}"
        local url="${BFS_INSTALL_BASE_URL:-https://downloads.sourceforge.net/project/bfsos/BFSOS/base/latest/${filename}}"
        local sha_url="${BFS_INSTALL_BASE_SHA256_URL:-https://downloads.sourceforge.net/project/bfsos/BFSOS/base/latest/${filename}.sha256}"
        local ca_file="${BFS_INSTALL_CA_FILE:-/etc/pki/tls/certs/ca-bundle.crt}"
        local archive="$archive_dir/$filename"
        local sha_file="$archive.sha256"
        local expected="" actual="" status=0
        local -a wget_args=()

        BASE_ARCHIVE_RESULT=""

        command -v wget >/dev/null 2>&1 || {
                dialog_message "Base download failed" \
                        "wget is required to download the BFSOS base archive."
                return 1
        }
        command -v sha256sum >/dev/null 2>&1 || {
                dialog_message "Base verification failed" \
                        "sha256sum is required to verify the BFSOS base archive."
                return 1
        }

        mkdir -p "$archive_dir" || return 1

        # BFSOS ships a canonical CA bundle here.  Keep this explicit until
        # every supported wget build has been verified to discover it by
        # default; never weaken TLS verification to work around trust lookup.
        if [[ -r "$ca_file" ]]; then
                wget_args+=(--ca-certificate="$ca_file")
        fi

        rm -f "$archive" "$sha_file"

        if { : </dev/tty; } 2>/dev/null; then
                clear_screen >/dev/tty 2>/dev/null || true
                printf '\nBFSOS base download\n===================\n\nRelease: %s\nFile:    %s\nSource:  %s\n\n' \
                        "$release" "$filename" "$url" >/dev/tty
                set +e
                wget "${wget_args[@]}" -O "$archive" "$url" </dev/tty >/dev/tty 2>/dev/tty
                status=$?
                set -e
        else
                printf '\nDownloading BFSOS base: %s\n' "$filename" >&2
                set +e
                wget "${wget_args[@]}" -O "$archive" "$url" >&2
                status=$?
                set -e
        fi
        if ((status != 0)); then
                rm -f "$archive" "$sha_file"
                dialog_message "Base download failed" \
                        "The BFSOS base archive download failed.\n\nSource: $url\n\nYou may retry, browse for a local archive, or go back."
                return 1
        fi

        if { : </dev/tty; } 2>/dev/null; then
                printf '\nArchive download complete.\n\nDownloading SHA256 verification file...\n\n' >/dev/tty
                set +e
                wget "${wget_args[@]}" -O "$sha_file" "$sha_url" </dev/tty >/dev/tty 2>/dev/tty
                status=$?
                set -e
        else
                printf 'Downloading SHA256 verification file...\n' >&2
                set +e
                wget "${wget_args[@]}" -O "$sha_file" "$sha_url" >&2
                status=$?
                set -e
        fi
        if ((status != 0)); then
                rm -f "$archive" "$sha_file"
                dialog_message "Base verification failed" \
                        "The BFSOS SHA256 file could not be downloaded.\n\nSource: $sha_url"
                return 1
        fi

        expected="$(awk 'NR == 1 { print $1 }' "$sha_file")"
        actual="$(sha256sum "$archive" | awk '{ print $1 }')"

        if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
                rm -f "$archive" "$sha_file"
                dialog_message "Base verification failed" \
                        "The downloaded SHA256 file did not contain a valid checksum."
                return 1
        fi

        if [[ "$actual" != "$expected" ]]; then
                rm -f "$archive" "$sha_file"
                dialog_message "Base verification failed" \
                        "SHA256 verification FAILED for:\n\n$filename\n\nThe downloaded archive was removed."
                return 1
        fi

        if ! supported_base_archive "$archive"; then
                dialog_message "Base verification failed" \
                        "The verified download exists but the installer cannot use its pathname:\n\n$archive"
                return 1
        fi

        log "Verified BFSOS base artifact: release=$release file=$filename sha256=$actual source=$url"
        dialog_message "Base archive verified" \
                "Download complete and SHA256 verification passed.\n\nRelease: $release\nFile: $filename\nSHA256: $actual\nSource: $url"
        BASE_ARCHIVE_RESULT="$archive"
        return 0
}

choose_missing_base_archive() {
        local archive_dir="$1" choice="" chosen=""
        BASE_ARCHIVE_RESULT=""

        while true; do
                themed_menu choice \
                        "Base archive" \
                        "No local BFSOS base archive was detected.\n\nChoose how to provide the base filesystem." \
                        16 94 5 \
                        1 "Download current BFSOS base from SourceForge" \
                        2 "Browse for local base archive" \
                        3 "Help" \
                        4 "Back"

                case "$choice" in
                        1)
                                if fetch_sourceforge_base "$archive_dir"; then
                                        if [[ -n "$BASE_ARCHIVE_RESULT" ]] && supported_base_archive "$BASE_ARCHIVE_RESULT"; then
                                                return 0
                                        fi
                                        dialog_message "Base archive handoff failed" \
                                                "The SourceForge download verified, but its local pathname was not handed back correctly.\n\nValue: ${BASE_ARCHIVE_RESULT:-<empty>}"
                                fi
                                ;;
                        2)
                                chosen=""
                                if browse_base_archive chosen "$archive_dir"; then
                                        BASE_ARCHIVE_RESULT="$chosen"
                                        return 0
                                fi
                                ;;
                        3) show_installer_help base ;;
                        4|"") return 1 ;;
                esac
        done
}

configure_archive() {
        local installer_dir="" project_dir="" archive_dir=""
        local default_archive="" selected="" action_status=0

        installer_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ "$(basename "$installer_dir")" == scripts ]]; then
                project_dir="$(cd "$installer_dir/.." && pwd)"
        elif [[ -d "$installer_dir/archives/base" ]]; then
                project_dir="$installer_dir"
        elif [[ -n "${HOME:-}" && -d "$HOME/BFSOS/archives/base" ]]; then
                project_dir="$HOME/BFSOS"
        else
                project_dir="$PROJECT_DIR"
        fi
        archive_dir="$project_dir/archives/base"

        if [[ -n "$ARCHIVE" ]] && supported_base_archive "$ARCHIVE"; then
                default_archive="$ARCHIVE"
        else
                default_archive="$(newest_base_archive "$archive_dir" 2>/dev/null || true)"
        fi

        while true; do
                selected=""
                if [[ -n "$default_archive" ]]; then
                        set +e
                        confirm_detected_archive "$default_archive"
                        action_status=$?
                        set -e
                        case "$action_status" in
                                0) selected="$default_archive" ;;
                                1)
                                        if ! browse_base_archive selected "$archive_dir"; then
                                                return 0
                                        fi
                                        ;;
                                2) return 0 ;;
                        esac
                else
                        if ! choose_missing_base_archive "$archive_dir"; then
                                return 0
                        fi
                        selected="$BASE_ARCHIVE_RESULT"
                fi

                if ! supported_base_archive "$selected"; then
                        dialog_message "Invalid base archive" \
                                "The selected file is missing, unreadable, or unsupported:\n\n$selected\n\nSupported formats: .tar.xz, .tar.zst, .tar.gz"
                        default_archive=""
                        continue
                fi
                ARCHIVE="$selected"
                break
        done

        ask_yes_no SAVE_BASE_ARCHIVE \
                "Save a copy of the BFS base archive on the installed system?" \
                "$SAVE_BASE_ARCHIVE"
        ARCHIVE_CONFIGURED=yes
}

detect_console_video_argument() {
        local status_file="" connector=""
        CONSOLE_VIDEO_ARG=""
        [[ -n "$CONSOLE_VIDEO_MODE" ]] || return 0
        for status_file in /sys/class/drm/card*-*/status; do
                [[ -r "$status_file" ]] || continue
                [[ "$(cat "$status_file" 2>/dev/null)" == connected ]] || continue
                connector="$(basename "${status_file%/status}")"
                connector="${connector#card*-}"
                [[ -n "$connector" ]] || continue

                # Do not force a mode the display does not advertise.  The
                # tested high-DPI default is 1920x1080@60, but lower-resolution
                # panels should simply keep their native/default console mode.
                if [[ -r "${status_file%/status}/modes" ]] &&
                   ! grep -qx "${CONSOLE_VIDEO_MODE%@*}" "${status_file%/status}/modes" 2>/dev/null; then
                        log "Connected DRM output $connector does not advertise ${CONSOLE_VIDEO_MODE%@*}; leaving console video mode unchanged"
                        continue
                fi

                CONSOLE_VIDEO_ARG="video=${connector}:${CONSOLE_VIDEO_MODE}"
                log "Detected connected DRM console output: $connector; default text-console mode: $CONSOLE_VIDEO_MODE"
                return 0
        done
        log "No suitable connected DRM connector was detected for $CONSOLE_VIDEO_MODE; leaving console video mode unchanged"
}

recalculate_system_settings_status() {
        BASIC_SYSTEM_CONFIGURED=$([[ -n "$HOSTNAME" && -n "$TIMEZONE" && -n "$LOCALE" ]] && echo yes || echo no)
        USERS_CONFIGURED=$([[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && echo yes || echo no)
        NETWORK_CONFIGURED=$([[ -n "$NETWORK_IFACE" && -n "$NETWORK_TARGET_NAME" ]] && echo yes || echo no)
        SSH_CONFIGURED=yes
        [[ "$ROOT_PASSWORD_POLICY" == locked || "$ROOT_PASSWORD_POLICY" == prompt ]] || ROOT_PASSWORD_POLICY=locked

        if [[ "$BASIC_SYSTEM_CONFIGURED" == yes &&
              "$USERS_CONFIGURED" == yes &&
              "$NETWORK_CONFIGURED" == yes &&
              "$SSH_CONFIGURED" == yes ]]; then
                SYSTEM_CONFIGURED=yes
        else
                SYSTEM_CONFIGURED=no
        fi
}

configure_basic_system() {
        local choice=""
        while true; do
                recalculate_system_settings_status
                themed_menu choice "Hostname / timezone / locale" \
                        "Review the current defaults below. Leave any value as-is or select only the field you want to change." \
                        20 92 9 \
                        1 "Hostname: $HOSTNAME" \
                        2 "Timezone: $TIMEZONE" \
                        3 "Locale: $LOCALE" \
                        4 "Done [$(completion_status "$BASIC_SYSTEM_CONFIGURED")]"
                case "$choice" in
                        1) ask_default HOSTNAME "Hostname" "$HOSTNAME" || true ;;
                        2) ask_default TIMEZONE "Timezone" "$TIMEZONE" || true ;;
                        3) ask_default LOCALE "Locale, for example en_US.UTF-8" "$LOCALE" || true ;;
                        4|"") recalculate_system_settings_status; return 0 ;;
                esac
        done
}

valid_username() {
        [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

username_selected() {
        local wanted="$1"
        local existing=""

        [[ "$USERNAME" == "$wanted" ]] && return 0

        for existing in "${ADDITIONAL_USERS[@]}"; do
                [[ "$existing" == "$wanted" ]] && return 0
        done

        return 1
}

username_conflicts_with_group() {
        local wanted="$1"
        local group_file=""

        # Private-primary-group account creation (`useradd -U`) cannot use a
        # username whose same-named group already exists. Check both an
        # already-extracted target and the BFSOS aaa_filesystem source shipped
        # with the project so this is caught in the configuration UI before
        # the install transaction begins.
        for group_file in \
                "$TARGET/etc/group" \
                "$PROJECT_DIR/ports/core/aaa_filesystem/group"; do
                [[ -r "$group_file" ]] || continue
                if awk -F: -v wanted="$wanted" '$1 == wanted { found=1; exit } END { exit !found }' "$group_file"; then
                        return 0
                fi
        done

        return 1
}

account_type_label() {
        case "${1:-standard}" in
                service) printf '%s' "System/service account" ;;
                service-login) printf '%s' "System/service account (interactive)" ;;
                *) printf '%s' "Standard user" ;;
        esac
}

completion_status() {
        [[ "${1:-no}" == yes ]] && printf '%s' "COMPLETE" || printf '%s' "INCOMPLETE"
}

valid_group_list() {
        local value="${1:-}"
        [[ -z "$value" || "$value" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]]
}

show_accounts_review() {
        local i type groups text=""
        local standard_groups_line1="users,wheel,audio,video,optical"
        local standard_groups_line2="cdrom,plugdev,storage,input,render"

        text+="PRIMARY ACCOUNT\n"
        text+="---------------\n"
        if [[ -n "$USERNAME" ]]; then
                text+="User:       $USERNAME\n"
                text+="Type:       Standard user [STANDARD]\n"
                text+="Groups:     Standard BFSOS groups\n"
                text+="            $standard_groups_line1\n"
                text+="            $standard_groups_line2\n"
                text+="Login:      Interactive shell (/bin/bash)\n"
                text+="Password:   Optional; blank keeps password login locked\n"
        else
                text+="User:       not configured\n"
        fi

        text+="\nADDITIONAL ACCOUNTS\n"
        text+="-------------------\n"
        if ((${#ADDITIONAL_USERS[@]})); then
                for ((i=0; i<${#ADDITIONAL_USERS[@]}; i++)); do
                        type="${ADDITIONAL_USER_TYPES[$i]:-standard}"
                        groups="${ADDITIONAL_USER_GROUPS[$i]:-}"
                        ((i == 0)) || text+="\n"
                        text+="Account $((i+1))\n"
                        text+="User:       ${ADDITIONAL_USERS[$i]}\n"
                        case "$type" in
                                service)
                                        text+="Type:       System/service account [SYSTEM]\n"
                                        text+="Groups:     ${groups:-none}\n"
                                        text+="Login:      Non-interactive (/usr/bin/false)\n"
                                        text+="Password:   Locked\n"
                                        ;;
                                service-login)
                                        text+="Type:       System/service account [SYSTEM]\n"
                                        text+="Groups:     ${groups:-none}\n"
                                        text+="Login:      Interactive shell (/bin/bash)\n"
                                        text+="Password:   Optional; blank keeps password login locked\n"
                                        ;;
                                *)
                                        text+="Type:       Standard user [STANDARD]\n"
                                        text+="Groups:     Standard BFSOS groups\n"
                                        text+="            $standard_groups_line1\n"
                                        text+="            $standard_groups_line2\n"
                                        text+="Login:      Interactive shell (/bin/bash)\n"
                                        text+="Password:   Optional; blank keeps password login locked\n"
                                        ;;
                        esac
                done
        else
                text+="none\n"
        fi

        dialog_message "Users and Groups" "$text"
}

configure_primary_standard_user() {
        local candidate="${USERNAME:-user}"
        while true; do
                if ! ask_default candidate \
                        "Primary Standard user\n\nStandard users receive the normal BFSOS supplementary groups automatically. Passwords are optional during installation; leaving the password blank keeps password login locked." \
                        "$candidate"; then
                        return 0
                fi
                if ! valid_username "$candidate"; then
                        dialog_message "Invalid username" "Use lowercase letters/numbers plus _, or -; the first character must be a letter or underscore."
                        continue
                fi
                if [[ "$candidate" != "$USERNAME" ]] && username_selected "$candidate"; then
                        dialog_message "Duplicate username" "That username is already configured."
                        continue
                fi
                if username_conflicts_with_group "$candidate"; then
                        dialog_message "Username conflicts with existing group" \
                                "The name '$candidate' is already used by a BFSOS group. Standard and System/service accounts use a private primary group by default, so this username cannot be used. Choose another username."
                        continue
                fi
                USERNAME="$candidate"
                USERS_CONFIGURED=yes
                recalculate_system_settings_status
                return 0
        done
}

add_configured_account() {
        local choice="" user_name="" groups="" type=standard
        themed_menu choice "Add account" \
                "Choose the account type. Standard users are normal interactive BFSOS accounts. System/service accounts are restricted identities with no supplementary groups and no interactive/password login by default." \
                18 92 8 \
                1 "Standard user" \
                2 "System/service account" \
                3 "Back"
        case "$choice" in
                1) type=standard ;;
                2) type=service ;;
                *) return 0 ;;
        esac

        while true; do
                ask_default user_name "Username" "user$(( ${#ADDITIONAL_USERS[@]} + 2 ))" || return 0
                valid_username "$user_name" || {
                        dialog_message "Invalid username" "Use lowercase letters/numbers plus _, or -; the first character must be a letter or underscore."
                        continue
                }
                username_selected "$user_name" && {
                        dialog_message "Duplicate username" "That username is already configured."
                        continue
                }
                if username_conflicts_with_group "$user_name"; then
                        dialog_message "Username conflicts with existing group" \
                                "The name '$user_name' is already used by a BFSOS group. This installer creates a private primary group for configured accounts, so choose another username."
                        continue
                fi
                break
        done

        if [[ "$type" == service ]]; then
                ask_default groups \
                        "Optional supplementary groups (comma-separated)\n\nLeave blank for the normal System/service default: its own primary group only. Only explicitly listed groups will be added." \
                        "" || return 0
                groups="${groups// /}"
                if ! valid_group_list "$groups"; then
                        dialog_message "Invalid group list" \
                                "Supplementary groups must be comma-separated group names using letters, numbers, _, ., or - only.\n\nExample: audio,video,input"
                        return 0
                fi
                local allow_login=no
                ask_yes_no allow_login \
                        "Allow an interactive shell for this System/service account?\n\nDefault: No. With No, the account uses /usr/bin/false and remains password-locked. With Yes, it uses /bin/bash and you may optionally set a password during installation." \
                        no || return 0
                [[ "$allow_login" == yes ]] && type=service-login
        fi

        ADDITIONAL_USERS+=("$user_name")
        ADDITIONAL_USER_TYPES+=("$type")
        ADDITIONAL_USER_GROUPS+=("$groups")
        recalculate_system_settings_status
}

modify_configured_account() {
        local choice="" i type groups allow_login
        local -a items=()
        ((${#ADDITIONAL_USERS[@]})) || {
                dialog_message "Modify account" "No additional accounts are configured."
                return 0
        }

        for ((i=0; i<${#ADDITIONAL_USERS[@]}; i++)); do
                items+=("$((i+1))" "${ADDITIONAL_USERS[$i]} - $(account_type_label "${ADDITIONAL_USER_TYPES[$i]:-standard}")")
        done
        themed_menu choice "Modify account" \
                "Select an additional account. The username remains fixed; change account type/login policy or explicit supplementary groups here." \
                21 96 13 "${items[@]}"
        [[ "$choice" =~ ^[0-9]+$ ]] || return 0
        i=$((choice-1))
        ((i>=0 && i<${#ADDITIONAL_USERS[@]})) || return 0

        themed_menu choice "Account type - ${ADDITIONAL_USERS[$i]}" \
                "Choose the account policy. Standard users receive the centralized BFSOS groups. System/service accounts receive no supplementary groups unless explicitly requested." \
                19 96 9 \
                1 "Standard user" \
                2 "System/service account" \
                3 "Back"
        case "$choice" in
                1)
                        ADDITIONAL_USER_TYPES[$i]=standard
                        ADDITIONAL_USER_GROUPS[$i]=""
                        ;;
                2)
                        type=service
                        groups="${ADDITIONAL_USER_GROUPS[$i]:-}"
                        ask_default groups \
                                "Optional supplementary groups (comma-separated)\n\nLeave blank for the System/service default: private primary group only." \
                                "$groups" || return 0
                        groups="${groups// /}"
                        if ! valid_group_list "$groups"; then
                                dialog_message "Invalid group list" \
                                        "Supplementary groups must be comma-separated group names using letters, numbers, _, ., or - only."
                                return 0
                        fi
                        allow_login=no
                        [[ "${ADDITIONAL_USER_TYPES[$i]:-service}" == service-login ]] && allow_login=yes
                        ask_yes_no allow_login \
                                "Allow an interactive shell for this System/service account?\n\nNo keeps /usr/bin/false and password login locked. Yes uses /bin/bash and allows an optional password during installation." \
                                "$allow_login" || return 0
                        [[ "$allow_login" == yes ]] && type=service-login
                        ADDITIONAL_USER_TYPES[$i]="$type"
                        ADDITIONAL_USER_GROUPS[$i]="$groups"
                        ;;
                *) return 0 ;;
        esac
        recalculate_system_settings_status
}

remove_configured_account() {
        local choice="" i
        local -a items=()
        ((${#ADDITIONAL_USERS[@]})) || {
                dialog_message "Remove account" "No additional accounts are configured."
                return 0
        }
        for ((i=0; i<${#ADDITIONAL_USERS[@]}; i++)); do
                items+=("$((i+1))" "${ADDITIONAL_USERS[$i]} - $(account_type_label "${ADDITIONAL_USER_TYPES[$i]:-standard}")")
        done
        themed_menu choice "Remove account" "Select an additional account to remove from the installation plan." 20 86 12 "${items[@]}"
        [[ "$choice" =~ ^[0-9]+$ ]] || return 0
        i=$((choice-1))
        ((i>=0 && i<${#ADDITIONAL_USERS[@]})) || return 0
        unset 'ADDITIONAL_USERS[i]' 'ADDITIONAL_USER_TYPES[i]' 'ADDITIONAL_USER_GROUPS[i]'
        ADDITIONAL_USERS=("${ADDITIONAL_USERS[@]}")
        ADDITIONAL_USER_TYPES=("${ADDITIONAL_USER_TYPES[@]}")
        ADDITIONAL_USER_GROUPS=("${ADDITIONAL_USER_GROUPS[@]}")
        recalculate_system_settings_status
}

configure_users() {
        local choice=""
        while true; do
                recalculate_system_settings_status
                themed_menu choice "Users and Groups" \
                        "Standard users receive the centralized BFSOS group policy automatically. System/service accounts receive only their private primary group unless supplementary groups are explicitly requested. Passwords are optional; blank means locked, never passwordless login." \
                        23 100 12 \
                        1 "Primary Standard user: ${USERNAME:-not configured} [$(completion_status "$USERS_CONFIGURED")]" \
                        2 "Root password login: $ROOT_PASSWORD_POLICY" \
                        3 "Add Standard or System/service account" \
                        4 "Modify additional account" \
                        5 "Remove additional account" \
                        6 "Review configured accounts" \
                        7 "Help / account policy" \
                        8 "Back to System Settings"
                case "$choice" in
                        1) configure_primary_standard_user ;;
                        2) configure_root_password_policy ;;
                        3) add_configured_account ;;
                        4) modify_configured_account ;;
                        5) remove_configured_account ;;
                        6) show_accounts_review ;;
                        7) show_installer_help accounts ;;
                        *) return 0 ;;
                esac
        done
}

configure_ssh_setting() {
        ask_yes_no ENABLE_OPENSSH \
                "Enable OpenSSH on boot?\n\nSSH uses the installed PAM/account policy. Account passwords remain optional; accounts with locked passwords can still be configured later for key-based authentication." \
                "$ENABLE_OPENSSH" || return 0
        SSH_CONFIGURED=yes
        recalculate_system_settings_status
}

configure_console_settings() {
        local choice=""
        while true; do
                themed_menu choice "Console / font" \
                        "Configure installed-console readability and optional early-boot serial troubleshooting. Serial output is disabled by default." \
                        18 88 8 \
                        1 "Console font: $(console_font_display_name)" \
                        2 "Serial troubleshooting console: $SERIAL_CONSOLE" \
                        3 "Help: serial troubleshooting console" \
                        4 "Back to System Settings"
                case "$choice" in
                        1) select_console_font_size ;;
                        2) toggle_setting SERIAL_CONSOLE ;;
                        3) show_installer_help serial ;;
                        *) return 0 ;;
                esac
        done
}

configure_root_password_policy() {
        local choice=""
        themed_menu choice "Root password policy" \
                "Root password login is locked by default. Choose Prompt only if you want the installer to offer an optional root password during installation. Passwords are never stored in profiles or logs." \
                17 96 7 \
                1 "Keep root password login locked (recommended/default)" \
                2 "Prompt for an optional root password during installation" \
                3 "Back"
        case "$choice" in
                1) ROOT_PASSWORD_POLICY=locked ;;
                2) ROOT_PASSWORD_POLICY=prompt ;;
                *) return 0 ;;
        esac
        recalculate_system_settings_status
}

system_settings_menu() {
        local choice=""
        while true; do
                recalculate_system_settings_status
                themed_menu choice "System Settings" \
                        "Configure required installed-system settings in one place. Required items show their current completion state; optional/default settings do not block installation." \
                        25 100 14 \
                        1 "Hostname / timezone / locale [$(completion_status "$BASIC_SYSTEM_CONFIGURED")]" \
                        2 "Console / font [$(console_font_display_name); serial=$SERIAL_CONSOLE]" \
                        3 "Networking [$(completion_status "$NETWORK_CONFIGURED")]" \
                        4 "Users and Groups [$(completion_status "$USERS_CONFIGURED")]" \
                        5 "SSH: $ENABLE_OPENSSH [$(completion_status "$SSH_CONFIGURED")]" \
                        6 "Back to main menu"
                case "$choice" in
                        1) configure_basic_system ;;
                        2) configure_console_settings ;;
                        3) configure_networking ;;
                        4) configure_users ;;
                        5) configure_ssh_setting ;;
                        *) return 0 ;;
                esac
        done
}

kernel_pkgfile_version() {
        local package="${1:-}"
        local pkgfile="" version=""

        [[ -n "$package" ]] || { printf '%s' "unknown"; return 0; }
        [[ "$package" =~ ^[A-Za-z0-9._+-]+$ ]] || { printf '%s' "unknown"; return 0; }
        pkgfile="$PROJECT_DIR/ports/core/$package/Pkgfile"
        [[ -r "$pkgfile" ]] || { printf '%s' "unknown"; return 0; }

        version="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*//p' "$pkgfile" 2>/dev/null | head -n1 || true)"
        version="${version//\"/}"
        version="${version//\'/}"
        version="${version//[[:space:]]/}"
        [[ -n "$version" ]] || version=unknown
        printf '%s' "$version"
}

configure_kernel() {
        local choice="" linux_version="" lts_version=""
        linux_version="$(kernel_pkgfile_version linux)"
        lts_version="$(kernel_pkgfile_version linux-lts)"

        while true; do
                themed_menu choice \
                        "Kernel selection" \
                        "Choose the kernel package for the installed system." \
                        18 82 9 \
                        1 "linux-lts $lts_version — BFSOS default LTS kernel" \
                        2 "linux $linux_version — optional current kernel" \
                        3 "Do not install a kernel" \
                        4 "Help"

                [[ -n "$choice" ]] || return 0
                case "$choice" in
                        1) KERNEL_PACKAGE=linux-lts; KERNEL_CONFIGURED=yes; return 0 ;;
                        2) KERNEL_PACKAGE=linux; KERNEL_CONFIGURED=yes; return 0 ;;
                        3) KERNEL_PACKAGE=none; KERNEL_CONFIGURED=yes; return 0 ;;
                        4) show_installer_help kernel ;;
                        *) return 0 ;;
                esac
        done
}

configure_networking() {
        select_network_interface || return 0
        ask_yes_no INSTALL_NETWORKMANAGER \
                "Use NetworkManager instead of systemd-networkd?" \
                "$INSTALL_NETWORKMANAGER" || return 0
        NETWORK_CONFIGURED=yes
        recalculate_system_settings_status
}

toggle_setting() {
        local variable="$1"

        if [[ "${!variable}" == yes ]]; then
                printf -v "$variable" '%s' no
        else
                printf -v "$variable" '%s' yes
        fi
}

selection_mark() {
        [[ "$1" == yes ]] && printf '[x]' || printf '[ ]'
}

configure_packages() {
        local choice=""
        local status=0

        while true; do
                if command -v dialog >/dev/null 2>&1 &&
                   [[ -r /dev/tty && -w /dev/tty ]]; then
                        if choice="$(
                                dialog --stdout --clear \
                                        --backtitle "BFSOS Installer" \
                                        --title "Optional software" \
                                        --cancel-label "Back" \
                                        --checklist \
                                        "Select optional software packages.\n\nStorage utilities such as cryptsetup, lvm2, and mdadm are installed automatically when the selected storage layout requires them." \
                                        20 88 8 \
                                        wget "Wget download utility" "$([[ "$INSTALL_WGET" == yes ]] && echo on || echo off)" \
                                        wpa_supplicant "WPA/WPA2 wireless supplicant" "$([[ "$INSTALL_WPA_SUPPLICANT" == yes ]] && echo on || echo off)" \
                                        wireless_tools "Legacy iwconfig/iwlist wireless utilities" "$([[ "$INSTALL_WIRELESS_TOOLS" == yes ]] && echo on || echo off)" \
                                        gpm "Console mouse support" "$([[ "$INSTALL_GPM" == yes ]] && echo on || echo off)" \
                                        lynx "Lynx text-mode web browser" "$([[ "$INSTALL_LYNX" == yes ]] && echo on || echo off)" \
                                        links "Links text-mode web browser" "$([[ "$INSTALL_LINKS" == yes ]] && echo on || echo off)" \
                                        </dev/tty
                        )"; then
                                status=0
                        else
                                status=$?
                        fi
                        ((status == 0)) || return 0

                        INSTALL_WGET=no
                        INSTALL_WPA_SUPPLICANT=no
                        INSTALL_WIRELESS_TOOLS=no
                        INSTALL_GPM=no
                        INSTALL_LYNX=no
                        INSTALL_LINKS=no

                        [[ " $choice " == *' "wget" '* || " $choice " == *' wget '* ]] &&
                                INSTALL_WGET=yes
                        [[ " $choice " == *' "wpa_supplicant" '* || " $choice " == *' wpa_supplicant '* ]] &&
                                INSTALL_WPA_SUPPLICANT=yes
                        [[ " $choice " == *' "wireless_tools" '* || " $choice " == *' wireless_tools '* ]] &&
                                INSTALL_WIRELESS_TOOLS=yes
                        [[ " $choice " == *' "gpm" '* || " $choice " == *' gpm '* ]] &&
                                INSTALL_GPM=yes
                        [[ " $choice " == *' "lynx" '* || " $choice " == *' lynx '* ]] &&
                                INSTALL_LYNX=yes
                        [[ " $choice " == *' "links" '* || " $choice " == *' links '* ]] &&
                                INSTALL_LINKS=yes

                        PACKAGES_CONFIGURED=yes
                        return 0
                fi

                clear_screen
                cat <<EOF_PACKAGES
Optional software
=================

Storage utilities (cryptsetup, lvm2, mdadm) are installed automatically
when the selected storage layout requires them.

  1) $(selection_mark "$INSTALL_WGET") wget
  2) $(selection_mark "$INSTALL_WPA_SUPPLICANT") wpa_supplicant
  3) $(selection_mark "$INSTALL_WIRELESS_TOOLS") wireless_tools
  4) $(selection_mark "$INSTALL_GPM") gpm
  5) $(selection_mark "$INSTALL_LYNX") lynx
  6) $(selection_mark "$INSTALL_LINKS") links
  7) Done

EOF_PACKAGES
                read -r -p "Choose [1-7]: " choice

                case "$choice" in
                        1) toggle_setting INSTALL_WGET ;;
                        2) toggle_setting INSTALL_WPA_SUPPLICANT ;;
                        3) toggle_setting INSTALL_WIRELESS_TOOLS ;;
                        4) toggle_setting INSTALL_GPM ;;
                        5) toggle_setting INSTALL_LYNX ;;
                        6) toggle_setting INSTALL_LINKS ;;
                        7) PACKAGES_CONFIGURED=yes; return 0 ;;
                        *) warn "Choose a number from 1 through 7."; sleep 1 ;;
                esac
        done
}

configure_sudo() {
        local choice=""
        while true; do
                themed_menu choice \
                        "Sudo configuration" \
                        "Choose how sudo should be configured for wheel-group users." \
                        19 86 9 \
                        1 "Do not install sudo" \
                        2 "Install sudo; require the user's password (recommended)" \
                        3 "Install sudo; allow wheel users without a password" \
                        4 "Help"

                [[ -n "$choice" ]] || return 0
                case "$choice" in
                        1) INSTALL_SUDO=no; SUDO_MODE=disabled; SUDO_CONFIGURED=yes; return 0 ;;
                        2) INSTALL_SUDO=yes; SUDO_MODE=password; SUDO_CONFIGURED=yes; return 0 ;;
                        3) INSTALL_SUDO=yes; SUDO_MODE=nopasswd; SUDO_CONFIGURED=yes; return 0 ;;
                        4) show_installer_help sudo ;;
                        *) return 0 ;;
                esac
        done
}

configure_bootloader() {
        if [[ -n "$EFI_DEV" || -d /sys/firmware/efi ]]; then
                BOOT_MODE=uefi
        else
                BOOT_MODE=bios
        fi

        ask_yes_no INSTALL_GRUB \
                "Detected boot mode: $BOOT_MODE\n\nWrite and configure the GRUB bootloader?" \
                "$INSTALL_GRUB" || return 0

        if [[ "$INSTALL_GRUB" == yes && "$BOOT_MODE" == bios ]]; then
                ask_default BOOT_DISK \
                        "Whole disk for BIOS GRUB, for example /dev/sda" \
                        "$BOOT_DISK" || return 0
        fi

        if [[ "$INSTALL_GRUB" == yes && "$BOOT_MODE" == uefi ]]; then
                ask_yes_no GRUB_FALLBACK \
                        "Also install the EFI fallback loader?\n\nThis is recommended for some MSI and other firmware implementations." \
                        "$GRUB_FALLBACK" || return 0
        fi

        BOOTLOADER_CONFIGURED=yes
}

additional_users_text() {
        local user_name=""
        local separator=""

        for user_name in "${ADDITIONAL_USERS[@]}"; do
                printf '%s%s' "$separator" "$user_name"
                separator=" "
        done
}

additional_user_entries_text() {
        local i separator=""
        for ((i=0; i<${#ADDITIONAL_USERS[@]}; i++)); do
                printf '%s%s:%s:%s' "$separator" \
                        "${ADDITIONAL_USERS[$i]}" \
                        "${ADDITIONAL_USER_TYPES[$i]:-standard}" \
                        "${ADDITIONAL_USER_GROUPS[$i]:-}"
                separator=" "
        done
}

show_additional_users_review() {
        local i user_name type groups

        if ((${#ADDITIONAL_USERS[@]} == 0)); then
                printf 'Additional users:     none\n'
                return 0
        fi

        printf 'Additional accounts:\n'
        for ((i=0; i<${#ADDITIONAL_USERS[@]}; i++)); do
                user_name="${ADDITIONAL_USERS[$i]}"
                type="${ADDITIONAL_USER_TYPES[$i]:-standard}"
                groups="${ADDITIONAL_USER_GROUPS[$i]:-}"
                case "$type" in
                        service)
                                printf '  - %-18s System/service, non-interactive, password locked, groups=%s\n' \
                                        "$user_name" "${groups:-none}"
                                ;;
                        service-login)
                                printf '  - %-18s System/service, interactive, password optional, groups=%s\n' \
                                        "$user_name" "${groups:-none}"
                                ;;
                        *)
                                printf '  - %-18s Standard user, password optional, groups=Standard BFSOS groups\n' "$user_name"
                                ;;
                esac
        done
}

show_btrfs_review() {
        local index=0
        local found=no
        local device="" mountpoint="" format=""
        local name="" data_subvol="" snapshot_subvol="" snapshot_mountpoint=""

        printf 'Btrfs snapshots:\n'

        for ((index=0; index<5+${#EXTRA_DEVICES[@]}; index++)); do
                case "$index" in
                        0) device="$ROOT_DEV"; mountpoint=/; format="$ROOT_FORMAT" ;;
                        1) device="$BOOT_DEV"; mountpoint=/boot; format="$BOOT_FORMAT" ;;
                        2) device="$EFI_DEV"; mountpoint=/boot/efi; format="$EFI_FORMAT" ;;
                        3) device="$HOME_DEV"; mountpoint=/home; format="$HOME_FORMAT" ;;
                        4) continue ;;
                        *)
                                device="${EXTRA_DEVICES[$((index - 5))]}"
                                mountpoint="${EXTRA_MOUNTPOINTS[$((index - 5))]}"
                                format="${EXTRA_FORMATS[$((index - 5))]}"
                                ;;
                esac

                [[ -n "$device" ]] || continue
                [[ "$format" == btrfs ]] || continue
                found=yes

                name="$(sanitize_btrfs_name "$mountpoint")"
                case "$mountpoint" in
                        /)
                                data_subvol=@
                                snapshot_subvol=@snapshots
                                snapshot_mountpoint=/.snapshots
                                ;;
                        /home)
                                data_subvol=@home
                                snapshot_subvol=@home-snapshots
                                snapshot_mountpoint=/home/.snapshots
                                ;;
                        *)
                                data_subvol="@$name"
                                snapshot_subvol="@$name-snapshots"
                                snapshot_mountpoint="$mountpoint/.snapshots"
                                ;;
                esac

                printf '  %-16s %-24s data=%-18s snapshots=%s mounted at %s\n' \
                        "$mountpoint" "$device" "$data_subvol" \
                        "$snapshot_subvol" "$snapshot_mountpoint"
        done

        [[ "$found" == yes ]] || printf '  none (no filesystem is set to format as Btrfs)\n'
}

menu_status() {
        case "$1" in
                yes) printf configured ;;
                optional) printf optional ;;
                default) printf default ;;
                *) printf pending ;;
        esac
}

install_menu_label() {
        if [[ "$INSTALLATION_ALREADY_COMPLETE" == yes ]]; then
                printf '%s' "Installation Complete"
        elif [[ "$RESUME_STATE_PRESENT" == yes || -s "$INSTALLER_RESUME_FILE" ]]; then
                printf '%s' "Install / Retry BFS"
        else
                printf '%s' "Install BFS"
        fi
}

install_menu_status() {
        if [[ "$INSTALLATION_ALREADY_COMPLETE" == yes ]]; then
                printf '%s' "COMPLETE"
        elif [[ "$RESUME_STATE_PRESENT" == yes || -s "$INSTALLER_RESUME_FILE" ]]; then
                printf '%s' "RETRY AVAILABLE"
        else
                available_status installer_ready
        fi
}

show_main_menu() {
        clear_screen

        cat <<EOF_MENU
============================================================
                  BFSOS Installer
============================================================

$(if [[ "$INSTALLATION_ALREADY_COMPLETE" == yes ]]; then printf "%s\n" "Recovered installation is already complete; use Chroot for inspection or Quit."; else printf "%s\n" "Configure each section, then select Install BFS." "The installer authenticates once and all installation actions run as root."; fi)

  1) Storage assignment         [$(menu_status "$DISKS_CONFIGURED")]
  2) Base archive               [$(menu_status "$ARCHIVE_CONFIGURED")]
  3) System Settings            [$(completion_status "$SYSTEM_CONFIGURED")]
  4) Kernel selection           [$(menu_status "$KERNEL_CONFIGURED")]
  5) Optional software          [$(menu_status "$PACKAGES_CONFIGURED")]
  6) Sudo configuration         [$(menu_status "$SUDO_CONFIGURED")]
  7) Bootloader                 [$(menu_status "$BOOTLOADER_CONFIGURED")]
  8) Review selections          [AVAILABLE]
  9) $(install_menu_label)       [$(install_menu_status)]
 10) Chroot into target          [$(available_status target_chroot_available)]
 11) Quit                        [EXIT]

EOF_MENU
}

target_mount_tree_complete() {
        local index="" mp="" expected=""
        mountpoint -q "$TARGET" || return 1

        # Every configured Btrfs role must be mounted at its real subvolume,
        # never merely at top-level ID 5.
        for ((index=0; index<${#BTRFS_MOUNTPOINTS[@]}; index++)); do
                mp="${BTRFS_MOUNTPOINTS[$index]}"
                [[ "$mp" == / ]] && expected="$TARGET" || expected="$TARGET$mp"
                mountpoint -q "$expected" || return 1
                findmnt -rn -o OPTIONS --target "$expected" 2>/dev/null |
                        tr ',' '\n' | grep -qx "subvol=/${BTRFS_SUBVOLUMES[$index]}" ||
                findmnt -rn -o OPTIONS --target "$expected" 2>/dev/null |
                        tr ',' '\n' | grep -qx "subvol=${BTRFS_SUBVOLUMES[$index]}" || return 1
        done

        [[ -z "$BOOT_DEV" ]] || mountpoint -q "$TARGET/boot" || return 1
        if [[ "$BOOT_MODE" == uefi && -n "$EFI_DEV" ]]; then
                mountpoint -q "$TARGET/boot/efi" || return 1
        fi
        return 0
}

chroot_into_target() {
        force_posix_locale
        clear_screen
        echo "Chroot into BFS target"
        echo "======================"
        echo

        [[ -n "$ROOT_DEV" ]] ||
                die "Configure the root filesystem first."

        # A mounted Btrfs top-level is not enough: separate /usr, /opt,
        # /home, /var and snapshot subvolumes must be mounted exactly as the
        # installer recorded them.  If the shell is hidden by an incomplete or
        # top-level mount, reconstruct the complete canonical target tree.
        if ! target_mount_tree_complete ||
           [[ ! -x "$TARGET/bin/bash" && ! -x "$TARGET/usr/bin/bash" ]]; then
                if findmnt -Rrn "$TARGET" 2>/dev/null | grep -q .; then
                        umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET" 2>/dev/null || true
                        MOUNTED_BY_SCRIPT=()
                fi
                mount_target_filesystems
        fi

        [[ -x "$TARGET/bin/bash" || -x "$TARGET/usr/bin/bash" ]] || {
                dialog_message "Chroot unavailable"                         "The target is mounted, but no usable Bash exists at /bin/bash or /usr/bin/bash.

For Btrfs layouts this usually means a required subvolume was not mounted. The installer attempted to reconstruct the complete target mount tree and still could not verify the shell."
                return 1
        }

        mount_virtual_filesystems

        if [[ -e /etc/resolv.conf ]]; then
                rm -f "$TARGET/etc/resolv.conf"
                cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
        fi

        KEEP_MOUNTS=yes

        echo "Entering $TARGET. Type exit to return to the installer."
        echo

        run_on_tty \
                chroot "$TARGET" /usr/bin/env -i \
                HOME=/root \
                TERM="${TERM:-linux}" \
                PATH=/usr/bin:/usr/sbin:/bin:/sbin \
                LANG=C \
                LC_ALL=C \
                /bin/bash --login

        KEEP_MOUNTS=no
        unmount_virtual_filesystems
        # Return directly to the installer menu; no redundant terminal pause.
        return 0
}

installer_menu() {
        local choice="" status=0 error_file=""

        while true; do
                recalculate_system_settings_status
                SELECTED_MENU_CHOICE=""

                if command -v dialog >/dev/null 2>&1 &&
                   [[ -r /dev/tty && -w /dev/tty ]]; then
                        error_file="$(mktemp /tmp/bfs-installer-dialog-error.XXXXXX)"

                        if SELECTED_MENU_CHOICE="$(
                                dialog --stdout --clear --colors \
                                        --backtitle "BFSOS Installer" \
                                        --title "BFSOS Installer" \
                                        --ok-label "Select" \
                                        --cancel-label "Quit" \
                                        --extra-button \
                                        --extra-label "Settings" \
                                        --menu \
                                        "Use Up/Down arrows and Enter, or type an option number.\n\nThe installer authenticates once with sudo and all installation actions run as root.\n\nUse Tab or Shift+Tab to move between Select, Quit, and Settings." \
                                        26 92 15 \
                                        1 "$(
                                                dialog_menu_description \
                                                        'Storage assignment' \
                                                        "$(dialog_status "$DISKS_CONFIGURED")"
                                        )" \
                                        2 "$(
                                                dialog_menu_description \
                                                        'Base archive' \
                                                        "$(dialog_status "$ARCHIVE_CONFIGURED")"
                                        )" \
                                        3 "$(
                                                dialog_menu_description \
                                                        'System settings' \
                                                        "$(completion_status "$SYSTEM_CONFIGURED")"
                                        )" \
                                        4 "$(
                                                dialog_menu_description \
                                                        'Kernel selection' \
                                                        "$(dialog_status "$KERNEL_CONFIGURED")"
                                        )" \
                                        5 "$(
                                                dialog_menu_description \
                                                        'Optional software' \
                                                        "$(dialog_status "$PACKAGES_CONFIGURED")"
                                        )" \
                                        6 "$(
                                                dialog_menu_description \
                                                        'Sudo configuration' \
                                                        "$(dialog_status "$SUDO_CONFIGURED")"
                                        )" \
                                        7 "$(
                                                dialog_menu_description \
                                                        'Bootloader' \
                                                        "$(dialog_status "$BOOTLOADER_CONFIGURED")"
                                        )" \
                                        8 "$(
                                                dialog_menu_description \
                                                        'Review selections' \
                                                        'AVAILABLE'
                                        )" \
                                        9 "$(
                                                dialog_menu_description \
                                                        "$(install_menu_label)" \
                                                        "$(install_menu_status)"
                                        )" \
                                        10 "$(
                                                dialog_menu_description \
                                                        'Enter installed system (chroot)' \
                                                        "$(available_status target_chroot_available)"
                                        )" \
                                        11 "$(
                                                dialog_menu_description \
                                                        'Quit' \
                                                        'EXIT'
                                        )" \
                                        </dev/tty 2>"$error_file"
                        )"; then
                                status=0
                        else
                                status=$?
                        fi

                        case "$status" in
                                0)
                                        choice="$SELECTED_MENU_CHOICE"
                                        ;;
                                1|255)
                                        choice=11
                                        ;;
                                3)
                                        choice=settings
                                        ;;
                                *)
                                        warn "Dialog failed; switching to the text menu."
                                        [[ ! -s "$error_file" ]] || cat "$error_file" >&2
                                        choice=""
                                        ;;
                        esac

                        rm -f "$error_file"
                fi

                if [[ -z "$choice" ]]; then
                        show_main_menu
                        read -r -p "Choose [1-12; 12=Settings]: " choice
                        [[ "$choice" == 12 ]] && choice=settings
                fi

                choice="$(
                        printf '%s' "$choice" |
                                tr -d '\r\n' |
                                sed -e 's/^[[:space:]]*//' \
                                    -e 's/[[:space:]]*$//' \
                                    -e 's/^"//' \
                                    -e 's/"$//'
                )"

                case "$choice" in
                        1)  storage_menu ;;
                        2)  configure_archive ;;
                        3)  system_settings_menu ;;
                        4)  configure_kernel ;;
                        5)  configure_packages ;;
                        6)  configure_sudo ;;
                        7)  configure_bootloader ;;
                        8)
                                show_summary
                                if installer_ready; then
                                        if confirm_continue "Begin the BFS installation?"; then
                                                INSTALL_CONFIRMED=yes
                                                return 0
                                        fi
                                        # Back from Ready to install returns to the main installer menu.
                                        continue
                                fi
                                ;;
                        9)
                                if [[ "$INSTALLATION_ALREADY_COMPLETE" == yes ]]; then
                                        dialog_message "Installation already complete" \
                                                "This recovered BFSOS installation is already complete. No retry is required.\n\nUse Chroot into target for inspection, or Quit when finished."
                                        continue
                                fi
                                if installer_ready; then
                                        INSTALL_CONFIRMED=no
                                        return 0
                                fi

                                warn "Complete every configuration section before installing BFS."
                                pause_screen
                                ;;
                        10) chroot_into_target ;;
                        11)
                                # After a caught installation failure, the active
                                # storage stack is valuable recovery state. Do not
                                # silently tear it down on Quit; let the operator
                                # choose whether to preserve it for inspection/retry
                                # or deactivate it cleanly.
                                if [[ "${SESSION_FAILURE_STATUS:-0}" =~ ^[0-9]+$ ]] &&
                                   ((SESSION_FAILURE_STATUS != 0)); then
                                        local quit_storage_choice=""
                                        themed_menu quit_storage_choice                                                 "Quit after installation failure"                                                 "The last installation attempt failed with exit status ${SESSION_FAILURE_STATUS}.\n\nChoose what to do with the currently active target storage stack."                                                 17 78 3                                                 1 "Leave storage active for recovery / inspection"                                                 2 "Cleanly deactivate installer-owned storage"                                                 3 "Back to installer"
                                        case "$quit_storage_choice" in
                                                1)
                                                        KEEP_MOUNTS=yes
                                                        echo "Installer exited; target storage left active for recovery."
                                                        exit "$SESSION_FAILURE_STATUS"
                                                        ;;
                                                2)
                                                        KEEP_MOUNTS=no
                                                        echo "Installer exited; deactivating installer-owned target storage."
                                                        exit "$SESSION_FAILURE_STATUS"
                                                        ;;
                                                *)
                                                        continue
                                                        ;;
                                        esac
                                fi
                                echo "Installer exited."
                                exit "${SESSION_FAILURE_STATUS:-0}"
                                ;;
                        settings)
                                installer_settings_menu
                                ;;
                        *)
                                warn "Choose a valid installer option."
                                sleep 1
                                ;;
                esac

                choice=""
        done
}

validate_format_command() {
        local format="$1" command=""
        case "$format" in
                keep) return 0 ;;
                ext2) command=mkfs.ext2 ;;
                ext4) command=mkfs.ext4 ;;
                xfs) command=mkfs.xfs ;;
                btrfs) command=mkfs.btrfs ;;
                f2fs) command=mkfs.f2fs ;;
                vfat) command=mkfs.fat ;;
                swap) command=mkswap ;;
                *) die "Unknown format selection: $format" ;;
        esac
        command -v "$command" >/dev/null 2>&1 || die "Required formatting command is missing: $command"
}


selected_target_devices() {
        local device=""
        local index=""

        for device in \
                "$ROOT_DEV" \
                "$BOOT_DEV" \
                "$EFI_DEV" \
                "$SWAP_DEV" \
                "$HOME_DEV"
        do
                [[ -n "$device" ]] && printf '%s\n' "$device"
        done

        for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                [[ -n "${EXTRA_DEVICES[$index]}" ]] &&
                        printf '%s\n' "${EXTRA_DEVICES[$index]}"
        done
}

device_ancestry_has_type() {
        local device="$1"
        local wanted="$2"
        local type=""

        [[ -b "$device" ]] || return 1

        while IFS= read -r type; do
                case "$wanted" in
                        raid)
                                [[ "$type" == raid* || "$type" == linear || "$type" == md ]] && return 0
                                ;;
                        *)
                                [[ "$type" == "$wanted" ]] && return 0
                                ;;
                esac
        done < <(
                lsblk -s -nro TYPE "$device" 2>/dev/null || true
        )

        return 1
}

detect_storage_requirements() {
        local device=""

        AUTO_CRYPTSETUP=no
        AUTO_LVM2=no
        AUTO_MDADM=no

        # These are derived from the final devices selected for /, /home, swap,
        # and other mountpoints. Merely visiting the LUKS/LVM/RAID menus does
        # not force packages into the installed system.
        while IFS= read -r device; do
                [[ -n "$device" ]] || continue

                if device_ancestry_has_type "$device" crypt; then
                        AUTO_CRYPTSETUP=yes
                fi

                if device_ancestry_has_type "$device" lvm; then
                        AUTO_LVM2=yes
                fi

                if device_ancestry_has_type "$device" raid; then
                        AUTO_MDADM=yes
                fi
        done < <(selected_target_devices)

        # cryptsetup is never a manual optional-package choice. Keep the legacy
        # variable synchronized for the chroot template/review code.
        INSTALL_CRYPTSETUP="$AUTO_CRYPTSETUP"
}

crypt_mapping_records() {
        local selected_device="" path="" type="" mapping_name="" parent_device="" luks_uuid="" record=""
        local status_output="" line=""
        local -a seen=()

        while IFS= read -r selected_device; do
                [[ -n "$selected_device" ]] || continue
                while read -r path type; do
                        [[ "$type" == crypt ]] || continue
                        mapping_name="$(basename "$path")"
                        status_output="$(cryptsetup status "$mapping_name" 2>/dev/null || true)"
                        parent_device="$(printf '%s\n' "$status_output" | sed -n 's/^[[:space:]]*device:[[:space:]]*//p' | head -n1)"
                        [[ -b "$parent_device" ]] || continue
                        luks_uuid="$(cryptsetup luksUUID "$parent_device" 2>/dev/null || blkid -s UUID -o value "$parent_device" 2>/dev/null || true)"
                        [[ -n "$luks_uuid" ]] || continue
                        record="$mapping_name|$parent_device|$luks_uuid"
                        if ((${#seen[@]})) && printf '%s\n' "${seen[@]}" | grep -qxF "$record"; then continue; fi
                        seen+=("$record")
                        printf '%s\n' "$record"
                done < <(lsblk -s -prno PATH,TYPE "$selected_device" 2>/dev/null || true)
        done < <(selected_target_devices)
}

generate_crypttab() {
        local crypttab="$TARGET/etc/crypttab"
        local record=""
        local mapping_name=""
        local parent_device=""
        local luks_uuid=""
        local generated=0

        detect_storage_requirements

        if [[ "$AUTO_CRYPTSETUP" != yes ]]; then
                rm -f "$crypttab"
                return 0
        fi

        log "Generating /etc/crypttab"

        mkdir -p "$TARGET/etc"
        : > "$crypttab"

        while IFS='|' read -r mapping_name parent_device luks_uuid; do
                [[ -n "$mapping_name" && -n "$luks_uuid" ]] || continue

                printf '# %s\n' "$parent_device" >> "$crypttab"
                printf '%-24s UUID=%-36s none luks\n\n' \
                        "$mapping_name" "$luks_uuid" >> "$crypttab"
                generated=$((generated + 1))
        done < <(crypt_mapping_records)

        ((generated > 0)) ||
                die "Encrypted storage was detected, but no crypttab entries could be generated."

        chmod 0600 "$crypttab"
}

bios_gpt_has_boot_partition() {
        local disk="${1:-}"
        local pttype=""
        local bios_guid="21686148-6449-6e6f-744e-656564454649"

        [[ -b "$disk" ]] || return 1

        pttype="$(
                lsblk -dn -o PTTYPE "$disk" 2>/dev/null |
                        tr '[:upper:]' '[:lower:]' |
                        head -n1
        )"

        # DOS/MBR BIOS installs do not require a dedicated BIOS Boot partition.
        [[ "$pttype" == gpt ]] || return 0

        lsblk -lnpo PARTTYPE "$disk" 2>/dev/null |
                tr '[:upper:]' '[:lower:]' |
                grep -Fxq "$bios_guid"
}

validate_settings() {
        detect_storage_requirements
        validate_zram_settings
        [[ "$DISKS_CONFIGURED" == yes ]] || die "Disk and filesystem setup is incomplete."
        [[ "$ARCHIVE_CONFIGURED" == yes ]] || die "Base archive selection is incomplete."
        [[ "$SYSTEM_CONFIGURED" == yes ]] || die "System settings are incomplete."
        [[ "$USERS_CONFIGURED" == yes ]] || die "User account setup is incomplete."
        [[ "$KERNEL_CONFIGURED" == yes ]] || die "Kernel selection is incomplete."
        [[ "$NETWORK_CONFIGURED" == yes ]] || die "Networking setup is incomplete."
        [[ "$BOOTLOADER_CONFIGURED" == yes ]] || die "Bootloader setup is incomplete."
        [[ -b "$ROOT_DEV" ]] || die "Root device does not exist: $ROOT_DEV"
        [[ -f "$ARCHIVE" ]] || die "Rootfs archive does not exist: $ARCHIVE"
        [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username: $USERNAME"
        [[ -d "/sys/class/net/$NETWORK_IFACE" ]] ||
                die "Network interface does not exist: $NETWORK_IFACE"
        [[ "$NETWORK_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] ||
                die "Invalid MAC address for $NETWORK_IFACE: $NETWORK_MAC"
        [[ "$NETWORK_TARGET_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]] ||
                die "Invalid target network-interface name: $NETWORK_TARGET_NAME"
        local device index mountpoint
        for device in "$BOOT_DEV" "$EFI_DEV" "$SWAP_DEV" "$HOME_DEV"; do
                [[ -z "$device" || -b "$device" ]] || die "Device does not exist: $device"
        done
        for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                device="${EXTRA_DEVICES[$index]}"; mountpoint="${EXTRA_MOUNTPOINTS[$index]}"
                [[ -b "$device" ]] || die "Additional partition does not exist: $device"
                [[ "$mountpoint" == /* && "$mountpoint" != *'..'* ]] || die "Invalid additional mount point: $mountpoint"
                validate_format_command "${EXTRA_FORMATS[$index]}"
        done
        validate_format_command "$ROOT_FORMAT"
        validate_format_command "$BOOT_FORMAT"
        validate_format_command "$EFI_FORMAT"
        validate_format_command "$SWAP_FORMAT"
        validate_format_command "$HOME_FORMAT"
        [[ "$BOOT_MODE" == uefi || "$BOOT_MODE" == bios ]] || die "Boot mode must be uefi or bios."
        if [[ "$INSTALL_GRUB" == yes ]]; then
                [[ "$BOOT_MODE" != uefi || -n "$EFI_DEV" ]] || die "UEFI GRUB requires an EFI partition."
                [[ "$BOOT_MODE" != bios || -b "$BOOT_DISK" ]] || die "BIOS GRUB requires a whole-disk target."

                if [[ "$BOOT_MODE" == bios ]]; then
                        local boot_pttype=""
                        boot_pttype="$(
                                lsblk -dn -o PTTYPE "$BOOT_DISK" 2>/dev/null |
                                        tr '[:upper:]' '[:lower:]' |
                                        head -n1
                        )"

                        if [[ "$boot_pttype" == gpt ]] &&
                           ! bios_gpt_has_boot_partition "$BOOT_DISK"; then
                                die "BIOS GRUB on GPT requires a BIOS Boot partition on $BOOT_DISK. Return to disk setup, create a small (~2 MiB) unformatted partition in cfdisk, and set its type to 'BIOS boot'."
                        fi
                fi
        fi
}

mdraid_review_text() {
        local array="" device="" detail="" level="" size="" state="" members="" member=""
        local found=no

        if [[ ! -r /proc/mdstat ]]; then
                printf 'none\n'
                return 0
        fi

        while read -r array; do
                [[ -n "$array" ]] || continue
                found=yes
                device="/dev/$array"
                detail="$(mdadm --detail "$device" 2>/dev/null || true)"
                level="$(printf '%s\n' "$detail" | awk -F: '/Raid Level/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}')"
                size="$(printf '%s\n' "$detail" | awk -F: '/Array Size/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}')"
                state="$(printf '%s\n' "$detail" | awk -F: '/^[[:space:]]*State/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}')"
                members=""
                while IFS= read -r member; do
                        [[ -n "$member" ]] || continue
                        members+="${members:+ }$member"
                done < <(printf '%s\n' "$detail" | awk '$NF ~ /^\/dev\// {print $NF}')

                printf 'Array:    %s\n' "$device"
                printf 'Level:    %s\n' "${level:-unknown}"
                printf 'Size:     %s\n' "${size:-unknown}"
                printf 'State:    %s\n' "${state:-unknown}"
                printf 'Members:  %s\n\n' "${members:-unknown}"
        done < <(list_active_md_arrays | sed 's#^/dev/##')

        [[ "$found" == yes ]] || printf 'none\n'
}

review_device_size() {
        local device="${1:-}" size=""
        [[ -n "$device" ]] || { printf '%s' "unknown"; return 0; }
        size="$(lsblk -dn -o SIZE "$device" 2>/dev/null | head -n1 | xargs 2>/dev/null || true)"
        [[ -n "$size" ]] || size="unknown"
        printf '%s' "$size"
}

review_device_type() {
        local device="${1:-}" requested="${2:-keep}" fstype=""
        if [[ -n "$requested" && "$requested" != keep ]]; then
                printf '%s' "$requested"
                return 0
        fi
        [[ -n "$device" ]] || { printf '%s' "unknown"; return 0; }
        fstype="$(lsblk -dn -o FSTYPE "$device" 2>/dev/null | head -n1 | xargs 2>/dev/null || true)"
        [[ -n "$fstype" ]] || fstype="keep"
        printf '%s' "$fstype"
}

show_additional_partitions() {
        local index
        if ((${#EXTRA_DEVICES[@]} == 0)); then
                printf 'Additional mounts:   none\n'
                return
        fi
        printf 'Additional mounts:\n'
        for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                printf '  %-18s %-24s format: %s\n' "${EXTRA_MOUNTPOINTS[$index]}" "${EXTRA_DEVICES[$index]}" "${EXTRA_FORMATS[$index]}"
        done
}

show_summary() {
        local summary_file=""
        local formatting_requested=no
        local format=""
        local index=0
        local selected_count=0
        local format_count=0
        local preserve_count=0
        local additional_user_count=0
        local warning_count=0

        detect_storage_requirements
        CRYPT_TARGETS="$(crypt_mapping_records | awk -F'|' '{printf "%s%s -> %s", (NR>1 ? ", " : ""), $2, $1}')"

        selected_count=1
        [[ -n "$BOOT_DEV" ]] && selected_count=$((selected_count + 1))
        [[ -n "$EFI_DEV" ]] && selected_count=$((selected_count + 1))
        [[ -n "$SWAP_DEV" ]] && selected_count=$((selected_count + 1))
        [[ -n "$HOME_DEV" ]] && selected_count=$((selected_count + 1))
        selected_count=$((selected_count + ${#EXTRA_DEVICES[@]}))

        for format in \
                "$ROOT_FORMAT" \
                "$BOOT_FORMAT" \
                "$EFI_FORMAT" \
                "$SWAP_FORMAT" \
                "$HOME_FORMAT" \
                "${EXTRA_FORMATS[@]}"; do
                [[ -n "$format" ]] || continue
                if [[ "$format" == keep ]]; then
                        preserve_count=$((preserve_count + 1))
                else
                        formatting_requested=yes
                        format_count=$((format_count + 1))
                fi
        done

        additional_user_count=${#ADDITIONAL_USERS[@]}

        summary_file="$(mktemp /tmp/bfs-install-summary.XXXXXX)"

        {
                cat <<'SUMMARY_HEADER'
BFSOS Installation Review
=======================

Filesystem Layout
-----------------
Mount/Use        Device                          Type     Size       Action
---------        ------------------------------  -------  ---------  ------------
SUMMARY_HEADER

                printf '%-16s %-30s %-7s %-9s %s\n' \
                        "/" "$ROOT_DEV" "$(review_device_type "$ROOT_DEV" "$ROOT_FORMAT")" "$(review_device_size "$ROOT_DEV")" "$ROOT_FORMAT"

                [[ -z "$BOOT_DEV" ]] || \
                        printf '%-16s %-30s %-7s %-9s %s\n' \
                                "/boot" "$BOOT_DEV" "$(review_device_type "$BOOT_DEV" "$BOOT_FORMAT")" "$(review_device_size "$BOOT_DEV")" "$BOOT_FORMAT"

                [[ -z "$EFI_DEV" ]] || \
                        printf '%-16s %-30s %-7s %-9s %s\n' \
                                "/boot/efi" "$EFI_DEV" "$(review_device_type "$EFI_DEV" "$EFI_FORMAT")" "$(review_device_size "$EFI_DEV")" "$EFI_FORMAT"

                [[ -z "$HOME_DEV" ]] || \
                        printf '%-16s %-30s %-7s %-9s %s\n' \
                                "/home" "$HOME_DEV" "$(review_device_type "$HOME_DEV" "$HOME_FORMAT")" "$(review_device_size "$HOME_DEV")" "$HOME_FORMAT"

                for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                        printf '%-16s %-30s %-7s %-9s %s\n' \
                                "${EXTRA_MOUNTPOINTS[$index]}" \
                                "${EXTRA_DEVICES[$index]}" \
                                "$(review_device_type "${EXTRA_DEVICES[$index]}" "${EXTRA_FORMATS[$index]}")" \
                                "$(review_device_size "${EXTRA_DEVICES[$index]}")" \
                                "${EXTRA_FORMATS[$index]}"
                done

                [[ -z "$SWAP_DEV" ]] || \
                        printf '%-16s %-30s %-7s %-9s %s\n' \
                                "swap" "$SWAP_DEV" "swap" "$(review_device_size "$SWAP_DEV")" "$SWAP_FORMAT"

                cat <<SUMMARY

System
------
Hostname:             $HOSTNAME
Timezone:             $TIMEZONE
Locale:               $LOCALE
System Settings:      $(completion_status "$SYSTEM_CONFIGURED")
Target directory:     $TARGET
Base archive:         $ARCHIVE

Users
-----
Primary user:         $USERNAME (Standard user)
Primary groups:       Standard BFSOS groups ($STANDARD_USER_GROUPS)
Password login:       optional; blank keeps account locked
Root password login:  $ROOT_PASSWORD_POLICY
SUMMARY

                show_additional_users_review

                cat <<SUMMARY

Networking
----------
Interface:            $NETWORK_IFACE
MAC address:          $NETWORK_MAC
Installed NIC name:   $NETWORK_TARGET_NAME
NetworkManager:       $INSTALL_NETWORKMANAGER
OpenSSH server:       $ENABLE_OPENSSH

Boot Loader
-----------
Boot mode:            $BOOT_MODE
Install GRUB:         $INSTALL_GRUB
GRUB disk:            ${BOOT_DISK:-not applicable}
EFI fallback loader:  $GRUB_FALLBACK
Serial debug console: $SERIAL_CONSOLE

Packages
--------
Kernel package:       $KERNEL_PACKAGE
Git / ports sync:     required infrastructure (auto-installed if missing)
Wget:                 $INSTALL_WGET
Sudo:                 $INSTALL_SUDO
Sudo mode:            $SUDO_MODE
Cryptsetup:           $(if [[ "$AUTO_CRYPTSETUP" == yes ]]; then printf '%s' "AUTO (required by LUKS)"; else printf '%s' "not required"; fi)
Save base archive:    $SAVE_BASE_ARCHIVE
Archive save dir:     $BASE_ARCHIVE_DIR

Detected Storage Features
-------------------------
Encrypted targets:    $AUTO_CRYPTSETUP
LVM detected:         $AUTO_LVM2
mdraid detected:      $AUTO_MDADM
ZRAM swap:            $ZRAM_SWAP
ZRAM size:            $(if [[ "$ZRAM_SWAP" == yes ]]; then printf '%s' "$ZRAM_SIZE_SPEC"; else printf '%s' "disabled"; fi)
SUMMARY

                show_btrfs_review

                cat <<SUMMARY

RAID
----
Enabled:             ${AUTO_MDADM:-no}
$(mdraid_review_text)
LUKS Encryption
---------------
Enabled:             ${AUTO_CRYPTSETUP:-no}
Encrypted devices:   ${CRYPT_TARGETS:-none}

LVM
---
Enabled:             ${AUTO_LVM2:-no}
$(lvm_review_text)

Installation Totals
-------------------
Partitions selected:  $selected_count
Will format/init:     $format_count
Will preserve:        $preserve_count
Additional users:     $additional_user_count
Boot type:            $BOOT_MODE
Kernel:               $KERNEL_PACKAGE
RAID:                 ${AUTO_MDADM:-no}
LUKS:                 ${AUTO_CRYPTSETUP:-no}
LVM:                  ${AUTO_LVM2:-no}
ZRAM:                 $ZRAM_SWAP $(if [[ "$ZRAM_SWAP" == yes ]]; then printf '(%s)' "$ZRAM_SIZE_SPEC"; fi)

Warnings
--------
SUMMARY

                if [[ "$formatting_requested" == yes ]]; then
                        echo "- Every partition marked for formatting or initialization will be erased."
                        warning_count=$((warning_count + 1))
                fi

                if [[ "$INSTALL_GRUB" == yes &&
                      "$KERNEL_PACKAGE" == none ]]; then
                        echo "- GRUB will be configured, but BFSOS will not install a kernel."
                        warning_count=$((warning_count + 1))
                fi

                if [[ "$INSTALL_GRUB" == yes &&
                      "$BOOT_MODE" == uefi &&
                      -z "$EFI_DEV" ]]; then
                        echo "- UEFI boot was selected, but no EFI System Partition is assigned."
                        warning_count=$((warning_count + 1))
                fi

                if ((warning_count == 0)); then
                        echo "None."
                fi
        } > "$summary_file"

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear \
                        --backtitle "BFSOS Installer" \
                        --title "Review selections" \
                        --exit-label "Continue" \
                        --textbox "$summary_file" \
                        32 100 \
                        </dev/tty >/dev/tty 2>/dev/tty || true
        else
                clear_screen
                cat "$summary_file"
                pause_screen
        fi

        rm -f "$summary_file"
        return 0
}

unmount_device_everywhere() {
        local device="$1" destination

        while IFS= read -r destination; do
                [[ -n "$destination" ]] || continue
                umount "$destination" || die "Could not unmount $device from $destination"
        done < <(findmnt -rn -S "$device" -o TARGET 2>/dev/null | sort -r || true)

        # An empty while loop otherwise returns a nonzero status under
        # set -E, which caused misleading ERR-trap reports at this function.
        return 0
}

format_device() {
        local device="$1" format="$2" role="$3"
        [[ -n "$device" && "$format" != keep ]] || return 0
        unmount_device_everywhere "$device"
        swapoff "$device" 2>/dev/null || true

        # A destructive format must remove stale filesystem signatures first.
        # Some mkfs tools do not erase metadata from a previous filesystem at
        # every offset. For example, mkfs.btrfs -f can leave an old ext4
        # signature behind, causing blkid to report the device as ambiguous
        # and preventing UUID detection.
        log "Clearing stale filesystem signatures from $device"
        wipefs -a "$device" ||
                die "Could not clear stale filesystem signatures from $device."
        command -v udevadm >/dev/null 2>&1 && udevadm settle || true
        sync

        log "Formatting $device as $format for $role"
        case "$format" in
                ext2) mkfs.ext2 -F "$device" ;;
                ext4) mkfs.ext4 -F "$device" ;;
                xfs) mkfs.xfs -f "$device" ;;
                btrfs) mkfs.btrfs -f "$device" ;;
                f2fs) mkfs.f2fs -f "$device" ;;
                vfat) mkfs.fat -F 32 "$device" ;;
                swap) mkswap -f "$device" ;;
        esac
        refresh_storage_state
}


sanitize_btrfs_name() {
        local mountpoint="$1"
        local name="${mountpoint#/}"

        [[ -n "$name" ]] || {
                printf '%s\n' root
                return 0
        }

        name="${name//\//-}"
        name="${name//[^a-zA-Z0-9_.-]/-}"
        printf '%s\n' "$name"
}

register_btrfs_layout() {
        local device="$1" mountpoint="$2"
        local name="" data_subvol="" snapshot_subvol=""

        name="$(sanitize_btrfs_name "$mountpoint")"

        case "$mountpoint" in
                /)
                        data_subvol="@"
                        snapshot_subvol="@snapshots"
                        name=root
                        ;;
                /home)
                        data_subvol="@home"
                        snapshot_subvol="@home-snapshots"
                        name=home
                        ;;
                *)
                        data_subvol="@$name"
                        snapshot_subvol="@$name-snapshots"
                        ;;
        esac

        BTRFS_DEVICES+=("$device")
        BTRFS_MOUNTPOINTS+=("$mountpoint")
        BTRFS_SUBVOLUMES+=("$data_subvol")
        BTRFS_SNAPSHOT_SUBVOLUMES+=("$snapshot_subvol")
        BTRFS_CONFIG_NAMES+=("$name")
}

prepare_btrfs_subvolumes() {
        local index="" device="" data_subvol="" snapshot_subvol="" temp_mount=""

        BTRFS_DEVICES=()
        BTRFS_MOUNTPOINTS=()
        BTRFS_SUBVOLUMES=()
        BTRFS_SNAPSHOT_SUBVOLUMES=()
        BTRFS_CONFIG_NAMES=()

        [[ "$ROOT_FORMAT" == btrfs ]] && register_btrfs_layout "$ROOT_DEV" /
        [[ "$HOME_FORMAT" == btrfs ]] && register_btrfs_layout "$HOME_DEV" /home

        for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                [[ "${EXTRA_FORMATS[$index]}" == btrfs ]] || continue
                register_btrfs_layout \
                        "${EXTRA_DEVICES[$index]}" \
                        "${EXTRA_MOUNTPOINTS[$index]}"
        done

        ((${#BTRFS_DEVICES[@]} > 0)) || return 0
        command -v btrfs >/dev/null 2>&1 ||
                die "The btrfs command is required for automatic snapshots."

        log "Creating Btrfs data and snapshot subvolumes"

        for ((index=0; index<${#BTRFS_DEVICES[@]}; index++)); do
                device="${BTRFS_DEVICES[$index]}"
                data_subvol="${BTRFS_SUBVOLUMES[$index]}"
                snapshot_subvol="${BTRFS_SNAPSHOT_SUBVOLUMES[$index]}"
                temp_mount="$(mktemp -d /tmp/bfs-btrfs.XXXXXX)"

                local mount_attempt=0 mount_status=1
                for mount_attempt in 1 2 3 4 5; do
                        if mount -t btrfs "$device" "$temp_mount"; then
                                mount_status=0
                                break
                        fi
                        warn "Btrfs first-mount attempt $mount_attempt/5 failed for $device; settling storage state before retry."
                        command -v udevadm >/dev/null 2>&1 && udevadm settle || true
                        sync
                        sleep 1
                done
                if ((mount_status != 0)); then
                        {
                                echo "Btrfs mount diagnostics for $device:"
                                command -v btrfs >/dev/null 2>&1 && btrfs filesystem show "$device" 2>&1 || true
                                command -v btrfs >/dev/null 2>&1 && btrfs inspect-internal dump-super -f "$device" 2>&1 | head -80 || true
                                dmesg 2>/dev/null | grep -i -E "btrfs|${device##*/}" | tail -80 || true
                        } >&2
                        rmdir "$temp_mount" 2>/dev/null || true
                        die "Could not mount newly formatted Btrfs filesystem $device after 5 attempts."
                fi
                [[ -e "$temp_mount/$data_subvol" ]] ||
                        btrfs subvolume create "$temp_mount/$data_subvol"
                [[ -e "$temp_mount/$snapshot_subvol" ]] ||
                        btrfs subvolume create "$temp_mount/$snapshot_subvol"
                umount "$temp_mount"
                rmdir "$temp_mount"
        done
}

btrfs_layout_index_for_mountpoint() {
        local wanted="$1" index=""

        for ((index=0; index<${#BTRFS_MOUNTPOINTS[@]}; index++)); do
                if [[ "${BTRFS_MOUNTPOINTS[$index]}" == "$wanted" ]]; then
                        printf '%s\n' "$index"
                        return 0
                fi
        done

        return 1
}

mount_btrfs_layout() {
        local device="$1" destination="$2" mountpoint_name="$3"
        local index="" snapshot_destination=""

        index="$(btrfs_layout_index_for_mountpoint "$mountpoint_name")" ||
                return 1

        mkdir -p "$destination"
        mount -o "subvol=${BTRFS_SUBVOLUMES[$index]}" "$device" "$destination"
        record_mount "$destination"

        snapshot_destination="$destination/.snapshots"
        mkdir -p "$snapshot_destination"
        mount -o "subvol=${BTRFS_SNAPSHOT_SUBVOLUMES[$index]}" \
                "$device" "$snapshot_destination"
        record_mount "$snapshot_destination"

        return 0
}

format_selected_partitions() {
        local index
        format_device "$ROOT_DEV" "$ROOT_FORMAT" / 
        format_device "$BOOT_DEV" "$BOOT_FORMAT" /boot
        format_device "$EFI_DEV" "$EFI_FORMAT" /boot/efi
        format_device "$SWAP_DEV" "$SWAP_FORMAT" swap
        format_device "$HOME_DEV" "$HOME_FORMAT" /home
        for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                format_device "${EXTRA_DEVICES[$index]}" "${EXTRA_FORMATS[$index]}" "${EXTRA_MOUNTPOINTS[$index]}"
        done

        prepare_btrfs_subvolumes
}

record_mount() { MOUNTED_BY_SCRIPT+=("$1"); }

mount_device() {
        local device="$1" destination="$2"
        [[ -n "$device" ]] || return 0
        mkdir -p "$destination"
        mountpoint -q "$destination" && die "$destination unexpectedly remained mounted."
        mount "$device" "$destination"
        record_mount "$destination"
}

canonical_mount_source() {
        local source="${1:-}"
        source="${source%%[*}"
        readlink -f "$source" 2>/dev/null || printf '%s' "$source"
}

device_mounted_at() {
        local device="$1" destination="$2" mounted_source=""
        mountpoint -q "$destination" || return 1
        mounted_source="$(findmnt -rn -M "$destination" -o SOURCE 2>/dev/null | head -n1)"
        [[ -n "$mounted_source" ]] || return 1
        [[ "$(canonical_mount_source "$mounted_source")" == "$(canonical_mount_source "$device")" ]]
}

target_mount_plan_is_active() {
        target_mount_tree_complete
}

mount_or_reuse_target_filesystems() {
        if target_mount_plan_is_active; then
                log "Target filesystem plan is already mounted correctly; reusing it for installer retry"
                [[ -z "$SWAP_DEV" ]] || swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_DEV" || swapon "$SWAP_DEV" 2>/dev/null || true
                return 0
        fi
        mount_target_filesystems
}

mount_target_filesystems() {
        local index="" device="" mountpoint_name="" record=""
        local -a records=()

        log "Mounting target filesystems"

        for device in "$ROOT_DEV" "$BOOT_DEV" "$EFI_DEV" "$HOME_DEV" "${EXTRA_DEVICES[@]}"; do
                [[ -n "$device" ]] && unmount_device_everywhere "$device"
        done

        mkdir -p "$TARGET"

        if ! mount_btrfs_layout "$ROOT_DEV" "$TARGET" /; then
                mount_device "$ROOT_DEV" "$TARGET"
        fi

        [[ -z "$BOOT_DEV" ]] || records+=("$BOOT_DEV|/boot")
        if [[ "$BOOT_MODE" == uefi && -n "$EFI_DEV" ]]; then
                records+=("$EFI_DEV|/boot/efi")
        fi
        [[ -z "$HOME_DEV" ]] || records+=("$HOME_DEV|/home")

        for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                records+=("${EXTRA_DEVICES[$index]}|${EXTRA_MOUNTPOINTS[$index]}")
        done

        # Mount parents before children regardless of the order in which the
        # user selected them. This is required for layouts such as /usr plus
        # /usr/local, /boot plus /boot/efi, and arbitrary separate /opt trees.
        while IFS= read -r record; do
                [[ -n "$record" ]] || continue
                device="${record%%|*}"
                mountpoint_name="${record#*|}"

                if ! mount_btrfs_layout \
                        "$device" "$TARGET$mountpoint_name" "$mountpoint_name"
                then
                        mount_device "$device" "$TARGET$mountpoint_name"
                fi
        done < <(
                printf '%s\n' "${records[@]}" |
                awk -F'|' '
                        NF >= 2 {
                                mp=$2
                                depth=gsub(/\//, "/", mp)
                                printf "%04d|%s\n", depth, $0
                        }
                ' |
                sort -t'|' -k1,1n -k3,3 |
                cut -d'|' -f2-
        )

        [[ -z "$SWAP_DEV" ]] || swapon "$SWAP_DEV"
}

mount_virtual_filesystems() {
        log "Mounting virtual filesystems for chroot"
        mkdir -p "$TARGET"/{dev,dev/pts,proc,sys,run}

        if ! mountpoint -q "$TARGET/dev"; then
                mount --rbind /dev "$TARGET/dev"
                mount --make-rslave "$TARGET/dev"
                record_mount "$TARGET/dev"
        fi
        if ! mountpoint -q "$TARGET/proc"; then
                mount -t proc proc "$TARGET/proc"
                record_mount "$TARGET/proc"
        fi
        if ! mountpoint -q "$TARGET/sys"; then
                mount --rbind /sys "$TARGET/sys"
                mount --make-rslave "$TARGET/sys"
                record_mount "$TARGET/sys"
        fi
        if ! mountpoint -q "$TARGET/run"; then
                mount --rbind /run "$TARGET/run"
                mount --make-rslave "$TARGET/run"
                record_mount "$TARGET/run"
        fi
}

unmount_virtual_filesystems() {
        local destination=""

        # Recursive unmount is required because --rbind includes nested mounts
        # such as /dev/pts, /dev/shm, and EFI variables below /sys.
        for destination in "$TARGET/run" "$TARGET/sys" "$TARGET/proc" "$TARGET/dev"; do
                if findmnt -Rrn "$destination" 2>/dev/null | grep -q .; then
                        umount -R "$destination" 2>/dev/null ||
                                umount -Rl "$destination" 2>/dev/null ||
                                warn "Could not completely unmount $destination"
                fi
        done
}

cleanup() {
        local status=$?
        local index destination

        # If the UI exits normally after a caught install failure, retain the
        # tracked operation status rather than writing a misleading SUCCESS/0
        # footer from the shell's final `exit 0`.
        if ((status == 0)) && [[ "${SESSION_FAILURE_STATUS:-0}" =~ ^[0-9]+$ ]] &&
           ((SESSION_FAILURE_STATUS != 0)); then
                status="$SESSION_FAILURE_STATUS"
        fi

        # Preserve a complete failure log before target filesystems are
        # unmounted. Successful runs close and copy the log in main().
        if [[ "$LOG_ENABLED" == yes && "$LOG_CLOSED" == no ]]; then
                close_logging "$status" || true
                copy_log_to_installed_system || true
        fi

        rm -f "$TARGET$CHROOT_INSTALLER" "$TARGET/root/.bfs-installer-dialogrc" 2>/dev/null || true

        [[ -z "$DIALOGRC_FILE" ]] || rm -f "$DIALOGRC_FILE"

        if [[ -n "$ORIGINAL_DIALOGRC" ]]; then
                export DIALOGRC="$ORIGINAL_DIALOGRC"
        else
                unset DIALOGRC
        fi

        reset_terminal_ui
        [[ "$KEEP_MOUNTS" == yes ]] && return "$status"

        # First remove every target mount, including Btrfs snapshot mounts and
        # nested chroot bind mounts. Storage layers cannot be closed while any
        # filesystem above them remains mounted.
        if findmnt -Rrn "$TARGET" 2>/dev/null | grep -q .; then
                umount -R "$TARGET" 2>/dev/null ||
                        umount -Rl "$TARGET" 2>/dev/null || true
        fi

        [[ -z "$SWAP_DEV" ]] || swapoff "$SWAP_DEV" 2>/dev/null || true

        # Deactivate only volume groups created by this installer session.
        if command -v vgchange >/dev/null 2>&1; then
                for ((index=${#ACTIVATED_VGS_BY_SCRIPT[@]}-1; index>=0; index--)); do
                        vgchange -an "${ACTIVATED_VGS_BY_SCRIPT[$index]}" 2>/dev/null || true
                done
        fi

        # Close only LUKS mappings opened by this installer session, after LVM.
        if command -v cryptsetup >/dev/null 2>&1; then
                for ((index=${#OPENED_LUKS_BY_SCRIPT[@]}-1; index>=0; index--)); do
                        cryptsetup close "${OPENED_LUKS_BY_SCRIPT[$index]}" 2>/dev/null || true
                done
        fi

        # Stop MD arrays created by this installer session after filesystems,
        # LVM, and dm-crypt have been unwound.
        if command -v mdadm >/dev/null 2>&1; then
                for ((index=${#CREATED_MD_ARRAYS_BY_SCRIPT[@]}-1; index>=0; index--)); do
                        mdadm --stop "${CREATED_MD_ARRAYS_BY_SCRIPT[$index]}" 2>/dev/null || true
                done
        fi

        # Leave a clean, empty mountpoint for the next installer run. Never
        # remove TARGET unless recursive mount verification proves that neither
        # TARGET nor anything below it is mounted. The path guards protect
        # against an empty TARGET or an accidental request to remove /.
        if [[ -n "$TARGET" && "$TARGET" == /* && "$TARGET" != / ]]; then
                if findmnt -Rrn "$TARGET" 2>/dev/null | grep -q .; then
                        warn "Not removing leftover directories because a mount still exists below $TARGET."
                else
                        rm -rf --one-file-system -- "$TARGET" 2>/dev/null ||
                                warn "Could not remove leftover mountpoint directories below $TARGET."
                        mkdir -p -- "$TARGET" 2>/dev/null ||
                                warn "Could not recreate clean target mountpoint $TARGET."
                fi
        else
                warn "Refusing to clean unsafe target path: ${TARGET:-<empty>}"
        fi

        return "$status"
}

installer_err_trap() {
        local status=$?
        local line="${BASH_LINENO[0]:-${LINENO}}"
        local command="${BASH_COMMAND:-unknown}"
        local stack=""
        stack="$(caller 0 2>/dev/null || true)"
        printf '\nERROR: command failed\n' >&2
        printf '  Exit status : %s\n' "$status" >&2
        printf '  Source      : %s\n' "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" >&2
        printf '  Line        : %s\n' "$line" >&2
        printf '  Function    : %s\n' "${FUNCNAME[1]:-main}" >&2
        printf '  Command     : %s\n' "$command" >&2
        [[ -z "$stack" ]] || printf '  Caller      : %s\n' "$stack" >&2
        exit "$status"
}

trap cleanup EXIT
trap installer_err_trap ERR

path_is_or_contains_mount() {
        local path="$1" mounted_target=""

        while IFS= read -r mounted_target; do
                [[ "$mounted_target" == "$path" || "$mounted_target" == "$path/"* ]] && return 0
        done < <(findmnt -Rrn -o TARGET "$TARGET" 2>/dev/null || true)

        return 1
}

target_has_valid_base_system() {
        [[ -x "$TARGET/usr/bin/bash" ]] &&
        [[ -x "$TARGET/usr/bin/pkgmk" ]] &&
        [[ -f "$TARGET/etc/os-release" ]]
}

restore_persistent_install_checkpoints() {
        local state=""
        for state in base_extracted accounts_configured packages_complete system_config_complete bootloader_complete; do
                if [[ -f "$TARGET/var/lib/bfs-installer/$state" ]]; then
                        checkpoint_mark "$state"
                fi
        done
}

extract_rootfs() {
        local entry has_existing_content=no
        log "Extracting BFS root filesystem"

        while IFS= read -r -d '' entry; do
                [[ "$(basename "$entry")" == lost+found ]] && continue

                # Ignore directories created solely to host selected filesystems.
                # This includes direct mounts such as /home and /var, and parent
                # directories such as /boot when only /boot/efi is mounted.
                path_is_or_contains_mount "$entry" && continue

                has_existing_content=yes
                break
        done < <(find "$TARGET" -mindepth 1 -maxdepth 1 -print0)

        if [[ "$has_existing_content" == yes ]]; then
                warn "$TARGET contains existing files."
                if ! confirm "Extract into it anyway?"; then
                        if target_has_valid_base_system; then
                                log "Existing valid BFSOS base retained after user declined re-extraction"
                                return 2
                        fi
                        dialog_message "Base extraction skipped"                                 "The target contains existing files, but it did not pass the BFSOS base-system sanity check.

Nothing was overwritten. Review the target or choose re-extraction explicitly."
                        return 3
                fi
        fi

        tar --xattrs --acls --numeric-owner -xpf "$ARCHIVE" -C "$TARGET"
        return 0
}


fix_installed_bfsos_branding() {
        local file=""
        for file in "$TARGET/etc/os-release" "$TARGET/usr/lib/os-release"; do
                [[ -f "$file" ]] || continue
                sed -i \
                        -e 's|https://codeberg.org/bmadonnaster/BFS-Linux/issues|https://github.com/bmadonnaster/BFSOS/issues|g' \
                        -e 's|https://codeberg.org/bmadonnaster/BFS-Linux|https://github.com/bmadonnaster/BFSOS|g' \
                        "$file"
        done
}

save_base_archive() {
        local archive_name destination
        [[ "$SAVE_BASE_ARCHIVE" == yes ]] || return 0

        archive_name="$(basename "$ARCHIVE")"
        destination="$TARGET$BASE_ARCHIVE_DIR"

        log "Saving BFS base archive"
        mkdir -p "$destination"
        if [[ "$(readlink -f "$ARCHIVE")" != "$(readlink -m "$destination/$archive_name")" ]]; then
                cp -f "$ARCHIVE" "$destination/$archive_name"
        fi

        (
                cd "$destination"
                sha256sum "$archive_name" > "$archive_name.sha256"
        )

        log "Saved base archive to $BASE_ARCHIVE_DIR/$archive_name"
}

device_is_nonrotational() {
        local device="$1"
        local rota=""

        rota="$(lsblk -dnro ROTA "$device" 2>/dev/null | head -n1 || true)"
        [[ "$rota" == 0 ]]
}

fstab_mount_options() {
        local device="$1"
        local fstype="$2"

        case "$fstype" in
                vfat|fat|msdos)
                        printf '%s\n' defaults
                        ;;
                ext2|ext3|ext4|xfs|btrfs|f2fs)
                        if device_is_nonrotational "$device"; then
                                printf '%s\n' defaults,discard
                        else
                                printf '%s\n' defaults
                        fi
                        ;;
                *)
                        printf '%s\n' defaults
                        ;;
        esac
}

write_fstab_entry() {
        local fstab="$1" device="$2" mountpoint="$3" pass="$4"
        local subvol="${5:-}" uuid="" fstype="" options=""

        [[ -n "$device" ]] || return 0

        uuid="$(blkid -s UUID -o value "$device" 2>/dev/null || true)"
        fstype="$(blkid -s TYPE -o value "$device" 2>/dev/null || true)"

        [[ -n "$uuid" ]] || die "Could not determine UUID for $device."
        [[ -n "$fstype" ]] || die "Could not determine filesystem type for $device."

        options="$(fstab_mount_options "$device" "$fstype")"
        [[ -z "$subvol" ]] || options="$options,subvol=$subvol"

        printf '# %s\n' "$device" >> "$fstab"
        printf 'UUID=%-36s %-20s %-8s %-36s 0 %s\n\n' \
                "$uuid" "$mountpoint" "$fstype" "$options" "$pass" >> "$fstab"
}

write_btrfs_fstab_layout() {
        local fstab="$1" mountpoint_name="$2"
        local index="" device="" snapshot_mountpoint=""

        index="$(btrfs_layout_index_for_mountpoint "$mountpoint_name")" ||
                return 1

        device="${BTRFS_DEVICES[$index]}"
        snapshot_mountpoint="$mountpoint_name/.snapshots"
        [[ "$mountpoint_name" == / ]] && snapshot_mountpoint="/.snapshots"

        write_fstab_entry \
                "$fstab" "$device" "$mountpoint_name" 0 \
                "${BTRFS_SUBVOLUMES[$index]}"
        write_fstab_entry \
                "$fstab" "$device" "$snapshot_mountpoint" 0 \
                "${BTRFS_SNAPSHOT_SUBVOLUMES[$index]}"

        return 0
}


validate_fstab_syntax() {
        local fstab="$1"

        awk '
                /^[[:space:]]*($|#)/ {
                        next
                }

                NF != 6 {
                        printf "Invalid fstab field count on line %d: %s\n", NR, $0 > "/dev/stderr"
                        failed=1
                        next
                }

                $1 !~ /^(UUID=|LABEL=|PARTUUID=|PARTLABEL=|\/dev\/|tmpfs$|proc$|sysfs$|devpts$|devtmpfs$|none$|overlay$|cgroup2?$|efivarfs$|securityfs$|debugfs$|tracefs$|pstore$|configfs$|fusectl$|mqueue$|hugetlbfs$|ramfs$)/ {
                        printf "Invalid fstab source on line %d: %s\n", NR, $1 > "/dev/stderr"
                        failed=1
                }

                $2 != "none" && $2 !~ /^\// {
                        printf "Invalid fstab target on line %d: %s\n", NR, $2 > "/dev/stderr"
                        failed=1
                }

                $3 == "" || $4 == "" {
                        printf "Missing filesystem type or options on line %d\n", NR > "/dev/stderr"
                        failed=1
                }

                $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ {
                        printf "Invalid dump/pass fields on line %d: %s %s\n", NR, $5, $6 > "/dev/stderr"
                        failed=1
                }

                END {
                        exit failed
                }
        ' "$fstab"
}

generate_fstab() {
        local fstab="$TARGET/etc/fstab"
        local index="" uuid=""

        log "Generating clean /etc/fstab"
        mkdir -p "$TARGET/etc"
        : > "$fstab"

        if ! write_btrfs_fstab_layout "$fstab" /; then
                write_fstab_entry "$fstab" "$ROOT_DEV" / 1
        fi

        write_fstab_entry "$fstab" "$BOOT_DEV" /boot 2

        if [[ "$BOOT_MODE" == uefi ]]; then
                write_fstab_entry "$fstab" "$EFI_DEV" /boot/efi 2
        fi

        if [[ -n "$HOME_DEV" ]]; then
                if ! write_btrfs_fstab_layout "$fstab" /home; then
                        write_fstab_entry "$fstab" "$HOME_DEV" /home 2
                fi
        fi

        for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                if ! write_btrfs_fstab_layout "$fstab" "${EXTRA_MOUNTPOINTS[$index]}"; then
                        write_fstab_entry \
                                "$fstab" \
                                "${EXTRA_DEVICES[$index]}" \
                                "${EXTRA_MOUNTPOINTS[$index]}" \
                                2
                fi
        done

        if [[ -n "$SWAP_DEV" ]]; then
                uuid="$(blkid -s UUID -o value "$SWAP_DEV" 2>/dev/null || true)"
                [[ -n "$uuid" ]] || die "Could not determine swap UUID for $SWAP_DEV."
                printf '# %s\n' "$SWAP_DEV" >> "$fstab"
                printf 'UUID=%-36s %-16s %-8s %-20s 0 0\n' \
                        "$uuid" none swap sw >> "$fstab"
        fi

        validate_fstab_syntax "$fstab" ||
                die "Generated fstab failed syntax validation."

        log "Generated /etc/fstab passed syntax validation"
}


build_package_list() {
        local packages=(pciutils)

        [[ "$KERNEL_PACKAGE" != none ]] && packages+=("$KERNEL_PACKAGE")
        [[ "$INSTALL_NETWORKMANAGER" == yes ]] && packages+=(networkmanager)
        [[ "$AUTO_CRYPTSETUP" == yes ]] && packages+=(cryptsetup)
        [[ "$AUTO_LVM2" == yes ]] && packages+=(lvm2)
        [[ "$AUTO_MDADM" == yes ]] && packages+=(mdadm)
        [[ "$INSTALL_SUDO" == yes ]] && packages+=(sudo)
        [[ "$INSTALL_WGET" == yes ]] && packages+=(wget)
        [[ "$INSTALL_WPA_SUPPLICANT" == yes ]] && packages+=(wpa_supplicant)
        [[ "$INSTALL_WIRELESS_TOOLS" == yes ]] && packages+=(wireless_tools)
        [[ "$INSTALL_GPM" == yes ]] && packages+=(gpm)
        [[ "$INSTALL_LYNX" == yes ]] && packages+=(lynx)
        [[ "$INSTALL_LINKS" == yes ]] && packages+=(links)
        if ((${#BTRFS_DEVICES[@]} > 0)); then
                packages+=(snapper)
        fi

        if ((${#packages[@]} > 0)); then
                printf '%s
' "${packages[@]}" |
                        awk '!seen[$0]++' |
                        tr '
' ' '
        fi
}

write_chroot_installer() {
        local package_list
        detect_storage_requirements
        package_list="$(build_package_list)"
        log "Preparing chroot configuration"
        install -d -m 0755 "$TARGET/root"

        # Transitional support for installs made from an older base archive:
        # seed the current Git port so Git can be installed before the first
        # Git-backed `ports -u`, and seed the updated driver independently of
        # which Git package release the base archive contains.
        if [[ -d "$PROJECT_DIR/ports/opt/git" ]]; then
                install -d -m 0755 "$TARGET/usr/ports/opt"
                rm -rf "$TARGET/usr/ports/opt/git"
                cp -a "$PROJECT_DIR/ports/opt/git" "$TARGET/usr/ports/opt/git"
                install -m 0755 "$PROJECT_DIR/ports/opt/git/git" "$TARGET/root/.bfsos-git-driver"
        fi

        # The chroot is launched with `env -i`, and the live-environment
        # DIALOGRC points at /tmp outside the target. Copy the active theme into
        # the installed tree so password/account dialogs retain the selected
        # installer theme.
        if [[ -n "$DIALOGRC_FILE" && -r "$DIALOGRC_FILE" ]]; then
                install -m 0600 "$DIALOGRC_FILE" "$TARGET/root/.bfs-installer-dialogrc"
        fi

        cat > "$TARGET$CHROOT_INSTALLER" <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export LANG=C LC_ALL=C LANGUAGE=C
export BFS_INSTALLER_RUNNING=yes
if [[ -r /root/.bfs-installer-dialogrc ]]; then
        export DIALOGRC=/root/.bfs-installer-dialogrc
fi
STATE_DIR=/var/lib/bfs-installer
mkdir -p "$STATE_DIR"

HOSTNAME_VALUE="__HOSTNAME__"
TIMEZONE_VALUE="__TIMEZONE__"
LOCALE_VALUE="__LOCALE__"
USERNAME_VALUE="__USERNAME__"
ROOT_PASSWORD_POLICY_VALUE="__ROOT_PASSWORD_POLICY__"
ADDITIONAL_USERS_VALUE="__ADDITIONAL_USERS__"
ADDITIONAL_USER_ENTRIES_VALUE="__ADDITIONAL_USER_ENTRIES__"
STANDARD_USER_GROUPS_VALUE="__STANDARD_USER_GROUPS__"
BOOT_MODE_VALUE="__BOOT_MODE__"
BOOT_DISK_VALUE="__BOOT_DISK__"
NETWORK_IFACE_VALUE="__NETWORK_IFACE__"
NETWORK_MAC_VALUE="__NETWORK_MAC__"
NETWORK_TARGET_NAME_VALUE="__NETWORK_TARGET_NAME__"
PACKAGE_LIST_VALUE="__PACKAGE_LIST__"
ENABLE_OPENSSH_VALUE="__ENABLE_OPENSSH__"
INSTALL_GRUB_VALUE="__INSTALL_GRUB__"
GRUB_FALLBACK_VALUE="__GRUB_FALLBACK__"
KERNEL_PACKAGE_VALUE="__KERNEL_PACKAGE__"
INSTALL_SUDO_VALUE="__INSTALL_SUDO__"
SUDO_MODE_VALUE="__SUDO_MODE__"
INSTALL_NETWORKMANAGER_VALUE="__INSTALL_NETWORKMANAGER__"
INSTALL_GPM_VALUE="__INSTALL_GPM__"
INSTALL_LYNX_VALUE="__INSTALL_LYNX__"
INSTALL_LINKS_VALUE="__INSTALL_LINKS__"
CONSOLE_VIDEO_ARG_VALUE="__CONSOLE_VIDEO_ARG__"
SERIAL_CONSOLE_VALUE="__SERIAL_CONSOLE__"
# INSTALL_CRYPTSETUP_VALUE is retained for compatibility with older template
# logic; both values are derived automatically from selected LUKS storage.
INSTALL_CRYPTSETUP_VALUE="__INSTALL_CRYPTSETUP__"
AUTO_CRYPTSETUP_VALUE="__AUTO_CRYPTSETUP__"
AUTO_LVM2_VALUE="__AUTO_LVM2__"
AUTO_MDADM_VALUE="__AUTO_MDADM__"
BTRFS_CONFIG_NAMES_VALUE="__BTRFS_CONFIG_NAMES__"
BTRFS_MOUNTPOINTS_VALUE="__BTRFS_MOUNTPOINTS__"
CONSOLE_FONT_SIZE_VALUE="__CONSOLE_FONT_SIZE__"
INSTALL_CONSOLE_FONT_VALUE="__INSTALL_CONSOLE_FONT__"
ZRAM_SWAP_VALUE="__ZRAM_SWAP__"
ZRAM_SIZE_SPEC_VALUE="__ZRAM_SIZE_SPEC__"
BUILD_JOBS_VALUE="__BUILD_JOBS__"
BUILD_OPT_VALUE="__BUILD_OPT__"
BUILD_CCACHE_VALUE="__BUILD_CCACHE__"
BUILD_CCACHE_SIZE_VALUE="__BUILD_CCACHE_SIZE__"
BUILD_TMPFS_VALUE="__BUILD_TMPFS__"
BUILD_TMPFS_SIZE_VALUE="__BUILD_TMPFS_SIZE__"
VERIFY_MD5_VALUE="__VERIFY_MD5__"
VERIFY_SIGNATURE_VALUE="__VERIFY_SIGNATURE__"
VERIFY_FOOTPRINT_VALUE="__VERIFY_FOOTPRINT__"

log() { printf '\n==> %s\n' "$*"; }

log "Setting hostname and timezone"
printf '%s\n' "$HOSTNAME_VALUE" > /etc/hostname
[[ -e "/usr/share/zoneinfo/$TIMEZONE_VALUE" ]] || { echo "Missing timezone: $TIMEZONE_VALUE" >&2; exit 1; }
ln -sfn "/usr/share/zoneinfo/$TIMEZONE_VALUE" /etc/localtime

log "Configuring locales"
mkdir -p /etc

normalize_locale_entry() {
        local locale_name="$1"
        local locale_base="$locale_name"

        case "$locale_name" in
                C.UTF-8|C.utf8)
                        printf '%s\n' 'C.UTF-8 UTF-8'
                        return 0
                        ;;
        esac

        locale_base="${locale_base%.UTF-8}"
        locale_base="${locale_base%.utf8}"
        printf '%s UTF-8\n' "$locale_base"
}

add_locale_entry() {
        local entry="$1"

        touch /etc/locales
        grep -qxF "$entry" /etc/locales ||
                printf '%s\n' "$entry" >> /etc/locales
}

SELECTED_LOCALE_ENTRY="$(normalize_locale_entry "$LOCALE_VALUE")"
C_UTF8_ENTRY="$(normalize_locale_entry C.UTF-8)"

add_locale_entry "$C_UTF8_ENTRY"
add_locale_entry "$SELECTED_LOCALE_ENTRY"

if command -v genlocales >/dev/null 2>&1; then
        genlocales || {
                echo "Locale generation failed with genlocales." >&2
                echo "Contents of /etc/locales:" >&2
                cat /etc/locales >&2
                exit 1
        }
elif command -v locale-gen >/dev/null 2>&1; then
        locale-gen || {
                echo "Locale generation failed with locale-gen." >&2
                echo "Contents of /etc/locales:" >&2
                cat /etc/locales >&2
                exit 1
        }
else
        echo "No locale generation command was found." >&2
        exit 1
fi

printf 'LANG=%s\n' "$LOCALE_VALUE" > /etc/locale.conf

log "Writing hosts and console configuration"
cat > /etc/hosts <<EOF_HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME_VALUE
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF_HOSTS
configure_installed_console_font() {
        local size="$CONSOLE_FONT_SIZE_VALUE" font="" base=""
        local -a dirs=(/usr/share/consolefonts /usr/share/kbd/consolefonts /lib/kbd/consolefonts)
        local dir="" pattern=""
        local -a patterns=()

        # Keep the BFSOS normal console default unless the user explicitly
        # selected a persistent large font.
        if [[ "$INSTALL_CONSOLE_FONT_VALUE" != yes || "$size" == default ]]; then
                printf 'FONT=Lat2-Terminus16\n' > /etc/vconsole.conf
                log "Installed console font: default (Lat2-Terminus16)"
                return 0
        fi

        case "$size" in
                16) patterns=('Lat2-Terminus16*' 'LatGrkCyr-8x16*' 'Uni2-Terminus16*' 'ter-v16n*' '*Terminus*16*' '*16*.psf*') ;;
                20) patterns=('LatGrkCyr-12x22*' 'Lat2-Terminus20*' 'Uni2-Terminus20*' 'ter-v20n*' 'LatArCyrHeb-19*' 'lat4-19*' '*Terminus*20*' '*22*.psf*' '*20*.psf*' '*19*.psf*') ;;
                32) patterns=('latarcyrheb-sun32*' '*sun32*' '*32*.psf*') ;;
                *)  patterns=() ;;
        esac

        for dir in "${dirs[@]}"; do
                [[ -d "$dir" ]] || continue
                for pattern in "${patterns[@]}"; do
                        font="$(find "$dir" -maxdepth 1 -type f -name "$pattern" -print -quit 2>/dev/null)"
                        [[ -z "$font" ]] || break 2
                done
        done

        if [[ -z "$font" ]]; then
                echo "WARNING: Requested ${size}-pixel installed console font was unavailable; using Lat2-Terminus16." >&2
                printf 'FONT=Lat2-Terminus16\n' > /etc/vconsole.conf
                log "Installed console font fallback: requested size=$size; wrote Lat2-Terminus16"
                return 0
        fi

        base="$(basename "$font")"
        base="${base%.gz}"
        base="${base%.psfu}"
        base="${base%.psf}"
        printf 'FONT=%s\n' "$base" > /etc/vconsole.conf
        log "Installed console font: requested size=$size; wrote FONT=$base from $font"

        # Validate exactly what we persisted before declaring configuration done.
        if ! grep -qx "FONT=$base" /etc/vconsole.conf; then
                echo "ERROR: /etc/vconsole.conf did not preserve the selected console font ($base)." >&2
                return 1
        fi
}

configure_installed_console_font

cat > /etc/inputrc <<'EOF_INPUTRC'
set horizontal-scroll-mode Off
set meta-flag On
set input-meta On
set convert-meta Off
set output-meta On
set bell-style none
"\eOd": backward-word
"\eOc": forward-word
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert
"\eOH": beginning-of-line
"\eOF": end-of-line
"\e[H": beginning-of-line
"\e[F": end-of-line
EOF_INPUTRC

log "Configuring systemd"
systemd-machine-id-setup
mkdir -p /etc/systemd/system/getty@tty1.service.d
rm -f /etc/systemd/system/getty@tty1.service.d/noclear.conf
cat > /etc/systemd/system/getty@tty1.service.d/clear.conf <<'EOF_GETTY'
[Service]
TTYVTDisallocate=yes
EOF_GETTY
mkdir -p /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/maxuse.conf <<'EOF_CORE'
[Coredump]
MaxUse=5G
EOF_CORE

mkdir -p /etc/systemd/network
rm -f \
        /etc/systemd/network/10-bfs-dhcp.network \
        /etc/systemd/network/10-bfs-ethernet.link \
        /etc/systemd/network/20-bfs-dhcp.network

# The .link file is handled by udev, so it provides the same eth0 naming
# whether systemd-networkd or NetworkManager is selected.
cat > /etc/systemd/network/10-bfs-ethernet.link <<EOF_LINK
[Match]
MACAddress=$NETWORK_MAC_VALUE

[Link]
Name=$NETWORK_TARGET_NAME_VALUE
EOF_LINK

chmod 0644 /etc/systemd/network/10-bfs-ethernet.link

if [[ "$INSTALL_NETWORKMANAGER_VALUE" != yes ]]; then
        cat > /etc/systemd/network/20-bfs-dhcp.network <<EOF_NETWORK
[Match]
Name=$NETWORK_TARGET_NAME_VALUE

[Network]
DHCP=ipv4

[DHCPv4]
UseDomains=true
EOF_NETWORK

        chmod 0644 /etc/systemd/network/20-bfs-dhcp.network
fi

log "Checking account database"
[[ -f /etc/passwd ]] || { echo "Missing required account file: /etc/passwd" >&2; exit 1; }
[[ -f /etc/group ]] || { echo "Missing required account file: /etc/group" >&2; exit 1; }

grep -q '^root:' /etc/passwd || { echo "The BFS archive has no root entry in /etc/passwd." >&2; exit 1; }
grep -q '^root:' /etc/group || { echo "The BFS archive has no root entry in /etc/group." >&2; exit 1; }

if [[ ! -f /etc/shadow ]]; then
        log "Creating /etc/shadow from /etc/passwd"
        awk -F: '{ print $1 ":!:1::::::" }' /etc/passwd > /etc/shadow
fi

if [[ ! -f /etc/gshadow ]]; then
        log "Creating /etc/gshadow from /etc/group"
        awk -F: '{ print $1 ":!::" $4 }' /etc/group > /etc/gshadow
fi

grep -q '^root:' /etc/shadow || printf '%s\n' 'root:!:1::::::' >> /etc/shadow
grep -q '^root:' /etc/gshadow || printf '%s\n' 'root:!::' >> /etc/gshadow

chown root:root /etc/passwd /etc/group /etc/shadow /etc/gshadow
chmod 0644 /etc/passwd /etc/group
chmod 0600 /etc/shadow /etc/gshadow

log "Creating users"

DEFAULT_USER_GROUPS="$STANDARD_USER_GROUPS_VALUE"

ensure_default_user_groups() {
        local group_name=""

        command -v groupadd >/dev/null 2>&1 || {
                echo "groupadd is missing" >&2
                exit 1
        }

        for group_name in ${DEFAULT_USER_GROUPS//,/ }; do
                getent group "$group_name" >/dev/null 2>&1 ||
                        groupadd -r "$group_name"
        done
}

verify_standard_user_groups() {
        local user_name="$1"
        local group_name=""
        local user_groups=""

        user_groups="$(id -nG "$user_name")"

        for group_name in ${DEFAULT_USER_GROUPS//,/ }; do
                if ! grep -qw "$group_name" <<< "$user_groups"; then
                        echo "User $user_name was not added to group $group_name." >&2
                        exit 1
                fi
        done

        printf 'Groups for %s: %s\n' "$user_name" "$user_groups"
}

create_standard_user() {
        local user_name="$1"

        if ! id "$user_name" >/dev/null 2>&1 && getent group "$user_name" >/dev/null 2>&1; then
                echo "Account '$user_name' conflicts with existing group '$user_name'; private primary group cannot be created." >&2
                exit 9
        fi

        if ! id "$user_name" >/dev/null 2>&1; then
                if [[ -d "/home/$user_name" ]]; then
                        useradd -M -U \
                                -d "/home/$user_name" \
                                -s /bin/bash \
                                "$user_name"
                else
                        useradd -m -U \
                                -s /bin/bash \
                                "$user_name"
                fi
        fi

        # Apply the centralized Standard-user policy to new or reused users.
        usermod -aG "$DEFAULT_USER_GROUPS" "$user_name"
        mkdir -p "/home/$user_name"
        chown -R "$user_name:$user_name" "/home/$user_name"
        verify_standard_user_groups "$user_name"
}

create_service_user() {
        local user_name="$1" account_type="$2" supplementary_groups="${3:-}"
        local shell=/usr/bin/false

        [[ "$account_type" == service-login ]] && shell=/bin/bash

        if ! id "$user_name" >/dev/null 2>&1 && getent group "$user_name" >/dev/null 2>&1; then
                echo "Account '$user_name' conflicts with existing group '$user_name'; private primary group cannot be created." >&2
                exit 9
        fi

        if ! id "$user_name" >/dev/null 2>&1; then
                if [[ "$account_type" == service-login ]]; then
                        useradd -r -m -U -d "/home/$user_name" -s "$shell" "$user_name"
                else
                        useradd -r -M -U -d /dev/null -s "$shell" "$user_name"
                fi
        else
                usermod -s "$shell" "$user_name"
        fi

        if [[ -n "$supplementary_groups" ]]; then
                local group_name
                for group_name in ${supplementary_groups//,/ }; do
                        getent group "$group_name" >/dev/null 2>&1 || {
                                echo "Requested supplementary group '$group_name' for service account '$user_name' does not exist." >&2
                                exit 1
                        }
                done
                usermod -aG "$supplementary_groups" "$user_name"
        fi

        # Non-interactive service identities are always password locked.
        if [[ "$account_type" == service ]]; then
                passwd -l "$user_name" >/dev/null 2>&1 || usermod -L "$user_name"
        fi
}

ensure_default_user_groups

prompt_optional_password() {
        local account="$1" label="$2"
        local password_one="" password_two="" status=0

        command -v chpasswd >/dev/null 2>&1 || {
                echo "chpasswd is missing" >&2
                exit 1
        }

        while true; do
                password_one=""
                password_two=""
                if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                        set +e
                        password_one="$(dialog --stdout --clear --backtitle "BFSOS Installer" \
                                --title "Password for $label" --cancel-label "Back" \
                                --passwordbox "Password is optional. Leave this blank and select OK to keep password login LOCKED. A blank value never creates an empty-password login." \
                                14 78 </dev/tty)"
                        status=$?
                        set -e
                        ((status == 0)) || return 1
                else
                        printf '\nSet optional password for %s. Leave blank to keep login locked.\n' "$label"
                        read -r -s -p "New password: " password_one
                        printf '\n'
                fi

                if [[ -z "$password_one" ]]; then
                        passwd -l "$account" >/dev/null 2>&1 || usermod -L "$account"
                        printf 'Password login left locked for %s.\n' "$account"
                        return 0
                fi

                # BFSOS owns an explicit eight-character floor.  Do this before
                # confirmation/chpasswd because privileged chpasswd/PAM paths can
                # warn about a short password yet still return success.
                if (( ${#password_one} < 8 )); then
                        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                                dialog --clear --backtitle "BFSOS Installer" \
                                        --title "Password too short" \
                                        --msgbox "Password must be at least 8 characters, or leave it blank to keep password login locked." \
                                        10 72 </dev/tty
                        else
                                echo "Password must be at least 8 characters."
                        fi
                        unset password_one password_two
                        continue
                fi

                if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                        set +e
                        password_two="$(dialog --stdout --clear --backtitle "BFSOS Installer" \
                                --title "Confirm password for $label" --cancel-label "Back" \
                                --passwordbox "Retype the password." 11 70 </dev/tty)"
                        status=$?
                        set -e
                        ((status == 0)) || return 1
                else
                        read -r -s -p "Retype new password: " password_two
                        printf '\n'
                fi

                if [[ "$password_one" != "$password_two" ]]; then
                        if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                                dialog --clear --backtitle "BFSOS Installer" --title "Passwords do not match" \
                                        --msgbox "The passwords did not match. Try again." 9 60 </dev/tty
                        else
                                echo "Passwords do not match."
                        fi
                        continue
                fi

                # PAM-enabled Shadow routes chpasswd through the BFSOS
                # system-password policy.  A libpwquality rejection should let
                # the installer user choose another password instead of
                # aborting the entire installation transaction.
                set +e
                printf '%s:%s\n' "$account" "$password_one" | chpasswd
                status=$?
                set -e

                unset password_one password_two

                if ((status == 0)); then
                        return 0
                fi

                if command -v dialog >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
                        dialog --clear --backtitle "BFSOS Installer" \
                                --title "Password rejected" \
                                --msgbox "The password was rejected by the installed BFSOS password policy. Choose a different password, or leave it blank to keep password login locked." \
                                11 76 </dev/tty
                else
                        echo "Password rejected by the installed BFSOS password policy. Try another password."
                fi
        done
}

if [[ ! -f "$STATE_DIR/accounts_configured" ]]; then
create_standard_user "$USERNAME_VALUE"
prompt_optional_password "$USERNAME_VALUE" "Standard user $USERNAME_VALUE" || exit 1

read -r -a ADDITIONAL_USER_ENTRIES_ARRAY <<< "$ADDITIONAL_USER_ENTRIES_VALUE"

for entry in "${ADDITIONAL_USER_ENTRIES_ARRAY[@]}"; do
        [[ -n "$entry" ]] || continue
        IFS=':' read -r user_name account_type supplementary_groups <<< "$entry"
        account_type="${account_type:-standard}"
        case "$account_type" in
                standard)
                        create_standard_user "$user_name"
                        prompt_optional_password "$user_name" "Standard user $user_name" || exit 1
                        ;;
                service)
                        create_service_user "$user_name" service "$supplementary_groups"
                        ;;
                service-login)
                        create_service_user "$user_name" service-login "$supplementary_groups"
                        prompt_optional_password "$user_name" "System/service account $user_name" || exit 1
                        ;;
                *)
                        echo "Unknown account type '$account_type' for '$user_name'." >&2
                        exit 1
                        ;;
        esac
done

if [[ "$ROOT_PASSWORD_POLICY_VALUE" == prompt ]]; then
        prompt_optional_password root root || exit 1
else
        passwd -l root >/dev/null 2>&1 || usermod -L root
        printf 'Root password login remains locked by installer policy.\n'
fi
touch "$STATE_DIR/accounts_configured"
else
        log "Account/password checkpoint already complete; preserving configured accounts"
fi

if [[ ! -f "$STATE_DIR/packages_complete" ]]; then
command -v prt-get >/dev/null 2>&1 || {
        echo "prt-get is missing; mandatory system upgrade cannot run." >&2
        exit 1
}
command -v ports >/dev/null 2>&1 || {
        echo "ports is missing; mandatory ports synchronization cannot run." >&2
        exit 1
}

record_package_failure() {
        local operation="$1" status="$2"
        mkdir -p /run
        {
                printf 'operation=%s\n' "$operation"
                printf 'status=%s\n' "$status"
        } > /run/bfs-install-failure
        mkdir -p /var/lib/bfs-installer
        cp /run/bfs-install-failure /var/lib/bfs-installer/last_failure 2>/dev/null || true
}

human_elapsed() {
        local total="${1:-0}" d=0 h=0 m=0 s=0
        [[ "$total" =~ ^[0-9]+$ ]] || total=0
        d=$((total / 86400))
        h=$(((total % 86400) / 3600))
        m=$(((total % 3600) / 60))
        s=$((total % 60))
        if ((d > 0)); then
                printf '%dd %dh %02dm %02ds' "$d" "$h" "$m" "$s"
        elif ((h > 0)); then
                printf '%dh %02dm %02ds' "$h" "$m" "$s"
        elif ((m > 0)); then
                printf '%dm %02ds' "$m" "$s"
        else
                printf '%ds' "$s"
        fi
}

run_package_operation() {
        local operation="$1"; shift
        local status=0 start=0 end=0 elapsed=0
        start="$(date +%s)"
        if "$@"; then
                status=0
        else
                status=$?
        fi
        end="$(date +%s)"
        elapsed=$((end - start))
        mkdir -p /var/log/pkgbuild
        printf '%s\tinstaller\t%s\tstatus=%s\telapsed_seconds=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$operation" "$status" "$elapsed" \
                >> /var/log/pkgbuild/build-times.log
        printf 'Timing: %s completed in %s (status %s)\n' "$operation" "$(human_elapsed "$elapsed")" "$status"
        if ((status != 0)); then
                record_package_failure "$operation" "$status"
                echo "ERROR: $operation failed with exit status $status" >&2
                exit "$status"
        fi
}

rm -f /run/bfs-install-failure

# Apply integrity toggles before ports synchronization, sysup, dependency
# preflights, or the GLib/GI bootstrap.  The older ordering applied these
# settings only after the package transaction had already run, so selecting
# "Verify footprints: no" could not affect the failing package build.
configure_pkgmk_integrity_settings_early() {
        local conf=/etc/pkgmk.conf md5_ignore=no signature_ignore=no footprint_ignore=no
        [[ -f "$conf" ]] || return 0

        [[ "$VERIFY_MD5_VALUE" == yes ]] || md5_ignore=yes
        [[ "$VERIFY_SIGNATURE_VALUE" == yes ]] || signature_ignore=yes
        [[ "$VERIFY_FOOTPRINT_VALUE" == yes ]] || footprint_ignore=yes

        sed -i \
                -e "s|^PKGMK_IGNORE_MD5SUM=.*|PKGMK_IGNORE_MD5SUM=\"$md5_ignore\"|" \
                -e "s|^PKGMK_IGNORE_SIGNATURE=.*|PKGMK_IGNORE_SIGNATURE=\"$signature_ignore\"|" \
                -e "s|^PKGMK_IGNORE_FOOTPRINT=.*|PKGMK_IGNORE_FOOTPRINT=\"$footprint_ignore\"|" \
                "$conf"

        log "Early package integrity policy: MD5=$VERIFY_MD5_VALUE signatures=$VERIFY_SIGNATURE_VALUE footprints=$VERIFY_FOOTPRINT_VALUE"
}

configure_pkgmk_integrity_settings_early

ensure_bfsos_git_ports() {
        local config=/etc/ports/bfsos.git
        local driver=/etc/ports/drivers/git

        if ! command -v git >/dev/null 2>&1; then
                log "Git is required by BFSOS ports; installing it from the existing base ports tree before ports -u"
                run_package_operation "required Git installation for ports synchronization" prt-get depinst git
        fi
        command -v git >/dev/null 2>&1 || { echo "Git installation completed but git is still unavailable." >&2; return 1; }

        mkdir -p /etc/ports/drivers
        if [[ -r /root/.bfsos-git-driver ]]; then
                install -m 0755 /root/.bfsos-git-driver "$driver"
        fi
        [[ -x "$driver" ]] || { echo "CRUX/BFSOS Git ports driver is missing after Git installation." >&2; return 1; }

        cat > "$config" <<'EOF_BFSOS_GIT'
URL=https://github.com/bmadonnaster/BFSOS.git
NAME=bfsos
BRANCH=main
LOCAL_REPOSITORY=/var/cache/ports-git/bfsos
COLLECTIONS="compat-32:ports/compat-32 compiz:ports/compiz contrib:ports/contrib core:ports/core gnome:ports/gnome iso:ports/iso lxqt:ports/lxqt opt:ports/opt plasma:ports/plasma xfce:ports/xfce xorg:ports/xorg"
EOF_BFSOS_GIT

        # Retire only BFSOS-owned legacy HttpUp definitions. Third-party *.httpup
        # files remain untouched and continue to use the generic HttpUp driver.
        local collection
        for collection in compat-32 compiz contrib core gnome iso lxqt opt plasma xfce xorg; do
                rm -f "/etc/ports/$collection.httpup"
        done
}

ensure_bfsos_git_ports || exit 1
log "Synchronizing BFSOS ports tree through Git"
run_package_operation "ports synchronization (ports -u)" ports -u

# GLib/GObject-Introspection bootstrap ordering.
#
# A bootstrap GLib without introspection is valid before gobject-introspection
# exists. Generated/final GLib metadata must not reject that pass. Once GI is
# installed, rebuild GLib once so its GIR files exist before Polkit is built.
ensure_glib_introspection_ready() {
        local closure="${1:-}"
        local glib_port="/usr/ports/opt/glib"
        local glib_footprint="$glib_port/.footprint"
        local gir=""

        case " $closure " in
                *" gobject-introspection "*|*" polkit "*) ;;
                *) return 0 ;;
        esac

        if ! prt-get isinst gobject-introspection >/dev/null 2>&1; then
                log "Preparing GObject Introspection before Polkit"
                rm -f "$glib_footprint"
                rm -f /var/cache/pkg/packages/glib#*.pkg.tar.*
                run_package_operation "gobject-introspection bootstrap installation" \
                        prt-get depinst gobject-introspection
        fi

        if [[ ! -r /usr/share/gir-1.0/Gio-2.0.gir || \
              ! -r /usr/share/gir-1.0/GLib-2.0.gir || \
              ! -r /usr/share/gir-1.0/GObject-2.0.gir ]]; then
                log "Rebuilding GLib once with introspection enabled"
                rm -f "$glib_footprint"
                rm -f /var/cache/pkg/packages/glib#*.pkg.tar.*
                run_package_operation "GLib introspection rebuild" \
                        prt-get -fr update glib
        fi

        for gir in GLib-2.0.gir GObject-2.0.gir Gio-2.0.gir GioUnix-2.0.gir GModule-2.0.gir GLibUnix-2.0.gir; do
                if [[ ! -r "/usr/share/gir-1.0/$gir" ]]; then
                        echo "ERROR: required GLib introspection file is still missing: /usr/share/gir-1.0/$gir" >&2
                        return 1
                fi
        done

        log "GObject Introspection is installed and GLib GIR files are ready for Polkit"
}


log "Running mandatory installed-system upgrade"
# prt-get update/sysup intentionally do not install dependencies newly added
# since a package was first installed. Resolve those missing dependencies first
# using the dependency-preflight pattern documented by CRUX.
outdated_packages="$(prt-get quickdiff 2>/dev/null || true)"
if [[ -n "$outdated_packages" ]]; then
        dependency_closure="$(prt-get quickdep $outdated_packages 2>/dev/null || true)"
        if [[ -n "$dependency_closure" ]]; then
                ensure_glib_introspection_ready "$dependency_closure" || exit 1
                missing_dependencies="$(prt-get isinst $dependency_closure 2>/dev/null | awk '/not installed/ {print $2}' | sort -u | tr '\n' ' ')"
                if [[ -n "$missing_dependencies" ]]; then
                        read -r -a missing_dependency_array <<< "$missing_dependencies"
                        run_package_operation "new dependencies required by system upgrade" \
                                prt-get depinst "${missing_dependency_array[@]}"
                fi
        fi
fi

run_package_operation "mandatory package upgrade (prt-get sysup)" prt-get sysup

log "Ensuring BFSOS package-build safety/cache tooling is installed"
run_package_operation "mandatory build tooling (fakeroot/ccache)" prt-get depinst fakeroot fmt xxhash ccache


if [[ -n "$PACKAGE_LIST_VALUE" ]]; then
        read -r -a PACKAGE_LIST_ARRAY <<< "$PACKAGE_LIST_VALUE"
        ((${#PACKAGE_LIST_ARRAY[@]} > 0)) || {
                echo "Internal error: package selection was empty." >&2
                exit 1
        }
        MISSING_PACKAGES=()
        log "Checking selected package installation status"
        for package in "${PACKAGE_LIST_ARRAY[@]}"; do
                if prt-get isinst "$package" >/dev/null 2>&1; then
                        printf 'Already installed: %s\n' "$package"
                else
                        printf 'Will install:      %s\n' "$package"
                        MISSING_PACKAGES+=("$package")
                fi
        done
        if ((${#MISSING_PACKAGES[@]} > 0)); then
                dependency_closure="$(prt-get quickdep "${MISSING_PACKAGES[@]}" 2>/dev/null || true)"
                ensure_glib_introspection_ready "$dependency_closure" || exit 1

                log "Installing missing packages: ${MISSING_PACKAGES[*]}"
                run_package_operation "optional package installation (${MISSING_PACKAGES[*]})" prt-get depinst "${MISSING_PACKAGES[@]}"
        else
                log "All selected packages are already installed"
        fi
else
        log "No optional packages were selected"
fi

touch "$STATE_DIR/packages_complete"
rm -f "$STATE_DIR/last_failure" /run/bfs-install-failure /root/.bfsos-git-driver
else
        log "Package transaction checkpoint already complete; skipping ports/sysup/depinst"
fi

# --------------------------------------------------------------------------
# Pacman pipeline bootstrap (--bfsos-pacman, default yes). Installs the
# core/pacman port through the same pkgutils transaction the installer just
# finished using, then builds/installs the first batch of bfsos repository
# packages with the new bfs-build/bfs-deps pipeline, so the installed system
# boots straight into pacman-based package management.
# --------------------------------------------------------------------------
INSTALL_PACMAN_PIPE="${BFS_INSTALL_PACMAN:-yes}"
if [[ "$INSTALL_PACMAN_PIPE" == yes ]]; then
        if [[ -d "$PROJECT_DIR/ports/core/pacman" && -f "$PROJECT_DIR/ports/core/pacman/Pkgfile" ]]; then
                log "Pacman pipeline requested; building and installing core/pacman"
                if prt-get isinst pacman >/dev/null 2>&1; then
                        log "pacman is already installed; skipping"
                else
                        run_package_operation "pacman pipeline installation" \
                                prt-get depinst pacman
                fi
                if command -v pacman >/dev/null 2>&1; then
                        # Publish the packages the installer just built from
                        # source into the pacman-compatible bfsos repository.
                        # Starting the repo makes bfsos install/upgrade work
                        # on the first boot. Failures here are not fatal:
                        # admins can rebuild the repository any time with
                        # bfs-repo-add.
                        repo_dir="/var/cache/repo/bfsos"
                        mkdir -p "$TARGET$repo_dir" 2>/dev/null || true
                        if command -v bfs-repo-add >/dev/null 2>&1; then
                                log "Publishing pacman repository database"
                                bfs-repo-add --repo bfsos --dbdir "$TARGET$repo_dir" \
                                        "$TARGET"/var/cache/pkg/packages/*.pkg.tar.* 2>/dev/null || \
                                        log "WARNING: bfs-repo-add could not populate the repository; rebuild later with bfs-repo-add"
                        fi
                        log "Pacman pipeline ready: bfsos install/upgrade available after reboot"
                else
                        log "WARNING: pacman was requested but is not available after installation"
                fi
        else
                log "Pacman pipeline requested but the core/pacman port is missing; skipping"
        fi
fi

if [[ "$INSTALL_GPM_VALUE" == yes ]]; then
        if [[ -f /usr/lib/systemd/system/gpm.service || -f /etc/systemd/system/gpm.service ]]; then
                offline_systemctl enable gpm.service 2>/dev/null ||
                        echo "WARNING: gpm was installed but gpm.service could not be enabled automatically." >&2
        else
                echo "WARNING: gpm was selected/installed but no gpm.service unit was found." >&2
        fi
fi

if [[ "$INSTALL_SUDO_VALUE" == yes ]]; then
        mkdir -p /etc/sudoers.d

        case "$SUDO_MODE_VALUE" in
                password)
                        cat > /etc/sudoers.d/10-wheel <<'EOF_SUDO_PASSWORD'
## Allow members of group wheel to execute any command
%wheel ALL=(ALL:ALL) ALL
EOF_SUDO_PASSWORD
                        ;;
                nopasswd)
                        cat > /etc/sudoers.d/10-wheel <<'EOF_SUDO_NOPASSWD'
## Allow members of group wheel to execute any command without a password
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF_SUDO_NOPASSWD
                        ;;
                *)
                        echo "Invalid sudo mode: $SUDO_MODE_VALUE" >&2
                        exit 1
                        ;;
        esac

        chmod 0440 /etc/sudoers.d/10-wheel

        if command -v visudo >/dev/null 2>&1; then
                visudo -cf /etc/sudoers.d/10-wheel
        fi
else
        rm -f /etc/sudoers.d/10-wheel
fi

offline_systemctl() {
        # /run is bind-mounted from the live environment while installing.
        # Force systemctl to operate only on the target filesystem so it never
        # attempts to contact the live system's D-Bus or systemd manager.
        env -u DBUS_SESSION_BUS_ADDRESS \
            -u DBUS_SYSTEM_BUS_ADDRESS \
            -u SYSTEMD_EXEC_PID \
            SYSTEMD_OFFLINE=1 \
            SYSTEMD_IGNORE_CHROOT=1 \
            systemctl --root=/ --no-reload --no-ask-password "$@"
}

command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -A
ldconfig
offline_systemctl preset-all || true

if [[ "$INSTALL_NETWORKMANAGER_VALUE" == yes ]] && offline_systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
        log "Enabling NetworkManager and disabling systemd-networkd"
        offline_systemctl enable NetworkManager.service
        offline_systemctl disable systemd-networkd.service 2>/dev/null || true
        offline_systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
elif offline_systemctl list-unit-files systemd-networkd.service >/dev/null 2>&1; then
        log "Enabling systemd-networkd"
        offline_systemctl enable systemd-networkd.service
        offline_systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
fi

if offline_systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
        offline_systemctl enable systemd-resolved.service
        ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

if [[ "$ENABLE_OPENSSH_VALUE" == yes ]]; then
        if offline_systemctl list-unit-files sshd.service >/dev/null 2>&1; then
                offline_systemctl enable sshd.service
        elif offline_systemctl list-unit-files ssh.service >/dev/null 2>&1; then
                offline_systemctl enable ssh.service
        else
                echo "WARNING: No OpenSSH service unit was found." >&2
        fi
fi

if [[ "$AUTO_LVM2_VALUE" == yes ]] &&
   command -v lvmconfig >/dev/null 2>&1; then
        if [[ ! -f /etc/lvm/lvm.conf ]]; then
                mkdir -p /etc/lvm
                lvmconfig --type full --withcomments > /etc/lvm/lvm.conf
        fi
        offline_systemctl enable lvm2-monitor.service 2>/dev/null || true
fi

configure_required_mdadm_conf() {
        local array="" uuid="" scan_line=""
        local -A wanted=()

        [[ "$AUTO_MDADM_VALUE" == yes ]] || { rm -f /etc/mdadm.conf; return 0; }
        command -v mdadm >/dev/null 2>&1 || {
                echo "Software RAID storage was detected, but mdadm is missing." >&2
                return 1
        }

        while IFS= read -r uuid; do
                [[ -n "$uuid" ]] && wanted["$uuid"]=1
        done < <(discover_required_md_uuids)

        ((${#wanted[@]} > 0)) || {
                echo "Software RAID is required, but no required MD UUID could be derived from the installed storage topology." >&2
                return 1
        }

        : > /etc/mdadm.conf
        printf '# Generated by the BFSOS installer from required target MD topology.\n' >> /etc/mdadm.conf
        while IFS= read -r scan_line; do
                [[ "$scan_line" == ARRAY* ]] || continue
                for uuid in "${!wanted[@]}"; do
                        if [[ " $scan_line " == *" UUID=$uuid "* || "$scan_line" == *" UUID=$uuid" ]]; then
                                printf '%s\n' "$scan_line" >> /etc/mdadm.conf
                                unset 'wanted[$uuid]'
                                break
                        fi
                done
        done < <(mdadm --detail --scan 2>/dev/null || true)

        if ((${#wanted[@]} > 0)); then
                echo "Failed to generate mdadm.conf entries for required MD UUID(s): ${!wanted[*]}" >&2
                return 1
        fi

        awk '!seen[$0]++' /etc/mdadm.conf > /etc/mdadm.conf.tmp
        mv /etc/mdadm.conf.tmp /etc/mdadm.conf
        log "Generated /etc/mdadm.conf for required BFSOS MD array(s)"
}

if [[ "$AUTO_CRYPTSETUP_VALUE" == yes ]]; then
        mkdir -p /etc/cryptsetup-keys.d
        chmod 0700 /etc/cryptsetup-keys.d
fi

configure_btrfs_snapshots() {
        local -a config_names=()
        local -a mountpoints=()
        local index="" config_name="" mountpoint_name="" config_file=""
        local have_root_config=no
        local snapper_configs=""

        read -r -a config_names <<< "$BTRFS_CONFIG_NAMES_VALUE"
        read -r -a mountpoints <<< "$BTRFS_MOUNTPOINTS_VALUE"

        ((${#config_names[@]} > 0)) || {
                # preset-all may have enabled the root-only boot timer even when
                # the installation has no root Snapper configuration.
                offline_systemctl disable snapper-boot.timer 2>/dev/null || true
                return 0
        }

        command -v snapper >/dev/null 2>&1 || {
                echo "Btrfs was selected but snapper is not installed." >&2
                exit 1
        }

        # BFS creates and mounts the dedicated *.snapshots Btrfs subvolumes
        # itself. Do not run `snapper create-config`, because it tries to create
        # .snapshots again and fails when that subvolume already exists.
        #
        # This Snapper build reads the global list from /etc/sysconfig/snapper.
        # Keep /etc/default/snapper in sync as a compatibility copy.
        mkdir -p /etc/snapper/configs /etc/sysconfig /etc/default

        for ((index=0; index<${#config_names[@]}; index++)); do
                config_name="${config_names[$index]}"
                mountpoint_name="${mountpoints[$index]}"
                config_file="/etc/snapper/configs/$config_name"

                [[ "$config_name" == root ]] && have_root_config=yes

                cat > "$config_file" <<EOF_SNAPPER
SUBVOLUME="$mountpoint_name"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS="wheel"
SYNC_ACL="yes"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="10"
TIMELINE_LIMIT_DAILY="10"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="10"
TIMELINE_LIMIT_YEARLY="10"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF_SNAPPER
        done

        snapper_configs="${config_names[*]}"
        printf 'SNAPPER_CONFIGS="%s"\n' "$snapper_configs" > /etc/sysconfig/snapper
        printf 'SNAPPER_CONFIGS="%s"\n' "$snapper_configs" > /etc/default/snapper

        # Verify the global registration and every per-filesystem config before
        # enabling timers. This prevents a fresh install from booting with a
        # guaranteed failed Snapper unit.
        grep -q '^SNAPPER_CONFIGS=.*[^"]' /etc/sysconfig/snapper || {
                echo "Snapper configuration error: no configurations were registered." >&2
                exit 1
        }

        for config_name in "${config_names[@]}"; do
                [[ -s "/etc/snapper/configs/$config_name" ]] || {
                        echo "Snapper configuration error: missing config '$config_name'." >&2
                        exit 1
                }
        done

        # The installer configures Snapper from inside the target chroot.
        # D-Bus is not normally running there, so plain `snapper list-configs`
        # can fail with org.freedesktop.DBus.Error.ServiceUnknown even when the
        # generated configuration is valid. Use Snapper's direct mode instead.
        if snapper --help 2>&1 | grep -q -- '--no-dbus'; then
                if ! snapper --no-dbus list-configs >/dev/null 2>&1; then
                        echo "Snapper configuration error: generated configs are not readable." >&2
                        exit 1
                fi
        else
                echo "NOTE: Snapper --no-dbus is unavailable; file-level configuration checks passed." >&2
        fi

        offline_systemctl enable snapper-timeline.timer 2>/dev/null || true
        offline_systemctl enable snapper-cleanup.timer 2>/dev/null || true

        # snapper-boot.service is hard-coded to use --config root, so only
        # enable its timer when / is actually one of the configured Btrfs
        # filesystems. Explicitly disable it otherwise because preset-all may
        # have enabled it earlier.
        if [[ "$have_root_config" == yes ]]; then
                offline_systemctl enable snapper-boot.timer 2>/dev/null || true
        else
                offline_systemctl disable snapper-boot.timer 2>/dev/null || true
        fi

        for config_name in "${config_names[@]}"; do
                if snapper --help 2>&1 | grep -q -- '--no-dbus'; then
                        snapper --no-dbus -c "$config_name" create \
                                --cleanup-algorithm number \
                                --description "Initial BFSOS installation" || {
                                echo "WARNING: Could not create initial Snapper snapshot for '$config_name'." >&2
                        }
                else
                        # The configs and snapshot subvolumes are already in
                        # place. Defer the initial snapshot until normal boot
                        # rather than failing the whole installation.
                        echo "NOTE: Initial Snapper snapshot for '$config_name' deferred until boot." >&2
                fi
        done
}

configure_btrfs_snapshots

# Keep normal cosmetic options in GRUB_CMDLINE_LINUX_DEFAULT, while storage
# discovery arguments live in GRUB_CMDLINE_LINUX so normal, recovery, and
# future kernel entries all inherit the same required early-boot topology.
mkdir -p /etc/default
touch /etc/default/grub

grub_get_cmdline_value() {
        local key="$1"
        sed -n "s/^${key}=\"\([^\"]*\)\"/\1/p" /etc/default/grub | head -n1
}

grub_set_cmdline_value() {
        local key="$1" value="$2"
        if grep -q "^${key}=" /etc/default/grub; then
                sed -i "s|^${key}=.*|${key}=\"${value}\"|" /etc/default/grub
        else
                printf '%s="%s"\n' "$key" "$value" >> /etc/default/grub
        fi
}

cmdline_append_unique() {
        local variable="$1" token="$2" value="${!1:-}"
        case " $value " in
                *" $token "*) ;;
                *) value="${value:+$value }$token" ;;
        esac
        printf -v "$variable" '%s' "$value"
}

strip_bfs_storage_cmdline() {
        local value="$1" token="" result=""
        for token in $value; do
                case "$token" in
                        rd.auto|rd.md=*|rd.driver.pre=*|rd.luks.uuid=*|rd.lvm.lv=*|video=*|console=tty0|console=ttyS0,115200|console=ttyS0,115200n8)
                                ;;
                        *)
                                result+="${result:+ }$token"
                                ;;
                esac
        done
        printf '%s' "$result"
}

discover_required_lvm_cmdline() {
        local source="" mountpoint="" fstype="" options="" dump="" passno=""
        local device="" device_real="" source_uuid=""
        local lv_record="" vg="" lv="" lv_path="" lv_real="" lv_uuid=""

        command -v lvs >/dev/null 2>&1 || return 0
        [[ -r /etc/fstab ]] || return 0

        while read -r source mountpoint fstype options dump passno; do
                [[ -n "$source" && "$source" != \#* ]] || continue

                device=""
                source_uuid=""
                case "$source" in
                        UUID=*)
                                source_uuid="${source#UUID=}"
                                command -v blkid >/dev/null 2>&1 &&
                                        device="$(blkid -U "$source_uuid" 2>/dev/null || true)"
                                ;;
                        /dev/*)
                                device="$source"
                                command -v blkid >/dev/null 2>&1 &&
                                        source_uuid="$(blkid -s UUID -o value "$device" 2>/dev/null || true)"
                                ;;
                        *)
                                continue
                                ;;
                esac

                device_real=""
                [[ -n "$device" ]] && device_real="$(readlink -f "$device" 2>/dev/null || true)"

                # Do not ask `lvs` to resolve the fstab device as a positional
                # LV selector.  Device-mapper may expose the same LV through
                # /dev/mapper/<escaped>, /dev/<vg>/<lv>, or /dev/dm-N, and the
                # selector lookup proved unreliable for non-root LVs on real
                # hardware.  Instead inventory every LV and match the fstab
                # filesystem by canonical block-device path and, independently,
                # by the filesystem UUID stored in fstab.
                while IFS='|' read -r vg lv lv_path; do
                        vg="$(printf '%s' "$vg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                        lv="$(printf '%s' "$lv" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                        lv_path="$(printf '%s' "$lv_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                        [[ -n "$vg" && -n "$lv" && -n "$lv_path" ]] || continue

                        lv_real="$(readlink -f "$lv_path" 2>/dev/null || true)"
                        lv_uuid=""
                        command -v blkid >/dev/null 2>&1 &&
                                lv_uuid="$(blkid -s UUID -o value "$lv_path" 2>/dev/null || true)"

                        if [[ -n "$device_real" && -n "$lv_real" && "$device_real" == "$lv_real" ]] ||
                           [[ -n "$source_uuid" && -n "$lv_uuid" && "$source_uuid" == "$lv_uuid" ]]; then
                                printf '%s/%s\n' "$vg" "$lv"
                                break
                        fi
                done < <(lvs --noheadings --separator '|' -o vg_name,lv_name,lv_path 2>/dev/null || true)
        done < /etc/fstab
}


discover_required_luks_cmdline() {
        local name="" source="" keyfile="" options="" uuid=""
        [[ -r /etc/crypttab ]] || return 0
        while read -r name source keyfile options; do
                [[ -n "$name" && "$name" != \#* ]] || continue
                case "$source" in
                        UUID=*) uuid="${source#UUID=}" ;;
                        /dev/*)
                                uuid="$(cryptsetup luksUUID "$source" 2>/dev/null ||
                                        blkid -s UUID -o value "$source" 2>/dev/null || true)"
                                ;;
                        *) uuid="" ;;
                esac
                [[ -n "$uuid" ]] && printf '%s\n' "$uuid"
        done < /etc/crypttab
}

discover_required_md_cmdline() {
        local source="" mountpoint="" fstype="" options="" dump="" passno=""
        local device=""
        [[ -r /etc/fstab ]] || return 0
        while read -r source mountpoint fstype options dump passno; do
                [[ -n "$source" && "$source" != \#* ]] || continue
                case "$source" in
                        UUID=*) device="$(blkid -U "${source#UUID=}" 2>/dev/null || true)" ;;
                        /dev/*) device="$source" ;;
                        *) continue ;;
                esac
                [[ -n "$device" ]] || continue
                lsblk -s -prno PATH,TYPE "$device" 2>/dev/null |
                        awk '$2 == "md" || $2 == "linear" || $2 ~ /^raid/ {print $1}'
        done < /etc/fstab
}


discover_required_md_uuids() {
        local array="" uuid=""
        command -v mdadm >/dev/null 2>&1 || return 0
        while IFS= read -r array; do
                [[ -b "$array" ]] || continue
                uuid="$(
                        mdadm --detail "$array" 2>/dev/null |
                                sed -n 's/^[[:space:]]*UUID[[:space:]]*:[[:space:]]*//p' |
                                head -n1
                )"
                uuid="${uuid%%[[:space:]]*}"
                [[ -n "$uuid" ]] && printf '%s\n' "$uuid"
        done < <(discover_required_md_cmdline | sort -u)
}

md_array_level() {
        local array="$1" name="" level=""
        name="${array##*/}"
        if [[ -r "/sys/class/block/$name/md/level" ]]; then
                read -r level < "/sys/class/block/$name/md/level" || true
        fi
        if [[ -z "$level" ]] && command -v mdadm >/dev/null 2>&1; then
                level="$(mdadm --detail "$array" 2>/dev/null |
                        sed -n 's/^[[:space:]]*Raid Level[[:space:]]*:[[:space:]]*//p' |
                        head -n1 || true)"
        fi
        printf '%s' "${level,,}"
}

md_level_to_preload() {
        case "${1,,}" in
                linear|-1) printf '%s' linear ;;
                raid0|0) printf '%s' raid0 ;;
                raid1|1) printf '%s' raid1 ;;
                raid10|10) printf '%s' raid10 ;;
                raid4|raid5|raid6|4|5|6) printf '%s' raid456 ;;
                *) return 1 ;;
        esac
}

discover_required_md_preload_drivers() {
        local array="" level="" driver=""
        while IFS= read -r array; do
                [[ -b "$array" ]] || continue
                level="$(md_array_level "$array")"
                driver="$(md_level_to_preload "$level" 2>/dev/null || true)"
                if [[ -z "$driver" ]]; then
                        echo "Unable to map MD personality '$level' for required array $array." >&2
                        return 1
                fi
                printf '%s\n' "$driver"
        done < <(discover_required_md_cmdline | sort -u)
}

md_array_uuid() {
        local array="$1" uuid=""
        command -v mdadm >/dev/null 2>&1 || return 1
        uuid="$(mdadm --detail "$array" 2>/dev/null |
                sed -n 's/^[[:space:]]*UUID[[:space:]]*:[[:space:]]*//p' |
                head -n1 || true)"
        uuid="${uuid%%[[:space:]]*}"
        [[ -n "$uuid" ]] || return 1
        printf '%s' "$uuid"
}

md_array_metadata_version() {
        local array="$1"
        mdadm --detail "$array" 2>/dev/null |
                sed -n 's/^[[:space:]]*Version[[:space:]]*:[[:space:]]*//p' |
                head -n1
}

md_v12_member_has_nonzero_reserved_padding() {
        local member="$1" magic="" reserved=""
        [[ -b "$member" ]] || return 2

        # MD metadata 1.2 places the v1 superblock 4096 bytes from the start
        # of each member.  Linux 6.18 rejects non-zero pad0/pad3 bytes; the
        # BFSOS compatibility backport can accept that specific newer-metadata
        # case when this conservative probe confirms it.
        magic="$(dd if="$member" bs=1 skip=4096 count=4 status=none 2>/dev/null |
                od -An -v -tx1 | tr -d '[:space:]')"
        [[ "$magic" == fc4e2ba9 ]] || return 2

        reserved="$({
                dd if="$member" bs=1 skip=$((4096 + 12)) count=4 status=none 2>/dev/null
                dd if="$member" bs=1 skip=$((4096 + 224)) count=32 status=none 2>/dev/null
        } | od -An -v -tx1 | tr -d '[:space:]')"
        [[ ${#reserved} -eq 72 ]] || return 2
        [[ "$reserved" =~ [1-9a-fA-F] ]]
}

md_array_requires_618_compat() {
        local array="$1" name="${1##*/}" member_path="" member=""
        local sector_size="" expected_sector_size="" members=0 affected=0

        [[ "$(md_array_metadata_version "$array" 2>/dev/null || true)" == 1.2 ]] || return 1
        [[ -d "/sys/class/block/$name/slaves" ]] || return 2

        for member_path in /sys/class/block/"$name"/slaves/*; do
                [[ -e "$member_path" ]] || continue
                member="/dev/${member_path##*/}"
                [[ -b "$member" ]] || return 2
                sector_size="$(blockdev --getss "$member" 2>/dev/null || true)"
                [[ "$sector_size" =~ ^[0-9]+$ ]] || return 2
                if [[ -z "$expected_sector_size" ]]; then
                        expected_sector_size="$sector_size"
                elif [[ "$sector_size" != "$expected_sector_size" ]]; then
                        echo "MD compatibility probe refused: mixed logical sector sizes in $array." >&2
                        return 2
                fi
                members=$((members + 1))
                if md_v12_member_has_nonzero_reserved_padding "$member"; then
                        affected=1
                else
                        case $? in
                                1) : ;;
                                *) echo "MD compatibility probe could not validate the v1.2 superblock on $member." >&2; return 2 ;;
                        esac
                fi
        done

        (( members >= 2 )) || return 2
        (( affected == 1 ))
}

configure_md_618_compat_policy() {
        local state_dir=/etc/bfsos state_file=/etc/bfsos/md-compat.conf
        local tmp="" array="" uuid="" rc=0 count=0
        mkdir -p "$state_dir"
        tmp="$state_file.tmp.$$"
        : > "$tmp"
        printf '%s\n' '# Managed by the BFSOS installer/kernel-maintenance policy.' >> "$tmp"
        printf '%s\n' 'reason=md-v1.2-nonzero-reserved-padding' >> "$tmp"

        while IFS= read -r array; do
                [[ -b "$array" ]] || continue
                set +e
                md_array_requires_618_compat "$array"
                rc=$?
                set -e
                case "$rc" in
                        0)
                                uuid="$(md_array_uuid "$array" 2>/dev/null || true)"
                                [[ -n "$uuid" ]] || {
                                        rm -f "$tmp"
                                        echo "Unable to record MD UUID for compatibility-required array $array." >&2
                                        return 1
                                }
                                printf 'uuid=%s\n' "$uuid" >> "$tmp"
                                log "Linux 6.18 MD compatibility required for $array ($uuid): validated metadata 1.2 member padding."
                                count=$((count + 1))
                                ;;
                        1) ;;
                        *)
                                rm -f "$tmp"
                                echo "MD compatibility safety probe was inconclusive for required array $array; refusing to enable the 6.18 bypass automatically." >&2
                                return 1
                                ;;
                esac
        done < <(discover_required_md_cmdline | sort -u)

        if (( count > 0 )); then
                mv -f "$tmp" "$state_file"
        else
                rm -f "$tmp" "$state_file"
        fi
}

apply_md_618_compat_to_grub_config() {
        local cfg="$1" state_file=/etc/bfsos/md-compat.conf tmp=""
        [[ -s "$state_file" ]] || return 0
        grep -q '^uuid=' "$state_file" || return 0
        tmp="$cfg.mdcompat.$$"
        awk '
                /^[[:space:]]*linux[[:space:]]/ && /vmlinuz-6\.18\.[^[:space:]]*-BFS-LTS/ {
                        if ($0 !~ /(^|[[:space:]])md_mod\.check_new_feature=/)
                                $0=$0 " md_mod.check_new_feature=0"
                }
                { print }
        ' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
        mv -f "$tmp" "$cfg"
}

configure_grub_storage_cmdline() {
        local default_cmdline="" storage_cmdline="" token="" uuid="" lv="" driver=""
        local -A seen_luks=() seen_lvs=() seen_drivers=()

        default_cmdline="$(grub_get_cmdline_value GRUB_CMDLINE_LINUX_DEFAULT)"
        storage_cmdline="$(grub_get_cmdline_value GRUB_CMDLINE_LINUX)"

        # Remove storage arguments from both variables before rebuilding them.
        # This makes repeated installer runs idempotent and avoids stale UUID/LV
        # references after changing a storage layout.
        default_cmdline="$(strip_bfs_storage_cmdline "$default_cmdline")"
        storage_cmdline="$(strip_bfs_storage_cmdline "$storage_cmdline")"

        case " $default_cmdline " in
                *" consoleblank="*) ;;
                *) default_cmdline="${default_cmdline:+$default_cmdline }consoleblank=1800" ;;
        esac
        if [[ -n "$CONSOLE_VIDEO_ARG_VALUE" ]]; then
                cmdline_append_unique default_cmdline "$CONSOLE_VIDEO_ARG_VALUE"
        fi

        if [[ "$SERIAL_CONSOLE_VALUE" == yes ]]; then
                # Keep the graphical console last so it remains the primary kernel
                # console while the serial console is still available for logging and
                # recovery.  This ordering is required for a usable Dracut/LUKS prompt.
                cmdline_append_unique default_cmdline "console=ttyS0,115200n8"
                cmdline_append_unique default_cmdline "console=tty0"
        fi

        if [[ "$AUTO_CRYPTSETUP_VALUE" == yes ]]; then
                while IFS= read -r uuid; do
                        uuid="${uuid#luks-}"
                        [[ -n "$uuid" ]] || continue
                        [[ -z "${seen_luks[$uuid]:-}" ]] || continue
                        seen_luks["$uuid"]=1
                        cmdline_append_unique storage_cmdline "rd.luks.uuid=$uuid"
                done < <(discover_required_luks_cmdline)
        fi

        while IFS= read -r uuid; do
                [[ -n "$uuid" ]] || continue
                cmdline_append_unique storage_cmdline "rd.md.uuid=$uuid"
        done < <(discover_required_md_uuids)

        while IFS= read -r driver; do
                [[ -n "$driver" ]] || continue
                [[ -z "${seen_drivers[$driver]:-}" ]] || continue
                seen_drivers["$driver"]=1
                cmdline_append_unique storage_cmdline "rd.driver.pre=$driver"
        done < <(discover_required_md_preload_drivers)

        if [[ "$AUTO_LVM2_VALUE" == yes ]]; then
                while IFS= read -r lv; do
                        [[ -n "$lv" ]] || continue
                        [[ -z "${seen_lvs[$lv]:-}" ]] || continue
                        seen_lvs["$lv"]=1
                        cmdline_append_unique storage_cmdline "rd.lvm.lv=$lv"
                done < <(discover_required_lvm_cmdline)
        fi

        grub_set_cmdline_value GRUB_CMDLINE_LINUX_DEFAULT "$default_cmdline"
        grub_set_cmdline_value GRUB_CMDLINE_LINUX "$storage_cmdline"

        log "GRUB default kernel arguments: ${default_cmdline:-none}"
        log "GRUB storage kernel arguments: ${storage_cmdline:-none}"
}


verify_grub_storage_cmdline() {
        local cfg="/boot/grub/grub.cfg" uuid="" lv="" expected="" driver=""
        local linux_lines="" recovery_lines="" lts618_lines="" other_linux_lines=""
        local -A seen_luks=() seen_lvs=() seen_md=() seen_drivers=()

        [[ -s "$cfg" ]] || return 1
        linux_lines="$(grep -E '^[[:space:]]*linux[[:space:]]' "$cfg" || true)"
        [[ -n "$linux_lines" ]] || {
                echo "GRUB verification failed: no Linux entries found." >&2
                return 1
        }

        while IFS= read -r uuid; do
                [[ -n "$uuid" ]] || continue
                [[ -z "${seen_md[$uuid]:-}" ]] || continue
                seen_md["$uuid"]=1
                expected="rd.md.uuid=$uuid"
                grep -qF "$expected" <<<"$linux_lines" || {
                        echo "GRUB verification failed: missing complete MD RAID UUID." >&2
                        echo "Expected: $expected" >&2
                        printf 'Generated Linux lines:\n%s\n' "$linux_lines" >&2
                        return 1
                }
        done < <(discover_required_md_uuids)

        while IFS= read -r driver; do
                [[ -n "$driver" ]] || continue
                [[ -z "${seen_drivers[$driver]:-}" ]] || continue
                seen_drivers["$driver"]=1
                expected="rd.driver.pre=$driver"
                grep -qF "$expected" <<<"$linux_lines" || {
                        echo "GRUB verification failed: missing required MD personality preload $expected." >&2
                        return 1
                }
        done < <(discover_required_md_preload_drivers)

        if [[ -s /etc/bfsos/md-compat.conf ]] && grep -q '^uuid=' /etc/bfsos/md-compat.conf; then
                lts618_lines="$(grep -E '^[[:space:]]*linux[[:space:]].*vmlinuz-6\.18\.[^[:space:]]*-BFS-LTS' "$cfg" || true)"
                [[ -n "$lts618_lines" ]] || {
                        echo "GRUB verification failed: MD compatibility state exists but no Linux 6.18 LTS entry was generated." >&2
                        return 1
                }
                while IFS= read -r token; do
                        [[ -n "$token" ]] || continue
                        grep -qF "rd.md.uuid=$token" <<<"$lts618_lines" || {
                                echo "GRUB verification failed: affected 6.18 LTS entry is missing MD UUID $token." >&2
                                return 1
                        }
                done < <(sed -n 's/^uuid=//p' /etc/bfsos/md-compat.conf)
                grep -qF 'md_mod.check_new_feature=0' <<<"$lts618_lines" || {
                        echo "GRUB verification failed: affected 6.18 LTS entry is missing md_mod.check_new_feature=0." >&2
                        return 1
                }
                other_linux_lines="$(grep -E '^[[:space:]]*linux[[:space:]]' "$cfg" | grep -Ev 'vmlinuz-6\.18\.[^[:space:]]*-BFS-LTS' || true)"
                if [[ -n "$other_linux_lines" ]] && grep -qF 'md_mod.check_new_feature=0' <<<"$other_linux_lines"; then
                        echo "GRUB verification failed: 6.18 MD compatibility token leaked into a non-6.18-LTS entry." >&2
                        return 1
                fi
        fi

        if [[ "$AUTO_CRYPTSETUP_VALUE" == yes ]]; then
                while IFS= read -r uuid; do
                        uuid="${uuid#luks-}"
                        [[ -n "$uuid" ]] || continue
                        [[ -z "${seen_luks[$uuid]:-}" ]] || continue
                        seen_luks["$uuid"]=1
                        expected="rd.luks.uuid=$uuid"
                        grep -qF "$expected" <<<"$linux_lines" || {
                                echo "GRUB verification failed: missing required LUKS UUID." >&2
                                echo "Expected: $expected" >&2
                                printf 'Generated Linux lines:\n%s\n' "$linux_lines" >&2
                                return 1
                        }
                done < <(discover_required_luks_cmdline)
        fi

        if [[ "$AUTO_LVM2_VALUE" == yes ]]; then
                while IFS= read -r lv; do
                        [[ -n "$lv" ]] || continue
                        [[ -z "${seen_lvs[$lv]:-}" ]] || continue
                        seen_lvs["$lv"]=1
                        expected="rd.lvm.lv=$lv"
                        grep -qF "$expected" <<<"$linux_lines" || {
                                echo "GRUB verification failed: missing required LVM argument." >&2
                                echo "Expected: $expected" >&2
                                printf 'Generated Linux lines:\n%s\n' "$linux_lines" >&2
                                return 1
                        }
                done < <(discover_required_lvm_cmdline)
        fi

        recovery_lines="$(grep -E '^[[:space:]]*linux[[:space:]].*[[:space:]]single([[:space:]]|$)' "$cfg" || true)"
        if [[ -n "$recovery_lines" ]]; then
                for uuid in "${!seen_md[@]}"; do
                        grep -qF "rd.md.uuid=$uuid" <<<"$recovery_lines" || {
                                echo "GRUB verification failed: recovery entry is missing MD UUID $uuid." >&2
                                return 1
                        }
                done
                for driver in "${!seen_drivers[@]}"; do
                        grep -qF "rd.driver.pre=$driver" <<<"$recovery_lines" || {
                                echo "GRUB verification failed: recovery entry is missing MD preload driver $driver." >&2
                                return 1
                        }
                done
                for uuid in "${!seen_luks[@]}"; do
                        grep -qF "rd.luks.uuid=$uuid" <<<"$recovery_lines" || {
                                echo "GRUB verification failed: recovery entry is missing LUKS UUID $uuid." >&2
                                return 1
                        }
                done
                for lv in "${!seen_lvs[@]}"; do
                        grep -qF "rd.lvm.lv=$lv" <<<"$recovery_lines" || {
                                echo "GRUB verification failed: recovery entry is missing LVM argument $lv." >&2
                                return 1
                        }
                done
        fi
        return 0
}

configure_required_mdadm_conf || exit 1
configure_md_618_compat_policy || exit 1
configure_grub_storage_cmdline

configure_zram_swap() {
        local config="" module_found=no service="/usr/lib/systemd/system/bfs-zram.service"
        [[ "$ZRAM_SWAP_VALUE" == yes ]] || {
                rm -f "$service" /usr/libexec/bfs-zram-setup /usr/libexec/bfs-zram-stop
                rm -f /etc/systemd/system/swap.target.wants/bfs-zram.service
                return 0
        }

        config="$(find /boot -maxdepth 1 -type f -name 'config-*' -print 2>/dev/null | sort -V | tail -n1)"
        if [[ -n "$config" ]] && grep -qE '^CONFIG_ZRAM=(y|m)$' "$config"; then
                module_found=yes
        elif find /lib/modules -type f -name 'zram.ko*' -print -quit 2>/dev/null | grep -q .; then
                module_found=yes
        fi

        [[ "$module_found" == yes ]] || {
                echo "ZRAM swap was selected, but the installed kernel does not appear to provide ZRAM support." >&2
                exit 1
        }

        mkdir -p /usr/libexec /usr/lib/systemd/system
        cat > /usr/libexec/bfs-zram-setup <<'EOF_ZRAM_SETUP'
#!/usr/bin/env bash
set -e
modprobe zram 2>/dev/null || true
[[ -b /dev/zram0 ]] || { echo "zram0 device is unavailable" >&2; exit 1; }
mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
size_spec="__ZRAM_SIZE_SPEC__"
case "$size_spec" in
        *%)
                percent=${size_spec%%%}
                size_bytes=$((mem_kb * 1024 * percent / 100))
                ;;
        *G)
                value=${size_spec%G}
                size_bytes=$(awk -v v="$value" 'BEGIN { printf "%.0f", v * 1024 * 1024 * 1024 }')
                ;;
        *M)
                value=${size_spec%M}
                size_bytes=$(awk -v v="$value" 'BEGIN { printf "%.0f", v * 1024 * 1024 }')
                ;;
        *)
                echo "Invalid BFSOS ZRAM size: $size_spec" >&2
                exit 1
                ;;
esac
(( size_bytes > 0 )) || { echo "Calculated ZRAM size is zero" >&2; exit 1; }
if [[ -e /sys/block/zram0/reset ]]; then
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
fi
echo "$size_bytes" > /sys/block/zram0/disksize
mkswap -f /dev/zram0
swapon -p 100 /dev/zram0
EOF_ZRAM_SETUP
        chmod 0755 /usr/libexec/bfs-zram-setup

        cat > /usr/libexec/bfs-zram-stop <<'EOF_ZRAM_STOP'
#!/usr/bin/env bash
swapoff /dev/zram0 2>/dev/null || true
[[ -e /sys/block/zram0/reset ]] && echo 1 > /sys/block/zram0/reset 2>/dev/null || true
EOF_ZRAM_STOP
        chmod 0755 /usr/libexec/bfs-zram-stop

        cat > "$service" <<'EOF_ZRAM_SERVICE'
[Unit]
Description=BFSOS compressed ZRAM swap
DefaultDependencies=no
After=systemd-modules-load.service
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/bfs-zram-setup
ExecStop=/usr/libexec/bfs-zram-stop

[Install]
WantedBy=swap.target
EOF_ZRAM_SERVICE

        offline_systemctl enable bfs-zram.service
        [[ -L /etc/systemd/system/swap.target.wants/bfs-zram.service ]] || {
                echo "ZRAM service was created but was not enabled successfully." >&2
                exit 1
        }
        log "Configured ZRAM swap for boot"
}

configure_pkgmk_tmpfs() {
        local mountpoint=/var/cache/pkg/build-work size="$BUILD_TMPFS_SIZE_VALUE"
        local kb=0 gib=0 recommended="" fstab_line=""

        mkdir -p "$mountpoint"
        if [[ "$BUILD_TMPFS_VALUE" != yes ]]; then
                # Remove only the BFSOS-managed tmpfs entry if the option was disabled.
                if [[ -f /etc/fstab ]]; then
                        sed -i '\|^[[:space:]]*tmpfs[[:space:]]\+/var/cache/pkg/build-work[[:space:]]\+tmpfs[[:space:]]|d' /etc/fstab
                fi
                return 0
        fi

        if [[ "$size" == auto ]]; then
                kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
                [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
                gib=$(( (kb + 1048575) / 1048576 ))
                if ((gib < 16)); then
                        # Auto uses physical RAM only.  On systems below 16 GiB,
                        # leave build-work disk-backed instead of creating a tiny
                        # tmpfs that can break modern browser/kernel/toolchain builds.
                        if [[ -f /etc/fstab ]]; then
                                sed -i '\|^[[:space:]]*tmpfs[[:space:]]\+/var/cache/pkg/build-work[[:space:]]\+tmpfs[[:space:]]|d' /etc/fstab
                        fi
                        log "Build-work Auto: ${gib} GiB physical RAM -> disk-backed /var/cache/pkg/build-work"
                        return 0
                elif ((gib < 32)); then
                        size=8G
                elif ((gib < 48)); then
                        size=16G
                elif ((gib < 96)); then
                        size=32G
                elif ((gib < 192)); then
                        size=64G
                else
                        size=96G
                fi
        fi

        [[ "$size" =~ ^[1-9][0-9]*[GgMm]$ ]] || {
                echo "Invalid RAM build-work tmpfs size: $size" >&2
                return 1
        }

        install -d -m 0775 -o pkgmk -g pkgmk "$mountpoint"
        [[ -f /etc/fstab ]] || : > /etc/fstab
        sed -i '\|^[[:space:]]*tmpfs[[:space:]]\+/var/cache/pkg/build-work[[:space:]]\+tmpfs[[:space:]]|d' /etc/fstab
        fstab_line="tmpfs /var/cache/pkg/build-work tmpfs rw,nosuid,nodev,size=$size,mode=0775,uid=82,gid=82 0 0"
        printf '%s\n' "$fstab_line" >> /etc/fstab

        # Make the setting effective for package builds in this installer run.
        # tmpfs size= is a ceiling; RAM is consumed only as files are written.
        if mountpoint -q "$mountpoint"; then
                if pgrep -x pkgmk >/dev/null 2>&1 || pgrep -f '/usr/bin/pkgmk' >/dev/null 2>&1; then
                        echo "Refusing to resize active build-work tmpfs while pkgmk is running." >&2
                        echo "Retry after the package build completes; current contents were left untouched." >&2
                        return 1
                fi
                mount -o remount,rw,nosuid,nodev,size="$size",mode=0775,uid=82,gid=82 "$mountpoint"
        else
                mount "$mountpoint"
        fi
        chown pkgmk:pkgmk "$mountpoint"
        chmod 0775 "$mountpoint"
        log "Configured RAM-backed pkgmk workspace at $mountpoint (maximum $size)"
}

configure_pkgmk_build_settings() {
        local conf=/etc/pkgmk.conf jobs flags size kb gib
        [[ -f "$conf" ]] || return 0
        [[ "$BUILD_JOBS_VALUE" == inherited ]] || {
                jobs="$BUILD_JOBS_VALUE"; [[ "$jobs" == auto ]] && jobs="$(nproc)"
                sed -i "s|^export JOBS=.*|export JOBS=$jobs|; s|^export MAKEFLAGS=.*|export MAKEFLAGS=\"-j \$JOBS\"|" "$conf"
        }
        case "$BUILD_OPT_VALUE" in
                portable)
                        if [[ "$BUILD_TMPFS_VALUE" == yes ]]; then flags='-O2 -march=x86-64'; else flags='-O2 -march=x86-64 -pipe'; fi
                        ;;
                native)
                        if [[ "$BUILD_TMPFS_VALUE" == yes ]]; then flags='-O2 -march=native -mtune=native'; else flags='-O2 -march=native -mtune=native -pipe'; fi
                        ;;
                *) flags='' ;;
        esac
        [[ -z "$flags" ]] || sed -i "s|^export CFLAGS=.*|export CFLAGS=\"$flags\"|; s|^export CXXFLAGS=.*|export CXXFLAGS=\"\${CFLAGS}\"|" "$conf"
        if [[ "$BUILD_CCACHE_VALUE" == yes ]]; then
                grep -q '^export PATH="/usr/lib/ccache:' "$conf" || printf '\nexport PATH="/usr/lib/ccache:$PATH"\n' >> "$conf"
        elif [[ "$BUILD_CCACHE_VALUE" == no ]]; then
                sed -i '\|^export PATH="/usr/lib/ccache:|d' "$conf"
        fi
        if [[ "$BUILD_CCACHE_SIZE_VALUE" != inherited && "$BUILD_CCACHE_VALUE" != no ]] && command -v ccache >/dev/null 2>&1; then
                size="$BUILD_CCACHE_SIZE_VALUE"
                if [[ "$size" == auto ]]; then
                        if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q; then size=20G; else
                                kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo); gib=$(( (kb + 1048575) / 1048576 )); size="${gib}G"
                        fi
                fi
                install -d -m 0775 -o pkgmk -g pkgmk /var/cache/ccache
                CCACHE_DIR=/var/cache/ccache ccache --set-config="max_size=$size"
                chown -R pkgmk:pkgmk /var/cache/ccache
        fi
}

configure_pkgmk_integrity_settings() {
        local conf=/etc/pkgmk.conf md5_ignore=no signature_ignore=no footprint_ignore=no
        [[ -f "$conf" ]] || return 0

        [[ "$VERIFY_MD5_VALUE" == yes ]] || md5_ignore=yes
        [[ "$VERIFY_SIGNATURE_VALUE" == yes ]] || signature_ignore=yes
        [[ "$VERIFY_FOOTPRINT_VALUE" == yes ]] || footprint_ignore=yes

        sed -i \
                -e "s|^PKGMK_IGNORE_MD5SUM=.*|PKGMK_IGNORE_MD5SUM=\"$md5_ignore\"|" \
                -e "s|^PKGMK_IGNORE_SIGNATURE=.*|PKGMK_IGNORE_SIGNATURE=\"$signature_ignore\"|" \
                -e "s|^PKGMK_IGNORE_FOOTPRINT=.*|PKGMK_IGNORE_FOOTPRINT=\"$footprint_ignore\"|" \
                "$conf"

        if [[ "$md5_ignore" == yes || "$signature_ignore" == yes || "$footprint_ignore" == yes ]]; then
                log "WARNING: development package-integrity bypass active: MD5=$VERIFY_MD5_VALUE signatures=$VERIFY_SIGNATURE_VALUE footprints=$VERIFY_FOOTPRINT_VALUE"
        else
                log "Package integrity verification enabled: MD5/checksums, signatures, footprints"
        fi
}

configure_pkgmk_tmpfs
configure_pkgmk_build_settings
configure_pkgmk_integrity_settings
configure_zram_swap

configure_dracut_storage_modules() {
        local config_file="/etc/dracut.conf.d/20-bfs-storage.conf"
        local -a modules=()
        local separate_usr=no

        mkdir -p /etc/dracut.conf.d

        if awk '!/^[[:space:]]*#/ && $2 == "/usr" {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
                separate_usr=yes
                modules+=(usrmount)
        fi

        if [[ "$AUTO_CRYPTSETUP_VALUE" == yes ]]; then
                command -v cryptsetup >/dev/null 2>&1 || {
                        echo "Encrypted storage was detected, but cryptsetup is missing." >&2
                        return 1
                }
                modules+=(crypt)
        fi

        if [[ "$AUTO_LVM2_VALUE" == yes ]]; then
                command -v lvm >/dev/null 2>&1 ||
                command -v vgchange >/dev/null 2>&1 || {
                        echo "LVM storage was detected, but LVM tools are missing." >&2
                        return 1
                }
                modules+=(lvm)
        fi

        if [[ "$AUTO_MDADM_VALUE" == yes ]]; then
                command -v mdadm >/dev/null 2>&1 || {
                        echo "Software RAID storage was detected, but mdadm is missing." >&2
                        return 1
                }
                modules+=(mdraid)
        fi

        if ((${#modules[@]} > 0)); then
                printf '# Generated by the BFS installer from the final storage topology.\n' > "$config_file"
                printf '# Separate /usr: %s\n' "$separate_usr" >> "$config_file"
                # BFS uses host-only initramfs images. Force these topology-
                # critical modules into every future rebuild of this machine.
                printf 'force_add_dracutmodules+=" %s "\n' "${modules[*]}" >> "$config_file"
                if [[ "$AUTO_MDADM_VALUE" == yes ]]; then
                        printf 'force_drivers+=" linear raid0 raid1 raid10 raid456 "\n' >> "$config_file"
                fi
        else
                rm -f "$config_file"
        fi
}

verify_required_dracut_modules() {
        local image="$1" kernel_release="${2:-}" module="" required_line="" config_file=""
        local symbol="" state=""
        local -a required=()

        command -v lsinitrd >/dev/null 2>&1 || {
                echo "WARNING: lsinitrd is unavailable; cannot verify initramfs module list." >&2
                return 0
        }

        [[ "$AUTO_CRYPTSETUP_VALUE" == yes ]] && required+=(crypt)
        [[ "$AUTO_LVM2_VALUE" == yes ]] && required+=(lvm)
        [[ "$AUTO_MDADM_VALUE" == yes ]] && required+=(mdraid)
        if awk '!/^[[:space:]]*#/ && $2 == "/usr" {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
                required+=(usrmount)
        fi

        required_line="$(lsinitrd "$image" 2>/dev/null || true)"
        for module in "${required[@]}"; do
                if ! grep -qE "(^|[[:space:]/-])${module}([[:space:]/.-]|$)" <<<"$required_line"; then
                        echo "Initramfs verification failed: required Dracut module '$module' was not found in $image." >&2
                        return 1
                fi
        done
        if [[ "$AUTO_MDADM_VALUE" == yes ]]; then
                grep -qE '(^|[[:space:]])etc/mdadm\.conf([[:space:]]|$)' <<<"$required_line" || {
                        echo "Initramfs verification failed: /etc/mdadm.conf was not embedded in $image." >&2
                        return 1
                }
                config_file="/boot/config-${kernel_release}"
                for module in linear raid0 raid1 raid10 raid456; do
                        case "$module" in
                                linear)  symbol=MD_LINEAR ;;
                                raid0)   symbol=MD_RAID0 ;;
                                raid1)   symbol=MD_RAID1 ;;
                                raid10)  symbol=MD_RAID10 ;;
                                raid456) symbol=MD_RAID456 ;;
                        esac

                        state=""
                        if [[ -n "$kernel_release" && -r "$config_file" ]]; then
                                grep -q "^CONFIG_${symbol}=y$" "$config_file" && state=y
                                grep -q "^CONFIG_${symbol}=m$" "$config_file" && state=m
                        fi

                        case "$state" in
                                y)
                                        # Built-in support is valid and has no .ko to embed.
                                        ;;
                                m)
                                        if ! grep -qE "/${module}\.ko([.]|$)" <<<"$required_line"; then
                                                echo "Initramfs verification failed: modular md driver '$module' was not found in $image." >&2
                                                return 1
                                        fi
                                        ;;
                                *)
                                        echo "Initramfs verification failed: CONFIG_${symbol} is neither built-in nor modular in ${config_file:-the selected kernel config}." >&2
                                        return 1
                                        ;;
                        esac
                done
        fi
        return 0
}

selected_kernel_release() {
        local pkgver="" version="" suffix=""

        [[ "$KERNEL_PACKAGE_VALUE" != none ]] || return 1
        case "$KERNEL_PACKAGE_VALUE" in
                linux) suffix="BFS-Linux" ;;
                linux-lts) suffix="BFS-LTS" ;;
                *) return 1 ;;
        esac

        pkgver="$(pkginfo -i 2>/dev/null | awk -v p="$KERNEL_PACKAGE_VALUE" '$1 == p { print $2; exit }')"
        version="${pkgver%-*}"
        if [[ -n "$version" && -f "/boot/vmlinuz-${version}-${suffix}" ]]; then
                printf '%s\n' "${version}-${suffix}"
                return 0
        fi

        # Legacy/fallback path: select by semantic version, never file mtime.
        case "$KERNEL_PACKAGE_VALUE" in
                linux)
                        find /boot -maxdepth 1 -type f -name 'vmlinuz-*-BFS-Linux' -printf '%f\n' 2>/dev/null |
                                sed 's/^vmlinuz-//' | sort -V | tail -n1
                        ;;
                linux-lts)
                        find /boot -maxdepth 1 -type f -name 'vmlinuz-*-BFS-LTS' -printf '%f\n' 2>/dev/null |
                                sed 's/^vmlinuz-//' | sort -V | tail -n1
                        ;;
        esac
}

atomic_kernel_symlink() {
        local target="$1" link="$2" dir="" base="" tmp=""
        dir="${link%/*}"
        base="${link##*/}"
        tmp="$dir/.${base}.tmp.$$"
        rm -f -- "$tmp"
        ln -s "$target" "$tmp" || return 1
        mv -Tf -- "$tmp" "$link" || return 1
}

rebuild_final_initramfs() {
        local kernel_release=""
        local kernel_image=""
        local initramfs_image=""

        [[ "$KERNEL_PACKAGE_VALUE" != none ]] || return 0

        command -v dracut >/dev/null 2>&1 || {
                echo "A kernel was installed, but dracut is unavailable." >&2
                exit 1
        }

        kernel_release="$(selected_kernel_release)"
        kernel_image="/boot/vmlinuz-$kernel_release"

        [[ -n "$kernel_release" && -s "$kernel_image" ]] || {
                echo "Could not find the kernel image belonging to selected flavor: $KERNEL_PACKAGE_VALUE" >&2
                exit 1
        }

        initramfs_image="/boot/initramfs-$kernel_release.img"

        configure_dracut_storage_modules || exit 1

        log "Generating final initramfs for selected $KERNEL_PACKAGE_VALUE kernel $kernel_release"
        log "Storage stack: RAID=$AUTO_MDADM_VALUE LUKS=$AUTO_CRYPTSETUP_VALUE LVM=$AUTO_LVM2_VALUE"
        if [[ "$AUTO_MDADM_VALUE" == yes ]]; then
                dracut --force --force-drivers "linear raid0 raid1 raid10 raid456" \
                        "$initramfs_image" "$kernel_release"
        else
                dracut --force "$initramfs_image" "$kernel_release"
        fi
        verify_required_dracut_modules "$initramfs_image" "$kernel_release" || exit 1
}

configure_kernel_source_policy() {
        local kernel_release="" src=""
        [[ "$KERNEL_PACKAGE_VALUE" != none ]] || return 0

        kernel_release="$(selected_kernel_release)"
        [[ -n "$kernel_release" ]] || {
                echo "Could not resolve selected kernel release: $KERNEL_PACKAGE_VALUE" >&2
                return 1
        }
        src="linux-$kernel_release"
        [[ -d "/usr/src/$src" ]] || {
                echo "Could not find source tree /usr/src/$src for selected kernel flavor." >&2
                return 1
        }

        install -d /etc/bfsos
        printf '%s\n' "$KERNEL_PACKAGE_VALUE" > /etc/bfsos/kernel-flavor
        atomic_kernel_symlink "$src" /usr/src/linux || return 1

        if [[ "$KERNEL_PACKAGE_VALUE" == linux-lts ]]; then
                atomic_kernel_symlink "$src" /usr/src/linux-lts || return 1
                [[ -s "/boot/vmlinuz-$kernel_release" ]] || return 1
                atomic_kernel_symlink "vmlinuz-$kernel_release" /boot/vmlinuz-lts || return 1
        fi
}

touch "$STATE_DIR/system_config_complete"
configure_kernel_source_policy || exit 1
rebuild_final_initramfs

verify_kernel_installation() {
        local kernel_image=""
        local kernel_release=""
        local initramfs_image=""

        [[ "$KERNEL_PACKAGE_VALUE" != none ]] || return 0

        kernel_release="$(selected_kernel_release)"
        kernel_image="/boot/vmlinuz-$kernel_release"

        [[ -n "$kernel_release" && -s "$kernel_image" ]] || {
                echo "No installed kernel image was found for selected flavor: $KERNEL_PACKAGE_VALUE" >&2
                exit 1
        }
        initramfs_image="/boot/initramfs-$kernel_release.img"

        if [[ ! -s "$initramfs_image" ]]; then
                initramfs_image="$(
                        find /boot -maxdepth 1 -type f \
                                \( -name "initramfs*$kernel_release*.img" -o -name "initrd*$kernel_release*" \) \
                                -printf '%T@ %p\n' |
                        sort -nr |
                        head -n1 |
                        cut -d' ' -f2-
                )"
        fi

        [[ -n "$initramfs_image" && -s "$initramfs_image" ]] || {
                echo "No matching initramfs was found for $kernel_release." >&2
                exit 1
        }

        printf 'Verified kernel: %s\n' "$kernel_image"
        printf 'Verified initramfs: %s\n' "$initramfs_image"
}

verify_kernel_installation

if [[ "$INSTALL_GRUB_VALUE" == yes ]]; then
        log "Writing and configuring GRUB"

        command -v grub-install >/dev/null 2>&1 || {
                echo "grub-install is missing" >&2
                exit 1
        }

        command -v grub-mkconfig >/dev/null 2>&1 || {
                echo "grub-mkconfig is missing" >&2
                exit 1
        }

        mkdir -p /boot/grub

        if [[ "$BOOT_MODE_VALUE" == uefi ]]; then
                grub-install \
                        --target=x86_64-efi \
                        --efi-directory=/boot/efi \
                        --bootloader-id=BFS \
                        --recheck

                if [[ "$GRUB_FALLBACK_VALUE" == yes ]]; then
                        grub-install \
                                --target=x86_64-efi \
                                --efi-directory=/boot/efi \
                                --bootloader-id=BFS \
                                --removable \
                                --recheck
                fi
        else
                grub-install "$BOOT_DISK_VALUE"
        fi

        if [[ -x /usr/libexec/bfs-kernel-maintenance ]]; then
                /usr/libexec/bfs-kernel-maintenance regenerate-grub
        else
                # Fallback for recovery/minimal installs: never overwrite a known-good
                # menu until the replacement has been generated successfully.
                grub_tmp="/boot/grub/.grub.cfg.bfs.$$"
                trap 'rm -f -- "$grub_tmp"' EXIT HUP INT TERM
                grub-mkconfig -o "$grub_tmp"
                apply_md_618_compat_to_grub_config "$grub_tmp" || {
                        echo "GRUB 6.18 MD compatibility post-processing failed; previous grub.cfg was preserved." >&2
                        exit 1
                }
                [[ -s "$grub_tmp" ]] || {
                        echo "GRUB configuration generation produced an empty file." >&2
                        exit 1
                }
                if command -v grub-script-check >/dev/null 2>&1; then
                        grub-script-check "$grub_tmp" >/dev/null || {
                                echo "GRUB configuration validation failed; previous grub.cfg was preserved." >&2
                                exit 1
                        }
                fi
                mv -f "$grub_tmp" /boot/grub/grub.cfg
                trap - EXIT HUP INT TERM
        fi

        [[ -s /boot/grub/grub.cfg ]] || {
                echo "GRUB configuration was not generated." >&2
                exit 1
        }

        if [[ "$KERNEL_PACKAGE_VALUE" != none ]]; then
                grep -q '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg || {
                        echo "grub.cfg contains no Linux kernel line." >&2
                        exit 1
                }

                grep -q '^[[:space:]]*initrd[[:space:]]' /boot/grub/grub.cfg || {
                        echo "grub.cfg contains no initrd line." >&2
                        exit 1
                }
        fi

        verify_grub_storage_cmdline || {
                echo "GRUB storage command-line verification failed." >&2
                exit 1
        }

        if [[ -n "$CONSOLE_VIDEO_ARG_VALUE" ]]; then
                grep -E '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg | grep -qF "$CONSOLE_VIDEO_ARG_VALUE" || {
                        echo "GRUB verification failed: configured console video argument is missing." >&2
                        echo "Expected: $CONSOLE_VIDEO_ARG_VALUE" >&2
                        exit 1
                }
        fi

        if [[ "$BOOT_MODE_VALUE" == uefi ]]; then
                [[ -s /boot/efi/EFI/BFS/grubx64.efi ]] || {
                        echo "BFS EFI loader was not installed." >&2
                        exit 1
                }

                if [[ "$GRUB_FALLBACK_VALUE" == yes ]]; then
                        [[ -s /boot/efi/EFI/BOOT/BOOTX64.EFI ]] || {
                                echo "EFI fallback loader was not installed." >&2
                                exit 1
                        }
                fi
        fi
        touch "$STATE_DIR/bootloader_complete"
else
        log "Skipping GRUB bootloader configuration"
fi

# Archive extraction and package post-install hooks must never leave / owned by
# a non-root account. Normalize it immediately before the final postflight and
# verify the result so a broken root directory cannot be handed to the user.
chown root:root /
chmod 0755 /
root_identity="$(stat -c '%U:%G %a' / 2>/dev/null || true)"
[[ "$root_identity" == "root:root 755" ]] || {
        echo "Root filesystem ownership/mode postflight failed: ${root_identity:-unreadable}" >&2
        exit 1
}

log "Running final checks"

if [[ "$AUTO_CRYPTSETUP_VALUE" == yes ]]; then
        [[ -s /etc/crypttab ]] || {
                echo "Encrypted storage was detected, but /etc/crypttab is missing." >&2
                exit 1
        }

        command -v cryptsetup >/dev/null 2>&1 || {
                echo "Encrypted storage was detected, but cryptsetup is missing." >&2
                exit 1
        }
fi

[[ -s /etc/systemd/network/10-bfs-ethernet.link ]] ||
        { echo "Missing BFS network link file." >&2; exit 1; }

grep -qx "MACAddress=$NETWORK_MAC_VALUE" /etc/systemd/network/10-bfs-ethernet.link ||
        { echo "BFS network link file has the wrong MAC address." >&2; exit 1; }
grep -qx "Name=$NETWORK_TARGET_NAME_VALUE" /etc/systemd/network/10-bfs-ethernet.link ||
        { echo "BFS network link file has the wrong target interface name." >&2; exit 1; }

if [[ "$INSTALL_NETWORKMANAGER_VALUE" == yes ]]; then
        [[ ! -e /etc/systemd/network/20-bfs-dhcp.network ]] ||
                { echo "A systemd-networkd DHCP file exists while NetworkManager is selected." >&2; exit 1; }
else
        [[ -s /etc/systemd/network/20-bfs-dhcp.network ]] ||
                { echo "Missing BFS DHCP network file." >&2; exit 1; }
        grep -qx "Name=$NETWORK_TARGET_NAME_VALUE" /etc/systemd/network/20-bfs-dhcp.network ||
                { echo "BFS DHCP file has the wrong interface name." >&2; exit 1; }
fi

awk '
        /^[[:space:]]*($|#)/ {
                next
        }

        NF != 6 {
                printf "Invalid fstab field count on line %d: %s\n", NR, $0 > "/dev/stderr"
                failed=1
                next
        }

        $1 !~ /^(UUID=|LABEL=|PARTUUID=|PARTLABEL=|\/dev\/|tmpfs$|proc$|sysfs$|devpts$|devtmpfs$|none$|overlay$|cgroup2?$|efivarfs$|securityfs$|debugfs$|tracefs$|pstore$|configfs$|fusectl$|mqueue$|hugetlbfs$|ramfs$)/ {
                printf "Invalid fstab source on line %d: %s\n", NR, $1 > "/dev/stderr"
                failed=1
        }

        $2 != "none" && $2 !~ /^\// {
                printf "Invalid fstab target on line %d: %s\n", NR, $2 > "/dev/stderr"
                failed=1
        }

        $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ {
                printf "Invalid dump/pass fields on line %d\n", NR > "/dev/stderr"
                failed=1
        }

        END {
                exit failed
        }
' /etc/fstab ||
        { echo "Generated /etc/fstab failed syntax validation." >&2; exit 1; }

if command -v findmnt >/dev/null 2>&1; then
        findmnt --verify --verbose >/root/bfs-fstab-verify.log 2>&1 || {
                cat /root/bfs-fstab-verify.log >&2
                echo "findmnt verification of the generated fstab failed." >&2
                exit 1
        }
fi

for command in bash sh env sed grep awk find tar gzip xz make gcc g++ ld ar nm strip readelf mount umount ls cp mv rm chmod chown pkgmk pkgadd pkginfo; do
        command -v "$command" >/dev/null 2>&1 || printf 'MISSING COMMAND: %s\n' "$command" >&2
done

cat > /tmp/bfs-test.c <<'EOF_TEST'
#include <stdio.h>
int main(void) { puts("BFS compiler test passed"); return 0; }
EOF_TEST
gcc /tmp/bfs-test.c -o /tmp/bfs-test
/tmp/bfs-test
if gcc -dumpspecs | grep -q '/tmp/lfs-tools'; then
        echo "ERROR: GCC still references /tmp/lfs-tools." >&2
        exit 1
fi
rm -f /tmp/bfs-test /tmp/bfs-test.c

pkginfo -i | sort > /root/base-system.manifest
find /usr/lib/systemd/system /etc/systemd/system -type f -o -type l 2>/dev/null | sort > /root/systemd-units.manifest
ldconfig -p > /root/ldconfig.manifest

log "BFS installation finished successfully"
CHROOT

        sed -i \
                -e "s|__HOSTNAME__|$(printf '%s' "$HOSTNAME" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__TIMEZONE__|$(printf '%s' "$TIMEZONE" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__LOCALE__|$(printf '%s' "$LOCALE" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__USERNAME__|$(printf '%s' "$USERNAME" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__ROOT_PASSWORD_POLICY__|$ROOT_PASSWORD_POLICY|g" \
                -e "s|__ADDITIONAL_USERS__|$(printf '%s' "$(additional_users_text)" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__ADDITIONAL_USER_ENTRIES__|$(printf '%s' "$(additional_user_entries_text)" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__STANDARD_USER_GROUPS__|$(printf '%s' "$STANDARD_USER_GROUPS" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__BOOT_MODE__|$BOOT_MODE|g" \
                -e "s|__BOOT_DISK__|$(printf '%s' "$BOOT_DISK" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__NETWORK_IFACE__|$(printf '%s' "$NETWORK_IFACE" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__NETWORK_MAC__|$(printf '%s' "$NETWORK_MAC" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__NETWORK_TARGET_NAME__|$(printf '%s' "$NETWORK_TARGET_NAME" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__PACKAGE_LIST__|$(printf '%s' "$package_list" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__ENABLE_OPENSSH__|$ENABLE_OPENSSH|g" \
                -e "s|__INSTALL_GRUB__|$INSTALL_GRUB|g" \
                -e "s|__GRUB_FALLBACK__|$GRUB_FALLBACK|g" \
                -e "s|__KERNEL_PACKAGE__|$KERNEL_PACKAGE|g" \
                -e "s|__INSTALL_SUDO__|$INSTALL_SUDO|g" \
                -e "s|__SUDO_MODE__|$SUDO_MODE|g" \
                -e "s|__INSTALL_NETWORKMANAGER__|$INSTALL_NETWORKMANAGER|g" \
                -e "s|__INSTALL_GPM__|$INSTALL_GPM|g" \
                -e "s|__INSTALL_LYNX__|$INSTALL_LYNX|g" \
                -e "s|__INSTALL_LINKS__|$INSTALL_LINKS|g" \
                -e "s|__CONSOLE_VIDEO_ARG__|$(printf '%s' "$CONSOLE_VIDEO_ARG" | sed 's/[&|]/\&/g')|g" \
                -e "s|__SERIAL_CONSOLE__|$SERIAL_CONSOLE|g" \
                -e "s|__INSTALL_CRYPTSETUP__|$INSTALL_CRYPTSETUP|g" \
                -e "s|__AUTO_CRYPTSETUP__|$AUTO_CRYPTSETUP|g" \
                -e "s|__AUTO_LVM2__|$AUTO_LVM2|g" \
                -e "s|__AUTO_MDADM__|$AUTO_MDADM|g" \
                -e "s|__BTRFS_CONFIG_NAMES__|$(printf '%s' "${BTRFS_CONFIG_NAMES[*]}" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__BTRFS_MOUNTPOINTS__|$(printf '%s' "${BTRFS_MOUNTPOINTS[*]}" | sed 's/[&|]/\\&/g')|g" \
                -e "s|__CONSOLE_FONT_SIZE__|$CONSOLE_FONT_SIZE|g" \
                -e "s|__INSTALL_CONSOLE_FONT__|$INSTALL_CONSOLE_FONT|g" \
                -e "s|__ZRAM_SWAP__|$ZRAM_SWAP|g" \
                -e "s|__ZRAM_SIZE_SPEC__|$ZRAM_SIZE_SPEC|g" \
                -e "s|__BUILD_JOBS__|$BUILD_JOBS|g" \
                -e "s|__BUILD_OPT__|$BUILD_OPT|g" \
                -e "s|__BUILD_CCACHE__|$BUILD_CCACHE|g" \
                -e "s|__BUILD_CCACHE_SIZE__|$BUILD_CCACHE_SIZE|g" \
                -e "s|__BUILD_TMPFS__|$BUILD_TMPFS|g" \
                -e "s|__BUILD_TMPFS_SIZE__|$BUILD_TMPFS_SIZE|g" \
                -e "s|__VERIFY_MD5__|$VERIFY_MD5|g" \
                -e "s|__VERIFY_SIGNATURE__|$VERIFY_SIGNATURE|g" \
                -e "s|__VERIFY_FOOTPRINT__|$VERIFY_FOOTPRINT|g" \
                "$TARGET$CHROOT_INSTALLER"
        chmod 0700 "$TARGET$CHROOT_INSTALLER"
}

INSTALL_CHECKPOINT_DIR="/run/bfs-installer-checkpoints"

checkpoint_reset() {
        rm -rf "$INSTALL_CHECKPOINT_DIR"
        mkdir -p "$INSTALL_CHECKPOINT_DIR"
}

checkpoint_mark() {
        mkdir -p "$INSTALL_CHECKPOINT_DIR"
        : > "$INSTALL_CHECKPOINT_DIR/$1"
}

checkpoint_done() {
        [[ -f "$INSTALL_CHECKPOINT_DIR/$1" ]]
}

checkpoint_clear() {
        local state="${1:-}"
        [[ -n "$state" ]] || return 0
        rm -f "$INSTALL_CHECKPOINT_DIR/$state"
        rm -f "$TARGET/var/lib/bfs-installer/$state" 2>/dev/null || true
}

invalidate_install_checkpoints_for_destructive_formats() {
        local index="" mountpoint="" format="" invalidate_all=no invalidate_packages=no
        local invalidate_system=no invalidate_bootloader=no

        # A newly formatted root, /usr, or /var cannot safely reuse any prior
        # installation checkpoint.  Root and /usr remove the installed base;
        # /var removes the package database and persistent installer state.
        if [[ "${ROOT_FORMAT:-keep}" != keep ]]; then
                invalidate_all=yes
        fi

        for ((index=0; index<${#EXTRA_DEVICES[@]}; index++)); do
                format="${EXTRA_FORMATS[$index]:-keep}"
                mountpoint="${EXTRA_MOUNTPOINTS[$index]:-}"
                [[ "$format" != keep ]] || continue

                case "$mountpoint" in
                        /usr|/var)
                                invalidate_all=yes
                                ;;
                        /opt)
                                # BFSOS intentionally installs major package
                                # stacks under /opt (Qt/KF, Rust, etc.).
                                invalidate_packages=yes
                                invalidate_system=yes
                                invalidate_bootloader=yes
                                ;;
                        /etc)
                                invalidate_system=yes
                                invalidate_bootloader=yes
                                ;;
                esac
        done

        if [[ "${BOOT_FORMAT:-keep}" != keep || "${EFI_FORMAT:-keep}" != keep ]]; then
                invalidate_bootloader=yes
        fi

        if [[ "$invalidate_all" == yes ]]; then
                log "Destructive format selected for installed-system storage; invalidating all prior install checkpoints"
                for state in base_extracted accounts_configured packages_complete system_config_complete bootloader_complete; do
                        checkpoint_clear "$state"
                done
                INSTALLATION_ALREADY_COMPLETE=no
                return 0
        fi

        if [[ "$invalidate_packages" == yes ]]; then
                log "Destructive format selected for package-bearing /opt; invalidating package/system/bootloader checkpoints"
                checkpoint_clear packages_complete
        fi

        if [[ "$invalidate_system" == yes ]]; then
                checkpoint_clear system_config_complete
        fi

        if [[ "$invalidate_bootloader" == yes ]]; then
                log "Boot-related storage will be reformatted; invalidating bootloader checkpoint"
                checkpoint_clear bootloader_complete
        fi

        return 0
}

show_install_failure_dialog() {
        local status="$1" marker="$TARGET/run/bfs-install-failure" operation="installation/chroot configuration"
        [[ -r "$marker" ]] || marker="$TARGET/var/lib/bfs-installer/last_failure"
        local detail="" failed_url=""
        if [[ -r "$marker" ]]; then
                operation="$(sed -n 's/^operation=//p' "$marker" | head -n1)"
        fi
        if [[ -n "$LOG_FILE" && -r "$LOG_FILE" ]]; then
                detail="$(tail -n 20 "$LOG_FILE" 2>/dev/null || true)"
                case "$operation" in
                        *download*|*source*|*ports*|*package*|*upgrade*|*depinst*|*sysup*)
                                failed_url="$(grep -Eo 'https?://[^[:space:]'\"'<>]+' "$LOG_FILE" 2>/dev/null | tail -n1 || true)"
                                ;;
                esac
        fi
        local message="Installation operation failed:\n$operation\n\nExit status: $status"
        [[ -z "$failed_url" ]] || message+="\n\nLast URL seen:\n$failed_url"
        [[ -z "$LOG_FILE" ]] || message+="\n\nInstaller log:\n$LOG_FILE"
        [[ -z "$detail" ]] || message+="\n\nLast output:\n$detail"
        dialog_message "Installation operation failed" "$message"
}

run_chroot_installer() {
        local status=0
        log "Entering BFS chroot"
        set +e
        if chroot "$TARGET" /usr/bin/env -i \
                HOME=/root \
                TERM="${TERM:-linux}" \
                PATH=/usr/bin:/usr/sbin:/bin:/sbin \
                LANG=C \
                LC_ALL=C \
                /bin/bash "$CHROOT_INSTALLER"; then
                status=0
        else
                status=$?
        fi
        set -e
        if ((status != 0)); then
                show_install_failure_dialog "$status"
                return "$status"
        fi
        return 0
}


offer_package_cache_cleanup() {
        local answer=no cache_dir="$TARGET/var/cache/pkg/packages"
        ask_yes_no answer \
                "Package installation and system upgrade completed successfully. Clear /var/cache/pkg/packages/* before finishing? Keeping packages is useful for reinstalling or deploying to additional systems." \
                no || answer=no
        [[ "$answer" == yes ]] || return 0
        mkdir -p "$cache_dir"
        find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        CLEAR_PACKAGE_CACHE=yes
        log "Cleared installed-system binary package cache: /var/cache/pkg/packages/*"
}

show_installation_success_dialog() {
        local root_fs="${ROOT_FORMAT:-unknown}"
        local snapshot_status="Disabled"
        local bootloader_status="Not installed"
        local additional_count="${#ADDITIONAL_USERS[@]}"
        local installed_log="disabled"
        local message=""

        if [[ "$root_fs" == keep && -n "$ROOT_DEV" ]]; then
                root_fs="$(blkid -s TYPE -o value "$ROOT_DEV" 2>/dev/null || printf '%s' existing)"
        fi

        ((${#BTRFS_CONFIG_NAMES[@]} > 0)) && snapshot_status="Enabled"
        [[ "$INSTALL_GRUB" == yes ]] && bootloader_status="GRUB"

        if [[ "$LOG_ENABLED" == yes && -n "$LOG_FILE" ]]; then
                installed_log="/var/log/bfs/installer/$(basename "$LOG_FILE")"
        fi

        message="Congratulations!\n\nYour BFSOS installation is complete.\n\nInstallation summary\n--------------------\nHostname:          $HOSTNAME\nKernel package:    $KERNEL_PACKAGE\nBoot mode:         ${BOOT_MODE:-unknown}\nBootloader:        $bootloader_status\nRoot filesystem:   $root_fs\nBtrfs snapshots:   $snapshot_status\nPrimary user:      ${USERNAME:-none}\nAdditional users:  $additional_count\nInstaller log:     $installed_log\n\nWelcome to BFSOS!"

        if command -v dialog >/dev/null 2>&1 &&
           [[ -r /dev/tty && -w /dev/tty ]]; then
                dialog --clear \
                        --backtitle "BFSOS Installer" \
                        --title "BFSOS Installation Complete" \
                        --ok-label "Continue" \
                        --msgbox "$message" \
                        24 76 \
                        </dev/tty >/dev/tty 2>/dev/tty
        else
                clear_screen
                printf '%s\n' '============================================================'
                printf '%s\n' '            BFSOS Installation Complete'
                printf '%s\n' '============================================================'
                printf '\n%b\n\n' "$message"
                pause_screen
        fi
}

post_install_menu() {
        local choice="" status=0

        while true; do
                set +e
                themed_menu choice \
                        "BFSOS installation complete" \
                        "The installation completed successfully. You may enter the installed BFSOS system for maintenance or finish and return to the live environment." \
                        16 82 6 \
                        1 "Enter installed BFSOS system (chroot)" \
                        2 "Finish and unmount the installed system"
                status=$?
                set -e

                [[ -n "$choice" ]] || choice=2

                case "$choice" in
                        1) chroot_into_target ;;
                        2) return 0 ;;
                        *) warn "Choose a valid post-install option."; sleep 1 ;;
                esac
        done
}

offer_final_chroot() {
        show_installation_success_dialog
        post_install_menu
        # Finish returns directly to the calling shell/bootstrap. Cleanup is
        # handled by the normal EXIT trap without another completion message.
        reset_terminal_ui
}

main() {
        local extraction_status=0
        local chroot_status=0
        parse_arguments "$@"
        require_root "$@"
        force_posix_locale
        sync_system_clock
        load_installer_settings
        detect_console_video_argument
        if [[ -n "$CONSOLE_FONT_OVERRIDE" ]]; then
                CONSOLE_FONT_SIZE="$CONSOLE_FONT_OVERRIDE"
        else
                CONSOLE_FONT_SIZE="$CONSOLE_FONT_PREFERENCE"
        fi
        setup_installer_theme
        apply_console_font "$CONSOLE_FONT_SIZE"
        report_installer_interface_mode
        setup_logging
        require_commands
        checkpoint_reset
        if [[ -s "$INSTALLER_RESUME_FILE" ]]; then
                # A resume profile must be read before any clean-start unmount.
                # Otherwise a valid recovered target is destroyed before its
                # MD/LUKS/LVM/Btrfs topology can be inspected and reused.
                mkdir -p "$TARGET"
                load_resume_state_if_present
        else
                prepare_target_environment
        fi

        while true; do
                while true; do
                        INSTALL_CONFIRMED=no
                        installer_menu
                        validate_settings

                        # Review (option 10) already flows through Ready to install.
                        [[ "$INSTALL_CONFIRMED" == yes ]] && break

                        # Direct option 11 opens Ready to install; Back returns to menu.
                        if confirm_continue "Begin the BFS installation?"; then
                                break
                        fi
                done

                invalidate_install_checkpoints_for_destructive_formats
                format_selected_partitions
                # format_selected_partitions rebuilds Btrfs layout only from
                # the current format actions. On resume those actions are KEEP,
                # so reconstruct the saved subvolume plan explicitly.
                rebuild_btrfs_layout_from_saved_plan
                mount_or_reuse_target_filesystems
                restore_persistent_install_checkpoints

                if ! checkpoint_done base_extracted && target_has_valid_base_system; then
                        log "Resume: valid BFSOS base detected; restoring base_extracted checkpoint"
                        mkdir -p "$TARGET/var/lib/bfs-installer"
                        : > "$TARGET/var/lib/bfs-installer/base_extracted"
                        checkpoint_mark base_extracted
                fi

                if ! checkpoint_done base_extracted; then
                        extraction_status=0
                        extract_rootfs || extraction_status=$?
                        case "$extraction_status" in
                                0)
                                        fix_installed_bfsos_branding
                                        save_base_archive
                                        mkdir -p "$TARGET/var/lib/bfs-installer"
                                        : > "$TARGET/var/lib/bfs-installer/base_extracted"
                                        checkpoint_mark base_extracted
                                        ;;
                                2)
                                        # The user declined redundant extraction
                                        # and the existing tree passed sanity checks.
                                        mkdir -p "$TARGET/var/lib/bfs-installer"
                                        : > "$TARGET/var/lib/bfs-installer/base_extracted"
                                        checkpoint_mark base_extracted
                                        ;;
                                *)
                                        INSTALL_CONFIRMED=no
                                        save_resume_state
                                        continue
                                        ;;
                        esac
                else
                        log "Resume checkpoint: base archive already extracted; preserving installed target"
                fi

                # Persist the non-secret active storage topology before entering
                # the chroot/package phase so an abrupt process exit can be
                # recovered on the next launch.
                save_resume_state
                generate_fstab
                generate_crypttab
                mount_virtual_filesystems
                write_chroot_installer

                chroot_status=0
                if run_chroot_installer; then
                        :
                else
                        chroot_status=$?
                        SESSION_FAILURE_STATUS="$chroot_status"
                        # A caught/retryable failure must preserve the complete
                        # active dependency chain (mounts -> LVM -> LUKS -> MD).
                        # Otherwise the EXIT trap can partially dismantle a
                        # layered target before the operator can inspect/retry it.
                        KEEP_MOUNTS=yes
                        for state in packages_complete system_config_complete bootloader_complete; do
                                if [[ -f "$TARGET/var/lib/bfs-installer/$state" ]]; then
                        checkpoint_mark "$state"
                fi
                        done
                        # Keep the process and UI alive.  Avoid reformatting the
                        # already-created filesystems if the user chooses to retry
                        # after inspecting/fixing a package/download failure.
                        ROOT_FORMAT=keep
                        BOOT_FORMAT=keep
                        EFI_FORMAT=keep
                        SWAP_FORMAT=keep
                        HOME_FORMAT=keep
                        local i
                        for ((i=0; i<${#EXTRA_FORMATS[@]}; i++)); do
                                EXTRA_FORMATS[$i]=keep
                        done
                        INSTALL_CONFIRMED=no
                        save_resume_state
                        dialog_message "Installation paused" \
                                "Installed-system configuration did not complete.\n\nThe complete active target storage stack is being preserved and the full log is retained. You are being returned to the installer menu. A retry will reuse the existing target when it still matches the selected filesystem plan, preserve completed package installs, and keep existing filesystem formats rather than formatting them again. If you Quit after this failure, the installer will ask whether to leave the storage stack active for recovery or deactivate it cleanly."
                        continue
                fi

                for state in packages_complete system_config_complete bootloader_complete; do
                        if [[ -f "$TARGET/var/lib/bfs-installer/$state" ]]; then
                        checkpoint_mark "$state"
                fi
                done
                offer_package_cache_cleanup
                clear_resume_state
                INSTALLATION_ALREADY_COMPLETE=yes
                SESSION_FAILURE_STATUS=0
                # A fully successful retry clears failure-preservation mode;
                # normal final cleanup may now unwind installer-owned storage.
                KEEP_MOUNTS=no
                log "Installation complete"
                offer_final_chroot
                break
        done

        if [[ "$LOG_ENABLED" == yes ]]; then
                printf '\nLive-environment log: %s\n' "$LOG_FILE"
                close_logging "$SESSION_FAILURE_STATUS"
                copy_log_to_installed_system
        fi
        return "$SESSION_FAILURE_STATUS"
}

set +e
main "$@"
_main_status=$?
set -e
exit "$_main_status"
