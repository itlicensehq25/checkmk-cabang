# =====================================================================
# Local Check Checkmk: Daily OS & Multi-Office Suite License Check (Windows)
# Scheduled to run once a day at 16:00
# Output dibuat ASCII-only agar aman dibaca Checkmk/PowerShell.
# =====================================================================

$ErrorActionPreference = 'SilentlyContinue'

$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Force $CacheDir | Out-Null
}
$CacheFile = Join-Path $CacheDir "cache_os_office.txt"

# =====================================================================
# Penjadwalan: scan ulang sekali sehari setelah pukul 16:00
# =====================================================================
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
            "22H2" {
                if ($WinName -match "11") {
                    "Windows 11 2022 (22H2)"
                } else {
                    "Windows 10 2022 (22H2)"
                }
            }
            "21H2" {
                if ($WinName -match "11") {
                    "Windows 11 2021 (21H2)"
                } else {
                    "Windows 10 2021 (21H2)"
                }
            }
            "21H1" { "Windows 10 2021 (21H1)" }
            "20H2" { "Windows 10 2020 (20H2)" }
            "2004" { "Windows 10 2020 (2004)" }
            "1909" { "Windows 10 2019 (1909)" }
            default {
                if ($WinDisplayVer) {
                    "Version $WinDisplayVer"
                } else {
                    "Version $WinBuild"
                }
            }
        }

        $WinLicense = cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /dli 2>$null
        $WinStatus = "Unknown"
        $WinKey = "Digital License"

        foreach ($line in $WinLicense) {
            if ($line -match "License Status") {
                $WinStatus = ($line.Split(":")[1]).Trim()
            }
            if ($line -match "Partial Product Key") {
                $WinKey = ($line.Split(":")[1]).Trim()
            }
        }

        $WinCheckStatus = 0
        $WinState = "OK"

        if ($WinStatus -match "Licensed") {
            $WinCheckStatus = 0
            $WinState = "OK"
        }
        elseif ($WinStatus -match "Unknown") {
            $WinCheckStatus = 0
            $WinState = "OK"
        }
        else {
            $WinCheckStatus = 2
            $WinState = "CRITICAL"
        }

        $Lines.Add("$WinCheckStatus `"Info_OS`" - $WinState - OS: $WinName | Version: $WinVersionName | Arch: $WinArch | Build: $WinBuild | License: $WinStatus | Key: $WinKey")
    }
    catch {
        $Lines.Add("0 `"Info_OS`" - OK - OS: Microsoft Windows | Status: Error querying WMI")
    }

    # =================================================================
    # 2. PENGECEKAN MULTI-OFFICE & LICENSE (Info_Office)
    # =================================================================
    try {
        # -----------------------------------------------------------------
        # Helper identitas produk
        # -----------------------------------------------------------------
        function Get-OfficeFamily {
            param([string]$Text)

            if ($Text -match '(?i)Excel')      { return 'excel' }
            if ($Text -match '(?i)Word')       { return 'word' }
            if ($Text -match '(?i)PowerPoint') { return 'powerpoint' }
            if ($Text -match '(?i)Access')     { return 'access' }
            if ($Text -match '(?i)Outlook')    { return 'outlook' }
            if ($Text -match '(?i)Publisher')  { return 'publisher' }
            if ($Text -match '(?i)Visio')      { return 'visio' }
            if ($Text -match '(?i)Project')    { return 'project' }

            return 'office'
        }

        function Get-OfficeYear {
            param([string]$Text)

            if ($Text -match '(?i)2024') { return '2024' }
            if ($Text -match '(?i)2021') { return '2021' }
            if ($Text -match '(?i)2019') { return '2019' }
            if ($Text -match '(?i)2016') { return '2016' }
            if ($Text -match '(?i)2013') { return '2013' }
            if ($Text -match '(?i)2010') { return '2010' }
            if ($Text -match '(?i)O365|Microsoft 365') { return '365' }

            # Mapping versi internal Office lama.
            if ($Text -match '(?i)Office\s*14|Office14') { return '2010' }
            if ($Text -match '(?i)Office\s*15|Office15') { return '2013' }

            # Office16 dipakai banyak generasi (2016-2024),
            # jadi jangan menebak tahun hanya dari "Office16".
            return ''
        }

        function Get-OfficeEdition {
            param([string]$Text)

            if ($Text -match '(?i)ProPlus|Professional\s+Plus') { return 'proplus' }
            if ($Text -match '(?i)Standard')                    { return 'standard' }
            if ($Text -match '(?i)HomeBusiness|Home\s+and\s+Business') { return 'homebusiness' }
            if ($Text -match '(?i)HomeStudent|Home\s+and\s+Student')   { return 'homestudent' }

            return (Get-OfficeFamily $Text)
        }

        $OfficeProducts = [System.Collections.ArrayList]::new()
        $OtherList = [System.Collections.Generic.List[string]]::new()

        function Get-NormalizedOfficeName {
            param([string]$Name)

            if ([string]::IsNullOrWhiteSpace($Name)) {
                return ""
            }

            $n = $Name.ToLowerInvariant()
            $n = $n -replace '\(v[^\)]*\)', ''
            $n = $n -replace '[^a-z0-9]+', ' '
            $n = ($n -replace '\s+', ' ').Trim()
            return $n
        }

        function Add-OfficeProduct {
            param(
                [string]$Name,
                [string]$Version,
                [string]$IdentityText,
                [string]$Source
            )

            if ([string]::IsNullOrWhiteSpace($Name)) {
                return
            }

            # IdentityText WAJIB memuat nama yang sudah dinormalisasi.
            # Ini penting karena DisplayName registry kadang hanya "Microsoft Excel LTSC"
            # tanpa tahun, sementara cleanName sudah menjadi "Microsoft Excel 2024 LTSC".
            $identity = "$Name $IdentityText"

            $family = Get-OfficeFamily $identity
            $year = Get-OfficeYear $identity
            $edition = Get-OfficeEdition $identity
            $normalizedName = Get-NormalizedOfficeName $Name

            # Kunci utama.
            $key = "$family|$year|$edition"

            # Deduplikasi berlapis:
            # 1. Nama produk sama (C2R vs Registry) -> produk yang sama.
            # 2. family + year + edition sama -> produk yang sama.
            # 3. family + year sama dan family bukan "office" generik -> produk yang sama.
            #
            # Dengan cara ini:
            # - Excel 2024 dari C2R + Registry TIDAK dobel.
            # - Office 2010 + Excel 2024 tetap dianggap dua produk berbeda.
            $existing = $OfficeProducts | Where-Object {
                $sameName = (Get-NormalizedOfficeName $_.Name) -eq $normalizedName

                $sameIdentity = (
                    $_.Family -eq $family -and
                    $_.Year -eq $year -and
                    $_.Edition -eq $edition -and
                    -not [string]::IsNullOrWhiteSpace($year)
                )

                $sameStandaloneFamilyYear = (
                    $_.Family -eq $family -and
                    $_.Year -eq $year -and
                    $family -ne 'office' -and
                    -not [string]::IsNullOrWhiteSpace($year)
                )

                $sameName -or $sameIdentity -or $sameStandaloneFamilyYear
            } | Select-Object -First 1

            if ($existing) {
                # Prioritaskan versi yang tersedia.
                if ([string]::IsNullOrWhiteSpace($existing.Version) -and $Version) {
                    $existing.Version = $Version
                }

                # Untuk produk yang sama, C2R lebih dipercaya untuk nama/versi modern.
                if ($Source -eq 'C2R') {
                    $existing.Name = $Name
                    if ($Version) {
                        $existing.Version = $Version
                    }
                    $existing.Source = $Source
                }

                # Isi metadata yang sebelumnya kosong.
                if ([string]::IsNullOrWhiteSpace($existing.Year) -and $year) {
                    $existing.Year = $year
                }
                if ([string]::IsNullOrWhiteSpace($existing.Edition) -and $edition) {
                    $existing.Edition = $edition
                }

                $existing.Key = "$($existing.Family)|$($existing.Year)|$($existing.Edition)"
                return
            }

            $obj = [pscustomobject]@{
                Key           = $key
                Name          = $Name
                Version       = $Version
                Family        = $family
                Year          = $year
                Edition       = $edition
                Source        = $Source
                LicenseStatus = ''
                LicenseKey    = ''
                LicenseName   = ''
            }

            [void]$OfficeProducts.Add($obj)
        }

        # -----------------------------------------------------------------
        # A. Deteksi Click-to-Run (Office modern / standalone modern)
        # -----------------------------------------------------------------
        $CtrPath = "HKLM:\Software\Microsoft\Office\ClickToRun\Configuration"

        if (Test-Path $CtrPath) {
            $ReleaseIDs = Get-ItemPropertyValue -Path $CtrPath -Name "ProductReleaseIDs" -ErrorAction SilentlyContinue
            $VerReport = Get-ItemPropertyValue -Path $CtrPath -Name "VersionToReport" -ErrorAction SilentlyContinue

            if ($ReleaseIDs) {
                foreach ($item in ($ReleaseIDs -split ',')) {
                    $cleanItem = $item.Trim()
                    if (-not $cleanItem) { continue }

                    $label = switch -Wildcard ($cleanItem) {
                        "*O365*"         { "Microsoft 365"; break }

                        "*ProPlus2024*"  { "Microsoft Office Professional Plus 2024 LTSC"; break }
                        "*Standard2024*" { "Microsoft Office Standard 2024 LTSC"; break }
                        "*ProPlus2021*"  { "Microsoft Office Professional Plus 2021 LTSC"; break }
                        "*Standard2021*" { "Microsoft Office Standard 2021 LTSC"; break }
                        "*ProPlus2019*"  { "Microsoft Office Professional Plus 2019"; break }
                        "*Standard2019*" { "Microsoft Office Standard 2019"; break }
                        "*ProPlus2016*"  { "Microsoft Office Professional Plus 2016"; break }
                        "*Standard2016*" { "Microsoft Office Standard 2016"; break }

                        "*Excel2024*"    { "Microsoft Excel 2024 LTSC"; break }
                        "*ExcelLTSC*"    { "Microsoft Excel 2024 LTSC"; break }
                        "*Excel2021*"    { "Microsoft Excel 2021"; break }
                        "*Excel2019*"    { "Microsoft Excel 2019"; break }
                        "*Excel2016*"    { "Microsoft Excel 2016"; break }

                        "*Word2024*"     { "Microsoft Word 2024 LTSC"; break }
                        "*Word2021*"     { "Microsoft Word 2021"; break }
                        "*Word2019*"     { "Microsoft Word 2019"; break }

                        "*Visio2024*"    { "Microsoft Visio 2024 LTSC"; break }
                        "*Visio2021*"    { "Microsoft Visio 2021"; break }
                        "*Visio2019*"    { "Microsoft Visio 2019"; break }

                        "*Project2024*"  { "Microsoft Project 2024 LTSC"; break }
                        "*Project2021*"  { "Microsoft Project 2021"; break }
                        "*Project2019*"  { "Microsoft Project 2019"; break }

                        default          { $cleanItem; break }
                    }

                    if ($label -is [array]) {
                        $label = $label[0]
                    }

                    Add-OfficeProduct `
                        -Name $label `
                        -Version $VerReport `
                        -IdentityText "$cleanItem $label" `
                        -Source 'C2R'
                }
            }
        }

        # -----------------------------------------------------------------
        # B. Registry uninstall untuk Office MSI/legacy + LibreOffice/WPS
        # -----------------------------------------------------------------
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

            if (-not $dn) {
                continue
            }

            if (
                $dn -match "^Microsoft\s+(Office|Excel|Word|PowerPoint|Access|Outlook|Publisher|Visio|Project)" -and
                $dn -notmatch $ExcludePattern
            ) {
                $cleanName = ($dn -replace '\s*-\s*[a-z]{2}-[a-z]{2}$', '').Trim()

                # Normalisasi beberapa nama yang umum.
                if ($cleanName -match '(?i)Excel.*LTSC.*2024|Excel LTSC') {
                    $cleanName = "Microsoft Excel 2024 LTSC"
                }

                Add-OfficeProduct `
                    -Name $cleanName `
                    -Version $dv `
                    -IdentityText "$cleanName $dn $dv" `
                    -Source 'Registry'
            }
            elseif ($dn -match "^LibreOffice") {
                if ($dv -and ($dn -notmatch [regex]::Escape($dv))) {
                    $lo = "$dn $dv"
                } else {
                    $lo = $dn
                }

                if (-not ($OtherList | Where-Object { $_ -like "*LibreOffice*" })) {
                    $OtherList.Add($lo.Trim())
                }
            }
            elseif ($dn -match "WPS Office" -and $dn -notmatch $ExcludePattern) {
                if ($dv -and ($dn -notmatch [regex]::Escape($dv))) {
                    $wps = "WPS Office v$dv"
                } else {
                    $wps = $dn
                }

                if (-not ($OtherList | Where-Object { $_ -like "*WPS Office*" })) {
                    $OtherList.Add($wps.Trim())
                }
            }
        }

        # -----------------------------------------------------------------
        # C. Ambil seluruh record license dari OSPP.VBS
        # -----------------------------------------------------------------
        $LicenseRecords = [System.Collections.ArrayList]::new()
        $SeenLicenseRecords = @{}

        # Office 2010 = Office14.
        # Office 2013 = Office15.
        # Office 2016/2019/2021/2024 umumnya memakai Office16/root\Office16.
        $VbsSearchPaths = @(
            "$env:ProgramFiles\Microsoft Office\Office14\OSPP.VBS",
            "${env:ProgramFiles(x86)}\Microsoft Office\Office14\OSPP.VBS",

            "$env:ProgramFiles\Microsoft Office\Office15\OSPP.VBS",
            "${env:ProgramFiles(x86)}\Microsoft Office\Office15\OSPP.VBS",

            "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS",
            "${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS",

            "$env:ProgramFiles\Microsoft Office\root\Office16\OSPP.VBS",
            "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OSPP.VBS"
        ) | Where-Object {
            $_ -and (Test-Path $_)
        } | Select-Object -Unique

        foreach ($vPath in $VbsSearchPaths) {
            $CscriptOut = cscript.exe //nologo "$vPath" /dstatus 2>$null

            $currentName = ''
            $currentDescription = ''
            $currentStatus = ''
            $currentKey = ''

            foreach ($line in $CscriptOut) {
                if ($line -match 'LICENSE NAME:\s*(.*)') {
                    $currentName = $Matches[1].Trim()
                    continue
                }

                if ($line -match 'LICENSE DESCRIPTION:\s*(.*)') {
                    $currentDescription = $Matches[1].Trim()
                    continue
                }

                if ($line -match 'LICENSE STATUS:\s*---(.*?)---') {
                    $currentStatus = $Matches[1].Trim()
                    continue
                }
                elseif ($line -match 'LICENSE STATUS:\s*(.*)') {
                    $currentStatus = $Matches[1].Trim().Trim('-')
                    continue
                }

                if ($line -match 'Last 5 characters of installed product key:\s*(.*)') {
                    $currentKey = $Matches[1].Trim()

                    if ($currentName -or $currentStatus -or $currentKey) {
                        $signature = "$currentName|$currentDescription|$currentStatus|$currentKey"

                        if (-not $SeenLicenseRecords.ContainsKey($signature)) {
                            $SeenLicenseRecords[$signature] = $true

                            $licenseText = "$currentName $currentDescription"

                            $record = [pscustomobject]@{
                                Name        = $currentName
                                Description = $currentDescription
                                Status      = $currentStatus
                                Key         = $currentKey
                                Family      = Get-OfficeFamily $licenseText
                                Year        = Get-OfficeYear $licenseText
                                Edition     = Get-OfficeEdition $licenseText
                            }

                            [void]$LicenseRecords.Add($record)
                        }
                    }

                    # Reset blok untuk license berikutnya.
                    $currentName = ''
                    $currentDescription = ''
                    $currentStatus = ''
                    $currentKey = ''
                }
            }
        }

        # -----------------------------------------------------------------
        # D. Pasangkan license ke produk yang benar.
        #    Urutan prioritas:
        #    1) family + year + edition
        #    2) family + year
        #    3) family + edition
        #    4) family tunggal
        #
        #    Tujuan: Office 2010 tidak tertukar dengan Excel 2024 LTSC.
        # -----------------------------------------------------------------
        foreach ($lic in $LicenseRecords) {
            $candidates = @()

            if ($lic.Family -and $lic.Year -and $lic.Edition) {
                $candidates = @($OfficeProducts | Where-Object {
                    $_.Family -eq $lic.Family -and
                    $_.Year -eq $lic.Year -and
                    $_.Edition -eq $lic.Edition
                })
            }

            if ($candidates.Count -eq 0 -and $lic.Family -and $lic.Year) {
                $candidates = @($OfficeProducts | Where-Object {
                    $_.Family -eq $lic.Family -and
                    $_.Year -eq $lic.Year
                })
            }

            if ($candidates.Count -eq 0 -and $lic.Family -and $lic.Edition) {
                $candidates = @($OfficeProducts | Where-Object {
                    $_.Family -eq $lic.Family -and
                    $_.Edition -eq $lic.Edition
                })
            }

            if ($candidates.Count -eq 0 -and $lic.Family) {
                $familyCandidates = @($OfficeProducts | Where-Object {
                    $_.Family -eq $lic.Family
                })

                if ($familyCandidates.Count -eq 1) {
                    $candidates = $familyCandidates
                }
            }

            if ($candidates.Count -eq 1) {
                $target = $candidates[0]

                $newIsLicensed = $lic.Status -match '(?i)^LICENSED$'
                $oldIsLicensed = $target.LicenseStatus -match '(?i)^LICENSED$'

                # Isi jika kosong. Jika ada beberapa record, prioritaskan LICENSED.
                if (
                    [string]::IsNullOrWhiteSpace($target.LicenseStatus) -or
                    ($newIsLicensed -and -not $oldIsLicensed)
                ) {
                    $target.LicenseStatus = $lic.Status
                    $target.LicenseKey = $lic.Key
                    $target.LicenseName = $lic.Name
                }
            }
        }

        # -----------------------------------------------------------------
        # D2. Final safety dedupe
        # -----------------------------------------------------------------
        # Jaga-jaga jika vendor/registry memberikan entri identik dari beberapa hive.
        # Hanya hapus produk dengan nama normalisasi + versi yang sama.
        $UniqueProducts = [System.Collections.ArrayList]::new()
        $SeenProducts = @{}

        foreach ($p in $OfficeProducts) {
            $displayKey = "$(Get-NormalizedOfficeName $p.Name)|$($p.Version)"

            if (-not $SeenProducts.ContainsKey($displayKey)) {
                $SeenProducts[$displayKey] = $true
                [void]$UniqueProducts.Add($p)
            } else {
                $existing = $UniqueProducts | Where-Object {
                    "$(Get-NormalizedOfficeName $_.Name)|$($_.Version)" -eq $displayKey
                } | Select-Object -First 1

                if ($existing) {
                    # Jika salah satu duplikat punya license dan satunya tidak,
                    # pertahankan informasi license yang valid.
                    if (
                        [string]::IsNullOrWhiteSpace($existing.LicenseStatus) -and
                        -not [string]::IsNullOrWhiteSpace($p.LicenseStatus)
                    ) {
                        $existing.LicenseStatus = $p.LicenseStatus
                        $existing.LicenseKey = $p.LicenseKey
                        $existing.LicenseName = $p.LicenseName
                    }
                }
            }
        }

        $OfficeProducts = $UniqueProducts

        # -----------------------------------------------------------------
        # E. Format output akhir.
        #
        # Contoh satu Office + LibreOffice:
        # Microsoft Excel 2024 LTSC (v16.x) LICENSED (Key: HCJB7)
        # + LibreOffice 26.x
        #
        # Contoh dua Microsoft Office berbeda:
        # Microsoft Office Professional Plus 2010 (v14.x) LICENSED (Key: ABCDE)
        # + Microsoft Excel 2024 LTSC (v16.x) LICENSED (Key: HCJB7)
        # -----------------------------------------------------------------
        $DisplayItems = [System.Collections.Generic.List[string]]::new()

        foreach ($product in $OfficeProducts) {
            if ($product.Version) {
                $display = "$($product.Name) (v$($product.Version))"
            } else {
                $display = $product.Name
            }

            if ($product.LicenseStatus) {
                $display += " $($product.LicenseStatus)"

                if ($product.LicenseKey) {
                    $display += " (Key: $($product.LicenseKey))"
                }
            } else {
                # Jangan memasangkan key secara acak jika identitas license tidak cukup jelas.
                $display += " LICENSE: N/A"
            }

            $DisplayItems.Add($display)
        }

        foreach ($other in $OtherList) {
            $DisplayItems.Add($other)
        }

        if ($DisplayItems.Count -gt 0) {
            $ProductString = $DisplayItems -join " + "
            $Lines.Add("0 `"Info_Office`" - OK - Product: $ProductString")
        } else {
            $Lines.Add("0 `"Info_Office`" - OK - Product: Tidak ada aplikasi Office (Native Windows) | Status: OK")
        }
    }
    catch {
        $Lines.Add("0 `"Info_Office`" - OK - Product: Microsoft Office | Status: Error checking registry")
    }

    # =================================================================
    # Simpan hasil scan ke cache
    # =================================================================
    [System.IO.File]::WriteAllLines(
        $CacheFile,
        $Lines,
        [System.Text.Encoding]::UTF8
    )
}

# =====================================================================
# Tampilkan hasil cache ke Checkmk agent
# =====================================================================
if (Test-Path $CacheFile) {
    [System.IO.File]::ReadAllLines(
        $CacheFile,
        [System.Text.Encoding]::UTF8
    )
}
