# =====================================================================
# Local Check Checkmk: Daily OS & Office License Check (Windows)
# Service: Info_OS dan Info_Office
# Dijalankan sekali sehari setelah pukul 16:00 (atau langsung jika file
# script ini lebih baru dari cache, mis. setelah diperbarui dari GitHub).
#
# Format Info_Office:
#   1 office : <versi office> - Licensed/Tidak Licensed - <serial>
#   >1 office: <office 1> - Licensed - <serial 1> + <office 2> - Licensed - <serial 2>
# Setiap produk (Excel, Word, dst.) mendapat serialnya sendiri.
# =====================================================================
$ErrorActionPreference = 'SilentlyContinue'

# ---------- Pengaturan ----------
$WarnIfUnlicensed = $false   # true = Info_Office jadi WARNING jika ada office yang Tidak Licensed
# --------------------------------

$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$CacheFile = Join-Path $CacheDir "cache_os_office.txt"

# Logika Penjadwalan: Eksekusi Baru Setiap Hari Setelah Pukul 16:00
$Now = Get-Date
$Today16 = Get-Date -Hour 16 -Minute 0 -Second 0
if ($Now -lt $Today16) { $Last16 = $Today16.AddDays(-1) } else { $Last16 = $Today16 }

$NeedUpdate = $true
if (Test-Path $CacheFile) {
    $CacheMtime = (Get-Item $CacheFile).LastWriteTime

    # Jalankan ulang juga jika file script ini lebih baru dari cache (script diperbarui)
    $ScriptNewer = $false
    $ScriptPath = $MyInvocation.MyCommand.Path
    if ($ScriptPath -and (Test-Path $ScriptPath)) {
        if ((Get-Item $ScriptPath).LastWriteTime -gt $CacheMtime) { $ScriptNewer = $true }
    }

    if ($CacheMtime -ge $Last16 -and -not $ScriptNewer) { $NeedUpdate = $false }
}

# ---------------------------------------------------------------------
# Fungsi bantu Office
# ---------------------------------------------------------------------
# Ubah nama lisensi/SKU (mis. "Office 21, Office21Excel2021R_Retail edition")
# menjadi nama yang mudah dibaca (mis. "Microsoft Excel 2021").
function Get-OfficeProductName {
    param([string]$Raw)
    $s = $Raw
    if ($s -match ',') { $s = $s.Substring($s.LastIndexOf(',') + 1) }
    $s = ($s -replace '(?i)\s*edition\s*$', '').Trim()

    $year = ''
    if ($s -match '(2010|2013|2016|2019|2021|2024)') { $year = $Matches[1] }
    # Office 2016 dan lama: nama lisensi tidak memuat tahun (mis. Office16Excel...), pakai kode versi
    if (-not $year -and $Raw -match 'Office\s?(14|15|16|19|21|24)') {
        $year = @{ '14' = '2010'; '15' = '2013'; '16' = '2016'; '19' = '2019'; '21' = '2021'; '24' = '2024' }[$Matches[1]]
    }
    $ltsc = ($s -match 'LTSC') -or ($year -eq '2024' -and $s -match 'VL')

    $name = $null
    foreach ($app in @('Excel', 'Word', 'PowerPoint', 'Outlook', 'Access', 'Publisher', 'OneNote', 'Visio', 'Project')) {
        if ($s -match $app) { $name = "Microsoft $app"; break }
    }
    if (-not $name) {
        if     ($s -match 'O365|Mondo365|Subscription|M365') { $name = 'Microsoft 365 Apps'; $year = '' }
        elseif ($s -match 'ProPlus')                         { $name = 'Microsoft Office Professional Plus' }
        elseif ($s -match 'Standard')                        { $name = 'Microsoft Office Standard' }
        elseif ($s -match 'HomeBusiness|HomeBus')            { $name = 'Microsoft Office Home & Business' }
        elseif ($s -match 'HomeStudent')                     { $name = 'Microsoft Office Home & Student' }
        elseif ($s -match 'Professional')                    { $name = 'Microsoft Office Professional' }
        else                                                 { $name = "Microsoft Office ($s)" }
    }
    $full = $name
    if ($year) { $full += " $year" }
    if ($ltsc) { $full += ' LTSC' }
    return $full
}

# Tambah satu produk Office ke daftar (tanpa duplikat nama+serial)
function Add-OfficeEntry {
    param([string]$Raw, [string]$Status, [string]$Key, [string]$Name)
    if (-not $Name) { $Name = Get-OfficeProductName -Raw $Raw }
    if (-not $Key) { $Key = '' }
    foreach ($e in $script:Entries) {
        if ($e.Name -eq $Name -and $e.Key -eq $Key) { return }
    }
    $st = ''
    $s = ($Status -replace '-', '').Trim().ToUpper()
    if ($s -eq 'LICENSED') { $st = 'Licensed' }
    elseif ($s) { $st = 'Tidak Licensed' }
    else { $st = 'Status tidak terbaca' }
    $script:Entries.Add([pscustomobject]@{ Name = $Name; Status = $st; Key = $Key })
}

if ($NeedUpdate) {
    $Lines = [System.Collections.Generic.List[string]]::new()

    # =================================================================
    # 1. PENGECEKAN WINDOWS OS (Info_OS)
    # =================================================================
    try {
        $OS = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $WinName = $OS.Caption
        $WinArch = $OS.OSArchitecture
        $WinBuild = $OS.BuildNumber

        $WinDisplayVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).DisplayVersion
        $WinVersionName = switch ($WinDisplayVer) {
            "25H2" { "Windows 11 2025 (25H2)" }
            "25H1" { "Windows 11 2025 (25H1)" }
            "24H2" { "Windows 11 2024 (24H2)" }
            "23H2" { "Windows 11 2023 (23H2)" }
            "22H2" { if ($WinName -match "11") { "Windows 11 2022 (22H2)" } else { "Windows 10 2022 (22H2)" } }
            "21H2" { if ($WinName -match "11") { "Windows 11 2021 (21H2)" } else { "Windows 10 2021 (21H2)" } }
            "21H1" { "Windows 10 2021 (21H1)" }
            "20H2" { "Windows 10 2020 (20H2)" }
            "2004" { "Windows 10 2020 (2004)" }
            "1909" { "Windows 10 2019 (1909)" }
            default { if ($WinDisplayVer) { "Version $WinDisplayVer" } else { "Version $WinBuild" } }
        }

        $WinLicense = cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /dli 2>$null
        $WinStatus = "Unknown"
        $WinKey = "Digital License"

        foreach ($line in $WinLicense) {
            if ($line -match "License Status") { $WinStatus = ($line.Split(":")[1]).Trim() }
            if ($line -match "Partial Product Key") { $WinKey = ($line.Split(":")[1]).Trim() }
        }

        $WinCheckStatus = 0
        $WinState = "OK"
        if ($WinStatus -match "Licensed") {
            $WinCheckStatus = 0; $WinState = "OK"
        } elseif ($WinStatus -match "Unknown") {
            $WinCheckStatus = 0; $WinState = "OK"
        } else {
            $WinCheckStatus = 2; $WinState = "CRITICAL"
        }

        $Lines.Add("$WinCheckStatus `"Info_OS`" - $WinState - OS: $WinName | Version: $WinVersionName | Arch: $WinArch | Build: $WinBuild | License: $WinStatus | Key: $WinKey")
    } catch {
        $Lines.Add("0 `"Info_OS`" - OK - OS: Microsoft Windows | Status: Error querying WMI")
    }

    # =================================================================
    # 2. PENGECEKAN OFFICE (Info_Office) - satu serial per produk
    # =================================================================
    try {
        $script:Entries = [System.Collections.Generic.List[object]]::new()
        $Others = [System.Collections.Generic.List[string]]::new()

        # A. Baca SEMUA lisensi dari OSPP.VBS (tiap produk = 1 blok LICENSE NAME)
        $VbsSearchPaths = @(
            "$env:ProgramFiles\Microsoft Office\Office14\OSPP.VBS",
            "${env:ProgramFiles(x86)}\Microsoft Office\Office14\OSPP.VBS",
            "$env:ProgramFiles\Microsoft Office\Office15\OSPP.VBS",
            "${env:ProgramFiles(x86)}\Microsoft Office\Office15\OSPP.VBS",
            "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS",
            "${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS"
        ) | Where-Object { Test-Path $_ } | Select-Object -Unique

        foreach ($vPath in $VbsSearchPaths) {
            $CscriptOut = cscript.exe //nologo "$vPath" /dstatus 2>$null
            $cur = $null
            foreach ($line in $CscriptOut) {
                if ($line -match '^\s*LICENSE NAME:\s*(.+)$') {
                    if ($cur) { Add-OfficeEntry -Raw $cur.Raw -Status $cur.Status -Key $cur.Key }
                    $cur = @{ Raw = $Matches[1].Trim(); Status = ''; Key = '' }
                }
                elseif ($cur -and $line -match '^\s*LICENSE STATUS:\s*(.+)$') {
                    $cur.Status = $Matches[1].Trim()
                }
                elseif ($cur -and $line -match 'Last 5 characters of installed product key:\s*(\S+)') {
                    $cur.Key = $Matches[1].Trim()
                    Add-OfficeEntry -Raw $cur.Raw -Status $cur.Status -Key $cur.Key
                    $cur = $null
                }
            }
            if ($cur) { Add-OfficeEntry -Raw $cur.Raw -Status $cur.Status -Key $cur.Key }
        }

        # B. Cadangan: jika OSPP tidak memberi hasil, baca dari layanan lisensi Windows
        if ($script:Entries.Count -eq 0) {
            $wmi = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationId='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL"
            foreach ($p in $wmi) {
                $stText = 'UNLICENSED'
                if ($p.LicenseStatus -eq 1) { $stText = 'LICENSED' }
                Add-OfficeEntry -Raw $p.Name -Status $stText -Key $p.PartialProductKey
            }
        }

        # C. Cadangan terakhir: Click-to-Run terpasang tapi lisensi tidak terbaca
        if ($script:Entries.Count -eq 0) {
            $CtrPath = "HKLM:\Software\Microsoft\Office\ClickToRun\Configuration"
            if (Test-Path $CtrPath) {
                $ReleaseIDs = Get-ItemPropertyValue -Path $CtrPath -Name "ProductReleaseIDs" -ErrorAction SilentlyContinue
                if ($ReleaseIDs) {
                    foreach ($id in ($ReleaseIDs -split ',')) {
                        if ($id.Trim()) { Add-OfficeEntry -Raw $id.Trim() -Status '' -Key '' }
                    }
                }
            }
        }

        # D. Aplikasi non-Microsoft (LibreOffice / WPS) dan Office MSI (cadangan)
        $RegPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $InstalledApps = Get-ItemProperty $RegPaths -ErrorAction SilentlyContinue
        $ExcludePattern = "MUI|Proof|Filter|Tools|Component|Update|Pack|Telemetry|Teams|Licensing|Primary Interop|Visual Studio|Add-in|Language|Service Pack|Help|Outils|Herramientas|Correcci|Verification|Verificacion"

        foreach ($app in $InstalledApps) {
            $dn = $app.DisplayName
            $dv = $app.DisplayVersion
            if (-not $dn) { continue }

            if ($dn -match "^LibreOffice") {
                $lo = $dn
                if ($dv -and ($dn -notmatch [regex]::Escape($dv))) { $lo = "$dn $dv" }
                if (-not ($Others | Where-Object { $_ -like "*LibreOffice*" })) { $Others.Add($lo.Trim()) }
            }
            elseif ($dn -match "WPS Office" -and $dn -notmatch $ExcludePattern) {
                $wps = $dn
                if ($dv -and ($dn -notmatch [regex]::Escape($dv))) { $wps = "WPS Office v$dv" }
                if (-not ($Others | Where-Object { $_ -like "*WPS Office*" })) { $Others.Add($wps.Trim()) }
            }
            elseif ($script:Entries.Count -eq 0 -and
                    $dn -match "^Microsoft\s+(Office|Excel|Word|PowerPoint|Access|Outlook|Publisher|Visio|Project)" -and
                    $dn -notmatch $ExcludePattern) {
                $clean = ($dn -replace '\s*-\s*[a-z]{2}-[a-z]{2}$', '').Trim()
                Add-OfficeEntry -Raw $clean -Status '' -Key '' -Name $clean
            }
        }

        # E. Susun output: "<office> - <status> - <serial> + <office> - <status> - <serial>"
        $Parts = [System.Collections.Generic.List[string]]::new()
        $AnyUnlicensed = $false
        foreach ($e in ($script:Entries | Sort-Object Name, Key)) {
            $keyText = '-'
            if ($e.Key) { $keyText = $e.Key }
            if ($e.Status -eq 'Tidak Licensed') { $AnyUnlicensed = $true }
            $Parts.Add("$($e.Name) - $($e.Status) - $keyText")
        }
        foreach ($o in $Others) { $Parts.Add($o) }

        $OfficeState = 0
        if ($WarnIfUnlicensed -and $AnyUnlicensed) { $OfficeState = 1 }

        if ($Parts.Count -gt 0) {
            $Lines.Add("$OfficeState `"Info_Office`" - " + ($Parts -join ' + '))
        } else {
            $Lines.Add("0 `"Info_Office`" - Tidak ada aplikasi Office terpasang")
        }
    } catch {
        $Lines.Add("0 `"Info_Office`" - Gagal membaca data Office")
    }

    # Simpan hasil pemindaian ke file cache
    [System.IO.File]::WriteAllLines($CacheFile, $Lines, [System.Text.Encoding]::UTF8)
}

# Tampilkan hasil dari file cache
if (Test-Path $CacheFile) {
    [System.IO.File]::ReadAllLines($CacheFile, [System.Text.Encoding]::UTF8)
}
