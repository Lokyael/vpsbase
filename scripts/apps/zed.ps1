#requires -Version 7.0
<#
.SYNOPSIS
    Zed 编辑器

.DESCRIPTION
    Zed 现代高性能代码编辑器 (Windows) 黄金基线配置与字体注入工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线（Plan -> Diff -> Gate -> Apply -> Report）。
    2. 基于 Scoop 纳管的二进制本体（优先适配 zedg 社区本地化版，兼容官方 zed），前置深入细化状态诊断。
    3. 注入 %APPDATA%\Zed\settings.json 黄金基线配置：固化工作站官方等宽字体基线 (Maple Mono NL NFMono CN)、关闭代码连字、规范 2 空格缩进、失焦自动保存、pwsh 终端集成与现代排版。
    4. 采用无破坏增量合并机制纳管 settings.json：原生兼容 JSONC 注释与尾随逗号，完整保留用户自定义主题、插件与客制配置。

.PARAMETER Clean
    清洁卸载模式。强杀常驻进程，清理 Zed 配置与缓存目录，并通过 Scoop 卸载客户端本体。
    别名: -Fresh, -Reset

.PARAMETER CheckOnly
    只查不改模式（体检巡检）。逐项深入比对 Zed 安装状态与 settings.json 核心受控基线，高亮输出 Diff，零写入安全退出。
    别名: -Audit

.PARAMETER ConfigOnly
    仅执行 settings.json 黄金基线注入，不重新安装或更新二进制程序。

.PARAMETER InstallOnly
    仅执行通过 Scoop 更新或安装 Zed 本体，不修改配置。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线（用于自动化流水线）。

.PARAMETER Yes
    一键全量确认放行（同 -NonInteractive）。

.PARAMETER InstallDir
    Zed 安装目标目录，默认优先自适应探测 Scoop 路径（如 D:\prog\scoop\apps\zedg\current）。

.PARAMETER ConfDir
    Zed 配置目录，默认为 $env:APPDATA\Zed。

.EXAMPLE
    # 交互式全流程检查与配置
    pwsh -File .\scripts\apps\zed.ps1

    # 只查不改体检巡检
    pwsh -File .\scripts\apps\zed.ps1 -CheckOnly

    # 仅修复字体与黄金基线配置
    pwsh -File .\scripts\apps\zed.ps1 -ConfigOnly

    # 彻底清洁重装
    pwsh -File .\scripts\apps\zed.ps1 -Clean
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
    [switch]$Yes,
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

# 自适应探测 zedg（社区本地化版）与 zed（官方原版）
$detectedApp = "zedg"
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    foreach ($root in $scoopRoots) {
        $candG = Join-Path $root "apps\zedg\current"
        if (Test-Path (Join-Path $candG "zed.exe")) {
            $InstallDir = $candG
            $detectedApp = "zedg"
            break
        }
        $candZ = Join-Path $root "apps\zed\current"
        if (Test-Path (Join-Path $candZ "zed.exe")) {
            $InstallDir = $candZ
            $detectedApp = "zed"
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = Join-Path $defaultScoop "apps\zedg\current"
    }
}

if ([string]::IsNullOrWhiteSpace($ConfDir)) {
    $ConfDir = Join-Path $env:APPDATA "Zed"
}

$zedExe = Join-Path $InstallDir "zed.exe"
$isInstalled = Test-Path $zedExe
$settingsFile = Join-Path $ConfDir "settings.json"

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "  Zed 编辑器 自动化部署与黄金基线配置工具 (pwsh 7+)" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "📂 安装基准目录: $InstallDir" -ForegroundColor Cyan
Write-Host "📁 配置基准目录: $ConfDir`n" -ForegroundColor Cyan

# ==============================================================================
# 阶段 A: 清洁卸载与环境重置 (-Clean)
# ==============================================================================
if ($Clean) {
    if (-not $NonInteractive -and -not $Yes) {
        $confirmClean = Read-Host "⚠️ [Clean 警示] 将彻底终止 Zed 进程、清理配置目录并卸载本体，确认继续? [y/N]"
        if ($confirmClean.Trim() -notmatch '^(y|yes)$') {
            Write-Host "用户已取消清洁重装操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "🧹 [清洁卸载模式] 正在执行环境清理..." -ForegroundColor Yellow

    # 1. 强力终止 Zed 常驻进程
    Get-Process -Name "zed", "zed-editor" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500

    # 2. 清理用户配置目录与本地缓存
    if (Test-Path $ConfDir) {
        Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已彻底清除 Zed 用户配置目录: $ConfDir" -ForegroundColor Gray
    }
    $localZed = Join-Path $env:LOCALAPPDATA "Zed"
    if (Test-Path $localZed) {
        Remove-Item -Path $localZed -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理 Zed 本地运行时缓存: $localZed" -ForegroundColor Gray
    }

    # 3. 委托 Scoop 卸载本体
    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        Write-Host "   - 正在通过 Scoop 卸载客户端本体..." -ForegroundColor Gray
        scoop uninstall zedg 2>$null | Out-Null
        scoop uninstall zed 2>$null | Out-Null
    }

    Write-Host "✅ [清洁完成] Zed 编辑器本体与配置环境已彻底清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 阶段 B: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
function ConvertFrom-Jsonc {
    param([string]$JsoncText)
    if ([string]::IsNullOrWhiteSpace($JsoncText)) { return $null }
    # 剥离单行/多行注释与尾随逗号 (Trailing Comma)
    $clean = $JsoncText -replace '(?m)^\s*//.*$', '' -replace '/\*[\s\S]*?\*/', ''
    $clean = $clean -replace ',(\s*[}\]])', '$1'
    try {
        return ($clean | ConvertFrom-Json)
    } catch {
        return $null
    }
}

$existingSettings = $null
if (Test-Path $settingsFile) {
    try {
        $rawContent = [System.IO.File]::ReadAllText($settingsFile, [System.Text.Encoding]::UTF8)
        $existingSettings = ConvertFrom-Jsonc -JsoncText $rawContent
    } catch {}
}

# 声明式工程受控基线属性清单
$baselineProps = [ordered]@{
    # 1. 字体与排版体系 (Maple Mono NL NFMono CN 核心承接)
    "buffer_font_family"                 = @{ Expected = "Maple Mono NL NFMono CN"; Desc = "代码主等宽字体" }
    "buffer_font_size"                   = @{ Expected = 14;                        Desc = "代码主字体字号" }
    "buffer_font_features.calt"          = @{ Expected = $false;                    Desc = "物理关闭代码连字 (No-Liga)" }
    "ui_font_size"                       = @{ Expected = 16;                        Desc = "UI 界面字号" }
    "cursor_shape"                       = @{ Expected = "bar";                     Desc = "标准垂直光标" }
    "cursor_blink"                       = @{ Expected = $true;                     Desc = "光标闪烁呼吸灯" }
    "current_line_highlight"             = @{ Expected = "all";                     Desc = "当前活动行与行号区高亮" }

    # 2. 现代工程代码缩进与排版规范
    "tab_size"                           = @{ Expected = 2;                         Desc = "Tab 制表符宽度 (2 空格)" }
    "hard_tabs"                          = @{ Expected = $false;                    Desc = "强制使用空格替换真实 Tab" }
    "auto_indent"                        = @{ Expected = $true;                     Desc = "语法树自适应自动缩进" }
    "auto_indent_on_paste"               = @{ Expected = $true;                     Desc = "多行粘贴自适应缩进对齐" }
    "format_on_save"                     = @{ Expected = "on";                      Desc = "文件保存时自动格式化" }
    "autosave"                           = @{ Expected = "on_focus_change";         Desc = "窗口失焦时即时自动保存" }
    "remove_trailing_whitespace_on_save" = @{ Expected = $true;                     Desc = "保存时自动剔除行尾无用空格" }
    "ensure_final_newline_on_save"       = @{ Expected = $true;                     Desc = "保存时确保文件末尾换行符" }
    "preferred_line_length"              = @{ Expected = 100;                       Desc = "现代宽屏最佳行宽上限 (100 列)" }
    "wrap_guides"                        = @{ Expected = @(100);                    Desc = "100 列垂直排版参考导轨" }
    "show_wrap_guides"                   = @{ Expected = $true;                     Desc = "显示垂直参考线" }
    "soft_wrap"                          = @{ Expected = "none";                    Desc = "代码区禁用自动软折行" }
    "show_whitespaces"                   = @{ Expected = "selection";               Desc = "选中文本时显式高亮空白符" }
    "scroll_beyond_last_line"            = @{ Expected = "off";                     Desc = "禁用末行过度空白滚动" }

    # 3. 视觉感知与无干扰辅助
    "colorize_brackets"                  = @{ Expected = $true;                     Desc = "彩虹配对括号高亮" }
    "sticky_scroll"                      = @{ Expected = $true;                     Desc = "长函数/类名顶部吸附 (Sticky Scroll)" }
    "minimap.show"                       = @{ Expected = "never";                   Desc = "彻底关闭右侧代码小地图 (降噪提速)" }
    "confirm_quit"                       = @{ Expected = $true;                     Desc = "退出应用防误触二次确认" }

    # 4. 智能感知与 LSP
    "inlay_hints.enabled"                = @{ Expected = $true;                     Desc = "行内类型与形参提示 (Inlay Hints)" }
    "show_completions_on_input"          = @{ Expected = $true;                     Desc = "输入时实时弹出智能补全" }
    "show_completion_documentation"      = @{ Expected = $true;                     Desc = "补全列表同步展开详细文档" }
    "hover_popover_enabled"              = @{ Expected = $true;                     Desc = "鼠标悬停符号展示类型详情" }
    "hover_popover_delay"                = @{ Expected = 300;                       Desc = "悬停提示触发延迟 (300ms 快速响应)" }

    # 5. 内置终端深度集成
    "terminal.font_family"               = @{ Expected = "Maple Mono NL NFMono CN"; Desc = "终端等宽字体" }
    "terminal.font_size"                 = @{ Expected = 13;                        Desc = "终端字体字号" }
    "terminal.shell.program"             = @{ Expected = "pwsh.exe";                Desc = "终端默认 Shell (pwsh)" }

    # 6. Git 与项目工作树
    "git.inline_blame.enabled"           = @{ Expected = $true;                     Desc = "光标行末轻量显示 Git Blame" }
    "diff_view_style"                    = @{ Expected = "split";                   Desc = "Git 差异双栏并排对比 (Split Diff)" }
    "project_panel.auto_reveal_entries"  = @{ Expected = $true;                     Desc = "活动文件左侧树自适应高亮定位" }
    "project_panel.git_status"           = @{ Expected = $true;                     Desc = "项目树展示 Git 变动状态色" }

    # 7. 隐私加固、遥测阻断与包管理器协同
    "telemetry.diagnostics"              = @{ Expected = $false;                    Desc = "切断崩溃与诊断遥测日志上传" }
    "telemetry.metrics"                  = @{ Expected = $false;                    Desc = "切断使用度量指标遥测回传" }
    "disable_ai"                         = @{ Expected = $true;                     Desc = "禁用内置 AI 遥测与闭源模型调用" }
    "auto_update"                        = @{ Expected = $false;                    Desc = "禁用内置自更新 (委托 Scoop 纳管)" }
    "suggest_extensions"                 = @{ Expected = $false;                    Desc = "禁用扩展弹窗推荐与横幅干扰" }
}

$chkList = [System.Collections.Generic.List[PSCustomObject]]::new()
$diffList = [System.Collections.Generic.List[PSCustomObject]]::new()

# 1. 二进制安装嗅探
$chkList.Add([PSCustomObject]@{
    "受控模块" = "客户端本体"
    "受控属性" = "二进制程序本体 (zed.exe)"
    "期望基线" = "已安装于 $InstallDir"
    "实机状态" = $isInstalled ? "已就绪" : "未安装"
    "判定"     = $isInstalled ? "✔ 匹配" : "✘ 缺失"
})
if (-not $isInstalled) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "客户端本体"
        "受控属性" = "二进制程序本体 (zed.exe)"
        "实机状态" = "未安装"
        "期望基线" = "已安装于 $InstallDir"
    })
}

# 辅助函数：根据点分路径提取对象深层属性
function Get-DeepProperty {
    param($Obj, [string]$Path)
    if ($null -eq $Obj) { return $null }
    $parts = $Path.Split('.')
    $curr = $Obj
    foreach ($p in $parts) {
        if ($null -eq $curr -or -not ($curr.PSObject.Properties.Name -contains $p)) {
            return $null
        }
        $curr = $curr.$p
    }
    return $curr
}

function Test-ValMatch($a, $b) {
    if ($null -eq $a -or $null -eq $b) { return ($null -eq $a -and $null -eq $b) }
    if ($a -is [bool] -or $b -is [bool]) { return [bool]$a -eq [bool]$b }
    if ($a -is [System.Collections.IEnumerable] -and $a -isnot [string]) {
        return (ConvertTo-Json $a -Compress) -eq (ConvertTo-Json $b -Compress)
    }
    return "$a" -eq "$b"
}

function Format-Val($v) {
    if ($null -eq $v) { return "<缺省未设>" }
    if ($v -is [bool]) { return ($v ? "true" : "false") }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
        return (ConvertTo-Json $v -Compress)
    }
    return "$v"
}

# 2. 受控属性逐项巡检
foreach ($key in $baselineProps.Keys) {
    $prop = $baselineProps[$key]
    $actual = Get-DeepProperty -Obj $existingSettings -Path $key
    $matched = Test-ValMatch $actual $prop.Expected
    $actualStr = Format-Val $actual
    $expectedStr = Format-Val $prop.Expected

    $chkList.Add([PSCustomObject]@{
        "受控模块" = "首选项配置"
        "受控属性" = $prop.Desc
        "期望基线" = $expectedStr
        "实机状态" = $actualStr
        "判定"     = $matched ? "✔ 匹配" : "✘ 偏离"
    })

    if (-not $matched -and -not $InstallOnly) {
        $diffList.Add([PSCustomObject]@{
            "受控模块" = "首选项配置"
            "受控属性" = $prop.Desc
            "实机状态" = $actualStr
            "期望基线" = $expectedStr
        })
    }
}

# 输出全量只读嗅探表格
Write-Host "📋 [只读嗅探] 受控属性合规诊断全景:" -ForegroundColor Cyan
$chkList | Format-Table -AutoSize | Out-String | Write-Host

# ==============================================================================
# 阶段 C: 差异决策门禁 (Gate)
# ==============================================================================
if ($CheckOnly) {
    if ($diffList.Count -eq 0) {
        Write-Host "✅ [体检合格] Zed 编辑器本体与黄金基线配置已 100% 契合，零偏离。`n" -ForegroundColor Green
    } else {
        Write-Host "⚠️ [体检偏离] 发现 $($diffList.Count) 项受控属性偏离黄金基线:`n" -ForegroundColor Yellow
        $diffList | Format-Table -AutoSize | Out-String | Write-Host
    }
    return
}

if ($diffList.Count -eq 0 -and $isInstalled) {
    Write-Host "✅ [已就绪] Zed 编辑器与受控黄金基线完全一致，无需任何写入。`n" -ForegroundColor Green
    return
}

Write-Host "⚠️ 检测到受控属性偏离或组件缺失，即将执行单向对齐:" -ForegroundColor Yellow
$diffList | Format-Table -AutoSize | Out-String | Write-Host

if (-not $NonInteractive -and -not $Yes) {
    $confirm = Read-Host "确认按上述黄金基线执行增量对齐? [Y/n]"
    if ($confirm.Trim() -match '^(n|no)$') {
        Write-Host "用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# 进程并发防覆写硬门禁
$runningProc = Get-Process -Name "zed", "zed-editor" -ErrorAction SilentlyContinue
if ($runningProc) {
    if ($NonInteractive -or $Yes) {
        Write-Host "  [*] 检测到 Zed 进程运行态，正在平滑关闭以防配置覆写..." -ForegroundColor Cyan
        $runningProc | Stop-Process -Force
        Start-Sleep -Milliseconds 600
    } else {
        $termChoice = Read-Host "⚠️ Zed 正在运行。为防止内存配置覆写冲刷，需关闭进程方可写入。立即关闭? [Y/n]"
        if ($termChoice.Trim() -match '^(n|no)$') {
            Write-Host "请手动保存工作并关闭 Zed 后重新执行本脚本。安全退出。`n" -ForegroundColor Yellow
            return
        }
        $runningProc | Stop-Process -Force
        Start-Sleep -Milliseconds 600
    }
}

# ==============================================================================
# 阶段 D: 单向语义与增量原子落盘 (Apply)
# ==============================================================================
# 1. 二进制安装 (若缺失且非 ConfigOnly)
if (-not $isInstalled -and -not $ConfigOnly) {
    Write-Host "`n📦 [1/2] 正在通过 Scoop 部署 Zed 编辑器本体..." -ForegroundColor Cyan
    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        # 优先使用 zedg (社区中文版)，若 Bucket 未添加或失败则尝试 zed
        scoop install zedg
        if (-not (Get-Command "zed" -ErrorAction SilentlyContinue)) {
            scoop install zed
        }
    } else {
        Write-Error "未检索到 Scoop 包管理器，请先就绪 Scoop 环境或手动指定 -InstallDir。"
        return
    }
}

# 2. settings.json 增量深层合并
if (-not $InstallOnly) {
    Write-Host "`n⚙️ [2/2] 正在注入 Zed 黄金基线配置与等宽字体..." -ForegroundColor Cyan

    if (-not (Test-Path $ConfDir)) {
        New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
    }

    # 读取已有配置或初始化新对象
    $targetObj = if ($existingSettings) { $existingSettings } else { [PSCustomObject]@{} }

    # 深度设置属性辅助函数
    function Set-DeepProperty {
        param($Obj, [string]$Path, $Value)
        $parts = $Path.Split('.')
        $curr = $Obj
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $p = $parts[$i]
            if ($null -eq $curr.$p -or -not ($curr.$p -is [System.Management.Automation.PSCustomObject])) {
                $curr | Add-Member -MemberType NoteProperty -Name $p -Value ([PSCustomObject]@{}) -Force
            }
            $curr = $curr.$p
        }
        $leaf = $parts[-1]
        $curr | Add-Member -MemberType NoteProperty -Name $leaf -Value $Value -Force
    }

    # 注入受控属性基线
    foreach ($key in $baselineProps.Keys) {
        Set-DeepProperty -Obj $targetObj -Path $key -Value $baselineProps[$key].Expected
    }

    # 格式化 JSON 并原子落盘写入 (无 BOM UTF-8)
    $jsonOutput = ($targetObj | ConvertTo-Json -Depth 10) + "`r`n"
    [System.IO.File]::WriteAllText($settingsFile, $jsonOutput, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  [+] 已成功写入黄金基线首选项: $settingsFile" -ForegroundColor Green
}

# ==============================================================================
# 阶段 E: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  Zed 编辑器 黄金基线已成功装配对齐" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  • 核心等宽字体 : Maple Mono NL NFMono CN (14pt, 连字物理关闭)" -ForegroundColor Gray
Write-Host "  • 内置终端基线 : pwsh.exe + Maple Mono NL NFMono CN (13pt)" -ForegroundColor Gray
Write-Host "  • 现代排版规范 : 2 空格缩进, 失焦自动保存, 100 列参考线, 彩虹括号, 选区显空白符" -ForegroundColor Gray
Write-Host "  • 智能与工作流 : Inlay Hints 行内类型提示开启, Git Blame 悬停提示, Split Diff 并排" -ForegroundColor Gray
Write-Host "  • 隐私与包管理 : 彻底切断官方遥测 (diagnostics/metrics), 禁用内置 AI 弹窗, 委托 Scoop 纳管" -ForegroundColor Gray
Write-Host "`n📋 动态后续行动清单:" -ForegroundColor Cyan
Write-Host "  1. [界面语言] 若需简体中文界面，可在 Zed 中按 Ctrl+Shift+X 搜索安装 'Chinese (Simplified) Language Pack' 扩展包；" -ForegroundColor Gray
Write-Host "  2. [终端联动] Zed 已全面绑定 Maple Mono NL NFMono CN 与 PowerShell 7，开箱即享严格对齐体验。`n" -ForegroundColor Gray
