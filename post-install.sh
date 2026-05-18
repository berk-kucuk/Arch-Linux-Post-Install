#!/usr/bin/env bash
# =============================================================================
# Arch Linux Post-Install Script — berkkucukk
# Root gerektiren işlemlerde sudo kullanır.
# Script NORMAL kullanıcı ile çalıştırılmalıdır.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

run "Firefox, Plasma (tam), KDE uygulamaları, base-devel, git, linux-headers kurulumu" \
    sudo pacman -S --noconfirm --needed firefox plasma-meta kde-applications-meta base-devel git linux-headers

# =============================================================================
# 2. Multilib repo (Steam ve 32-bit kütüphaneler için zorunlu)
# =============================================================================

if grep -q '^\[multilib\]' /etc/pacman.conf; then
    warning "multilib repo zaten aktif."
else
    run "multilib repo aktifleştiriliyor" \
        sudo sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/{s/^#//}' /etc/pacman.conf

    run "pacman veritabanı güncelleniyor (multilib dahil)" \
        sudo pacman -Sy --noconfirm
fi

# =============================================================================
# 3. NVIDIA ayarları
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

    if grep -q "^interface_resolution:" "$LIMINE_CONF"; then
        run "Limine çözünürlük güncelleniyor" \
            sudo sed -i \
            's/^interface_resolution:.*/interface_resolution: 2560x1440x32/' \
            "$LIMINE_CONF"
    else
        run "Limine çözünürlük ekleniyor" \
            sudo sed -i '1s|^|interface_resolution: 2560x1440x32\n|' "$LIMINE_CONF"
    fi

    if ! grep -q "^wallpaper:" "$LIMINE_CONF"; then
        run "Limine wallpaper ayarı ekleniyor" \
            sudo sed -i '1s|^|wallpaper: boot():/limine/wallpaper.png\n|' "$LIMINE_CONF"
    else
        warning "wallpaper zaten mevcut."
    fi

    if ! grep -q "^timeout:" "$LIMINE_CONF"; then
        run "Limine timeout ekleniyor" \
            sudo sed -i '1s|^|timeout: 5\n|' "$LIMINE_CONF"
    else
        run "Limine timeout güncelleniyor" \
            sudo sed -i 's/^timeout:.*/timeout: 5/' "$LIMINE_CONF"
    fi

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
WALLPAPER="${SCRIPT_DIR}/wallpaper.png"

if [[ -f "$WALLPAPER" ]]; then
    run "Limine wallpaper kopyalanıyor" \
        sudo cp "$WALLPAPER" /boot/limine/
else
    warning "wallpaper.png bulunamadı."
fi

# =============================================================================
# 4. paru kurulumu
# =============================================================================

if command -v paru &>/dev/null; then
    warning "paru zaten kurulu."
else

    PARU_DIR="${TARGET_HOME}/Downloads/paru"

    mkdir -p "${TARGET_HOME}/Downloads"

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
# 5. AUR paketleri
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
    noise-suppression-for-voice
    vmware-workstation
)

for pkg in "${AUR_PACKAGES[@]}"; do
    run "AUR paketi kuruluyor: $pkg" \
        paru -S --noconfirm --needed "$pkg"
done

# =============================================================================
# 6. Resmi repo paketleri
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
    aircrack-ng
    unzip
    unrar
    virt-manager
    filezilla
    koko
    smartmontools
    ethtool
    lm_sensors
    xsensors
    acpi
    acpid
    btrfs-assistant
    zsh
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
    openssh
    macchanger
)

run "Resmi repo paketleri kuruluyor" \
    sudo pacman -S --noconfirm --needed "${PACMAN_PACKAGES[@]}"

# =============================================================================
# 7. Plymouth yapılandırması
# =============================================================================

run "Plymouth varsayılan teması ayarlanıyor (arch-logo-symbol)" \
    sudo plymouth-set-default-theme -R arch-logo-symbol

# =============================================================================
# 8. Flatpak
# =============================================================================

run "Flathub ekleniyor" \
    sudo flatpak remote-add --if-not-exists \
    flathub https://flathub.org/repo/flathub.flatpakrepo

# =============================================================================
# 9. Reflector
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
# 10. SSH hardening
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
# 11. Kullanıcı grupları
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
# 12. Servisler
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
    # clamav-freshclam önce başlamalı — daemon imza DB olmadan çalışmaz
    clamav-freshclam
    clamav-daemon
    fail2ban
    firewalld
    vmware-networks
    vmware-usbarbitrator
    # plymouth-start boot servisi, mkinitcpio hook'u ile yönetilir; burada enable gerekmez
)

for svc in "${SERVICES[@]}"; do
    run "Servis etkinleştiriliyor: $svc" \
        sudo systemctl enable --now "$svc"
done

# =============================================================================
# 13. fail2ban
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
# 14. rkhunter
# =============================================================================

run "rkhunter update" \
    sudo rkhunter --update --nocolors

run "rkhunter property update" \
    sudo rkhunter --propupd --nocolors

# =============================================================================
# 15. firewalld
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
# 16. MAC Randomizasyon
# =============================================================================

# NetworkManager yerleşik randomizasyonu — her bağlantıdan ÖNCE devreye girer
run "NM conf.d dizini oluşturuluyor" \
    sudo mkdir -p /etc/NetworkManager/conf.d

if sudo tee /etc/NetworkManager/conf.d/mac-randomize.conf > /dev/null << 'EOF'
[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF
then
    success "NM mac-randomize.conf yazıldı."
else
    error "NM mac-randomize.conf yazılamadı."
    ERRORS+=("NM mac-randomize.conf")
fi

run "MAC log dizini oluşturuluyor" \
    sudo mkdir -p /var/log/mac-changer

if sudo tee /usr/local/bin/mac_anonymizer.py > /dev/null << 'PYEOF'
#!/usr/bin/env python3

import subprocess
import re
import sys
import time
import datetime


def log_message(message):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}")


def get_network_interfaces():
    try:
        output = subprocess.check_output(["ip", "link"], text=True)
        all_interfaces = re.findall(r'\d+: ([\w\d]+):', output)
        physical = []
        for iface in all_interfaces:
            if iface.startswith(('lo', 'tun', 'tap', 'docker', 'br-', 'veth', 'virbr')):
                continue
            if iface.startswith(('wlan', 'wl', 'eth', 'en', 'em')):
                physical.append(iface)
        return physical
    except subprocess.CalledProcessError as e:
        log_message(f"ERROR: ip link komutu başarısız: {e}")
        sys.exit(1)


def get_current_mac(interface):
    try:
        output = subprocess.check_output(["ip", "link", "show", interface], text=True)
        mac_match = re.search(r'ether ([a-f0-9:]{17})', output)
        return mac_match.group(1) if mac_match else "Unknown"
    except Exception:
        return "Unknown"


def change_mac(interface):
    try:
        old_mac = get_current_mac(interface)
        log_message(f"INFO: İşlem yapılıyor: {interface} (Eski MAC: {old_mac})")

        subprocess.run(["nmcli", "device", "disconnect", interface],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)

        subprocess.run(["ip", "link", "set", interface, "down"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["macchanger", "-r", interface],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["ip", "link", "set", interface, "up"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        time.sleep(2)
        subprocess.run(["nmcli", "device", "connect", interface],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(3)

        new_mac = get_current_mac(interface)
        log_message(f"INFO: {interface} MAC değiştirildi: {old_mac} -> {new_mac}")

    except subprocess.CalledProcessError as e:
        log_message(f"ERROR: {interface} için MAC değiştirilemedi: {e}")


def main():
    log_message("MAC anonymizer başlatıldı")
    interfaces = get_network_interfaces()
    if not interfaces:
        log_message("WARN: Hiçbir fiziksel network arayüzü bulunamadı")
        sys.exit(0)
    log_message(f"INFO: Bulunan fiziksel interface'ler: {', '.join(interfaces)}")
    for iface in interfaces:
        change_mac(iface)
    log_message("MAC anonymizer tamamlandı")


if __name__ == "__main__":
    main()
PYEOF
then
    success "mac_anonymizer.py yazıldı."
    run "mac_anonymizer.py çalıştırma izni" \
        sudo chmod +x /usr/local/bin/mac_anonymizer.py
else
    error "mac_anonymizer.py yazılamadı."
    ERRORS+=("mac_anonymizer.py")
fi

if sudo tee /etc/systemd/system/mac-changer.service > /dev/null << 'EOF'
[Unit]
Description=MAC Address Randomizer (manuel kullanım)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mac_anonymizer.py
User=root
StandardOutput=append:/var/log/mac-changer/mac-changer.log
StandardError=append:/var/log/mac-changer/mac-changer.log
EOF
then
    success "mac-changer.service yazıldı."
else
    error "mac-changer.service yazılamadı."
    ERRORS+=("mac-changer.service")
fi

if sudo tee /usr/local/bin/change-mac-now > /dev/null << 'EOF'
#!/bin/bash
echo "Manuel MAC değiştirme başlatılıyor..."
sudo /usr/local/bin/mac_anonymizer.py
echo ""
echo "Mevcut MAC adresleri:"
for iface in $(ip -o link | awk -F': ' '{print $2}' | grep -E '^(wlan|wl|eth|en|em)' | grep -vE '^(docker|br-|veth|virbr)'); do
    mac=$(ip link show "$iface" | awk '/ether/{print $2}')
    [[ -n "$mac" ]] && echo "  $iface: $mac"
done
EOF
then
    sudo chmod +x /usr/local/bin/change-mac-now
    success "change-mac-now yazıldı."
else
    error "change-mac-now yazılamadı."
    ERRORS+=("change-mac-now")
fi

if sudo tee /usr/local/bin/mac-changer-logs > /dev/null << 'EOF'
#!/bin/bash
echo "=== MAC Changer Logları ==="
if [[ -f /var/log/mac-changer/mac-changer.log ]]; then
    tail -50 /var/log/mac-changer/mac-changer.log
else
    echo "Henüz log dosyası oluşmamış."
fi
EOF
then
    sudo chmod +x /usr/local/bin/mac-changer-logs
    success "mac-changer-logs yazıldı."
else
    error "mac-changer-logs yazılamadı."
    ERRORS+=("mac-changer-logs")
fi

run "systemd daemon-reload (mac-changer)" \
    sudo systemctl daemon-reload

run "NetworkManager yeniden başlatılıyor (MAC randomizasyon devreye alınıyor)" \
    sudo systemctl restart NetworkManager

# =============================================================================
# 17. Oh My Zsh
# =============================================================================

if [[ ! -d "${TARGET_HOME}/.oh-my-zsh" ]]; then

    run "Oh My Zsh kuruluyor" \
        bash -c 'RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'

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

if [[ -f "${SCRIPT_DIR}/arch-linux.zsh-theme" ]]; then
    run "Tema kopyalanıyor" \
        cp "${SCRIPT_DIR}/arch-linux.zsh-theme" \
        "${TARGET_HOME}/.oh-my-zsh/themes/"
fi

if [[ -f "${SCRIPT_DIR}/zshrc" ]]; then
    run ".zshrc kopyalanıyor" \
        cp "${SCRIPT_DIR}/zshrc" "${TARGET_HOME}/.zshrc"
fi

run "Varsayılan shell zsh yapılıyor" \
    sudo chsh -s "$(which zsh)" "$TARGET_USER"

# =============================================================================
# 18. Snapper
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
# 19. Claude CLI
# =============================================================================

run "Claude CLI kuruluyor" \
    bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

ZSHRC="${TARGET_HOME}/.zshrc"

if [[ -f "$ZSHRC" ]] && ! grep -q 'HOME/.local/bin' "$ZSHRC"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$ZSHRC"
    success "PATH eklendi."
fi

# =============================================================================
# 20. mkinitcpio
# (Plymouth teması -R flag'i ile zaten mkinitcpio'yu tetikler,
#  burada tekrar çalıştırarak son haliyle rebuild ediliyor)
# =============================================================================

run "mkinitcpio yeniden oluşturuluyor" \
    sudo mkinitcpio -P

# =============================================================================
# 21. Son snapshot
# =============================================================================

run "Son snapper snapshot oluşturuluyor" \
    sudo snapper -c root create -d "Post-install tamamlandı"

# =============================================================================
# 22. Sonuç
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
