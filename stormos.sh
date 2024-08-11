#!/bin/bash

# Function to install selected packages
install_packages() {
  local packages=("$@")
  for package in "${packages[@]}"; do
    sudo pacman -S --noconfirm "$package"
  done
}

# Base packages
base_packages=(
  xorg
  nvidia
  nvidia-dkms
  nvidia-settings
  nvidia-utils
  intel-ucode
  xf86-video-amdgpu
  vim
  nano
  xfce4
  xfce4-goodies
  lightdm
  lightdm-gtk-greeter
)

# Optional packages
optional_packages=(
  "chromium Chromium"
  "firefox Firefox"
  "virtualbox VirtualBox"
  "virtualbox-host-dkms VirtualBox Host DKMS"
  "virtualbox-guest-iso VirtualBox Guest ISO"
  "bluez BlueZ (Bluetooth support)"
  "blueman Blueman (Bluetooth Manager)"
  "yay-bin yay-bin (AUR helper)"
  "pamac-aur pamac-aur"
  "tela-icon-theme-bin Tela Icon Theme"
  "zensu Zensu"
  "oh-my-bash-git Oh My Bash"
  "adw-gtk3 adw-gtk3"
  "stormos-grub-theme StormOS GRUB Theme"
  "stormos-conf StormOS Configuration"
  "stormos-xfce-config StormOS XFCE Configuration"
)

# Create multilib repository entry
echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | sudo tee -a /etc/pacman.conf

# Update system and install base packages
sudo pacman -Syu --noconfirm
install_packages "${base_packages[@]}"

# Dialog options
declare -a options=()
for opt in "${optional_packages[@]}"; do
  options+=($(echo "$opt" | cut -d' ' -f1) "$(echo "$opt" | cut -d' ' -f2-)" off)
done

# Show the dialog with package options
choices=$(dialog --clear --stdout --separate-output \
  --checklist "Select additional packages to install:" 20 60 15 "${options[@]}")

clear

# Add StormOS repository if StormOS packages are selected
if echo "$choices" | grep -qE "(stormos-grub-theme|stormos-conf|stormos-xfce-config)"; then
  echo -e "\n[stormos]\nSigLevel = Optional TrustAll\nServer = https://raw.githubusercontent.com/bfitzgit23/stormos/master/x86_64" | sudo tee -a /etc/pacman.conf
  sudo pacman -Syu --noconfirm
fi

# Install the selected optional packages
install_packages $choices

# Enable necessary services
sudo systemctl enable lightdm
sudo systemctl enable NetworkManager
if echo "$choices" | grep -q "bluez"; then
  sudo systemctl enable bluetooth
fi

# Set up GRUB with StormOS theme if selected
if echo "$choices" | grep -q "stormos-grub-theme"; then
  sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "Installation and setup complete. Reboot to apply changes."
