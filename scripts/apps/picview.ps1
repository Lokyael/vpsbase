#requires -Version 7.0
<#
.SYNOPSIS
    PicView 看图工具

.DESCRIPTION
    PicView 极简快速看图工具 (Windows) 系统图像关联注册与体验偏好基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 基于 Scoop 纳管的二进制本体 (D:\prog\scoop\apps\picview\current\PicView.exe)。
    3. 系统级图像关联与默认应用点亮：向注册表写入 ProgID (PicView.Image)、Capabilities 与 RegisteredApplications，在 Win11 设置中点亮 PicView，并注册 13 种主流图片格式。
    4. 现代化看图体验黄金基线：注入 Config\UserSettings.json，固化简体中文界面、单窗口复用防多开霸屏、ESC 直接退出、循环看图与超大图自适应窗口。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync        : 增量对齐黄金基线 (默认，缺失则装、偏离则修)
    - Check       : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - ResetConfig : 仅执行系统图像关联注册与 UserSettings.json 黄金基线注入
    - Uninstall   : 彻底清洁卸载与注销系统图片关联，抹除软件与配置
    - Upgrade     : 覆盖升级客户端本体 (调用 Scoop update)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\picview.ps1 -Action Check

    # 交互式检查并应用黄金基线
    pwsh -File .\scripts\apps\picview.ps1

    # 仅修复系统图像关联与体验基线配置
    pwsh -File .\scripts\apps\picview.ps1 -Action ResetConfig

    # 彻底清洁卸载
    pwsh -File .\scripts\apps\picview.ps1 -Action Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "ResetConfig", "Uninstall", "Upgrade")]
    [string]$Action = "Sync",

    [switch]$Yes
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
    throw "【权限错误】PicView 注册系统级文件关联与 RegisteredApplications 需管理员特权，请在提升的 pwsh 会话中重新执行！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防配置污染，请直接在桌面登录用户会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 应用元数据与部署基准路径锁定 (Golden Baseline Paths)
# ==============================================================================
$AppId        = "picview"
$AppName      = "PicView 看图工具"
$ProcessName  = "PicView"
$ScoopBucket  = "extras"
$ScoopApp     = "picview"
$progId       = "PicView.Image"
$imgExts      = @(".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".ico", ".tiff", ".tif", ".avif", ".heic", ".svg", ".jxl")

$scoopRoot    = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
$InstallDir   = Join-Path $scoopRoot "apps\$ScoopApp\current"
$AppExe       = Join-Path $InstallDir "PicView.exe"
$ConfDir      = Join-Path $InstallDir "Config"
$ConfigFile   = Join-Path $ConfDir "UserSettings.json"
$PersistDir   = Join-Path $scoopRoot "persist\$ScoopApp"

$HighValueUserData = @(
    "个人看图习惯与界面偏好: $ConfigFile",
    "持久化配置目录: $PersistDir"
)

function Ensure-RegKey {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null }
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# 受控属性全景声明清单 (含 Purpose 目的 与 Impact 影响)
$ManagedSpecs = @(
    @{
        Module   = "客户端本体"
        Property = "主执行文件 (PicView.exe)"
        Expected = "已安装于 Scoop 环境"
        Purpose  = "部署极简快速看图工具本体，支持超大图快速解包与丰富图像格式渲染"
        Impact   = "若未就绪将自动调用 Scoop 从 extras bucket 安装"
        Type     = "Binary"
    },
    @{
        Module   = "系统集成"
        Property = "全功能看图器注册 (Capabilities)"
        Expected = "已注册 (RegisteredApplications + ProgID)"
        Purpose  = "在注册表中注入 PicView.Image 与 Capabilities，支持 13 种主流图片格式关联"
        Impact   = "在 Windows 11 设置「默认应用」中点亮 PicView，允许一键设为默认图片查看器"
        Type     = "Integration"
    },
    @{
        Module   = "偏好配置"
        Path     = "UIProperties.UserLanguage"
        Property = "界面语言 (UIProperties.UserLanguage)"
        Expected = "zh-CN"
        Purpose  = "固化简体中文界面"
        Impact   = "界面所有按钮、提示与菜单以中文呈现"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Path     = "UIProperties.OpenInSameWindow"
        Property = "单窗口复用 (UIProperties.OpenInSameWindow)"
        Expected = "True"
        Purpose  = "连续点击多张图片时在同一窗口中快速复用切换"
        Impact   = "杜绝连续双击多张图片导致桌面弹出数十个窗口霸屏卡顿"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Path     = "UIProperties.ShowConfirmationOnEsc"
        Property = "ESC 免确认退出 (UIProperties.ShowConfirmationOnEsc)"
        Expected = "False"
        Purpose  = "按 ESC 键直接关闭看图窗口"
        Impact   = "退出时不再弹出「确认退出」询问对话框，提升看图流转效率"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Path     = "UIProperties.ShowFullPathInTitleBar"
        Property = "标题栏显示完整路径 (UIProperties.ShowFullPathInTitleBar)"
        Expected = "True"
        Purpose  = "窗口标题栏直观呈现图片所在绝对磁盘路径"
        Impact   = "方便快速定位文件所在目录"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Path     = "UIProperties.Looping"
        Property = "循环看图 (UIProperties.Looping)"
        Expected = "True"
        Purpose  = "翻页至当前目录最后一张图片时自动循环回第一张"
        Impact   = "看图翻页不中断"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Path     = "StartUp.OpenLastFile"
        Property = "启动时不自动打开上次文件 (StartUp.OpenLastFile)"
        Expected = "False"
        Purpose  = "每次冷启动或双击新图片时仅聚焦当前目标"
        Impact   = "避免打开查看器时闪现上次关闭时的历史图片"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Path     = "ImageScaling.ZoomToFit"
        Property = "超大图自适应窗口 (ImageScaling.ZoomToFit)"
        Expected = "True"
        Purpose  = "超过屏幕分辨率的超大高像素图片自动等比例缩放适应窗口"
        Impact   = "消除打开高分辨率相机原图时超出屏幕边界需拖动滚动条的问题"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Path     = "WindowProperties.KeepCentered"
        Property = "窗口居中呈现 (WindowProperties.KeepCentered)"
        Expected = "True"
        Purpose  = "窗口每次打开始终保持屏幕居中呈现"
        Impact   = "窗口位置稳定一致，不出现边缘偏移"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Path     = "Navigation.IsFileWatcherEnabled"
        Property = "文件变动智能监视 (Navigation.IsFileWatcherEnabled)"
        Expected = "True"
        Purpose  = "当前目录下有新图片保存或删除时实时刷新图库"
        Impact   = "动态更新翻页队列，无需手动按 F5 刷新"
        Type     = "Config"
    }
)

# ==============================================================================
# 3. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将注销系统图片关联并彻底清理 PicView 查看器！" -ForegroundColor Yellow
        Write-Host "📌 【即将被物理抹除的高价值用户数据清单】:" -ForegroundColor Cyan
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "👉 执行清洁卸载将彻底清理配置目录。若需保留客制配置，请先手动备份。`n" -ForegroundColor Yellow

        $confirm = (Read-Host "确认注销系统图片关联并彻底清理 PicView 及其配置? [y/N]").Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在清理 PicView 系统关联与配置..." -ForegroundColor Yellow

    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force

    @(
        "HKLM:\SOFTWARE\Classes\$progId",
        "HKLM:\SOFTWARE\Classes\Applications\PicView.exe",
        "HKLM:\SOFTWARE\PicView",
        "HKCU:\Software\Classes\$progId",
        "HKCU:\Software\Classes\Applications\PicView.exe",
        "HKCU:\Software\PicView"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "PicView" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "PicView" -ErrorAction SilentlyContinue

    foreach ($ext in $imgExts) {
        Remove-ItemProperty -Path "HKCU:\Software\Classes\$ext\OpenWithProgids" -Name $progId -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Classes\$ext\OpenWithProgids" -Name $progId -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\OpenWithProgids" -Name $progId -ErrorAction SilentlyContinue
    }

    @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "PicView.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Scoop Apps" "PicView.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "PicView.lnk")
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path $ConfDir) { Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $PersistDir) { Remove-Item -Path $PersistDir -Recurse -Force -ErrorAction SilentlyContinue }

    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        if (Test-Path (Join-Path $scoopRoot "apps\picview")) {
            & scoop uninstall -p picview
        }
    }
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`n✅ [清洁卸载完成] PicView 系统注册与本体已彻底清除。`n" -ForegroundColor Green
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
$PendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()

$isInstalled = Test-Path $AppExe
$regApp = (Get-ItemProperty "HKLM:\SOFTWARE\RegisteredApplications" -Name "PicView" -ErrorAction SilentlyContinue).PicView
if (-not $regApp) {
    $regApp = (Get-ItemProperty "HKCU:\Software\RegisteredApplications" -Name "PicView" -ErrorAction SilentlyContinue).PicView
}
$hasApp = (Test-Path "HKLM:\SOFTWARE\Classes\Applications\PicView.exe") -or (Test-Path "HKCU:\Software\Classes\Applications\PicView.exe")
$hasProgId = Test-Path "HKLM:\SOFTWARE\Classes\$progId"
$isRegistered = ($null -ne $regApp -and $hasApp -and $hasProgId)

$settingsJson = $null
if (Test-Path $ConfigFile) {
    try {
        $settingsJson = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
    } catch { }
}

function Get-JsonValueByPath($obj, [string]$propPath) {
    if ($null -eq $obj) { return $null }
    $parts = $propPath.Split('.')
    $curr = $obj
    foreach ($p in $parts) {
        if ($null -eq $curr -or -not ($curr.PSObject.Properties.Match($p).Count)) {
            return $null
        }
        $curr = $curr.$p
    }
    return "$curr"
}

foreach ($spec in $ManagedSpecs) {
    $actualStr = ""
    $isMatch = $false

    if ($spec.Type -eq "Binary") {
        $actualStr = if ($isInstalled) { "已安装" } else { "未安装" }
        $isMatch = $isInstalled
    } elseif ($spec.Type -eq "Integration") {
        $actualStr = if ($isRegistered) { "已注册" } else { "未完整注册" }
        $isMatch = $isRegistered
    } elseif ($spec.Type -eq "Config") {
        $val = Get-JsonValueByPath $settingsJson $spec.Path
        $actualStr = if ($null -eq $val) { "<缺省未设>" } else { "$val" }
        $isMatch = ($actualStr -eq $spec.Expected)
    }

    $AuditBoard.Add([PSCustomObject]@{
        分层模块 = $spec.Module
        受控属性 = $spec.Property
        期望基线 = $spec.Expected
        实机状态 = $actualStr
        状态判定 = if ($isMatch) { "✔ 匹配" } else { "✘ 偏离" }
    })

    if (-not $isMatch -and $Action -ne "Upgrade") {
        $PendingItems.Add([PSCustomObject]@{
            Spec     = $spec
            Actual   = $actualStr
            Expected = $spec.Expected
        })
    }
}

Write-Host "`n📊 [巡检看板] PicView 原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($Action -eq "Check") {
    if ($driftCount -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性均与工程黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $driftCount) -ForegroundColor Yellow
    }
    return
}

if ($driftCount -eq 0 -and $Action -ne "Upgrade") {
    Write-Host "✨ [状态合规] 所有受控属性均已符合工程黄金基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate - Shift-Left: 目的与影响结构化直出)
# ==============================================================================

# 5.1 运行态并发防覆写硬门禁
$runningPv = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if ($runningPv) {
    if (-not $Yes) {
        Write-Warning "检测到 PicView 看图工具当前正在运行！外部修改会被退出时的内存状态覆写。"
        $confirmProc = (Read-Host "是否立即关闭正在运行的 PicView 进程以继续应用基线? [Y/n]").Trim()
        if ($confirmProc -match '^(n|no)$') {
            Write-Host "[-] 用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningPv | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# 5.2 未安装审查门禁
if (-not $isInstalled) {
    if ($Action -eq "ResetConfig") {
        throw "未检测到 PicView 客户端安装！请先执行 -Action Sync 安装后再执行配置重置。"
    }

    if (-not $Yes) {
        $shouldInstall = (Read-Host "未检测到 PicView 客户端，是否立即调用 'scoop install extras/picview' 进行安装？[Y/n]").Trim()
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
    foreach ($p in $PendingItems) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.Spec.Property) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.Actual, $p.Expected) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $p.Spec.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $p.Spec.Impact) -ForegroundColor Gray
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

# 6.1 程序本体安装或覆盖升级
if (-not $isInstalled -or $Action -eq "Upgrade") {
    if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
        throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
    }

    if ($Action -eq "Upgrade") {
        Write-Host "`n📦 [覆盖升级] 正在调用 Scoop 升级 PicView 本体..." -ForegroundColor Cyan
        & scoop update picview
        Write-Host "✅ [升级完成] PicView 客户端本体已完成升级。`n" -ForegroundColor Green
        return
    } else {
        Write-Host "`n🚀 正在通过 Scoop 安装 PicView..." -ForegroundColor Cyan
        & scoop bucket add extras 2>$null | Out-Null
        & scoop install extras/picview

        if (Test-Path (Join-Path $InstallDir "PicView.exe")) {
            $AppExe = Join-Path $InstallDir "PicView.exe"
            $isInstalled = $true
        }
        if (-not $isInstalled) {
            throw "Scoop 安装完成，但未能定位到 $AppExe，请检查 Scoop 安装状态。"
        }
    }
}

# 6.2 注册系统关联与 Capabilities
Write-Host "`n⚙️  正在执行系统图像关联注册与 Capabilities 点亮..." -ForegroundColor Cyan

$progIdKey = "HKLM:\SOFTWARE\Classes\$progId"
Ensure-RegKey $progIdKey
Set-ItemProperty -Path $progIdKey -Name "(default)" -Value "PicView Image File" -Force
Ensure-RegKey "$progIdKey\DefaultIcon"
Set-ItemProperty -Path "$progIdKey\DefaultIcon" -Name "(default)" -Value "`"$AppExe`",0" -Force
Ensure-RegKey "$progIdKey\shell\open\command"
Set-ItemProperty -Path "$progIdKey\shell\open\command" -Name "(default)" -Value "`"$AppExe`" `"%1`"" -Force

$appKey = "HKLM:\SOFTWARE\Classes\Applications\PicView.exe"
Ensure-RegKey "$appKey\shell\open\command"
Set-ItemProperty -Path "$appKey\shell\open\command" -Name "(default)" -Value "`"$AppExe`" `"%1`"" -Force
Ensure-RegKey "$appKey\SupportedTypes"
foreach ($ext in $imgExts) {
    Set-ItemProperty -Path "$appKey\SupportedTypes" -Name $ext -Value "" -Force
}

$capKey = "HKLM:\SOFTWARE\PicView\Capabilities"
Ensure-RegKey $capKey
Set-ItemProperty -Path $capKey -Name "ApplicationName" -Value "PicView" -Force
Set-ItemProperty -Path $capKey -Name "ApplicationDescription" -Value "PicView Fast Image Viewer" -Force
Ensure-RegKey "$capKey\FileAssociations"
foreach ($ext in $imgExts) {
    Set-ItemProperty -Path "$capKey\FileAssociations" -Name $ext -Value $progId -Force
}

Ensure-RegKey "HKLM:\SOFTWARE\RegisteredApplications"
Set-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "PicView" -Value "SOFTWARE\PicView\Capabilities" -Force

foreach ($ext in $imgExts) {
    $extKey = "HKCU:\Software\Classes\$ext\OpenWithProgids"
    Ensure-RegKey $extKey
    Set-ItemProperty -Path $extKey -Name $progId -Value ([byte[]]@()) -Force
}
Write-Host "✅ 系统全功能看图器注册与 13 种主流图片格式关联完成。" -ForegroundColor Green

# 6.3 注入/调优 UserSettings.json 体验基线偏好
Ensure-Dir $ConfDir

$settings = if (Test-Path $ConfigFile) {
    try { Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
} else { $null }

if (-not $settings) { $settings = [PSCustomObject]@{} }
if (-not $settings.UIProperties) { $settings | Add-Member -MemberType NoteProperty -Name "UIProperties" -Value ([PSCustomObject]@{}) -Force }
if (-not $settings.StartUp) { $settings | Add-Member -MemberType NoteProperty -Name "StartUp" -Value ([PSCustomObject]@{}) -Force }
if (-not $settings.ImageScaling) { $settings | Add-Member -MemberType NoteProperty -Name "ImageScaling" -Value ([PSCustomObject]@{}) -Force }
if (-not $settings.WindowProperties) { $settings | Add-Member -MemberType NoteProperty -Name "WindowProperties" -Value ([PSCustomObject]@{}) -Force }
if (-not $settings.Navigation) { $settings | Add-Member -MemberType NoteProperty -Name "Navigation" -Value ([PSCustomObject]@{}) -Force }

$settings.UIProperties | Add-Member -MemberType NoteProperty -Name "UserLanguage" -Value "zh-CN" -Force
$settings.UIProperties | Add-Member -MemberType NoteProperty -Name "OpenInSameWindow" -Value $true -Force
$settings.UIProperties | Add-Member -MemberType NoteProperty -Name "ShowConfirmationOnEsc" -Value $false -Force
$settings.UIProperties | Add-Member -MemberType NoteProperty -Name "ShowFullPathInTitleBar" -Value $true -Force
$settings.UIProperties | Add-Member -MemberType NoteProperty -Name "Looping" -Value $true -Force
$settings.StartUp | Add-Member -MemberType NoteProperty -Name "OpenLastFile" -Value $false -Force
$settings.ImageScaling | Add-Member -MemberType NoteProperty -Name "ZoomToFit" -Value $true -Force
$settings.WindowProperties | Add-Member -MemberType NoteProperty -Name "KeepCentered" -Value $true -Force
$settings.Navigation | Add-Member -MemberType NoteProperty -Name "IsFileWatcherEnabled" -Value $true -Force

$jsonStr = $settings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ConfigFile, $jsonStr, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ UserSettings.json 体验基线偏好已原子落盘至: $ConfigFile" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与系统注册管理完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 图像关联: 已注册 PicView.Image 与 Capabilities，支持 jpg/png/webp 等主流格式" -ForegroundColor Gray
Write-Host "   - 偏好基线: 固化简体中文、单窗口复用(OpenInSameWindow)、ESC 免确认极速退出" -ForegroundColor Gray

$isDefaultPhoto = $false
try {
    $jpgChoice = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.jpg\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    if ($jpgChoice -eq $progId) { $isDefaultPhoto = $true }
} catch { }

if (-not $isDefaultPhoto) {
    Write-Host "`n--------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "📋 [手动收尾清单 (Actionable Handoff)]" -ForegroundColor Cyan
    Write-Host "  1. 设为默认: 在系统【默认应用】中将 PicView 设为照片查看器默认应用" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------`n" -ForegroundColor DarkGray
}

return
