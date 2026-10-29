# =====================================================================
# Local Check Checkmk: Real-Time RAM Capacity & Usage (Windows)
# =====================================================================

$OS = Get-CimInstance -ClassName Win32_OperatingSystem

$TotalKB = $OS.TotalVisibleMemorySize
$FreeKB  = $OS.FreePhysicalMemory
$UsedKB  = $TotalKB - $FreeKB

$TotalGB = [Math]::Round($TotalKB / 1048576, 2)
$FreeGB  = [Math]::Round($FreeKB / 1048576, 2)
$UsedGB  = [Math]::Round($UsedKB / 1048576, 2)

$UsedPct = [int](($UsedKB / $TotalKB) * 100)

# Alert thresholds: OK < 85%, WARNING >= 85%, CRITICAL >= 95%
$Status = 0
$StatusTxt = "OK"
if ($UsedPct -ge 95) {
    $Status = 2
    $StatusTxt = "Critical"
} elseif ($UsedPct -ge 85) {
    $Status = 1
    $StatusTxt = "Warning"
}

# Hitung nilai ambang batas GB untuk garis visualisasi di grafik
$WarnGB = [Math]::Round($TotalGB * 0.85, 2)
$CritGB = [Math]::Round($TotalGB * 0.95, 2)

# Format Performance Data: nama=nilai;warn;crit;min;max (PENTING: tidak boleh ada spasi di dalam perfdata)
$PerfData = "ram_used=${UsedGB}GB;${WarnGB};${CritGB};0;${TotalGB}|ram_percent=${UsedPct}%;85;95;0;100"

# Output ke Checkmk (tanda '-' digantikan oleh $PerfData)
Write-Output "$Status `"RAM_Usage`" $PerfData Status : $StatusTxt | Used: $($UsedPct)% | Used Space: $($UsedGB) GB | Free: $($FreeGB) GB | Total: $($TotalGB) GB"
