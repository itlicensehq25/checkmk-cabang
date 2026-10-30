# ==========================================================
# setup_crystaldiskinfo.ps1
# Membuat tugas otomatis (Task Scheduler) yang menjalankan CrystalDiskInfo
# tiap 6 jam, menyimpan hasilnya ke:
#   C:\ProgramData\checkmk\agent\log_custom\diskinfo.txt
# File itu dibaca oleh disk_nvme_health.ps1 (local check Checkmk).
#
# Otomatis:
#   - Jika CrystalDiskInfo belum ada, dicoba dipasang lewat winget.
#   - Task dicoba sebagai SYSTEM dulu; jika file tidak terbentuk dan script
#     dijalankan oleh user biasa (admin), dicoba ulang sebagai user itu.
#
# Jalankan di PowerShell sebagai Administrator:
#   .\setup_crystaldiskinfo.ps1
#   .\setup_crystaldiskinfo.ps1 -CdiPath "D:\Tools\CrystalDiskInfo\DiskInfo64.exe"
#   .\setup_crystaldiskinfo.ps1 -AsCurrentUser   # paksa mode user (tanpa coba SYSTEM)
# ==========================================================
param(
    [string]$CdiPath = '',
    [switch]$AsCurrentUser
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '[!] Script ini HARUS dijalankan sebagai Administrator!' -ForegroundColor Red
    exit 1
}

$AgentRoot = 'C:\ProgramData\checkmk\agent'
$LogFolder = Join-Path $AgentRoot 'log_custom'
$Wrapper   = Join-Path $AgentRoot 'run_crystaldiskinfo.ps1'
$OutFile   = Join-Path $LogFolder 'diskinfo.txt'
$TaskName  = 'Checkmk_CrystalDiskInfo'

if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Force -Path $LogFolder | Out-Null }

# ---------- 1. Cari DiskInfo64.exe ----------
function Find-Cdi {
    $candidates = @(
        'C:\Program Files\CrystalDiskInfo\DiskInfo64.exe',
        'C:\Program Files (x86)\CrystalDiskInfo\DiskInfo64.exe',
        'C:\CrystalDiskInfo\DiskInfo64.exe',
        (Join-Path $AgentRoot 'tools\CrystalDiskInfo\DiskInfo64.exe')
    )
    $running = Get-Process DiskInfo64 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path) { $candidates = @($running.Path) + $candidates }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return ''
}

if (-not $CdiPath) { $CdiPath = Find-Cdi }

# Belum ada -> coba pasang lewat winget
if (-not $CdiPath -or -not (Test-Path $CdiPath)) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host '[-] CrystalDiskInfo belum ada, mencoba memasang lewat winget...' -ForegroundColor Yellow
        try {
            & $winget.Source install --id CrystalDewWorld.CrystalDiskInfo -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
        } catch {}
        $CdiPath = Find-Cdi
    }
}

if (-not $CdiPath -or -not (Test-Path $CdiPath)) {
    Write-Host '[!] DiskInfo64.exe tidak ditemukan dan pemasangan otomatis gagal.' -ForegroundColor Red
    Write-Host '    Pasang CrystalDiskInfo (atau ekstrak versi portable/ZIP) ke:' -ForegroundColor Yellow
    Write-Host "    $(Join-Path $AgentRoot 'tools\CrystalDiskInfo')" -ForegroundColor Yellow
    Write-Host '    lalu jalankan ulang script ini, atau beri lokasinya: -CdiPath "C:\...\DiskInfo64.exe"' -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] CrystalDiskInfo: $CdiPath" -ForegroundColor Green

# ---------- 2. Buat script pembungkus ----------
$template = @'
$ErrorActionPreference = 'SilentlyContinue'
$cdi = '__CDI__'
$out = '__OUT__'
$dir = Split-Path $cdi
$txt = Join-Path $dir 'DiskInfo.txt'
if (Test-Path $txt) { Remove-Item $txt -Force }
$p = Start-Process -FilePath $cdi -ArgumentList '/CopyExit' -WorkingDirectory $dir -PassThru
if ($p) {
    if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force }
}
if (Test-Path $txt) { Copy-Item $txt $out -Force }
'@
$content = $template.Replace('__CDI__', $CdiPath).Replace('__OUT__', $OutFile)
Set-Content -Path $Wrapper -Value $content -Encoding UTF8
Write-Host "[OK] Script pembungkus dibuat: $Wrapper" -ForegroundColor Green

# ---------- 3. Daftarkan Scheduled Task (tiap 6 jam) dan uji ----------
function Register-CdiTask {
    param([bool]$AsUser)

    $Action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Wrapper`""
    $Trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650)
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    if ($AsUser) {
        $me = $identity.Name
        $Principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
        Write-Host "[INFO] Task berjalan sebagai $me (hanya saat user itu login)." -ForegroundColor Cyan
    } else {
        $Principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Write-Host '[INFO] Task berjalan sebagai SYSTEM.' -ForegroundColor Cyan
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
    }
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal | Out-Null
    Write-Host "[OK] Scheduled Task '$TaskName' terdaftar (tiap 6 jam)." -ForegroundColor Green
}

function Test-CdiRun {
    $startTime = Get-Date
    Start-ScheduledTask -TaskName $TaskName
    Write-Host '[-] Menjalankan CrystalDiskInfo, menunggu hasil (maks 60 detik)...' -ForegroundColor Yellow
    for ($i = 0; $i -lt 30; $i++) {
        if ((Test-Path $OutFile) -and ((Get-Item $OutFile).LastWriteTime -gt $startTime)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Urutan mode: SYSTEM dulu; jika gagal dan script dijalankan oleh user (bukan SYSTEM), coba sebagai user
if ($AsCurrentUser) {
    $modes = @($true)
} elseif ($identity.IsSystem) {
    $modes = @($false)
} else {
    $modes = @($false, $true)
}

$ok = $false
foreach ($m in $modes) {
    Register-CdiTask -AsUser $m
    if (Test-CdiRun) { $ok = $true; break }
    Write-Host '[!] File diskinfo.txt belum terbentuk dengan mode ini.' -ForegroundColor Yellow
}

if ($ok) {
    Write-Host "[OK] Berhasil: $OutFile" -ForegroundColor Green
    Select-String -Path $OutFile -Pattern '^\s*(Model|Interface|Temperature|Health Status)\s*:' | ForEach-Object { $_.Line }
    exit 0
} else {
    Write-Host '[!] File diskinfo.txt tetap belum terbentuk.' -ForegroundColor Red
    Write-Host "    Tes manual: tutup CrystalDiskInfo, jalankan  & `"$CdiPath`" /CopyExit  lalu cek apakah DiskInfo.txt muncul di foldernya." -ForegroundColor Yellow
    exit 1
}
