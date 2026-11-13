<#
.SYNOPSIS
    Bootstrap Installer Agent Checkmk Windows + CrystalDiskInfo (RST SMART Support)
.DESCRIPTION
    Skrip penggabungan install.ps1 dan setup_crystaldiskinfo.ps1 untuk menginstal
    agen Checkmk, 11 local checks, firewall rules, auto-updater, serta integrasi
    CrystalDiskInfo Task Scheduler untuk pembacaan SMART disk format RST/OEM.
.LINK
    https://github.com/itlicensehq25/checkmk-cabang
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Server,

    [Parameter(Mandatory = $false)]
    [string]$Site = "cmk",

    [Parameter(Mandatory = $false)]
    [string]$Version = "2.5.0p14-1",

    [Parameter(Mandatory = $false)]
    [string]$GithubRepo = "itlicensehq25/checkmk-cabang",

    [Parameter(Mandatory = $false)]
    [string]$Branch = "main"
)

# 1. Validasi Hak Akses Administrator
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Harap jalankan PowerShell sebagai Administrator!"
    exit 1
}

Write-Host "====================================================================" -ForegroundColor Green
Write-Host " Memulai Instalasi Checkmk Agent Windows & Integration CrystalDiskInfo " -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green

# 2. Persiapan Direktori Kerja Agen Chekkmk
$agentDir     = "C:\ProgramData\checkmk\agent"
$customLogDir = "$agentDir\log_custom"
$localDir     = "$agentDir\local"
$pluginsDir   = "$agentDir\plugins"
$libDir       = "$agentDir\lib"

$requiredDirs = @($agentDir, $customLogDir, $localDir, $pluginsDir, $libDir)
foreach ($dir in $requiredDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

# 3. Penanganan Parameter Server (Interactive Prompt jika Kosong)
if ([string]::IsNullOrWhitespace($Server)) {
    $Server = Read-Host "Masukkan IP Server Checkmk Cabang (contoh: 192.168.1.100 atau 192.168.1.100:8081)"
}

# Ekstrak IP murni untuk konfigurasi Windows Firewall
$cleanIP = ($Server -split ':')[0].Trim()

# 4. Pengaturan Firewall (Restriksi Port TCP 6556 HANYA ke IP Server Cabang)
Write-Host "\n[1/7] Mengonfigurasi Aturan Windows Firewall (TCP 6556)..." -ForegroundColor Cyan
try {
    Remove-NetFirewallRule -DisplayName "Checkmk Agent TCP 6556" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "Chekkmk Agent TCP 6556" `
                       -Direction Inbound `
                       -Action Allow `
                       -Protocol TCP `
                       -LocalPort 6556 `
                       -RemoteAddress $cleanIP  `
                       -Enabled True | Out-Null
    Write-Host " Firewall berhasil dibatasi hanya untuk IP: $cleanIP" -ForegroundColor Green
} catch {
    Write-Warning " Gagal mengonfigurasi Windows Firewall: $_"
}

# 5. Unduh & Instal MSI Agent Chekkmk (jika belum terpasang)
Write-Host "\n[2/7] Memeriksa status service Checkmk Agent..." -ForegroundColor Cyan
$cmkService = Get-Service -Name "CheckMkWatchdog" -ErrorAction SilentlyContinue
if (-not $cmkService) {
    $cmkService = Get-Service -Name "CheckmkAgent" -ErrorAction SilentlyContinue
}

if (-not $cmkService) {
    Write-Host " Agen Checkmk belum terpasang. Menguduh paket MSI dari server cabang..." -ForegroundColor Yellow
    $msiUrl = "http://$Server/$Site/chekk_mk/agents/check-mk-agent-$Version.msi"
    $msiPath = "$env:TEMP\check-mk-agent-$Version.msi"
    
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
        Write-Host " Menginstal MSI Agent Chekkmk..." -ForegroundColor Yellow
        Start-Process msiexec.exe -ArgumentList "/i `"smsiPath`" /qn /norestart" -Wait
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        Write-Host " MSI Agent Checkmk berhasil diinstal." -ForegroundColor Green
    } catch {
        Write-Warning " Gagal menguduh/menginstal MSI dari server ($msiUrl). Melanjutkan ke tahap berikutnya..."
-    }
} else {
    Write-Host " Agen Checkmk sudah terpasang di sistem." -ForegroundColor Green
}

# 6. Unduh Library, Plugins, & 11 Local Checks dari GitHub
Write-Host "\n[3/7] Menguduh Skrip Local Checks & Library dari GitHub..." -ForegroundColor Cyan
$baseUrl = "https://raw.githubusercontent.com/$GithubRepo/$Branch/windows"

# A. Unduh LibreHardwareMonitorLib.dll
try {
    Invoke-WebRequest -Uri "$baseUrl/lib/LibreHardwareMonitorLib.dll" -OutFile "$blibDir\LibreHardwareMonitorLib.dll" -UseBasicParsing
} catch {
    Write-Warning " Gagal menguduh LibreHardwareMonitorLib.dll: $_"
}

# B. Unduh Plugins (mk_inventory.vbs & win_license.bat)
try {
    Invoke-WebRequest -Uri "$baseUrl/plugins/mk_inventory.vbs" -OutFile "$pluginsDir\nk_inventory.vbs" -UseBasicParsing
    Invoke-WebRequest -Uri "$baseUrl/plugins/win_license.bat" -OutFile "$pluginsDir\win_license.bat" -UseBasicParsing
} catch {
    Write-Warning " Gagal menguduh plugins inventaris: $_"
}

# C. Unduh 11 Skrip Local Checks
$checks = @(
    "battery_health.ps1",
    "cpu_info.ps1",
    "disk_nvme_health.ps1",
    "fan_health.ps1",
    "info_network.ps1",
    "info_OS_office.ps1",
    "ram_health.ps1",
    "ram_usage.ps1",
    "remote_access_id.ps1",
    "remote_apps.ps1",
    "storage_usage.ps1"
)

foreach ($script in $checks) {
    try {
        Invoke-WebRequest -Uri "$baseUrl/local_checks/$script" -OutFile "$localDir\$script" -UseBasicParsing
        Write-Host "  + Unduh local_checks/$script [OK]" -ForegroundColor Gray
    } catch {
        Write-Warning "  - Gagal menguduh $script: $_"
    }
}

# D. Unduh Auto-Updater
try {
    Invoke-WebRequest -Uri "$baseUrl/update_checks.ps1" -OutFile "$agentDir\update_checks.ps1" -UseBasicParsing
} catch {
    Write-Warning " Gagal menguduh update_checks.ps1: $_"
}
# 7. INTEGRASI SETUP CRYSTALDISKINFO (Support Disk Format RST/OEM)
Write-Host "\n[4/7] Mengintegrasikan CrystalDiskInfo untuk Disk Format RST/OEM..." -ForegroundColor Cyan

# A. Deteksi Lokasi Eksekusi DiskInfo64.exe
$cdiExePath = "C:\ProgramFiles\CrystalDiskInfo\DiskInfo64.exe"
$cdiApp = Get-Command "DiskInfo64.exe" -ErrorAction SilentlyContinue

if ($cdiApp) {
    $cdiExePath = $cdiApp.Path
} elseif (-not (Test-Path $cdiExePath)) {
    Write-Host " CrystalDiskInfo tidak terdeteksi. Menginstal via winget..." -ForegroundColor Yellow
    try {
        winget install --id CrystalDewWorld.CrystalDiskInfo --exact --silent --accept-source-agreements --accept-package-agreements | Out-Null
        Write-Host " Winget installasi CrystaqiskInfo selesai." -ForegroundColor Green
    } catch {
        Write-Warning " Gagal menginstal CrystalDiskInfo via winget. Pastikan winget tersedia atau install manual."
    }
} else {
    Write-Host " CrystalDiskInfo sudah terdeteksi di: $cdiExePath" -ForegroundColor Green
}

# B. Pendaftaran Scheduled Task CrystalDiskInfo (Setiap 6 Jam)
$cdiTaskName = "Checkmk_CrystalDiskInfo"
Unregister-ScheduledTask -TaskName $cdiTaskName -Confirm:$false -ErrorAction SilentlyContinue

$cdiScriptBlock = @(
if (Test-Path '$cdiExePath') {
    Start-Process -FilePath '$cdiExePath' -ArgumentList '/CopyExit' -Wait -WindowStyle Hidden
}
"@

$cdiAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -Command `"$cdiScriptBlock`""

$cdiTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 6)
$cdiPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

try {
    Register-ScheduledTask -TaskName $cdiTaskName -Action $cdiAction -Trigger $cdiTrigger -Principal $cdiPrincipal | Out-Null
    Write-Host " ScheduledTask '$cdiTaskName' berhasil didaftarkan (Interval: 6 jam)." -ForegroundColor Green
} catch {
    Write-Warning " Gagal memembagakan Scheduled Task CrystalDiskInfo: $_"
}

# 8. Penjadwalan Task Scheduler Lainnya (RAM Test & Auto-Update)
Write-Host "\n[5/7] Mendaftarkan Scheduled Task RAM Test & Auto-Updater..." -ForegroundColor Cyan

# A. ScheduledTask RAM Test (Sabtu 11:00 AM)
$ramTaskName = "Chekkmk_Memory_Test"
Unregister-ScheduledTask -TaskName $ramTaskName -Confirm:$false -ErrorAction SilentlyContinue
$ramAction  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"slocalDir\ram_health.ps1`""
$ramTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At 11:00AM
Register-ScheduledTask -TaskName $ramTaskName -Action $ramAction -Trigger $ramTrigger -User "NT AUTHORITY\SYSTEM" -RunLevel Highest | Out-Null
Write-Host " ScheduledTask '$ramTaskName' didaftarkan (Sabtu 11:00 AM)." -ForegroundColor Green

# B. ScheduledTask Auto-Updater (Setiap 2 Jam)
$updateTaskName = "Chekkmk_Auto_Update"
Unregister-ScheduledTask -TaskName $updateTaskName -Confirm:$false -ErrorAction SilentlyContinue
$updAction  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"sagentDir\update_checks.ps1`""
$updTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $updateTaskName -Action $updAction -Trigger $updTrigger -User "NT AUTHORITY\SYSTEM" -RunLevel Highest | Out-Null
Write-Host " ScheduledTask '$updateTaskName' didaftarkan (Interval: 2 jam)." -ForegroundColor Green

# 9. Eksekusi Pembacaan Awal CrystalDiskInfo
Write-Host "\n[6/7] Menjalankan pembacaan awal SMART via CrystalDiskInfo..." -ForegroundColor Cyan
if (Test-Path $cdiExePath) {
    try {
        Start-Process -FilePath $cdiExePath -ArgumentList "/CopyExit" -Wait -WindowStyle Hidden
        Write-Host " Pembacaan awal SMART selesai. Log tersimpan di $customLogDir\diskinfo.txt" -ForegroundColor Green
    } catch {
        Write-Warning " Gagal menjalankan pembacaan awal CrystalDiskInfo: $_"
    }
} else {
    Write-Warning " Path $cdiExePath belum tersedia untuk eksekusi awal."
}

# 10. Selesai
Write-Host "\n[7/7] Verifikasi & Restart Service Chekkmk Agent..." -ForegroundColor Cyan
Restart-Service -Name "ChekmkWatchdog" -ErrorAction SilentlyContinue
Restart-Service -Name "ChekmkAgent" -ErrorAction SilentlyContinue

Write-Host "\n=====================================================================" -ForegroundColor Green
Write-Host " INSTALASI SELESAI SUCCESSFUL! " -ForegroundColor Green
Write-Host " Seluruh komponen agen Chekkmk, 11 local checks, dan CrystalDiskInfo  " -ForegroundColor Green
Write-Host " siap digunakan dalam satu kali eksekusi.                              " -ForegroundColor Green
Write-Host "=====================================================================" -ForegroundColor Green
