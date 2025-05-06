#!/usr/bin/env bash

set -eo pipefail
trap 'echo -e "${RED}❌ An error occurred on line $LINENO. Exiting.${RESET}"' ERR

# Colors
RED="\e[31m"
GREEN="\e[32m"
BLUE="\e[34m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

# Banner Functions
print_title() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "╔════════════════════════════════════════════════════╗"
  echo "║                XFCE DESKTOP INSTALLER              ║"
  echo "╚════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

print_section() {
  local msg="$1"
  echo -e "\n${CYAN}=== $msg ===${RESET}"
}

# Pre-checks
check_vanilla_arch() {
  if ! grep -q '^ID=arch' /etc/os-release || ! [ -f /etc/arch-release ]; then
    echo -e "${RED}This script is for vanilla Arch Linux only. Exiting.${RESET}"
    exit 1
  fi
}

check_existing_de() {
  local known_de_packages=(
    plasma-desktop gnome-shell xfce4-session hyprland cosmic-session-git
    budgie-desktop cinnamon pantheon-session deepin kde-applications lxqt-session
    sway i3-wm openbox awesome enlightenment mate-session gdm sddm lightdm
  )

  for pkg in "${known_de_packages[@]}"; do
    if pacman -Q "$pkg" &>/dev/null; then
      echo -e "${RED}DE Detected: ${CYAN}${pkg}${RESET} is already installed!"
      echo -e "${YELLOW}This script is for fresh/clean installs only. Exiting.${RESET}"
      exit 1
    fi
  done
}

check_vm_environment() {
  local virt
  virt=$(systemd-detect-virt 2>/dev/null)
  virt=${virt:-none}

  if [[ "$virt" != "none" ]]; then
    echo -e "\n${YELLOW}🖥️ VM detected — installing guest tools...${RESET}"
    sleep 6
    case "$virt" in
      oracle)
        install_packages virtualbox-guest-utils
        ;;
      kvm)
        install_packages qemu-guest-agent spice-vdagent
        ;;
      vmware)
        install_packages xf86-video-vmware open-vm-tools xf86-input-vmmouse
        sudo systemctl enable vmtoolsd.service
        ;;
      microsoft)
        echo -e "${YELLOW}⚠️  WSL detected — GUI support is limited.${RESET}"
        ;;
      *)
        echo -e "${YELLOW}⚠️ Unknown VM type: ${virt}${RESET}"
        ;;
    esac
  fi
}

install_packages() {
  local failed_packages=()
  local spinner=("|" "/" "-" "\\")

  for pkg in "$@"; do
    local i=0
    echo -ne "${CYAN}[ ] Installing ${pkg}...${RESET}"

    (
      while true; do
        echo -ne "\r${CYAN}[${spinner[i]}] Installing ${pkg}...${RESET}"
        i=$(( (i + 1 ) % 4 ))
        sleep 0.1
      done
    ) &
    SPIN_PID=$!

    if sudo pacman -S --noconfirm --needed "$pkg" &> /tmp/xfce-install.log; then
      RESULT=true
    else
      RESULT=false
    fi

    kill "$SPIN_PID" &>/dev/null
    wait "$SPIN_PID" 2>/dev/null || true
    echo -ne "\r\033[2K"

    if $RESULT; then
      echo -e "${GREEN}[✔] Installed ${pkg}${RESET}"
    else
      echo -e "${RED}[✘] Failed ${pkg}${RESET}"
      failed_packages+=("$pkg")
    fi
  done

  if [[ ${#failed_packages[@]} -gt 0 ]]; then
    echo -e "${RED}The following packages failed to install:${RESET}"
    for pkg in "${failed_packages[@]}"; do
      echo -e "${RED}- $pkg${RESET}"
    done
  fi
}

add_stormos_repo() {
  if ! grep -q "\[stormos\]" /etc/pacman.conf; then
    echo -e "\nAdding The StormOS Repository..."
    sleep 3
    echo -e '\n[stormos]\nSigLevel = Never\nServer = https://bfitzgit23.github.io/$repo/$arch' | sudo tee -a /etc/pacman.conf
    sudo sed -i '/^\s*#\s*\[multilib\]/,/^$/ s/^#//' /etc/pacman.conf
    echo "StormOS Repository added!"
    sleep 3
  else
    echo "StormOS Repository already added."
    sleep 2
  fi
}

add_chaotic_aur() {
  if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
    echo -e "\nAdding The Chaotic-AUR Repository..."
    sleep 3
    sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
    sudo pacman-key --lsign-key 3056513887B78AEB
    sudo pacman -U --noconfirm 'https://repos.xerolinux.xyz/aur/chaotic-keyring.pkg.tar.zst'
    sudo pacman -U --noconfirm 'https://repos.xerolinux.xyz/aur/chaotic-mirrorlist.pkg.tar.zst'
    echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' | sudo tee -a /etc/pacman.conf
    echo "Chaotic-AUR Repository added!"
    sleep 3
  else
    echo "Chaotic-AUR Repository already added."
    sleep 2
  fi
}

update_pacman_conf() {
  echo -e "\nUpdating Pacman Options..."
  sudo sed -i '/^# Misc options/,/ParallelDownloads = [0-9]*/c\# Misc options\nColor\nILoveCandy\nCheckSpace\n#DisableSandbox\nDownloadUser = alpm\nDisableDownloadTimeout\nParallelDownloads = 10' /etc/pacman.conf
  echo "Updated /etc/pacman.conf under # Misc options"
}

install_xfce() {
  check_vm_environment
  clear && print_section "XFCE Desktop"
  echo
  install_packages linux-headers xfce4 chromium mousepad parole ristretto thunar-archive-plugin thunar-media-tags-plugin xfburn xfce4-artwork xfce4-docklike-plugin xfce4-battery-plugin xfce4-clipman-plugin xfce4-cpufreq-plugin xfce4-cpugraph-plugin xfce4-dict xfce4-diskperf-plugin xfce4-eyes-plugin xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-mailwatch-plugin xfce4-mount-plugin xfce4-mpc-plugin xfce4-netload-plugin xfce4-notes-plugin xfce4-notifyd xfce4-power-manager xfce4-indicator-plugin xfce4-places-plugin xfce4-pulseaudio-plugin xfce4-screensaver xfce4-screenshooter xfce4-sensors-plugin xfce4-smartbookmark-plugin xfce4-systemload-plugin xfce4-taskmanager xfce4-time-out-plugin xfce4-timer-plugin xfce4-verve-plugin xfce4-wavelan-plugin xfce4-weather-plugin xfce4-whiskermenu-plugin xfce4-xkb-plugin lightdm lightdm-gtk-greeter adw-gtk-theme-git power-profiles-daemon compiz-easy-patch
  sudo systemctl enable lightdm.service power-profiles-daemon.service &>/dev/null || echo "Warning: lightdm.service not found."
}

post_install() {
  clear && print_section "Apps & Services..."
  echo
  install_packages bluez bluez-utils bluez-plugins bluez-hid2hci bluez-cups bluez-libs bluez-tools kvantum-qt5 pamac-aur-git meld timeshift mpv gnome-disk-utility nano git eza downgrade ntp most wget dnsutils logrotate gtk-update-icon-cache dex bash-completion bat bat-extras ttf-fira-code otf-libertinus tex-gyre-fonts ttf-hack-nerd ttf-ubuntu-font-family awesome-terminal-fonts ttf-jetbrains-mono-nerd adobe-source-sans-pro-fonts gtk-engines gtk-engine-murrine gnome-themes-extra ntfs-3g gvfs mtpfs udiskie udisks2 ldmtool gvfs-afc gvfs-mtp gvfs-nfs gvfs-smb gvfs-gphoto2 libgsf tumbler freetype2 libopenraw ffmpegthumbnailer python-pip python-cffi python-numpy python-docopt python-pyaudio python-pyparted python-pygments python-websockets ocs-url xmlstarlet yt-dlp wavpack unarchiver gnustep-base parallel gnome-keyring ark vi duf gcc yad zip xdo lzop nmon tree vala htop lshw cmake cblas expac fuse3 lhasa meson unace unrar zip unzip 7zip rhash sshfs vnstat nodejs cronie hwinfo arandr assimp netpbm wmctrl grsync libmtp polkit sysprof semver zenity gparted hddtemp mlocate jsoncpp fuseiso gettext node-gyp intltool graphviz pkgstats inetutils s3fs-fuse playerctl oniguruma cifs-utils lsb-release dbus-python laptop-detect perl-xml-parser appmenu-gtk-module fastfetch flatpak pacman-bintrans pacseek openssh
  sudo systemctl enable sshd bluetooth &>/dev/null

  clear && print_section "GRUB Bootloader..."
  echo
  if pacman -Q grub &>/dev/null && [[ -d /boot/grub ]]; then
    echo -e "${GREEN}✔ GRUB installed and appears active. Setting up bootloader...${RESET}"
    install_packages os-prober update-grub || true
    sudo sed -i 's/#\s*GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || true
    sudo os-prober && sudo update-grub || true
  else
    echo -e "${YELLOW}⚠️ GRUB not active. Checking for orphan GRUB tools...${RESET}"
    for pkg in grub os-prober update-grub; do
      if pacman -Q "$pkg" &>/dev/null; then
        echo -e "${YELLOW}🧹 Removing unused package: ${pkg}${RESET}"
        sudo pacman -Rdd --noconfirm "$pkg" &>/dev/null || true
      fi
    done
  fi
}

main() {
  print_title
  check_vanilla_arch
  check_existing_de
  add_stormos_repo
  add_chaotic_aur
  update_pacman_conf

  # 🔄 Update pacman DB after modifying pacman.conf
  sudo pacman -Syy

  install_xfce
  post_install

  echo -e "\n${GREEN}✔ Done! You may now reboot into your desktop environment.${RESET}"
  echo
  read -rp "Press Enter to reboot now or Ctrl+C to cancel..."
  sudo reboot
}

run() {
  trap 'echo -e "${RED}An error occurred. Exiting...${RESET}"; exit 1' ERR
  main "$@"
}

run "$@"
