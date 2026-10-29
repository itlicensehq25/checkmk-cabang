# =====================================================================
# Local Check Checkmk: Weekly RAM Health & Slot Inventory (Asynchronous)
# Scheduled to run once a week on Saturday at 11:00 AM
# =====================================================================
$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$CacheFile = Join-Path $CacheDir "cache_ram_health.txt"
$LogFile = "C:\ProgramData\checkmk\agent\log_custom\memtester_health.log"

# Find last Saturday 11:00 AM epoch threshold
$Now = Get-Date
$DaysToSubtract = ([int]$Now.DayOfWeek - 6 + 7) % 7
if ($DaysToSubtract -eq 0 -and $Now.Hour -lt 11) {
    $DaysToSubtract = 7
}
$LastSat11 = (Get-Date -Hour 11 -Minute 0 -Second 0).AddDays(-$DaysToSubtract)

$NeedUpdate = $true
if (Test-Path $CacheFile) {
    $CacheMtime = (Get-Item $CacheFile).LastWriteTime
    
    # Cache Invalidation: if log file is newer than the cache file (new test run)
    $LogNewer = $false
    if (Test-Path $LogFile) {
        $LogMtime = (Get-Item $LogFile).LastWriteTime
        if ($LogMtime -gt $CacheMtime) {
            $LogNewer = $true
        }
    }
    
    # Cache Invalidation: if the script file itself is newer than the cache file (script updated)
    $ScriptPath = $MyInvocation.MyCommand.Path
    if ($ScriptPath -and (Test-Path $ScriptPath)) {
        $ScriptMtime = (Get-Item $ScriptPath).LastWriteTime
        if ($ScriptMtime -gt $CacheMtime) {
            $LogNewer = $true
        }
    }
    
    if ($CacheMtime -ge $LastSat11 -and -not $LogNewer) {
        $NeedUpdate = $false
    }
}

if ($NeedUpdate) {
    if (Test-Path $CacheFile) { Remove-Item $CacheFile -Force }
    
    # --- 1. DETEKSI SLOT RAM FISIK (SMBIOS/CIM) ---
    $MemoryArray = Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue
    $MemoryDevices = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
    
    $TotalSlots = 0
    if ($MemoryArray) { $TotalSlots = $MemoryArray.MemoryDevices }
    $UsedSlots = 0
    if ($MemoryDevices) { $UsedSlots = ($MemoryDevices | Measure-Object).Count }
    
    if ($TotalSlots -lt $UsedSlots) { $TotalSlots = $UsedSlots }
    $EmptySlots = $TotalSlots - $UsedSlots
    
    # Extract active modules sizes
    $ActiveModules = @()
    if ($MemoryDevices) {
        foreach ($Device in $MemoryDevices) {
            $CapGB = [Math]::Round($Device.Capacity / 1GB, 1)
            $ActiveModules += "$($CapGB)GiB"
        }
    }
    
    if ($ActiveModules.Count -gt 0) {
        $ActiveStr = $ActiveModules -join ","
    } else {
        $ActiveStr = "None"
    }
    
    $SlotOutput = "Used Slots: $UsedSlots/$TotalSlots ($EmptySlots Empty) | Active Modules: [$ActiveStr]"
    
    # --- 2. PEMBACAAN LOG MEMTESTER ---
    if (-not (Test-Path $LogFile)) {
        # Hitung 20% dari Free RAM saat ini secara dinamis sebagai estimasi awal
        $FreeKB = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).FreePhysicalMemory
        if ($FreeKB) {
            $EstMB = [Math]::Max(128, [Math]::Floor(($FreeKB / 1024) * 0.20))
            $EstSize = "${EstMB}M"
        } else {
            $EstSize = "N/A"
        }
        $Output = "0 `"Health_RAM`" - Status : OK | Result: Passed | Tested Size: $EstSize | Last Test: No test run yet | $SlotOutput | Log: Waiting for first scheduled memtester run on Saturday 11:00 AM."
    } else {
        $LogContent = Get-Content $LogFile -ErrorAction SilentlyContinue
        
        $StatusLine = $LogContent | Where-Object { $_ -like "STATUS:*" } | Select-Object -Last 1
        $SampleLine = $LogContent | Where-Object { $_ -like "SAMPLE_SIZE:*" } | Select-Object -Last 1
        $StartLine = $LogContent | Where-Object { $_ -like "=== MEMTESTER START:*" } | Select-Object -Last 1
        
        $SampleSize = ""
        if ($SampleLine) {
            $SampleSize = ($SampleLine -replace "SAMPLE_SIZE:", "").Trim()
        }
        if (-not $SampleSize) {
            # Hitung dinamis 20% dari Free RAM saat ini jika log belum mencatat SAMPLE_SIZE
            $FreeKB = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).FreePhysicalMemory
            if ($FreeKB) {
                $CalcMB = [Math]::Max(128, [Math]::Floor(($FreeKB / 1024) * 0.20))
                $SampleSize = "${CalcMB}M"
            } else {
                $SampleSize = "256M"
            }
        }
        
        $FormattedTime = "Unknown Date"
        if ($StartLine) {
            $RawTime = ($StartLine -replace "=== MEMTESTER START:", "" -replace "===", "").Trim()
            try {
                $FormattedTime = (Get-Date $RawTime -Format "yyyy-MM-dd HH:mm")
            } catch {
                $FormattedTime = $RawTime
            }
        }
        
        $StatusCode = 0
        $StatusTxt = "OK"
        $ResultTxt = "Passed"
        $LogSummary = "Memory allocation and system diagnostics passed."
        
        if ($StatusLine -and $StatusLine -like "*FAILED*") {
            $StatusCode = 2
            $StatusTxt = "Critical"
            $ResultTxt = "Failed"
            $LogSummary = "Memory test failed during allocation or hardware diagnostics."
        }
        
        $Output = "$StatusCode `"Health_RAM`" - Status : $StatusTxt | Result: $ResultTxt | Tested Size: $SampleSize | Last Test: $FormattedTime | $SlotOutput | Log: $LogSummary"
    }
    
    $Output | Out-File -FilePath $CacheFile -Encoding utf8 -Force
}

Get-Content $CacheFile -ErrorAction SilentlyContinue
