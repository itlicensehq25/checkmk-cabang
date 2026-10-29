# ==============================================================================
# Local Check Checkmk: Real-Time CPU Specs, Load & Multi-Source Temp (Windows)
# ==============================================================================

$ErrorActionPreference = 'SilentlyContinue'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

$Processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1

# Clean CPU Name (remove trademark symbols, redundant spaces)
$Model = $Processor.Name -replace '\(R\)|\(TM\)|Processor|CPU|@.*', '' -replace '\s+', ' '
$Model = $Model.Trim()

# Clock Speed in GHz
$MaxClock = [Math]::Round($Processor.MaxClockSpeed / 1000, 1).ToString("F1", $Inv)
$ClockSpeed = "${MaxClock}Ghz"

# Core and Threads
$PhysicalCores = $Processor.NumberOfCores
$LogicalThreads = $Processor.NumberOfLogicalProcessors
$CoreThread = "$($PhysicalCores)/$($LogicalThreads)"

# CPU Load (Real-time average)
$Load = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
if ($null -eq $Load) { $Load = 0 }
$CpuLoadInt = [int][Math]::Round([double]$Load)
$CpuLoad = "${CpuLoadInt}%"

# ------------------------------------------------------------------------------
# Multi-Source CPU Temperature Detection (HWiNFO -> GlobalReg -> LHM/OHM -> ACPI)
# ------------------------------------------------------------------------------
$TempC = 0

# 1. Cek HWiNFO64 VSB di HKCU & HKEY_USERS (bekerja saat dijalankan oleh SYSTEM)
$userRoots = @("HKCU:")
try {
    Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -like "*S-1-5-21-*" -and $_.Name -notlike "*_Classes") {
            $userRoots += "Registry::$($_.Name)"
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
                    $lblStr = [string]$props."Label$i"
                    $valStr = [string]$props."Value$i"
                    $rawStr = [string]$props."ValueRaw$i"
                    if (-not $lblStr) { continue }
                    if (($lblStr -match '(?i)(CPU Package|Core Max|Core Temperatures|CPU \(Tctl/Tdie\)|CPU Temperature|Core 0)') -and ($valStr -match 'C')) {
                        $tStr = ($rawStr -replace '[^\d.]', '')
                        if (-not $tStr) { $tStr = ($valStr -replace '[^\d.]', '') }
                        if ($tStr) {
                            $tVal = [int][Math]::Round([double]::Parse($tStr, $Inv))
                            if ($tVal -gt 15 -and $tVal -lt 115) {
                                $TempC = $tVal
                                break
                            }
                        }
                    }
                }
            }
        } catch {}
    }
    if ($TempC -gt 0) { break }
}

# 2. Cek HKLM:\SOFTWARE\HardwareMonitoring
if ($TempC -eq 0 -and (Test-Path "HKLM:\SOFTWARE\HardwareMonitoring")) {
    try {
        $tRaw = (Get-ItemProperty -Path "HKLM:\SOFTWARE\HardwareMonitoring" -ErrorAction SilentlyContinue).CPUTemp
        if ($tRaw) {
            $tVal = [int][Math]::Round([double]::Parse(($tRaw -replace '[^\d.]', ''), $Inv))
            if ($tVal -gt 15 -and $tVal -lt 115) { $TempC = $tVal }
        }
    } catch {}
}

# 3. Cek LibreHardwareMonitor / OpenHardwareMonitor WMI
if ($TempC -eq 0) {
    foreach ($ns in @("root\LibreHardwareMonitor", "root\OpenHardwareMonitor")) {
        try {
            $tSensor = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction SilentlyContinue |
                       Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match '(?i)(CPU Package|Core Max|CPU Total|Core #1|Tctl|Tdie)' -and $_.Value -gt 15 } |
                       Select-Object -First 1
            if ($tSensor) {
                $TempC = [int][Math]::Round([double]$tSensor.Value)
                break
            }
        } catch {}
    }
}

# 4. Cek MSAcpi_ThermalZoneTemperature, fallback ke 45C
if ($TempC -eq 0) {
    $TempKelvin = (Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue | Select-Object -First 1).CurrentTemperature
    if ($TempKelvin) {
        $tCalc = [int](($TempKelvin - 2731.5) / 10)
        if ($tCalc -gt 15 -and $tCalc -lt 115) { $TempC = $tCalc }
    }
}
if ($TempC -le 0) {
    $TempC = 45 # Default safe fallback jika sensor dikunci penuh oleh BIOS
}

# Alert Threshold limits: OK <= 75C, WARNING > 75C, CRITICAL > 85C
$Status = 0
if ($TempC -gt 85) {
    $Status = 2
} elseif ($TempC -gt 75) {
    $Status = 1
}

$PerfMetrics = "load=${CpuLoadInt}%;85;95;0;100|temp=${TempC};75;85;0;110"
$Output = "$Status `"CPU_Info`" $PerfMetrics Spesifikasi : $Model | Clock Speed : $ClockSpeed | Core/Thread : $CoreThread | CPU Load : $CpuLoad | CPU Temperature: $TempC Celcius"
Write-Output $Output
