# cmkagent v1.3.7 - Stable Release

> **Catatan Rilis v1.3.7 Stable:** 
> - **Monitoring Ping 3-Baris Terpisah (Core, Internet, & Gateway Cabang):** Menjalankan ping 4x setiap 1 menit ke **3 target**:
>   1. `Ping_192.168.122.10` (Core / Local Server)
>   2. `Ping_8.8.8.8` (Internet / Google DNS)
>   3. `Ping_Gateway` (**Gateway Kantor Cabang** yang diisi manual di Settings PDA, dengan tombol *Auto-Detect* dari DHCP Wi-Fi).
>   Hasil disimpan ke berkas log lokal di PDA (`ping_history.log`) dengan **retensi otomatis 30 hari ala CCTV** (hari ke-31+ otomatis terhapus), dan dikirim ke server Checkmk setiap 1 jam dalam **3 baris service terpisah**.
> - **Penyatuan Penuh Menu Baterai ke 1 Baris (`Health_Battery`):** Menggabungkan seluruh metrik baterai (Level, Status, Real Health, Cycles, Full Capacity, Design Spec, Temperature, Voltage, Current) menjadi **1 baris service Checkmk tunggal (`Health_Battery`)** dengan multi-perfdata (`battery_level`, `battery_health`, `battery_cycles`, `battery_temp`, `battery_voltage`, `battery_current`).
> - **Logika Kesehatan 2946 mAh @ 100% & Perbaikan Pembacaan Siklus (`Cycles`):** Mengkalibrasi kesehatan baterai menggunakan kapasitas penuh hardware saat charge 100% di **2946 mAh** (`Design Spec : 4800 mAh`), serta memperbaiki penghitung siklus charging (`Cycles`) dengan pelacakan sesi & delta muatan kontinu (`BatteryHistory` + `BroadcastReceiver` + timer 1 menit).
> - **Deteksi Roaming Access Point Wi-Fi (`WiFi_Status` - UniFi & Multi-AP):** Menangkap perpindahan Access Point (roaming BSSID, identifikasi vendor OUI UniFi/Ubiquiti termasuk virtual BSSID, Band 2.4GHz/5GHz & Nomor Kanal, riwayat perpindahan AP sebelumnya ke AP aktif, hitungan roam 1 jam terakhir & total, serta log permanen `wifi_roaming.log`).
> - **Pembatasan Firewall IP Server Checkmk Cabang:** Menolak konfigurasi kosong pada port TCP/6556 dan mewajibkan pengisian manual **IP Server Checkmk Cabang** saat setting pertama kali di PDA (tanpa menampilkan IP default bawaan; mendukung input IP saja maupun `IP:Port` seperti `:80`, `:8080`, `:8081`).

Agen monitoring Android native untuk Checkmk Community.

- **Package:** `com.bcp.checkmkagent`
- **Nama Aplikasi:** `cmkagent`
- **Versi:** `1.3.7` (Stable Release)
- **Target SDK:** Android SDK 35 (Compile), Android SDK 33 (Target), Android SDK 26 (Minimum)
- **Lingkungan Build:** Java 17 + Gradle 8.9
- **Transport Utama:** Checkmk PULL melalui TCP/6556 (Terproteksi Whitelist IP Server Cabang)
- **Transport Cadangan:** HTTP/HTTPS PUSH ke receiver cache
- **Target Armada Produksi:** Newland MT93 (`Full Capacity @ 100% = 2946 mAh`, `Design Spec = 4800 mAh`) & Android Generic

---

## 1. Arsitektur Agen & Aliran Data

    +-----------------------------------------------------------------------------------+
    |                            cmkagent v1.3.7 Architecture                           |
    +-----------------------------------------------------------------------------------+
    |  [Hardware & Network Layer: Newland MT93 / Android OS]                            |
    |        │                                                                          |
    |        ├──> Kernel Sysfs + BatteryManager + BroadcastReceiver (Charge & Cycles)   |
    |        ├──> ConnectivityManager + WifiManager + Roaming Tracker (BSSID/UniFi/Ch)  |
    |        ├──> Background 1-Minute Scheduler (4x Ping to Local, Net, & Gateway)      |
    |        └──> Linux StatFs & ActivityManager (Storage & RAM Usage)                  |
    |                                                                                   |
    |  [Processing & Local Persistence Engine]                                          |
    |        │                                                                          |
    |        ├──> BatteryHistory.java : Kalibrasi 2946 mAh @ 100% & Siklus Charging     |
    |        ├──> PingMonitor.java    : 3-Target Buffer 60m + Log 30 Hari CCTV          |
    |        └──> WifiRoamingTracker  : Deteksi Handoff AP + Log wifi_roaming.log       |
    |                                                                                   |
    |  [Checkmk Formatter: CheckmkOutput.java]                                          |
    |        │                                                                          |
    |        ├──> Real-time (60s) : Agent_Status, Health_Battery (1 Baris),             |
    |        │                      RAM_Usage, WiFi_Status (AP Roaming), Android_Info   |
    |        └──> Cached Service  : Ping_192.168.122.10 (1h), Ping_8.8.8.8 (1h),        |
    |                               Ping_Gateway (1h), Transport_Status (3h),           |
    |                               Storage_Usage (24h)                                 |
    +-----------------------------------------------------------------------------------+

---

## 2. Logika Pemantauan & Perhitungan Metrik

### A. Metrik Baterai Terpadu 1 Baris (`Health_Battery`)

Seluruh informasi baterai disatukan ke dalam **1 baris service Checkmk (`Health_Battery`)** agar ringkas dan mudah dipantau:
1. **Kapasitas Penuh @ 100% (`2946 mAh`) & Spesifikasi Pabrik (`4800 mAh`):**  
   Pada perangkat Newland MT93, pembacaan coulomb counter penuh ketika 100% charge berada di **2.946 mAh** (`Full Capacity : 2946 mAh`) dengan spesifikasi desain pabrik **4.800 mAh** (`Design Spec : 4800 mAh`).
2. **Perbaikan Pembacaan Siklus Pengisian (`Cycles`):**  
   Pelacakan muatan kontinu via `BatteryHistory` menangkap kenaikan energi across sleep and cradle docking, menghitung akumulasi charged mAh dan sesi charging nyata sehingga `Cycles` selalu akurat bertambah.

```text
0 "Health_Battery" battery_level=100;30;15;0;100|battery_health=100.0;80;65;0;100|battery_cycles=4;500;800;0|battery_temp=31.0;42;48|battery_voltage=4.349|battery_current=-180.0 Level : 100% (Full, AC) | Health : 100.0% (OK) | Cycles : 4 | Full Capacity : 2946 mAh | Design Spec : 4800 mAh | Temp : 31.0 C | Voltage : 4.35 V | Current : -180.0 mA | Calc : Full Capacity @ 100% Charge (2946 mAh)
```

---

### B. Monitoring Ping 3-Baris Setiap 1 Menit & Laporan 1 Jam (`Ping_192.168.122.10`, `Ping_8.8.8.8`, `Ping_Gateway`)

1. **Eksekusi 3 Target Setiap 1 Menit:**
   - Scheduler latar belakang (`PingMonitor`) menjalankan **4x ping setiap 1 menit** ke **3 target**:
     - `192.168.122.10` (Core / Local Server)
     - `8.8.8.8` (Internet / Google DNS)
     - **IP Gateway Kantor Cabang** (diinput manual di Settings PDA atau dideteksi via tombol *Auto-Detect*)
2. **Penyimpanan Lokal & Retensi 30 Hari (Mirip Rekaman CCTV):**
   - Hasil setiap menit dikumpulkan di memori/storage PDA hingga mencapai durasi **1 jam (60 sampel = 240 paket ping per target)**.
   - Seluruh log per menit dan ringkasan per jam disimpan di memori internal PDA pada berkas **`ping_history.log`** dengan **retensi otomatis 30 hari** (`LOG_RETENTION_DAYS = 30`). Begitu memasuki **hari ke-31 dan seterusnya**, log lama yang berumur lebih dari 30 hari otomatis dihapus seperti sistem rekaman CCTV, dan dapat dilihat langsung dari tombol **VIEW PING LOG** di aplikasi.
3. **Pengiriman ke Server Checkmk Setiap 1 Jam (3 Baris Terpisah):**
   - Menggunakan mekanisme `<<<local:cached(...,3600):sep(0)>>>`, laporan rangkuman 1 jam dikirim ke Checkmk dalam **3 baris service terpisah**:
     - **`Ping_192.168.122.10`** (Baris 1: rta, pl, jitter, max/min RTT, jumlah sampel 1 jam)
     - **`Ping_8.8.8.8`** (Baris 2: rta, pl, jitter, max/min RTT, jumlah sampel 1 jam)
     - **`Ping_Gateway`** (Baris 3: rta, pl, jitter, max/min RTT ke Gateway Cabang)

---

### C. Deteksi Roaming Access Point Wi-Fi (`WiFi_Status`)

Memantau perpindahan Access Point (UniFi maupun AP multi-vendor lainnya) secara real-time saat PDA dibawa berkeliling gudang/cabang:
- Melacak alamat fisik **BSSID** Access Point aktif, mengenali vendor **UniFi / Ubiquiti** (termasuk virtual BSSID multi-SSID UniFi), memetakan frekuensi ke **Band & Channel**, menghitung jumlah roam 1 jam terakhir & total, serta mencatat handoff ke `wifi_roaming.log`.

---

### D. Ringkasan Seluruh Metrik & Strategi Caching (`v1.3.7`)

| Nama Service Checkmk | Tipe Eksekusi | Interval Cache | Ambang Batas (Threshold) & Keterangan |
| :--- | :--- | :--- | :--- |
| **`Agent_Status`** | Real-time | Setiap polling (60 dtk) | Statistik koneksi masuk/ditolak, durasi pull terakhir, dan whitelist IP server cabang. |
| **`Health_Battery`** | Real-time | Setiap polling (60 dtk) | **1 Baris Terpadu:** Level (%), Status, Health (%) berbasis 2946 mAh @ 100%, Cycles, Full Capacity (2946 mAh), Design Spec (4800 mAh), Suhu (C), Tegangan (V), dan Arus (mA). |
| **`RAM_Usage`** | Real-time | Setiap polling (60 dtk) | Pemakaian memori RAM via ActivityManager. **WARN** >= 85%, **CRIT** >= 95%. |
| **`WiFi_Status`** | Real-time | Setiap polling (60 dtk) | RSSI (dBm), SSID, BSSID & Vendor AP (UniFi), Band/Channel, Roam Count (1h & Total), Last Roam transition, Link Speed, dan IP lokal. |
| **`Android_Info`** | Real-time | Setiap polling (60 dtk) | Model perangkat, manufaktur, versi OS Android, level SDK, profil, dan uptime sistem. |
| **`Ping_192.168.122.10`** | Caching + Log HP | **1 Jam** (3600 dtk) | Ping 4x setiap 1 menit ke `192.168.122.10` (240 paket/jam), log 30 hari di `ping_history.log`. |
| **`Ping_8.8.8.8`** | Caching + Log HP | **1 Jam** (3600 dtk) | Ping 4x setiap 1 menit ke `8.8.8.8` (240 paket/jam), log 30 hari di `ping_history.log`. |
| **`Ping_Gateway`** | Caching + Log HP | **1 Jam** (3600 dtk) | Ping 4x setiap 1 menit ke **Gateway Kantor Cabang** (240 paket/jam), log 30 hari di `ping_history.log`. |
| **`Transport_Status`** | Caching | **3 Jam** (10800 dtk) | Status jalur cadangan PUSH HTTP(S), jumlah sukses/gagal, dan status kode HTTP. |
| **`Storage_Usage`** | Caching | **24 Jam** (86400 dtk) | Pemakaian partisi internal `/data` via StatFs. **WARN** >= 85%, **CRIT** >= 95%. |

---

## 3. Pengaturan IP Server & Gateway Cabang pada PDA

Saat setting pertama kali di PDA pada kartu **SETTINGS**:
1. **IP Server Checkmk Cabang:**
   - Diisi manual dengan IP Server Checkmk cabang yang bersangkutan.
   - Mendukung format IP saja (`192.168.x.x`) maupun dengan port web cabang (`192.168.x.x:8081`, `:8080`, `:80`).
2. **IP Gateway Cabang:**
   - Diisi manual dengan alamat IP Gateway Router kantor cabang (contoh: `192.168.55.1` atau `192.168.122.1`).
   - Tersedia tombol **AUTO-DETECT GATEWAY DARI WI-FI** untuk mendeteksi default gateway secara otomatis dari koneksi DHCP Wi-Fi yang sedang aktif.

---

**Dibuat oleh IT OPS HQEJBNT**
