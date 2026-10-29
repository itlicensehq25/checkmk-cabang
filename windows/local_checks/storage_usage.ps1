# =====================================================================
# Local Check Checkmk: Daily Active Storage Capacity Monitor (Windows)
# Scheduled to run once a day at 16:00
# =====================================================================
$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$CacheFile = Join-Path $CacheDir "cache_storage_usage.txt"

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
    if (Test-Path $CacheFile) { Remove-Item $CacheFile -Force }
    
    # Get active local volumes (DriveType = 3 represents physical/local disk)
    $Volumes = Get-CimInstance -ClassName Win32_Volume -Filter "DriveType=3 and DriveLetter <> NULL" -ErrorAction SilentlyContinue
    
    foreach ($Volume in $Volumes) {
        $Mount = $Volume.DriveLetter
        $Label = $Volume.Label
        if (-not $Label) { $Label = "Local Disk" }
        
        $Capacity = $Volume.Capacity
        $FreeSpace = $Volume.FreeSpace
        $Used = $Capacity - $FreeSpace
        
        $TotalGB = [Math]::Round($Capacity / 1GB, 2)
        $FreeGB = [Math]::Round($FreeSpace / 1GB, 2)
        $UsedGB = [Math]::Round($Used / 1GB, 2)
        
        $UsedPct = [int](($Used / $Capacity) * 100)
        
        # Clean naming for Checkmk Service Name
        $CleanMount = $Mount -replace '[^\w\s-]', '' # Convert "C:" to "C"
        $ServiceName = "Storage_Usage_$CleanMount"
        
        # Thresholds: OK < 85%, WARNING >= 85%, CRITICAL >= 95%
        $Status = 0
        $StatusTxt = "OK"
        if ($UsedPct -ge 95) {
            $Status = 2
            $StatusTxt = "Critical"
        } elseif ($UsedPct -ge 85) {
            $Status = 1
            $StatusTxt = "Warning"
        }
        
        $OutputLine = "$Status `"$ServiceName`" - Status : $StatusTxt | Partition: $Mount ($Label) | Used: $($UsedPct)% | Free: $($FreeGB) GB | Total: $($TotalGB) GB"
        $OutputLine | Out-File -FilePath $CacheFile -Encoding utf8 -Append
    }
}

Get-Content $CacheFile -ErrorAction SilentlyContinue
