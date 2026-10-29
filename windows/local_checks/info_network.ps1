# ==============================================================================
# Local Check Checkmk: Real-Time Network Info, Throughput & 3-Line Ping Monitor
# Platform   : Windows Client / Server (PowerShell 5.1+)
# Fitur Baru :
#   1. Real-Time Interface Throughput (RX/TX Rate & Total Download/Upload)
#   2. Ping 4x setiap 1 menit ke 3 Target (192.168.122.10, 8.8.8.8, & Gateway Cabang)
#   3. Akumulasi laporan 1 Jam (60x4 = 240 paket) dikirim ke Checkmk dalam 3 baris
#   4. Log lokal (ping_history.log) dengan retensi bergulir 30 hari ala CCTV
#      (otomatis menghapus log di hari ke-31 dan seterusnya)
# ==============================================================================

param(
    [switch]$CollectOnly
)

$ErrorActionPreference = "SilentlyContinue"
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ------------------------------------------------------------------------------
# 1. KONFIGURASI TARGET PING & RETENSI LOG (Identik dengan Android PDA v1.3.7)
# ------------------------------------------------------------------------------
# Isi $ManualGatewayIP jika ingin mengunci IP Gateway Cabang secara manual di skrip,
# atau biarkan kosong ("") agar membaca dari C:\ProgramData\checkmk\agent\config\gateway_ip.txt
# maupun deteksi otomatis dari Default Gateway cabang yang sedang aktif.
$ManualGatewayIP    = ""
$TargetLocal        = "192.168.122.10"
$TargetInternet     = "8.8.8.8"

$ServiceLocal       = "Ping_192.168.122.10"
$ServiceInternet    = "Ping_8.8.8.8"
$ServiceGateway     = "Ping_Gateway"

$PingsPerMinute     = 4
$ReportIntervalSec  = 3600   # 1 Jam (3600 detik)
$SamplesPerHour     = 60     # 60 sampel x 1 menit = 1 jam (240 paket)
$LogRetentionDays   = 30     # Retensi log 30 hari (Hari ke-31+ otomatis dihapus)
$PruneIntervalSec   = 3600   # Interval pemeriksaan pemangkasan log (1 jam)
$MaxEmergencyBytes  = 35MB   # Batas aman darurat ukuran file log

$AgentDir           = "C:\ProgramData\checkmk\agent"
$ConfigDir          = "$AgentDir\config"
$LogDir             = "$AgentDir\log_custom"
$CacheDir           = "$AgentDir\cache"

$GatewayConfigFile  = "$ConfigDir\gateway_ip.txt"
$PingLogFile        = "$LogDir\ping_history.log"
$PingStateFile      = "$CacheDir\ping_monitor_state.json"

foreach ($dir in @($ConfigDir, $LogDir, $CacheDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ------------------------------------------------------------------------------
# 2. FUNGSI HELPER: VALIDASI IP & DETEKSI GATEWAY CABANG
# ------------------------------------------------------------------------------
function Test-ValidIPv4 {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    $clean = $Ip.Trim()
    if ($clean -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($octet in $Matches[1..4]) {
        $val = [int]$octet
        if ($val -lt 0 -or $val -gt 255) { return $false }
    }
    return ($clean -ne "0.0.0.0")
}

function Get-DetectedDefaultGateway {
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                 Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
                 Sort-Object RouteMetric, InterfaceMetric |
                 Select-Object -First 1
        if ($route -and (Test-ValidIPv4 $route.NextHop)) {
            return $route.NextHop.Trim()
        }
    } catch {}

    try {
        $wmiGw = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE" -ErrorAction SilentlyContinue |
                 Where-Object { $_.DefaultIPGateway } |
                 Select-Object -First 1
        if ($wmiGw -and $wmiGw.DefaultIPGateway.Count -gt 0) {
            $gw = [string]$wmiGw.DefaultIPGateway[0]
            if (Test-ValidIPv4 $gw) { return $gw.Trim() }
        }
    } catch {}
    return ""
}

function Get-BranchGatewayIP {
    # Prioritas 1: Variabel manual di skrip
    if (Test-ValidIPv4 $ManualGatewayIP) {
        return $ManualGatewayIP.Trim()
    }

    # Prioritas 2: File konfigurasi gateway_ip.txt (jika diset manual/locked saat instalasi)
    $savedIp = ""
    $isLocked = $false
    if (Test-Path $GatewayConfigFile) {
        try {
            $raw = (Get-Content -Path $GatewayConfigFile -TotalCount 1 -ErrorAction SilentlyContinue)
            if ($raw) {
                $raw = $raw.Trim()
                if ($raw.StartsWith("LOCKED:", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $candidate = $raw.Substring(7).Trim()
                    if (Test-ValidIPv4 $candidate) {
                        return $candidate
                    }
                } elseif (Test-ValidIPv4 $raw) {
                    $savedIp = $raw
                }
            }
        } catch {}
    }

    # Prioritas 3: Deteksi otomatis dari tabel routing aktif & simpan sebagai fallback
    $detected = Get-DetectedDefaultGateway
    if (Test-ValidIPv4 $detected) {
        if ($detected -ne $savedIp) {
            try { Set-Content -Path $GatewayConfigFile -Value $detected -Encoding ASCII -Force } catch {}
        }
        return $detected
    }

    return $savedIp
}

# ------------------------------------------------------------------------------
# 3. FUNGSI REGISTRASI BACKGROUND TASK 1 MENIT (SELF-HEALING)
# ------------------------------------------------------------------------------
function Ensure-PingScheduledTask {
    $TaskName = "Checkmk_Ping_Monitor"
    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existing) {
            $scriptPath = $MyInvocation.ScriptName
            if ([string]::IsNullOrWhiteSpace($scriptPath)) {
                $scriptPath = "$AgentDir\local\info_network.ps1"
            }
            if (Test-Path $scriptPath) {
                $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -CollectOnly"
                $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
                $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
                $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
                Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            }
        }
    } catch {}
}

# ------------------------------------------------------------------------------
# 4. FUNGSI EKSEKUSI PING 4X PARALEL KE 3 TARGET
# ------------------------------------------------------------------------------
function Invoke-PingBatch4x {
    param([string[]]$Targets, [int]$Count = 4)

    $validTargets = @($Targets | Where-Object { Test-ValidIPv4 $_ } | Select-Object -Unique)
    $rtts = @{}
    foreach ($t in $validTargets) {
        $rtts[$t] = New-Object 'System.Collections.Generic.List[double]'
    }

    for ($i = 0; $i -lt $Count; $i++) {
        $tasks = @{}
        $pingers = @{}
        foreach ($t in $validTargets) {
            try {
                $p = New-Object System.Net.NetworkInformation.Ping
                $pingers[$t] = $p
                $tasks[$t] = $p.SendPingAsync($t, 1000)
            } catch {}
        }

        if ($tasks.Count -gt 0) {
            try {
                [System.Threading.Tasks.Task]::WhenAll([System.Threading.Tasks.Task[]]($tasks.Values)).Wait(1500) | Out-Null
            } catch {}
        }

        foreach ($t in $validTargets) {
            try {
                $task = $tasks[$t]
                if ($task -and $task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                    $reply = $task.Result
                    if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $rtts[$t].Add([double]$reply.RoundtripTime)
                    }
                }
            } catch {}
            try {
                if ($pingers[$t]) { $pingers[$t].Dispose() }
            } catch {}
        }

        if ($i -lt ($Count - 1)) {
            Start-Sleep -Milliseconds 150
        }
    }

    $samples = @{}
    foreach ($t in $validTargets) {
        $list = $rtts[$t]
        $rx = $list.Count
        $tx = $Count
        $loss = (($tx - $rx) * 100.0) / $tx
        if ($rx -gt 0) {
            $min = ($list | Measure-Object -Minimum).Minimum
            $max = ($list | Measure-Object -Maximum).Maximum
            $avg = ($list | Measure-Object -Average).Average
        } else {
            $min = -1.0
            $max = -1.0
            $avg = -1.0
        }
        $samples[$t] = @{
            target = $t
            tx     = $tx
            rx     = $rx
            loss   = [double]$loss
            min    = [double]$min
            avg    = [double]$avg
            max    = [double]$max
        }
    }
    return $samples
}

# ------------------------------------------------------------------------------
# 5. FUNGSI FORMAT LOG & RETENSI 30 HARI ALA CCTV (HARI KE-31+ DIHAPUS)
# ------------------------------------------------------------------------------
function Format-SampleLogLine {
    param([string]$Timestamp, [hashtable]$Sample)
    $avgStr = if ($Sample.avg -ge 0) { $Sample.avg.ToString("F1", $Inv) + "ms" } else { "TIMEOUT" }
    $minStr = if ($Sample.min -ge 0) { $Sample.min.ToString("F1", $Inv) + "ms" } else { "-" }
    $maxStr = if ($Sample.max -ge 0) { $Sample.max.ToString("F1", $Inv) + "ms" } else { "-" }
    $lossStr = $Sample.loss.ToString("F0", $Inv)
    $targetPadded = $Sample.target.PadRight(24)
    return "[$Timestamp] PING $targetPadded | tx=$($Sample.tx) rx=$($Sample.rx) loss=${lossStr}% min=$minStr avg=$avgStr max=$maxStr"
}

function Invoke-PrunePingLogs30Days {
    param([datetime]$NowDt)
    if (-not (Test-Path $PingLogFile)) { return }
    try {
        $cutoffStr = $NowDt.AddDays(-$LogRetentionDays).ToString("yyyy-MM-dd HH:mm:ss", $Inv)
        $fileInfo  = Get-Item $PingLogFile -ErrorAction SilentlyContinue
        if (-not $fileInfo) { return }

        $needsPrune = ($fileInfo.Length -gt $MaxEmergencyBytes)
        if (-not $needsPrune) {
            $firstLines = Get-Content -Path $PingLogFile -TotalCount 5 -ErrorAction SilentlyContinue
            foreach ($line in $firstLines) {
                if ($line -and $line.Length -ge 21 -and $line[0] -eq '[' -and $line[20] -eq ']') {
                    $ts = $line.Substring(1, 19)
                    if ([string]::CompareOrdinal($ts, $cutoffStr) -lt 0) {
                        $needsPrune = $true
                    }
                    break
                }
            }
        }

        if (-not $needsPrune) { return }

        $tempFile = "$PingLogFile.tmp"
        $reader = [System.IO.StreamReader]::new($PingLogFile, [System.Text.Encoding]::UTF8)
        $writer = [System.IO.StreamWriter]::new($tempFile, $false, [System.Text.Encoding]::UTF8)
        $keeping = $false
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if (-not $keeping) {
                    if ($line.Length -ge 21 -and $line[0] -eq '[' -and $line[20] -eq ']') {
                        $ts = $line.Substring(1, 19)
                        if ([string]::CompareOrdinal($ts, $cutoffStr) -ge 0) {
                            $keeping = $true
                        }
                    } else {
                        continue
                    }
                }
                if ($keeping) {
                    $writer.WriteLine($line)
                }
            }
        } finally {
            $reader.Close()
            $writer.Flush()
            $writer.Close()
        }

        Move-Item -Path $tempFile -Destination $PingLogFile -Force -ErrorAction SilentlyContinue
    } catch {}
}

# ------------------------------------------------------------------------------
# 6. FUNGSI FORMAT BARIS OUTPUT CHECKMK (IDENTIK DENGAN ANDROID PDA)
# ------------------------------------------------------------------------------
function Format-CheckmkPingLine {
    param(
        [string]$ServiceName,
        [string]$TargetDisplay,
        [int]$Samples,
        [int]$Tx,
        [int]$Rx,
        [double]$LossPct,
        [double]$AvgMs,
        [double]$MinMs,
        [double]$MaxMs,
        [int]$FailMinutes,
        [long]$StartEpoch,
        [long]$EndEpoch,
        [double]$LastMs,
        [double]$WarnRttMs,
        [double]$CritRttMs,
        [bool]$CompletedHour
    )

    $state = 0
    if ($Tx -gt 0 -and ($LossPct -ge 50.0 -or ($AvgMs -ge 0 -and $AvgMs -ge $CritRttMs))) {
        $state = 2
    } elseif ($Tx -gt 0 -and ($LossPct -ge 20.0 -or ($AvgMs -ge 0 -and $AvgMs -ge $WarnRttMs))) {
        $state = 1
    }

    $warnInt = [Math]::Round($WarnRttMs).ToString($Inv)
    $critInt = [Math]::Round($CritRttMs).ToString($Inv)

    $rtaMetric = if ($AvgMs -ge 0) {
        "rta=$($AvgMs.ToString('F2', $Inv))ms;$warnInt;$critInt;0"
    } else {
        "rta=0.00ms;$warnInt;$critInt;0"
    }
    $plMetric  = "pl=$($LossPct.ToString('F1', $Inv))%;20;50;0;100"
    $minMetric = if ($MinMs -ge 0) { "|rtmin=$($MinMs.ToString('F2', $Inv))ms" } else { "" }
    $maxMetric = if ($MaxMs -ge 0) { "|rtmax=$($MaxMs.ToString('F2', $Inv))ms" } else { "" }
    $metrics   = "$rtaMetric|$plMetric$minMetric$maxMetric"

    $avgStr    = if ($AvgMs -ge 0) { "$($AvgMs.ToString('F1', $Inv)) ms" } else { "TIMEOUT" }
    $minMaxStr = if ($MinMs -ge 0 -and $MaxMs -ge 0) { "$($MinMs.ToString('F1', $Inv))/$($MaxMs.ToString('F1', $Inv)) ms" } else { "N/A" }
    $lastStr   = if ($LastMs -ge 0) { "$($LastMs.ToString('F1', $Inv)) ms" } else { "TIMEOUT" }

    $startDt   = [DateTimeOffset]::FromUnixTimeSeconds($StartEpoch).LocalDateTime.ToString("HH:mm", $Inv)
    $endDt     = [DateTimeOffset]::FromUnixTimeSeconds($EndEpoch).LocalDateTime.ToString("HH:mm", $Inv)
    $windowStr = "$startDt-$endDt"

    $modeLabel = if ($CompletedHour) {
        "1h Summary (${Samples}x4=${Tx} pkt)"
    } else {
        "Buffering 1h (${Samples}/60m, ${Tx} pkt)"
    }

    $stateStr = switch ($state) { 2 { "CRITICAL" } 1 { "WARNING" } default { "OK" } }
    $maxSamples = [Math]::Max(1, $Samples)
    $lossFormatted = "$($LossPct.ToString('F1', $Inv))% ($Rx/$Tx rx)"

    return "$state `"$ServiceName`" $metrics Status : $stateStr | Target : $TargetDisplay | Mode : $modeLabel | Loss : $lossFormatted | Avg RTT : $avgStr | Min/Max : $minMaxStr | Last : $lastStr | Timeout Min : $FailMinutes/$maxSamples | Window : $windowStr | Log : 30d Rolling"
}

# ------------------------------------------------------------------------------
# 7. FUNGSI UPDATE AKUMULATOR 1 JAM & SIMPAN LOG PER MENIT
# ------------------------------------------------------------------------------
function New-EmptyTargetState {
    param([long]$NowEpoch)
    return @{
        win_start_sec  = $NowEpoch
        win_samples    = 0
        win_tx         = 0
        win_rx         = 0
        win_fail_min   = 0
        win_rtt_count  = 0
        win_rtt_sum    = 0.0
        win_rtt_min    = -1.0
        win_rtt_max    = -1.0
        last_sample_sec= 0
        last_avg_ms    = -1.0
        last_loss      = 0.0
        pub_sec        = 0
        pub_line       = ""
    }
}

function Load-PingState {
    param([long]$NowEpoch)
    if (Test-Path $PingStateFile) {
        try {
            $raw = Get-Content -Path $PingStateFile -Raw -Encoding UTF8 -ErrorAction Stop
            $obj = ConvertFrom-Json $raw -ErrorAction Stop
            $state = @{
                last_collect_sec = [long]($obj.last_collect_sec)
                last_prune_sec   = [long]($obj.last_prune_sec)
                last_gateway_ip  = [string]($obj.last_gateway_ip)
                targets          = @{}
            }
            foreach ($k in @("local", "internet", "gateway")) {
                $tObj = $obj.targets.$k
                if ($tObj) {
                    $state.targets[$k] = @{
                        win_start_sec   = [long]$tObj.win_start_sec
                        win_samples     = [int]$tObj.win_samples
                        win_tx          = [int]$tObj.win_tx
                        win_rx          = [int]$tObj.win_rx
                        win_fail_min    = [int]$tObj.win_fail_min
                        win_rtt_count   = [int]$tObj.win_rtt_count
                        win_rtt_sum     = [double]$tObj.win_rtt_sum
                        win_rtt_min     = [double]$tObj.win_rtt_min
                        win_rtt_max     = [double]$tObj.win_rtt_max
                        last_sample_sec = [long]$tObj.last_sample_sec
                        last_avg_ms     = [double]$tObj.last_avg_ms
                        last_loss       = [double]$tObj.last_loss
                        pub_sec         = [long]$tObj.pub_sec
                        pub_line        = [string]$tObj.pub_line
                    }
                } else {
                    $state.targets[$k] = New-EmptyTargetState -NowEpoch $NowEpoch
                }
            }
            return $state
        } catch {}
    }

    return @{
        last_collect_sec = 0L
        last_prune_sec   = 0L
        last_gateway_ip  = ""
        targets          = @{
            local    = New-EmptyTargetState -NowEpoch $NowEpoch
            internet = New-EmptyTargetState -NowEpoch $NowEpoch
            gateway  = New-EmptyTargetState -NowEpoch $NowEpoch
        }
    }
}

function Save-PingState {
    param([hashtable]$State)
    try {
        $tempState = "$PingStateFile.tmp"
        $json = $State | ConvertTo-Json -Depth 6
        Set-Content -Path $tempState -Value $json -Encoding UTF8 -Force
        Move-Item -Path $tempState -Destination $PingStateFile -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Update-SingleTargetAccumulator {
    param(
        [hashtable]$TState,
        [string]$ServiceName,
        [string]$TargetDisplay,
        [hashtable]$Sample,
        [long]$NowEpoch,
        [string]$NowStr,
        [double]$WarnRttMs,
        [double]$CritRttMs
    )

    if ($TState.win_start_sec -le 0 -or $NowEpoch -lt $TState.win_start_sec) {
        $TState.win_start_sec = $NowEpoch
    }

    $TState.win_samples  = [int]$TState.win_samples + 1
    $TState.win_tx       = [int]$TState.win_tx + [int]$Sample.tx
    $TState.win_rx       = [int]$TState.win_rx + [int]$Sample.rx
    if ($Sample.rx -eq 0) {
        $TState.win_fail_min = [int]$TState.win_fail_min + 1
    }

    if ($Sample.avg -ge 0) {
        $TState.win_rtt_count = [int]$TState.win_rtt_count + 1
        $TState.win_rtt_sum   = [double]$TState.win_rtt_sum + [double]$Sample.avg
    }
    if ($Sample.min -ge 0) {
        if ($TState.win_rtt_min -lt 0 -or $Sample.min -lt $TState.win_rtt_min) {
            $TState.win_rtt_min = [double]$Sample.min
        }
    }
    if ($Sample.max -ge 0) {
        if ($TState.win_rtt_max -lt 0 -or $Sample.max -gt $TState.win_rtt_max) {
            $TState.win_rtt_max = [double]$Sample.max
        }
    }

    $TState.last_sample_sec = $NowEpoch
    $TState.last_avg_ms     = [double]$Sample.avg
    $TState.last_loss       = [double]$Sample.loss

    $elapsedSec = $NowEpoch - $TState.win_start_sec
    $hourCompleted = ($elapsedSec -ge $ReportIntervalSec) -or ($TState.win_samples -ge $SamplesPerHour)

    if ($hourCompleted) {
        $lossPct = if ($TState.win_tx -gt 0) { (($TState.win_tx - $TState.win_rx) * 100.0) / $TState.win_tx } else { 100.0 }
        $avgMs   = if ($TState.win_rtt_count -gt 0) { $TState.win_rtt_sum / $TState.win_rtt_count } else { -1.0 }
        $minMs   = [double]$TState.win_rtt_min
        $maxMs   = [double]$TState.win_rtt_max

        $hourlyLine = Format-CheckmkPingLine `
            -ServiceName $ServiceName `
            -TargetDisplay $TargetDisplay `
            -Samples $TState.win_samples `
            -Tx $TState.win_tx `
            -Rx $TState.win_rx `
            -LossPct $lossPct `
            -AvgMs $avgMs `
            -MinMs $minMs `
            -MaxMs $maxMs `
            -FailMinutes $TState.win_fail_min `
            -StartEpoch $TState.win_start_sec `
            -EndEpoch $NowEpoch `
            -LastMs $Sample.avg `
            -WarnRttMs $WarnRttMs `
            -CritRttMs $CritRttMs `
            -CompletedHour $true

        $TState.pub_line = $hourlyLine
        $TState.pub_sec  = $NowEpoch

        # Catat baris rangkuman 1 jam ke dalam ping_history.log
        $startShort = [DateTimeOffset]::FromUnixTimeSeconds($TState.win_start_sec).LocalDateTime.ToString("HH:mm", $Inv)
        $endShort   = [DateTimeOffset]::FromUnixTimeSeconds($NowEpoch).LocalDateTime.ToString("HH:mm", $Inv)
        $avgSummary = if ($avgMs -ge 0) { $avgMs.ToString("F1", $Inv) + "ms" } else { "TIMEOUT" }
        $mmSummary  = if ($minMs -ge 0 -and $maxMs -ge 0) { "$($minMs.ToString('F1', $Inv))/$($maxMs.ToString('F1', $Inv))ms" } else { "N/A" }
        $summaryLog = "[$NowStr] === 1H CHECKMK REPORT [$TargetDisplay] window=$startShort-$endShort samples=$($TState.win_samples) pkt=$($TState.win_rx)/$($TState.win_tx) loss=$($lossPct.ToString('F1', $Inv))% avg=$avgSummary min/max=$mmSummary ==="
        try { Add-Content -Path $PingLogFile -Value $summaryLog -Encoding UTF8 } catch {}

        # Reset window 1 jam untuk jam berikutnya
        $TState.win_start_sec = $NowEpoch
        $TState.win_samples   = 0
        $TState.win_tx        = 0
        $TState.win_rx        = 0
        $TState.win_fail_min  = 0
        $TState.win_rtt_count = 0
        $TState.win_rtt_sum   = 0.0
        $TState.win_rtt_min   = -1.0
        $TState.win_rtt_max   = -1.0
    }
}

function Invoke-MinutePingCollection {
    param([switch]$Force)

    $nowDt    = Get-Date
    $nowEpoch = [DateTimeOffset]::new($nowDt).ToUnixTimeSeconds()
    $nowStr   = $nowDt.ToString("yyyy-MM-dd HH:mm:ss", $Inv)

    $state = Load-PingState -NowEpoch $nowEpoch
    $gatewayIp = Get-BranchGatewayIP

    # Reset akumulator gateway apabila IP Gateway Cabang berubah
    if ($gatewayIp -ne $state.last_gateway_ip) {
        $state.last_gateway_ip = $gatewayIp
        $state.targets["gateway"] = New-EmptyTargetState -NowEpoch $nowEpoch
    }

    # Hindari duplikasi sampel dalam menit yang sama (< 45 detik) kecuali dipaksa
    if (-not $Force -and $state.last_collect_sec -gt 0 -and (($nowEpoch - $state.last_collect_sec) -lt 45)) {
        return $state
    }

    $pingTargets = @($TargetLocal, $TargetInternet)
    if (Test-ValidIPv4 $gatewayIp) {
        $pingTargets += $gatewayIp
    }

    $batchResults = Invoke-PingBatch4x -Targets $pingTargets -Count $PingsPerMinute
    $sLocal = $batchResults[$TargetLocal]
    $sNet   = $batchResults[$TargetInternet]
    $sGw    = if (Test-ValidIPv4 $gatewayIp) { $batchResults[$gatewayIp] } else { $null }

    # 1. Tulis ke ping_history.log
    $logLines = New-Object 'System.Collections.Generic.List[string]'
    if ($sLocal) { $logLines.Add((Format-SampleLogLine -Timestamp $nowStr -Sample $sLocal)) }
    if ($sNet)   { $logLines.Add((Format-SampleLogLine -Timestamp $nowStr -Sample $sNet)) }
    if ($sGw) {
        $gwSampleForLog = @{
            target = "$gatewayIp (GW)"
            tx     = $sGw.tx
            rx     = $sGw.rx
            loss   = $sGw.loss
            min    = $sGw.min
            avg    = $sGw.avg
            max    = $sGw.max
        }
        $logLines.Add((Format-SampleLogLine -Timestamp $nowStr -Sample $gwSampleForLog))
    }
    if ($logLines.Count -gt 0) {
        try { Add-Content -Path $PingLogFile -Value ($logLines -join "`r`n") -Encoding UTF8 } catch {}
    }

    # 2. Update akumulator 1 jam untuk ke-3 target
    if ($sLocal) {
        Update-SingleTargetAccumulator -TState $state.targets["local"] -ServiceName $ServiceLocal -TargetDisplay $TargetLocal -Sample $sLocal -NowEpoch $nowEpoch -NowStr $nowStr -WarnRttMs 100.0 -CritRttMs 250.0
    }
    if ($sNet) {
        Update-SingleTargetAccumulator -TState $state.targets["internet"] -ServiceName $ServiceInternet -TargetDisplay $TargetInternet -Sample $sNet -NowEpoch $nowEpoch -NowStr $nowStr -WarnRttMs 150.0 -CritRttMs 300.0
    }
    if ($sGw) {
        Update-SingleTargetAccumulator -TState $state.targets["gateway"] -ServiceName $ServiceGateway -TargetDisplay "$gatewayIp (Gateway Cabang)" -Sample $sGw -NowEpoch $nowEpoch -NowStr $nowStr -WarnRttMs 50.0 -CritRttMs 150.0
    }

    # 3. Pangkas log > 30 hari (Hari ke-31+) setiap 1 jam
    if ($state.last_prune_sec -le 0 -or (($nowEpoch - $state.last_prune_sec) -ge $PruneIntervalSec)) {
        Invoke-PrunePingLogs30Days -NowDt $nowDt
        $state.last_prune_sec = $nowEpoch
    }

    $state.last_collect_sec = $nowEpoch
    Save-PingState -State $state
    return $state
}

function Get-TargetCheckmkOutputLine {
    param(
        [hashtable]$TState,
        [string]$ServiceName,
        [string]$TargetDisplay,
        [double]$WarnRttMs,
        [double]$CritRttMs,
        [long]$NowEpoch
    )

    $line = $TState.pub_line
    $pubSec = [long]$TState.pub_sec

    if ([string]::IsNullOrWhiteSpace($line)) {
        $samples = [int]$TState.win_samples
        $tx      = [int]$TState.win_tx
        $rx      = [int]$TState.win_rx
        $lossPct = if ($tx -gt 0) { (($tx - $rx) * 100.0) / $tx } else { 0.0 }
        $avgMs   = if ($TState.win_rtt_count -gt 0) { $TState.win_rtt_sum / $TState.win_rtt_count } else { -1.0 }
        $minMs   = [double]$TState.win_rtt_min
        $maxMs   = [double]$TState.win_rtt_max
        $startSec = if ($TState.win_start_sec -gt 0) { [long]$TState.win_start_sec } else { $NowEpoch }
        $endSec   = if ($TState.last_sample_sec -gt 0) { [long]$TState.last_sample_sec } else { $NowEpoch }

        $line = Format-CheckmkPingLine `
            -ServiceName $ServiceName `
            -TargetDisplay $TargetDisplay `
            -Samples $samples `
            -Tx $tx `
            -Rx $rx `
            -LossPct $lossPct `
            -AvgMs $avgMs `
            -MinMs $minMs `
            -MaxMs $maxMs `
            -FailMinutes $TState.win_fail_min `
            -StartEpoch $startSec `
            -EndEpoch $endSec `
            -LastMs $TState.last_avg_ms `
            -WarnRttMs $WarnRttMs `
            -CritRttMs $CritRttMs `
            -CompletedHour $false
        $pubSec = $startSec
    }

    if ($pubSec -le 0 -or $pubSec -gt $NowEpoch) { $pubSec = $NowEpoch }
    return $line
}

# ------------------------------------------------------------------------------
# 8. MODE EKSEKUSI: BACKGROUND COLLECTOR VS CHECKMK AGENT POLL
# ------------------------------------------------------------------------------
if ($CollectOnly) {
    Invoke-MinutePingCollection | Out-Null
    Exit 0
}

# Pastikan Scheduled Task 1 menit terdaftar
Ensure-PingScheduledTask

# Ambil / mutakhirkan sampel ping (otomatis skip ping jika baru diambil < 45 detik lalu oleh Task Scheduler)
$PingState = Invoke-MinutePingCollection

# ------------------------------------------------------------------------------
# 9. REAL-TIME NETWORK INTERFACE THROUGHPUT (Info_Network_<Interface>)
# ------------------------------------------------------------------------------
$ActiveAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" })

if ($ActiveAdapters.Count -eq 0) {
    Write-Output "0 `"Info_Network_NoActive`" - OK - No active network interfaces detected."
} else {
    $StatsPhase1 = @{}
    $IpMap       = @{}

    foreach ($Adapter in $ActiveAdapters) {
        $IfaceName = $Adapter.Name
        $s1 = $Adapter | Get-NetAdapterStatistics -ErrorAction SilentlyContinue
        if ($s1) {
            $StatsPhase1[$IfaceName] = $s1
            $ipObj = Get-NetIPAddress -InterfaceAlias $IfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            $IpMap[$IfaceName] = if ($ipObj -and $ipObj.IPAddress) { $ipObj.IPAddress } else { "No IP" }
        }
    }

    if ($StatsPhase1.Count -gt 0) {
        Start-Sleep -Seconds 1
    }

    $FormatTotal = {
        param([uint64]$b)
        if ($b -ge 1073741824) { ($b / 1073741824).ToString("F2", $Inv) + " GB" }
        elseif ($b -ge 1048576) { ($b / 1048576).ToString("F2", $Inv) + " MB" }
        else { ($b / 1024).ToString("F2", $Inv) + " KB" }
    }

    $FormatRate = {
        param([uint64]$b)
        if ($b -ge 1048576) { ($b / 1048576).ToString("F2", $Inv) + " MB/s" }
        elseif ($b -ge 1024) { ($b / 1024).ToString("F2", $Inv) + " KB/s" }
        else { "$($b) B/s" }
    }

    foreach ($Adapter in $ActiveAdapters) {
        $IfaceName = $Adapter.Name
        if (-not $StatsPhase1.ContainsKey($IfaceName)) { continue }

        $s1 = $StatsPhase1[$IfaceName]
        $s2 = $Adapter | Get-NetAdapterStatistics -ErrorAction SilentlyContinue
        if (-not $s2) { continue }

        $Rx1 = [int64]$s1.ReceivedBytes
        $Tx1 = [int64]$s1.SentBytes
        $Rx2 = [int64]$s2.ReceivedBytes
        $Tx2 = [int64]$s2.SentBytes

        $RxRate = $Rx2 - $Rx1
        $TxRate = $Tx2 - $Tx1
        if ($RxRate -lt 0) { $RxRate = 0 }
        if ($TxRate -lt 0) { $TxRate = 0 }

        $TotalRxHR = &$FormatTotal ([uint64]$Rx2)
        $TotalTxHR = &$FormatTotal ([uint64]$Tx2)
        $RxRateHR  = &$FormatRate ([uint64]$RxRate)
        $TxRateHR  = &$FormatRate ([uint64]$TxRate)

        $CleanIfaceName = $IfaceName -replace '[^\w\s-]', ''
        $IP = $IpMap[$IfaceName]
        $ServiceName = "Info_Network_$CleanIfaceName"

        Write-Output "0 `"$ServiceName`" in=$($Rx2)c|out=$($Tx2)c OK - IP Address: $IP | Total Download: $TotalRxHR | Total Upload: $TotalTxHR | RX Rate : $RxRateHR | TX Rate : $TxRateHR"
    }
}

# ------------------------------------------------------------------------------
# 10. CETAK 3 BARIS PING MONITOR KE CHECKMK (192.168.122.10, 8.8.8.8, & Gateway)
# ------------------------------------------------------------------------------
$NowEpochOut = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$GatewayIpOut = Get-BranchGatewayIP

$LineLocal = Get-TargetCheckmkOutputLine -TState $PingState.targets["local"] -ServiceName $ServiceLocal -TargetDisplay $TargetLocal -WarnRttMs 100.0 -CritRttMs 250.0 -NowEpoch $NowEpochOut
$LineNet   = Get-TargetCheckmkOutputLine -TState $PingState.targets["internet"] -ServiceName $ServiceInternet -TargetDisplay $TargetInternet -WarnRttMs 150.0 -CritRttMs 300.0 -NowEpoch $NowEpochOut

Write-Output $LineLocal
Write-Output $LineNet

if (Test-ValidIPv4 $GatewayIpOut) {
    $LineGw = Get-TargetCheckmkOutputLine -TState $PingState.targets["gateway"] -ServiceName $ServiceGateway -TargetDisplay "$GatewayIpOut (Gateway Cabang)" -WarnRttMs 50.0 -CritRttMs 150.0 -NowEpoch $NowEpochOut
    Write-Output $LineGw
} else {
    Write-Output "1 `"$ServiceGateway`" - Status : WARNING | Target : Belum Terdeteksi | Remark : Isi IP Gateway Cabang di $GatewayConfigFile"
}
