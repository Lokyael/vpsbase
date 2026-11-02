#requires -Version 7.0
<#
.SYNOPSIS
    Zed i18n 编辑器

.DESCRIPTION
    LI-NA/zed-i18n 社区汉化编辑器 (Windows) 工程基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 仅通过 Scoop zed-i18n/zed-i18n 纳管本体 (D:\prog\scoop\apps\zed-i18n\current\Zed.exe)，不自动迁移或卸载旧 ZedG。
    3. 注入 %APPDATA%\Zed\settings.json 工程基线配置：固化工作站等宽字体基线 (Maple Mono NL NFMono CN)、关闭代码连字、规范 2 空格缩进、自动软折行与空白字符显示、优先 POSIX 换行 (line_ending=prefer_lf)、失焦自动保存与原生遥测切断。
    4. 中文界面 ui_locale=zh-CN，关闭内置更新，由 Scoop 更新。卸载仅退役本体并核验终态，保留共享 Zed 用户目录与未知 persist 数据；不强杀进程、不补删目录。
    5. 使用原生 JSONC 解析与字段级合并保留未受控配置值；已有文件读取或解析失败时停止，不覆盖为默认配置。落盘会重新格式化并移除注释。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (只读比对受控属性 Diff)
    - Uninstall : 退役 Zed i18n 本体，保留共享 Zed 设置、扩展、数据库与会话

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\desktop\apps\zed-i18n.ps1 -Action Check

    # 交互式检查并应用工程基线
    pwsh -File .\desktop\apps\zed-i18n.ps1

    # 卸载本体，保留共享用户数据
    pwsh -File .\desktop\apps\zed-i18n.ps1 -Action Uninstall
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
$AppId        = "zed-i18n"
$AppName      = "Zed i18n 代码编辑器"
$ScoopBucket  = "zed-i18n"
$ScoopApp     = "zed-i18n"

$scoopRoot    = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
$InstallDir   = Join-Path $scoopRoot "apps\$ScoopApp\current"
$AppExe       = Join-Path $InstallDir "Zed.exe"
$ConfDir      = Join-Path $env:APPDATA "Zed"
$ConfigFile   = Join-Path $ConfDir "settings.json"
$GlobalConfigFile = Join-Path $ConfDir "global_settings.json"

# ConfirmUninstall 的列表表示将清理的数据；共享用户数据不属于本体卸载范围。
$HighValueUserData = @()
$UninstallExtraMessage = '仅卸载 Zed i18n 本体；保留共享 Zed 设置、扩展、数据库、会话与 persist 数据，不卸载旧 ZedG。'

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Assert-AppStopped {
    if (Get-Process -ErrorAction Stop | Where-Object ProcessName -in @('Zed', 'ZedG')) {
        throw 'Zed / ZedG 仍在运行，请保存文件并自行退出后重新执行。'
    }
}

function Get-ScoopInstallRecord {
    param(
        [string]$CurrentDir,
        [switch]$AllowMissingRecord
    )
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
    if (-not $AllowMissingRecord -and (Test-Path -LiteralPath (Split-Path $CurrentDir -Parent) -ErrorAction Stop)) {
        throw "Scoop 应用目录存在但当前安装记录缺失，请先通过 Scoop 检查安装状态: $CurrentDir"
    }
    return $null
}

function Get-ZedInstallState {
    param(
        [Parameter(Mandatory = $true)] [string]$CurrentDir,
        [Parameter(Mandatory = $true)] [string]$AppPath
    )
    $appRoot = Split-Path -Path $CurrentDir -Parent
    $record = Get-ScoopInstallRecord -CurrentDir $CurrentDir -AllowMissingRecord
    $hasExe = Test-Path -LiteralPath $AppPath -PathType Leaf -ErrorAction Stop
    $hasAppRoot = Test-Path -LiteralPath $appRoot -PathType Container -ErrorAction Stop
    $state = if ($record -and $hasExe) { 'Present' }
        elseif ($record -and -not $hasExe) { 'Broken' }
        elseif ($hasExe -or $hasAppRoot) { 'Conflict' }
        else { 'Absent' }
    [PSCustomObject]@{
        State = $state
        Record = $record
        HasExe = $hasExe
        AppRoot = $appRoot
    }
}

function Ensure-ScoopBucket {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BucketName,
        [string]$BucketRepo = ""
    )
    $bucketDir = Join-Path $scoopRoot "buckets\$BucketName"
    if (-not (Test-Path -LiteralPath $bucketDir)) {
        Write-Host "📦 正在添加 Scoop '$BucketName' bucket..." -ForegroundColor Cyan
        $global:LASTEXITCODE = $null
        & scoop bucket add $BucketName $BucketRepo
        $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw "添加 Scoop bucket '$BucketName' 失败 (退出代码 $exitCode)。"
        }
    }
    $global:LASTEXITCODE = $null
    $origin = @(& git -C $bucketDir remote get-url origin)
    $gitExit = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
    if ($gitExit -ne 0 -or $origin.Count -ne 1 -or
        $origin[0] -cnotin @($BucketRepo, "$BucketRepo.git")) {
        throw "Scoop bucket '$BucketName' 来源不匹配或无法读取；必须为 $BucketRepo，未自动更换来源。"
    }
}

function ConvertFrom-Jsonc {
    param([string]$JsoncText)
    if ([string]::IsNullOrWhiteSpace($JsoncText)) { throw 'Zed 配置内容为空，拒绝覆盖。' }
    $settings = ConvertFrom-Json -InputObject $JsoncText -NoEnumerate -Depth 100 -ErrorAction Stop
    if ($settings -isnot [System.Management.Automation.PSCustomObject]) { throw 'Zed 配置根结构必须为 JSON 对象，拒绝覆盖。' }
    return $settings
}

function Get-ZedSettings {
    param([string]$FilePath)
    try {
        $content = [IO.File]::ReadAllText($FilePath, [Text.Encoding]::UTF8)
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        return [PSCustomObject]@{}
    }
    return ConvertFrom-Jsonc -JsoncText $content
}

$ManagedSpecs = @(
    @{
        Property = "简体中文界面 (ui_locale)"
        Path     = "ui_locale"
        Expected = "zh-CN"
        Purpose  = "固定 Zed i18n 显示语言，不随系统语言变化"
        Impact   = "使用社区中文翻译，部分动态文案可能仍为英文"
    },
    @{
        Property = "关闭内置更新 (auto_update)"
        Path     = "auto_update"
        Expected = "False"
        Purpose  = "仅使用 Scoop 更新本体"
        Impact   = "日常更新执行 scoop update zed-i18n，避免原生更新器另装实例"
    },
    @{
        Property = "代码主等宽字体 (buffer_font_family)"
        Path     = "buffer_font_family"
        Expected = "Maple Mono NL NFMono CN"
        Purpose  = "固化工作站等宽字体 (Maple Mono NL NFMono CN)"
        Impact   = "提供清晰高辨识度的中英文代码等宽排版，避免字形变形"
    },
    @{
        Property = "代码字号 (buffer_font_size)"
        Path     = "buffer_font_size"
        Expected = "14"
        Purpose  = "规范代码编辑区标准文字字号为 14pt"
        Impact   = "保障高分屏下代码视效舒适度"
    },
    @{
        Property = "关闭代码连字 (buffer_font_features.calt)"
        Path     = "buffer_font_features.calt"
        Expected = "False"
        Purpose  = "关闭代码连字特性，保持符号原始独立形态"
        Impact   = "避免 !=、=> 等运算符连体混淆，提升代码阅读与排错精度"
    },
    @{
        Property = "UI 界面字号 (ui_font_size)"
        Path     = "ui_font_size"
        Expected = "16"
        Purpose  = "提升侧边栏与菜单 UI 控件字号至 16pt"
        Impact   = "提升文件目录树与面板文字可读性"
    },
    @{
        Property = "光标样式 (cursor_shape)"
        Path     = "cursor_shape"
        Expected = "bar"
        Purpose  = "固化竖线垂直光标样式"
        Impact   = "对齐现代编辑器标准光标交互手感"
    },
    @{
        Property = "光标闪烁 (cursor_blink)"
        Path     = "cursor_blink"
        Expected = "True"
        Purpose  = "保持编辑区光标闪烁"
        Impact   = "避免静态光标降低编辑位置的可见性"
    },
    @{
        Property = "Tab 制表符宽度 (tab_size = 2)"
        Path     = "tab_size"
        Expected = "2"
        Purpose  = "统一代码缩进宽度为标准 2 空格"
        Impact   = "对齐现代前端与云原生工程代码缩进风格"
    },
    @{
        Property = "软空格缩进 (hard_tabs = false)"
        Path     = "hard_tabs"
        Expected = "False"
        Purpose  = "禁止在代码中插入硬制表符 \t"
        Impact   = "按 Tab 键自动展开为 2 个真实空格字符"
    },
    @{
        Property = "自动软折行 (soft_wrap)"
        Path     = "soft_wrap"
        Expected = "editor_width"
        Purpose  = "超出编辑器视口宽度的长文本自动折行"
        Impact   = "消除水平横向滚动条，按当前窗口边缘动态折行显示"
    },
    @{
        Property = "显示空白与换行符 (show_whitespaces)"
        Path     = "show_whitespaces"
        Expected = "all"
        Purpose  = "在编辑区显式渲染空格、制表符及换行标记"
        Impact   = "增强代码缩进与不可见字符的可视化排查能力"
    },
    @{
        Property = "优先 POSIX LF 换行 (line_ending = prefer_lf)"
        Path     = "line_ending"
        Expected = "prefer_lf"
        Purpose  = "新文件与保存时优先采用 POSIX 标准 LF (\n) 换行符"
        Impact   = "减少跨平台 Git 提交时的 CRLF 换行混用"
    },
    @{
        Property = "保存末尾换行 (ensure_final_newline_on_save)"
        Path     = "ensure_final_newline_on_save"
        Expected = "True"
        Purpose  = "保存文件时确保文件末尾包含单个终结换行符"
        Impact   = "符合 POSIX 文件规范，避免代码差异比对末尾报错"
    },
    @{
        Property = "失焦即时自动保存 (autosave = on_focus_change)"
        Path     = "autosave"
        Expected = "on_focus_change"
        Purpose  = "切换文件或编辑器失去焦点时自动静默保存"
        Impact   = "免除频繁手动按 Ctrl+S，降低代码丢失风险"
    },
    @{
        Property = "切断崩溃与使用遥测 (telemetry.diagnostics)"
        Path     = "telemetry.diagnostics"
        Expected = "False"
        Purpose  = "禁用 Zed 后台使用数据与崩溃报告上传"
        Impact   = "关闭对应遥测上传，不阻断更新、扩展或语言服务联网"
    },
    @{
        Property = "切断匿名性能指标 (telemetry.metrics)"
        Path     = "telemetry.metrics"
        Expected = "False"
        Purpose  = "关闭匿名指标数据收集"
        Impact   = "消除遥测网络开销"
    }
)

# ==============================================================================
# 3. 独立流转分支：清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    Assert-AppStopped

    $installState = Get-ZedInstallState -CurrentDir $InstallDir -AppPath $AppExe
    if ($installState.State -eq 'Broken') {
        throw "Zed i18n Scoop 安装记录存在但核心执行文件缺失 (Broken 状态)；已阻断卸载，请通过 Scoop 修复或排查。"
    }
    if ($installState.State -eq 'Conflict') {
        throw "Zed i18n 安装记录、应用目录与核心执行文件不一致 (Conflict 状态)；已阻断卸载，请检查安装渠道与实例。"
    }
    $isInstalled = $installState.State -eq 'Present'

    Write-Host $UninstallExtraMessage -ForegroundColor Yellow
    if (-not (& $console -Task ConfirmUninstall -AppName $AppName -UserDataList $HighValueUserData -Yes:$Yes)) {
        return
    }

    Assert-AppStopped

    if ($isInstalled) {
        Write-Host "`n🧹 正在调用 Scoop 退役 Zed i18n 本体（保留共享用户数据）..." -ForegroundColor Yellow
        if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
            throw "未检测到 scoop 命令，无法执行本体卸载；请先就绪 Scoop 环境。"
        }

        $global:LASTEXITCODE = $null
        & scoop uninstall $ScoopApp
        $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw "Scoop 卸载 Zed i18n 失败 (退出代码 $exitCode)；未删除用户数据。"
        }

        $afterRecord = Get-ScoopInstallRecord -CurrentDir $InstallDir -AllowMissingRecord
        $afterExe = Test-Path -LiteralPath $AppExe -PathType Leaf
        if ($afterRecord -or $afterExe) {
            throw "Scoop 卸载命令已执行，但 Zed i18n 安装记录或核心执行文件仍存在；请检查 Scoop 状态。"
        }
        Write-Host "✔ Zed i18n 本体已由 Scoop 卸载。" -ForegroundColor Green
    } else {
        Write-Host "`nℹ️  未检测到活动的 Zed i18n Scoop 安装实例，跳过包管理器卸载。" -ForegroundColor Gray
    }

    Write-Host "`n✅ Zed i18n 本体已退役；共享用户目录、persist 与旧 ZedG 均保持原状。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 部署路径: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $InstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$installState = Get-ZedInstallState -CurrentDir $InstallDir -AppPath $AppExe
$isInstalled = $installState.State -eq 'Present'
$existingSettings = Get-ZedSettings -FilePath $ConfigFile
# Scoop post_install 会重写此共享文件；先校验，不将损坏内容交给 hook。
$null = Get-ZedSettings -FilePath $GlobalConfigFile

function Get-ZedConfigValue($obj, [string]$path) {
    if ($null -eq $obj) { return $null }
    $parts = $path.Split('.')
    $curr = $obj
    foreach ($p in $parts) {
        if ($null -eq $curr -or -not ($curr.PSObject.Properties.Match($p).Count)) {
            return $null
        }
        $curr = $curr.$p
    }
    return $curr
}

$binaryActual = switch ($installState.State) {
    'Present' { '已安装于 Scoop 环境' }
    'Absent' { '未安装' }
    'Broken' { '安装记录存在但核心文件缺失 (Broken)' }
    'Conflict' { '安装记录与核心文件不一致 (Conflict)' }
    default { "未知 ($($installState.State))" }
}
$Specs = @(
    [PSCustomObject]@{
        Module   = "本体"
        Property = "主执行文件 (Zed.exe)"
        Expected = "已安装于 Scoop 环境"
        Actual   = $binaryActual
        IsMatch  = ($installState.State -eq 'Present')
        Purpose  = "部署 LI-NA/zed-i18n 社区编辑器本体"
        Impact   = "通过 zed-i18n bucket 安装；未签名构建，Scoop hook 会重写共享 global_settings.json 的更新设置"
        Type     = "Binary"
    }
)

foreach ($item in $ManagedSpecs) {
    $actual = Get-ZedConfigValue $existingSettings $item.Path
    $actualStr = if ($null -eq $actual) { "<缺省未设>" } else { "$actual" }
    $expectedStr = "$($item.Expected)"
    $expectedValue = if ($expectedStr -eq 'True') { $true }
        elseif ($expectedStr -eq 'False') { $false }
        elseif ($expectedStr -match '^\d+$') { [int]$expectedStr }
        else { $expectedStr }
    $matched = if ($null -eq $actual) { $false }
        elseif ($expectedValue -is [bool]) { $actual -is [bool] -and $actual -eq $expectedValue }
        elseif ($expectedValue -is [int]) {
            (($actual -is [byte]) -or ($actual -is [int16]) -or ($actual -is [int32]) -or ($actual -is [int64])) -and [long]$actual -eq [long]$expectedValue
        } elseif ($expectedValue -is [string]) { $actual -is [string] -and $actual -ceq $expectedValue }
        else { $false }

    $Specs += [PSCustomObject]@{
        Module   = "配置"
        Property = $item.Property
        Expected = $expectedStr
        Actual   = $actualStr
        IsMatch  = $matched
        Purpose  = $item.Purpose
        Impact   = $item.Impact
        Type     = "Config"
    }
}

# 委派 _console.ps1 渲染差异矩阵
& $console -Task RenderDiff -Specs $Specs

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate)
# ==============================================================================

# 5.1 状态体检与合规性判定
$diffs = @($Specs | Where-Object { -not $_.IsMatch })

if ($Action -eq "Check") {
    if ($diffs.Count -eq 0 -and $installState.State -eq 'Present') {
        Write-Host "✨ [状态合规] 所有受控属性与工程基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        $stateHint = if ($installState.State -ne 'Present') { "；本体状态: $($installState.State)" } else { '' }
        Write-Host ("⚠️  共发现 {0} 项基线偏离{1}。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $diffs.Count, $stateHint) -ForegroundColor Yellow
    }
    return
}

if ($installState.State -eq 'Conflict') {
    throw "Zed i18n 本体状态为 Conflict，已阻断 Sync；请先通过 Scoop 检查或修复安装状态。"
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

$needBinaryDeploy = (-not $isInstalled)

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体安装或覆盖升级
Assert-AppStopped
if ($needBinaryDeploy) {
    if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
        throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
    }

    $beforeInstall = Get-ScoopInstallRecord -CurrentDir $InstallDir
    if ($beforeInstall -and $beforeInstall.Held) {
        throw "Scoop 应用 zed-i18n 已 hold，未执行部署；如需更新，请先自行执行 scoop unhold zed-i18n。"
    }
    $null = Get-ZedSettings -FilePath $GlobalConfigFile
    Ensure-ScoopBucket $ScoopBucket "https://github.com/LI-NA/scoop-zed-i18n"
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
    $isInstalled = $false
    $AppExe = Join-Path $InstallDir "Zed.exe"
    $isInstalled = Test-Path -LiteralPath $AppExe -PathType Leaf
    if (-not $isInstalled) {
        throw "Scoop 安装完成，但未能定位到 $AppExe，请检查 Scoop 安装状态。"
    }
}

# 6.2 增量合并并写入 settings.json
Assert-AppStopped
Write-Host "`n⚙️  正在执行 settings.json 体验基线偏好对齐..." -ForegroundColor Cyan
$targetJsonObj = Get-ZedSettings -FilePath $ConfigFile
Ensure-Dir $ConfDir

function Set-NestedProperty($obj, [string]$path, $val) {
    $parts = $path.Split('.')
    $curr = $obj
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if ($null -eq $curr -or $curr -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Zed 配置路径 [$path] 的父节点不是 JSON 对象，拒绝覆盖。"
        }
        $part = $parts[$i]
        $property = $curr.PSObject.Properties[$part]
        if ($null -eq $property) {
            $curr | Add-Member -MemberType NoteProperty -Name $part -Value ([PSCustomObject]@{}) -Force
        } elseif ($null -eq $property.Value -or $property.Value -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Zed 配置路径 [$path] 的父节点不是 JSON 对象，拒绝覆盖。"
        }
        $curr = $curr.$part
    }
    $typedVal = if ($val -eq "True") { $true } elseif ($val -eq "False") { $false } elseif ($val -match '^\d+$') { [int]$val } else { $val }
    if ($curr -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Zed 配置路径 [$path] 的目标父节点不是 JSON 对象，拒绝覆盖。"
    }
    $property = $curr.PSObject.Properties[$parts[-1]]
    $typeMismatch = $null -ne $property -and (
        ($typedVal -is [bool] -and $property.Value -isnot [bool]) -or
        ($typedVal -is [int] -and $property.Value -isnot [byte] -and $property.Value -isnot [int16] -and $property.Value -isnot [int32] -and $property.Value -isnot [int64]) -or
        ($typedVal -is [string] -and $property.Value -isnot [string]))
    if ($null -eq $property -or $property.Value -cne $typedVal -or $typeMismatch) {
        $curr | Add-Member -MemberType NoteProperty -Name $parts[-1] -Value $typedVal -Force
    }
}

foreach ($item in $ManagedSpecs) {
    Set-NestedProperty -obj $targetJsonObj -path $item.Path -val $item.Expected
}

$finalJson = $targetJsonObj | ConvertTo-Json -Depth 100 -WarningAction Stop -ErrorAction Stop
$settingsParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigFile))
$temporarySettings = Join-Path $settingsParent ('.settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [System.IO.File]::WriteAllText($temporarySettings, $finalJson, [System.Text.UTF8Encoding]::new($false))
    $null = Get-ZedSettings -FilePath $temporarySettings
    [System.IO.File]::Move($temporarySettings, $ConfigFile, $true)
    $null = Get-ZedSettings -FilePath $ConfigFile
} finally {
    if ([System.IO.File]::Exists($temporarySettings)) { [System.IO.File]::Delete($temporarySettings) }
}
Write-Host "✅ settings.json 工程基线已写入: $ConfigFile" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与配置管理完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 字体基线: 已注入 Maple Mono NL NFMono CN 并关闭代码连字" -ForegroundColor Gray
Write-Host "   - 编辑基线: 固化 2 空格缩进、自动软折行、空白符显示、失焦即时保存与 prefer_lf 换行格式" -ForegroundColor Gray
Write-Host "   - 中文与更新: zh-CN；关闭内置更新，使用 scoop update zed-i18n" -ForegroundColor Gray
Write-Host "   - 隐私: 已关闭对应遥测选项，不代表其他网络活动已阻断" -ForegroundColor Gray

return
