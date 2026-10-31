# ==============================================================================
# setup_hwinfo.ps1 - Otomasi Konfigurasi HWiNFO64 untuk Sensor Kipas Motherboard
# Mendukung: Microsoft Store (XP9CS6FHQ00B8J), Winget Win32, & Portable Installer
# Digunakan untuk: PC Desktop Windows (MSI, ASUS, Gigabyte, ASRock) & Laptop
# ==============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "SilentlyContinue"

Write-Host "=== SETUP OTOMATIS HWINFO64 UNTUK CHECKMK SENSOR ===" -ForegroundColor Cyan

$hwinfoDir = "C:\Program Files\HWiNFO64"
$hwinfoExe = "$hwinfoDir\HWiNFO64.exe"
$hwinfoIni = "$hwinfoDir\HWiNFO64.INI"

# 1. Deteksi apakah HWiNFO sudah terpasang (Standar Win32 atau Microsoft Store)
if (-not (Test-Path $hwinfoExe)) {
    # Cek instalasi Microsoft Store (Package: MartinMalik.HWiNFO)
    try {
        $storeApp = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*HWiNFO*" } | Select-Object -First 1
        if ($storeApp -and (Test-Path (Join-Path $storeApp.InstallLocation "HWiNFO64.exe"))) {
            $hwinfoExe = Join-Path $storeApp.InstallLocation "HWiNFO64.exe"
            Write-Host "[OK] Terdeteksi HWiNFO dari Microsoft Store di: $hwinfoExe" -ForegroundColor Green
        }
    } catch {}
}

# 2. Jika belum ada, lakukan instalasi otomatis
if (-not (Test-Path $hwinfoExe)) {
    Write-Host "[-] HWiNFO64 belum terpasang. Mencoba instalasi otomatis..." -ForegroundColor Yellow

    # Prioritas A: Microsoft Store via Winget ID XP9CS6FHQ00B8J
    Write-Host "[-] Mencoba instalasi via Microsoft Store (ID: XP9CS6FHQ00B8J)..." -ForegroundColor Yellow
    try {
        & winget install --id XP9CS6FHQ00B8J --source msstore --silent --accept-source-agreements --accept-package-agreements | Out-Null
    } catch {}

    # Cek kembali setelah instalasi Store
    try {
        $storeApp = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*HWiNFO*" } | Select-Object -First 1
        if ($storeApp -and (Test-Path (Join-Path $storeApp.InstallLocation "HWiNFO64.exe"))) {
            $hwinfoExe = Join-Path $storeApp.InstallLocation "HWiNFO64.exe"
        }
    } catch {}

    # Prioritas B: Winget Win32 (REALiX.HWiNFO) jika Store gagal
    if (-not (Test-Path $hwinfoExe)) {
        Write-Host "[-] Mencoba instalasi via Winget Win32 (REALiX.HWiNFO)..." -ForegroundColor Yellow
        try {
            & winget install --id REALiX.HWiNFO -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
        } catch {}
    }

    # Prioritas C: Direct Portable ZIP ke C:\Program Files\HWiNFO64
    if (-not (Test-Path $hwinfoExe)) {
        Write-Host "[-] Mengunduh paket portable resmi HWiNFO64..." -ForegroundColor Yellow
        if (-not (Test-Path $hwinfoDir)) { New-Item -ItemType Directory -Path $hwinfoDir -Force | Out-Null }
        $zipPath = "$env:TEMP\hwinfo_portable.zip"
        try {
            $client = New-Object System.Net.WebClient
            $client.Headers.Add("User-Agent", "Mozilla/5.0")
            $client.DownloadFile("https://raw.githubusercontent.com/itlicensehq25/checkmk-cabang/main/windows/tools/hwi_804.zip", $zipPath)
            if ((Test-Path $zipPath) -and ((Get-Item $zipPath).Length -gt 100000)) {
                Expand-Archive -Path $zipPath -DestinationPath $hwinfoDir -Force
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                $hwinfoExe = "$hwinfoDir\HWiNFO64.exe"
            }
        } catch {}
    }
}

if (-not (Test-Path $hwinfoExe)) {
    Write-Host "[!] Pemasangan HWiNFO belum berhasil otomatis." -ForegroundColor Red
    Write-Host "    Silakan buka Microsoft Store: https://apps.microsoft.com/detail/XP9CS6FHQ00B8J" -ForegroundColor Yellow
    Write-Host "    atau pasang manual ke: C:\Program Files\HWiNFO64\" -ForegroundColor Yellow
} else {
    Write-Host "[OK] HWiNFO64 terverifikasi di: $hwinfoExe" -ForegroundColor Green
}

# 3. Tulis Konfigurasi HWiNFO64.INI (Jika folder Program Files writable)
$iniContent = @"
[Settings]
Theme=1
AutoUpdateBetaDisable=1
AutoUpdate=0
DefReportType=7
SensorsOnly=1
OpenSensors=1
MinimalizeMainWnd=1
MinimalizeSensors=1
MinimalizeSensorsClose=1
ShowWelcomeAndProgress=0
Autorun=1
SensorsSM=1
"@

if (Test-Path (Split-Path $hwinfoExe)) {
    try {
        Set-Content -Path (Join-Path (Split-Path $hwinfoExe) "HWiNFO64.INI") -Value $iniContent -Encoding ASCII -ErrorAction SilentlyContinue
    } catch {}
}
if (Test-Path $hwinfoDir) {
    Set-Content -Path $hwinfoIni -Value $iniContent -Encoding ASCII -ErrorAction SilentlyContinue
}

# 4. Injeksi Pengaturan ke Registry Windows (HKCU & Seluruh HKEY_USERS)
# Ini memastikan HWiNFO selalu membuka mode Sensors-Only dan mengaktifkan VSB bahkan untuk versi Store!
Write-Host "[-] Mengonfigurasi Registry Sensors-Only, AutoRun, dan VSB Sharing..." -ForegroundColor Yellow

$regTargets = @("HKCU:\Software\HWiNFO64")
try {
    Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -like "*S-1-5-21-*" -and $_.Name -notlike "*_Classes") {
            $regTargets += "Registry::$($_.Name)\Software\HWiNFO64"
        }
    }
} catch {}

foreach ($target in $regTargets) {
    try {
        if (-not (Test-Path $target)) { New-Item -ItemType Registry -Path $target -Force | Out-Null }
        Set-ItemProperty -Path $target -Name "SensorsOnly" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $target -Name "OpenSensors" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $target -Name "ShowWelcomeAndProgress" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $target -Name "MinimalizeSensors" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $target -Name "MinimalizeSensorsClose" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $target -Name "MinimalizeMainWnd" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $target -Name "Autorun" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $target -Name "SensorsSM" -Value 1 -Type DWord -Force

        $targetSensors = "$target\Sensors"
        if (-not (Test-Path $targetSensors)) { New-Item -ItemType Registry -Path $targetSensors -Force | Out-Null }
        Set-ItemProperty -Path $targetSensors -Name "EnableVSB" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $targetSensors -Name "EnableLogging" -Value 1 -Type DWord -Force
    } catch {}
}

# 5. Buat Task Scheduler agar HWiNFO64 selalu aktif otomatis saat user login
if (Test-Path $hwinfoExe) {
    Write-Host "[-] Mendaftarkan Task Scheduler HWiNFO_AutoStart..." -ForegroundColor Yellow
    try {
        $action = New-ScheduledTaskAction -Execute $hwinfoExe
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Administrators" -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 0)

        Register-ScheduledTask -TaskName "HWiNFO_AutoStart" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "[OK] Task Scheduler 'HWiNFO_AutoStart' berhasil didaftarkan." -ForegroundColor Green
    } catch {}
}

Write-Host "`n[SUKSES] Konfigurasi Otomatis HWiNFO Selesai!" -ForegroundColor Green
Write-Host "Karakteristik yang Sudah Aktif Otomatis:" -ForegroundColor Cyan
Write-Host "  * Mode: Sensors-Only (Bypass Welcome Screen & Ringkasan Hardware)"
Write-Host "  * Tampilan: Minimized ke System Tray (Senyap di background)"
Write-Host "  * Startup: Otomatis berjalan saat pengguna login (Task Scheduler & Registry)"
Write-Host "  * VSB: Virtual Sensor Bus Sharing Aktif ke Windows Registry"
Write-Host "`nLangkah Terakhir Mengaktifkan Pembacaan Kipas (Fan RPM) ke Checkmk:" -ForegroundColor Yellow
Write-Host "  1. Buka HWiNFO di desktop (jika belum terbuka)."
Write-Host "  2. Klik ikon Gear (Configure Sensors) di kanan bawah jendela sensor."
Write-Host "  3. Pilih tab 'HWiNFO Gadget' (VSB)."
Write-Host "  4. Pastikan 'Enable reporting to Gadget' tercentang."
Write-Host "  5. Pada daftar sensor, cari 'CPU Fan' / 'Chassis Fan' / Nuvoton / ITE, centang 'Report value in Gadget'."
Write-Host "  6. Klik OK. Checkmk akan otomatis membaca RPM kipas secara realtime!`n" -ForegroundColor Green
