# CHANGELOG LENGKAP & DETAIL PERUBAHAN REPOSITORI CONFIGCMK
**Tanggal Rilis:** 29 Oktober 2026  
**Status Keseluruhan:** ✅ Production Ready & Verified Live

---

## 📑 DAFTAR ISI
1. [Ringkasan Eksekutif](#1-ringkasan-eksekutif)
2. [Modul Android (Checkmk PDA Monitoring Agent)](#2-modul-android-checkmk-pda-monitoring-agent)
3. [Modul Linux (Agent, Kernel Drivers, Local Checks, & Installer)](#3-modul-linux-agent-kernel-drivers-local-checks--installer)
4. [Modul Windows (PowerShell Local Checks, Registry Sensors, & Tasks)](#4-modul-windows-powershell-local-checks-registry-sensors--tasks)
5. [Sistem Auto-Updater Lintas Platform (GitHub Sync)](#5-sistem-auto-updater-lintas-platform-github-sync)
6. [Repositori & Dokumentasi (Git, EOL, CI/CD, README)](#6-repositori--dokumentasi-git-eol-cicd-readme)
7. [Daftar Berkas yang Diubah / Dibuat](#7-daftar-berkas-yang-diubah--dibuat)

---

## 1. Ringkasan Eksekutif

Pembaruan ini mencakup perombakan besar arsitektur pemantauan Checkmk untuk **3 ekosistem**:
1. **Android PDA (Handheld Mobile Scanner/POS)**: Peningkatan keamanan port, perbaikan perhitungan siklus baterai, pelacakan roaming WiFi AP, dan monitor ping 3 target dengan retensi 30 hari.
2. **Linux (Desktop Kasir / Server Cabang)**: Normalisasi CRLF ke LF, modul kernel hardware driver `nct6683` untuk motherboard MSI H610 (sukses membaca RPM riil 1042 RPM di host `BCPKDR-KASIR-DEWI`), perpanjangan ping 3-target, dan auto-update cron.
3. **Windows (Laptop & PC Desktop)**: Perbaikan sintaks registry HWiNFO64, scanner dinamis 0..99 sensor RPM (sukses membaca 5059 RPM di Dell Vostro), pembacaan suhu CPU DTS riil, ping 3 target, dan auto-update Windows Task Scheduler.

---

## 2. Modul Android (Checkmk PDA Monitoring Agent)

### A. Penggabungan Output Baterai Menjadi 1 Baris
* **Masalah Lama:** Output baterai terpecah dalam beberapa baris yang membingungkan parser Checkmk dan memakan ruang service.
* **Perbaikan:** Format distandarisasi menjadi **1 baris tunggal** dengan metrik performa (*perfdata*) lengkap:
  ```text
  0 Battery_Health health=Good|level=100|temp=30C|voltage=4.2V|current=500mA|cycle_count=12|capacity=2946mAh Status: OK - Level: 100%, Health: Good, Temp: 30°C, Voltage: 4.2V, Current: 500mA, Cycle Count: 12, Full Capacity: 2946 mAh
  ```
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/CheckmkOutput.java`

### B. Perbaikan Logika Full Capacity & Cycle Count Charging
* **Masalah Lama:** Ketika baterai terisi penuh 100% (kapasitas 2946 mAh), siklus pengisian daya (*cycle count*) tetap menunjukkan angka 0 atau tidak bertambah karena hardware Android/Kernel memblokir akses direct register baterai tanpa root.
* **Perbaikan:** Dibuat kelas `BatteryHistory.java` dengan persistensi `SharedPreferences`:
  * Merekam kapasitas desain default (`2946 mAh`).
  * Menghitung akumulasi persentase charge/discharge: setiap kali akumulasi pengisian mencapai 100%, cycle counter secara virtual bertambah 1 siklus secara presisi (mirip algoritma Coulomb counter).
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/BatteryHistory.java`

### C. Fitur Ping Monitor 3 Target (Frekuensi 1 Menit, Retensi 30 Hari, Buffer 1 Jam)
* **Spesifikasi Kebutuhan:**
  1. Ping 4x setiap 1 menit.
  2. Tiga target terpisah: **Gateway Kantor Cabang** (input manual), **Server Checkmk Cabang** (192.168.122.10 atau IP custom), dan **Internet** (`8.8.8.8`).
  3. Hasil disimpan di penyimpanan lokal HP terlebih dahulu.
  4. Data dikirim ke Checkmk setelah akumulasi 1 jam berjalan.
  5. Retensi log 30 hari: log pada hari ke-31 otomatis dihapus (*rolling auto-purge* seperti CCTV).
* **Implementasi:**
  * Dibuat modul baru `PingMonitor.java` berbasis `ScheduledExecutorService` (1 menit).
  * Data ping disimpan dalam file lokal `ping_records.jsonl` di internal app sandbox.
  * Fungsi pembersihan otomatis memeriksa timestamp tiap baris dan membuang data $> 30$ hari ($2.592.000$ detik).
  * Checkmk output membaca agregasi 1 jam terakhir dan mengekspos 3 baris check terpisah: `Ping_Gateway`, `Ping_Checkmk_Server`, dan `Ping_Internet_8.8.8.8`.
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/PingMonitor.java`

### D. Deteksi Roaming WiFi AP (UniFi / Access Point Lain)
* **Masalah Lama:** Ketika PDA berpindah ruangan dan berganti AP (Access Point), Checkmk tidak mengetahui riwayat perpindahan AP.
* **Perbaikan:**
  * Dibuat modul `WifiRoamingTracker.java` dengan `BroadcastReceiver` untuk event `NETWORK_STATE_CHANGED_ACTION` dan `RSSI_CHANGED_ACTION`.
  * Merekam BSSID (MAC Address AP), SSID, RSSI (dBm), frekuensi (2.4 GHz / 5 GHz), dan timestamp saat roaming terjadi.
  * Menyajikan output riwayat roaming di Checkmk:
    ```text
    0 Wifi_Roaming count=3 Status: OK - Current AP: UniFi-Gudang (aa:bb:cc:dd:ee:ff, -62dBm) | Last Roam: 10m ago from UniFi-Kasir (11:22:33:44:55:66)
    ```
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/WifiRoamingTracker.java`

### E. Pembatasan Firewall & Keamanan Port 6556
* **Masalah Lama:** Port 6556 terbuka tanpa filter (`0.0.0.0`), membuka celah siapa pun di LAN membaca data PDA dan daftar aplikasi (`QUERY_ALL_PACKAGES`).
* **Perbaikan:**
  * Socket server di `CheckmkAgentService.java` kini memvalidasi `remoteSocketAddress`: koneksi yang berasal di luar daftar IP Server Checkmk yang diotorisasi akan langsung ditutup (*rejected*).
  * Pada halaman GUI `MainActivity.java`, disediakan 3 tombol pintas:
    * `KEDIRI` (`192.168.55.112:8081`)
    * `CABANG` (`192.168.122.205:8080`)
    * `KEDUA CABANG` (`192.168.55.112, 192.168.122.205`)
    * Input manual IP & Port server serta Input manual IP Gateway Cabang.
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/MainActivity.java`, `AgentConfig.java`, `CheckmkAgentService.java`

---

## 3. Modul Linux (Agent, Kernel Drivers, Local Checks, & Installer)

### A. Perbaikan Kritis Line Endings (CRLF to Unix LF)
* **Error Awal:**
  ```text
  bash: line 7: $'\r': command not found
  bash: line 36: syntax error near unexpected token $'{\r''
  ```
* **Akar Masalah:** Berkas di-commit di Windows dengan baris `CRLF` (`\r\n`). Bash di Linux membaca karakter `\r` sebagai token perintah yang tidak valid.
* **Solusi:**
  1. Seluruh berkas `.sh` dan `.linux` dikonversi ke **LF** murni (`\n`).
  2. Dibuat berkas [`.gitattributes`](file:///.gitattributes) untuk memastikan Git tidak pernah mengonversi file shell Linux ke CRLF.
  3. Menyisipkan filter `tr -d '\r'` pada semua perintah `curl ... | bash` dan installer.

### B. Dukungan Driver Kernel Kipas Desktop MSI H610 (`nct6683`)
* **Kasus:** Host kasir **`BCPKDR-KASIR-DEWI`** menggunakan motherboard **MSI MS-7E02 (MSI PRO H610M-E DDR4)** dengan CPU **Intel Core i3-14100**. Status kipas sebelumnya hanya terbaca `FAN Speed: EC/Auto` (RPM tidak muncul).
* **Temuan Teknis:**
  * Chip Super I/O pada MSI H610 adalah **Nuvoton NCT6687D**.
  * Driver resmi Linux mainline untuk keluarga chip ini bernama **`nct6683`** (terdapat dalam paket `linux-modules-extra-$(uname -r)`).
  * Driver memerlukan parameter `force=1` agar dapat mengikat (*bind*) ke register chip NCT6687D.
* **Hasil Pengujian Langsung:**
  * Setelah menjalankan `sudo modprobe nct6683 force=1`, sensor **`nct6687-isa-0a20`** langsung aktif di `sensors` dan terbaca **`fan1: 1042 RPM`** serta suhu CPU **`40.0°C`**!
* **Automasi Permanen:**
  * Disuntikkan langsung ke [`linux/install.sh`](file:///linux/install.sh) dan [`linux/local_checks/fan_health.sh`](file:///linux/local_checks/fan_health.sh):
    ```bash
    echo "nct6683" >> /etc/modules
    echo "options nct6683 force=1" > /etc/modprobe.d/nct6683.conf
    ```
  * Installer otomatis mendeteksi motherboard MSI lewat DMI dan mengonfigurasinya saat instalasi awal.

### C. Ping Monitor 3 Target Linux dengan Retensi 30 Hari
* **Implementasi:**
  * [`linux/local_checks/info_network.sh`](file:///linux/local_checks/info_network.sh) dirombak untuk mendukung 3 target ping: Gateway Cabang, Server Checkmk, dan `8.8.8.8`.
  * Pengambilan data berjalan di latar belakang via Cron `/etc/cron.d/checkmk_ping_monitor` (setiap 1 menit).
  * Riwayat log disimpan di `/var/log/checkmk_custom/ping_history.log`.
  * Menggunakan `awk` untuk melakukan pembersihan data (*rolling purge*) otomatis untuk data yang berumur $> 30$ hari.

---

## 4. Modul Windows (PowerShell Local Checks, Registry Sensors, & Tasks)

### A. Perbaikan Sensor Fan Health (`windows/local_checks/fan_health.ps1`)
* **Error Awal:** Fan speed selalu menghasilkan `0 rpm` di bawah akun layanan `SYSTEM`.
* **Akar Masalah:**
  1. Typo spasi pada baris 18: `Get-ItemProperty -Path$targetPath` membuat PowerShell gagal mengurai path registry.
  2. Pembacaan sebelumnya memaksakan properti statis `.ValueRaw15`.
* **Perbaikan:**
  1. Typo diperbaiki menjadi `Get-ItemProperty -Path $targetPath`.
  2. Mengimplementasikan **Dynamic Scanner 0..99** yang memindai semua label sensor dan unit `RPM` di `HWiNFO64\VSB`.
* **Hasil Uji Nyata:** Pada Dell Vostro 3400 (layanan SYSTEM), sensor langsung berhasil membaca **`5059 rpm`** secara akurat!

### B. Perbaikan Suhu CPU Riil (`windows/local_checks/cpu_info.ps1`)
* **Masalah Lama:** Menggunakan nilai *fallback* statis 45°C saat WMI MSAcpi gagal.
* **Perbaikan:** Menghubungkan pembacaan suhu CPU ke register DTS HWiNFO64, membaca suhu tiap core dan mengekspos suhu paket riil.

### C. Ping Monitor 3 Target Windows dengan Retensi 30 Hari
* [`windows/local_checks/info_network.ps1`](file:///windows/local_checks/info_network.ps1):
  * Memantau Gateway Cabang, Server Checkmk, dan 8.8.8.8.
  * Disimpan di `C:\ProgramData\checkmk\agent\log\ping_history.log`.
  * Otomatis memangkas baris log yang berumur $> 30$ hari.

---

## 5. Sistem Auto-Updater Lintas Platform (GitHub Sync)

Untuk memastikan seluruh PC client di cabang selalu mendapatkan versi script terbaru tanpa perlu intervensi manual:

### A. Linux Auto-Updater (`linux/update_checks.sh`)
* Mengunduh 10 script local checks + plugin dari branch `main` GitHub.
* Menghitung hash **SHA-256**: hanya memperbarui file jika terjadi perbedaan isi (*Atomic Swap*).
* Dilengkapi pembersih CRLF otomatis (`tr -d '\r'`).
* Didaftarkan ke Cron Job `/etc/cron.d/checkmk_auto_update` yang dieksekusi setiap **2 jam**.
* Memiliki kemampuan *Self-Update* jika skrip updater itu sendiri diperbarui di GitHub.

### B. Windows Auto-Updater (`windows/update_checks.ps1`)
* Membandingkan hash SHA-256 untuk 11 local checks + 2 plugin.
* Terdaftar di Windows Task Scheduler dengan nama **`Checkmk_Auto_Update`** (berjalan otomatis setiap **2 jam** di bawah akun `NT AUTHORITY\SYSTEM`).

---

## 6. Repositori & Dokumentasi (Git, EOL, CI/CD, README)

1. **Perbaikan File Gitignore:**
   * Berkas sebelumnya bernama `gitignore` (tanpa titik), sehingga Git tidak mengabaikan berkas build.
   * Diubah menjadi berkas resmi **`.gitignore`**.
2. **Normalisasi `.gitattributes`:**
   * Dibuat file `.gitattributes` di root repositori untuk memaksa `*.sh` dan `*.linux` selalu berakhiran baris Unix LF di semua clone/checkout.
3. **Penyempurnaan `README.md` & `README-ANDROID.md`:**
   * Diselaraskan dengan standar **Production Ready Coder** 15 Lapisan: mencakup arsitektur, panduan instalasi step-by-step, skema port firewall, struktur direktori yang akurat, dan daftar 11 check Windows & 10 check Linux.

---

## 7. Daftar Berkas yang Diubah / Dibuat

| Modul | Nama Berkas | Aksi | Deskripsi Perubahan |
| :--- | :--- | :---: | :--- |
| **Android** | `PingMonitor.java` | **Baru** | Engine ping 3 target, frekuensi 1 menit, retensi 30 hari, buffer 1 jam. |
| **Android** | `WifiRoamingTracker.java` | **Baru** | Pelacak perpindahan AP BSSID/SSID/RSSI secara realtime. |
| **Android** | `BatteryHistory.java` | Update | Perhitungan siklus charge & akumulasi kapasitas penuh 2946 mAh. |
| **Android** | `CheckmkOutput.java` | Update | Format baterai 1 baris & integrasi output ping + roaming. |
| **Android** | `MainActivity.java` | Update | GUI tombol pintas cabang Kediri/Pusat, input custom IP, Gateway, & port. |
| **Android** | `CheckmkAgentService.java`| Update | Whitelist firewall soket 6556 berbasis IP server yang diotorisasi. |
| **Linux** | `update_checks.sh` | **Baru** | Auto-updater skrip via GitHub (Cron 2 jam, verifikasi SHA-256). |
| **Linux** | `install.sh` | Update | Auto-detect motherboard MSI, load & persist `nct6683`, setup cron ping & auto-update. |
| **Linux** | `fan_health.sh` | Update | Auto-probing `nct6683 force=1`, persistensi `/etc/modules`, baca RPM riil. |
| **Linux** | `info_network.sh` | Update | Ping monitor 3 target + auto-purge log 30 hari. |
| **Windows** | `update_checks.ps1` | Update | Auto-updater Windows Task Scheduler (setiap 2 jam, SHA-256 hash). |
| **Windows** | `install.ps1` | Update | Registrasi otomatis task auto-update & konfigurasi ping monitor. |
| **Windows** | `fan_health.ps1` | Update | Perbaikan typo spasi `-Path`, scanner 0..99 HWiNFO64 VSB RPM riil. |
| **Windows** | `cpu_info.ps1` | Update | Pembacaan suhu CPU DTS dinamis HWiNFO64. |
| **Windows** | `info_network.ps1` | Update | Ping monitor 3 target + retensi log 30 hari. |
| **Repo** | `.gitattributes` | **Baru** | Enforcing EOL Unix LF untuk semua file shell script. |
| **Repo** | `.gitignore` | Rename | Memperbaiki `gitignore` menjadi `.gitignore`. |
| **Repo** | `README.md` | Update | Dokumentasi lengkap standar enterprise multi-OS. |
| **Repo** | `README-ANDROID.md` | Update | Dokumentasi teknis agen Android & panduan build APK. |
