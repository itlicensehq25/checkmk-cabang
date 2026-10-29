$ErrorActionPreference = 'SilentlyContinue'
$CacheFolder = "$env:ProgramData\checkmk\agent"
if (-not (Test-Path $CacheFolder)) { New-Item -ItemType Directory -Path $CacheFolder -Force }
$WeeklyCache = "$CacheFolder\cache_remote_id.txt"

function Save-CacheAndOutput ([string]$FilePath, [System.Collections.Generic.List[string]]$Lines) {
    $CleanLines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $Lines) { if (-not [string]::IsNullOrWhiteSpace($l)) { $CleanLines.Add(($l -replace "[\r\n]+", " ").Trim()) } }
    if ($CleanLines.Count -gt 0) { [System.IO.File]::WriteAllLines($FilePath, $CleanLines, [System.Text.Encoding]::UTF8); foreach ($cl in $CleanLines) { Write-Host $cl } }
}
function Read-CacheAndOutput ([string]$FilePath) {
    if (Test-Path $FilePath) { foreach ($l in [System.IO.File]::ReadAllLines($FilePath, [System.Text.Encoding]::UTF8)) { if (-not [string]::IsNullOrWhiteSpace($l)) { Write-Host $l } } }
}

$Today = Get-Date
$DaysSinceMonday = ([int]$Today.DayOfWeek - [int][DayOfWeek]::Monday + 7) % 7
$ThisMonday = $Today.Date.AddDays(-$DaysSinceMonday)

$NeedUpdateWeekly = $true
if (Test-Path $WeeklyCache) { if ((Get-Item $WeeklyCache).LastWriteTime -ge $ThisMonday) { $NeedUpdateWeekly = $false } }

if ($NeedUpdateWeekly) {
    $linesWeekly = [System.Collections.Generic.List[string]]::new()
    try {
        $users = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "^(Public|Default|Default User|All Users)$" }
        $ANYDESK_ID = "Not Installed"; $RUSTDESK_ID = "Not Installed"; $ANYVIEWER_ID = "Not Installed"

        # AnyDesk
        $ad_paths = @("$env:ProgramData\AnyDesk\system.conf"); foreach ($u in $users) { $ad_paths += "$($u.FullName)\AppData\Roaming\AnyDesk\system.conf" }
        foreach ($path in $ad_paths) {
            if (Test-Path $path) { $ad_conf = Get-Content $path -ErrorAction SilentlyContinue; $ad_line = $ad_conf | Where-Object { $_ -match "^ad\.anynet\.id=" }; if ($ad_line) { $ANYDESK_ID = ($ad_line -split "=")[1].Trim(); break } }
        }

        # RustDesk
        $rd_exe = @("$env:ProgramFiles\RustDesk\rustdesk.exe", "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe", "$env:LOCALAPPDATA\Programs\RustDesk\rustdesk.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($rd_exe) { $cli_out = (& $rd_exe --get-id 2>$null | Out-String).Trim(); if ($cli_out -match '^\d{8,15}$') { $RUSTDESK_ID = $cli_out } }
        if ($RUSTDESK_ID -eq "Not Installed") {
            $rd_paths = @("$env:ProgramData\RustDesk\config\RustDesk2.toml", "$env:ProgramData\RustDesk\config\RustDesk.toml"); foreach ($u in $users) { $rd_paths += "$($u.FullName)\AppData\Roaming\RustDesk\config\RustDesk2.toml" }
            foreach ($path in $rd_paths) { if (Test-Path $path) { $content = Get-Content $path -Raw -ErrorAction SilentlyContinue; if ($content -match '(?m)^\s*id\s*=\s*[''"]?(\d{8,15})[''"]?') { $RUSTDESK_ID = $matches[1].Trim(); break } } }
        }

        # AnyViewer
        $hu = Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue
        foreach ($h in $hu) { $av_reg = "$($h.PSPath)\SOFTWARE\Aomei\AnyViewer\Option"; if (Test-Path $av_reg) { $val = Get-ItemPropertyValue -Path $av_reg -Name "DeviceID" -ErrorAction SilentlyContinue; if ($val) { $ANYVIEWER_ID = $val; break } } }
        if ($ANYVIEWER_ID -eq "Not Installed") { $val = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\WOW6432Node\Aomei\AnyViewer\Option" -Name "DeviceID" -ErrorAction SilentlyContinue; if ($val) { $ANYVIEWER_ID = $val } }

        $linesWeekly.Add("0 `"Remote_Access_ID`" - OK: AnyDesk: $ANYDESK_ID | RustDesk: $RUSTDESK_ID | AnyViewer: $ANYVIEWER_ID")
    } catch {}
    Save-CacheAndOutput -FilePath $WeeklyCache -Lines $linesWeekly
} else { Read-CacheAndOutput -FilePath $WeeklyCache }
