#!/usr/bin/env bash
# =============================================================================
# Checkmk Agent Bootstrap Installer - Unified Multi-Distro Edition
# Supports: Debian/Ubuntu (.deb) and Fedora/RHEL/Alma/Rocky (.rpm)
# Includes: smartmontools, HDSentinel CLI, & HW/SW Inventory Auto-Installer
# =============================================================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31m[ERROR] Script ini harus dijalankan sebagai root (sudo bash).\e[0m"
    exit 1
fi

# Default variables
SERVER_IP=""
GATEWAY_IP=""
SITE_ID="cmk"
AGENT_VERSION="2.5.0p14-1"
GITHUB_REPO="itlicensehq25/checkmk-cabang"
GITHUB_BRANCH="main"

# ==============================================================================
# Membersihkan Config & Cache Lama
# ==============================================================================
echo "[INFO] Membersihkan skrip local checks dan cache lama..."
rm -rf /usr/lib/check_mk_agent/local/*
rm -rf /var/lib/check_mk_agent/cache/*

# Pastikan folder target tetap ada setelah dibersihkan
mkdir -p /etc/check_mk
mkdir -p /usr/lib/check_mk_agent/local
mkdir -p /usr/lib/check_mk_agent/plugins
mkdir -p /var/lib/check_mk_agent/cache

# Help message
show_help() {
    echo "Penggunaan: sudo bash install.sh [OPSI]"
    echo ""
    echo "OPSI:"
    echo "  -s, --server IP/HOST      IP atau Hostname server Checkmk"
    echo "  -gw, --gateway IP         IP Gateway Cabang untuk Ping Monitor (Opsional, default: Auto-Detect)"
    echo "  -d, --site SITE_ID        Site ID Checkmk (Default: cmk)"
    echo "  -v, --version VERSION     Versi Agen Checkmk (Default: 2.5.0p14-1)"
    echo "  -g, --github REPO         Repositori GitHub kustom (Format: user/repo)"
    echo "  -b, --branch BRANCH       Branch GitHub (Default: main)"
    echo "  -h, --help                Tampilkan bantuan"
    echo ""
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -s|--server) SERVER_IP="$2"; shift 2 ;;
        -gw|--gateway) GATEWAY_IP="$2"; shift 2 ;;
        -d|--site) SITE_ID="$2"; shift 2 ;;
        -v|--version) AGENT_VERSION="$2"; shift 2 ;;
        -g|--github) GITHUB_REPO="$2"; shift 2 ;;
        -b|--branch) GITHUB_BRANCH="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Opsi tidak dikenal: $1"; show_help; exit 1 ;;
    esac
done

# Interactive Mode if parameters are missing
if [ -z "$SERVER_IP" ]; then
    echo -e "\e[34m=== Konfigurasi Server Checkmk ===\e[0m"
    read -p "Masukkan IP Address atau Hostname Server Checkmk: " SERVER_IP < /dev/tty

    if [ -z "$SERVER_IP" ]; then
        echo -e "\e[31m[ERROR] IP address / hostname server Checkmk wajib diisi!\e[0m"
        exit 1
    fi

    if [ -z "$GATEWAY_IP" ]; then
        read -p "Masukkan IP Gateway Cabang untuk Ping Monitor [Enter = Auto-Detect]: " TEMP_GW < /dev/tty
        [ -n "$TEMP_GW" ] && GATEWAY_IP="$TEMP_GW"
    fi

    read -p "Masukkan Site ID Checkmk [Default: $SITE_ID]: " TEMP_SITE < /dev/tty
    [ ! -z "$TEMP_SITE" ] && SITE_ID="$TEMP_SITE"

    read -p "Masukkan Versi Agen Checkmk [Default: $AGENT_VERSION]: " TEMP_VER < /dev/tty
    [ ! -z "$TEMP_VER" ] && AGENT_VERSION="$TEMP_VER"
fi

# Detect Distribution
OS_TYPE=""
PKG_MANAGER=""
if [ -f /etc/debian_version ]; then
    OS_TYPE="debian"
    PKG_MANAGER="apt-get"
elif [ -f /etc/redhat-release ] || [ -f /etc/fedora-release ]; then
    OS_TYPE="redhat"
    if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="yum"
    fi
else
    echo -e "\e[31m[ERROR] Distribusi Linux tidak didukung (Hanya mendukung Debian/Ubuntu dan Fedora/RHEL/RPM).\e[0m"
    exit 1
fi

echo -e "\e[32m[INFO] Mendeteksi Sistem Operasi: $OS_TYPE ($PKG_MANAGER)\e[0m"

# Install System Dependencies (Termasuk smartmontools, dmidecode, & pciutils untuk Inventory)
echo -e "\e[32m[INFO] Menginstal dependensi sistem, smartmontools, & tools hardware...\e[0m"
if [ "$OS_TYPE" = "debian" ]; then
    apt-get update -y
    apt-get install -y curl smartmontools memtester lm-sensors jq upower bc gzip tar dmidecode pciutils iproute2 iputils-ping
    # Pastikan paket modul kernel hwmon tambahan terpasang (nct6683, nct6775, dell_smm, dll.)
    apt-get install -y "linux-modules-extra-$(uname -r)" 2>/dev/null || apt-get install -y linux-modules-extra-generic 2>/dev/null || true
elif [ "$OS_TYPE" = "redhat" ]; then
    if [ "$PKG_MANAGER" = "dnf" ]; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y curl smartmontools memtester lm_sensors jq upower bc gzip tar dmidecode pciutils iproute iputils
    else
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl smartmontools memtester lm_sensors jq upower bc gzip tar dmidecode pciutils iproute iputils
    fi
fi

# ==============================================================================
# Install / Setup Hard Disk Sentinel (HDSentinel CLI Linux)
# ==============================================================================
echo -e "\e[32m[INFO] Memeriksa instalasi Hard Disk Sentinel (HDSentinel)...\e[0m"
if ! command -v hdsentinel >/dev/null 2>&1 && [ ! -f /usr/local/bin/hdsentinel ]; then
    ARCH=$(uname -m)
    HDS_URL=""

    case "$ARCH" in
        x86_64|amd64)
            HDS_URL="https://www.hdsentinel.com/hdslin/hdsentinel-019c-x64.gz"
            ;;
        i*86)
            HDS_URL="https://www.hdsentinel.com/hdslin/hdsentinel-019c.gz"
            ;;
        aarch64|arm64)
            HDS_URL="https://www.hdsentinel.com/hdslin/hdsentinel-armv8.gz"
            ;;
        armv7*|armhf)
            HDS_URL="https://www.hdsentinel.com/hdslin/hdsentinel-armv7.gz"
            ;;
    esac

    if [ -n "$HDS_URL" ]; then
        echo "[INFO] Mengunduh HDSentinel ($ARCH) dari official server..."
        if curl -sSfL "$HDS_URL" | gunzip -c > /usr/local/bin/hdsentinel 2>/dev/null; then
            chmod +x /usr/local/bin/hdsentinel
            echo -e "\e[32m[SUCCESS] HDSentinel berhasil dipasang di /usr/local/bin/hdsentinel\e[0m"
        else
            echo -e "\e[33m[WARNING] Gagal mengunduh HDSentinel otomatis. Script akan menggunakan smartctl murni.\e[0m"
        fi
    fi
else
    echo -e "\e[32m[INFO] HDSentinel sudah terpasang di sistem.\e[0m"
fi

# ==============================================================================
# Download & Install Checkmk Agent
# ==============================================================================
echo -e "\e[32m[INFO] Mengunduh Agen Checkmk dari Server...\e[0m"
TEMP_DIR="/tmp"

if [ "$OS_TYPE" = "debian" ]; then
    AGENT_FILE="check-mk-agent_${AGENT_VERSION}_all.deb"
    DOWNLOAD_URL="http://${SERVER_IP}/${SITE_ID}/check_mk/agents/${AGENT_FILE}"
    LOCAL_PATH="${TEMP_DIR}/${AGENT_FILE}"

    echo "Mengunduh: ${DOWNLOAD_URL}"
    if curl -sSfL -o "${LOCAL_PATH}" "${DOWNLOAD_URL}"; then
        echo -e "\e[32m[INFO] Menginstal Agen Checkmk (.deb)...\e[0m"
        dpkg -i "${LOCAL_PATH}" || apt-get install -f -y
        rm -f "${LOCAL_PATH}"
    else
        echo -e "\e[31m[ERROR] Gagal mengunduh file agen .deb. Silakan periksa IP Server, Site ID, atau versi agen.\e[0m"
        exit 1
    fi
elif [ "$OS_TYPE" = "redhat" ]; then
    AGENT_FILE="check-mk-agent-${AGENT_VERSION}.noarch.rpm"
    DOWNLOAD_URL="http://${SERVER_IP}/${SITE_ID}/check_mk/agents/${AGENT_FILE}"
    LOCAL_PATH="${TEMP_DIR}/${AGENT_FILE}"

    echo "Mengunduh: ${DOWNLOAD_URL}"
    if curl -sSfL -o "${LOCAL_PATH}" "${DOWNLOAD_URL}"; then
        echo -e "\e[32m[INFO] Menginstal Agen Checkmk (.rpm)...\e[0m"
        if [ "$PKG_MANAGER" = "dnf" ]; then
            dnf install -y "${LOCAL_PATH}"
        else
            yum install -y "${LOCAL_PATH}"
        fi
        rm -f "${LOCAL_PATH}"
    else
        echo -e "\e[31m[ERROR] Gagal mengunduh file agen .rpm. Silakan periksa IP Server, Site ID, atau versi agen.\e[0m"
        exit 1
    fi
fi

# ==============================================================================
# Download & Pasang Plugin Hardware/Software Inventory (mk_inventory.linux)
# ==============================================================================
echo -e "\e[32m[INFO] Mengunduh dan memasang plugin Hardware/Software Inventory...\e[0m"
PLUGIN_DIR="/usr/lib/check_mk_agent/plugins"
INVENTORY_FILE="${PLUGIN_DIR}/mk_inventory.linux"
mkdir -p "${PLUGIN_DIR}"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"
INVENTORY_GITHUB_URL="${GITHUB_RAW_BASE}/linux/plugins/mk_inventory.linux?v=$(date +%s)"

# Coba unduh dari repositori GitHub
if curl -sSfL "${INVENTORY_GITHUB_URL}" | tr -d '\r' > "${INVENTORY_FILE}" && [ -s "${INVENTORY_FILE}" ]; then
    chmod +x "${INVENTORY_FILE}"
    echo -e "\e[32m[SUCCESS] Plugin mk_inventory.linux berhasil dipasang dari GitHub.\e[0m"
else
    # Fallback jika unduh GitHub gagal: Ambil langsung dari Server Checkmk
    echo -e "\e[33m[WARNING] Gagal mengunduh dari GitHub, mengambil langsung dari Server Checkmk...\e[0m"
    SERVER_PLUGIN_URL="http://${SERVER_IP}/${SITE_ID}/check_mk/agents/plugins/mk_inventory.linux"
    if curl -sSfL "${SERVER_PLUGIN_URL}" | tr -d '\r' > "${INVENTORY_FILE}" && [ -s "${INVENTORY_FILE}" ]; then
        chmod +x "${INVENTORY_FILE}"
        echo -e "\e[32m[SUCCESS] Plugin mk_inventory.linux berhasil dipasang dari Server Checkmk.\e[0m"
    else
        echo -e "\e[31m[ERROR] Gagal mengunduh plugin mk_inventory.linux.\e[0m"
    fi
fi

# Bersihkan cache persist inventaris lama agar data langsung diperbarui
rm -rf /var/lib/check_mk_agent/persisted/* 2>/dev/null

# ==============================================================================
# Download Local Checks from GitHub
# ==============================================================================
LOCAL_CHECKS_DIR="/usr/lib/check_mk_agent/local"
mkdir -p "${LOCAL_CHECKS_DIR}"
chmod 755 "${LOCAL_CHECKS_DIR}"

echo -e "\e[32m[INFO] Membersihkan file cache lama agar seluruh script kustom langsung melakukan pemindaian baru...\e[0m"
rm -f /var/lib/check_mk_agent/cache/cache_*.txt

echo -e "\e[32m[INFO] Mengunduh script local checks kustom dari GitHub...\e[0m"
SCRIPTS=(
    "battery_health.sh"
    "cpu_info.sh"
    "disk_nvme_health.sh"
    "fan_health.sh"
    "info_network.sh"
    "info_OS_office.sh"
    "ram_health.sh"
    "ram_usage.sh"
    "remote_apps.sh"
    "storage_usage.sh"
)

GITHUB_RAW_URL="${GITHUB_RAW_BASE}/linux"

for script in "${SCRIPTS[@]}"; do
    SCRIPT_URL="${GITHUB_RAW_URL}/local_checks/${script}?v=$(date +%s)"
    TARGET_PATH="${LOCAL_CHECKS_DIR}/${script}"

    echo "Mengunduh: ${script}..."
    if curl -sSfL "${SCRIPT_URL}" | tr -d '\r' > "${TARGET_PATH}" && [ -s "${TARGET_PATH}" ]; then
        chmod +x "${TARGET_PATH}"
        echo -e "\e[32m[SUCCESS] Berhasil memasang ${script}\e[0m"
    else
        echo -e "\e[31m[WARNING] Gagal mengunduh ${script} dari GitHub. Silakan periksa path atau visibilitas repositori.\e[0m"
    fi
done

# ==============================================================================
# Setup Sensor Kernel Modules (Khusus Motherboard Desktop & Laptop Baru)
# ==============================================================================
echo -e "\e[32m[INFO] Memeriksa modul kernel hardware sensor (Motherboard & CPU Fan)...\e[0m"
SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
SYS_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
COMBINED_DMI="${SYS_VENDOR} ${SYS_PRODUCT}"

# Deteksi Motherboard Desktop MSI (seperti MS-7E02 / H610 / B660 / B760) -> Nuvoton NCT6687D
if echo "$COMBINED_DMI" | grep -iqE "MICRO-STAR|MSI|MS-7"; then
    echo "[INFO] Terdeteksi motherboard MSI ($SYS_PRODUCT). Mengonfigurasi modul sensor Nuvoton nct6683..."
    modprobe nct6683 force=1 2>/dev/null || modprobe nct6683 2>/dev/null || modprobe nct6775 2>/dev/null || true
    echo "options nct6683 force=1" > /etc/modprobe.d/nct6683.conf 2>/dev/null || true
    if ! grep -q "^nct6683" /etc/modules 2>/dev/null; then
        echo "nct6683" >> /etc/modules 2>/dev/null || true
    fi
fi

# Deteksi Motherboard Desktop Gigabyte (seperti B760M DS3H, B660, dll.) -> ITE IT8689E/IT87xx
if echo "$COMBINED_DMI" | grep -iqE "GIGABYTE"; then
    echo "[INFO] Terdeteksi motherboard Gigabyte ($SYS_PRODUCT). Mengonfigurasi modul sensor ITE it87..."
    modprobe it87 ignore_resource_conflict=1 2>/dev/null || modprobe it87 2>/dev/null || true
    if lsmod | grep -q "it87"; then
        echo "options it87 ignore_resource_conflict=1" > /etc/modprobe.d/it87.conf 2>/dev/null || true
        grep -q "^it87" /etc/modules 2>/dev/null || echo "it87" >> /etc/modules 2>/dev/null || true
    fi
fi

# Deteksi Dell Laptop / Desktop
if echo "$COMBINED_DMI" | grep -iqE "DELL"; then
    echo "[INFO] Terdeteksi hardware Dell. Mengaktifkan modul dell_smm_hwmon..."
    modprobe dell_smm_hwmon ignore_dmi=1 restricted=0 2>/dev/null || modprobe dell_smm_hwmon 2>/dev/null || true
fi

# ==============================================================================
# Setup IP Gateway Cabang & Cron 1 Menit untuk Ping Monitor (3 Target + Retensi 30d)
# ==============================================================================
echo -e "\e[32m[INFO] Mengonfigurasi Ping Monitor (3 Target + Retensi Log 30 Hari)...\e[0m"
GATEWAY_CONF="/etc/check_mk/gateway_ip.conf"
mkdir -p /etc/check_mk /var/log/checkmk_custom /var/lib/check_mk_agent/cache/ping_monitor 2>/dev/null

if [[ "$GATEWAY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "LOCKED:${GATEWAY_IP}" > "$GATEWAY_CONF"
    echo -e "\e[32m[SUCCESS] IP Gateway Cabang dikunci secara manual ke: ${GATEWAY_IP}\e[0m"
else
    AUTO_GW=$(ip -4 route show default 2>/dev/null | awk '/default via/ {print $3; exit}')
    if [[ "$AUTO_GW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "${AUTO_GW}" > "$GATEWAY_CONF"
        echo -e "\e[32m[SUCCESS] IP Gateway Cabang terdeteksi otomatis: ${AUTO_GW}\e[0m"
    fi
fi

if [ -f "${LOCAL_CHECKS_DIR}/info_network.sh" ]; then
    cat <<EOF > /etc/cron.d/checkmk_ping_monitor
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
* * * * * root ${LOCAL_CHECKS_DIR}/info_network.sh --collect-only >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/checkmk_ping_monitor
    nohup "${LOCAL_CHECKS_DIR}/info_network.sh" --collect-only >/dev/null 2>&1 &
    echo -e "\e[32m[SUCCESS] Cron job 1 menit Ping Monitor aktif (/etc/cron.d/checkmk_ping_monitor)\e[0m"
fi

# ==============================================================================
# Setup Auto-Update Skrip Otomatis dari GitHub (Setiap 2 Jam)
# ==============================================================================
echo -e "\e[32m[INFO] Mengonfigurasi Auto-Update skrip dari GitHub (Setiap 2 Jam)...\e[0m"
UPDATER_PATH="/usr/local/bin/update_checks.sh"
UPDATER_URL="${GITHUB_RAW_BASE}/linux/update_checks.sh?v=$(date +%s)"

if curl -sSfL "${UPDATER_URL}" | tr -d '\r' > "${UPDATER_PATH}" && [ -s "${UPDATER_PATH}" ]; then
    chmod +x "${UPDATER_PATH}"
    cat <<EOF > /etc/cron.d/checkmk_auto_update
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 */2 * * * root ${UPDATER_PATH} >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/checkmk_auto_update
    echo -e "\e[32m[SUCCESS] Cron job Auto-Update aktif setiap 2 jam (/etc/cron.d/checkmk_auto_update)\e[0m"
fi

# ==============================================================================
# Setup Asynchronous Memtester Runner
# ==============================================================================
echo -e "\e[32m[INFO] Mengonfigurasi Runner Memtester Asinkron...\e[0m"
RUNNER_PATH="/usr/local/bin/run_memtester.sh"
LOG_DIR="/var/log/checkmk_custom"
LOG_FILE="${LOG_DIR}/memtester_health.log"

mkdir -p "${LOG_DIR}"
chmod 755 "${LOG_DIR}"

cat << 'EOF' > "${RUNNER_PATH}"
#!/usr/bin/env bash
LOG_DIR="/var/log/checkmk_custom"
LOG_FILE="${LOG_DIR}/memtester_health.log"
mkdir -p "$LOG_DIR"

echo "=== MEMTESTER START: $(date) ===" > "$LOG_FILE"
FREE_RAM=$(free -m | awk '/^Mem:/{print $4}')
SAMPLE_MB=$(( FREE_RAM * 20 / 100 ))

if [ $SAMPLE_MB -lt 128 ]; then
    SAMPLE_MB=128
fi

echo "SAMPLE_SIZE: ${SAMPLE_MB}M" >> "$LOG_FILE"
echo "Menjalankan memtester dengan alokasi ${SAMPLE_MB}MB..." >> "$LOG_FILE"

if memtester ${SAMPLE_MB}M 1 >> "$LOG_FILE" 2>&1; then
    echo "STATUS: SUCCESS" >> "$LOG_FILE"
else
    echo "STATUS: FAILED" >> "$LOG_FILE"
fi

echo "=== MEMTESTER END: $(date) ===" >> "$LOG_FILE"
EOF

chmod +x "${RUNNER_PATH}"

# Setup Cron Job (Dijalankan setiap hari Sabtu pukul 11:00 AM)
CRON_JOB="0 11 * * 6 ${RUNNER_PATH} >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -Fv "${RUNNER_PATH}"; echo "${CRON_JOB}") | crontab -

echo -e "\e[32m[INFO] Memulai pengujian RAM pertama di latar belakang (background)...\e[0m"
nohup "${RUNNER_PATH}" >/dev/null 2>&1 &

echo -e "\e[32m===================================================\e[0m"
echo -e "\e[32m[SUCCESS] Instalasi Agen Checkmk & Tooling Selesai!\e[0m"
echo -e "\e[32m- smartmontools: Terpasang\e[0m"
echo -e "\e[32m- HDSentinel: Terpasang di /usr/local/bin/hdsentinel\e[0m"
echo -e "\e[32m- HW/SW Inventory: Terpasang di /usr/lib/check_mk_agent/plugins/mk_inventory.linux\e[0m"
echo -e "\e[32m- Ping Monitor (3 Target + Log 30d): Aktif di /var/log/checkmk_custom/ping_history.log\e[0m"
echo -e "\e[32m===================================================\e[0m"

SERVER_HOST=$(echo "$SERVER_IP" | sed -e 's|^https\?://||' -e 's|:[0-9]\+.*||' -e 's|/.*||')
echo -e "\nUntuk mendaftarkan sertifikat agen TLS ke server Checkmk, jalankan:"
echo -e "\e[33msudo cmk-agent-ctl register --hostname <NAMA_HOST> --server ${SERVER_HOST}:8000 --site ${SITE_ID} --user cmkadmin\e[0m"
