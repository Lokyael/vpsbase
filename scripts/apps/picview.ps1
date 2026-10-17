#requires -Version 7.0
<#
.SYNOPSIS
    PicView 看图工具

.DESCRIPTION
    PicView 极简快速看图工具 (Windows) 系统图像关联注册与体验偏好基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循“先检查后配置、幂等无冗余”原则。
    2. 基于 Scoop 纳管的二进制本体（D:\prog\scoop\apps\picview\current\PicView.exe），前置安装状态探测。
    3. 系统级图像关联与默认应用点亮：向注册表写入 ProgID (PicView.Image)、Capabilities 与 RegisteredApplications，在 Win11 设置中点亮 PicView，并注册 13 种主流图片格式。
    4. 现代化看图体验黄金基线：注入 Config\UserSettings.json，固化简体中文界面、单窗口复用防多开霸屏、ESC 直接退出、循环看图与超大图自适应窗口。

.PARAMETER Clean
    清洁卸载模式。清理注册表系统关联与 Capabilities，清理 Config 配置，并通过 Scoop 卸载客户端本体。
    别名: -Fresh, -Reset

.PARAMETER CheckOnly
    只查不改模式（体检巡检）。逐项比对 PicView 安装状态、系统图像关联注册表与 UserSettings.json 核心参数基线，高亮输出 Diff，零写入安全退出。
    别名: -Audit

.PARAMETER ConfigOnly
    仅执行系统图像关联注册与 UserSettings.json 黄金基线注入，不重新安装或更新二进制程序。

.PARAMETER InstallOnly
    仅执行通过 Scoop 更新或安装 PicView 本体，不修改配置。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线（用于自动化流水线）。

.PARAMETER InstallDir
    PicView 安装目标目录，默认优先自适应探测 Scoop 路径（如 D:\prog\scoop\apps\picview\current）。

.PARAMETER ConfDir
    PicView 配置目录，默认为安装目录下的 Config。

.EXAMPLE
    # 交互式全流程检查与配置
    pwsh -File .\scripts\apps\picview.ps1

    # 只查不改体检巡检
    pwsh -File .\scripts\apps\picview.ps1 -CheckOnly

    # 仅修复系统图像关联与体验基线配置
    pwsh -File .\scripts\apps\picview.ps1 -ConfigOnly

    # 彻底清洁重装
    pwsh -File .\scripts\apps\picview.ps1 -Clean
#>

[CmdletBinding()]
param(
    [Alias("Fresh", "Reset")]
    [switch]$Clean,

    [Alias("Audit")]
    [switch]$CheckOnly,

    [switch]$ConfigOnly,
    [switch]$InstallOnly,
    [switch]$NonInteractive,
    [string]$InstallDir,
    [string]$ConfDir
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
# 0. 路径自适应探测与初始化
# ==============================================================================
$scoopRoots = @($env:SCOOP, "D:\prog\scoop", (Join-Path $env:USERPROFILE "scoop")) | Where-Object { $_ -and (Test-Path $_) }
$defaultScoop = if ($scoopRoots.Count -gt 0) { $scoopRoots[0] } else { "D:\prog\scoop" }

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    foreach ($root in $scoopRoots) {
        $cand = Join-Path $root "apps\picview\current"
        if (Test-Path (Join-Path $cand "PicView.exe")) {
            $InstallDir = $cand
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = Join-Path $defaultScoop "apps\picview\current"
    }
}

$pvExe = Join-Path $InstallDir "PicView.exe"
$isInstalled = Test-Path $pvExe

if ([string]::IsNullOrWhiteSpace($ConfDir)) {
    $ConfDir = Join-Path $InstallDir "Config"
}

$confFile = Join-Path $ConfDir "UserSettings.json"

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "  PicView 极简看图工具系统注册与体验自愈工具 (pwsh 7+)" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "📂 部署基准目录: 安装目录 [$InstallDir] | 配置目录 [$ConfDir]`n" -ForegroundColor Cyan

# 辅助函数：确保注册表项存在
function Ensure-Key {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

$imgExts = @(".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".ico", ".tiff", ".tif", ".avif", ".heic", ".svg", ".jxl")
$progId  = "PicView.Image"

# ==============================================================================
# 阶段 A: 清洁卸载与环境重置 (-Clean)
# ==============================================================================
if ($Clean) {
    Write-Host "🧹 [清洁重装模式] 正在清理 PicView 系统关联与配置..." -ForegroundColor Yellow

    # 1. 终止进程
    Get-Process -Name "PicView" -ErrorAction SilentlyContinue | Stop-Process -Force

    # 2. 清理系统关联注册表
    Remove-Item -Path "HKLM:\SOFTWARE\Classes\$progId" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\SOFTWARE\Classes\Applications\PicView.exe" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\SOFTWARE\PicView" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "PicView" -ErrorAction SilentlyContinue
    Write-Host "   - 已注销系统 ProgID、Capabilities 与 RegisteredApplications。" -ForegroundColor Gray

    # 3. 清理配置目录
    if (Test-Path $ConfDir) {
        Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理配置目录: $ConfDir" -ForegroundColor Gray
    }

    # 4. 卸载程序本体
    if (Test-Path $InstallDir) {
        if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
            Write-Host "   - 正在调用 Scoop 卸载客户端本体..." -ForegroundColor Gray
            & scoop uninstall picview 2>$null | Out-Null
        } else {
            Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "✅ [清洁完成] PicView 系统注册与本体已彻底清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 阶段 B: 只查不改体检巡检 (-CheckOnly / -Audit)
# ==============================================================================
if ($CheckOnly) {
    Write-Host "🔍 [只查不改模式] 正在对 PicView 看图工具与系统级偏好执行逐项巡检..." -ForegroundColor Cyan

    $chkList = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. 二进制安装
    $chkList.Add([PSCustomObject]@{
        "配置模块" = "客户端本体"
        "受控属性" = "二进制程序 (PicView.exe)"
        "期望基线" = "已安装于 Scoop 环境"
        "实机状态" = $isInstalled ? "已安装 ($pvExe)" : "未安装"
        "判定"     = $isInstalled ? "✔ 匹配" : "✘ 缺失"
    })

    # 2. 系统 RegisteredApplications 与 ProgID 注册
    $regApp = (Get-ItemProperty "HKLM:\SOFTWARE\RegisteredApplications" -Name "PicView" -ErrorAction SilentlyContinue).PicView
    if (-not $regApp) {
        $regApp = (Get-ItemProperty "HKCU:\Software\RegisteredApplications" -Name "PicView" -ErrorAction SilentlyContinue).PicView
    }
    $hasApp = (Test-Path "HKLM:\SOFTWARE\Classes\Applications\PicView.exe") -or (Test-Path "HKCU:\Software\Classes\Applications\PicView.exe")
    $hasProgId = Test-Path "HKLM:\SOFTWARE\Classes\$progId"
    $isRegistered = ($null -ne $regApp -and $hasApp -and $hasProgId)

    $chkList.Add([PSCustomObject]@{
        "配置模块" = "系统集成"
        "受控属性" = "系统全功能看图器注册 (Capabilities)"
        "期望基线" = "已注册并点亮默认应用"
        "实机状态" = $isRegistered ? "已注册 (RegisteredApplications)" : "未完整注册"
        "判定"     = $isRegistered ? "✔ 匹配" : "✘ 缺失"
    })

    # 3. UserSettings.json 体验基线偏好就绪度
    $hasConfig = $false
    $langVal = "缺失"
    $sameWinVal = "缺失"
    $escVal = "缺失"

    if (Test-Path $confFile) {
        try {
            $json = Get-Content -Path $confFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $langVal = $json.UIProperties.UserLanguage
            $sameWinVal = $json.UIProperties.OpenInSameWindow.ToString()
            $escVal = $json.UIProperties.ShowConfirmationOnEsc.ToString()

            $hasConfig = ($json.UIProperties.UserLanguage -eq "zh-CN" -and
                          $json.UIProperties.OpenInSameWindow -eq $true -and
                          $json.UIProperties.ShowConfirmationOnEsc -eq $false)
        } catch { }
    }

    $chkList.Add([PSCustomObject]@{
        "配置模块" = "偏好配置"
        "受控属性" = "界面语言 (UserLanguage)"
        "期望基线" = "zh-CN (简体中文)"
        "实机状态" = $langVal
        "判定"     = ($langVal -eq "zh-CN") ? "✔ 匹配" : "✘ 偏离"
    })

    $chkList.Add([PSCustomObject]@{
        "配置模块" = "偏好配置"
        "受控属性" = "单窗口复用 (OpenInSameWindow)"
        "期望基线" = "True (防多开霸屏)"
        "实机状态" = $sameWinVal
        "判定"     = ($sameWinVal -eq "True") ? "✔ 匹配" : "✘ 偏离"
    })

    $chkList.Add([PSCustomObject]@{
        "配置模块" = "偏好配置"
        "受控属性" = "ESC退出确认 (ShowConfirmationOnEsc)"
        "期望基线" = "False (直接退出)"
        "实机状态" = $escVal
        "判定"     = ($escVal -eq "False") ? "✔ 匹配" : "✘ 偏离"
    })

    Write-Host "`n📊 [巡检看板] PicView 受控属性基线审计清单:" -ForegroundColor Cyan
    $chkList | Format-Table -AutoSize | Out-String | Write-Host

    $driftCount = ($chkList | Where-Object { $_.判定 -like "✘*" }).Count
    if ($driftCount -eq 0) {
        Write-Host "🎉 状态完美！所有受控属性均与工程黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host "⚠️  共发现 $driftCount 项偏离或缺失。执行本脚本默认模式 (-Sync) 或纯配置重置 (-ConfigOnly) 即可自动对齐自愈。`n" -ForegroundColor Yellow
        if (-not $isInstalled) {
            Write-Host "💡 提示: 未检测到客户端安装，请先执行 'scoop install extras/picview' 安装本体。" -ForegroundColor Gray
        }
    }
    return
}

# ==============================================================================
# 前置门禁断言：验证是否已安装 (除 CheckOnly/Clean 外其余模式强制要求)
# ==============================================================================
if (-not $isInstalled) {
    if ($ConfigOnly) {
        throw "未检测到 PicView 客户端安装。本工具专注于系统注册与偏好加固，请先执行 'scoop install extras/picview' 安装后再执行配置。"
    }

    Write-Host "⚠️  未在 Scoop 路径检测到已安装的 PicView 看图工具。" -ForegroundColor Yellow
    if ($NonInteractive) {
        throw "非交互模式下检测到未安装 PicView，拒绝盲目静默安装。请先在交互环境中确认安装。"
    }

    $shouldInstall = Read-Host "是否立即调用 'scoop install extras/picview' 进行安装？(y/N)"
    if ($shouldInstall.Trim().ToLower() -eq 'y') {
        if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
            throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
        }
        Write-Host "🚀 正在通过 Scoop 安装 PicView..." -ForegroundColor Cyan
        & scoop bucket add extras 2>$null | Out-Null
        & scoop install extras/picview

        # 重新探测
        foreach ($root in $scoopRoots) {
            $cand = Join-Path $root "apps\picview\current"
            if (Test-Path (Join-Path $cand "PicView.exe")) {
                $InstallDir = $cand
                $pvExe = Join-Path $InstallDir "PicView.exe"
                $isInstalled = $true
                break
            }
        }
        if (-not $isInstalled) {
            throw "Scoop 安装完成，但未能定位到 $pvExe，请检查 Scoop 安装状态。"
        }
    } else {
        Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor Yellow
        return
    }
}

# ==============================================================================
# 阶段 C: 覆盖更新本体 (-InstallOnly)
# ==============================================================================
if ($InstallOnly) {
    Write-Host "📦 [覆盖升级模式] 正在调用 Scoop 升级 PicView 本体..." -ForegroundColor Cyan
    Get-Process -Name "PicView" -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        & scoop update picview
        Write-Host "✅ [升级完成] PicView 客户端本体已通过 Scoop 完成升级。`n" -ForegroundColor Green
    } else {
        throw "未检测到 scoop 命令，无法执行自动更新。"
    }
    return
}

# ==============================================================================
# 阶段 D: 增量对齐 (-Sync / 默认) 与 纯配置重置 (-ConfigOnly)
# ==============================================================================
Write-Host "⚙️  正在执行系统图像关联注册与 PicView 偏好配置对齐..." -ForegroundColor Cyan

# 1. 注册 ProgID 实体
$progIdKey = "HKLM:\SOFTWARE\Classes\$progId"
Ensure-Key $progIdKey
Set-ItemProperty -Path $progIdKey -Name "(default)" -Value "PicView Image File" -Force
Ensure-Key "$progIdKey\DefaultIcon"
Set-ItemProperty -Path "$progIdKey\DefaultIcon" -Name "(default)" -Value "`"$pvExe`",0" -Force
Ensure-Key "$progIdKey\shell\open\command"
Set-ItemProperty -Path "$progIdKey\shell\open\command" -Name "(default)" -Value "`"$pvExe`" `"%1`"" -Force

# 2. 注册 Applications\PicView.exe 支持类型
$appKey = "HKLM:\SOFTWARE\Classes\Applications\PicView.exe"
Ensure-Key "$appKey\shell\open\command"
Set-ItemProperty -Path "$appKey\shell\open\command" -Name "(default)" -Value "`"$pvExe`" `"%1`"" -Force
Ensure-Key "$appKey\SupportedTypes"
foreach ($ext in $imgExts) {
    Set-ItemProperty -Path "$appKey\SupportedTypes" -Name $ext -Value "" -Force
}

# 3. 注册系统 Capabilities 与 RegisteredApplications (在 Win11“设置 - 默认应用”中点亮 PicView)
$capKey = "HKLM:\SOFTWARE\PicView\Capabilities"
Ensure-Key $capKey
Set-ItemProperty -Path $capKey -Name "ApplicationName" -Value "PicView" -Force
Set-ItemProperty -Path $capKey -Name "ApplicationDescription" -Value "PicView Fast Image Viewer" -Force
Ensure-Key "$capKey\FileAssociations"
foreach ($ext in $imgExts) {
    Set-ItemProperty -Path "$capKey\FileAssociations" -Name $ext -Value $progId -Force
}

Ensure-Key "HKLM:\SOFTWARE\RegisteredApplications"
Set-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "PicView" -Value "SOFTWARE\PicView\Capabilities" -Force

# 4. 用户层 OpenWithProgids 快速透传
foreach ($ext in $imgExts) {
    $extKey = "HKCU:\Software\Classes\$ext\OpenWithProgids"
    Ensure-Key $extKey
    Set-ItemProperty -Path $extKey -Name $progId -Value ([byte[]]@()) -Force
}
Write-Host "✅ 系统全功能看图器注册与 13 种主流图片格式关联完成。" -ForegroundColor Green

# 5. 注入/调优 UserSettings.json 体验基线偏好 (增量保留客制字段)
if (-not (Test-Path $ConfDir)) {
    New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
}

$settings = if (Test-Path $confFile) {
    try { Get-Content -Path $confFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
} else { $null }

if (-not $settings) { $settings = [PSCustomObject]@{} }
if (-not $settings.UIProperties) { $settings | Add-Member -MemberType NoteProperty -Name "UIProperties" -Value ([PSCustomObject]@{}) -Force }
if (-not $settings.StartUp) { $settings | Add-Member -MemberType NoteProperty -Name "StartUp" -Value ([PSCustomObject]@{}) -Force }
if (-not $settings.ImageScaling) { $settings | Add-Member -MemberType NoteProperty -Name "ImageScaling" -Value ([PSCustomObject]@{}) -Force }
if (-not $settings.WindowProperties) { $settings | Add-Member -MemberType NoteProperty -Name "WindowProperties" -Value ([PSCustomObject]@{}) -Force }
if (-not $settings.Navigation) { $settings | Add-Member -MemberType NoteProperty -Name "Navigation" -Value ([PSCustomObject]@{}) -Force }

# 固化体验基线：简体中文、单窗口复用(防连续看图多开霸屏)、ESC 直接退出、循环看图
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
[System.IO.File]::WriteAllText($confFile, $jsonStr, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ UserSettings.json 体验基线偏好已原子落盘至: $confFile" -ForegroundColor Green

# ==============================================================================
# 尾部结报与手动引导清单
# ==============================================================================
Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  ✅ PicView 看图工具基线与系统注册管理完成！" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "   - 图像关联: 已注册 PicView.Image 与 Capabilities，支持 jpg/png/webp 等主流格式" -ForegroundColor Gray
Write-Host "   - 偏好基线: 固化简体中文、单窗口复用(OpenInSameWindow)、ESC 免确认极速退出" -ForegroundColor Gray
Write-Host "   - 窗口适应: 固化超大图自动适应窗口与窗口居中呈现" -ForegroundColor Gray

Write-Host "`n--------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📋 [手动收尾引导清单 (Manual Checklist)]" -ForegroundColor Cyan
Write-Host " 1. 设为默认: 在 Windows 11【设置 - 应用 - 默认应用】中将 PicView 设为照片查看器默认应用" -ForegroundColor Gray
Write-Host " 2. 双击测试: 在资源管理器中双击图片文件，确认以单窗口秒级拉起且界面呈现简体中文" -ForegroundColor Gray
Write-Host " 3. ESC 测试: 查看图片时轻按 'Esc' 键，确认直接关闭窗口且无二次弹窗打扰" -ForegroundColor Gray
Write-Host "--------------------------------------------------`n" -ForegroundColor DarkGray
