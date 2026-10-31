# CHANGELOG LENGKAP & DETAIL PERUBAHAN REPOSITORI CONFIGCMK
**Tanggal Rilis:** 30 Oktober 2026  
**Status Keseluruhan:** ✅ Production Ready & Verified Live

---

## 📑 DAFTAR ISI
1. [Ringkasan Eksekutif](#1-ringkasan-eksekutif)
2. [Modul Android (Checkmk PDA Monitoring Agent)](#2-modul-android-checkmk-pda-monitoring-agent)
3. [Modul Linux (Agent, Multi-Vendor Motherboard Drivers, GRUB, & Local Checks)](#3-modul-linux-agent-multi-vendor-motherboard-drivers-grub--local-checks)
4. [Modul Windows (PowerShell Local Checks, Registry Sensors, HWiNFO, & Tasks)](#4-modul-windows-powershell-local-checks-registry-sensors-hwinfo--tasks)
5. [Sistem Auto-Updater Lintas Platform (GitHub Sync)](#5-sistem-auto-updater-lintas-platform-github-sync)
6. [Repositori & Dokumentasi (Git, EOL, CI/CD, README)](#6-repositori--dokumentasi-git-eol-cicd-readme)
7. [Daftar Berkas yang Diubah / Dibuat](#7-daftar-berkas-yang-diubah--dibuat)

---

## 1. Ringkasan Eksekutif

Pembaruan ini mencakup perombakan besar arsitektur pemantauan Checkmk untuk **3 ekosistem**:
1. **Android PDA (Handheld Mobile Scanner/POS)**: Peningkatan keamanan port, perbaikan perhitungan siklus baterai, pelacakan roaming WiFi AP, dan monitor ping 3 target dengan retensi 30 hari.
2. **Linux (Desktop Kasir / Server Cabang)**: Normalisasi CRLF ke LF, modul kernel multi-vendor motherboard (MSI `nct6683`, Gigabyte `it87` & `gigabyte_wmi`, ASUS `asus_ec_sensors`, ASRock `nct6775`, Dell `dell_smm_hwmon`, Lenovo `thinkpad_acpi`), otomasi patch GRUB `acpi_enforce_resources=lax`, perpanjangan ping 3-target, dan auto-update cron.
3. **Windows (Laptop & PC Desktop)**: Perbaikan sintaks registry HWiNFO64, scanner dinamis 0..99 sensor RPM (sukses membaca 5059 RPM di Dell Vostro), skrip otomasi `setup_hwinfo.ps1`, pembacaan suhu CPU DTS riil, ping 3 target, dan auto-update Windows Task Scheduler.

---

## 2. Modul Android (Checkmk PDA Monitoring Agent)

### A. Penggabungan Output Baterai Menjadi 1 Baris
* **Format:** Distandarisasi menjadi **1 baris tunggal** dengan metrik performa (*perfdata*) lengkap:
  ```text
  0 Battery_Health health=Good|level=100|temp=30C|voltage=4.2V|current=500mA|cycle_count=12|capacity=2946mAh Status: OK - Level: 100%, Health: Good, Temp: 30°C, Voltage: 4.2V, Current: 500mA, Cycle Count: 12, Full Capacity: 2946 mAh
  ```
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/CheckmkOutput.java`

### B. Perbaikan Logika Full Capacity & Cycle Count Charging
* Dibuat kelas `BatteryHistory.java` dengan persistensi `SharedPreferences` yang merekam kapasitas desain default (`2946 mAh`) dan menghitung akumulasi charging 100% menjadi 1 siklus nyata secara presisi.
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/BatteryHistory.java`

### C. Fitur Ping Monitor 3 Target (Frekuensi 1 Menit, Retensi 30 Hari, Buffer 1 Jam)
* Ping 4x setiap 1 menit ke 3 target: **Gateway Cabang**, **Server Checkmk**, dan **8.8.8.8**.
* Disimpan di lokal HP, dikirim tiap 1 jam, dan auto-purge data $>30$ hari.
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/PingMonitor.java`

### D. Deteksi Roaming WiFi AP (UniFi / Access Point Lain)
* Mendeteksi perpindahan BSSID, SSID, RSSI, dan channel secara realtime.
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/WifiRoamingTracker.java`

### E. Pembatasan Firewall & Keamanan Port 6556
* Socket server memvalidasi alamat IP yang masuk. Koneksi di luar whitelist IP Server Checkmk langsung ditolak.
* Disediakan tombol shortcut cabang Kediri/Pusat dan port kustom (8081/8080/80) di GUI `MainActivity.java`.

---

## 3. Modul Linux (Agent, Multi-Vendor Motherboard Drivers, GRUB, & Local Checks)

### A. Perbaikan Kritis Line Endings (CRLF to Unix LF)
* Seluruh berkas `.sh` dan `.linux` dikonversi ke **LF** murni (`\n`).
* Dibuat berkas `.gitattributes` dan filter `tr -d '\r'` pada semua proses `curl | bash`.

### B. Otomasi Patch Bootloader GRUB (`acpi_enforce_resources=lax`)
* Pada motherboard modern (MSI, Gigabyte B760/B660, ASUS), BIOS mengunci port I/O sensor untuk fitur Smart Fan internal.
* Skrip `linux/install.sh` kini secara **otomatis memeriksa `/etc/default/grub`**, menyuntikkan parameter `acpi_enforce_resources=lax` ke `GRUB_CMDLINE_LINUX_DEFAULT`, dan mengeksekusi `update-grub` tanpa perlu diedit manual oleh teknisi.

### C. Matriks Otomasi Multi-Vendor Motherboard Desktop & Laptop
Installer dan skrip `fan_health.sh` mendeteksi vendor hardware lewat DMI BIOS (`/sys/class/dmi/id/sys_vendor`):
* **MSI (Micro-Star):** Mengaktifkan modul Nuvoton `nct6683 force=1` (berhasil membaca `1042 RPM` di host `BCPKDR-KASIR-DEWI`).
* **GIGABYTE / AORUS:** Mengaktifkan modul ITE `it87 ignore_resource_conflict=1 force_id=0x8628` (terbukti sukses membaca `1477 RPM` di Gigabyte B760M DS3H AX / chip IT8689E host `bcpkdrinkirawan`), fallback `native`, `0x8689`, `0x8688`, `0x8686` + `gigabyte_wmi`, serta persistensi otomatis di `/etc/modprobe.d/it87.conf` dan `/etc/modules`.
* **ASUS / ASUSTeK:** Mengaktifkan modul `asus_ec_sensors`, `asus_wmi`, dan `nct6775`.
* **ASRock:** Mengaktifkan modul Nuvoton/Winbond `nct6775` dan `w83627ehf`.
* **DELL:** Mengaktifkan modul `dell_smm_hwmon ignore_dmi=1 restricted=0`.
* **LENOVO:** Mengaktifkan modul `thinkpad_acpi` dan `ideapad_laptop`.
* **HP:** Mengaktifkan modul `hp_wmi`.

### D. Ping Monitor 3 Target Linux dengan Retensi 30 Hari
* `linux/local_checks/info_network.sh` memantau Gateway Cabang, Server Checkmk, dan 8.8.8.8 tiap 1 menit via `/etc/cron.d/checkmk_ping_monitor` dengan rotasi data 30 hari di `/var/log/checkmk_custom/ping_history.log`.

---

## 4. Modul Windows (PowerShell Local Checks, Registry Sensors, HWiNFO, & Tasks)

### A. Perbaikan Sensor Fan Health (`windows/local_checks/fan_health.ps1`)
* Memperbaiki bug sintaks registry `-Path$targetPath` menjadi `-Path $targetPath`.
* Mengganti indeks statis dengan **Dynamic Scanner 0..99** yang memindai semua sensor HWiNFO64 VSB bervalue `RPM` (berhasil membaca `5059 RPM` di Dell Vostro).

### B. Otomasi HWiNFO64 (`windows/setup_hwinfo.ps1`)
* Menyediakan skrip otomasi untuk mengatur `HWiNFO64.INI` (SensorsOnly, Minimized, Autorun), mengaktifkan registry `EnableVSB`, dan mendaftarkan Task Scheduler Windows agar sensor motherboard terbaca otomatis.

### C. CPU Temp Dinamis (`cpu_info.ps1`)
* Mengganti fallback 45°C dengan pembacaan sensor temperatur core DTS riil dari HWiNFO64.

### D. Ping Monitor 3 Target Windows dengan Retensi 30 Hari
* `windows/local_checks/info_network.ps1` memantau Gateway Cabang, Server Checkmk, dan 8.8.8.8 dengan retensi 30 hari di `C:\ProgramData\checkmk\agent\log_custom\ping_history.log`.

---

## 5. Sistem Auto-Updater Lintas Platform (GitHub Sync)

1. **Linux Auto-Updater (`linux/update_checks.sh`):**
   * Berjalan setiap **2 jam** via `/etc/cron.d/checkmk_auto_update`.
   * Membandingkan hash **SHA-256** berkas di GitHub dengan berkas lokal di Linux.
2. **Windows Auto-Updater (`windows/update_checks.ps1`):**
   * Berjalan setiap **2 jam** via Task Scheduler **`Checkmk_Auto_Update`** (akun `SYSTEM`).
   * Memverifikasi ke-11 skrip local checks PowerShell dan plugin inventaris berbasis SHA-256.

---

## 6. Repositori & Dokumentasi (Git, EOL, CI/CD, README)

* Mengubah berkas `gitignore` menjadi **`.gitignore`**.
* Menambahkan **`.gitattributes`** untuk memaksakan Unix LF pada seluruh skrip Linux.
* Memperbarui dokumentasi **`README.md`** dan **`README-ANDROID.md`** sesuai standar 15-lapisan *Production Ready Coder*.

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
| **Linux** | `install.sh` | Update | Otomasi GRUB `acpi_enforce_resources=lax`, multi-vendor motherboard (MSI, Gigabyte, ASUS, ASRock, Dell, Lenovo), cron ping & auto-update. |
| **Linux** | `fan_health.sh` | Update | Auto-probing multi-vendor motherboard, persistensi `/etc/modules`, baca RPM riil. |
| **Linux** | `info_network.sh` | Update | Ping monitor 3 target + auto-purge log 30 hari. |
| **Windows** | `setup_hwinfo.ps1` | **Baru** | Otomasi setup HWiNFO64.INI, registry VSB, dan task startup. |
| **Windows** | `update_checks.ps1` | Update | Auto-updater Windows Task Scheduler (setiap 2 jam, SHA-256 hash). |
| **Windows** | `install.ps1` | Update | Registrasi otomatis task auto-update, setup_hwinfo, & konfigurasi ping monitor. |
| **Windows** | `fan_health.ps1` | Update | Perbaikan typo spasi `-Path`, scanner 0..99 HWiNFO64 VSB RPM riil. |
| **Windows** | `cpu_info.ps1` | Update | Pembacaan suhu CPU DTS dinamis HWiNFO64. |
| **Windows** | `info_network.ps1` | Update | Ping monitor 3 target + retensi log 30 hari. |
| **Windows** | `windows/lib/*.dll` | Update | Penambahan dependensi assembly .NET helper. |
| **Repo** | `.gitattributes` | **Baru** | Enforcing EOL Unix LF untuk semua file shell script. |
| **Repo** | `.gitignore` | Rename | Memperbaiki `gitignore` menjadi `.gitignore`. |
| **Repo** | `README.md` | Update | Dokumentasi lengkap standar enterprise multi-OS. |
| **Repo** | `README-ANDROID.md` | Update | Dokumentasi teknis agen Android & panduan build APK. |
