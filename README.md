# Checkmk Client Monitoring Agent Script Suite

Proyek ini bertujuan untuk membangun sistem monitoring aset perusahaan menggunakan **Checkmk** secara terpusat, otomatis, dan seragam. Semua berkas konfigurasi, skrip instalasi (*installer*), dan skrip pemantauan (*local checks*) dikelola secara terpusat melalui repositori GitHub resmi: **`ITHQEJBNT`**.

---

## 📂 Struktur Repositori GitHub (`itlicensehq25/checkmk-cabang`)

```text
itlincensehq25/checkmk-cabang/
├── .gitignore
├── README.md
├── docker-compose-checkmk.yml
├── .github/workflows/
│   └── build-cmkagent.yml          # unknown function
├── android/
│   ├── app/                        # Much more subfolder here
    ├── build.grandle               # Unknown
    ├── grandle.properties          # Unknown
│   └── setting.grandle             # Unknown
├── linux/
│   ├── install.sh                  # Skrip Bootstrap Installer Linux Client (Multi-Distro)
│   ├── install_server_stack.sh     # Auto-Installer Server Stack (Docker Engine, Dockge, Checkmk Community)
│   └── local_checks/               # 10 Skrip Local Checks Linux
│       ├── battery_health.sh       # Deteksi Kesehatan Baterai (UPower & Sysfs Fallback)
│       ├── cpu_info.sh             # Metrik CPU (Model, Speed, Cores, Load, Temp)
│       ├── disk_nvme_health.sh     # Pemantau Kesehatan Disk (NVMe, SATA SSD TBW, SATA HDD)
│       ├── fan_health.sh           # Pemantau Kipas (RPM vs Suhu CPU)
│       ├── info_network.sh         # Performa & Bandwidth Jaringan (RX/TX Rate & IP)
│       ├── info_OS_office.sh       # Informasi OS & Deteksi Aplikasi Office (LibreOffice, Onlyoffice, WPS)
│       ├── ram_health.sh           # Uji RAM Asinkron via memtester (20% Free RAM)
│       ├── ram_usage.sh            # Penggunaan RAM Fisik Real-time (Used, Free, Total)
│       ├── remote_apps.sh          # Deteksi ID AnyDesk & RustDesk
│       └── storage_usage.sh        # Penggunaan Kapasitas Partisi Penyimpanan Fisik
├── windows/
│   ├── install.ps1                 # Skrip Bootstrap Installer Windows Client (Mode Interaktif & CLI)
│   └── local_checks/               # 10 Skrip Local Checks Windows
│       ├── battery_health.ps1      # Deteksi Baterai Laptop vs PC Desktop
│       ├── cpu_info.ps1            # Metrik CPU & Suhu Windows
│       ├── disk_nvme_health.ps1    # Kesehatan NVMe, SSD, & HDD Windows
│       ├── fan_health.ps1          # Pemantau Kipas Windows (Win32_Fan / CIM)
│       ├── info_network.ps1        # Statistik Jaringan Windows (IP & Throughput)
│       ├── info_OS_office.ps1      # Detail OS Windows & Deteksi MS Office / Onlyoffice
│       ├── ram_health.ps1          # Uji RAM Asinkron Windows (20% Free RAM)
│       ├── ram_usage.ps1           # Penggunaan RAM Fisik Windows
│       ├── remote_apps.ps1         # Deteksi ID AnyDesk & RustDesk (--get-id)
│       └── storage_usage.ps1       # Penggunaan Kapasitas Storage Windows
├── server-test/
    ├── README.md                   # Unknow funtion
    └── receiver.py                 # Unknow fitur
```
---

## 🚀 Panduan Deployment Cepat (One-Liner Bootstrap)

### **1. Server Stack (Docker, Dockge, Checkmk Community Edition)**

Jalankan perintah satu baris ini pada terminal server Linux (Ubuntu/Debian/RHEL/Fedora) dengan hak akses **root / sudo**:
```bash
curl -fsSL https://raw.githubusercontent.com/itlicensehq25/checkmk-cabang/main/linux/install_server_stack.sh | sudo bash
```
> **Info Akses Dashboard Server**:
> * **Dockge Manager**: `http://<IP_SERVER>:5001`
> * **Checkmk Web GUI**: `http://<IP_SERVER>:8080/cmk` *(User: `cmkadmin` | Pass: `cmkadmin`)*
> * **Agent Registration Port**: `<IP_SERVER>:8000`

---

### **2. Client Linux (Debian, Ubuntu, Fedora, RHEL, Rocky, Alma)**

#### **A. Mode Interaktif**:
```bash
curl -sSfgL https://raw.githubusercontent.com/itlincensehq25/checkmk-cabang/main/linux/install.sh | sudo bash
```

#### **B. Mode Instan / Silent (Deployment Massal)**:
```bash
curl -sSfgL https://raw.githubusercontent.com/itlincensehq25/checkmk-cabang/main/linux/install.sh | sudo bash -s -- \
  -s 192.168.1.100:8080 \
  -d cmk \
  -v 2.5.0p14-1 \
  -g itlincensehq25/checkmk-cabang
```

---

### **3. Platform Windows**

Jalankan perintah berikut melalui **PowerShell (Administrator)**:

#### **A. Mode Interaktif (3 Inputan Ringkas)**:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/itlicensehq25/checkmk-cabang/main/windows/install.ps1'))
```

#### **B. Mode Non-Interaktif / Fast CLI**:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex "& { $(New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/itlicensehq25/checkmk-cabang/main/windows/install.ps1') } -s 192.168.1.100:8080 -d cmk -v 2.5.0p14-1"
```

---

## 🔐 Registrasi Sertifikat Keamanan Agen (mTLS Registration)

Pendaftaran sertifikat mTLS (*Mutual Transport Layer Security*) dilakukan **satu kali** (*one-time registration*) setelah instalasi agen untuk mengamankan jalur enkripsi antara agen dan server Checkmk.

### **Linux Host**:
```bash
sudo cmk-agent-ctl register \
  --hostname <NAMA_HOST_CLIENT> \
  --server <IP_SERVER_CHECKMK>:8000 \
  --site cmk \
  --user cmkadmin
```

### **Windows Host (PowerShell Administrator)**:
```powershell
$ctlPath = "C:\Program Files (x86)\checkmk\service\cmk-agent-ctl.exe"
if (-not (Test-Path $ctlPath)) { $ctlPath = "C:\Program Files\checkmk\service\cmk-agent-ctl.exe" }

& "$ctlPath" register `
  --hostname <NAMA_HOST_CLIENT> `
  --server <IP_SERVER_CHECKMK>:8000 `
  --site cmk `
  --user cmkadmin
```

---

## 📊 Detail 10 Skrip Pemantauan Lokal (Local Checks)

Seluruh output local check menggunakan placeholder data kinerja (`-`) serta pembatas visual Unicode Light Vertical Bar (**`❘`**) untuk menjamin keakuratan parsing data Checkmk.

### **1. `battery_health.sh` / `battery_health.ps1`**
*   **Fungsi**: Mendeteksi secara dinamis baterai laptop (UPower / Sysfs / WMI) dan PC Desktop.
*   **Format Output**:
    `0 "Health_Battery" - Status Battery : Fully Charged ❘ Design Capacity : 40w/h ❘ Current Capacity : 36w/h ❘ Health : 90% ❘ Battery Level : 100%`

### **2. `cpu_info.sh` / `cpu_info.ps1`**
*   **Fungsi**: Membaca spesifikasi prosesor fisik, menghitung load %, kecepatan clock, dan sensor suhu CPU.
*   **Format Output**:
    `0 "CPU_Info" - Spesifikasi : Intel Core i3 13100 | Clock Speed : 3.4Ghz | Core/Thread : 4/8 | CPU Load : 12% | CPU Temperature: 48 Celcius`

### **3. `disk_nvme_health.sh` / `disk_nvme_health.ps1`**
*   **Fungsi**: Pemantau penyimpanan terpadu (NVMe, SATA SSD, HDD). Menghitung TBW berbasis algoritma heuristik LBA serta pelacakan bad sector HDD.
*   **Format Output (SSD)**:
    `0 "Storage_Health_sda" - Status : OK ❘ Model: CS900 SSD 120GB (111.79 GB) ❘ Status: PASSED ❘ Temp: 26C ❘ Health: 100% ❘ Read: 4.8 TB ❘ Written: 5.2 TB ❘ Write/Day: 35.50 GB ❘ Est. Life: >10 Years`

### **4. `fan_health.sh` / `fan_health.ps1`**
*   **Fungsi**: Membandingkan kecepatan putaran kipas pendingin (*fan RPM*) terhadap suhu CPU.
*   **Format Output**:
    `0 "FAN_Health" - Status : OK | FAN Speed : 2319rpm | Remark: FAN Condition Good`

### **5. `info_network.sh` / `info_network.ps1`**
*   **Fungsi**: Melacak statistik performa jaringan, RX/TX Rate, serta IP Address aktif secara real-time.
*   **Format Output**:
    `0 "Info_Network_wlo1" in=122554432c|out=3586048c OK - IP Address: 192.168.43.33 | Total Download: 114.14 GB | Total Upload: 3.34 GB | RX Rate : 250.20 KB/s | TX Rate : 123.00 KB/s`

### **6. `info_OS_office.sh` / `info_OS_office.ps1`**
*   **Fungsi**: Menyajikan rincian distribusi OS, kernel, serta pendeteksian terintegrasi aplikasi office (LibreOffice, OnlyOffice, WPS, MS Office).
*   **Format Output**:
    `0 "Info_OS" - OK - OS: Ubuntu 24.04 LTS | Kernel: 6.8.0-40-generic ❘ Checked At: 2026-09-24 16:00:00`

### **7. `ram_health.sh` / `ram_health.ps1`**
*   **Fungsi**: Uji kesehatan memori RAM asinkron (alokasi dinamis 20% Free RAM) beserta pemetaan slot fisik RAM (SMBIOS/DMI).
*   **Format Output**:
    `0 "Health_RAM" - Status : OK ❘ Result: Passed ❘ Tested Size: 1638M ❘ Last Test: 2026-09-24 11:00 ❘ Used Slots: 2/2 (0 Empty) ❘ Active Modules: [8GiB,8GiB] ❘ Log: memtester passed successfully.`

### **8. `ram_usage.sh` / `ram_usage.ps1`**
*   **Fungsi**: Memantau persentase penggunaan memori fisik (RAM) real-time.
*   **Format Output**:
    `0 "RAM_Usage" - Status : OK ❘ Used: 45% ❘ Used Space: 3.60 GB ❘ Free: 4.40 GB ❘ Total: 8.00 GB`

### **9. `remote_apps.sh` / `remote_apps.ps1`**
*   **Fungsi**: Mengidentifikasi ID unik aplikasi remote support yang terpasang (AnyDesk & RustDesk).
*   **Format Output**:
    `0 "Remote_Apps" - Status : OK ❘ AnyDesk ID: 123456789 ❘ RustDesk ID: 987654321`

### **10. `storage_usage.sh` / `storage_usage.ps1`**
*   **Fungsi**: Memantau persentase kapasitas partisi penyimpanan fisik lokal (bebas virtual/tmpfs).
*   **Format Output**:
    `0 "Storage_Usage_root" - Status : OK ❘ Partition: / ❘ Used: 42% ❘ Free: 139.20 GB ❘ Total: 240.00 GB`

---

## 📋 Matriks Standardisasi Threshold Keputusan

Checkmk menginterpretasikan status (*OK / Warning / Critical*) berdasarkan matriks keputusan baku berikut:

| Parameter Monitoring | OK (0) | Warning (1) | Critical (2) | Keterangan / Sumber Data |
| :--- | :--- | :--- | :--- | :--- |
| **Suhu CPU** | `≤ 75°C` | `> 75°C` s.d `≤ 85°C` | `> 85°C` | Sensor ACPI / CPUTIN / Coretemp |
| **FAN Speed** | `> 1600 RPM` atau `0 RPM` (Jika Fanless/PC) | `< 1600 RPM` (Saat suhu tinggi) | Kipas macet / mati saat overheat | lm-sensors / WMI / CIM |
| **Battery Health** | `≥ 60%` | `40% - 59%` | `≤ 20%` | UPower / sysfs / WMI |
| **SSD Health** | `> 90%` | `81% - 90%` | `≤ 80%` | Remaining Life / TBW Wearout |
| **HDD Bad Sector** | 0 | Reallocated/Pending `> 0` | Reallocated `≥ 50` | SMART Reallocated Sector Count |
| **RAM Usage** | `< 85%` | `≥ 85%` s.d `< 95%` | `≥ 95%` | `/proc/meminfo` / Win32_OperatingSystem |
| **RAM Health** | Passed | - | Failed | Uji Alokasi Memori Dinamis (20% Free RAM) |
| **Storage Usage** | `< 85%` | `≥ 85%` s.d `< 95%` | `≥ 95%` | Partisi Penyimpanan Fisik Lokal |
| **Aplikasi Remote** | Terdeteksi ID | - | Tidak terpasang | AnyDesk CLI / RustDesk `--get-id` |

---
*Dokumen ini diperbarui secara berkala mengikuti pengembangan standardisasi infrastruktur monitoring IT.*
