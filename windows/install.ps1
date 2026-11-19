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

# 1. Validasi Hak Akses Administrator & Set Execution Policy
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Harap jalankan PowerShell sebagai Administrator!"
    exit 1
}

# Atur ExecutionPolicy sistem agar local checks .ps1 dapat dijalankan oleh Service Checkmk Agent
try {
    Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction SilentlyContinue
} catch {}

Write-Host "====================================================================" -ForegroundColor Green
Write-Host " Memulai Instalasi Checkmk Agent Windows & Integration CrystalDiskInfo " -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green

# 2. Persiapan Direktori Kerja Agen Checkmk
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

# 3. Penanganan Parameter Server, Site ID, & Version (Interactive Prompt jika Server Kosong)
if ([string]::IsNullOrWhitespace($Server)) {
    $Server = Read-Host "Masukkan IP Server & Port Checkmk Cabang (contoh: 192.168.43.188:8080)"
    
    $inputSite = Read-Host "Masukkan Site ID Checkmk [Default: $Site]"
    if (-not [string]::IsNullOrWhitespace($inputSite)) {
        $Site = $inputSite.Trim()
    }
    
    $inputVersion = Read-Host "Masukkan Versi Checkmk Agent (contoh: 2.5.0p14-1) [Default: $Version]"
    if (-not [string]::IsNullOrWhitespace($inputVersion)) {
        $Version = $inputVersion.Trim()
    }
}

# Pastikan parameter yang dimasukkan bersih dari skema http(s):// dan spasi
$Server  = ($Server -replace '^https?://', '').Trim().TrimEnd('/')
$Site    = $Site.Trim().Trim('/')
$Version = $Version.Trim()

# Ekstrak IP murni untuk konfigurasi Windows Firewall
$cleanIP = ($Server -split ':')[0].Trim()

Write-Host "`n[Informasi Target Server]" -ForegroundColor Yellow
Write-Host "  - Server IP   : $Server" -ForegroundColor Yellow
Write-Host "  - Site ID     : $Site" -ForegroundColor Yellow
Write-Host "  - Agent Ver   : $Version" -ForegroundColor Yellow

# 4. Pengaturan Firewall (Restriksi Port TCP 6556 HANYA ke IP Server Cabang)
Write-Host "`n[1/7] Mengonfigurasi Aturan Windows Firewall (TCP 6556)..." -ForegroundColor Cyan
try {
    Remove-NetFirewallRule -DisplayName "Checkmk Agent TCP 6556" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "Checkmk Agent TCP 6556" `
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

# 5. Unduh & Instal MSI Agent Checkmk (jika belum terpasang)
Write-Host "`n[2/7] Memeriksa status service Checkmk Agent..." -ForegroundColor Cyan
$cmkService = Get-Service -Name "CheckMkWatchdog" -ErrorAction SilentlyContinue
if (-not $cmkService) {
    $cmkService = Get-Service -Name "CheckmkAgent" -ErrorAction SilentlyContinue
}

if (-not $cmkService) {
    Write-Host " Agen Checkmk belum terpasang. Mengunduh paket MSI dari server cabang..." -ForegroundColor Yellow
    
    # Bypass SSL validation untuk self-signed certificate & atur protokol TLS
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
    } catch {}
    
    $msiPath = "$env:TEMP\check-mk-agent-installer.msi"
    if (Test-Path $msiPath) { Remove-Item $msiPath -Force -ErrorAction SilentlyContinue }
    
    # Buat varian versi tanpa release suffix (misal: '2.5.0p14-1' -> '2.5.0p14')
    $cleanVersion = $Version -replace '-.*$', ''
    
    # Daftar kandidat URL unduhan MSI (Mendukung subfolder /windows/, versi spesifik, & HTTPS)
    $msiCandidates = @(
        "http://$Server/$Site/check_mk/agents/windows/check_mk_agent.msi",
        "http://$Server/$Site/check_mk/agents/windows/check-mk-agent-$Version.msi",
        "http://$Server/$Site/check_mk/agents/windows/check-mk-agent-$cleanVersion.msi",
        "http://$Server/$Site/check_mk/agents/check-mk-agent-$Version.msi",
        "http://$Server/$Site/check_mk/agents/check-mk-agent-$cleanVersion.msi",
        "http://$Server/$Site/check_mk/agents/check_mk_agent.msi",
        "https://$Server/$Site/check_mk/agents/windows/check_mk_agent.msi",
        "https://$Server/$Site/check_mk/agents/windows/check-mk-agent-$Version.msi",
        "https://$Server/$Site/check_mk/agents/windows/check-mk-agent-$cleanVersion.msi",
        "https://$Server/$Site/check_mk/agents/check-mk-agent-$Version.msi",
        "https://$Server/$Site/check_mk/agents/check-mk-agent-$cleanVersion.msi",
        "https://$Server/$Site/check_mk/agents/check_mk_agent.msi"
    )
    
    $msiDownloaded = $false
    $successfulUrl = ""
    
    foreach ($url in $msiCandidates) {
        try {
            Write-Host "  [-] Mencoba unduh dari: $url ..." -ForegroundColor Gray
            Invoke-WebRequest -Uri $url -OutFile $msiPath -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            
            # Validasi file terunduh dan ukuran file > 500 KB (memastikan paket installer valid, bukan HTML error 404/500)
            if ((Test-Path $msiPath) -and ((Get-Item $msiPath).Length -gt 500000)) {
                $msiDownloaded = $true
                $successfulUrl = $url
                Write-Host "  [+] Berhasil mengunduh paket MSI dari: $url" -ForegroundColor Green
                break
            } else {
                if (Test-Path $msiPath) { Remove-Item $msiPath -Force -ErrorAction SilentlyContinue }
            }
        } catch {
            Write-Host "      (Kandidat tidak dapat dijangkau: $($_.Exception.Message))" -ForegroundColor DarkGray
        }
    }
    
    if ($msiDownloaded) {
        try {
            Write-Host " Menginstal MSI Agent Checkmk..." -ForegroundColor Yellow
            $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -PassThru
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                Write-Host " MSI Agent Checkmk berhasil diinstal." -ForegroundColor Green
            } else {
                Write-Warning " Instalasi msiexec selesai dengan exit code: $($proc.ExitCode)"
            }
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warning " Gagal menjalankan msiexec: $_"
        }
    } else {
        Write-Warning " Gagal mengunduh paket MSI dari seluruh kandidat URL server ($Server)."
        Write-Warning " Petunjuk Diagnosa Pembacaan Server:"
        Write-Warning "  1. Pastikan IP dan Port Server sudah sesuai (contoh: 192.168.43.188 atau 192.168.43.188:8080)."
        Write-Warning "  2. Pastikan Site ID '$Site' dan versi agent '$Version' terdaftar di server."
        Write-Warning "  3. Jika installer MSI dipasang secara manual, jalankan kembali skrip ini untuk mengonfigurasi local checks & scheduler."
        Write-Warning " Melanjutkan ke tahap berikutnya..."
    }
} else {
    Write-Host " Agen Checkmk sudah terpasang di sistem." -ForegroundColor Green
}

# 6. Unduh Library, Plugins, & 11 Local Checks dari GitHub
Write-Host "`n[3/7] Mengunduh Skrip Local Checks & Library dari GitHub..." -ForegroundColor Cyan
$baseUrl = "https://raw.githubusercontent.com/$GithubRepo/$Branch/windows"

# A. Unduh LibreHardwareMonitorLib.dll
try {
    Invoke-WebRequest -Uri "$baseUrl/lib/LibreHardwareMonitorLib.dll" -OutFile "$libDir\LibreHardwareMonitorLib.dll" -UseBasicParsing
} catch {
    Write-Warning " Gagal mengunduh LibreHardwareMonitorLib.dll: $_"
}

# B. Unduh Plugins (mk_inventory.vbs & win_license.bat)
try {
    Invoke-WebRequest -Uri "$baseUrl/plugins/mk_inventory.vbs" -OutFile "$pluginsDir\mk_inventory.vbs" -UseBasicParsing
    Invoke-WebRequest -Uri "$baseUrl/plugins/win_license.bat" -OutFile "$pluginsDir\win_license.bat" -UseBasicParsing
} catch {
    Write-Warning " Gagal mengunduh plugins inventaris: $_"
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
        Write-Warning "  - Gagal mengunduh ${script}: $_"
    }
}

# D. Unduh Auto-Updater
try {
    Invoke-WebRequest -Uri "$baseUrl/update_checks.ps1" -OutFile "$agentDir\update_checks.ps1" -UseBasicParsing
} catch {
    Write-Warning " Gagal mengunduh update_checks.ps1: $_"
}
# 7. INTEGRASI SETUP CRYSTALDISKINFO (Support Disk Format RST/OEM)
Write-Host "`n[4/7] Mengintegrasikan CrystalDiskInfo untuk Disk Format RST/OEM..." -ForegroundColor Cyan

# A. Membuat skrip helper setup_crystaldiskinfo.ps1 di direktori agent
$setupCdiPath = "$agentDir\setup_crystaldiskinfo.ps1"
$setupCdiContent = @'
# Skrip otomatisasi pembacaan SMART CrystalDiskInfo
$customLogDir = "C:\ProgramData\checkmk\agent\log_custom"
if (-not (Test-Path $customLogDir)) {
    New-Item -Path $customLogDir -ItemType Directory -Force | Out-Null
}

$cdiPaths = @(
    "C:\Program Files\CrystalDiskInfo\DiskInfo64.exe",
    "C:\Program Files (x86)\CrystalDiskInfo\DiskInfo64.exe"
)
$cdiApp = Get-Command "DiskInfo64.exe" -ErrorAction SilentlyContinue
if ($cdiApp) { $cdiPaths = @($cdiApp.Path) + $cdiPaths }

$cdiExe = $cdiPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $cdiExe) {
    try {
        winget install --id CrystalDewWorld.CrystalDiskInfo --exact --silent --accept-source-agreements --accept-package-agreements | Out-Null
        $cdiExe = $cdiPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    } catch {}
}

if ($cdiExe) {
    $cdiDir = Split-Path $cdiExe -Parent
    
    # Jalankan DiskInfo64.exe dengan WorkingDirectory agar file DiskInfo.txt konsisten terbuat
    Start-Process -FilePath $cdiExe -ArgumentList "/CopyExit" -WorkingDirectory $cdiDir -Wait -WindowStyle Hidden
    Start-Sleep -Seconds 2
    
    # Cari berkas DiskInfo.txt di beberapa lokasi potensial keluaran CrystalDiskInfo
    $candidateLogs = @(
        (Join-Path $cdiDir "DiskInfo.txt"),
        "DiskInfo.txt",
        "C:\Windows\System32\DiskInfo.txt",
        "$env:TEMP\DiskInfo.txt",
        "C:\ProgramData\checkmk\agent\DiskInfo.txt"
    )
    
    $foundLog = $candidateLogs | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($foundLog) {
        Copy-Item -Path $foundLog -Destination "$customLogDir\diskinfo.txt" -Force
    }
}
'@

Set-Content -Path $setupCdiPath -Value $setupCdiContent -Encoding UTF8 -Force
Write-Host " Skrip helper $setupCdiPath berhasil dibuat." -ForegroundColor Green

# B. Pendaftaran Scheduled Task CrystalDiskInfo (Setiap 6 Jam)
$cdiTaskName = "Checkmk_CrystalDiskInfo"
Unregister-ScheduledTask -TaskName $cdiTaskName -Confirm:$false -ErrorAction SilentlyContinue

$cdiAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$setupCdiPath`""
$cdiTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 6)
$cdiPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

try {
    Register-ScheduledTask -TaskName $cdiTaskName -Action $cdiAction -Trigger $cdiTrigger -Principal $cdiPrincipal | Out-Null
    Write-Host " ScheduledTask '$cdiTaskName' berhasil didaftarkan (Interval: 6 jam)." -ForegroundColor Green
} catch {
    Write-Warning " Gagal mendaftarkan Scheduled Task CrystalDiskInfo: $_"
}

# 8. Penjadwalan Task Scheduler Lainnya (RAM Test & Auto-Update)
Write-Host "`n[5/7] Mendaftarkan Scheduled Task RAM Test dan Auto-Updater..." -ForegroundColor Cyan

# A. ScheduledTask RAM Test (Sabtu 11:00 AM)
$ramTaskName = "Checkmk_Memory_Test"
Unregister-ScheduledTask -TaskName $ramTaskName -Confirm:$false -ErrorAction SilentlyContinue
$ramAction  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$localDir\ram_health.ps1`""
$ramTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At 11:00AM
Register-ScheduledTask -TaskName $ramTaskName -Action $ramAction -Trigger $ramTrigger -User "NT AUTHORITY\SYSTEM" -RunLevel Highest | Out-Null
Write-Host " ScheduledTask '$ramTaskName' didaftarkan (Sabtu 11:00 AM)." -ForegroundColor Green

# B. ScheduledTask Auto-Updater (Setiap 2 Jam)
$updateTaskName = "Checkmk_Auto_Update"
Unregister-ScheduledTask -TaskName $updateTaskName -Confirm:$false -ErrorAction SilentlyContinue
$updAction  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$agentDir\update_checks.ps1`""
$updTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $updateTaskName -Action $updAction -Trigger $updTrigger -User "NT AUTHORITY\SYSTEM" -RunLevel Highest | Out-Null
Write-Host " ScheduledTask '$updateTaskName' didaftarkan (Interval: 2 jam)." -ForegroundColor Green

# 9. Eksekusi Pembacaan Awal CrystalDiskInfo
Write-Host "`n[6/7] Menjalankan pembacaan awal SMART via CrystalDiskInfo..." -ForegroundColor Cyan
try {
    & "$setupCdiPath"
    if (Test-Path "$customLogDir\diskinfo.txt") {
        Write-Host " Pembacaan awal SMART selesai. Log tersimpan di $customLogDir\diskinfo.txt" -ForegroundColor Green
    } else {
        Write-Warning " Eksekusi awal selesai tetapi $customLogDir\diskinfo.txt belum terbentuk. Pastikan CrystalDiskInfo terpasang."
    }
} catch {
    Write-Warning " Gagal menjalankan pembacaan awal CrystalDiskInfo: $_"
}

# 10. Selesai
Write-Host "`n[7/7] Verifikasi dan Restart Service Checkmk Agent..." -ForegroundColor Cyan
Restart-Service -Name "CheckMkWatchdog" -ErrorAction SilentlyContinue
Restart-Service -Name "CheckmkAgent" -ErrorAction SilentlyContinue

Write-Host "`n=====================================================================" -ForegroundColor Green
Write-Host " INSTALASI SELESAI SUCCESSFUL! " -ForegroundColor Green
Write-Host " Seluruh komponen agen Checkmk, 11 local checks, dan CrystalDiskInfo  " -ForegroundColor Green
Write-Host " siap digunakan dalam satu kali eksekusi.                              " -ForegroundColor Green
Write-Host "=====================================================================" -ForegroundColor Green
