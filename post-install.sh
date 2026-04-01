#!/usr/bin/env bash
# =============================================================================
# Arch Linux Post-Install Script
# =============================================================================

set -euo pipefail

# --- Renkler ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Yardımcı fonksiyonlar ---
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[UYARI]${NC} $1"; }
error()   { echo -e "${RED}[HATA]${NC} $1"; }

FAILED_SERVICES=()
add_failed_service() { FAILED_SERVICES+=("$1"); warning "Servis başlatılamadı: $1"; }

# --- Root kontrolü ---
if [[ $EUID -eq 0 ]]; then
    error "Bu scripti root olarak çalıştırma. sudo gereken yerlerde zaten kullanılıyor."
    exit 1
fi

# sudo ile çalıştırılınca SUDO_USER gerçek kullanıcıyı verir
CURRENT_USER="${SUDO_USER:-$USER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Kullanıcı: $CURRENT_USER"

# =============================================================================
# 1. SİSTEM GÜNCELLEMESİ & TEMEL PAKETLER
# =============================================================================
info "Sistem güncelleniyor ve temel paketler kuruluyor..."
sudo pacman -Syu --noconfirm firefox plasma-meta base-devel git

# =============================================================================
# 2. KERNEL DEĞİŞİKLİĞİ: LTS → STANDART + NVIDIA
# =============================================================================
info "LTS kernel kaldırılıyor, standart kernel ve nvidia kuruluyor..."
sudo pacman -Rns --noconfirm linux-lts linux-lts-headers nvidia-open-dkms 2>/dev/null || \
    warning "LTS kernel zaten kaldırılmış olabilir, devam ediliyor."
sudo pacman -S --noconfirm linux linux-headers nvidia-open nvidia-utils

# =============================================================================
# 3. NVIDIA AYARLARI
# =============================================================================
info "Nvidia modprobe ayarları yapılıyor..."
sudo tee /etc/modprobe.d/nvidia.conf > /dev/null << 'EOF'
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_EnableGpuFirmware=1
EOF

info "Nvidia modülleri mkinitcpio.conf'a ekleniyor..."
sudo sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf

info "UKI kernel cmdline'a nvidia parametreleri ekleniyor..."
if [[ -f /etc/kernel/cmdline ]]; then
    if ! grep -q "nvidia-drm.modeset=1" /etc/kernel/cmdline; then
        sudo sed -i 's/$/ nvidia-drm.modeset=1 nvidia-drm.fbdev=1/' /etc/kernel/cmdline
        success "nvidia-drm parametreleri cmdline'a eklendi."
    else
        warning "nvidia-drm parametreleri zaten mevcut, atlanıyor."
    fi
else
    warning "/etc/kernel/cmdline bulunamadı."
fi

# =============================================================================
# 4. NVIDIA PACMAN HOOK — kernel/nvidia senkronizasyonu
# =============================================================================
info "Nvidia pacman hook'u oluşturuluyor..."
sudo mkdir -p /etc/pacman.d/hooks
sudo tee /etc/pacman.d/hooks/nvidia.hook > /dev/null << 'EOF'
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia-open
Target=linux
Target=linux-headers

[Action]
Description=Nvidia modülleri için mkinitcpio yeniden oluşturuluyor...
When=PostTransaction
Depends=mkinitcpio
Exec=/usr/bin/mkinitcpio -P
EOF
success "Nvidia hook oluşturuldu. Kernel/nvidia güncellemelerinde mkinitcpio otomatik çalışacak."

info "mkinitcpio yeniden oluşturuluyor..."
sudo mkinitcpio -P

# =============================================================================
# 5. PARU (AUR HELPER) KURULUMU
# =============================================================================
if ! command -v paru &>/dev/null; then
    info "Paru kuruluyor..."
    mkdir -p ~/Downloads
    cd ~/Downloads/
    git clone https://aur.archlinux.org/paru.git
    cd paru
    makepkg -si --noconfirm
    cd ~
    success "Paru kuruldu."
else
    warning "Paru zaten kurulu, atlanıyor."
fi

# =============================================================================
# 6. AUR PAKETLERİ (1. GRUP)
# =============================================================================
info "AUR paketleri kuruluyor (1. grup)..."
paru -S --noconfirm \
    mullvad-browser-bin \
    session-desktop-bin \
    tutanota-desktop-bin \
    spotify \
    joplin-bin \
    cursor-bin \
    onlyoffice-bin \
    lmstudio-bin

# =============================================================================
# 7. PACMAN PAKETLERİ
# =============================================================================
info "Pacman paketleri kuruluyor..."
sudo pacman -Syu --noconfirm \
    torbrowser-launcher \
    onionshare \
    mullvad-vpn \
    discord \
    bitwarden \
    steam \
    clamav \
    clamtk

sudo pacman -S --noconfirm \
    wget curl sof-firmware flatpak \
    bash-completion btop wireshark-qt \
    fuse2 isoimagewriter \
    power-profiles-daemon \
    partitionmanager distrobox \
    tor fail2ban lynis \
    python-pip python-setuptools \
    openvpn kdeconnect \
    ttf-nerd-fonts-symbols \
    network-manager-applet \
    wireguard-tools systemd-resolvconf \
    aircrack-ng unzip unrar \
    virt-manager filezilla koko \
    acpi_call smartmontools ethtool \
    lm_sensors xsensors acpi acpid \
    btrfs-assistant zsh \
    noise-suppression-for-voice \
    apparmor audit rkhunter \
    reflector downgrade

# =============================================================================
# 8. REFLECTOR — En hızlı mirror listesi
# =============================================================================
info "Reflector ayarlanıyor..."
sudo tee /etc/xdg/reflector/reflector.conf > /dev/null << 'EOF'
--save /etc/pacman.d/mirrorlist
--protocol https
--country Turkey,Germany,Netherlands
--latest 10
--sort rate
EOF
sudo systemctl enable --now reflector.timer
success "Reflector timer etkinleştirildi."

# =============================================================================
# 9. VİRTUALİZASYON
# =============================================================================
info "Virtualizasyon paketleri kuruluyor..."
sudo pacman -S --noconfirm \
    virt-manager qemu-full vde2 dnsmasq \
    dmidecode libvirt edk2-ovmf openbsd-netcat

sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$CURRENT_USER"
sudo usermod -aG kvm "$CURRENT_USER"
success "Kullanıcı libvirt ve kvm grubuna eklendi."

# =============================================================================
# 10. AUR PAKETLERİ (2. GRUP)
# =============================================================================
info "AUR paketleri kuruluyor (2. grup)..."
paru -S --noconfirm \
    proton-vpn-gtk-app \
    visual-studio-code-bin \
    upscayl-bin \
    monero-gui \
    winboat-bin

# =============================================================================
# 11. SERVİSLER
# =============================================================================
info "Servisler etkinleştiriliyor..."
sudo systemctl enable --now acpid
sudo systemctl enable --now power-profiles-daemon
sudo systemctl enable --now tor
sudo systemctl enable --now sshd
sudo systemctl enable --now fstrim.timer
sudo systemctl enable --now systemd-resolved.service
sudo systemctl enable --now smartd              2>/dev/null || add_failed_service "smartd"
sudo systemctl enable --now apparmor            2>/dev/null || add_failed_service "apparmor"
sudo systemctl enable --now auditd              2>/dev/null || add_failed_service "auditd"
sudo systemctl enable --now clamav-daemon       2>/dev/null || add_failed_service "clamav-daemon"
sudo systemctl enable --now clamav-freshclam    2>/dev/null || add_failed_service "clamav-freshclam"
sudo systemctl enable --now mullvad-daemon.service 2>/dev/null || add_failed_service "mullvad-daemon"

# =============================================================================
# 12. FIREWALLD
# =============================================================================
info "Firewalld kuruluyor ve ayarlanıyor..."
sudo pacman -S --noconfirm firewalld
sudo systemctl enable --now firewalld

# KDE Connect (TCP+UDP 1714-1764)
sudo firewall-cmd --permanent --add-service=kdeconnect

# SSH
sudo firewall-cmd --permanent --add-service=ssh

sudo firewall-cmd --reload
success "Firewalld ayarlandı: KDE Connect ve SSH portları açıldı."

# =============================================================================
# 13. GRUP ÜYELİKLERİ
# =============================================================================
info "Grup üyelikleri ayarlanıyor..."
sudo usermod -aG video "$CURRENT_USER"
sudo usermod -aG wireshark "$CURRENT_USER"
sudo usermod -aG input "$CURRENT_USER"
success "Gruplar: video, wireshark, input eklendi."

# =============================================================================
# 14. /boot İZİNLERİ
# =============================================================================
info "/boot izinleri düzeltiliyor..."
sudo chmod 700 /boot
success "/boot chmod 700 yapıldı."

# =============================================================================
# 14. ZSH & OH MY ZSH
# =============================================================================
info "Oh My Zsh kuruluyor..."
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    success "Oh My Zsh kuruldu."
else
    warning "Oh My Zsh zaten kurulu, atlanıyor."
fi

info "Zsh pluginleri kuruluyor..."
if [[ ! -d "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" ]]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
        "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
fi

if [[ ! -d "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ]]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions \
        "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
fi

info "Tema ve zshrc kopyalanıyor..."
cp "$SCRIPT_DIR/arch-linux.zsh-theme" "$HOME/.oh-my-zsh/themes/"
cp "$SCRIPT_DIR/.zshrc" "$HOME/.zshrc"

info "Zsh default shell olarak ayarlanıyor..."
chsh -s "$(which zsh)" "$CURRENT_USER"
success "Default shell zsh olarak ayarlandı."

# =============================================================================
# 15. SNAPPER
# =============================================================================
info "Snapper yapılandırılıyor..."
if ! sudo snapper list-configs 2>/dev/null | grep -q "^root"; then
    sudo snapper -c root create-config /
    success "Snapper root config oluşturuldu."
else
    warning "Snapper root config zaten mevcut."
fi
sudo snapper -c root create -d "Post-install tamamlandı"
success "Snapper snapshot alındı."

# =============================================================================
# ÖZET
# =============================================================================
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  Kurulum tamamlandı!${NC}"
echo -e "${GREEN}=============================================${NC}"

if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Başlatılamayan servisler:${NC}"
    for svc in "${FAILED_SERVICES[@]}"; do
        echo -e "  ${RED}✗${NC} $svc"
    done
else
    echo -e "${GREEN}Tüm servisler başarıyla etkinleştirildi.${NC}"
fi

echo ""
echo -e "${YELLOW}► Grup değişiklikleri için yeniden oturum aç.${NC}"
echo -e "${YELLOW}► Nvidia ve kernel değişiklikleri için sistemi yeniden başlat.${NC}"
echo -e "${YELLOW}► Bir şey bozulursa: sudo downgrade nvidia-open nvidia-utils${NC}"
