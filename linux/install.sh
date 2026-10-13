#!/usr/bin/env bash
# =============================================================================
# Checkmk Agent Bootstrap Installer - Unified Multi-Distro Edition
# Supports: Debian/Ubuntu (.deb) and Fedora/RHEL/Alma/Rocky (.rpm)
# =============================================================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31m[ERROR] Script ini harus dijalankan sebagai root (sudo bash).\e[0m"
    exit 1
fi

# Default variables
SERVER_IP=""
SITE_ID="cmk"
AGENT_VERSION="2.5.0p14-1"
GITHUB_REPO="itlicensehq25/checkmk-cabang"
GITHUB_BRANCH="main"

# Help message
show_help() {
    echo "Penggunaan: sudo bash install.sh [OPSI]"
    echo ""
    echo "OPSI:"
    echo "  -s, --server IP/HOST      IP atau Hostname server Checkmk"
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
    # Menggunakan < /dev/tty untuk mengatasi bug stdin pada curl | bash
    read -p "Masukkan IP Address atau Hostname Server Checkmk: " SERVER_IP < /dev/tty
    
    if [ -z "$SERVER_IP" ]; then
        echo -e "\e[31m[ERROR] IP address / hostname server Checkmk wajib diisi!\e[0m"
        exit 1
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

# Install Dependencies
echo -e "\e[32m[INFO] Menginstal dependensi sistem...\e[0m"
if [ "$OS_TYPE" = "debian" ]; then
    apt-get update -y
    apt-get install -y curl smartmontools memtester lm-sensors jq upower bc
elif [ "$OS_TYPE" = "redhat" ]; then
    # Di RHEL/CentOS/Fedora, epel-release mungkin diperlukan untuk memtester
    if [ "$PKG_MANAGER" = "dnf" ]; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y curl smartmontools memtester lm_sensors jq upower bc
    else
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl smartmontools memtester lm_sensors jq upower bc
    fi
fi

# Download & Install Checkmk Agent
echo -e "\e[32m[INFO] Mengunduh Agen Checkmk dari Server...\e[0m"
TEMP_DIR="/tmp"

if [ "$OS_TYPE" = "debian" ]; then
    AGENT_FILE="check-mk-agent_${AGENT_VERSION}_all.deb"
    DOWNLOAD_URL="http://${SERVER_IP}/${SITE_ID}/check_mk/agents/${AGENT_FILE}"
    LOCAL_PATH="${TEMP_DIR}/${AGENT_FILE}"
    
    echo "Mengunduh: ${DOWNLOAD_URL}"
    # Menggunakan -f untuk menggagalkan download jika 404
    if curl -sSfL -o "${LOCAL_PATH}" "${DOWNLOAD_URL}"; then
        echo -e "\e[32m[INFO] Menginstal Agen Checkmk (.deb)...\e[0m"
        dpkg -i "${LOCAL_PATH}" || apt-get install -f -y
        rm -f "${LOCAL_PATH}"
    else
        echo -e "\e[31m[ERROR] Gagal mengunduh file agen .deb. Silakan periksa kembali IP Server, Site ID, atau versi agen.\e[0m"
        exit 1
    fi
elif [ "$OS_TYPE" = "redhat" ]; then
    # Format RPM biasanya: check-mk-agent-2.5.0p9-1.noarch.rpm
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
        echo -e "\e[31m[ERROR] Gagal mengunduh file agen .rpm. Silakan periksa kembali IP Server, Site ID, atau versi agen.\e[0m"
        exit 1
    fi
fi

# Ensure Local Checks Directory Exists
LOCAL_CHECKS_DIR="/usr/lib/check_mk_agent/local"
mkdir -p "${LOCAL_CHECKS_DIR}"
chmod 755 "${LOCAL_CHECKS_DIR}"

# Membersihkan cache lama agar script baru langsung dieksekusi segar
echo -e "\e[32m[INFO] Membersihkan file cache lama agar seluruh script kustom langsung melakukan pemindaian baru...\e[0m"
rm -f /var/lib/check_mk_agent/cache/cache_*.txt

# Download Local Checks from GitHub
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

GITHUB_RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/linux"

for script in "${SCRIPTS[@]}"; do
    SCRIPT_URL="${GITHUB_RAW_URL}/local_checks/${script}"
    TARGET_PATH="${LOCAL_CHECKS_DIR}/${script}"
    
    echo "Mengunduh: ${script}..."
    # Gunakan -f agar tidak mengunduh halaman 404
    if curl -sSfL -o "${TARGET_PATH}" "${SCRIPT_URL}"; then
        chmod +x "${TARGET_PATH}"
        echo -e "\e[32m[SUCCESS] Berhasil memasang ${script}\e[0m"
    else
        echo -e "\e[31m[WARNING] Gagal mengunduh ${script} dari GitHub. Silakan periksa path atau visibilitas repositori.\e[0m"
    fi
done

# Download custom agent plugins from GitHub
# Checkmk built-in plugins remain managed in the agent installation directory.
PLUGINS_DIR="/usr/lib/check_mk_agent/plugins"
mkdir -p "${PLUGINS_DIR}"
chmod 755 "${PLUGINS_DIR}"

PLUGINS=(
    "mk_inventory.linux"
)

echo -e "\e[32m[INFO] Mengunduh plugin tambahan ke ${PLUGINS_DIR}...\e[0m"
for plugin in "${PLUGINS[@]}"; do
    PLUGIN_URL="${GITHUB_RAW_URL}/plugins/${plugin}"
    TARGET_PATH="${PLUGINS_DIR}/${plugin}"
    TEMP_PATH="${TARGET_PATH}.tmp"

    echo "Mengunduh plugin: ${plugin}..."
    if curl -sSfL -o "${TEMP_PATH}" "${PLUGIN_URL}"; then
        mv -f "${TEMP_PATH}" "${TARGET_PATH}"
        chmod 755 "${TARGET_PATH}"
        echo -e "\e[32m[SUCCESS] Berhasil memasang plugin ${plugin}\e[0m"
    else
        rm -f "${TEMP_PATH}"
        echo -e "\e[31m[WARNING] Gagal mengunduh plugin ${plugin} dari ${PLUGIN_URL}.\e[0m"
    fi
done

# Setup Asynchronous Memtester Runner
echo -e "\e[32m[INFO] Mengonfigurasi Runner Memtester Asinkron...\e[0m"
RUNNER_PATH="/usr/local/bin/run_memtester.sh"
LOG_DIR="/var/log/checkmk_custom"
LOG_FILE="${LOG_DIR}/memtester_health.log"

mkdir -p "${LOG_DIR}"
chmod 755 "${LOG_DIR}"

# Tulis script runner
cat << 'EOF' > "${RUNNER_PATH}"
#!/usr/bin/env bash
# Script Runner Memtester Asinkron - Menghitung 20% Free RAM & Menjalankan Tes

LOG_DIR="/var/log/checkmk_custom"
LOG_FILE="${LOG_DIR}/memtester_health.log"
mkdir -p "$LOG_DIR"

echo "=== MEMTESTER START: $(date) ===" > "$LOG_FILE"

# Hitung 20% dari Free RAM saat ini
FREE_RAM=$(free -m | awk '/^Mem:/{print $4}')
SAMPLE_MB=$(( FREE_RAM * 20 / 100 ))

# Batas minimum alokasi adalah 128MB agar memtester berjalan dengan valid
if [ $SAMPLE_MB -lt 128 ]; then
    SAMPLE_MB=128
fi

# Catat ukuran sampel ke log agar bisa dibaca ram_health.sh secara dinamis
echo "SAMPLE_SIZE: ${SAMPLE_MB}M" >> "$LOG_FILE"
echo "Menjalankan memtester dengan alokasi ${SAMPLE_MB}MB..." >> "$LOG_FILE"

# Jalankan memtester 1 siklus saja untuk diagnosa kesehatan RAM
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

# Jalankan pengujian pertama kali di background agar langsung ada data log awal
echo -e "\e[32m[INFO] Memulai pengujian RAM pertama di latar belakang (background)...\e[0m"
nohup "${RUNNER_PATH}" >/dev/null 2>&1 &

echo -e "\e[32m===================================================\e[0m"
echo -e "\e[32m[SUCCESS] Instalasi Agen Checkmk Selesai!\e[0m"
echo -e "\e[32mClient telah terdaftar di Cron Scheduler (Setiap Sabtu pukul 11:00 AM).\e[0m"
echo -e "\e[32mPastikan untuk mendaftarkan host ini di server Checkmk Anda.\e[0m"
echo -e "\e[32m===================================================\e[0m"

