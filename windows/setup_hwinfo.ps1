# ==============================================================================
# setup_hwinfo.ps1 - Otomasi Konfigurasi HWiNFO64 untuk Sensor Kipas Motherboard
# Repositori : itlicensehq25/checkmk-cabang
# Digunakan untuk: PC Desktop Windows (MSI, ASUS, Gigabyte, ASRock) & Laptop
# ==============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

Write-Host "=== SETUP OTOMATIS HWINFO64 UNTUK CHECKMK SENSOR ===" -ForegroundColor Cyan

$hwinfoDir = "C:\Program Files\HWiNFO64"
$hwinfoExe = "$hwinfoDir\HWiNFO64.exe"
$hwinfoIni = "$hwinfoDir\HWiNFO64.INI"

# 1. Pastikan Direktori Ada
if (-not (Test-Path $hwinfoDir)) {
    New-Item -ItemType Directory -Path $hwinfoDir -Force | Out-Null
}

# 2. Cek apakah HWiNFO64 sudah terpasang
if (-not (Test-Path $hwinfoExe)) {
    Write-Host "[-] HWiNFO64 belum terpasang. Mencoba instalasi otomatis via winget..." -ForegroundColor Yellow
    try {
        & winget install --id REALiX.HWiNFO -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
    } catch {}
}

if (-not (Test-Path $hwinfoExe)) {
    Write-Host "[-] Mengunduh installer resmi HWiNFO64..." -ForegroundColor Yellow
    $zipPath = "$env:TEMP\hwinfo_portable.zip"
    $downloadUrl = "https://www.fosshub.com/HWiNFO.html?dwl=hwi_804.zip"
    try {
        # Fallback direct mirror
        $client = New-Object System.Net.WebClient
        $client.Headers.Add("User-Agent", "Mozilla/5.0")
        $client.DownloadFile("https://raw.githubusercontent.com/itlicensehq25/checkmk-cabang/main/windows/tools/hwi_804.zip", $zipPath)
        if ((Test-Path $zipPath) -and ((Get-Item $zipPath).Length -gt 100000)) {
            Expand-Archive -Path $zipPath -DestinationPath $hwinfoDir -Force
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# 3. Tulis Konfigurasi HWiNFO64.INI agar berjalan di background tanpa pop-up
Write-Host "[-] Mengonfigurasi HWiNFO64.INI (Sensors Only, Minimized, Autorun)..." -ForegroundColor Yellow
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

Set-Content -Path $hwinfoIni -Value $iniContent -Encoding ASCII

# 4. Aktifkan Registry EnableVSB pada Akun Pengguna Aktif & HKEY_USERS
Write-Host "[-] Mengaktifkan Registry VSB Sensor Sharing..." -ForegroundColor Yellow
$regSensors = "HKCU:\Software\HWiNFO64\Sensors"
if (-not (Test-Path $regSensors)) { New-Item -ItemType Registry -Path $regSensors -Force | Out-Null }
Set-ItemProperty -Path $regSensors -Name "EnableVSB" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $regSensors -Name "EnableLogging" -Value 1 -Type DWord -Force

# 5. Buat Task Scheduler agar HWiNFO64 selalu aktif otomatis saat user login
Write-Host "[-] Mendaftarkan Task Scheduler HWiNFO_AutoStart..." -ForegroundColor Yellow
$action = New-ScheduledTaskAction -Execute $hwinfoExe -Argument "-sensors"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Administrators" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 0)

Register-ScheduledTask -TaskName "HWiNFO_AutoStart" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "`n[SUKSES] Konfigurasi HWiNFO64 Selesai!" -ForegroundColor Green
Write-Host "Langkah Terakhir untuk Membaca Sensor Kipas:" -ForegroundColor Cyan
Write-Host "1. Buka aplikasi HWiNFO64 di layar desktop."
Write-Host "2. Klik ikon Gear (Configure Sensors) di kanan bawah layar sensor."
Write-Host "3. Pilih tab 'HWiNFO Gadget' (VSB)."
Write-Host "4. Centang 'Enable reporting to Gadget' lalu centang sensor 'CPU Fan' (Nuvoton)."
Write-Host "5. Klik OK. Checkmk akan otomatis membaca RPM kipas secara realtime!" -ForegroundColor Green
