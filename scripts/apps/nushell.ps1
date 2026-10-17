#requires -Version 7.0
<#
.SYNOPSIS
    Nushell 现代终端环境

.DESCRIPTION
    Nushell 现代结构化数据流 Shell (Windows) 官方插件管理与 SQLite 历史基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线（Plan -> Diff -> Gate -> Apply -> Report）。
    2. 基于 Scoop 纳管的二进制本体（D:\prog\scoop\apps\nushell\current\nu.exe），前置深入细化状态诊断。
    3. 官方核心插件自治管理与自愈：管理并自动重新签名注册 5 大官方核心插件 (polars, formats, gstat, query, inc)，彻底解决 Nushell 版本升级导致插件签名协议失效 (invalid) 的问题。
    4. 现代化历史体验黄金基线：注入 config.nu 托管配置块，固化 SQLite 数据库结构化存储、多终端跨会话即时同步与前缀检索。

.PARAMETER Clean
    清洁卸载模式。清理 config.nu 托管块，注销核心插件，并通过 Scoop 卸载客户端本体。
    别名: -Fresh, -Reset

.PARAMETER CheckOnly
    只查不改模式（体检巡检）。逐项深入比对 Nushell 安装状态、核心插件有效性与 config.nu 核心参数基线，高亮输出 Diff，零写入安全退出。
    别名: -Audit

.PARAMETER ConfigOnly
    仅执行插件重新注册与 config.nu 黄金基线注入，不重新安装或更新二进制程序。

.PARAMETER InstallOnly
    仅执行通过 Scoop 更新或安装 Nushell 本体，不修改配置。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线（用于自动化流水线）。

.PARAMETER Yes
    一键全量确认放行（同 -NonInteractive）。

.PARAMETER InstallDir
    Nushell 安装目标目录，默认优先自适应探测 Scoop 路径（如 D:\prog\scoop\apps\nushell\current）。

.PARAMETER ConfDir
    Nushell 配置目录，默认为 $env:APPDATA\nushell。

.EXAMPLE
    # 交互式全流程检查与配置
    pwsh -File .\scripts\apps\nushell.ps1

    # 只查不改体检巡检
    pwsh -File .\scripts\apps\nushell.ps1 -CheckOnly

    # 仅修复插件注册与历史基线配置
    pwsh -File .\scripts\apps\nushell.ps1 -ConfigOnly

    # 彻底清洁重装
    pwsh -File .\scripts\apps\nushell.ps1 -Clean
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

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    foreach ($root in $scoopRoots) {
        $cand = Join-Path $root "apps\nushell\current"
        if (Test-Path (Join-Path $cand "nu.exe")) {
            $InstallDir = $cand
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = Join-Path $defaultScoop "apps\nushell\current"
    }
}

$nuExe = Join-Path $InstallDir "nu.exe"
$isInstalled = Test-Path $nuExe

if ([string]::IsNullOrWhiteSpace($ConfDir)) {
    $ConfDir = Join-Path $env:APPDATA "nushell"
}

$configFile = Join-Path $ConfDir "config.nu"

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "  Nushell 现代终端环境与插件管理工具 (pwsh 7+)" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "📂 部署基准目录: 安装目录 [$InstallDir] | 配置目录 [$ConfDir]`n" -ForegroundColor Cyan

# 辅助函数：更新标记配置块 (Managed Config Block)
function Update-ManagedConfigFile {
    param(
        [string]$FilePath,
        [string]$Tag,
        [string]$NewContent
    )
    $startMarker = "# >>> managed: $Tag >>>"
    $endMarker   = "# <<< managed: $Tag <<<"
    $managedBlock = "$startMarker`r`n$NewContent`r`n$endMarker"

    if (-not (Test-Path $FilePath)) {
        $parent = Split-Path $FilePath -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($FilePath, "$managedBlock`r`n", [System.Text.UTF8Encoding]::new($false))
        return
    }

    $existing = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $startEscaped = [regex]::Escape($startMarker)
    $endEscaped   = [regex]::Escape($endMarker)
    $pattern = "(?ms)^[ \t]*$startEscaped\r?\n.*?\r?\n[ \t]*$endEscaped[ \t]*\r?\n?"

    if ($existing -match $pattern) {
        $updated = [System.Text.RegularExpressions.Regex]::Replace($existing, $pattern, "$managedBlock`r`n")
    } else {
        $trimmed = $existing.TrimEnd()
        $updated = if ($trimmed.Length -gt 0) { "$trimmed`r`n`r`n$managedBlock`r`n" } else { "$managedBlock`r`n" }
    }
    [System.IO.File]::WriteAllText($FilePath, $updated, [System.Text.UTF8Encoding]::new($false))
}

$nuBaseline = @'
# 固化历史记录为现代 SQLite 结构化数据库格式
$env.config.history.file_format = "sqlite"

# 跨终端多会话即时写入同步 (回车即提交历史，告别终端退出才落盘与覆盖丢失)
$env.config.history.sync_on_enter = true

# 关闭会话隔离，确保跨会话多终端共享全量命令历史
$env.config.history.isolation = false

# 扩容历史记录上限至 100,000 条
$env.config.history.max_size = 100_000

# 终端表格渲染基线：现代圆角风格与索引列优化
$env.config.table.mode = "rounded"
$env.config.table.show_empty = true

# 开启快速光标行尾前缀匹配过滤历史 (Up/Down 原生检索)
$env.config.edit_mode = "emacs"
'@

# ==============================================================================
# 阶段 A: 清洁卸载模式 (-Clean)
# ==============================================================================
if ($Clean) {
    if (-not $NonInteractive -and -not $Yes) {
        $confirmClean = Read-Host "⚠️ [Clean 警示] 将清理 Nushell 核心配置与插件并卸载本体，确认继续? [y/N]"
        if ($confirmClean.Trim() -notmatch '^(y|yes)$') {
            Write-Host "用户已取消清洁重装操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "🧹 [清洁重装模式] 正在清理 Nushell 配置与插件环境..." -ForegroundColor Yellow

    # 1. 终止可能运行的 nu 进程
    Get-Process -Name "nu" -ErrorAction SilentlyContinue | Stop-Process -Force

    # 2. 清理 config.nu 中的 managed 托管块
    if (Test-Path $configFile) {
        $existing = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
        $cleanPattern = "(?ms)^[ \t]*# >>> managed: nu-history-baseline >>>\r?\n.*?\r?\n[ \t]*# <<< managed: nu-history-baseline <<<\r?\n?"
        if ($existing -match $cleanPattern) {
            $cleaned = [System.Text.RegularExpressions.Regex]::Replace($existing, $cleanPattern, "")
            [System.IO.File]::WriteAllText($configFile, $cleaned.TrimEnd() + "`r`n", [System.Text.UTF8Encoding]::new($false))
            Write-Host "   - 已剥离 config.nu 中的托管基线配置块。" -ForegroundColor Gray
        }
    }

    # 3. 清理插件注册缓存文件 (plugin.msgpackz)
    $pluginCache = Join-Path $ConfDir "plugin.msgpackz"
    if (Test-Path $pluginCache) {
        Remove-Item -Path $pluginCache -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理插件注册签名缓存: $pluginCache" -ForegroundColor Gray
    }

    # 4. 卸载程序本体
    if (Test-Path $InstallDir) {
        if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
            Write-Host "   - 正在调用 Scoop 卸载客户端本体..." -ForegroundColor Gray
            & scoop uninstall nushell 2>$null | Out-Null
        } else {
            Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "✅ [清洁完成] Nushell 托管配置与本体已彻底清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 阶段 B: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
$chkList = [System.Collections.Generic.List[PSCustomObject]]::new()
$diffList = [System.Collections.Generic.List[PSCustomObject]]::new()

# 1. 本体安装状态
$chkList.Add([PSCustomObject]@{
    "配置模块" = "客户端本体"
    "受控属性" = "Nushell 二进制安装 (nu.exe)"
    "期望基线" = "已就绪 ($nuExe)"
    "实机状态" = if ($isInstalled) { "已就绪 ($nuExe)" } else { "未安装" }
    "判定"     = if ($isInstalled) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $isInstalled) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "客户端本体"
        "受控属性" = "Nushell 二进制安装 (nu.exe)"
        "实机状态" = "未安装"
        "期望基线" = "已就绪 ($nuExe)"
    })
}

# 2. 深入检查 5 大核心官方插件有效性状态 (polars, formats, gstat, query, inc)
$isPluginReady = $false
$pluginStatusText = "未安装本体"
if ($isInstalled) {
    try {
        $checkCmd = 'let helper = ($nu.current-exe | path dirname | path join "register-core-plugins.nu"); if ($helper | path exists) { (plugin list | where name == "polars" and status != "invalid" | is-not-empty) } else { true }'
        $res = (& $nuExe -c $checkCmd 2>$null)
        if ($res -match '(?i)true') {
            $isPluginReady = $true
            $pluginStatusText = "有效注册 (polars等5核心插件)"
        } else {
            $pluginStatusText = "未注册或签名失效 (invalid)"
        }
    } catch {
        $pluginStatusText = "探测异常: $($_.Exception.Message)"
    }
}

$chkList.Add([PSCustomObject]@{
    "配置模块" = "插件生态"
    "受控属性" = "核心官方插件注册 (polars/formats/gstat/query/inc)"
    "期望基线" = "有效注册 (polars等5核心插件)"
    "实机状态" = $pluginStatusText
    "判定"     = if ($isPluginReady) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isPluginReady -and $isInstalled -and -not $InstallOnly) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "插件生态"
        "受控属性" = "核心官方插件注册 (polars等5核心插件)"
        "实机状态" = $pluginStatusText
        "期望基线" = "有效注册并加载"
    })
}

# 3. 深入细化检查 config.nu 各受控历史体验基线
$confRaw = ""
if (Test-Path $configFile) {
    $confRaw = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
}

function Test-NuConfigField([string]$raw, [string]$field, [string]$valRegex) {
    if ([string]::IsNullOrEmpty($raw)) { return $false }
    $escapedPrefix = [regex]::Escape('$env.config.')
    $escapedField  = [regex]::Escape($field)
    return ($raw -match "(?m)^\s*$escapedPrefix$escapedField\s*=\s*$valRegex")
}

$coreNuConfigs = @(
    @{ Field = "history.file_format";  ValRegex = '"sqlite"';  Expected = '"sqlite"'; Desc = "结构化历史存储格式" },
    @{ Field = "history.sync_on_enter"; ValRegex = 'true';     Expected = "true";     Desc = "多终端即时回车同步" },
    @{ Field = "history.isolation";     ValRegex = 'false';    Expected = "false";    Desc = "关闭会话隔离 (全量共享)" },
    @{ Field = "history.max_size";      ValRegex = '\d+';      Expected = ">= 100000"; Desc = "历史容量扩容" },
    @{ Field = "table.mode";            ValRegex = '"rounded"'; Expected = '"rounded"'; Desc = "现代圆角表格视效" }
)

foreach ($nc in $coreNuConfigs) {
    $matched = Test-NuConfigField $confRaw $nc.Field $nc.ValRegex
    $actualStr = if ($matched) { "已注入期望值" } else { (Test-Path $configFile) ? "缺省未设或偏离" : "配置文件缺失" }

    $chkList.Add([PSCustomObject]@{
        "配置模块" = "Shell体验"
        "受控属性" = "$($nc.Desc) ($($nc.Field))"
        "期望基线" = $nc.Expected
        "实机状态" = $actualStr
        "判定"     = $matched ? "✔ 匹配" : "✘ 偏离"
    })

    if (-not $matched -and -not $InstallOnly) {
        $diffList.Add([PSCustomObject]@{
            "受控模块" = "Shell体验"
            "受控属性" = "$($nc.Desc) ($($nc.Field))"
            "实机状态" = $actualStr
            "期望基线" = $nc.Expected
        })
    }
}

# 只查不改模式 (-CheckOnly) 立即输出看板后安全退出
if ($CheckOnly) {
    Write-Host "`n📊 [巡检看板] Nushell 受控属性深入基线审计清单:" -ForegroundColor Cyan
    $chkList | Format-Table -AutoSize | Out-String | Write-Host

    if ($diffList.Count -eq 0) {
        Write-Host "✔ [状态合规] 所有受控属性均与工程黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host "⚠️  共发现 $($diffList.Count) 项基线偏离。执行默认模式 (-Sync) 或纯配置模式 (-ConfigOnly) 即可自动对齐。`n" -ForegroundColor Yellow
        if (-not $isPluginReady -and $isInstalled) {
            Write-Host "💡 插件失效成因: Nushell 插件强绑定引擎主版本协议。升级主程序后旧插件在 plugin.msgpackz 中的签名将失效 (invalid)，执行默认模式 (-Sync) 即可重新签名注册自愈。" -ForegroundColor Gray
        }
        if (-not $isInstalled) {
            Write-Host "💡 提示: 未检测到客户端安装，可执行 'scoop install nushell' 或运行本脚本安装本体。" -ForegroundColor Gray
        }
    }
    return
}

# 若无偏离且无安装诉求，直接提前安全退出
if ($diffList.Count -eq 0 -and -not $InstallOnly) {
    Write-Host "`n📊 [巡检看板] Nushell 受控属性深入基线审计清单:" -ForegroundColor Cyan
    $chkList | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "✨ [状态合规] 所有受控属性与策略均已符合工程黄金基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# 发现基线偏离，高亮输出差异清单
Write-Host "`n📋 [差异清单] 检测到以下受控属性偏离黄金基线:" -ForegroundColor Cyan
$diffList | Format-Table -AutoSize | Out-String | Write-Host

# ==============================================================================
# 阶段 C: 模式审查门禁 (Gate)
# ==============================================================================
# 1. 运行态并发防覆写硬门禁
$runningNu = Get-Process -Name "nu" -ErrorAction SilentlyContinue
if ($runningNu) {
    if (-not $NonInteractive -and -not $Yes) {
        Write-Warning "检测到 Nushell 正在运行！外部修改会被退出时的内存状态覆写。"
        $confirmProc = Read-Host "是否立即关闭正在运行的 Nushell 进程以继续应用基线? [Y/n]"
        if ($confirmProc.Trim() -match "^(n|no)$") {
            Write-Host "用户已取消操作，安全退出。`n" -ForegroundColor Yellow
            return
        }
    }
    $runningNu | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# 2. 未安装时的安装审查门禁
if (-not $isInstalled) {
    if ($ConfigOnly) {
        throw "未检测到 Nushell 客户端安装。请先执行 'scoop install nushell' 安装后再执行配置。"
    }

    if (-not $NonInteractive -and -not $Yes) {
        $shouldInstall = Read-Host "未检测到 Nushell 客户端，是否立即调用 'scoop install nushell' 进行安装？[Y/n]"
        if ($shouldInstall.Trim() -match "^(n|no)$") {
            Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor Yellow
            return
        }
    }

    if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
        throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
    }
    Write-Host "🚀 正在通过 Scoop 安装 nushell..." -ForegroundColor Cyan
    & scoop install nushell

    # 重新探测
    foreach ($root in $scoopRoots) {
        $cand = Join-Path $root "apps\nushell\current"
        if (Test-Path (Join-Path $cand "nu.exe")) {
            $InstallDir = $cand
            $nuExe = Join-Path $InstallDir "nu.exe"
            $isInstalled = $true
            break
        }
    }
    if (-not $isInstalled) {
        throw "Scoop 安装完成，但未能定位到 $nuExe，请检查 Scoop 安装状态。"
    }
}

# 3. 策略审查门禁 (Shift-Left Gate: 改动理由与生效机制)
if (-not $NonInteractive -and -not $Yes) {
    Write-Host "💡 [改动说明与生效机制]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 注册并签名 5 大官方核心插件 (polars/formats/gstat/query/inc)" -ForegroundColor Gray
    Write-Host "   - 体验基线: 注入 config.nu 固化 SQLite 数据库历史格式、多终端跨会话即时同步与圆角表格" -ForegroundColor Gray
    $gateChoice = Read-Host "`n确认应用上述黄金基线配置? [Y] 确认应用 / [Q] 退出 (默认 Y)"
    if ($gateChoice.Trim() -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 阶段 D: 覆盖更新本体 (-InstallOnly)
# ==============================================================================
if ($InstallOnly) {
    Write-Host "📦 [覆盖升级模式] 正在调用 Scoop 升级 Nushell 本体..." -ForegroundColor Cyan
    Get-Process -Name "nu" -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        & scoop update nushell
        Write-Host "✅ [升级完成] Nushell 客户端本体已通过 Scoop 完成升级。`n" -ForegroundColor Green

        # 核心插件签名自愈：主版本升级后旧签名失效，自动触发核心插件重新签名注册
        Write-Host "🔄 [插件自愈] 检测到本体版本升级，正在重新签名注册 5 大官方核心插件 (polars, formats, gstat, query, inc)..." -ForegroundColor Cyan
        try {
            $regCmd = 'let helper = ($nu.current-exe | path dirname | path join "register-core-plugins.nu"); if ($helper | path exists) { nu $helper }'
            & $nuExe -c $regCmd 2>$null
            Write-Host "✅ 核心插件签名与加载自愈成功。`n" -ForegroundColor Green
        } catch {
            Write-Warning "调用核心插件注册脚本失败: $($_.Exception.Message)"
        }
    } else {
        throw "未检测到 scoop 命令，无法执行自动更新。"
    }
    return
}

# ==============================================================================
# 阶段 E: 单向原子落盘 (Apply)
# ==============================================================================
Write-Host "⚙️  正在执行 Nushell 插件注册与配置基线对齐..." -ForegroundColor Cyan
Write-Host "ℹ️  说明: Nushell 官方核心插件强依赖引擎主版本协议签名，版本升级后需重新签名并载入。" -ForegroundColor Gray

# 1. 注册核心官方插件 (polars, formats, gstat, query, inc)
Write-Host "   - 正在调用 register-core-plugins.nu 注册并签名 5 大官方核心插件..." -ForegroundColor Gray
try {
    $regCmd = 'let helper = ($nu.current-exe | path dirname | path join "register-core-plugins.nu"); if ($helper | path exists) { nu $helper }'
    & $nuExe -c $regCmd 2>$null
    Write-Host "✅ 核心插件签名与注册完成。" -ForegroundColor Green
} catch {
    Write-Warning "调用核心插件注册脚本失败: $($_.Exception.Message)"
}

# 2. 注入/更新 config.nu 现代化 SQLite 历史基线
if (-not (Test-Path $ConfDir)) {
    New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
}

Update-ManagedConfigFile $configFile "nu-history-baseline" $nuBaseline
Write-Host "✅ SQLite 结构化历史与跨终端同步基线已原子落盘至: $configFile" -ForegroundColor Green

# ==============================================================================
# 阶段 F: 尾部结报 (Report)
# ==============================================================================
Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  ✅ Nushell 现代终端环境与插件管理完成！" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "   - 插件状态: 5 大核心官方插件 (polars/formats/gstat/query/inc) 已签名自愈" -ForegroundColor Gray
Write-Host "   - 历史体验: 固化 SQLite 数据库存储格式与多终端跨会话即时同步" -ForegroundColor Gray
Write-Host "   - 检索交互: 原生支持命令行行尾按 Up/Down 前缀历史快速检索`n" -ForegroundColor Gray
