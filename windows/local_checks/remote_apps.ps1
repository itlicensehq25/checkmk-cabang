# =====================================================================
# Local Check Checkmk: Daily Remote Apps Inventory Scan (Windows)
# Scheduled to run once a day at 16:00
# =====================================================================
$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$CacheFile = Join-Path $CacheDir "cache_remote_apps.txt"

# Get current hour and today's 16:00 threshold
$Now = Get-Date
$Today16 = Get-Date -Hour 16 -Minute 0 -Second 0
if ($Now -lt $Today16) {
    $Last16 = $Today16.AddDays(-1)
} else {
    $Last16 = $Today16
}

$NeedUpdate = $true
if (Test-Path $CacheFile) {
    $CacheMtime = (Get-Item $CacheFile).LastWriteTime
    if ($CacheMtime -ge $Last16) {
        $NeedUpdate = $false
    }
}

if ($NeedUpdate) {
    $RemoteList = @()
    
    # --- 1. DETEKSI ANYDESK ---
    $AnyDeskID = ""
    # Coba eksekusi CLI AnyDesk jika ada
    $AnyExe = "C:\Program Files (x86)\AnyDesk\AnyDesk.exe"
    if (-not (Test-Path $AnyExe)) { $AnyExe = "C:\Program Files\AnyDesk\AnyDesk.exe" }
    if (-not (Test-Path $AnyExe)) { $AnyExe = (Get-Command anydesk.exe -ErrorAction SilentlyContinue).Path }
    
    if ($AnyExe -and (Test-Path $AnyExe)) {
        try {
            $AnyDeskID = (& $AnyExe --get-id | Out-String).Trim()
        } catch {}
    }
    # Fallback ke file sistem AnyDesk system.conf jika CLI kosong
    if (-not $AnyDeskID) {
        $AnyConfPath = "$env:ProgramData\AnyDesk\system.conf"
        if (Test-Path $AnyConfPath) {
            $AnyConf = Get-Content $AnyConfPath -ErrorAction SilentlyContinue
            $IdLine = $AnyConf | Where-Object { $_ -like "ad.id=*" }
            if ($IdLine) {
                $AnyDeskID = ($IdLine -replace "ad.id=", "").Trim()
            }
        }
    }
    # Fallback ke Registry
    if (-not $AnyDeskID) {
        $AnyDeskID = Get-ItemPropertyValue -Path "HKCU:\Software\AnyDesk\Client" -Name "ad.id" -ErrorAction SilentlyContinue
    }
    
    if ($AnyDeskID) {
        $RemoteList += "AnyDesk ID: $AnyDeskID"
    }
    
    # --- 2. DETEKSI RUSTDESK ---
    $RustDeskID = ""
    # Coba eksekusi CLI rustdesk.exe --get-id | Out-String
    $RustExe = "C:\Program Files\RustDesk\rustdesk.exe"
    if (-not (Test-Path $RustExe)) { $RustExe = "C:\Program Files (x86)\RustDesk\rustdesk.exe" }
    if (-not (Test-Path $RustExe)) { $RustExe = (Get-Command rustdesk.exe -ErrorAction SilentlyContinue).Path }
    
    if ($RustExe -and (Test-Path $RustExe)) {
        try {
            $RustDeskID = (& $RustExe --get-id | Out-String).Trim()
        } catch {}
    }
    
    if (-not $RustDeskID) {
        try {
            $RustDeskID = (rustdesk.exe --get-id 2>$null | Out-String).Trim()
        } catch {}
    }
    
    # Fallback ke berkas konfigurasi rustdesk.toml jika CLI tidak mengembalikan ID
    if (-not $RustDeskID) {
        $RustConfPath = "$env:ProgramData\RustDesk\config\rustdesk.toml"
        if (Test-Path $RustConfPath) {
            $RustConf = Get-Content $RustConfPath -ErrorAction SilentlyContinue
            $IdLine = $RustConf | Where-Object { $_ -match "^\s*id\s*=" } | Select-Object -First 1
            if ($IdLine) {
                $RustDeskID = ($IdLine -split '=' | Select-Object -Last 1).Trim().Trim('"').Trim()
            }
        }
    }
    
    if ($RustDeskID) {
        $RemoteList += "RustDesk ID: $RustDeskID"
    }
    
    # Format Detail Output (Sama persis seperti Linux & README.md)
    if ($RemoteList.Count -gt 0) {
        $Details = $RemoteList -join " | "
    } else {
        $Details = "No remote apps detected."
    }
    
    $Output = "0 `"Info_Remote_Support`" - Status : OK | $Details"
    $Output | Out-File -FilePath $CacheFile -Encoding utf8 -Force
}

Get-Content $CacheFile -ErrorAction SilentlyContinue
