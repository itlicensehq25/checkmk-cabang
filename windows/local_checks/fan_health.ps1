# ==============================================================================
# Local Check Checkmk: Multi-Layer FAN & Thermal Cooling Health (Windows)
# Perbaikan Utama:
#   1. Memperbaiki bug typo "-Path$targetPath" saat dijalankan oleh SYSTEM service
#   2. Menghapus hardcode ".ValueRaw15" -> Memindai dinamis seluruh sensor 0..99
#      berdasarkan satuan "RPM" atau label Fan (mendukung semua tipe PC/Laptop)
#   3. Multi-source fallback: HWiNFO VSB/Sensors (HKCU & HKEY_USERS),
#      HKLM:\SOFTWARE\HardwareMonitoring, LibreHardwareMonitor/OpenHardwareMonitor
#      WMI, dan Win32_Fan
#   4. Smart EC/BIOS Thermal Correlation untuk laptop modern (Zero-RPM / EC Lock)
# ==============================================================================

$ErrorActionPreference = 'SilentlyContinue'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

$fanSpeed  = 0
$fanSource = ""
$cpuTemp   = 0

# ------------------------------------------------------------------------------
# 1. LAPIS 1: Dynamic Scanner HWiNFO64 VSB & Sensors (HKCU + Semua HKEY_USERS)
# ------------------------------------------------------------------------------
$userRoots = @("HKCU:")
try {
    Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ($name -like "*S-1-5-21-*" -and $name -notlike "*_Classes") {
            $userRoots += "Registry::$name"
        }
    }
} catch {}

foreach ($root in $userRoots) {
    $vsbPath = "$root\Software\HWiNFO64\VSB"
    if (Test-Path $vsbPath) {
        try {
            $props = Get-ItemProperty -Path $vsbPath -ErrorAction SilentlyContinue
            if ($props) {
                for ($i = 0; $i -lt 100; $i++) {
                    $valStr = [string]$props."Value$i"
                    $rawStr = [string]$props."ValueRaw$i"
                    $lblStr = [string]$props."Label$i"
                    $snsStr = [string]$props."Sensor$i"
                    if (-not $valStr -and -not $lblStr) { continue }

                    # Deteksi Sensor Kipas (RPM) secara dinamis
                    if ($valStr -match '(?i)\bRPM\b' -or $lblStr -match '(?i)(CPU Fan|System Fan|Chassis Fan|Fan|Other \(Docking\)|Cooler|Pump)') {
                        $numStr = ($rawStr -replace '[^\d.]', '')
                        if (-not $numStr) { $numStr = ($valStr -replace '[^\d.]', '') }
                        if ($numStr) {
                            $rpmVal = [int][Math]::Round([double]::Parse($numStr, $Inv))
                            if ($rpmVal -gt $fanSpeed -and $rpmVal -lt 15000) {
                                $fanSpeed  = $rpmVal
                                $fanSource = if ($lblStr) { $lblStr } else { "HWiNFO" }
                            }
                        }
                    }

                    # Deteksi Suhu CPU secara dinamis dari HWiNFO
                    if ($cpuTemp -eq 0 -and ($lblStr -match '(?i)(CPU Package|Core Max|Core Temperatures|CPU \(Tctl/Tdie\)|CPU Temperature|Core 0|Temp0)') -and ($valStr -match 'C')) {
                        $tStr = ($rawStr -replace '[^\d.]', '')
                        if (-not $tStr) { $tStr = ($valStr -replace '[^\d.]', '') }
                        if ($tStr) {
                            $tVal = [int][Math]::Round([double]::Parse($tStr, $Inv))
                            if ($tVal -gt 15 -and $tVal -lt 115) {
                                $cpuTemp = $tVal
                            }
                        }
                    }
                }
            }
        } catch {}
    }

    # Cek juga subkey Software\HWiNFO64\Sensors jika VSB belum lengkap
    if ($fanSpeed -eq 0) {
        $sensorsPath = "$root\Software\HWiNFO64\Sensors"
        if (Test-Path $sensorsPath) {
            try {
                Get-ChildItem -Path $sensorsPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $sp = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                    if ($sp -and ($sp.Value -match '(?i)\bRPM\b' -or $sp.Label -match '(?i)(CPU Fan|System Fan|Fan|Other|Docking)')) {
                        $numStr = ([string]$sp.ValueRaw -replace '[^\d.]', '')
                        if (-not $numStr) { $numStr = ([string]$sp.Value -replace '[^\d.]', '') }
                        if ($numStr) {
                            $rpmVal = [int][Math]::Round([double]::Parse($numStr, $Inv))
                            if ($rpmVal -gt $fanSpeed -and $rpmVal -lt 15000) {
                                $fanSpeed  = $rpmVal
                                $fanSource = [string]$sp.Label
                            }
                        }
                    }
                }
            } catch {}
        }
    }
}

# ------------------------------------------------------------------------------
# 2. LAPIS 2: HKLM:\SOFTWARE\HardwareMonitoring (Hasil Sync Lokal)
# ------------------------------------------------------------------------------
if ($fanSpeed -eq 0 -or $cpuTemp -eq 0) {
    $globalReg = "HKLM:\SOFTWARE\HardwareMonitoring"
    if (Test-Path $globalReg) {
        try {
            $gp = Get-ItemProperty -Path $globalReg -ErrorAction SilentlyContinue
            if ($fanSpeed -eq 0 -and $gp.CPUFan) {
                $numStr = ([string]$gp.CPUFan -replace '[^\d.]', '')
                if ($numStr) { $fanSpeed = [int][Math]::Round([double]::Parse($numStr, $Inv)) }
            }
            if ($cpuTemp -eq 0 -and $gp.CPUTemp) {
                $tStr = ([string]$gp.CPUTemp -replace '[^\d.]', '')
                if ($tStr) { $cpuTemp = [int][Math]::Round([double]::Parse($tStr, $Inv)) }
            }
        } catch {}
    }
}

# ------------------------------------------------------------------------------
# 3. LAPIS 3: LibreHardwareMonitor / OpenHardwareMonitor WMI Namespace
# ------------------------------------------------------------------------------
if ($fanSpeed -eq 0 -or $cpuTemp -eq 0) {
    foreach ($ns in @("root\LibreHardwareMonitor", "root\OpenHardwareMonitor")) {
        try {
            $wmiSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction SilentlyContinue
            if ($wmiSensors) {
                if ($fanSpeed -eq 0) {
                    $fSensor = $wmiSensors | Where-Object { $_.SensorType -eq 'Fan' -and $_.Value -gt 0 } | Sort-Object Value -Descending | Select-Object -First 1
                    if ($fSensor) {
                        $fanSpeed  = [int][Math]::Round([double]$fSensor.Value)
                        $fanSource = $fSensor.Name
                    }
                }
                if ($cpuTemp -eq 0) {
                    $tSensor = $wmiSensors | Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match '(?i)(CPU Package|Core Max|CPU Total|Core #1|Tctl|Tdie)' -and $_.Value -gt 15 } | Select-Object -First 1
                    if ($tSensor) {
                        $cpuTemp = [int][Math]::Round([double]$tSensor.Value)
                    }
                }
            }
        } catch {}
    }
}

# ------------------------------------------------------------------------------
# 4. LAPIS 4: WMI Standar Windows (Win32_Fan & ThermalZone)
# ------------------------------------------------------------------------------
if ($fanSpeed -eq 0) {
    try {
        $wmiFan = Get-CimInstance -ClassName Win32_Fan -ErrorAction SilentlyContinue | Where-Object { $_.DesiredSpeed -gt 0 } | Select-Object -First 1
        if ($wmiFan) {
            $fanSpeed  = [int]$wmiFan.DesiredSpeed
            $fanSource = $wmiFan.Name
        }
    } catch {}
}

if ($cpuTemp -eq 0) {
    try {
        $tz = Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tz -and $tz.CurrentTemperature) {
            $tCalc = [int](($tz.CurrentTemperature - 2731.5) / 10)
            if ($tCalc -gt 15 -and $tCalc -lt 115) { $cpuTemp = $tCalc }
        }
    } catch {}
}

# ------------------------------------------------------------------------------
# 5. EVALUASI KONDISI KIPAS & KORELASI TERMAL (EC/BIOS Managed Aware)
# ------------------------------------------------------------------------------
$status    = 0
$statusTxt = "OK"
$tempInfo  = if ($cpuTemp -gt 0) { " | CPU Temp: ${cpuTemp}C" } else { "" }
$perfTemp  = if ($cpuTemp -gt 0) { "|cpu_temp=${cpuTemp};75;85;0;110" } else { "" }

if ($fanSpeed -gt 0) {
    if ($cpuTemp -gt 85 -and $fanSpeed -lt 1600) {
        $status    = 2
        $statusTxt = "CRITICAL"
        $kondisi   = "Suhu CPU Tinggi (${cpuTemp}C) namun putaran Fan lemah (<1600 RPM) - Cek Kipas/Thermal Paste!"
    } elseif ($cpuTemp -gt 75 -and $fanSpeed -lt 1000) {
        $status    = 1
        $statusTxt = "WARNING"
        $kondisi   = "Suhu CPU Panas (${cpuTemp}C) dengan RPM rendah - Pantau Pendinginan"
    } elseif ($fanSpeed -ge 5500) {
        $kondisi = "Maximum / Turbo Cooling"
    } elseif ($fanSpeed -ge 4500) {
        $kondisi = "High Speed (Heavy Load)"
    } elseif ($fanSpeed -ge 2500) {
        $kondisi = "Medium (Active Cooling)"
    } else {
        $kondisi = "Low / Silent (Normal)"
    }

    Write-Output "$status `"FAN_Health`" fan_speed=${fanSpeed};5500;6000;0;6500$perfTemp Status: $statusTxt - FAN Speed: ${fanSpeed} rpm$tempInfo - Kondisi: $kondisi"
} else {
    # Pada PC/Laptop modern di mana EC/BIOS menyembunyikan register RPM atau mode 0dB Passive aktif
    if ($cpuTemp -gt 85) {
        $status    = 2
        $statusTxt = "CRITICAL"
        $kondisi   = "CPU Overheat (${cpuTemp}C) - Periksa Kipas Pendingin / Thermal Paste!"
    } elseif ($cpuTemp -gt 75) {
        $status    = 1
        $statusTxt = "WARNING"
        $kondisi   = "CPU Cukup Panas (${cpuTemp}C) - EC/BIOS Auto Cooling Aktif"
    } else {
        $status    = 0
        $statusTxt = "OK"
        $kondisi   = "EC/BIOS Auto Managed (Zero-RPM Idle / Sensor Dikunci Firmware, Suhu Aman)"
    }

    Write-Output "$status `"FAN_Health`" fan_speed=0;5500;6000;0;6500$perfTemp Status: $statusTxt - FAN Speed: EC/Auto$tempInfo - Kondisi: $kondisi"
}
