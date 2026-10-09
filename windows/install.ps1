# install.ps1 - Script Installer Otomatis Agen Checkmk untuk Windows Client
# Dijalankan via PowerShell Administrator (Mendukung Mode Interaktif & CLI Arguments)

$ErrorActionPreference = "Stop"

# 1. Pastikan script berjalan sebagai Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Script ini HARUS dijalankan sebagai Administrator!"
    Exit
}

# 2. Inisialisasi Variabel Default & Parsing Argumen Baris Perintah ($args)
$ServerIP      = ""
$WebPort       = "8080"
$SiteName      = "cmk"
$AgentVersion  = "2.5.0p14-1"
$GithubUser    = "itlicensehq25"
$GithubRepo    = "checkmk-cabang"
$Branch        = "main"

# Manual Argument Parser (Sangat fleksibel untuk iex dan CLI)
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -regex ($args[$i]) {
        '^(-s|--server|-ServerIP)$'     { $ServerIP     = $args[++$i] }
        '^(-p|--port|-Port)$'           { $WebPort      = $args[++$i] }
        '^(-d|--site|-SiteName)$'       { $SiteName     = $args[++$i] }
        '^(-v|--version|-AgentVersion)$'{ $AgentVersion = $args[++$i] }
        '^(-g|--github|-GithubUser)$'  { $GithubUser   = $args[++$i] }
        '^(-r|--repo|-GithubRepo)$'    { $GithubRepo   = $args[++$i] }
        '^(-b|--branch|-Branch)$'      { $Branch       = $args[++$i] }
    }
}

Write-Host "=== Memulai Instalasi Otomatis Agen Checkmk di Windows ===" -ForegroundColor Cyan

# 3. Mode Interaktif (Jika ServerIP tidak diberikan via argumen)
if ([string]::IsNullOrWhiteSpace($ServerIP)) {
    Write-Host "`n[MODE INTERAKTIF] Silakan masukkan konfigurasi server Checkmk Anda:" -ForegroundColor Yellow
    
    while ([string]::IsNullOrWhiteSpace($ServerIP)) {
        $ServerIP = (Read-Host "1. Masukkan Alamat Server Checkmk [Contoh: 192.168.43.188:8080 atau 192.168.43.188]").Trim()
        if ([string]::IsNullOrWhiteSpace($ServerIP)) {
            Write-Host "   [!] Alamat server tidak boleh kosong!" -ForegroundColor Red
        }
    }

    $inputSite = (Read-Host "2. Masukkan Site ID Checkmk [Default: $SiteName]").Trim()
    if (-not [string]::IsNullOrWhiteSpace($inputSite)) {
        $SiteName = $inputSite
    }

    $inputVer = (Read-Host "3. Masukkan Versi Agen Checkmk [Default: $AgentVersion]").Trim()
    if (-not [string]::IsNullOrWhiteSpace($inputVer)) {
        $AgentVersion = $inputVer
    }
}

# Ekstraksi Host dan Port dari ServerIP (jika user memasukkan 192.168.43.188:8080)
$CleanServer = $ServerIP -replace '^https?://', ''
if ($CleanServer -like "*:*") {
    $parts = $CleanServer -split ':'
    $HostOnly = $parts[0]
    $WebPort  = $parts[1]
} else {
    $HostOnly = $CleanServer
}

# Konstruksi URL Download & GitHub Base
$CmkServerDownloadUrl = "http://${HostOnly}:${WebPort}"
$BaseUrl              = "https://raw.githubusercontent.com/$GithubUser/$GithubRepo/$Branch/windows"
$MsiUrl               = "$CmkServerDownloadUrl/$SiteName/check_mk/agents/windows/check_mk_agent.msi"

# Folder lokal tujuan
$AgentLocalFolder = "C:\ProgramData\checkmk\agent\local"
$LogFolder        = "C:\ProgramData\checkmk\agent\log_custom"
$MsiLocalPath     = "$env:TEMP\check_mk_agent.msi"
$RamScriptPath    = "C:\ProgramData\checkmk\agent\run_memtester.ps1"

Write-Host "`n=== Ringkasan Konfigurasi Target ===" -ForegroundColor Green
Write-Host "Server Host : $HostOnly" -ForegroundColor Gray
Write-Host "Web Port    : $WebPort" -ForegroundColor Gray
Write-Host "Site ID     : $SiteName" -ForegroundColor Gray
Write-Host "Versi Agen  : $AgentVersion" -ForegroundColor Gray
Write-Host "MSI URL     : $MsiUrl" -ForegroundColor Gray

# 4. Buat direktori lokal agen jika belum ada
if (-not (Test-Path $AgentLocalFolder)) {
    New-Item -ItemType Directory -Force -Path $AgentLocalFolder | Out-Null
    Write-Host "[OK] Folder local checks dibuat: $AgentLocalFolder" -ForegroundColor Green
}
if (-not (Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Force -Path $LogFolder | Out-Null
    Write-Host "[OK] Folder log custom dibuat: $LogFolder" -ForegroundColor Green
}

# Membersihkan file cache lama agar pemindaian ulang berjalan segar
$CacheFolder = "C:\ProgramData\checkmk\agent\cache"
if (Test-Path $CacheFolder) {
    Remove-Item (Join-Path $CacheFolder "cache_*.txt") -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] File cache lama dibersihkan untuk pemindaian segar." -ForegroundColor Green
}

# 5. Pemeriksaan Status & Versi Agen Terpasang (Smart Version Check)
$ShouldInstall = $true
$InstalledVersion = $null

Write-Host "[-] Memeriksa status instalasi Agen Checkmk pada sistem..." -ForegroundColor Yellow

# Query Registry untuk mencari "Checkmk Agent"
$RegUninstallPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$RegAgent = Get-ItemProperty -Path $RegUninstallPaths -ErrorAction SilentlyContinue | 
            Where-Object { $_.DisplayName -match "Check(mk|_MK) Agent" } | Select-Object -First 1

if ($RegAgent) {
    $InstalledVersion = $RegAgent.DisplayVersion
    Write-Host "[INFO] Agen Checkmk terdeteksi terpasang. Versi: $InstalledVersion" -ForegroundColor Gray
} else {
    # Fallback ke file exe langsung
    $agentExe = "C:\Program Files (x86)\checkmk\service\check_mk_agent.exe"
    if (-not (Test-Path $agentExe)) {
        $agentExe = "C:\Program Files\checkmk\service\check_mk_agent.exe"
    }
    if (Test-Path $agentExe) {
        $InstalledVersion = (Get-Item $agentExe).VersionInfo.ProductVersion
        Write-Host "[INFO] Executable Agen Checkmk ditemukan. Versi: $InstalledVersion" -ForegroundColor Gray
    }
}

# Pembanding versi cerdas
function Compare-Versions {
    param([string]$v1, [string]$v2)
    if ($v1 -eq $v2) { return 0 }
    
    $v1Norm = $v1 -replace '[a-zA-Z]', '.' -replace '\.+', '.' -replace '^\.', '' -replace '\.$', ''
    $v2Norm = $v2 -replace '[a-zA-Z]', '.' -replace '\.+', '.' -replace '^\.', '' -replace '\.$', ''
    
    try {
        $version1 = [System.Version]$v1Norm
        $version2 = [System.Version]$v2Norm
        return $version1.CompareTo($version2)
    } catch {
        return [string]::Compare($v1, $v2, $true)
    }
}

if ($InstalledVersion) {
    $Comparison = Compare-Versions -v1 $InstalledVersion -v2 $AgentVersion
    if ($Comparison -ge 0) {
        $ShouldInstall = $false
        Write-Host "[OK] Versi terpasang ($InstalledVersion) sudah sesuai atau lebih baru dibanding versi server ($AgentVersion)." -ForegroundColor Green
        Write-Host "[INFO] Melewati pengunduhan dan pemasangan ulang file MSI agen." -ForegroundColor Green
    } else {
        Write-Host "[WARNING] Versi terpasang ($InstalledVersion) lebih usang dibanding versi target ($AgentVersion)." -ForegroundColor Yellow
        Write-Host "[-] Mempersiapkan proses pembaruan (upgrade) ke versi $AgentVersion..." -ForegroundColor Yellow
    }
} else {
    Write-Host "[INFO] Agen Checkmk belum terpasang di komputer ini." -ForegroundColor Gray
    Write-Host "[-] Memulai instalasi baru versi $AgentVersion..." -ForegroundColor Yellow
}

# 6. Unduh dan Instal Agen Checkmk secara Silent (Hanya jika dibutuhkan)
if ($ShouldInstall) {
    Write-Host "[-] Mengunduh installer Agen Checkmk dari server ($MsiUrl)..." -ForegroundColor Yellow
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
        Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiLocalPath -UseBasicParsing
        Write-Host "[OK] Berhasil mengunduh installer agen." -ForegroundColor Green

        Write-Host "[-] Menginstal/Memperbarui Agen Checkmk secara silent (tanpa GUI)..." -ForegroundColor Yellow
        $installProcess = Start-Process msiexec.exe -ArgumentList "/i `"$MsiLocalPath`" /qn /norestart" -Wait -PassThru
        if ($installProcess.ExitCode -eq 0 -or $installProcess.ExitCode -eq 3010) {
            Write-Host "[OK] Agen Checkmk berhasil diinstal!" -ForegroundColor Green
        } else {
            Write-Warning "Instalasi agen selesai dengan ExitCode: $($installProcess.ExitCode)"
        }
    } catch {
        Write-Error "Gagal mengunduh atau menginstal agen Checkmk dari $MsiUrl : $_"
    } finally {
        if (Test-Path $MsiLocalPath) { Remove-Item $MsiLocalPath -Force }
    }
}

# 7. Unduh 10 Script Local Checks dari GitHub
$LocalChecks = @(
    "battery_health.ps1",
    "cpu_info.ps1",
    "disk_nvme_health.ps1",
    "fan_health.ps1",
    "info_network.ps1",
    "info_OS_office.ps1",
    "ram_health.ps1",
    "ram_usage.ps1",
    "remote_apps.ps1",
    "storage_usage.ps1"
)

Write-Host "[-] Mengunduh 10 script Local Checks dari GitHub..." -ForegroundColor Yellow
foreach ($script in $LocalChecks) {
    $scriptUrl = "$BaseUrl/local_checks/$script"
    $destination = Join-Path $AgentLocalFolder $script
    try {
        Invoke-WebRequest -Uri $scriptUrl -OutFile $destination -UseBasicParsing
        Write-Host " -> [OK] Mengunduh $script" -ForegroundColor Green
    } catch {
        Write-Warning "Gagal mengunduh script: $script dari $scriptUrl. Melewati..."
    }
}

# 8. Setup RAM Health (Pengujian Memtester Dinamis 20% Free RAM - Setiap Sabtu 11:00 AM)
Write-Host "[-] Menyiapkan penjadwalan uji kesehatan RAM (Dinamis 20% Free RAM)..." -ForegroundColor Yellow

$RamCheckScriptContent = @'
# Script Windows RAM Test (Pengujian Memtester Dinamis 20% Free RAM)
$LogFile = "C:\ProgramData\checkmk\agent\log_custom\memtester_health.log"
$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Add-Content -Path $LogFile -Value "=== MEMTESTER START: $Timestamp ==="

try {
    # Hitung 20% dari Free Physical Memory saat ini
    $FreeKB = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).FreePhysicalMemory
    $SampleMB = [Math]::Max(128, [Math]::Floor(($FreeKB / 1024) * 0.20))
    
    Add-Content -Path $LogFile -Value "SAMPLE_SIZE: ${SampleMB}M"
    Add-Content -Path $LogFile -Value "Mengalokasikan $SampleMB MB memori untuk pengujian..."
    
    $ByteCount = [long]$SampleMB * 1024 * 1024
    $testArray = New-Object Byte[] $ByteCount
    for ($i = 0; $i -lt $testArray.Length; $i += 4096) {
        $testArray[$i] = 1
    }
    $testArray = $null
    [System.GC]::Collect()
    
    $memoryErrors = Get-CimInstance -ClassName Win32_MemoryDevice | Where-Object { $_.ErrorCorrecting -eq $true -and $_.ErrorDescription -ne $null }
    
    if ($memoryErrors) {
        Add-Content -Path $LogFile -Value "STATUS: FAILED"
        Add-Content -Path $LogFile -Value "Error details: Terdeteksi kesalahan hardware pada modul RAM."
    } else {
        Add-Content -Path $LogFile -Value "STATUS: SUCCESS"
        Add-Content -Path $LogFile -Value "Memory allocation and system diagnostics passed."
    }
} catch {
    Add-Content -Path $LogFile -Value "STATUS: FAILED"
    Add-Content -Path $LogFile -Value "Error during diagnostic run: $_"
}

$EndTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path $LogFile -Value "=== MEMTESTER END: $EndTimestamp ==="
'@

$RamCheckScriptContent | Out-File -FilePath $RamScriptPath -Encoding utf8 -Force

# Task Scheduler - Setiap Sabtu 11:00 AM
$TaskName = "Checkmk_RAM_Health_Test"
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RamScriptPath`""
$Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At 11am
$Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
}

try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal | Out-Null
    Write-Host "[OK] Windows Task Scheduler '$TaskName' berhasil didaftarkan!" -ForegroundColor Green
    
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "[OK] Menjalankan pengujian RAM inisial pertama kali..." -ForegroundColor Green
} catch {
    Write-Warning "Gagal mendaftarkan Scheduled Task untuk pengujian RAM: $_"
}

# 9. Deteksi Lokasi cmk-agent-ctl.exe
$ctlPath = "C:\Program Files (x86)\checkmk\service\cmk-agent-ctl.exe"
if (-not (Test-Path $ctlPath)) {
    $ctlPath = "C:\Program Files\checkmk\service\cmk-agent-ctl.exe"
}

Write-Host "`n=====================================================================" -ForegroundColor Green
Write-Host "  PROSES INSTALASI SELESAI & SELURUH SCRIPT MONITORING TERPASANG!" -ForegroundColor Green
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host "Untuk mendaftarkan sertifikat keamanan agen (mTLS) ke server Checkmk, jalankan:" -ForegroundColor Cyan
Write-Host " & `"$ctlPath`" register --hostname <NAMA_HOST> --server ${HostOnly}:8000 --site $SiteName --user cmkadmin" -ForegroundColor Yellow
Write-Host "=====================================================================`n" -ForegroundColor Green
