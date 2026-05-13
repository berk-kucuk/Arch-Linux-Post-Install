#!/usr/bin/env bash
# =============================================================================
# Arch Linux Post-Install Script — berkkucukk
# Root gerektiren işlemlerde sudo kullanır.
# Script NORMAL kullanıcı ile çalıştırılmalıdır.
# =============================================================================

set -euo pipefail

# ---------- Renkli çıktı yardımcıları -----------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

# ---------- Hata takip listesi ------------------------------------------------
ERRORS=()

# FIX #11 — trap artık ERRORS dizisine de ekliyor
trap 'error "Beklenmedik hata: satır $LINENO — \"$BASH_COMMAND\""; ERRORS+=("Beklenmedik hata: satır $LINENO")' ERR

run() {
    local desc="$1"
    shift

    info "$desc"

    if "$@"; then
        success "$desc"
    else
        error "$desc BAŞARISIZ"
        ERRORS+=("$desc")
    fi
}

# =============================================================================
# 0. Kullanıcı & temel kontroller
# =============================================================================

if [[ $EUID -eq 0 ]]; then
    error "Bu scripti root olarak DEĞİL normal kullanıcı ile çalıştırın."
    echo ""
    echo "Örnek:"
    echo "bash $0"
    exit 1
fi

if ! command -v sudo &>/dev/null; then
    error "sudo kurulu değil."
    exit 1
fi

if ! sudo -v; then
    error "sudo yetkisi alınamadı."
    exit 1
fi

TARGET_USER="$(whoami)"
TARGET_HOME="$HOME"

info "Hedef kullanıcı: ${TARGET_USER}"
info "Home dizini: ${TARGET_HOME}"

keep_sudo_alive() {
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" || exit
    done 2>/dev/null &
}

keep_sudo_alive

# =============================================================================
# 1. Sistem güncellemesi + temel paketler
# =============================================================================

run "Sistem güncellemesi" \
    sudo pacman -Syu --noconfirm

run "Firefox, Plasma, base-devel, git kurulumu" \
    sudo pacman -S --noconfirm --needed firefox plasma-meta base-devel git

# =============================================================================
# 2. NVIDIA ayarları
# =============================================================================

info "NVIDIA modprobe.d ayarları yazılıyor..."

if sudo tee /etc/modprobe.d/nvidia.conf > /dev/null << 'EOF'
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_EnableGpuFirmware=1

blacklist nouveau
options nouveau modeset=0
EOF
then
    success "nvidia.conf yazıldı."
else
    error "nvidia.conf yazılamadı!"
    ERRORS+=("nvidia.conf")
fi

# mkinitcpio
MKINIT="/etc/mkinitcpio.conf"

if [[ -f "$MKINIT" ]]; then
    run "mkinitcpio.conf yedekleniyor" \
        sudo cp "$MKINIT" "${MKINIT}.bak"

    # Plymouth — udev'den hemen sonra ekleniyor
    if ! grep -q 'plymouth' "$MKINIT"; then
        run "mkinitcpio HOOKS içine plymouth ekleniyor" \
            sudo sed -i 's/\(HOOKS=([^)]*udev\)/\1 plymouth/' "$MKINIT"
    else
        warning "plymouth hook zaten mevcut."
    fi

    # FIX #6 — MODULES tamamen üzerine yazmak yerine nvidia modülleri ekleniyor
    if ! grep -q 'nvidia' "$MKINIT"; then
        run "mkinitcpio MODULES güncelleniyor (nvidia ekleniyor)" \
            sudo sed -i \
            's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
            "$MKINIT"
    else
        warning "MODULES içinde nvidia modülleri zaten mevcut."
    fi

else
    warning "$MKINIT bulunamadı."
fi

# limine.conf
LIMINE_CONF="/boot/limine/limine.conf"

if [[ -f "$LIMINE_CONF" ]]; then

    run "limine.conf yedekleniyor" \
        sudo cp "$LIMINE_CONF" "${LIMINE_CONF}.bak"

    run "Limine çözünürlük ayarlanıyor" \
        sudo sed -i \
        's/^interface_resolution:.*/interface_resolution: 2560x1440/' \
        "$LIMINE_CONF"

    # NVIDIA parametreleri
    if ! grep -q "nvidia-drm.modeset=1" "$LIMINE_CONF"; then
        run "Limine NVIDIA parametreleri ekleniyor" \
            sudo sed -i \
            '/^ *cmdline:/ s/$/ nvidia-drm.modeset=1 nvidia-drm.fbdev=1/' \
            "$LIMINE_CONF"
    else
        warning "NVIDIA parametreleri zaten mevcut."
    fi

    # FIX #3 — AppArmor kernel parametresi ekleniyor
    if ! grep -q "apparmor=1" "$LIMINE_CONF"; then
        run "Limine AppArmor parametresi ekleniyor" \
            sudo sed -i \
            '/^ *cmdline:/ s/$/ lsm=landlock,lockdown,yama,integrity,apparmor,bpf apparmor=1 security=apparmor/' \
            "$LIMINE_CONF"
    else
        warning "AppArmor parametresi zaten mevcut."
    fi

    # Plymouth — quiet splash
    if ! grep -q "quiet splash" "$LIMINE_CONF"; then
        run "Limine Plymouth (quiet splash) parametresi ekleniyor" \
            sudo sed -i \
            '/^ *cmdline:/ s/$/ quiet splash/' \
            "$LIMINE_CONF"
    else
        warning "quiet splash zaten mevcut."
    fi

else
    warning "$LIMINE_CONF bulunamadı."
fi

# Wallpaper
WALLPAPER="./wallpaper.png"

if [[ -f "$WALLPAPER" ]]; then
    run "Limine wallpaper kopyalanıyor" \
        sudo cp "$WALLPAPER" /boot/limine/
else
    warning "wallpaper.png bulunamadı."
fi

# =============================================================================
# 3. paru kurulumu
# =============================================================================

if command -v paru &>/dev/null; then
    warning "paru zaten kurulu."
else

    PARU_DIR="${TARGET_HOME}/Downloads/paru"

    if [[ ! -d "$PARU_DIR" ]]; then
        run "paru repo klonlanıyor" \
            git clone https://aur.archlinux.org/paru.git "$PARU_DIR"
    fi

    run "paru derleniyor" \
        bash -c "cd '${PARU_DIR}' && makepkg -si --noconfirm"

    # FIX #9 — Kurulum sonrası kaynak dizin temizleniyor
    run "paru kaynak dizini temizleniyor" \
        rm -rf "$PARU_DIR"
fi

# =============================================================================
# 4. AUR paketleri
# =============================================================================

AUR_PACKAGES=(
    mullvad-browser-bin
    session-desktop-bin
    tutanota-desktop-bin
    spotify
    joplin-bin
    cursor-bin
    onlyoffice-bin
    lmstudio-bin
    brave-bin
    proton-vpn-gtk-app
    visual-studio-code-bin
    upscayl-bin
    monero-gui
    # FIX #4 — opensnitch AUR'da, pacman'da değil
    opensnitch
    # FIX #5 — winboat-bin AUR'da mevcut değil, kaldırıldı
    # Plymouth teması
    plymouth-theme-arch-logo-symbol
)

for pkg in "${AUR_PACKAGES[@]}"; do
    run "AUR paketi kuruluyor: $pkg" \
        paru -S --noconfirm --needed "$pkg"
done

# =============================================================================
# 5. Resmi repo paketleri
# =============================================================================

PACMAN_PACKAGES=(
    torbrowser-launcher
    onionshare
    mullvad-vpn
    discord
    bitwarden
    steam
    clamav
    clamtk
    wget
    curl
    sof-firmware
    flatpak
    bash-completion
    btop
    wireshark-qt
    fuse2
    isoimagewriter
    power-profiles-daemon
    partitionmanager
    distrobox
    tor
    fail2ban
    lynis
    fastfetch
    python-pip
    python-setuptools
    openvpn
    kdeconnect
    ttf-nerd-fonts-symbols
    network-manager-applet
    wireguard-tools
    systemd-resolvconf
    aircrack-ng
    unzip
    unrar
    virt-manager
    filezilla
    koko
    acpi_call
    smartmontools
    ethtool
    lm_sensors
    xsensors
    acpi
    acpid
    btrfs-assistant
    zsh
    noise-suppression-for-voice
    apparmor
    audit
    rkhunter
    reflector
    dolphin
    kate
    # FIX #4 — opensnitch AUR'a taşındı, buradan kaldırıldı
    qemu-full
    vde2
    dnsmasq
    dmidecode
    libvirt
    edk2-ovmf
    openbsd-netcat
    snapper
    firewalld
    plymouth
)

run "Resmi repo paketleri kuruluyor" \
    sudo pacman -S --noconfirm --needed "${PACMAN_PACKAGES[@]}"

# =============================================================================
# 6. Plymouth yapılandırması
# =============================================================================

run "Plymouth varsayılan teması ayarlanıyor (arch-logo-symbol)" \
    sudo plymouth-set-default-theme -R arch-logo-symbol

# =============================================================================
# 7. Flatpak
# =============================================================================

run "Flathub ekleniyor" \
    sudo flatpak remote-add --if-not-exists \
    flathub https://flathub.org/repo/flathub.flatpakrepo

# =============================================================================
# 8. Reflector
# =============================================================================

if sudo tee /etc/xdg/reflector/reflector.conf > /dev/null << 'EOF'
--save /etc/pacman.d/mirrorlist
--protocol https
--country Turkey,Germany,Netherlands
--latest 10
--sort rate
EOF
then
    success "reflector.conf yazıldı."
else
    error "reflector.conf yazılamadı."
    ERRORS+=("reflector.conf")
fi

run "reflector.timer etkinleştiriliyor" \
    sudo systemctl enable --now reflector.timer

# =============================================================================
# 9. SSH hardening
# FIX #8 — sshd enable ediliyordu ama hiçbir hardening yapılmıyordu
# =============================================================================

if sudo tee /etc/ssh/sshd_config.d/hardening.conf > /dev/null << 'EOF'
PermitRootLogin no
PasswordAuthentication no
X11Forwarding no
MaxAuthTries 3
AllowAgentForwarding no
AllowTcpForwarding no
EOF
then
    success "SSH hardening yazıldı."
else
    error "SSH hardening yazılamadı."
    ERRORS+=("SSH hardening")
fi

# =============================================================================
# 10. Kullanıcı grupları
# =============================================================================

GROUPS_TO_ADD=(
    libvirt
    kvm
    video
    wireshark
    input
)

for grp in "${GROUPS_TO_ADD[@]}"; do
    run "Kullanıcı ${grp} grubuna ekleniyor" \
        sudo usermod -aG "$grp" "$TARGET_USER"
done

# =============================================================================
# 11. Servisler
# =============================================================================

SERVICES=(
    acpid
    power-profiles-daemon
    tor
    sshd
    fstrim.timer
    systemd-resolved.service
    libvirtd
    opensnitchd
    smartd
    apparmor
    auditd
    # FIX #7 — clamav-freshclam servisi zaten güncellemeyi yönetir,
    #           manual freshclam (adım 14 eski) kaldırıldı; çakışma önlendi
    clamav-daemon
    clamav-freshclam
    fail2ban
    firewalld
    plymouth-start
)

for svc in "${SERVICES[@]}"; do
    run "Servis etkinleştiriliyor: $svc" \
        sudo systemctl enable --now "$svc"
done

# =============================================================================
# 12. fail2ban
# FIX #1 — Arch'ta /var/log/auth.log yok; systemd journal backend kullanılıyor
# =============================================================================

if sudo tee /etc/fail2ban/jail.d/sshd.conf > /dev/null << 'EOF'
[sshd]
enabled      = true
port         = ssh
filter       = sshd
backend      = systemd
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
maxretry     = 5
bantime      = 3600
findtime     = 600
EOF
then
    success "fail2ban sshd.conf yazıldı."
else
    error "fail2ban sshd.conf yazılamadı."
    ERRORS+=("fail2ban sshd.conf")
fi

run "fail2ban yeniden başlatılıyor" \
    sudo systemctl restart fail2ban

# =============================================================================
# 13. rkhunter
# =============================================================================

run "rkhunter update" \
    sudo rkhunter --update --nocolors

run "rkhunter property update" \
    sudo rkhunter --propupd --nocolors

# =============================================================================
# 14. firewalld
# =============================================================================

run "kdeconnect firewall kuralı" \
    sudo firewall-cmd --permanent --add-service=kdeconnect

run "ssh firewall kuralı" \
    sudo firewall-cmd --permanent --add-service=ssh

if sudo firewall-cmd --permanent --add-service=wireguard 2>/dev/null; then
    success "wireguard servisi eklendi."
else
    warning "wireguard servisi eklenemedi."
fi

run "firewalld reload" \
    sudo firewall-cmd --reload

# =============================================================================
# 15. Oh My Zsh
# =============================================================================

if [[ ! -d "${TARGET_HOME}/.oh-my-zsh" ]]; then

    run "Oh My Zsh kuruluyor" \
        sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        "" --unattended

else
    warning "Oh My Zsh zaten kurulu."
fi

ZSH_PLUGIN_DIR="${TARGET_HOME}/.oh-my-zsh/custom/plugins"

if [[ ! -d "${ZSH_PLUGIN_DIR}/zsh-syntax-highlighting" ]]; then
    run "zsh-syntax-highlighting kuruluyor" \
        git clone \
        https://github.com/zsh-users/zsh-syntax-highlighting.git \
        "${ZSH_PLUGIN_DIR}/zsh-syntax-highlighting"
fi

if [[ ! -d "${ZSH_PLUGIN_DIR}/zsh-autosuggestions" ]]; then
    run "zsh-autosuggestions kuruluyor" \
        git clone \
        https://github.com/zsh-users/zsh-autosuggestions \
        "${ZSH_PLUGIN_DIR}/zsh-autosuggestions"
fi

if [[ -f "./arch-linux.zsh-theme" ]]; then
    run "Tema kopyalanıyor" \
        cp ./arch-linux.zsh-theme \
        "${TARGET_HOME}/.oh-my-zsh/themes/"
fi

if [[ -f "./.zshrc" ]]; then
    run ".zshrc kopyalanıyor" \
        cp ./.zshrc "${TARGET_HOME}/.zshrc"
fi

run "Varsayılan shell zsh yapılıyor" \
    sudo chsh -s "$(which zsh)" "$TARGET_USER"

# =============================================================================
# 16. Snapper
# =============================================================================

if ! sudo snapper list-configs 2>/dev/null | grep -q "^root"; then

    run "Snapper root config oluşturuluyor" \
        sudo snapper -c root create-config /

else
    warning "Snapper root config zaten mevcut."
fi

# FIX #10 — Varsayılan limitsiz snapshot birikimini önlemek için limitler ayarlanıyor
run "Snapper snapshot limitleri ayarlanıyor" \
    sudo snapper -c root set-config \
    "TIMELINE_LIMIT_HOURLY=5"  \
    "TIMELINE_LIMIT_DAILY=7"   \
    "TIMELINE_LIMIT_WEEKLY=2"  \
    "TIMELINE_LIMIT_MONTHLY=1" \
    "TIMELINE_LIMIT_YEARLY=0"

run "snapper timeline timer" \
    sudo systemctl enable --now snapper-timeline.timer

run "snapper cleanup timer" \
    sudo systemctl enable --now snapper-cleanup.timer

# =============================================================================
# 17. Claude CLI
# =============================================================================

run "Claude CLI kuruluyor" \
    bash -c "$(curl -fsSL https://claude.ai/install.sh)"

ZSHRC="${TARGET_HOME}/.zshrc"

if [[ -f "$ZSHRC" ]] && ! grep -q 'HOME/.local/bin' "$ZSHRC"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$ZSHRC"
    success "PATH eklendi."
fi

# =============================================================================
# 18. mkinitcpio
# (Plymouth teması -R flag'i ile zaten mkinitcpio'yu tetikler,
#  burada tekrar çalıştırarak son haliyle rebuild ediliyor)
# =============================================================================

run "mkinitcpio yeniden oluşturuluyor" \
    sudo mkinitcpio -P

# =============================================================================
# 19. Son snapshot
# =============================================================================

run "Son snapper snapshot oluşturuluyor" \
    sudo snapper -c root create -d "Post-install tamamlandı"

# =============================================================================
# 20. Sonuç
# =============================================================================

echo ""
echo "======================================================================"

if [[ ${#ERRORS[@]} -eq 0 ]]; then
    success "TÜM ADIMLAR BAŞARIYLA TAMAMLANDI."
else
    error "${#ERRORS[@]} ADIM HATA VERDİ:"

    for i in "${!ERRORS[@]}"; do
        echo -e "  ${RED}[$((i+1))]${NC} ${ERRORS[$i]}"
    done
fi

echo "======================================================================"
echo ""
warning "Bazı grup değişiklikleri için logout/login gerekebilir."
warning "NVIDIA modülleri ve AppArmor için reboot gereklidir."
warning "SSH key-based auth kurulmadıysa PasswordAuthentication'ı açık bırak!"
