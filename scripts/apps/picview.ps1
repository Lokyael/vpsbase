#requires -Version 7.0
<#
.SYNOPSIS
    PicView 看图工具

.DESCRIPTION
    PicView 极简快速看图工具 (Windows) 系统图像关联注册与体验偏好基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 基于 Scoop 纳管的二进制本体 (D:\prog\scoop\apps\picview\current\PicView.exe)。
    3. 系统级图像关联与默认应用点亮：向注册表写入 ProgID (PicView.Image)、Capabilities 与 RegisteredApplications，在 Win11 设置中点亮 PicView，并注册 13 种主流图片格式。
    4. 现代化看图体验基线：注入 Config\UserSettings.json，固化简体中文界面、单窗口复用防多开霸屏、ESC 直接退出、循环看图与超大图自适应窗口。
    5. 终端矩阵呈现与决策交互统一委派内部辅助算子 _console.ps1 闭环承接。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐工程基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - Uninstall : 清洁卸载与注销系统图片关联 (默认保留用户持久化配置)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制调用 Scoop 重新安装/更新本体并全量重写配置。

.PARAMETER Purge
    配合 Uninstall 使用，连带深度物理粉碎配置与持久化目录 (包含 persist)。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\picview.ps1 -Action Check

    # 交互式检查并应用工程基线
    pwsh -File .\scripts\apps\picview.ps1

    # 强制重新部署覆盖本体并对齐基线
    pwsh -File .\scripts\apps\picview.ps1 -Force

    # 安全清洁卸载 (保留配置)
    pwsh -File .\scripts\apps\picview.ps1 -Action Uninstall

    # 深度粉碎卸载 (全抹除)
    pwsh -File .\scripts\apps\picview.ps1 -Action Uninstall -Purge
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall")]
    [string]$Action = "Sync",

    [switch]$Yes,
    [switch]$Force,
    [switch]$Purge
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

$console = Join-Path $PSScriptRoot "_console.ps1"
if (-not (Test-Path $console)) {
    throw "未在应用域定位到核心终端交互组件: _console.ps1，请确保仓库完整性！"
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

function Ensure-ScoopBucket {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BucketName,
        [string]$BucketRepo = ""
    )
    $bucketDir = Join-Path $scoopRoot "buckets\$BucketName"
    if (Test-Path $bucketDir) { return }

    $installedBuckets = @(& scoop bucket list 2>$null 3>$null | ForEach-Object {
        if ($_.Name) { $_.Name } else { ($_ -split '\s+')[0] }
    })
    if ($installedBuckets -contains $BucketName) { return }

    Write-Host "📦 正在添加 Scoop '$BucketName' bucket..." -ForegroundColor Cyan
    if ($BucketRepo) {
        & scoop bucket add $BucketName $BucketRepo
    } else {
        & scoop bucket add $BucketName
    }
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

# ==============================================================================
# 3. 独立流转分支：清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not (& $console -Task ConfirmUninstall -AppName $AppName -UserDataList $HighValueUserData -Yes:$Yes -Purge:$Purge)) {
        return
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

    if ($Purge) {
        if (Test-Path $ConfDir) { Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $PersistDir) { Remove-Item -Path $PersistDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "   - [已粉碎] 用户持久化配置与缓存数据。" -ForegroundColor Red
    } else {
        if (Test-Path $PersistDir) {
            Write-Host "   - [数据安全保护] 用户配置已安全保留在: $PersistDir" -ForegroundColor Green
        }
    }

    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        if (Test-Path (Join-Path $scoopRoot "apps\picview")) {
            if ($Purge) {
                & scoop uninstall -p picview
            } else {
                & scoop uninstall picview
            }
        }
    }
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`n✅ [清洁卸载完成] PicView 系统注册与本体已清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与受控属性比对 (Plan & Diff)
# ==============================================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 部署路径: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $InstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

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

$Specs = @(
    @{
        Module   = "客户端本体"
        Property = "主执行文件 (PicView.exe)"
        Expected = "已安装于 Scoop 环境"
        Actual   = if ($isInstalled) { "已安装于 Scoop 环境" } else { "未安装" }
        IsMatch  = $isInstalled
        Purpose  = "部署极简快速看图工具本体，支持超大图快速解包与丰富图像格式渲染"
        Impact   = "若未就绪将自动调用 Scoop 从 extras bucket 安装"
        Type     = "Binary"
    },
    @{
        Module   = "系统集成"
        Property = "全功能看图器注册 (Capabilities)"
        Expected = "已注册 (RegisteredApplications + ProgID)"
        Actual   = if ($isRegistered) { "已注册 (RegisteredApplications + ProgID)" } else { "未完整注册" }
        IsMatch  = $isRegistered
        Purpose  = "在注册表中注入 PicView.Image 与 Capabilities，支持 13 种主流图片格式关联"
        Impact   = "在 Windows 11 设置「默认应用」中点亮 PicView，允许一键设为默认图片查看器"
        Type     = "Integration"
    },
    @{
        Module   = "偏好配置"
        Property = "界面语言 (UIProperties.UserLanguage)"
        Expected = "zh-CN"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.UserLanguage"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.UserLanguage") -eq "zh-CN")
        Purpose  = "固化简体中文界面"
        Impact   = "界面所有按钮、提示与菜单以中文呈现"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Property = "单窗口复用 (UIProperties.OpenInSameWindow)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.OpenInSameWindow"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.OpenInSameWindow") -eq "True")
        Purpose  = "连续点击多张图片时在同一窗口中快速复用切换"
        Impact   = "杜绝连续双击多张图片导致桌面弹出数十个窗口霸屏卡顿"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Property = "ESC 免确认退出 (UIProperties.ShowConfirmationOnEsc)"
        Expected = "False"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.ShowConfirmationOnEsc"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.ShowConfirmationOnEsc") -eq "False")
        Purpose  = "按 ESC 键直接关闭看图窗口"
        Impact   = "退出时不再弹出「确认退出」询问对话框，提升看图流转效率"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Property = "标题栏显示完整路径 (UIProperties.ShowFullPathInTitleBar)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.ShowFullPathInTitleBar"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.ShowFullPathInTitleBar") -eq "True")
        Purpose  = "窗口标题栏直观呈现图片所在绝对磁盘路径"
        Impact   = "方便快速定位文件所在目录"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Property = "循环看图 (UIProperties.Looping)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.Looping"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.Looping") -eq "True")
        Purpose  = "翻页至当前目录最后一张图片时自动循环回第一张"
        Impact   = "看图翻页不中断"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Property = "启动时不自动打开上次文件 (StartUp.OpenLastFile)"
        Expected = "False"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "StartUp.OpenLastFile"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "StartUp.OpenLastFile") -eq "False")
        Purpose  = "每次冷启动或双击新图片时仅聚焦当前目标"
        Impact   = "避免打开查看器时闪现上次关闭时的历史图片"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Property = "超大图自适应窗口 (ImageScaling.ZoomToFit)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "ImageScaling.ZoomToFit"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "ImageScaling.ZoomToFit") -eq "True")
        Purpose  = "超过屏幕分辨率的超大高像素图片自动等比例缩放适应窗口"
        Impact   = "消除打开高分辨率相机原图时超出屏幕边界需拖动滚动条的问题"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Property = "窗口居中呈现 (WindowProperties.KeepCentered)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "WindowProperties.KeepCentered"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "WindowProperties.KeepCentered") -eq "True")
        Purpose  = "窗口每次打开始终保持屏幕居中呈现"
        Impact   = "窗口位置稳定一致，不出现边缘偏移"
        Type     = "Config"
    },
    @{
        Module   = "偏好配置"
        Property = "文件变动智能监视 (Navigation.IsFileWatcherEnabled)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "Navigation.IsFileWatcherEnabled"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "Navigation.IsFileWatcherEnabled") -eq "True")
        Purpose  = "当前目录下有新图片保存或删除时实时刷新图库"
        Impact   = "动态更新翻页队列，无需手动按 F5 刷新"
        Type     = "Config"
    }
)

# 委派 _console.ps1 渲染差异矩阵
& $console -Task RenderDiff -Specs $Specs

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate)
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

# 5.2 状态体检与门禁授权
$diffs = @($Specs | Where-Object { -not $_.IsMatch })

if (-not (& $console -Task ConfirmGate -Specs $diffs -Action $Action -Yes:$Yes)) {
    return
}

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体安装或强制重装
$needBinaryDeploy = (-not $isInstalled) -or $Force
if ($needBinaryDeploy) {
    if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
        throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
    }

    Ensure-ScoopBucket $ScoopBucket
    if ($Force -and $isInstalled) {
        Write-Host "`n📦 [强制重新部署] 正在重新安装/更新 PicView 本体..." -ForegroundColor Cyan
        & scoop install extras/picview --force
    } else {
        Write-Host "`n🚀 正在通过 Scoop 安装 PicView..." -ForegroundColor Cyan
        & scoop install extras/picview
    }

    if (Test-Path (Join-Path $InstallDir "PicView.exe")) {
        $AppExe = Join-Path $InstallDir "PicView.exe"
        $isInstalled = $true
    }
    if (-not $isInstalled) {
        throw "Scoop 安装完成，但未能定位到 $AppExe，请检查 Scoop 安装状态。"
    }
}

# 6.2 注册系统关联与 Capabilities
Write-Host "⚙️  正在执行系统图像关联注册与 Capabilities 点亮..." -ForegroundColor Cyan

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
Write-Host "✔ 系统全功能看图器注册与 13 种主流图片格式关联完成。" -ForegroundColor Green

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
Write-Host "✔ UserSettings.json 体验基线偏好已原子落盘。" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
$sw.Stop()
& $console -Task Summary -Duration $sw.Elapsed -AppliedCount $diffs.Count

$isDefaultPhoto = $false
try {
    $jpgChoice = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.jpg\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    if ($jpgChoice -eq $progId) { $isDefaultPhoto = $true }
} catch { }

if (-not $isDefaultPhoto) {
    Write-Host "📋 [手动收尾清单 (Actionable Handoff)]" -ForegroundColor Cyan
    Write-Host "   - 设为默认: 在系统【默认应用】中将 PicView 设为照片查看器默认应用`n" -ForegroundColor Yellow
}

return
