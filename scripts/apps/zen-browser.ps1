#requires -Version 7.0
<#
.SYNOPSIS
    Zen Browser

.DESCRIPTION
    Zen Browser (Windows) 自动化纯净安装与企业策略配置脚本。
    1. 专为 PowerShell 7+ (pwsh) 编写，充分运用现代 pwsh 语言特性与原生无 BOM UTF-8 输出。
    2. 严格遵循“先检查后配置、幂等无冗余”原则：对二进制、离线扩展包、语言包及策略文件全流程先检后配，杜绝重复下载与脏写入。
    3. 纯净提取官方安装包的核心组件，杜绝特权维护服务（MozillaMaintenance）、计划任务及注册表广域污染。
    4. 采用无破坏增量合并机制纳管 Profile user.js：完整保留用户自定义的其他偏好，向控制台高亮输出 Old/New 差异对比表。
    5. 分离 Gecko 原生白名单策略与 Zen 专属特性，通过 defaults\pref\ 全局预置与 user.js 增量固化，
       涵盖 38 项现代极简视效、黄金三角搜索引擎、Glance 悬浮快窥、多工作区隔离及能耗优化全量基线。
    6. 智能注册 Windows 系统级浏览器功能与文件/协议关联 (HTTP, HTTPS, HTML)，幂等配置 Zen Browser 为系统默认浏览器。

.PARAMETER InstallOnly
    仅执行二进制文件的下载、提取与快捷方式创建，不配置企业策略。

.PARAMETER ConfigOnly
    仅执行本地扩展校验、企业策略增量比对与首选项注入，不重新下载安装程序。

.PARAMETER Clean
    清洁安装模式。强制终止常驻进程、清理安装目录、抹除本地用户数据缓存并 100% 全新拉取与重构环境。
    别名: -Fresh, -Reset

.PARAMETER UninstallOnly
    仅执行取证级彻底卸载与全量系统侵入清理（注销协议注册、清理注册表关联与快捷方式、抹除安装目录与数据），不执行重新安装。
    别名: -Uninstall, -Remove

.PARAMETER CheckOnly
    只查不改模式（体检巡检）。逐项比对二进制存在性、企业策略 (policies.json)、偏好配置与默认浏览器关联，高亮输出 Diff，零写入安全退出。
    别名: -Audit

.PARAMETER InstallOnly
    仅执行二进制文件的下载、提取与快捷方式创建，不配置企业策略。

.PARAMETER ConfigOnly
    仅执行本地扩展校验、企业策略增量比对与首选项注入，不重新下载安装程序。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线偏好（用于全新自动化装机流）。

.PARAMETER InstallDir
    Zen Browser 安装部署目标目录，默认为 D:\prog\zen-browser。

.EXAMPLE
    # 交互式全流程安装与配置（回车直接采纳推荐基线）
    pwsh -File .\scripts\apps\zen-browser.ps1

    # 静默全量安装与加固
    pwsh -File .\scripts\apps\zen-browser.ps1 -NonInteractive

    # 仅增量检查并更新策略与扩展（零重复 I/O）
    pwsh -File .\scripts\apps\zen-browser.ps1 -ConfigOnly

    # 彻底清洁重装
    pwsh -File .\scripts\apps\zen-browser.ps1 -Clean

    # 只查不改体检巡检
    pwsh -File .\scripts\apps\zen-browser.ps1 -CheckOnly
#>

[CmdletBinding()]
param(
    [Alias("Fresh", "Reset")]
    [switch]$Clean,

    [Alias("Uninstall", "Remove")]
    [switch]$UninstallOnly,

    [Alias("Audit")]
    [switch]$CheckOnly,

    [switch]$InstallOnly,
    [switch]$ConfigOnly,
    [switch]$NonInteractive,
    [string]$InstallDir
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ==============================================================================
# 环境校验：强制锁定 PowerShell 7+
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "本脚本已全面转向 PowerShell 7+ (pwsh)，不兼容旧版 Windows PowerShell 5.1。请使用 'pwsh' 执行本脚本。"
}

# ==============================================================================
# 工具函数：JS 首选项格式化与增量比对
# ==============================================================================
function Format-JsValue($val) {
    if ($val -is [bool]) { return $val ? "true" : "false" }
    if ($val -is [int] -or $val -is [long]) { return "$val" }
    return "`"$($val.ToString().Replace('\', '\\').Replace('"', '\"'))`""
}

function Update-UserJsPreferences {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$DesiredPrefs
    )

    $existingLines = (Test-Path $Path) ? (Get-Content -Path $Path -Encoding utf8NoBOM) : @()
    $diffTable = [System.Collections.Generic.List[PSCustomObject]]::new()
    $processedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $outputLines = [System.Collections.Generic.List[string]]::new()

    # 1. 逐行原位扫描并更新已有配置（未纳入目标字典的用户自定义项绝对完整保留）
    foreach ($line in $existingLines) {
        if ($line -match '^\s*user_pref\(\s*["'']([^"'']+)["'']\s*,\s*(.*?)\s*\);\s*$') {
            $key = $Matches[1]
            $currentRawVal = $Matches[2].Trim()

            if ($DesiredPrefs.Contains($key)) {
                $processedKeys.Add($key) | Out-Null
                $targetVal = $DesiredPrefs[$key]
                $targetFormatted = Format-JsValue $targetVal

                if ($currentRawVal -ne $targetFormatted) {
                    $diffTable.Add([PSCustomObject]@{
                        Preference = $key
                        OldValue   = $currentRawVal
                        NewValue   = $targetFormatted
                    })
                    $outputLines.Add("user_pref(`"$key`", $targetFormatted);")
                } else {
                    $outputLines.Add($line)
                }
                continue
            }
        }
        $outputLines.Add($line)
    }

    # 2. 追加此前未配置的基线项
    foreach ($key in $DesiredPrefs.Keys) {
        if (-not $processedKeys.Contains($key)) {
            $targetVal = $DesiredPrefs[$key]
            $targetFormatted = Format-JsValue $targetVal
            $diffTable.Add([PSCustomObject]@{
                Preference = $key
                OldValue   = "[未配置]"
                NewValue   = $targetFormatted
            })
            $outputLines.Add("user_pref(`"$key`", $targetFormatted);")
        }
    }

    # 3. 仅在有实际差异时才执行落盘写操作（实现纯粹幂等）
    if ($diffTable.Count -gt 0 -or (-not (Test-Path $Path))) {
        Set-Content -Path $Path -Value $outputLines -Encoding utf8NoBOM
    }

    return $diffTable
}

# ==============================================================================
# 0. 目标安装路径智能探测与交互确认
# ==============================================================================
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = (Test-Path "D:\") ? "D:\prog\zen-browser" : (Join-Path $env:LOCALAPPDATA "Programs\zen-browser")
}

function Clear-GeckoStrayRegistrations {
    $regApp = "HKCU:\Software\RegisteredApplications"
    if (Test-Path $regApp) {
        Remove-ItemProperty -Path $regApp -Name "Zen" -ErrorAction SilentlyContinue
        (Get-ItemProperty $regApp -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -like "Firefox-*" } |
            ForEach-Object { Remove-ItemProperty -Path $regApp -Name $_.Name -ErrorAction SilentlyContinue }
    }
    Get-ChildItem "HKCU:\Software\Clients\StartMenuInternet" -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "Firefox-*" -or $_.PSChildName -eq "ZEN.EXE" } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem "HKCU:\Software\Classes" -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "FirefoxHTML-*" -or $_.PSChildName -like "FirefoxURL-*" -or $_.PSChildName -like "FirefoxPDF-*" } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($ext in @(".html", ".htm")) {
        $owp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\OpenWithProgids"
        if (Test-Path $owp) {
            (Get-ItemProperty $owp -ErrorAction SilentlyContinue).PSObject.Properties |
                Where-Object { $_.Name -like "FirefoxHTML-*" } |
                ForEach-Object { Remove-ItemProperty -Path $owp -Name $_.Name -ErrorAction SilentlyContinue }
        }
    }
}

function Sync-ZenShortcuts {
    param([switch]$AuditOnly)

    $canonicalLnk = Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Zen Browser.lnk"
    $isLnkReady = (Test-Path $canonicalLnk)
    if ($isLnkReady) {
        try {
            $wsh = New-Object -ComObject WScript.Shell
            $scObj = $wsh.CreateShortcut($canonicalLnk)
            $isLnkReady = ($scObj.TargetPath -eq (Join-Path $InstallDir "zen.exe"))
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        } catch { $isLnkReady = $false }
    }

    if ($AuditOnly) {
        return [PSCustomObject]@{
            IsReady    = $isLnkReady
            StatusText = $isLnkReady ? "已就绪" : "快捷方式缺失/路径偏离"
        }
    }

    # 执行快捷方式对齐与派生冗余清理
    if (-not $isLnkReady) {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($canonicalLnk)
        $shortcut.TargetPath = Join-Path $InstallDir "zen.exe"
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        Write-Host "   - 已对齐开始菜单快捷方式: $canonicalLnk" -ForegroundColor Green
    }
    @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Zen.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Firefox 隐私浏览.lnk"),
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Zen.lnk",
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zen.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zen Browser.lnk"),
        "C:\Users\Public\Desktop\Zen.lnk",
        "C:\Users\Public\Desktop\Zen Browser.lnk"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue
            Write-Host "   - 已自动清理派生冗余快捷方式: $_" -ForegroundColor Gray
        }
    }
}

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "  Zen Browser 自动化部署与策略配置工具 (pwsh 7+)" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "📂 部署基准目录: $InstallDir`n" -ForegroundColor Cyan

# ==============================================================================
# 清洁卸载与环境重置 (-Clean / -UninstallOnly)
# ==============================================================================
if ($Clean -or $UninstallOnly) {
    Write-Host "🧹 [清洁卸载模式] 正在执行全量系统侵入反注册与地毯式深度清理..." -ForegroundColor Yellow

    # 1. 强力终止 Zen 常驻进程
    Get-Process -Name zen -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 600

    # 2. 清理系统默认浏览器与注册表关联 (包括 Gecko 派生哈希项)
    Remove-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "Zen Browser" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "Zen" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Clients\StartMenuInternet\Zen" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Clients\StartMenuInternet\ZEN.EXE" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Classes\ZenHTML" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Classes\ZenURL" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Classes\ZenPDF" -Recurse -Force -ErrorAction SilentlyContinue
    Clear-GeckoStrayRegistrations

    # 3. 清理快捷方式 (涵盖用户与全机公用目录)
    $shortcutCandidates = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Zen Browser.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Zen.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Firefox 隐私浏览.lnk"),
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Zen.lnk",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Firefox 隐私浏览.lnk",
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zen Browser.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zen.lnk"),
        "C:\Users\Public\Desktop\Zen.lnk",
        "C:\Users\Public\Desktop\Zen Browser.lnk"
    )
    foreach ($sc in $shortcutCandidates) {
        if (Test-Path $sc) { Remove-Item -Path $sc -Force -ErrorAction SilentlyContinue }
    }

    # 4. 清理安装目录与本地用户数据缓存
    if (Test-Path $InstallDir) {
        Write-Host "   - 正在清理安装目录: $InstallDir" -ForegroundColor Gray
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $zenAppData = Join-Path $env:APPDATA "zen"
    $zenLocalAppData = Join-Path $env:LOCALAPPDATA "zen"
    if (Test-Path $zenAppData) {
        Write-Host "   - 正在清理用户配置目录: $zenAppData" -ForegroundColor Gray
        Remove-Item -Path $zenAppData -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $zenLocalAppData) {
        Write-Host "   - 正在清理本地缓存目录: $zenLocalAppData" -ForegroundColor Gray
        Remove-Item -Path $zenLocalAppData -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "✅ [清洁完成] Zen Browser 二进制本体、注册表关联与用户数据已彻底清除。" -ForegroundColor Green
    if ($UninstallOnly) {
        return
    }
}

# ==============================================================================
# 只查不改体检巡检模式 (-CheckOnly / -Audit)
# ==============================================================================
if ($CheckOnly) {
    Write-Host "`n🔍 [只查不改模式] 正在对 Zen Browser 执行逐项状态与配置巡检..." -ForegroundColor Cyan
    $zenExe = Join-Path $InstallDir "zen.exe"
    $policyPath = Join-Path $InstallDir "distribution\policies.json"
    $policyData = $null
    if (Test-Path $policyPath) {
        try { $policyData = (Get-Content -Path $policyPath -Raw -Encoding utf8NoBOM | ConvertFrom-Json).policies } catch {}
    }

    $chkList = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. 二进制安装
    $chkList.Add([PSCustomObject]@{
        "配置项目" = "二进制程序本体 (zen.exe)"
        "期望状态" = "已安装于 $InstallDir"
        "实机状态" = (Test-Path $zenExe) ? "已就绪" : "未安装"
        "判定"     = (Test-Path $zenExe) ? "✔ 匹配" : "✘ 缺失"
    })

    # 2. 账号登录入口切除
    $accVal = ($policyData -and $policyData.DisableFirefoxAccounts -eq $true)
    $chkList.Add([PSCustomObject]@{
        "配置项目" = "底层切除账号登录 (DisableFirefoxAccounts)"
        "期望状态" = "True (物理禁用)"
        "实机状态" = $accVal ? "True" : "False/未配置"
        "判定"     = $accVal ? "✔ 匹配" : "✘ 漂移"
    })

    # 3. 遥测采集
    $telemVal = ($policyData -and $policyData.DisableTelemetry -eq $true)
    $chkList.Add([PSCustomObject]@{
        "配置项目" = "禁用隐私遥测 (DisableTelemetry)"
        "期望状态" = "True"
        "实机状态" = $telemVal ? "True" : "False/未配置"
        "判定"     = $telemVal ? "✔ 匹配" : "✘ 漂移"
    })

    # 4. Pocket 资讯
    $pocketVal = ($policyData -and $policyData.DisablePocket -eq $true)
    $chkList.Add([PSCustomObject]@{
        "配置项目" = "禁用 Pocket 资讯推荐 (DisablePocket)"
        "期望状态" = "True"
        "实机状态" = $pocketVal ? "True" : "False/未配置"
        "判定"     = $pocketVal ? "✔ 匹配" : "✘ 漂移"
    })

    # 5. 默认应用关联
    $currHttp = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    $isDef = ($currHttp -like "*zen*" -or $currHttp -eq "ZenURL" -or $currHttp -eq "ZenHTML")
    $chkList.Add([PSCustomObject]@{
        "配置项目" = "系统默认浏览器 (HTTP 关联)"
        "期望状态" = "Zen Browser (ZenURL/ZenHTML)"
        "实机状态" = [string]::IsNullOrEmpty($currHttp) ? "[未关联]" : $currHttp
        "判定"     = $isDef ? "✔ 匹配" : "✘ 漂移"
    })

    # 6. 开始菜单快捷方式
    $shortcutAudit = Sync-ZenShortcuts -AuditOnly
    $chkList.Add([PSCustomObject]@{
        "配置项目" = "开始菜单快捷方式 (Zen Browser.lnk)"
        "期望状态" = "已就绪"
        "实机状态" = $shortcutAudit.StatusText
        "判定"     = $shortcutAudit.IsReady ? "✔ 匹配" : "✘ 缺失/漂移"
    })

    $chkList | Format-Table -AutoSize
    Write-Host "✔ 巡检完成，未对磁盘与注册表执行任何写入。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 阶段 1: 纯净二进制提取与安装 (先检查后提取)
# ==============================================================================
if (-not $ConfigOnly) {
    $zenExe = Join-Path $InstallDir "zen.exe"
    $needExtract = $true

    if (Test-Path $zenExe) {
        $needExtract = $false
        Write-Host "⏭️  检测到二进制本体已存在 ($zenExe)，跳过重复下载解压。" -ForegroundColor Gray
    }

    if ($needExtract) {
        if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
            throw "未检测到 7z 解压工具。请先执行 'scoop install 7zip' 安装，拒绝调用安装器向导以防系统与注册表污染。"
        }

        $tempDir = Join-Path $env:TEMP "zen_install_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir, $InstallDir -Force | Out-Null

        try {
            Write-Host "🔍 检索 Zen Browser 官方最新 Release..." -ForegroundColor Cyan
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/zen-browser/desktop/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }
            $asset = $release.assets | Where-Object { $_.name -eq "zen.installer.exe" } | Select-Object -First 1
            if (-not $asset) {
                throw "未在最新 Release ($($release.tag_name)) 中匹配到 zen.installer.exe"
            }

            $installerPath = Join-Path $tempDir "zen.installer.exe"
            Write-Host "⬇️  正在下载 $($asset.name) ($($release.tag_name))..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath

            Write-Host "📦 提取核心二进制至 $InstallDir..." -ForegroundColor Cyan
            7z x -y -o"$tempDir\extract" $installerPath "core/*" | Out-Null
            Copy-Item -Path "$tempDir\extract\core\*" -Destination $InstallDir -Recurse -Force

            Write-Host "🔗 对齐开始菜单快捷方式..." -ForegroundColor Cyan
            Sync-ZenShortcuts

            Write-Host "✅ Zen Browser 纯净安装就绪: $InstallDir\zen.exe" -ForegroundColor Green
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($InstallOnly) {
    return
}

# ==============================================================================
# 阶段 2: 核心扩展与语言包先检后配 (零重复下载)
# ==============================================================================

# 运行状态检查：写入 policies 与扩展前必须退出浏览器
if (Get-Process -Name zen -ErrorAction SilentlyContinue) {
    throw "检测到 Zen Browser 正在运行，请先完全退出浏览器后再执行策略配置！"
}

$distDir = Join-Path $InstallDir "distribution"
$extDir  = Join-Path $distDir "extensions"
New-Item -ItemType Directory -Path $extDir -Force | Out-Null

Write-Host "📦 检查核心离线扩展与语言包缓存..." -ForegroundColor Cyan

# 1. 检查 uBlock Origin
$ublockFile = Join-Path $extDir "uBlock0@raymondhill.net.xpi"
if ((Test-Path $ublockFile) -and ((Get-Item $ublockFile).Length -gt 0)) {
    Write-Host "   - [已就绪] uBlock Origin 离线包已存在，跳过重复下载。" -ForegroundColor Gray
} else {
    Write-Host "   - ⬇️  正在预下载 uBlock Origin..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi" -OutFile $ublockFile
}

# 2. 检查 Bitwarden
$bwFile = Join-Path $extDir "{446900e4-71c2-419f-a6a7-df9c091e268b}.xpi"
if ((Test-Path $bwFile) -and ((Get-Item $bwFile).Length -gt 0)) {
    Write-Host "   - [已就绪] Bitwarden 离线包已存在，跳过重复下载。" -ForegroundColor Gray
} else {
    Write-Host "   - ⬇️  正在预下载 Bitwarden..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://addons.mozilla.org/firefox/downloads/latest/bitwarden-password-manager/latest.xpi" -OutFile $bwFile
}

# 3. 动态精准匹配与当前内核主版本一致的简体中文语言包
$langFile = Join-Path $extDir "langpack-zh-CN@firefox.mozilla.org.xpi"
$platIni = Join-Path $InstallDir "platform.ini"
$major = ((Test-Path $platIni) -and ((Get-Content $platIni -Raw) -match "Milestone=([\d]+)")) ? $Matches[1] : "157"

$needDownloadLang = $true
if (Test-Path $langFile) {
    # 检查已缓存语言包是否与当前 Gecko Milestone 主版本严格一致
    $cachedVer = & 7z e -so $langFile "manifest.json" 2>$null
    if ($cachedVer -and ($cachedVer -match "`"strict_min_version`":\s*`"$major\.")) {
        $needDownloadLang = $false
        Write-Host "   - [已就绪] 本地语言包与 Gecko $major 主版本精确兼容，跳过重复下载。" -ForegroundColor Gray
    }
}

$langUrl = "https://addons.mozilla.org/firefox/downloads/file/5089007/chinese_simplified_zh_cn_la-157.0.20261005.135250.xpi"
if ($needDownloadLang) {
    Write-Host "   - 🔍 检索与 Gecko $major 精确匹配的官方中文语言包..." -ForegroundColor Gray
    try {
        $amoRes = Invoke-RestMethod -Uri "https://addons.mozilla.org/api/v5/addons/addon/chinese-simplified-zh-cn-la/versions/" -Headers @{ "User-Agent" = "PowerShell" }
        $matchedLang = $amoRes.results | Where-Object { $_.compatibility.firefox.min -eq "$major.0" } | Select-Object -First 1
        if ($matchedLang) { $langUrl = $matchedLang.file.url }
    } catch {
        Write-Host "   - [提示] AMO API 检索回退至内置兜底版本。" -ForegroundColor Yellow
    }
    Write-Host "   - ⬇️  正在下载简体中文语言包 ($major)..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $langUrl -OutFile $langFile
}

Write-Host "`n⚙️  [受控配置基线] 正在应用以下黄金策略:" -ForegroundColor Cyan
Write-Host "   ▶ [搜索矩阵] 默认 Bing + @g 谷歌技术 + @gh 开源码直达 (阻断按键联想上传，强制新标签打开)" -ForegroundColor White
Write-Host "   ▶ [工效视效] 38 项现代极简基线 (触顶悬浮紧凑视图、4px 微留白、Glance 快窥、MRU 标签回跳、能耗休眠)" -ForegroundColor White
Write-Host "   ▶ [系统关联] 注册系统级浏览器能力与协议关联 (HTTP, HTTPS, HTML)，设为系统默认浏览器`n" -ForegroundColor White

$optSearch         = $true
$optCompact        = $true
$optDefaultBrowser = $true

# ==============================================================================
# 阶段 3: policies.json 先检后写 (严格无 BOM)
# ==============================================================================
$policiesObj = [ordered]@{
    RequestedLocales           = @("zh-CN", "en-US")
    DisableFirefoxAccounts     = $true
    DisableTelemetry           = $true
    DisableFirefoxStudies      = $true
    DisableDefaultBrowserAgent = $true
    DontCheckDefaultBrowser    = $true
    DisablePocket              = $true
    DisableFeedbackCommands    = $true
    OfferToSaveLogins          = $false
    PasswordManagerEnabled     = $false
    SearchSuggestEnabled       = $false
    DNSOverHTTPS               = [ordered]@{
        Enabled = $false
        Locked  = $true
    }
    ExtensionSettings          = [ordered]@{
        "uBlock0@raymondhill.net" = [ordered]@{
            installation_mode = "force_installed"
            install_url       = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
            default_area      = "navbar"
        }
        "{446900e4-71c2-419f-a6a7-df9c091e268b}" = [ordered]@{
            installation_mode = "force_installed"
            install_url       = "https://addons.mozilla.org/firefox/downloads/latest/bitwarden-password-manager/latest.xpi"
            default_area      = "navbar"
        }
        "langpack-zh-CN@firefox.mozilla.org" = [ordered]@{
            installation_mode = "force_installed"
            install_url       = $langUrl
        }
    }
}

# Gecko 官方白名单支持的标准 Preferences
$prefMap = [ordered]@{
    "intl.locale.requested"                         = [ordered]@{ Value = "zh-CN"; Status = "locked" }
    "intl.accept_languages"                         = [ordered]@{ Value = "zh-CN, zh, en-US, en"; Status = "default" }
    "browser.toolbars.bookmarks.visibility"         = [ordered]@{ Value = "always"; Status = "default" }
    "network.trr.mode"                              = [ordered]@{ Value = 5; Status = "locked" }
    "privacy.query_stripping.enabled"               = [ordered]@{ Value = $true; Status = "default" }
    "privacy.query_stripping.enabled.pbmode"        = [ordered]@{ Value = $true; Status = "default" }
    "privacy.trackingprotection.enabled"            = [ordered]@{ Value = $true; Status = "default" }
    "privacy.fingerprintingProtection"              = [ordered]@{ Value = $true; Status = "default" }
    "network.cookie.cookieBehavior"                 = [ordered]@{ Value = 5; Status = "default" }
    "media.peerconnection.ice.default_address_only" = [ordered]@{ Value = $true; Status = "default" }
    "media.peerconnection.ice.no_host"              = [ordered]@{ Value = $true; Status = "default" }
    "browser.tabs.loadBookmarksInTabs"              = [ordered]@{ Value = $true; Status = "default" }
    "browser.search.openintab"                      = [ordered]@{ Value = $true; Status = "default" }
    "browser.search.suggest.enabled"                = [ordered]@{ Value = $false; Status = "default" }
    "browser.urlbar.suggest.searches"               = [ordered]@{ Value = $false; Status = "default" }
    "browser.startup.page"                          = [ordered]@{ Value = 3; Status = "default" }
    "browser.download.useDownloadDir"               = [ordered]@{ Value = $true; Status = "default" }
    "browser.tabs.unloadOnLowMemory"                = [ordered]@{ Value = $true; Status = "default" }
    "zen.welcome-screen.seen"                       = [ordered]@{ Value = $true; Status = "default" }
    "browser.aboutwelcome.enabled"                  = [ordered]@{ Value = $false; Status = "default" }
    "trailhead.firstrun.didSeeAboutWelcome"         = [ordered]@{ Value = $true; Status = "default" }
    "browser.startup.homepage_override.mstone"      = [ordered]@{ Value = "ignore"; Status = "default" }
    "zen.workspaces.open-new-tab-if-last-unpinned-tab-is-closed" = [ordered]@{ Value = $true; Status = "default" }
}

if ($optSearch) {
    $policiesObj["SearchEngines"] = [ordered]@{
        Default         = "Bing"
        PreventInstalls = $false
        Remove          = @("Baidu", "百度")
        Add             = @(
            [ordered]@{
                Name        = "Google"
                URLTemplate = "https://www.google.com/search?q={searchTerms}"
                Method      = "GET"
                IconURL     = "https://www.google.com/favicon.ico"
                Alias       = "@g"
            },
            [ordered]@{
                Name        = "GitHub"
                URLTemplate = "https://github.com/search?q={searchTerms}&type=repositories"
                Method      = "GET"
                IconURL     = "https://github.com/favicon.ico"
                Alias       = "@gh"
            }
        )
    }
}

$policiesObj["Preferences"] = $prefMap

# 编译并比对 policies.json
$policyPath = Join-Path $distDir "policies.json"
$newJsonOut = ([ordered]@{ policies = $policiesObj } | ConvertTo-Json -Depth 10).Replace("\u0026", "&")

if ((Test-Path $policyPath) -and ((Get-Content -Path $policyPath -Raw -Encoding utf8NoBOM).Trim() -eq $newJsonOut.Trim())) {
    Write-Host "✅ [已就绪] $policyPath 策略与基准一致，无需重复写入。" -ForegroundColor Green
} else {
    Set-Content -Path $policyPath -Value $newJsonOut -Encoding utf8NoBOM
    Write-Host "✅ [更新] 已成功写入企业策略: $policyPath (UTF-8 No-BOM)" -ForegroundColor Green
}

# ==============================================================================
# 阶段 4: defaults\pref\ 全局默认首选项先检后写
# ==============================================================================
$defaultsPrefDir = Join-Path $InstallDir "defaults\pref"
New-Item -ItemType Directory -Path $defaultsPrefDir -Force | Out-Null
$defaultsPrefFile = Join-Path $defaultsPrefDir "zen-overrides.js"

$prefLines = [System.Collections.Generic.List[string]]::new()
$prefLines.Add('// Zen Browser Global Default Preferences (Deployed by Automation Script)')
$prefLines.Add('pref("intl.locale.requested", "zh-CN");')
$prefLines.Add('pref("intl.accept_languages", "zh-CN, zh, en-US, en");')
$prefLines.Add('pref("browser.toolbars.bookmarks.visibility", "always");')
$prefLines.Add('pref("browser.tabs.loadBookmarksInTabs", true);')
$prefLines.Add('pref("browser.search.openintab", true);')
$prefLines.Add('pref("browser.search.suggest.enabled", false);')
$prefLines.Add('pref("browser.urlbar.suggest.searches", false);')
$prefLines.Add('pref("browser.startup.page", 3);')
$prefLines.Add('pref("browser.download.useDownloadDir", true);')
$prefLines.Add('pref("browser.shell.checkDefaultBrowser", false);')
$prefLines.Add('pref("media.autoplay.default", 5);')
$prefLines.Add('pref("browser.tabs.unloadOnLowMemory", true);')
$prefLines.Add('pref("mousewheel.min_line_scroll_amount", 20);')
$prefLines.Add('pref("zen.welcome-screen.seen", true);')
$prefLines.Add('pref("browser.aboutwelcome.enabled", false);')
$prefLines.Add('pref("trailhead.firstrun.didSeeAboutWelcome", true);')
$prefLines.Add('pref("browser.startup.homepage_override.mstone", "ignore");')
$prefLines.Add('pref("zen.workspaces.open-new-tab-if-last-unpinned-tab-is-closed", true);')

if ($optCompact) {
    # 紧凑模式与视口布局
    $prefLines.Add('pref("zen.view.compact.enable-at-startup", true);')
    $prefLines.Add('pref("zen.view.compact.hide-toolbar", true);')
    $prefLines.Add('pref("zen.view.compact.hide-tabbar", true);')
    $prefLines.Add('pref("zen.view.compact.show-sidebar-and-toolbar-on-hover", true);')
    $prefLines.Add('pref("zen.view.compact.sidebar-keep-hover.duration", 150);')
    $prefLines.Add('pref("zen.view.hide-window-controls", true);')
    $prefLines.Add('pref("zen.view.borderless-fullscreen", true);')

    # 视觉风格与材质 (4px 微卡片留白)
    $prefLines.Add('pref("zen.theme.acrylic-sidebar", true);')
    $prefLines.Add('pref("zen.theme.acrylic-urlbar", true);')
    $prefLines.Add('pref("zen.theme.border-radius", -1);')
    $prefLines.Add('pref("zen.theme.content-element-separation", 4);')
    $prefLines.Add('pref("zen.theme.hide-unified-extensions-button", true);')
    $prefLines.Add('pref("zen.theme.hide-tab-throbber", true);')

    # 侧边栏与地址栏
    $prefLines.Add('pref("zen.view.use-single-toolbar", true);')
    $prefLines.Add('pref("zen.tabs.vertical.right-side", false);')
    $prefLines.Add('pref("zen.view.sidebar-expanded", true);')
    $prefLines.Add('pref("zen.urlbar.behavior", "floating-on-type");')
    $prefLines.Add('pref("zen.urlbar.show-domain-only-in-sidebar", true);')
    $prefLines.Add('pref("zen.urlbar.single-toolbar-show-copy-url", false);')
    $prefLines.Add('pref("zen.urlbar.hide-one-offs", true);')
    $prefLines.Add('pref("zen.urlbar.replace-newtab", true);')

    # 多工作区与分屏
    $prefLines.Add('pref("zen.workspaces.separate-essentials", true);')
    $prefLines.Add('pref("zen.workspaces.swipe-actions", false);')
    $prefLines.Add('pref("zen.workspaces.wrap-around-navigation", true);')
    $prefLines.Add('pref("zen.splitView.enable-drag-over-split", true);')

    # Glance 悬浮快窥与标签流转
    $prefLines.Add('pref("zen.glance.enabled", true);')
    $prefLines.Add('pref("zen.glance.activation-method", "alt");')
    $prefLines.Add('pref("zen.glance.enable-contextmenu-search", true);')
    $prefLines.Add('pref("zen.tabs.select-recently-used-on-close", true);')
    $prefLines.Add('pref("zen.tabs.rename-tabs", true);')
    $prefLines.Add('pref("zen.tabs.open-pinned-in-new-tab", true);')
    $prefLines.Add('pref("zen.tabs.close-on-back-with-no-history", false);')
}

$newPrefContent = ($prefLines -join "`n").Trim()
if ((Test-Path $defaultsPrefFile) -and ((Get-Content -Path $defaultsPrefFile -Raw -Encoding utf8NoBOM).Trim() -eq $newPrefContent)) {
    Write-Host "✅ [已就绪] $defaultsPrefFile 全局偏好与基准一致，无需重复写入。" -ForegroundColor Green
} else {
    Set-Content -Path $defaultsPrefFile -Value $prefLines -Encoding utf8NoBOM
    Write-Host "✅ [更新] 已成功写入全局默认首选项: $defaultsPrefFile" -ForegroundColor Green
}

# ==============================================================================
# 阶段 5: Profile user.js 增量智能合并与可观测对比 (非破坏性维护)
# ==============================================================================
# 组装待比对的目标字典
$desiredPrefsMap = [ordered]@{
    "intl.locale.requested"                                        = "zh-CN"
    "intl.accept_languages"                                        = "zh-CN, zh, en-US, en"
    "browser.toolbars.bookmarks.visibility"                        = "always"
    "browser.tabs.loadBookmarksInTabs"                             = $true
    "browser.search.openintab"                                     = $true
    "browser.search.suggest.enabled"                               = $false
    "browser.urlbar.suggest.searches"                              = $false
    "browser.startup.page"                                         = 3
    "browser.download.useDownloadDir"                              = $true
    "browser.shell.checkDefaultBrowser"                            = $false
    "media.autoplay.default"                                       = 5
    "browser.tabs.unloadOnLowMemory"                               = $true
    "mousewheel.min_line_scroll_amount"                            = 20
    "zen.welcome-screen.seen"                                      = $true
    "browser.aboutwelcome.enabled"                                 = $false
    "trailhead.firstrun.didSeeAboutWelcome"                        = $true
    "browser.startup.homepage_override.mstone"                     = "ignore"
    "zen.workspaces.open-new-tab-if-last-unpinned-tab-is-closed"    = $true
}

if ($optCompact) {
    $desiredPrefsMap["zen.view.compact.enable-at-startup"]                 = $true
    $desiredPrefsMap["zen.view.compact.hide-toolbar"]                      = $true
    $desiredPrefsMap["zen.view.compact.hide-tabbar"]                       = $true
    $desiredPrefsMap["zen.view.compact.show-sidebar-and-toolbar-on-hover"] = $true
    $desiredPrefsMap["zen.view.compact.sidebar-keep-hover.duration"]       = 150
    $desiredPrefsMap["zen.view.hide-window-controls"]                      = $true
    $desiredPrefsMap["zen.view.borderless-fullscreen"]                     = $true
    $desiredPrefsMap["zen.theme.acrylic-sidebar"]                          = $true
    $desiredPrefsMap["zen.theme.acrylic-urlbar"]                           = $true
    $desiredPrefsMap["zen.theme.border-radius"]                            = -1
    $desiredPrefsMap["zen.theme.content-element-separation"]               = 4
    $desiredPrefsMap["zen.theme.hide-unified-extensions-button"]           = $true
    $desiredPrefsMap["zen.theme.hide-tab-throbber"]                        = $true
    $desiredPrefsMap["zen.view.use-single-toolbar"]                        = $true
    $desiredPrefsMap["zen.tabs.vertical.right-side"]                       = $false
    $desiredPrefsMap["zen.view.sidebar-expanded"]                          = $true
    $desiredPrefsMap["zen.urlbar.behavior"]                                = "floating-on-type"
    $desiredPrefsMap["zen.urlbar.show-domain-only-in-sidebar"]             = $true
    $desiredPrefsMap["zen.urlbar.single-toolbar-show-copy-url"]            = $false
    $desiredPrefsMap["zen.urlbar.hide-one-offs"]                           = $true
    $desiredPrefsMap["zen.urlbar.replace-newtab"]                          = $true
    $desiredPrefsMap["zen.workspaces.separate-essentials"]                 = $true
    $desiredPrefsMap["zen.workspaces.swipe-actions"]                       = $false
    $desiredPrefsMap["zen.workspaces.wrap-around-navigation"]              = $true
    $desiredPrefsMap["zen.splitView.enable-drag-over-split"]               = $true
    $desiredPrefsMap["zen.glance.enabled"]                                 = $true
    $desiredPrefsMap["zen.glance.activation-method"]                       = "alt"
    $desiredPrefsMap["zen.glance.enable-contextmenu-search"]               = $true
    $desiredPrefsMap["zen.tabs.select-recently-used-on-close"]             = $true
    $desiredPrefsMap["zen.tabs.rename-tabs"]                               = $true
    $desiredPrefsMap["zen.tabs.open-pinned-in-new-tab"]                    = $true
    $desiredPrefsMap["zen.tabs.close-on-back-with-no-history"]             = $false
}

$profiles = Get-ChildItem -Path "$env:APPDATA\zen\Profiles" -Directory -ErrorAction SilentlyContinue
if ($profiles) {
    Write-Host "`n🔍 扫描并增量比对用户 Profile user.js 配置状态..." -ForegroundColor Cyan
    foreach ($prof in $profiles) {
        $userJsFile = Join-Path $prof.FullName "user.js"
        $diffs = Update-UserJsPreferences -Path $userJsFile -DesiredPrefs $desiredPrefsMap

        if ($diffs.Count -gt 0) {
            Write-Host "`n📝 Profile [$($prof.Name)] 发现 $($diffs.Count) 项配置与基线存在差异，已原位更新:" -ForegroundColor Yellow
            $diffs | Format-Table -Property @{ Label = "首选项名称 (Preference)"; Expression = { $_.Preference } },
                                            @{ Label = "原值 (Old)"; Expression = { $_.OldValue } },
                                            @{ Label = "基线值 (New)"; Expression = { $_.NewValue } } -AutoSize
        } else {
            Write-Host "✅ Profile [$($prof.Name)] 所有配置项均已处于最佳基线，无需任何写入 (幂等保持)。" -ForegroundColor Green
        }
    }
} else {
    Write-Host "💡 尚未检测到用户 Profile 目录，全新安装将在首次启动浏览器时由全局 defaults\pref\ 自动初始化。" -ForegroundColor Gray
}

# ==============================================================================
# 阶段 6: 系统浏览器注册与默认应用配置 (先检后配与闭环反馈)
# ==============================================================================
if ($optDefaultBrowser) {
    Write-Host "`n🌐 检查系统浏览器注册与默认应用状态..." -ForegroundColor Cyan

    $zenExe = Join-Path $InstallDir "zen.exe"
    $helperExe = Join-Path $InstallDir "uninstall\helper.exe"

    # 1. 检查注册表注册就绪度 (Capabilities & ProgID & RegisteredApplications)
    $regApp = (Get-ItemProperty "HKCU:\Software\RegisteredApplications" -Name "Zen Browser" -ErrorAction SilentlyContinue)."Zen Browser"
    if (-not $regApp) {
        $regApp = (Get-ItemProperty "HKCU:\Software\RegisteredApplications" -Name "Zen" -ErrorAction SilentlyContinue).Zen
    }
    $hasCapabilities = (Test-Path "HKCU:\Software\Clients\StartMenuInternet\Zen\Capabilities")
    $hasProgId = (Test-Path "HKCU:\Software\Classes\ZenHTML\shell\open\command") -and (Test-Path "HKCU:\Software\Classes\ZenURL\shell\open\command")
    $isRegistryReady = ($null -ne $regApp -and $hasCapabilities -and $hasProgId)

    # 2. 检查系统当前默认浏览器协议指向
    $currentHttpProg = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    $currentHttpsProg = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    $isDefaultBrowser = ($currentHttpProg -like "*zen*" -or $currentHttpProg -eq "ZenURL" -or $currentHttpProg -eq "ZenHTML") -and
                        ($currentHttpsProg -like "*zen*" -or $currentHttpsProg -eq "ZenURL" -or $currentHttpsProg -eq "ZenHTML")

    if ($isRegistryReady -and $isDefaultBrowser) {
        Write-Host "✅ [已就绪] Zen Browser 已注册且当前已为系统默认浏览器 (HTTP: $currentHttpProg)，跳过重复配置。" -ForegroundColor Green
    } else {
        Write-Host "⚙️  正在向系统注册 Zen Browser 浏览器能力与文件/协议关联..." -ForegroundColor Yellow

        function Ensure-RegKey([string]$path) {
            if (-not (Test-Path $path)) {
                New-Item -Path $path -Force | Out-Null
            }
        }
        function Set-RegDefaultValue([string]$path, [string]$value) {
            Ensure-RegKey $path
            Set-Item -Path $path -Value $value -Force
            Set-ItemProperty -Path $path -Name "(default)" -Value $value -Force -ErrorAction SilentlyContinue
        }
        function Set-RegNamedValue([string]$path, [string]$name, $value, [string]$type = "String") {
            Ensure-RegKey $path
            Set-ItemProperty -Path $path -Name $name -Value $value -Type $type -Force
        }

        # --- A. 注册 ProgID: ZenHTML (用于 HTML 文档与网页文件) ---
        $progIdHtml = "ZenHTML"
        $htmlKey = "HKCU:\Software\Classes\$progIdHtml"
        Set-RegDefaultValue $htmlKey "Zen HTML Document"
        Set-RegNamedValue $htmlKey "FriendlyTypeName" "Zen HTML Document"
        Set-RegNamedValue $htmlKey "AppUserModelId" "Zen"

        $htmlAppKey = "$htmlKey\Application"
        Set-RegNamedValue $htmlAppKey "ApplicationName" "Zen Browser"
        Set-RegNamedValue $htmlAppKey "ApplicationIcon" "`"$zenExe`",0"
        Set-RegNamedValue $htmlAppKey "ApplicationDescription" "Zen Browser"
        Set-RegNamedValue $htmlAppKey "ApplicationCompany" "Zen"

        Set-RegDefaultValue "$htmlKey\DefaultIcon" "`"$zenExe`",0"
        Set-RegDefaultValue "$htmlKey\shell\open\command" "`"$zenExe`" -osint -url `"%1`""

        # --- B. 注册 ProgID: ZenURL (用于 HTTP / HTTPS / FTP 等协议) ---
        $progIdUrl = "ZenURL"
        $urlKey = "HKCU:\Software\Classes\$progIdUrl"
        Set-RegDefaultValue $urlKey "Zen URL"
        Set-RegNamedValue $urlKey "AppUserModelId" "Zen"
        Set-RegNamedValue $urlKey "EditFlags" 2 "DWord"
        Set-RegNamedValue $urlKey "URL Protocol" ""

        $urlAppKey = "$urlKey\Application"
        Set-RegNamedValue $urlAppKey "ApplicationName" "Zen Browser"
        Set-RegNamedValue $urlAppKey "ApplicationIcon" "`"$zenExe`",0"
        Set-RegNamedValue $urlAppKey "ApplicationDescription" "Zen Browser"
        Set-RegNamedValue $urlAppKey "ApplicationCompany" "Zen"

        Set-RegDefaultValue "$urlKey\DefaultIcon" "`"$zenExe`",0"
        Set-RegDefaultValue "$urlKey\shell\open\command" "`"$zenExe`" -osint -url `"%1`""

        # --- C. 注册 ProgID: ZenPDF (用于 PDF 文档) ---
        $progIdPdf = "ZenPDF"
        $pdfKey = "HKCU:\Software\Classes\$progIdPdf"
        Set-RegDefaultValue $pdfKey "Zen PDF Document"
        Set-RegNamedValue $pdfKey "FriendlyTypeName" "Zen PDF Document"
        Set-RegNamedValue $pdfKey "AppUserModelId" "Zen"
        Set-RegDefaultValue "$pdfKey\DefaultIcon" "`"$zenExe`",0"
        Set-RegDefaultValue "$pdfKey\shell\open\command" "`"$zenExe`" -osint -url `"%1`""

        # --- D. 注册 Applications\zen.exe ---
        $appKey = "HKCU:\Software\Classes\Applications\zen.exe"
        Set-RegNamedValue $appKey "FriendlyAppName" "Zen Browser"
        Set-RegDefaultValue "$appKey\DefaultIcon" "`"$zenExe`",0"
        Set-RegDefaultValue "$appKey\shell\open\command" "`"$zenExe`" -osint -url `"%1`""

        $supportedExts = @(".htm", ".html", ".shtml", ".xht", ".xhtml", ".svg", ".webp", ".pdf")
        Ensure-RegKey "$appKey\SupportedTypes"
        foreach ($ext in $supportedExts) {
            Set-RegNamedValue "$appKey\SupportedTypes" $ext ""
        }

        # --- E. 注册 StartMenuInternet 客户端与 Capabilities ---
        $clientKey = "HKCU:\Software\Clients\StartMenuInternet\Zen"
        Set-RegDefaultValue $clientKey "Zen Browser"
        Set-RegDefaultValue "$clientKey\DefaultIcon" "`"$zenExe`",0"
        Set-RegDefaultValue "$clientKey\shell\open\command" "`"$zenExe`""

        # InstallInfo
        $installInfoKey = "$clientKey\InstallInfo"
        Set-RegNamedValue $installInfoKey "HideIconsCommand" ""
        Set-RegNamedValue $installInfoKey "ShowIconsCommand" ""
        Set-RegNamedValue $installInfoKey "ReinstallCommand" "`"$zenExe`" -setDefaultBrowser"

        # Capabilities
        $capKey = "$clientKey\Capabilities"
        Set-RegNamedValue $capKey "ApplicationName" "Zen Browser"
        Set-RegNamedValue $capKey "ApplicationIcon" "`"$zenExe`",0"
        Set-RegNamedValue $capKey "ApplicationDescription" "Zen Browser"

        # FileAssociations
        $fileAssocKey = "$capKey\FileAssociations"
        Set-RegNamedValue $fileAssocKey ".htm" $progIdHtml
        Set-RegNamedValue $fileAssocKey ".html" $progIdHtml
        Set-RegNamedValue $fileAssocKey ".shtml" $progIdHtml
        Set-RegNamedValue $fileAssocKey ".xht" $progIdHtml
        Set-RegNamedValue $fileAssocKey ".xhtml" $progIdHtml
        Set-RegNamedValue $fileAssocKey ".svg" $progIdHtml
        Set-RegNamedValue $fileAssocKey ".webp" $progIdHtml
        Set-RegNamedValue $fileAssocKey ".pdf" $progIdPdf

        # URLAssociations
        $urlAssocKey = "$capKey\URLAssociations"
        Set-RegNamedValue $urlAssocKey "http" $progIdUrl
        Set-RegNamedValue $urlAssocKey "https" $progIdUrl
        Set-RegNamedValue $urlAssocKey "ftp" $progIdUrl

        # StartMenu
        Set-RegNamedValue "$capKey\StartMenu" "StartMenuInternet" "Zen"

        # --- F. 注册 RegisteredApplications (在 Windows 默认应用中点亮 Zen Browser) ---
        Set-RegNamedValue "HKCU:\Software\RegisteredApplications" "Zen Browser" "Software\Clients\StartMenuInternet\Zen\Capabilities"
        Sync-ZenShortcuts

        # --- G. 挂载用户层 OpenWithProgids 透传 ---
        foreach ($ext in @(".htm", ".html", ".shtml", ".xht", ".xhtml")) {
            Set-RegNamedValue "HKCU:\Software\Classes\$ext\OpenWithProgids" $progIdHtml ([byte[]]@()) "Binary"
        }
        foreach ($proto in @("http", "https")) {
            Set-RegNamedValue "HKCU:\Software\Classes\$proto\OpenWithProgids" $progIdUrl ([byte[]]@()) "Binary"
        }

        Write-Host "✅ [注册] 系统浏览器功能与协议关联注册完成。" -ForegroundColor Green

        # --- H. 触发设置为系统默认浏览器 ---
        if (-not $isDefaultBrowser) {
            Write-Host "🌐 正在配置 Zen Browser 为系统默认浏览器..." -ForegroundColor Cyan

            # 1. 优先调用官方 helper.exe /SetAsDefaultAppUser (Firefox/Gecko 原生用户级注册器，带 3s 超时保护)
            if (Test-Path $helperExe) {
                $hProc = Start-Process -FilePath $helperExe -ArgumentList "/SetAsDefaultAppUser" -PassThru -NoNewWindow -ErrorAction SilentlyContinue
                if ($hProc) { $hProc.WaitForExit(3000) | Out-Null }
            }

            # 2. 调用 zen.exe 静默触发 Gecko 内核原生 UserChoice 写入 (必须附加 -silent 防弹出主窗口挂起进程，带 5s 超时保护)
            if (Test-Path $zenExe) {
                $zProc = Start-Process -FilePath $zenExe -ArgumentList "-silent -setDefaultBrowser" -PassThru -NoNewWindow -ErrorAction SilentlyContinue
                if ($zProc) { $zProc.WaitForExit(5000) | Out-Null }
            }

            # 单次闭环清理 helper.exe / zen.exe 退出时派生出来的 Gecko 幽灵项，确保注册表纯净
            Clear-GeckoStrayRegistrations

            # 3. 闭环验证生效状态
            Start-Sleep -Milliseconds 600
            $postHttp = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
            $postHttps = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
            $isNowDefault = ($postHttp -like "*zen*" -or $postHttp -eq "ZenURL" -or $postHttp -eq "ZenHTML") -and
                            ($postHttps -like "*zen*" -or $postHttps -eq "ZenURL" -or $postHttps -eq "ZenHTML")

            if ($isNowDefault) {
                Write-Host "✅ [生效] Zen Browser 已成功配置为系统默认浏览器 (HTTP: $postHttp / HTTPS: $postHttps)。" -ForegroundColor Green
            } else {
                Write-Host "💡 已完成底层功能与协议注册。若系统未直接切换，可在打开的【默认应用】设置中将 Zen Browser 设为默认。" -ForegroundColor Yellow
                $targetUri = $isAdmin ? "ms-settings:defaultapps?registeredAppMachine=Zen%20Browser" : "ms-settings:defaultapps?registeredAppUser=Zen%20Browser"
                Start-Process $targetUri -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  ✅ Zen Browser 全流程策略与首选项校验完成！" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "   - 幂等保护: 无变更文件全部跳过写操作，零重复网络与磁盘 I/O" -ForegroundColor Gray
Write-Host "   - 账号切除: DisableFirefoxAccounts 生效，底层禁用账号登录，纯本地离线无状态" -ForegroundColor Gray
Write-Host "   - 增量纳管: Profile user.js 采用非破坏性更新，完整保留用户原有配置" -ForegroundColor Gray
Write-Host "   - 搜索矩阵: 默认高可用 Bing + @g 谷歌技术 + @gh 开源码直达" -ForegroundColor Gray
Write-Host "   - 默认应用: 注册系统浏览器能力与协议关联，无缝接管 HTTP / HTTPS / HTML" -ForegroundColor Gray
Write-Host "   - 隐私加固: 彻底切断输入框按键联想上传，搜索结果强制新标签打开" -ForegroundColor Gray

Write-Host "`n--------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📋 [手动收尾引导清单 (Manual Checklist)]" -ForegroundColor Cyan
if (-not $isNowDefault) {
    Write-Host " 1. 默认应用: 底层协议已注册，请在弹出的【默认应用】设置中将 Zen Browser 设为默认浏览器" -ForegroundColor Yellow
}
Write-Host " 2. 扩展图标: uBlock Origin 与 Bitwarden 已预置生效，启动后请在工具栏拼图菜单中固定图标" -ForegroundColor Gray
Write-Host " 3. 紧凑视图: 已注入触顶悬浮紧凑模式样式，可根据屏幕视网膜 DPI 在侧栏按需体验" -ForegroundColor Gray
Write-Host "--------------------------------------------------`n" -ForegroundColor DarkGray
Write-Host "👉 启动浏览器即可立即检验全量生效状态！" -ForegroundColor Green
