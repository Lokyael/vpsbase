#requires -Version 7.0
<#
.SYNOPSIS
    PicView 看图工具

.DESCRIPTION
    PicView 极简快速看图工具 (Windows) 偏好基线与生命周期配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 基于 Scoop 纳管的二进制本体 (D:\prog\scoop\apps\picview\current\PicView.exe)。本体生命周期与包集成由 Scoop 负责，脚本不自造系统 ProgID 与 RegisteredApplications。
    3. 现代化看图体验基线：注入 Config\UserSettings.json，固化简体中文界面、单窗口复用防多开霸屏、ESC 直接退出、循环看图与超大图自适应窗口。
    4. 卸载生命周期遵循“先判断、后调用、再清理”：先核验运行态与目标实例，由 Scoop 卸载本体并独立核验终态；确认 Absent 后定点清理声明残留与 persist 目录；不强杀进程，不补删目录。
    5. 终端矩阵呈现与决策交互统一委派内部辅助算子 _console.ps1 闭环承接。
    6. 仅在配置文件缺失时初始化；已有文件读取、解析或受控分组结构无效时停止，保留原文件。配置写入保留未受控字段值，重新格式化并移除注释。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐工程基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (只读比对受控属性 Diff)
    - Uninstall : 清洁卸载与清理声明残留 (退役本体并定点清理声明数据与 persist 目录)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\desktop\apps\picview.ps1 -Action Check

    # 交互式检查并应用工程基线
    pwsh -File .\desktop\apps\picview.ps1

    # 安全清洁卸载 (退役本体并清理声明残留)
    pwsh -File .\desktop\apps\picview.ps1 -Action Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall")]
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

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防配置污染，请直接在 [$consoleUser] 桌面会话中执行。"
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
$PersistDir   = Join-Path $scoopRoot "persist\$ScoopApp"
$ConfDir      = Join-Path $PersistDir "Config"
$ConfigFile   = Join-Path $ConfDir "UserSettings.json"

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

function Assert-AppStopped {
    if (Get-Process -ErrorAction Stop | Where-Object ProcessName -in @('PicView')) {
        throw 'PicView 仍在运行，请保存工作并自行退出后重新执行。'
    }
}

function Get-ScoopInstallRecord {
    param([string]$CurrentDir)
    foreach ($name in @('scoop-install.json', 'install.json')) {
        $path = Join-Path $CurrentDir $name
        if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) {
            $info = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
            if ($info -isnot [System.Management.Automation.PSCustomObject] -or
                ($null -ne $info.hold -and $info.hold -isnot [bool])) {
                throw "Scoop 安装记录格式无效: $path"
            }
            return [PSCustomObject]@{
                Path = $path
                Held = $info.hold -eq $true
                LastWriteTimeUtc = (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTimeUtc
            }
        }
    }
    if (Test-Path -LiteralPath (Split-Path $CurrentDir -Parent) -ErrorAction Stop) {
        throw "Scoop 应用目录存在但当前安装记录缺失，请先通过 Scoop 检查安装状态: $CurrentDir"
    }
    return $null
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
    $global:LASTEXITCODE = $null
    if ($BucketRepo) {
        & scoop bucket add $BucketName $BucketRepo
    } else {
        & scoop bucket add $BucketName
    }
    $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "添加 Scoop bucket '$BucketName' 失败 (退出代码 $exitCode)，请检查网络连接与仓库地址。"
    }
}

function Get-PicViewSettings {
    param([string]$FilePath)
    try {
        $content = [IO.File]::ReadAllText($FilePath, [Text.Encoding]::UTF8)
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        return [PSCustomObject]@{}
    }
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'PicView 配置内容为空，拒绝覆盖。' }
    $settings = ConvertFrom-Json -InputObject $content -NoEnumerate -Depth 100 -ErrorAction Stop
    if ($settings -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'PicView 配置根结构必须为 JSON 对象，拒绝覆盖。'
    }
    foreach ($group in @('UIProperties', 'StartUp', 'ImageScaling', 'WindowProperties', 'Navigation')) {
        if ($null -ne $settings.$group -and $settings.$group -isnot [System.Management.Automation.PSCustomObject]) {
            throw "PicView 配置分组 [$group] 必须为 JSON 对象或 null，拒绝覆盖。"
        }
    }
    return $settings
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
    Assert-AppStopped

    $appRoot = Join-Path $scoopRoot "apps\$ScoopApp"
    $record = Get-ScoopInstallRecord -CurrentDir $InstallDir
    $hasExe = Test-Path -LiteralPath $AppExe -PathType Leaf
    if ($record -and -not $hasExe) {
        throw "PicView Scoop 安装记录存在但核心执行文件缺失 (Broken 状态)；已阻断清理，请通过 Scoop 修复或排查。"
    }
    if (-not $record -and $hasExe) {
        throw "PicView 核心执行文件存在但 Scoop 安装记录缺失 (Conflict 状态)；已阻断清理，请检查安装渠道与实例。"
    }
    $isInstalled = ($null -ne $record) -and $hasExe

    if (-not (& $console -Task ConfirmUninstall -AppName $AppName -UserDataList $HighValueUserData -Yes:$Yes)) {
        return
    }

    Assert-AppStopped

    if ($isInstalled) {
        Write-Host "`n🧹 [清洁卸载] 正在调用 Scoop 退役 PicView 本体..." -ForegroundColor Yellow
        if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
            throw "未检测到 scoop 命令，无法执行本体卸载；请先就绪 Scoop 环境。"
        }

        $global:LASTEXITCODE = $null
        & scoop uninstall picview
        $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw "Scoop 卸载 PicView 失败 (退出代码 $exitCode)；未清理声明残留与持久化数据。"
        }

        $afterRecord = Get-ScoopInstallRecord -CurrentDir $InstallDir
        $afterExe = Test-Path -LiteralPath $AppExe -PathType Leaf
        if ($afterRecord -or $afterExe) {
            throw "Scoop 卸载命令已执行，但 PicView 安装记录或核心执行文件仍存在；请检查 Scoop 状态。"
        }
        Write-Host "✔ PicView 本体已由 Scoop 安全卸载。" -ForegroundColor Green
    } else {
        Write-Host "`nℹ️  未检测到活动的 PicView Scoop 安装实例，跳过包管理器卸载。" -ForegroundColor Gray
    }

    # 终态核验后：定点清理声明的历史残留对象（快捷方式及历史自建关联）
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

    # 默认清洁卸载：受控配置与持久化目录随软件退役清理
    if (Test-Path -LiteralPath $PersistDir) {
        $persistItem = Get-Item -LiteralPath $PersistDir -Force -ErrorAction Stop
        if ($persistItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "PicView persist 目录为重解析点，拒绝递归删除: $PersistDir"
        }
        Remove-Item -LiteralPath $PersistDir -Recurse -Force -ErrorAction Stop
        Write-Host "   - [已清理] 声明的持久化配置与缓存数据: $PersistDir" -ForegroundColor Red
    }

    Write-Host "`n✅ [清洁卸载完成] PicView 本体已退役，声明残留已审计清理。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与受控属性比对 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 部署路径: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $InstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$isInstalled = Test-Path $AppExe
$settingsJson = Get-PicViewSettings -FilePath $ConfigFile

$Specs = @(
    @{
        Module   = "本体"
        Property = "主执行文件 (PicView.exe)"
        Expected = "已安装于 Scoop 环境"
        Actual   = if ($isInstalled) { "已安装于 Scoop 环境" } else { "未安装" }
        IsMatch  = $isInstalled
        Purpose  = "部署极简快速看图工具本体，支持超大图快速解包与丰富图像格式渲染"
        Impact   = "若未就绪将自动调用 Scoop 从 extras bucket 安装"
        Type     = "Binary"
    },
    @{
        Module   = "配置"
        Property = "界面语言 (UIProperties.UserLanguage)"
        Expected = "zh-CN"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.UserLanguage"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.UserLanguage") -eq "zh-CN")
        Purpose  = "固化简体中文界面"
        Impact   = "界面所有按钮、提示与菜单以中文呈现"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Property = "单窗口复用 (UIProperties.OpenInSameWindow)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.OpenInSameWindow"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.OpenInSameWindow") -eq "True")
        Purpose  = "连续点击多张图片时在同一窗口中快速复用切换"
        Impact   = "避免连续双击多张图片导致桌面弹出多个窗口卡顿"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Property = "ESC 免确认退出 (UIProperties.ShowConfirmationOnEsc)"
        Expected = "False"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.ShowConfirmationOnEsc"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.ShowConfirmationOnEsc") -eq "False")
        Purpose  = "按 ESC 键直接关闭看图窗口"
        Impact   = "退出时不再弹出「确认退出」询问对话框，提升看图流转效率"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Property = "标题栏显示完整路径 (UIProperties.ShowFullPathInTitleBar)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.ShowFullPathInTitleBar"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.ShowFullPathInTitleBar") -eq "True")
        Purpose  = "窗口标题栏直观呈现图片所在绝对磁盘路径"
        Impact   = "方便快速定位文件所在目录"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Property = "循环看图 (UIProperties.Looping)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "UIProperties.Looping"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "UIProperties.Looping") -eq "True")
        Purpose  = "翻页至当前目录最后一张图片时自动循环回第一张"
        Impact   = "看图翻页不中断"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Property = "启动时不自动打开上次文件 (StartUp.OpenLastFile)"
        Expected = "False"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "StartUp.OpenLastFile"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "StartUp.OpenLastFile") -eq "False")
        Purpose  = "每次冷启动或双击新图片时仅聚焦当前目标"
        Impact   = "避免打开查看器时闪现上次关闭时的历史图片"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Property = "超大图自适应窗口 (ImageScaling.ZoomToFit)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "ImageScaling.ZoomToFit"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "ImageScaling.ZoomToFit") -eq "True")
        Purpose  = "超过屏幕分辨率的超大高像素图片自动等比例缩放适应窗口"
        Impact   = "消除打开高分辨率相机原图时超出屏幕边界需拖动滚动条的问题"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Property = "窗口居中呈现 (WindowProperties.KeepCentered)"
        Expected = "True"
        Actual   = $( $v = Get-JsonValueByPath $settingsJson "WindowProperties.KeepCentered"; if ($null -eq $v) { "<缺省未设>" } else { "$v" } )
        IsMatch  = ((Get-JsonValueByPath $settingsJson "WindowProperties.KeepCentered") -eq "True")
        Purpose  = "窗口每次打开始终保持屏幕居中呈现"
        Impact   = "窗口位置稳定一致，不出现边缘偏移"
        Type     = "Config"
    },
    @{
        Module   = "配置"
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

# 5.1 状态体检与合规性判定
$diffs = @($Specs | Where-Object { -not $_.IsMatch })

if ($Action -eq "Check") {
    if ($diffs.Count -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性与偏好均与工程基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $diffs.Count) -ForegroundColor Yellow
    }
    return
}

if ($diffs.Count -eq 0 -and $isInstalled) {
    Write-Host "✨ [状态合规] 所有受控属性均已符合工程基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# 5.2 运行态并发防覆写硬门禁
Assert-AppStopped

# 5.3 门禁授权放行
if (-not (& $console -Task ConfirmGate -Specs $diffs -Action $Action -Yes:$Yes -AppName $AppName)) {
    return
}

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体安装或强制重装
Assert-AppStopped
$needBinaryDeploy = (-not $isInstalled)
if ($needBinaryDeploy) {
    if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
        throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
    }

    $beforeInstall = Get-ScoopInstallRecord -CurrentDir $InstallDir
    if ($beforeInstall -and $beforeInstall.Held) {
        throw "Scoop 应用 picview 已 hold，未执行部署；如需更新，请先自行执行 scoop unhold picview。"
    }
    Ensure-ScoopBucket $ScoopBucket
    $scoopArgs = if ($beforeInstall) { @('update', $ScoopApp, '--force') } else { @('install', "$ScoopBucket/$ScoopApp") }
    $global:LASTEXITCODE = $null
    & scoop @scoopArgs
    $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Scoop 部署 $ScoopApp 失败 (退出代码 $exitCode)，未继续写入配置。"
    }
    $afterInstall = Get-ScoopInstallRecord -CurrentDir $InstallDir
    if (-not $afterInstall -or ($beforeInstall -and $afterInstall.Path -eq $beforeInstall.Path -and
        $afterInstall.LastWriteTimeUtc -eq $beforeInstall.LastWriteTimeUtc)) {
        throw "Scoop 未生成或刷新 $ScoopApp 安装记录，无法确认部署完成；请检查 Scoop 的跳过或错误输出。"
    }
    $AppExe = Join-Path $InstallDir 'PicView.exe'
    $isInstalled = Test-Path -LiteralPath $AppExe -PathType Leaf
    if (-not $isInstalled) {
        throw "Scoop 安装完成，但未能定位到 $AppExe，请检查 Scoop 安装状态。"
    }
}

# 6.2 注入/调优 UserSettings.json 体验基线偏好
Assert-AppStopped
$settings = Get-PicViewSettings -FilePath $ConfigFile
Ensure-Dir $ConfDir

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

$jsonStr = $settings | ConvertTo-Json -Depth 100 -WarningAction Stop -ErrorAction Stop
[System.IO.File]::WriteAllText($ConfigFile, $jsonStr, [System.Text.UTF8Encoding]::new($false))
Write-Host "✔ UserSettings.json 体验基线偏好已写入。" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与偏好管理完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green

$isDefaultPhoto = $false
try {
    $jpgChoice = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.jpg\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    if ($jpgChoice -eq $progId) { $isDefaultPhoto = $true }
} catch { }

if (-not $isDefaultPhoto) {
    Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData '如需默认使用 PicView，请在 Windows 设置 → 应用 → 默认应用中将其设为照片查看器。'
}

return
