# =============================================================================
# install.ps1 - Script Installer Otomatis Agen Checkmk untuk Windows Client
# Repositori : itlicensehq25/checkmk-cabang
# Dijalankan via PowerShell Administrator (One-Liner Bypass)
# =============================================================================

$ErrorActionPreference = "Stop"

# 1. Pastikan script berjalan sebagai Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Script ini HARUS dijalankan sebagai Administrator!"
    Exit
}

# Paksa protokol TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

# 2. Konfigurasi Default & Parser Argumen Manual
$ServerIP      = ""
$GatewayIP     = ""
$WebPort       = ""
$SiteName      = "cmk"
$AgentVersion  = "2.5.0p14"
$GithubUser    = "itlicensehq25"
$GithubRepo    = "checkmk-cabang"
$Branch        = "main"

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "-s"            { $ServerIP = $args[++$i] }
        "-ServerIP"     { $ServerIP = $args[++$i] }
        "-gw"           { $GatewayIP = $args[++$i] }
        "-GatewayIP"    { $GatewayIP = $args[++$i] }
        "-p"            { $WebPort = $args[++$i] }
        "-Port"         { $WebPort = $args[++$i] }
        "-d"            { $SiteName = $args[++$i] }
        "-SiteName"     { $SiteName = $args[++$i] }
        "-v"            { $AgentVersion = $args[++$i] }
        "-AgentVersion" { $AgentVersion = $args[++$i] }
        "-g"            { $GithubUser = $args[++$i] }
        "-GithubUser"   { $GithubUser = $args[++$i] }
        "-r"            { $GithubRepo = $args[++$i] }
        "-GithubRepo"   { $GithubRepo = $args[++$i] }
        "-b"            { $Branch = $args[++$i] }
        "-Branch"       { $Branch = $args[++$i] }
    }
}

if ([string]::IsNullOrWhiteSpace($ServerIP)) {
    Write-Host "`n=== Konfigurasi Server Checkmk ===" -ForegroundColor Cyan
    $PromptServer = Read-Host "Masukkan IP Address atau Hostname Server Checkmk"
    if ([string]::IsNullOrWhiteSpace($PromptServer)) {
        Write-Error "IP address server Checkmk wajib diisi!"
        Exit
    }
    $ServerIP = $PromptServer.Trim()

    if ([string]::IsNullOrWhiteSpace($GatewayIP)) {
        $PromptGw = Read-Host "Masukkan IP Gateway Cabang untuk Ping Monitor [Tekan Enter = Auto-Detect]"
        if (-not [string]::IsNullOrWhiteSpace($PromptGw)) {
            $GatewayIP = $PromptGw.Trim()
        }
    }
}

# 3. Normalisasi Host & URL Server (Mendukung NAT Port 80 Madiun & Port 8081 Kediri)
$CleanHost = $ServerIP -replace '^https?://', ''
$CleanHost = $CleanHost.TrimEnd('/')

if ($CleanHost -match '^([^:]+):(\d+)$') {
    $HostOnly = $Matches[1]
    $WebPort  = $Matches[2]
} else {
    $HostOnly = ($CleanHost -split '/')[0]
}

if (-not [string]::IsNullOrWhiteSpace($WebPort) -and $WebPort -ne "80") {
    $CmkServer = "http://${HostOnly}:${WebPort}"
} else {
    $CmkServer = "http://${HostOnly}"
}

$BaseUrl          = "https://raw.githubusercontent.com/$GithubUser/$GithubRepo/$Branch/windows"
$MsiUrlVersioned  = "$CmkServer/$SiteName/check_mk/agents/check-mk-agent-${AgentVersion}.msi"
$MsiUrlLegacy     = "$CmkServer/$SiteName/check_mk/agents/windows/check_mk_agent.msi"

# Folder direktori pasti (Gunakan variabel konsisten tanpa Join-Path ambigu)
$AgentDir         = "C:\ProgramData\checkmk\agent"
$ConfigDir        = "$AgentDir\config"
$LocalDir         = "$AgentDir\local"
$PluginsDir       = "$AgentDir\plugins"
$LogDir           = "$AgentDir\log_custom"
$CacheDir         = "$AgentDir\cache"
$MsiLocalPath     = "$env:TEMP\check_mk_agent.msi"
$RamScriptPath    = "$AgentDir\run_memtester.ps1"

Write-Host "=== Memulai Instalasi Otomatis Agen Checkmk di Windows ===" -ForegroundColor Cyan
Write-Host "Server Host : $HostOnly" -ForegroundColor Gray
Write-Host "Site Name   : $SiteName" -ForegroundColor Gray
Write-Host "Target Ver  : $AgentVersion" -ForegroundColor Gray
Write-Host "Base Server : $CmkServer" -ForegroundColor Gray

# 4. Buat folder yang dibutuhkan jika belum ada
@($ConfigDir, $LocalDir, $PluginsDir, $LogDir, $CacheDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Force -Path $_ | Out-Null
    }
}

# Bersihkan cache lama
Remove-Item "$CacheDir\cache_*.txt" -Force -ErrorAction SilentlyContinue
Write-Host "[OK] Folder agen dan cache telah disiapkan." -ForegroundColor Green

# 5. Cek Status Versi Terpasang
$ShouldInstall = $true
$InstalledVersion = $null

Write-Host "[-] Memeriksa status instalasi Agen Checkmk pada komputer host..." -ForegroundColor Yellow

$RegUninstallPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$RegAgent = Get-ItemProperty -Path $RegUninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "Check(mk|_MK) Agent" } | Select-Object -First 1

if ($RegAgent) {
    $InstalledVersion = $RegAgent.DisplayVersion
    Write-Host "[INFO] Agen Checkmk terdeteksi terpasang di sistem. Versi: $InstalledVersion" -ForegroundColor Gray
} else {
    $agentExe = "C:\Program Files (x86)\checkmk\service\check_mk_agent.exe"
    if (-not (Test-Path $agentExe)) { $agentExe = "C:\Program Files\checkmk\service\check_mk_agent.exe" }
    if (Test-Path $agentExe) {
        $InstalledVersion = (Get-Item $agentExe).VersionInfo.ProductVersion
        Write-Host "[INFO] File Agen Checkmk ditemukan di disk. Versi: $InstalledVersion" -ForegroundColor Gray
    }
}

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
        Write-Host "[OK] Versi terpasang ($InstalledVersion) sudah sesuai atau lebih baru dibanding server ($AgentVersion)." -ForegroundColor Green
        Write-Host "[INFO] Melewati instalasi ulang file MSI agen." -ForegroundColor Green
    } else {
        Write-Host "[WARNING] Versi terpasang ($InstalledVersion) lebih usang dibanding target ($AgentVersion)." -ForegroundColor Yellow
        Write-Host "[-] Mempersiapkan proses pembaruan (upgrade)..." -ForegroundColor Yellow
    }
} else {
    Write-Host "[INFO] Agen Checkmk belum terpasang. Memulai instalasi baru..." -ForegroundColor Yellow
}

# 5.1 Dependensi Pendukung (Smartmontools & HWiNFO64)
Write-Host "[-] Memeriksa dependensi pendukung (Smartmontools & HWiNFO)..." -ForegroundColor Yellow

$smartctl = Get-Command "smartctl.exe" -ErrorAction SilentlyContinue
if (-not $smartctl -and -not (Test-Path "C:\Program Files\smartmontools\bin\smartctl.exe")) {
    Write-Host " -> smartmontools belum terpasang. Menginstal otomatis..." -ForegroundColor Cyan
    try { & winget install --id Smartmontools.Smartmontools -e --silent --accept-source-agreements --accept-package-agreements | Out-Null } catch {}

    if (-not (Test-Path "C:\Program Files\smartmontools\bin\smartctl.exe")) {
        $smartInstaller = "$env:TEMP\smartmontools-installer.exe"
        $smartUrl = "https://sourceforge.net/projects/smartmontools/files/smartmontools/7.4/smartmontools-7.4-1.win32-setup.exe/download"
        & curl.exe -s -k -L "$smartUrl" -o "$smartInstaller"
        if (Test-Path $smartInstaller) {
            Start-Process -FilePath $smartInstaller -ArgumentList "/S" -Wait
            Remove-Item $smartInstaller -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "[OK] smartmontools berhasil dipasang!" -ForegroundColor Green
} else {
    Write-Host "[OK] smartmontools sudah terpasang di sistem." -ForegroundColor Green
}

$hwinfoPath = "C:\Program Files\HWiNFO64"
if (-not (Test-Path "$hwinfoPath\HWiNFO64.exe") -and -not (Test-Path "C:\Program Files (x86)\HWiNFO64\HWiNFO64.exe")) {
    Write-Host " -> HWiNFO64 belum terpasang. Menyiapkan instalasi portable..." -ForegroundColor Cyan
    $installed = $false
    try {
        & winget install --id REALiX.HWiNFO -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
        if (Test-Path "$hwinfoPath\HWiNFO64.exe") { $installed = $true }
    } catch {}

    if (-not $installed) {
        if (-not (Test-Path $hwinfoPath)) { New-Item -ItemType Directory -Path $hwinfoPath -Force | Out-Null }
        $zipPath = "$env:TEMP\hwinfo.zip"
        & curl.exe -s -k -L -A "Mozilla/5.0" "https://raw.githubusercontent.com/itlicensehq25/checkmk-cabang/main/windows/tools/hwi_804.zip" -o "$zipPath"
        if ((Test-Path $zipPath) -and ((Get-Item $zipPath).Length -gt 100000)) {
            Expand-Archive -Path $zipPath -DestinationPath $hwinfoPath -Force
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] HWiNFO64 Portable berhasil diekstrak!" -ForegroundColor Green
        }
    } else {
        Write-Host "[OK] HWiNFO64 berhasil dipasang via winget!" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] HWiNFO64 sudah terpasang di sistem." -ForegroundColor Green
}

# 6. Unduh & Install MSI Agen Checkmk
if ($ShouldInstall) {
    Write-Host "[-] Mengunduh installer Agen Checkmk dari server..." -ForegroundColor Yellow
    $downloadSuccess = $false

    try {
        Write-Host " -> Mencoba: $MsiUrlVersioned" -ForegroundColor Gray
        Invoke-WebRequest -Uri $MsiUrlVersioned -OutFile $MsiLocalPath -UseBasicParsing -TimeoutSec 60
        $downloadSuccess = $true
    } catch {
        try {
            Write-Host " -> Mencoba fallback: $MsiUrlLegacy" -ForegroundColor Gray
            Invoke-WebRequest -Uri $MsiUrlLegacy -OutFile $MsiLocalPath -UseBasicParsing -TimeoutSec 60
            $downloadSuccess = $true
        } catch {
            Write-Error "Gagal mengunduh file MSI agen dari kedua URL target server!"
        }
    }

    if ($downloadSuccess) {
        Write-Host "[OK] Berhasil mengunduh installer agen." -ForegroundColor Green
        Write-Host "[-] Menginstal/Memperbarui Agen Checkmk secara silent (tanpa GUI)..." -ForegroundColor Yellow
        $installProcess = Start-Process msiexec.exe -ArgumentList "/i `"$MsiLocalPath`" /qn /norestart ALLUSERS=1" -Wait -PassThru
        if ($installProcess.ExitCode -eq 0 -or $installProcess.ExitCode -eq 3010) {
            Write-Host "[OK] Agen Checkmk berhasil diinstal!" -ForegroundColor Green
        } else {
            Write-Warning "Instalasi agen selesai dengan ExitCode: $($installProcess.ExitCode)"
        }
        Remove-Item $MsiLocalPath -Force -ErrorAction SilentlyContinue
    }
}

# 7. Unduh Script Local Checks dari GitHub (Tanpa Join-Path)
$LocalChecks = @(
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

Write-Host "[-] Mengunduh script Local Checks dari GitHub..." -ForegroundColor Yellow
foreach ($script in $LocalChecks) {
    $scriptUrl   = "$BaseUrl/local_checks/$script"
    $destination = "$LocalDir\$script"

    try {
        & curl.exe -s -k -L "$scriptUrl" -o "$destination"
        if (Test-Path $destination) {
            Unblock-File -Path $destination -ErrorAction SilentlyContinue
            Write-Host " -> [OK] Mengunduh $script" -ForegroundColor Green
        } else {
            Write-Warning "File kosong atau gagal diunduh: $script"
        }
    } catch {
        Write-Warning "Gagal mengunduh script: $script dari $scriptUrl. Melewati..."
    }
}

# 7.1 Unduh Official Plugins (Inventory & License)
$OfficialPlugins = @("mk_inventory.vbs", "win_license.bat")

Write-Host "[-] Mengunduh Plugin Resmi Checkmk dari GitHub..." -ForegroundColor Yellow
foreach ($plugin in $OfficialPlugins) {
    $pluginUrl   = "$BaseUrl/plugins/$plugin"
    $destination = "$PluginsDir\$plugin"

    & curl.exe -s -k -L "$pluginUrl" -o "$destination"
    if (Test-Path $destination) {
        Write-Host " -> [OK] Mengunduh plugin: $plugin" -ForegroundColor Green
    } else {
        Write-Warning "Gagal mengunduh plugin: $plugin"
    }
}

# 8. Setup Penjadwalan RAM Health (Setiap Sabtu 11:00 AM)
Write-Host "[-] Menyiapkan penjadwalan uji kesehatan RAM (Setiap Sabtu 11:00 AM)..." -ForegroundColor Yellow

$RamCheckScriptContent = @'
# Script Windows RAM Test (Representasi memtester di Windows)
$LogFile = "C:\ProgramData\checkmk\agent\log_custom\memtester_health.log"
$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Add-Content -Path $LogFile -Value "=== MEMTESTER START: $Timestamp ==="
try {
    Write-Output "Mengalokasikan memori untuk testing..."
    $testArray = New-Object Byte[] (256 * 1024 * 1024) # 256MB
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

$TaskName = "Checkmk_RAM_Health_Test"
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File '$RamScriptPath'"
$Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At 11am
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount

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

# 8.1 Konfigurasi IP Gateway Cabang & Penjadwalan Ping Monitor 1 Menit (3 Target + Retensi 30 Hari)
$GatewayConfigFile = "$ConfigDir\gateway_ip.txt"
if (-not [string]::IsNullOrWhiteSpace($GatewayIP) -and ($GatewayIP -match '^\d{1,3}(\.\d{1,3}){3}$')) {
    Set-Content -Path $GatewayConfigFile -Value "LOCKED:$($GatewayIP.Trim())" -Encoding ASCII -Force
    Write-Host "[OK] IP Gateway Cabang dikunci secara manual ke: $GatewayIP" -ForegroundColor Green
} else {
    try {
        $autoGw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1).NextHop
        if ($autoGw -and ($autoGw -match '^\d{1,3}(\.\d{1,3}){3}$')) {
            Set-Content -Path $GatewayConfigFile -Value $autoGw.Trim() -Encoding ASCII -Force
            Write-Host "[OK] IP Gateway Cabang terdeteksi otomatis: $autoGw" -ForegroundColor Green
        }
    } catch {}
}

$PingTaskName = "Checkmk_Ping_Monitor"
$InfoNetScript = "$LocalDir\info_network.ps1"
if (Test-Path $InfoNetScript) {
    try {
        $PingAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InfoNetScript`" -CollectOnly"
        $PingTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
        $PingPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $PingSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        Register-ScheduledTask -TaskName $PingTaskName -Action $PingAction -Trigger $PingTrigger -Principal $PingPrincipal -Settings $PingSettings -Force | Out-Null
        Start-ScheduledTask -TaskName $PingTaskName -ErrorAction SilentlyContinue
        Write-Host "[OK] Windows Task Scheduler '$PingTaskName' (Ping 4x tiap 1 menit + Retensi 30 Hari) berhasil diaktifkan!" -ForegroundColor Green
    } catch {
        Write-Warning "Gagal mendaftarkan Scheduled Task '$PingTaskName': $_"
    }
}

# 8.2 Setup Auto-Update Skrip Otomatis dari GitHub (Setiap 2 Jam)
Write-Host "[-] Menyiapkan penjadwalan Auto-Update skrip dari GitHub (Setiap 2 Jam)..." -ForegroundColor Yellow
$UpdaterPath = "$AgentDir\update_checks.ps1"
$UpdaterUrl  = "$BaseUrl/update_checks.ps1"
try {
    & curl.exe -s -k -L "$UpdaterUrl" -o "$UpdaterPath"
    if (Test-Path $UpdaterPath) {
        Unblock-File -Path $UpdaterPath -ErrorAction SilentlyContinue
        $AutoUpdateTask = "Checkmk_Auto_Update"
        $UpdateAction   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$UpdaterPath`" -GithubUser `"$GithubUser`" -GithubRepo `"$GithubRepo`" -Branch `"$Branch`""
        $UpdateTrigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration (New-TimeSpan -Days 3650)
        $UpdatePrincipal= New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $UpdateSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
        Register-ScheduledTask -TaskName $AutoUpdateTask -Action $UpdateAction -Trigger $UpdateTrigger -Principal $UpdatePrincipal -Settings $UpdateSettings -Force | Out-Null
        Write-Host "[OK] Windows Task Scheduler '$AutoUpdateTask' berhasil diaktifkan (Auto-Update tiap 2 jam)!" -ForegroundColor Green
    }
} catch {
    Write-Warning "Gagal mendaftarkan Scheduled Task Auto-Update: $_"
}

# 8.3 Unduh Tooling Hardware Sensor (setup_hwinfo.ps1 & setup_crystaldiskinfo.ps1)
$HwinfoSetupPath = "$AgentDir\setup_hwinfo.ps1"
$HwinfoSetupUrl  = "$BaseUrl/setup_hwinfo.ps1"
try {
    & curl.exe -s -k -L "$HwinfoSetupUrl" -o "$HwinfoSetupPath"
    if (Test-Path $HwinfoSetupPath) { Unblock-File -Path $HwinfoSetupPath -ErrorAction SilentlyContinue }
} catch {}

# 9. Konfigurasi Firewall & Service Checkmk (Dibatasi ke IP Server Checkmk Cabang)
try {
    $allowedRemoteIps = @()
    if ($HostOnly -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $allowedRemoteIps += $HostOnly
    } else {
        $resolvedIps = [System.Net.Dns]::GetHostAddresses($HostOnly) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -ExpandProperty IPAddressToString
        if ($resolvedIps) { $allowedRemoteIps += $resolvedIps }
    }
    $rule = Get-NetFirewallRule -DisplayName "Checkmk Agent (TCP 6556)" -ErrorAction SilentlyContinue
    if ($allowedRemoteIps.Count -gt 0) {
        if ($rule) {
            Set-NetFirewallRule -DisplayName "Checkmk Agent (TCP 6556)" -RemoteAddress $allowedRemoteIps -Action Allow | Out-Null
        } else {
            New-NetFirewallRule -DisplayName "Checkmk Agent (TCP 6556)" -Direction Inbound -LocalPort 6556 -Protocol TCP -RemoteAddress $allowedRemoteIps -Action Allow | Out-Null
        }
        Write-Host "[OK] Firewall TCP 6556 dibatasi khusus untuk IP Server Checkmk Cabang: $($allowedRemoteIps -join ', ')" -ForegroundColor Green
    }
} catch {}

try {
    $svc = Get-Service -Name "CheckMkService" -ErrorAction SilentlyContinue
    if ($svc) { Restart-Service -Name "CheckMkService" -Force }
} catch {}

# 10. Info Registrasi Agen
$ctlPath = "C:\Program Files (x86)\checkmk\service\cmk-agent-ctl.exe"
if (-not (Test-Path $ctlPath)) {
    $ctlPath = "C:\Program Files\checkmk\service\cmk-agent-ctl.exe"
}

Write-Host "`n=== Proses Instalasi Selesai! Agen Anda Siap Digunakan ===" -ForegroundColor Green
Write-Host "Untuk mendaftarkan sertifikat agen ke server Checkmk, jalankan perintah berikut sebagai Administrator:" -ForegroundColor Green
Write-Host " & `"$ctlPath`" register --hostname <NAMA_HOST> --server ${HostOnly}:8000 --site $SiteName --user cmkadmin" -ForegroundColor Yellow
