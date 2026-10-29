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
    # Check common system configuration path
    $AnyConfPath = "$env:ProgramData\AnyDesk\system.conf"
    if (Test-Path $AnyConfPath) {
        $AnyConf = Get-Content $AnyConfPath -ErrorAction SilentlyContinue
        $IdLine = $AnyConf | Where-Object { $_ -like "ad.id=*" }
        if ($IdLine) {
            $AnyDeskID = ($IdLine -replace "ad.id=", "").Trim()
        }
    }
    # Check registry as fallback
    if (-not $AnyDeskID) {
        $AnyDeskID = Get-ItemPropertyValue -Path "HKCU:\Software\AnyDesk\Client" -Name "ad.id" -ErrorAction SilentlyContinue
    }
    
    if ($AnyDeskID) {
        $RemoteList += "AnyDesk ID: $AnyDeskID"
    }
    
    # --- 2. DETEKSI RUSTDESK ---
    $RustDeskID = ""
    $RustConfPath = "$env:ProgramData\RustDesk\config\rustdesk.toml"
    if (Test-Path $RustConfPath) {
        $RustConf = Get-Content $RustConfPath -ErrorAction SilentlyContinue
        # Look for id="xxx" or id = "xxx"
        $IdLine = $RustConf | Where-Object { $_ -match "^\s*id\s*=" } | Select-Object -First 1
        if ($IdLine) {
            $RustDeskID = ($IdLine -split '=' | Select-Object -Last 1).Trim().Trim('"').Trim()
        }
    }
    
    if ($RustDeskID) {
        $RemoteList += "RustDesk ID: $RustDeskID"
    }
    
    # Format Detail Output
    if ($RemoteList.Count -gt 0) {
        $Details = $RemoteList -join " | "
    } else {
        $Details = "No remote apps detected."
    }
    
    $Output = "0 `"Remote_Apps`" - Status : OK | $Details"
    $Output | Out-File -FilePath $CacheFile -Encoding utf8 -Force
}

Get-Content $CacheFile -ErrorAction SilentlyContinue
