# CHANGELOG RESMI - IT OPS NASIONAL
## Standardisasi Pemantauan Checkmk Cabang (`checkmk-cabang`)
**Repositori Terpusat:** [itlicensehq25/checkmk-cabang](https://github.com/itlicensehq25/checkmk-cabang)  
**Target Pengguna:** Seluruh Tim IT Operations Regional & Kantor Cabang Nasional  
**Tanggal Rilis:** 29 Oktober 2026  
**Status Produksi:** ✅ Verified Live on Multi-Hardware (Android PDA, Linux Desktop, Windows Laptop/PC)

---

## 📑 DAFTAR ISI
1. [Latar Belakang & Tujuan Pembaruan Terpusat](#1-latar-belakang--tujuan-pembaruan-terpusat)
2. [Pembaruan Modul Android PDA (`cmkagent v1.3.7`)](#2-pembaruan-modul-android-pda-cmkagent-v137)
3. [Pembaruan Modul Linux (`Debian / Ubuntu / RHEL`)](#3-pembaruan-modul-linux-debian--ubuntu--rhel)
4. [Pembaruan Modul Windows (`Windows 10 / 11 / Server`)](#4-pembaruan-modul-windows-windows-10--11--server)
5. [Infrastruktur Auto-Update Otomatis Lintas Cabang](#5-infrastruktur-auto-update-otomatis-lintas-cabang)
6. [Instruksi Standardisasi Operasional untuk Seluruh IT Cabang](#6-instruksi-standardisasi-operasional-untuk-seluruh-it-cabang)
7. [Daftar Lengkap Berkas Repositori](#7-daftar-lengkap-berkas-repositori)

---

## 1. Latar Belakang & Tujuan Pembaruan Terpusat

Untuk memastikan pemantauan perangkat operasional di seluruh cabang sehingga memiliki keandalan tinggi, keseragaman metrik, serta keamanan jaringan yang ketat, IT OPS NASIONAL merilis pembaruan arsitektur besar melalui repositori terpusat **`itlicensehq25/checkmk-cabang`**.

Pembaruan ini menyelesaikan sejumlah kendala operasional yang ditemukan di lapangan:
* Port monitoring Android yang sebelumnya terbuka tanpa filter kini diamankan dengan whitelist IP Server Cabang.
* Pembacaan status baterai PDA disatukan menjadi 1 baris terpadu dengan algoritma kalibrasi kapasitas dan siklus charging yang akurat.
* Pemantauan konektivitas jaringan ditingkatkan menjadi **3 target ping simultan** (Gateway Cabang, Server Checkmk Lokal, dan Internet 8.8.8.8) dengan riwayat berumur **30 hari** yang otomatis terhapus bergulir (*rolling purge* ala rekaman CCTV).
* Pendeteksian perpindahan Access Point Wi-Fi (*roaming*) untuk melacak kualitas sinyal saat PDA berpindah area kerja.
* Pembacaan kecepatan kipas (*fan RPM*) pada PC dan laptop modern (seperti motherboard desktop MSI H610 dan laptop Dell) yang sebelumnya gagal atau hanya menampilkan `EC/Auto`, kini berhasil membaca putaran RPM riil.
* Penyediaan sistem pembaruan otomatis (*Auto-Updater*) berbasis verifikasi hash SHA-256 agar pembaruan skrip di GitHub langsung terdistribusi ke seluruh client cabang tanpa instalasi ulang manual.

---

## 2. Pembaruan Modul Android PDA (`cmkagent v1.3.7`)

### A. Penyatuan Menu Baterai Menjadi 1 Baris Tunggal (`Health_Battery`)
* **Masalah:** Output baterai sebelumnya terpecah ke dalam beberapa baris service terpisah yang membebani dashboard dan membingungkan pemantauan.
* **Perubahan:** Seluruh metrik baterai (Level, Status, Real Health, Cycles, Full Capacity, Design Spec, Temperature, Voltage, Current) disatukan ke dalam **1 baris service Checkmk (`Health_Battery`)** lengkap dengan multi-perfdata:
  ```text
  0 "Health_Battery" battery_level=100;30;15;0;100|battery_health=100.0;80;65;0;100|battery_cycles=4;500;800;0|battery_temp=31.0;42;48|battery_voltage=4.349|battery_current=-180.0 Level : 100% (Full, AC) | Health : 100.0% (OK) | Cycles : 4 | Full Capacity : 2946 mAh | Design Spec : 4800 mAh | Temp : 31.0 C | Voltage : 4.35 V | Current : -180.0 mA
  ```
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/CheckmkOutput.java`

### B. Perbaikan Logika Kapasitas Penuh (2946 mAh) & Virtual Cycle Counter
* **Masalah:** Pada PDA industri (seperti Newland NLS-MT93), saat baterai terisi 100%, pembacaan kapasitas hardware tercatat di 2946 mAh (dari spek desain pabrik 4800 mAh), namun siklus pengisian daya (*cycle count*) tidak pernah bertambah karena proteksi kernel Android.
* **Perubahan:** Dibuat modul `BatteryHistory.java` yang menghitung akumulasi energi pengisian secara kontinu. Setiap kali akumulasi pengisian mencapai 100% muatan, counter siklus bertambah 1 secara presisi dan disimpan persisten di `SharedPreferences`.
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/BatteryHistory.java`

### C. Monitoring Ping 3 Target (Gateway Cabang, Server Checkmk, 8.8.8.8)
* **Kebutuhan:**
  1. Ping dieksekusi 4x setiap 1 menit.
  2. Memantau **3 target terpisah**:
     * **Gateway Kantor Cabang** (diinput manual di menu Settings PDA atau dideteksi via tombol *Auto-Detect*).
     * **Server Checkmk Cabang** (misal `192.168.122.10` atau IP server cabang masing-masing).
     * **Internet** (`8.8.8.8`).
  3. Hasil ping disimpan di memori lokal PDA selama 1 jam sebelum dikirim ke Checkmk dalam 3 baris terpisah (`Ping_Gateway`, `Ping_Server_Checkmk`, `Ping_8.8.8.8`).
  4. **Retensi 30 Hari :** File riwayat `ping_history.log` menyimpan data 30 hari. Saat hari ke-31 tiba, baris log lama otomatis dibersihkan sehingga kapasitas memori PDA tetap aman (~8 MB).
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/PingMonitor.java`

### D. Pelacak Roaming Access Point Wi-Fi (`WifiRoamingTracker.java`)
* **Kebutuhan:** Mendeteksi perpindahan AP (misal UniFi AP atau perangkat access point lainnya di gudang/toko).
* **Perubahan:** Memantau perubahan BSSID, SSID, RSSI (dBm), frekuensi (2.4 GHz / 5 GHz), dan nomor channel secara realtime. Menghasilkan service Checkmk `WiFi_Status` yang memuat ringkasan perpindahan AP terkini beserta log audit di PDA.
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/WifiRoamingTracker.java`

### E. Pengetatan Keamanan Port 6556 & Antarmuka Settings PDA
* **Masalah:** Port TCP/6556 sebelumnya terbuka untuk seluruh alamat IP (`0.0.0.0`), membuka peluang pihak tidak berwenang di jaringan LAN membaca informasi sistem dan daftar aplikasi (`QUERY_ALL_PACKAGES`).
* **Perubahan:**
  * Socket server di `CheckmkAgentService.java` memvalidasi alamat IP yang melakukan koneksi. Koneksi dari IP di luar whitelist server Checkmk akan langsung ditolak (*rejected*).
  * Pada halaman Settings PDA, IP default tidak ditampilkan secara terbuka melainkan wajib diisi saat konfigurasi awal.
  * Disediakan tombol pintas cabang serta dukungan port kustom (misal `:8081`, `:8080`, atau `:80`).
* **Berkas:** `android/app/src/main/java/com/bcp/checkmkagent/MainActivity.java`, `AgentConfig.java`, `CheckmkAgentService.java`

---

## 3. Pembaruan Modul Linux (`Debian / Ubuntu / RHEL`)

### A. Perbaikan Karakter Baris Windows (CRLF ke Unix LF)
* **Masalah:** Eksekusi skrip melalui `curl | sudo bash` sebelumnya memunculkan error:
  ```text
  bash: line 7: $'\r': command not found
  bash: line 36: syntax error near unexpected token $'{\r''
  ```
* **Solusi:** Seluruh skrip shell di repositori dinormalisasi ke format **Unix LF** murni (`\n`). Repositori dilengkapi [.gitattributes](.gitattributes) dan seluruh pipeline `curl` disisipi filter sanitasi `tr -d '\r'`.

### B. Aktivasi Driver Kipas Desktop Modern
* **Kasus Lapangan:** Host kasir cabang dengan motherboard desktop modern **MSI MS-7E02 (MSI PRO H610M-E DDR4)** dan prosesor **Intel Core i3-14100** sebelumnya tidak dapat membaca RPM kipas pendingin dan hanya memunculkan status `FAN Speed: EC/Auto`.
* **Solusi & Hasil Pengujian Langsung:**
  * Chip Super I/O pada motherboard MSI seri H610/B660/B760 adalah **Nuvoton NCT6687D**.
  * Driver resmi di kernel Linux mainline bernama **`nct6683`** (tersedia di paket `linux-modules-extra-$(uname -r)`).
  * Dengan memuat modul kernel menggunakan parameter `sudo modprobe nct6683 force=1`, sensor **`nct6687-isa-0a20`** langsung aktif dan berhasil membaca putaran kipas riil sebesar **`1042 RPM`** serta suhu prosesor yang sangat dingin di **`40.0°C`**!
* **Automasi Terpusat:**
  * Skrip [`linux/install.sh`](linux/install.sh) kini secara otomatis mendeteksi motherboard MSI lewat DMI BIOS dan langsung menambahkan konfigurasi permanen:
    ```bash
    echo "nct6683" >> /etc/modules
    echo "options nct6683 force=1" > /etc/modprobe.d/nct6683.conf
    ```
  * Skrip [`linux/local_checks/fan_health.sh`](linux/local_checks/fan_health.sh) juga memiliki logika *self-healing* yang otomatis memuat dan mengunci konfigurasi ini jika belum terpasang.

### C. Ping Monitor 3 Target Linux dengan Retensi 30 Hari
* Skrip [`linux/local_checks/info_network.sh`](linux/local_checks/info_network.sh) mengumpulkan data ping ke Gateway Cabang, Server Checkmk, dan 8.8.8.8 setiap 1 menit via `/etc/cron.d/checkmk_ping_monitor`.
* Log disimpan di `/var/log/checkmk_custom/ping_history.log` dengan rotasi otomatis membuang baris log yang berumur $> 30$ hari.

---

## 4. Pembaruan Modul Windows (`Windows 10 / 11 / Server`)

### A. Perbaikan Sensor Kipas Laptop & PC (`fan_health.ps1`)
* **Masalah:** Service `fan_health.ps1` selalu menghasilkan `0 rpm` saat berjalan di bawah akun `NT AUTHORITY\SYSTEM`.
* **Penyebab & Solusi:**
  1. Ditemukan bug penulisan spasi pada query registry: `Get-ItemProperty -Path$targetPath` yang diperbaiki menjadi `Get-ItemProperty -Path $targetPath`.
  2. Pembacaan indeks kaku `.ValueRaw15` diganti dengan **Dynamic Scanner 0..99** yang memindai seluruh sensor registry HWiNFO64 VSB yang memiliki satuan `RPM`.
* **Hasil Pengujian Nyata:** Pada laptop operasional Dell Vostro 3400, kecepatan kipas berhasil terbaca presisi di **`5059 RPM`**!

### B. Pembacaan Suhu CPU DTS Dinamis (`cpu_info.ps1`)
* Mengganti nilai cadangan statis 45°C dengan pembacaan sensor temperatur core DTS riil dari HWiNFO64.

### C. Ping Monitor 3 Target Windows dengan Retensi 30 Hari
* Skrip [`windows/local_checks/info_network.ps1`](windows/local_checks/info_network.ps1) memantau Gateway Cabang, Server Checkmk, dan 8.8.8.8.
* Log disimpan di `C:\ProgramData\checkmk\agent\log_custom\ping_history.log` dengan pemangkasan otomatis data berumur $> 30$ hari.

---

## 5. Infrastruktur Auto-Update Otomatis Lintas Cabang

Untuk mengeliminasi kebutuhan login manual satu per satu ke komputer client saat ada perbaikan skrip di kemudian hari:

1. **Auto-Updater Linux ([`linux/update_checks.sh`](linux/update_checks.sh)):**
   * Berjalan otomatis setiap **2 jam** melalui `/etc/cron.d/checkmk_auto_update`.
   * Membandingkan hash **SHA-256** antara file di GitHub `itlicensehq25/checkmk-cabang` dengan file lokal di `/usr/lib/check_mk_agent/local/`.
   * Hanya menimpa file jika terdapat perbedaan (*Atomic Replacement*).
   * Log tercatat di `/var/log/checkmk_custom/update_checks.log`.

2. **Auto-Updater Windows ([`windows/update_checks.ps1`](windows/update_checks.ps1)):**
   * Didaftarkan ke Windows Task Scheduler dengan nama **`Checkmk_Auto_Update`** (berjalan setiap **2 jam** di bawah akun `SYSTEM`).
   * Memverifikasi ke-11 skrip local checks PowerShell dan plugin inventaris menggunakan hash SHA-256.
   * Log tercatat di `C:\ProgramData\checkmk\agent\log_custom\update_checks.log`.

---

## 6. Instruksi Standardisasi Operasional untuk Seluruh IT Cabang

### A. Perintah Pemasangan Linux Host (Desktop Kasir / Server Cabang)
Cukup jalankan **satu baris** berikut di terminal Linux sebagai root:
```bash
sudo rm -rf /usr/lib/check_mk_agent/local/* /var/lib/check_mk_agent/cache/* && \
curl -sSL https://raw.githubusercontent.com/itlicensehq25/checkmk-cabang/main/linux/install.sh | tr -d '\r' | \
sudo bash -s -- -s <IP_SERVER_CHECKMK_CABANG>:<PORT> -d cmk -v 2.5.0p14-1
```
*(Ganti `<IP_SERVER_CHECKMK_CABANG>:<PORT>` sesuai alamat server Checkmk cabang Anda, misalnya `192.168.55.112:8081` atau `192.168.122.205:80`)*.

### B. Perintah Pemasangan Windows Host (PC Kasir / Backoffice / Laptop)
Buka PowerShell sebagai Administrator dan jalankan:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/itlicensehq25/checkmk-cabang/main/windows/install.ps1'))) -s "<IP_SERVER_CHECKMK_CABANG>:<PORT>" -d "cmk"
```

### C. Pemasangan Android PDA
1. Unduh file `cmkagent-v1.3.7.apk` dari tab **Releases / Actions** repositori [itlicensehq25/checkmk-cabang](https://github.com/itlicensehq25/checkmk-cabang).
2. Instal di PDA Newland NLS-MT93.
3. Buka aplikasi, masukkan **IP Server Checkmk Cabang** dan **IP Gateway Cabang** (atau gunakan tombol *Auto-Detect*).
4. Klik tombol **SAVE & START AGENT**.

---

## 7. Daftar Lengkap Berkas Repositori

| Kategori | Berkas | Deskripsi |
| :--- | :--- | :--- |
| **Dokumentasi** | `README.md` | Panduan utama standar operasional IT OPS NASIONAL. |
| **Dokumentasi** | `README-ANDROID.md` | Panduan arsitektur & kompilasi aplikasi Android PDA. |
| **Dokumentasi** | `CHANGELOG.md` | Catatan teknis detail riwayat rilis dan perbaikan bug. |
| **Konfigurasi Git** | `.gitattributes` | Standar pemaksaan Unix LF untuk file skrip Linux. |
| **Konfigurasi Git** | `.gitignore` | Pengabaian file sementara, cache, dan build APK. |
| **CI/CD** | `.github/workflows/build-cmkagent.yml` | Pipeline kompilasi APK otomatis di GitHub Actions. |
| **Linux Core** | `linux/install.sh` | Installer otomatis agen Linux multi-distro. |
| **Linux Core** | `linux/update_checks.sh` | Updater otomatis berbasis hash SHA-256 via Cron. |
| **Linux Checks** | `linux/local_checks/*.sh` (10 skrip) | Skrip pengawas CPU, RAM, Fan, NVMe, Network Ping 3-Target, OS, Storage, Remote Apps, Battery. |
| **Windows Core** | `windows/install.ps1` | Installer otomatis agen Windows & firewall lockdown. |
| **Windows Core** | `windows/update_checks.ps1` | Updater otomatis Task Scheduler berbasis SHA-256. |
| **Windows Checks** | `windows/local_checks/*.ps1` (11 skrip) | Skrip pengawas CPU, RAM, Fan HWiNFO, Disk NVMe, Network Ping 3-Target, License OS & Office, Storage, Remote ID. |
| **Android Core** | `android/app/src/main/java/` (11 file) | Source code Java agen PDA (PingMonitor, WifiRoamingTracker, BatteryHistory, CheckmkOutput, dll.). |

---
*Dikelola secara terpusat oleh **Tim IT Operations Nasional** — [itlicensehq25/checkmk-cabang](https://github.com/itlicensehq25/checkmk-cabang)*
