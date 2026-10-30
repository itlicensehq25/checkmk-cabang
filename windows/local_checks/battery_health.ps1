# =====================================================================
# Local Check Checkmk: Daily Battery Health Monitor (Windows)
# Scheduled to run once a day at 16:00
# Pure ASCII Encoding - Safe for PowerShell 5.1 & Checkmk Agent
# =====================================================================
$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$CacheFile = Join-Path $CacheDir "cache_battery_health.txt"

# Check 16:00 daily cache threshold
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
    $DesignMwh = 0
    $FullMwh = 0
    $BatteryLevel = 0
    $State = "AC Power"
    $HasBattery = $false

    # -----------------------------------------------------------------
    # 1. METHOD A: Query powercfg /batteryreport /xml (Most accurate)
    # -----------------------------------------------------------------
    $XmlPath = "$env:TEMP\battery_report_tmp.xml"
    try {
        $null = powercfg /batteryreport /xml /output $XmlPath 2>$null
        if (Test-Path $XmlPath) {
            [xml]$xml = Get-Content $XmlPath -ErrorAction SilentlyContinue
            $batNode = $xml.BatteryReport.Batteries.Battery | Select-Object -First 1
            if ($batNode) {
                if ($batNode.DesignCapacity -and [int]$batNode.DesignCapacity -gt 0) {
                    $DesignMwh = [int]$batNode.DesignCapacity
                    $HasBattery = $true
                }
                if ($batNode.FullChargeCapacity -and [int]$batNode.FullChargeCapacity -gt 0) {
                    $FullMwh = [int]$batNode.FullChargeCapacity
                    $HasBattery = $true
                }
            }
            Remove-Item $XmlPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    # -----------------------------------------------------------------
    # 2. METHOD B: Query ACPI WMI root\wmi (Direct firmware table)
    # -----------------------------------------------------------------
    if ($DesignMwh -le 0) {
        try {
            $StaticData = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue
            if ($StaticData -and $StaticData.DesignedCapacity -gt 0) {
                $DesignMwh = [int]$StaticData.DesignedCapacity
                $HasBattery = $true
            }
        } catch {}
    }
    if ($FullMwh -le 0) {
        try {
            $FullData = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue
            if ($FullData -and $FullData.FullChargedCapacity -gt 0) {
                $FullMwh = [int]$FullData.FullChargedCapacity
                $HasBattery = $true
            }
        } catch {}
    }

    # -----------------------------------------------------------------
    # 3. METHOD C: Query Win32_Battery (Standard WMI)
    # -----------------------------------------------------------------
    try {
        $Battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if ($Battery) {
            $HasBattery = $true
            if ($Battery.EstimatedChargeRemaining) {
                $BatteryLevel = [int]$Battery.EstimatedChargeRemaining
            }
            
            # Extract state
            $StateVal = $Battery.BatteryStatus
            if ($StateVal -eq 1) { $State = "Discharging" }
            elseif ($StateVal -eq 2) { $State = "Fully Charged" }
            elseif ($StateVal -eq 6) { $State = "Charging" }
            else { $State = "AC Power" }

            if ($DesignMwh -le 0 -and $Battery.DesignCapacity -gt 0) {
                $DesignMwh = [int]$Battery.DesignCapacity
            }
            if ($FullMwh -le 0 -and $Battery.FullChargeCapacity -gt 0) {
                $FullMwh = [int]$Battery.FullChargeCapacity
            }
        }
    } catch {}

    # -----------------------------------------------------------------
    # 4. Fallbacks & Sanity Checks
    # -----------------------------------------------------------------
    if ($HasBattery) {
        if ($BatteryLevel -eq 0) { $BatteryLevel = 100 }
        
        # Convert mWh to Wh
        $DesignWh = [Math]::Round($DesignMwh / 1000)
        $FullWh = [Math]::Round($FullMwh / 1000)

        # Fix 0w/h issue: If Design Capacity is missing/0 but Full Capacity exists
        if ($DesignWh -le 0 -and $FullWh -gt 0) {
            $DesignWh = $FullWh
            $DesignMwh = $FullMwh
        }
        
        # Ultimate fallback if both are 0 but laptop has battery
        if ($DesignWh -le 0) { $DesignWh = 35 }
        if ($FullWh -le 0) { $FullWh = $DesignWh }

        # Calculate State of Health (SOH) %
        if ($DesignWh -gt 0) {
            $Health = [Math]::Floor(($FullWh / $DesignWh) * 100)
            if ($Health -gt 100) { $Health = 100 }
        } else {
            $Health = 100
        }

        # Checkmk Status Thresholds
        # OK >= 60%, WARNING 21-59%, CRITICAL <= 20%
        $Status = 0
        $StatusTxt = "OK"
        if ($Health -le 20) {
            $Status = 2
            $StatusTxt = "Critical"
        } elseif ($Health -lt 60) {
            $Status = 1
            $StatusTxt = "Warning"
        }

        # PURE ASCII Output (Uses standard pipe '|' instead of Unicode vertical bar)
        $Output = "$Status `"Health_Battery`" - Status Battery : $State | Design Capacity : $($DesignWh)w/h | Current Capacity : $($FullWh)w/h | Health : $($Health)% | Battery Level : $($BatteryLevel)%"
    } else {
        # PC Desktop / No Battery
        $Output = "0 `"Health_Battery`" - Status Battery : N/A | Device is PC/Desktop, there is no battery."
    }

    # Write cache file strictly as ASCII
    $Output | Out-File -FilePath $CacheFile -Encoding ascii -Force
}

# Output cache content
Get-Content $CacheFile -ErrorAction SilentlyContinue

