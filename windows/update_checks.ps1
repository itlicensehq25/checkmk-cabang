# =============================================================================
# update_checks.ps1 - Auto-Update Skrip & Plugin Checkmk dari GitHub
# Repositori : itlicensehq25/checkmk-cabang
# Dijalankan secara otomatis oleh Scheduled Task "Checkmk_Auto_Update" (SYSTEM).
#
# Cara kerja:
#   1. Mengunduh berkas skrip ke folder sementara (temp).
#   2. Membandingkan hash SHA-256 antara file baru di GitHub vs file di komputer.
#      Hanya file yang BERBEDA yang ditimpa (Atomic Swap).
#   3. Memperbarui dirinya sendiri (update_checks.ps1) jika ada versi baru di GitHub.
# Log: C:\ProgramData\checkmk\agent\log_custom\update_checks.log
# =============================================================================
param(
    [string]$GithubUser = 'itlicensehq25',
    [string]$GithubRepo = 'checkmk-cabang',
    [string]$Branch     = 'main'
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$BaseUrl   = "https://raw.githubusercontent.com/$GithubUser/$GithubRepo/$Branch/windows"
$AgentRoot = 'C:\ProgramData\checkmk\agent'
$LocalDir  = Join-Path $AgentRoot 'local'
$PluginDir = Join-Path $AgentRoot 'plugins'
$LogDir    = Join-Path $AgentRoot 'log_custom'
$LogFile   = Join-Path $LogDir 'update_checks.log'
$TempDir   = Join-Path $env:TEMP 'checkmk_update'

# 11 Skrip Local Checks Windows
$LocalCheckFiles = @(
    'battery_health.ps1',
    'cpu_info.ps1',
    'disk_nvme_health.ps1',
    'fan_health.ps1',
    'info_network.ps1',
    'info_OS_office.ps1',
    'ram_health.ps1',
    'ram_usage.ps1',
    'remote_access_id.ps1',
    'remote_apps.ps1',
    'storage_usage.ps1'
)

# Plugin Resmi (Disimpan ke folder plugins)
$PluginFiles = @(
    'mk_inventory.vbs',
    'win_license.bat'
)

foreach ($d in @($LogDir, $LocalDir, $PluginDir, $TempDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

function Write-Log {
    param([string]$Msg)
    $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Msg
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 200KB)) {
            Get-Content $LogFile -Tail 200 | Set-Content $LogFile -Encoding UTF8
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
}

# Unduh $Url ke file sementara; ganti $Dest hanya jika hash SHA-256 berbeda
function Sync-File {
    param([string]$Url, [string]$Dest)
    $tmp = Join-Path $TempDir ([IO.Path]::GetFileName($Dest) + '.new')
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 30
    if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -eq 0) { throw 'file kosong atau gagal unduh' }

    $same = $false
    if (Test-Path $Dest) {
        $hashNew = (Get-FileHash $tmp -Algorithm SHA256).Hash
        $hashOld = (Get-FileHash $Dest -Algorithm SHA256).Hash
        $same = ($hashNew -eq $hashOld)
    }
    if ($same) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return 'same'
    }

    Copy-Item $tmp $Dest -Force
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return 'updated'
}

$updated = 0
$failed  = 0
$total   = 0

# ---------- 1. Sinkronisasi Local Checks ----------
foreach ($f in $LocalCheckFiles) {
    $total++
    $dest = Join-Path $LocalDir $f
    try {
        $r = Sync-File -Url "$BaseUrl/local_checks/$f" -Dest $dest
        if ($r -eq 'updated') {
            $updated++
            Write-Log "DIPERBARUI (Local Check): $f"
        }
    } catch {
        $failed++
        Write-Log "GAGAL: $f ($($_.Exception.Message))"
    }
}

# ---------- 2. Sinkronisasi Official Plugins ----------
foreach ($p in $PluginFiles) {
    $total++
    $dest = Join-Path $PluginDir $p
    try {
        $r = Sync-File -Url "$BaseUrl/plugins/$p" -Dest $dest
        if ($r -eq 'updated') {
            $updated++
            Write-Log "DIPERBARUI (Plugin): $p"
        }
    } catch {
        $failed++
        Write-Log "GAGAL (Plugin): $p ($($_.Exception.Message))"
    }
}

Write-Log "Pengecekan selesai. Diperbarui=$updated, Gagal=$failed, Total Diperiksa=$total"

# ---------- 3. Perbarui Skrip Ini Sendiri (Self-Update) ----------
try {
    $selfPath = $MyInvocation.ScriptName
    if ([string]::IsNullOrWhiteSpace($selfPath)) {
        $selfPath = Join-Path $AgentRoot 'update_checks.ps1'
    }
    if (Test-Path $selfPath) {
        $r = Sync-File -Url "$BaseUrl/update_checks.ps1" -Dest $selfPath
        if ($r -eq 'updated') {
            Write-Log 'update_checks.ps1 sendiri berhasil diperbarui (efektif pada jadwal berikutnya)'
        }
    }
} catch {}
