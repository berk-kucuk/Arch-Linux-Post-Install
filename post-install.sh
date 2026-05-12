#!/usr/bin/env bash
# =============================================================================
# Arch Linux Post-Install Script
# RTX 5060 (Blackwell) + KDE Plasma + Wayland
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
    error "Bu scripti doğrudan root olarak çalıştırma. Gerekli yerlerde sudo kullanılıyor."
    exit 1
fi

CURRENT_USER="${SUDO_USER:-$USER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Kullanıcı: $CURRENT_USER"
info "Script dizini: $SCRIPT_DIR"

# --- Gerekli dosyaları kontrol et ---
for f in "$SCRIPT_DIR/arch-linux.zsh-theme" "$SCRIPT_DIR/.zshrc"; do
    if [[ ! -f "$f" ]]; then
        error "Gerekli dosya bulunamadı: $f"
        exit 1
    fi
done
success "Gerekli dosyalar mevcut."

# =============================================================================
# 1. SİSTEM GÜNCELLEMESİ & TEMEL PAKETLER
# =============================================================================
info "Sistem güncelleniyor ve temel paketler kuruluyor..."
sudo pacman -Syu --noconfirm firefox plasma-meta base-devel git

# =============================================================================
# 2. KERNEL: LTS → STANDART (open kernel zaten archinstall ile kuruldu)
# =============================================================================
info "LTS kernel kaldırılıyor (varsa)..."
sudo pacman -Rns --noconfirm linux-lts linux-lts-headers 2>/dev/null || \
    warning "LTS kernel zaten kaldırılmış, devam ediliyor."

info "Standart kernel ve başlıklar güncelleniyor..."
sudo pacman -S --noconfirm --needed linux linux-headers

# =============================================================================
# 3. NVIDIA KURULUMU (RTX 5060 / Blackwell — sadece nvidia-open desteklenir)
# =============================================================================
info "Mevcut nvidia-open-dkms kaldırılıyor (varsa)..."
sudo pacman -Rns --noconfirm nvidia-open-dkms 2>/dev/null || true

info "nvidia-open ve nvidia-utils kuruluyor..."
sudo pacman -S --noconfirm --needed nvidia-open nvidia-utils lib32-nvidia-utils

# --- 3a. Modprobe ayarları ---
info "Nvidia modprobe ayarları yapılıyor..."
sudo tee /etc/modprobe.d/nvidia.conf > /dev/null << 'EOF'
# RTX 5060 (Blackwell) için gerekli ayarlar
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_EnableGpuFirmware=1

# Nouveau'yu kapat (çakışmayı önler)
blacklist nouveau
options nouveau modeset=0
EOF

# --- 3b. mkinitcpio modülleri ---
info "Nvidia modülleri mkinitcpio.conf'a ekleniyor..."
sudo sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf

# --- 3c. UKI / kernel cmdline ---
info "Kernel cmdline nvidia parametreleri kontrol ediliyor..."
if [[ -f /etc/kernel/cmdline ]]; then
    if ! grep -q "nvidia-drm.modeset=1" /etc/kernel/cmdline; then
        sudo sed -i 's/$/ nvidia-drm.modeset=1 nvidia-drm.fbdev=1/' /etc/kernel/cmdline
        success "nvidia-drm parametreleri cmdline'a eklendi."
    else
        warning "nvidia-drm parametreleri zaten mevcut, atlanıyor."
    fi
else
    warning "/etc/kernel/cmdline bulunamadı (UKI kullanılmıyor olabilir, GRUB kullanıcıları için normal)."
fi

# --- 3d. SDDM + Wayland siyah ekran koruması (RTX 5060 bilinen sorun) ---
# Kaynak: Arch/Manjaro forumlarında RTX 5060 + SDDM/Wayland siyah ekran raporları
info "SDDM Wayland ayarları yapılıyor (RTX 5060 uyumluluk)..."
sudo mkdir -p /etc/sddm.conf.d
sudo tee /etc/sddm.conf.d/nvidia-wayland.conf > /dev/null << 'EOF'
[General]
# RTX 5060 (Blackwell) ile SDDM/Wayland siyah ekran sorununu önler
# Sorun çözülürse bu dosya silinebilir
DisplayServer=x11
EOF
warning "SDDM geçici olarak X11 modunda başlatılıyor (RTX 5060 SDDM/Wayland uyumluluk sorunu)."
warning "Nvidia driver güncellemelerini takip et: https://bbs.archlinux.org/viewtopic.php?id=307259"

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
success "Nvidia hook oluşturuldu."

info "mkinitcpio yeniden oluşturuluyor..."
sudo mkinitcpio -P

# =============================================================================
# 5. PARU (AUR HELPER) KURULUMU
# =============================================================================
if ! command -v paru &>/dev/null; then
    info "Paru kuruluyor..."
    PARU_BUILD_DIR="/home/$CURRENT_USER/Downloads/paru-build"
    sudo -u "$CURRENT_USER" mkdir -p "$PARU_BUILD_DIR"
    sudo -u "$CURRENT_USER" git clone https://aur.archlinux.org/paru.git "$PARU_BUILD_DIR"
    sudo -u "$CURRENT_USER" bash -c "cd '$PARU_BUILD_DIR' && makepkg -si --noconfirm"
    rm -rf "$PARU_BUILD_DIR"
    success "Paru kuruldu."
else
    warning "Paru zaten kurulu, atlanıyor."
fi

# =============================================================================
# 6. SNAPPER (btrfs snapshot — kurulum öncesinde kuralım)
# =============================================================================
info "Snapper ve snap-pac kuruluyor..."
sudo pacman -S --noconfirm --needed snapper snap-pac

# =============================================================================
# 7. AUR PAKETLERİ (1. GRUP)
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
# 8. PACMAN PAKETLERİ
# =============================================================================
info "Pacman paketleri kuruluyor..."
sudo pacman -S --noconfirm --needed \
    torbrowser-launcher \
    onionshare \
    mullvad-vpn \
    discord \
    bitwarden \
    steam \
    clamav \
    clamtk

sudo pacman -S --noconfirm --needed \
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
    reflector downgrade \
    firewalld

# =============================================================================
# 9. FLATPAK — Flathub eklentisi
# =============================================================================
info "Flatpak Flathub deposu ekleniyor..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
success "Flathub eklendi."

# =============================================================================
# 10. REFLECTOR — En hızlı mirror listesi
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
# 11. VİRTUALİZASYON
# =============================================================================
info "Virtualizasyon paketleri kuruluyor..."
sudo pacman -S --noconfirm --needed \
    virt-manager qemu-full vde2 dnsmasq \
    dmidecode libvirt edk2-ovmf openbsd-netcat

sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$CURRENT_USER"
sudo usermod -aG kvm "$CURRENT_USER"
success "Kullanıcı libvirt ve kvm grubuna eklendi."

# =============================================================================
# 12. AUR PAKETLERİ (2. GRUP)
# =============================================================================
info "AUR paketleri kuruluyor (2. grup)..."
paru -S --noconfirm \
    proton-vpn-gtk-app \
    visual-studio-code-bin \
    upscayl-bin \
    monero-gui \
    winboat-bin

# =============================================================================
# 13. SERVİSLER
# =============================================================================
info "Servisler etkinleştiriliyor..."

# Kritik servisler — hata çıkarsa dur
sudo systemctl enable --now acpid
sudo systemctl enable --now power-profiles-daemon
sudo systemctl enable --now tor
sudo systemctl enable --now sshd
sudo systemctl enable --now fstrim.timer
sudo systemctl enable --now systemd-resolved.service
sudo systemctl enable --now libvirtd

# Opsiyonel servisler — hata çıkarsa kaydet, devam et
{ sudo systemctl enable --now smartd;             } 2>/dev/null || add_failed_service "smartd"
{ sudo systemctl enable --now apparmor;           } 2>/dev/null || add_failed_service "apparmor"
{ sudo systemctl enable --now auditd;             } 2>/dev/null || add_failed_service "auditd"
{ sudo systemctl enable --now clamav-daemon;      } 2>/dev/null || add_failed_service "clamav-daemon"
{ sudo systemctl enable --now clamav-freshclam;   } 2>/dev/null || add_failed_service "clamav-freshclam"
{ sudo systemctl enable --now mullvad-daemon;     } 2>/dev/null || add_failed_service "mullvad-daemon"
{ sudo systemctl enable --now fail2ban;           } 2>/dev/null || add_failed_service "fail2ban"

# =============================================================================
# 14. FAIL2BAN TEMEL YAPILANDIRMA (SSH koruması)
# =============================================================================
info "Fail2ban SSH koruması yapılandırılıyor..."
sudo tee /etc/fail2ban/jail.d/sshd.conf > /dev/null << 'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF
success "Fail2ban SSH kuralı oluşturuldu."

# =============================================================================
# 15. RKHUNTER VERİTABANI GÜNCELLEMESİ
# =============================================================================
info "Rkhunter veritabanı güncelleniyor..."
sudo rkhunter --update --nocolors 2>/dev/null || warning "rkhunter --update başarısız oldu (ağ sorunu olabilir)."
sudo rkhunter --propupd --nocolors 2>/dev/null || warning "rkhunter --propupd başarısız oldu."
success "Rkhunter veritabanı hazırlandı."

# =============================================================================
# 16. FIREWALLD
# =============================================================================
info "Firewalld ayarlanıyor..."
sudo systemctl enable --now firewalld

# KDE Connect (TCP+UDP 1714-1764)
sudo firewall-cmd --permanent --add-service=kdeconnect
# SSH
sudo firewall-cmd --permanent --add-service=ssh
# Mullvad VPN (WireGuard)
sudo firewall-cmd --permanent --add-service=wireguard 2>/dev/null || true

sudo firewall-cmd --reload
success "Firewalld ayarlandı: KDE Connect, SSH ve WireGuard portları açıldı."

# =============================================================================
# 17. GRUP ÜYELİKLERİ
# =============================================================================
info "Grup üyelikleri ayarlanıyor..."
sudo usermod -aG video      "$CURRENT_USER"
sudo usermod -aG wireshark  "$CURRENT_USER"
sudo usermod -aG input      "$CURRENT_USER"
success "Gruplar: video, wireshark, input eklendi."

# =============================================================================
# 18. /boot İZİNLERİ
# =============================================================================
info "/boot izinleri düzeltiliyor..."
sudo chmod 700 /boot
success "/boot chmod 700 yapıldı."

# =============================================================================
# 19. ZSH & OH MY ZSH
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
    success "zsh-syntax-highlighting kuruldu."
fi

if [[ ! -d "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ]]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions \
        "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
    success "zsh-autosuggestions kuruldu."
fi

info "Tema ve zshrc kopyalanıyor..."
cp "$SCRIPT_DIR/arch-linux.zsh-theme" "$HOME/.oh-my-zsh/themes/"
cp "$SCRIPT_DIR/.zshrc" "$HOME/.zshrc"
success "Zsh tema ve yapılandırma kopyalandı."

info "Zsh default shell olarak ayarlanıyor..."
chsh -s "$(which zsh)" "$CURRENT_USER"
success "Default shell zsh olarak ayarlandı."

# =============================================================================
# 20. CLAMAV VERİTABANI GÜNCELLEMESİ
# =============================================================================
info "ClamAV veritabanı güncelleniyor..."
sudo freshclam 2>/dev/null || warning "freshclam başarısız oldu, servis başladıktan sonra otomatik güncellenecek."

# =============================================================================
# 21. SNAPPER YAPILANDIRMASI
# =============================================================================
info "Snapper yapılandırılıyor..."
if ! sudo snapper list-configs 2>/dev/null | grep -q "^root"; then
    sudo snapper -c root create-config /
    success "Snapper root config oluşturuldu."
else
    warning "Snapper root config zaten mevcut."
fi

# Otomatik snapshot zamanlaması
sudo systemctl enable --now snapper-timeline.timer
sudo systemctl enable --now snapper-cleanup.timer
success "Snapper timer'ları etkinleştirildi."

sudo snapper -c root create -d "Post-install tamamlandı"
success "İlk snapper snapshot alındı."

# =============================================================================
# ÖZET
# =============================================================================
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  Kurulum tamamlandı!${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""

if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Başlatılamayan servisler (reboot sonrası tekrar dene):${NC}"
    for svc in "${FAILED_SERVICES[@]}"; do
        echo -e "  ${RED}✗${NC} $svc"
    done
else
    echo -e "${GREEN}✓ Tüm servisler başarıyla etkinleştirildi.${NC}"
fi

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  ÖNEMLİ NOTLAR${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}► Grup değişiklikleri için yeniden oturum aç.${NC}"
echo -e "${YELLOW}► Nvidia ve kernel değişiklikleri için sistemi yeniden başlat.${NC}"
echo -e "${YELLOW}► RTX 5060: SDDM geçici olarak X11 modunda. Siyah ekran çözülünce:${NC}"
echo -e "    sudo rm /etc/sddm.conf.d/nvidia-wayland.conf${NC}"
echo -e "${YELLOW}► Bir şey bozulursa: sudo downgrade nvidia-open nvidia-utils${NC}"
echo -e "${YELLOW}► Lynis güvenlik taraması için: sudo lynis audit system${NC}"
echo -e "${YELLOW}► Nvidia driver durumu için: nvidia-smi${NC}"
echo ""
