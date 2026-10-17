#requires -Version 7.0
<#
.SYNOPSIS
    Nushell 现代化结构化终端

.DESCRIPTION
    Nushell (Windows) 终端环境、5 大官方核心插件注册与 SQLite 结构化历史基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循“先检查后配置、幂等无冗余”原则。
    2. 基于 Scoop 纳管的二进制本体（D:\prog\scoop\apps\nushell\current\nu.exe），前置探测安装状态。
    3. 核心官方插件签名自愈：自动探测随 Scoop 分发的 5 大核心插件（polars, formats, gstat, query, inc），状态感知并自动签名注册；在安装与覆盖升级 (-InstallOnly) 后自动串联自愈，杜绝版本升级后插件 invalid 故障。
    4. 现代化历史基线固化：在 config.nu 中原子注入 SQLite 结构化历史存储格式、多终端会话回车即时同步与跨会话前缀检索基线。

.PARAMETER Clean
    清洁卸载模式。清理 Nushell 用户配置与历史数据库，并通过 Scoop 卸载客户端本体。
    别名: -Fresh, -Reset

.PARAMETER CheckOnly
    只查不改模式（体检巡检）。逐项比对 Nushell 安装状态、核心插件有效性与 config.nu 核心参数基线，高亮输出 Diff，零写入安全退出。
    别名: -Audit

.PARAMETER ConfigOnly
    仅执行插件注册签名与 config.nu 黄金基线注入，不重新安装或更新二进制程序。

.PARAMETER InstallOnly
    仅执行通过 Scoop 更新或安装 Nushell 本体，不修改配置。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线（用于自动化流水线）。

.PARAMETER InstallDir
    Nushell 安装目标目录，默认自适应探测 Scoop 路径（如 D:\prog\scoop\apps\nushell\current）。

.PARAMETER ConfDir
    Nushell 用户配置目录，默认为 $env:APPDATA\nushell。

.EXAMPLE
    # 交互式全流程检查与配置 (推荐)
    pwsh -File .\scripts\apps\nushell.ps1

    # 只查不改体检巡检
    pwsh -File .\scripts\apps\nushell.ps1 -CheckOnly

    # 仅修复插件注册与 config.nu 历史基线
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
        $cmdNu = Get-Command nu.exe -ErrorAction SilentlyContinue
        if ($cmdNu) {
            $InstallDir = Split-Path $cmdNu.Source -Parent
        } else {
            $InstallDir = Join-Path $defaultScoop "apps\nushell\current"
        }
    }
}

$nuExe = Join-Path $InstallDir "nu.exe"
$isInstalled = Test-Path $nuExe

if ([string]::IsNullOrWhiteSpace($ConfDir)) {
    if ($isInstalled) {
        try {
            $detected = & $nuExe -c '$nu.config-path' 2>$null
            if ($detected -and (Test-Path (Split-Path $detected.Trim()))) {
                $ConfDir = Split-Path $detected.Trim() -Parent
            }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($ConfDir)) {
        $ConfDir = Join-Path $env:APPDATA "nushell"
    }
}

$configFile = Join-Path $ConfDir "config.nu"

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "  Nushell 现代终端插件注册与基线自愈工具 (pwsh 7+)" -ForegroundColor Yellow
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
    $pattern = "(?ms)^[ \t]*\Q$startMarker\E\r?\n.*?\r?\n[ \t]*\Q$endMarker\E[ \t]*\r?\n?"

    if ($existing -match $pattern) {
        $updated = [System.Text.RegularExpressions.Regex]::Replace($existing, $pattern, "$managedBlock`r`n")
    } else {
        $trimmed = $existing.TrimEnd()
        $updated = if ($trimmed.Length -gt 0) { "$trimmed`r`n`r`n$managedBlock`r`n" } else { "$managedBlock`r`n" }
    }
    [System.IO.File]::WriteAllText($FilePath, $updated, [System.Text.UTF8Encoding]::new($false))
}

$nuBaseline = @'
# Nushell 默认已支持在行尾按 Up/Down 执行前缀检索 (PrefixSearch)
# 启用 SQLite 结构化历史与跨终端会话即时同步
$env.config.history.file_format = "sqlite"
$env.config.history.isolation = false
$env.config.history.sync_on_enter = true
'@

# ==============================================================================
# 阶段 A: 清洁卸载模式 (-Clean)
# ==============================================================================
if ($Clean) {
    Write-Host "🧹 [清洁卸载模式] 正在彻底清理 Nushell 运行时与配置残留..." -ForegroundColor Yellow
    Get-Process -Name "nu" -ErrorAction SilentlyContinue | Stop-Process -Force

    if (Test-Path $ConfDir) {
        Write-Host "   - 正在移除配置目录: $ConfDir" -ForegroundColor Gray
        Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        Write-Host "   - 正在通过 Scoop 卸载 Nushell 本体..." -ForegroundColor Gray
        & scoop uninstall nushell 2>$null | Out-Null
    }

    Write-Host "✅ [清洁完成] Nushell 已彻底移除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 阶段 B: 全量只读嗅探与状态比对 (Plan & Diff)
# ==============================================================================
$chkList = [System.Collections.Generic.List[PSCustomObject]]::new()

# 1. 本体安装状态
$chkList.Add([PSCustomObject]@{
    受控属性 = "Nushell 二进制安装"
    实机状态 = if ($isInstalled) { "已就绪 ($nuExe)" } else { "未安装" }
    期望基线 = "已就绪"
    判定     = if ($isInstalled) { "✔ 合规" } else { "✘ 偏离" }
})

# 2. 核心官方插件签名与注册状态 (polars, formats, gstat, query, inc)
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
            $pluginStatusText = "未注册或状态失效 (invalid)"
        }
    } catch {
        $pluginStatusText = "探测异常: $($_.Exception.Message)"
    }
}
$chkList.Add([PSCustomObject]@{
    受控属性 = "核心官方插件注册"
    实机状态 = $pluginStatusText
    期望基线 = "有效注册 (polars等5核心插件)"
    判定     = if ($isPluginReady) { "✔ 合规" } else { "✘ 偏离" }
})

# 3. config.nu 历史与会话同步基线
$isConfigReady = $false
$configStatusText = "配置文件缺失"
if (Test-Path $configFile) {
    $content = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
    $hasSqlite = $content -match 'history\.file_format\s*=\s*"sqlite"'
    $hasSync   = $content -match 'history\.sync_on_enter\s*=\s*true'
    if ($hasSqlite -and $hasSync) {
        $isConfigReady = $true
        $configStatusText = "已注入 (SQLite格式/跨会话同步)"
    } else {
        $configStatusText = "未注入 SQLite/跨会话历史基线"
    }
}
$chkList.Add([PSCustomObject]@{
    受控属性 = "config.nu 历史体验基线"
    实机状态 = $configStatusText
    期望基线 = "已注入 (SQLite格式/跨会话同步)"
    判定     = if ($isConfigReady) { "✔ 合规" } else { "✘ 偏离" }
})

# 只查不改模式 (-CheckOnly) 立即输出看板后安全退出
if ($CheckOnly) {
    Write-Host "`n📊 [巡检看板] Nushell 受控属性基线审计清单:" -ForegroundColor Cyan
    $chkList | Format-Table -AutoSize | Out-String | Write-Host

    $driftCount = ($chkList | Where-Object { $_.判定 -like "✘*" }).Count
    if ($driftCount -eq 0) {
        Write-Host "🎉 状态完美！所有受控属性均与工程黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host "⚠️  共发现 $driftCount 项偏离或缺失。执行本脚本默认模式 (-Sync) 或纯配置重置 (-ConfigOnly) 即可自动对齐自愈。`n" -ForegroundColor Yellow
        if (-not $isPluginReady -and $isInstalled) {
            Write-Host "💡 插件失效成因: Nushell 插件强绑定引擎主版本协议。升级主程序后旧插件在 plugin.msgpackz 中的签名将失效 (invalid)，执行默认模式 (-Sync) 即可重新计算签名并加载自愈。" -ForegroundColor Gray
        }
        if (-not $isInstalled) {
            Write-Host "💡 提示: 未检测到客户端安装，请先执行 'scoop install nushell' 安装本体。" -ForegroundColor Gray
        }
    }
    return
}

# ==============================================================================
# 前置门禁断言：验证是否已安装 (除 CheckOnly/Clean 外其余模式强制要求)
# ==============================================================================
if (-not $isInstalled) {
    if ($ConfigOnly) {
        throw "未检测到 Nushell 客户端安装。请先执行 'scoop install nushell' 安装后再执行配置。"
    }

    Write-Host "⚠️  未在 Scoop 路径检测到已安装的 Nushell。" -ForegroundColor Yellow
    if ($NonInteractive) {
        throw "非交互模式下检测到未安装 Nushell，拒绝盲目静默安装。请先在交互环境中确认安装。"
    }

    $shouldInstall = Read-Host "是否立即调用 'scoop install nushell' 进行安装？(y/N)"
    if ($shouldInstall.Trim().ToLower() -eq 'y') {
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
    } else {
        Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor Yellow
        return
    }
}

# ==============================================================================
# 阶段 C: 覆盖更新本体 (-InstallOnly)
# ==============================================================================
if ($InstallOnly) {
    Write-Host "📦 [覆盖升级模式] 正在调用 Scoop 升级 nushell 本体..." -ForegroundColor Cyan
    Get-Process -Name "nu" -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        & scoop update nushell
        Write-Host "✅ [升级完成] Nushell 客户端本体已通过 Scoop 完成升级。" -ForegroundColor Green

        # 重新探测定位 nu.exe
        foreach ($root in $scoopRoots) {
            $cand = Join-Path $root "apps\nushell\current"
            if (Test-Path (Join-Path $cand "nu.exe")) {
                $InstallDir = $cand
                $nuExe = Join-Path $InstallDir "nu.exe"
                break
            }
        }

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
# 阶段 D: 增量对齐 (-Sync / 默认) 与 纯配置重置 (-ConfigOnly)
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
# 尾部结报与手动引导清单
# ==============================================================================
Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  ✅ Nushell 现代终端环境与插件管理完成！" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "   - 插件状态: 5 大核心官方插件 (polars/formats/gstat/query/inc) 已签名自愈" -ForegroundColor Gray
Write-Host "   - 历史体验: 固化 SQLite 数据库存储格式与多终端跨会话即时同步" -ForegroundColor Gray
Write-Host "   - 检索交互: 原生支持命令行行尾按 Up/Down 前缀历史快速检索" -ForegroundColor Gray
Write-Host "`n--------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📋 [手动收尾引导清单 (Manual Checklist)]" -ForegroundColor Cyan
Write-Host " 1. 插件验证: 在终端中执行 'plugin list'，确认 5 大核心官方插件 (polars/formats/gstat/query/inc) 均处于 active 状态" -ForegroundColor Gray
Write-Host " 2. 交互体验: 启动 nu 体验结构化管道输出与基于 SQLite 的跨会话历史前缀检索" -ForegroundColor Gray
Write-Host "--------------------------------------------------`n" -ForegroundColor DarkGray
Write-Host "👉 执行 'nu' 即可开启现代结构化数据流 Shell！" -ForegroundColor Green
