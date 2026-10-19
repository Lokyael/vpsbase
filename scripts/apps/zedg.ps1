#requires -Version 7.0
<#
.SYNOPSIS
    ZedG 编辑器

.DESCRIPTION
    ZedG (Zed Globalization) 汉化版现代高性能代码编辑器 (Windows) 工程基线配置与字体注入工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 基于 Scoop 纳管的二进制本体 (D:\prog\scoop\apps\zedg\current\ZedG.exe)。
    3. 注入 %APPDATA%\Zed\settings.json 工程基线配置：固化工作站等宽字体基线 (Maple Mono NL NFMono CN)、关闭代码连字、规范 2 空格缩进、自动软折行与空白字符显示、规范 POSIX 换行 (prefer_lf)、失焦自动保存、pwsh 终端集成与原生遥测切断。
    4. 采用无破坏增量合并机制纳管 settings.json：原生兼容 JSONC 注释与尾随逗号，完整保留用户自定义主题、插件与客制配置。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - Uninstall : 清洁卸载 ZedG (默认保留用户自定义配置与插件)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制重新调用 Scoop 重新安装/更新本体并全量重写配置。

.PARAMETER Purge
    配合 Uninstall 使用，连带深度物理粉碎配置目录与持久化缓存 (包含 persist)。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\zedg.ps1 -Action Check

    # 交互式检查并应用工程基线
    pwsh -File .\scripts\apps\zedg.ps1

    # 强制重新部署覆盖本体并对齐基线
    pwsh -File .\scripts\apps\zedg.ps1 -Force

    # 安全清洁卸载 (保留配置)
    pwsh -File .\scripts\apps\zedg.ps1 -Action Uninstall

    # 深度粉碎卸载 (全抹除)
    pwsh -File .\scripts\apps\zedg.ps1 -Action Uninstall -Purge
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
    throw "【权限错误】ZedG 编辑器自动化部署与配置管理需管理员特权，请在提升的 pwsh 会话中重新执行！"
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
$AppId        = "zedg"
$AppName      = "ZedG 代码编辑器"
$ProcessName  = "ZedG"
$ScoopBucket  = "zedg"
$ScoopApp     = "zedg"

$scoopRoot    = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
$InstallDir   = Join-Path $scoopRoot "apps\$ScoopApp\current"
$AppExe       = Join-Path $InstallDir "ZedG.exe"
if (-not (Test-Path $AppExe) -and (Test-Path (Join-Path $InstallDir "bin\ZedG.exe"))) {
    $AppExe = Join-Path $InstallDir "bin\ZedG.exe"
}
$ConfDir      = Join-Path $env:APPDATA "Zed"
$ConfigFile   = Join-Path $ConfDir "settings.json"
$PersistDir   = Join-Path $scoopRoot "persist\$ScoopApp"

$HighValueUserData = @(
    "个人按键映射: $ConfDir\keymap.json",
    "自定义编辑器设置与主题/插件声明: $ConfigFile",
    "持久化配置目录: $PersistDir"
)

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
    if (Test-Path $bucketDir) {
        return
    }

    $installedBuckets = @(& scoop bucket list 2>$null 3>$null | ForEach-Object {
        if ($_.Name) { $_.Name } else { ($_ -split '\s+')[0] }
    })
    if ($installedBuckets -contains $BucketName) {
        return
    }

    Write-Host "📦 正在添加 Scoop '$BucketName' bucket..." -ForegroundColor Cyan
    if ($BucketRepo) {
        & scoop bucket add $BucketName $BucketRepo
    } else {
        & scoop bucket add $BucketName
    }
    if ($LASTEXITCODE -ne 0) {
        throw "添加 Scoop bucket '$BucketName' 失败 (退出代码 $LASTEXITCODE)，请检查网络连接与仓库地址。"
    }
}

function ConvertFrom-Jsonc {
    param([string]$JsoncText)
    if ([string]::IsNullOrWhiteSpace($JsoncText)) { return $null }
    $clean = $JsoncText -replace '(?m)^\s*//.*$', '' -replace '/\*[\s\S]*?\*/', ''
    $clean = $clean -replace ',(\s*[}\]])', '$1'
    try {
        return ($clean | ConvertFrom-Json)
    } catch {
        return $null
    }
}

$ManagedSpecs = @(
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
        Purpose  = "物理关闭代码连字特性，保持符号原始独立形态"
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
        Property = "光标样式与闪烁 (cursor_shape / blink)"
        Path     = "cursor_shape"
        Expected = "bar"
        Purpose  = "固化竖线垂直光标与呼吸灯闪烁效果"
        Impact   = "对齐现代编辑器标准光标交互手感"
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
        Property = "优先 POSIX LF 换行 (prefer_lf = true)"
        Path     = "prefer_lf"
        Expected = "True"
        Purpose  = "新文件与保存时优先采用 POSIX 标准 LF (\n) 换行符"
        Impact   = "彻底消除跨平台 Git 提交时的 CRLF 脏换行漫延"
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
        Impact   = "免除频繁手动按 Ctrl+S，代码资产永不丢失"
    },
    @{
        Property = "切断崩溃与使用遥测 (telemetry.diagnostics)"
        Path     = "telemetry.diagnostics"
        Expected = "False"
        Purpose  = "彻底禁用 Zed 后台使用数据与崩溃报告上传"
        Impact   = "保护本地代码与项目隐私，消除静默网络请求"
    },
    @{
        Property = "切断匿名性能指标 (telemetry.metrics)"
        Path     = "telemetry.metrics"
        Expected = "False"
        Purpose  = "彻底关闭匿名指标数据收集"
        Impact   = "消除遥测网络开销"
    }
)

# ==============================================================================
# 3. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将彻底终止 ZedG 进程、清理配置目录并卸载本体！" -ForegroundColor Yellow
        Write-Host "📌 【即将被物理抹除的高价值用户数据清单】:" -ForegroundColor Cyan
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "👉 执行清洁卸载将彻底清理配置目录。若需保留客制配置，请先手动备份。`n" -ForegroundColor Yellow

        $confirm = (Read-Host "确认彻底清除 ZedG 配置目录与程序本体? [y/N]").Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在执行环境清理..." -ForegroundColor Yellow

    Get-Process -Name "ZedG", "zedg" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500

    foreach ($candConf in @($ConfDir, (Join-Path $env:APPDATA "ZedG"))) {
        if (Test-Path $candConf) {
            Remove-Item -Path $candConf -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "   - 已彻底清除用户配置目录: $candConf" -ForegroundColor Gray
        }
    }
    foreach ($candLocal in @((Join-Path $env:LOCALAPPDATA "Zed"), (Join-Path $env:LOCALAPPDATA "ZedG"))) {
        if (Test-Path $candLocal) {
            Remove-Item -Path $candLocal -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "   - 已清理本地运行时缓存: $candLocal" -ForegroundColor Gray
        }
    }

    Remove-Item -Path "HKCU:\Software\Classes\Applications\ZedG.exe" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\ZedG" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Zed" -Recurse -Force -ErrorAction SilentlyContinue
    @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "ZedG.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Scoop Apps" "ZedG.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "ZedG.lnk")
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
    }

    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        if (Test-Path (Join-Path $scoopRoot "apps\zedg")) {
            Write-Host "   - 正在通过 Scoop 清洁卸载客户端本体 [zedg] (--purge)..." -ForegroundColor Gray
            & scoop uninstall -p zedg
        }
    }

    $candApp = Join-Path $scoopRoot "apps\zedg"
    if (Test-Path $candApp) {
        Remove-Item -Path $candApp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $candPersist = Join-Path $scoopRoot "persist\zedg"
    if (Test-Path $candPersist) {
        Remove-Item -Path $candPersist -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`n✅ [清洁卸载完成] ZedG 编辑器本体与配置环境已彻底清除。`n" -ForegroundColor Green
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
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "客户端本体"
    受控属性 = "主执行文件 (ZedG.exe)"
    期望基线 = "已就绪 ($AppExe)"
    实机状态 = if ($isInstalled) { "已就绪 ($AppExe)" } else { "未安装" }
    状态判定 = if ($isInstalled) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $isInstalled) {
    $PendingItems.Add([PSCustomObject]@{
        Property = "主执行文件 (ZedG.exe)"
        Actual   = "未安装"
        Expected = "已就绪 ($AppExe)"
        Purpose  = "部署 Zed Globalization 现代高性能代码编辑器本体"
        Impact   = "若未就绪将自动调用 Scoop 从 zedg bucket 安装"
    })
}

$existingSettings = $null
if (Test-Path $ConfigFile) {
    try {
        $rawContent = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
        $existingSettings = ConvertFrom-Jsonc -JsoncText $rawContent
    } catch {}
}

function Get-ZedgConfigValue($obj, [string]$path) {
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

foreach ($item in $ManagedSpecs) {
    $actual = Get-ZedgConfigValue $existingSettings $item.Path
    $actualStr = if ($null -eq $actual) { "<缺省未设>" } else { "$actual" }
    $expectedStr = "$($item.Expected)"
    $matched = ($actualStr.ToLower() -eq $expectedStr.ToLower())

    $AuditBoard.Add([PSCustomObject]@{
        分层模块 = "编辑器基线"
        受控属性 = $item.Property
        期望基线 = $expectedStr
        实机状态 = $actualStr
        状态判定 = if ($matched) { "✔ 匹配" } else { "✘ 偏离" }
    })

    if (-not $matched) {
        $PendingItems.Add([PSCustomObject]@{
            Property = $item.Property
            Path     = $item.Path
            Actual   = $actualStr
            Expected = $expectedStr
            Purpose  = $item.Purpose
            Impact   = $item.Impact
        })
    }
}

Write-Host "`n📊 [巡检看板] ZedG 原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($Action -eq "Check") {
    if ($driftCount -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性与工程基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $driftCount) -ForegroundColor Yellow
    }
    return
}

if ($driftCount -eq 0 -and -not $Force) {
    Write-Host "✨ [状态合规] 所有受控属性均已符合工程基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate - Shift-Left: 目的与影响结构化直出)
# ==============================================================================

# 5.1 运行态并发防覆写硬门禁
$runningZed = Get-Process -Name "ZedG", "zedg" -ErrorAction SilentlyContinue
if ($runningZed) {
    if (-not $Yes) {
        Write-Warning "检测到 ZedG 编辑器当前正在运行！外部修改会被退出时的内存状态覆写。"
        $confirmProc = (Read-Host "是否立即关闭正在运行的 ZedG 进程以继续应用基线? [Y/n]").Trim()
        if ($confirmProc -match '^(n|no)$') {
            Write-Host "[-] 用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningZed | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# 5.2 未安装或强制重装审查门禁
$needBinaryDeploy = (-not $isInstalled) -or $Force
if ($needBinaryDeploy) {
    if (-not $Yes) {
        $promptMsg = if (-not $isInstalled) {
            "未检测到 ZedG 编辑器，是否立即调用 Scoop 安装？[Y/n]"
        } else {
            "已开启强制重新部署 (-Force)，是否重新通过 Scoop 安装/更新 ZedG 本体？[Y/n]"
        }
        $shouldInstall = (Read-Host $promptMsg).Trim()
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
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.Property) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.Actual, $p.Expected) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $p.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $p.Impact) -ForegroundColor Gray
        $idx++
    }

    $gateChoice = (Read-Host "`n确认应用上述工程基线配置? [Y] 确认执行 / [Q] 退出 (默认 Y)").Trim()
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体安装或覆盖升级
if ($needBinaryDeploy) {
    if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
        throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
    }

    Ensure-ScoopBucket $ScoopBucket "https://github.com/x6nux/scoop-zedg"
    if ($Force -and $isInstalled) {
        Write-Host "`n📦 [强制重新部署] 正在重新安装/更新 ZedG 本体..." -ForegroundColor Cyan
        & scoop install zedg/zedg --force
    } else {
        Write-Host "`n🚀 正在通过 Scoop 安装 ZedG..." -ForegroundColor Cyan
        & scoop install zedg/zedg
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Scoop 部署 ZedG 失败 (退出代码 $LASTEXITCODE)。"
    }

    $cand = Join-Path $scoopRoot "apps\zedg\current"
    if (Test-Path (Join-Path $cand "ZedG.exe")) {
        $AppExe = Join-Path $cand "ZedG.exe"
        $isInstalled = $true
    } elseif (Test-Path (Join-Path $cand "bin\ZedG.exe")) {
        $AppExe = Join-Path $cand "bin\ZedG.exe"
        $isInstalled = $true
    }
    if (-not $isInstalled) {
        throw "Scoop 安装完成，但未能定位到 $AppExe，请检查 Scoop 安装状态。"
    }
}

# 6.2 增量合并并原子写入 settings.json
Write-Host "`n⚙️  正在执行 settings.json 体验基线偏好对齐..." -ForegroundColor Cyan
Ensure-Dir $ConfDir

$targetJsonObj = if ($existingSettings) { $existingSettings } else { [PSCustomObject]@{} }

function Set-NestedProperty($obj, [string]$path, $val) {
    $parts = $path.Split('.')
    $curr = $obj
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        if (-not $curr.PSObject.Properties.Match($part).Count) {
            $curr | Add-Member -MemberType NoteProperty -Name $part -Value ([PSCustomObject]@{}) -Force
        }
        $curr = $curr.$part
    }
    $typedVal = if ($val -eq "True") { $true } elseif ($val -eq "False") { $false } elseif ($val -match '^\d+$') { [int]$val } else { $val }
    $curr | Add-Member -MemberType NoteProperty -Name $parts[-1] -Value $typedVal -Force
}

foreach ($item in $ManagedSpecs) {
    Set-NestedProperty -obj $targetJsonObj -path $item.Path -val $item.Expected
}

$finalJson = $targetJsonObj | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ConfigFile, $finalJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ settings.json 工程基线已原子落盘至: $ConfigFile" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与配置管理完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 字体基线: 已注入 Maple Mono NL NFMono CN 并关闭代码连字" -ForegroundColor Gray
Write-Host "   - 编辑基线: 固化 2 空格缩进、自动软折行、空白符显示、失焦即时保存与 LF 换行格式" -ForegroundColor Gray
Write-Host "   - 隐私与终端: 切断遥测与匿名指标上传，锁定系统终端集成" -ForegroundColor Gray

return
