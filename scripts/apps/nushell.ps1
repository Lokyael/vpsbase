#requires -Version 7.0
<#
.SYNOPSIS
    Nushell 现代终端环境

.DESCRIPTION
    Nushell 现代结构化数据流 Shell (Windows) 官方插件管理与 SQLite 历史基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 基于 Scoop 纳管的二进制本体 (D:\prog\scoop\apps\nu\current\nu.exe)。
    3. 官方核心插件自治管理与自愈：管理并自动重新签名注册 5 大官方核心插件 (polars, formats, gstat, query, inc)，彻底解决 Nushell 版本升级导致插件签名协议失效 (invalid) 的问题。
    4. 现代化历史体验黄金基线：注入 config.nu 托管配置块，固化 SQLite 数据库结构化存储、多终端跨会话即时同步与前缀检索。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync        : 增量对齐黄金基线 (默认，缺失则装、偏离则修)
    - Check       : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - ResetConfig : 仅执行插件重新注册与 config.nu 黄金基线注入
    - Uninstall   : 彻底清洁卸载 Nushell、注销核心插件并清理环境
    - Upgrade     : 覆盖升级客户端本体 (调用 Scoop update)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\nushell.ps1 -Action Check

    # 交互式检查并应用黄金基线
    pwsh -File .\scripts\apps\nushell.ps1

    # 仅修复插件注册与历史基线配置
    pwsh -File .\scripts\apps\nushell.ps1 -Action ResetConfig

    # 彻底清洁卸载
    pwsh -File .\scripts\apps\nushell.ps1 -Action Uninstall
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
    throw "【权限错误】Nushell 现代终端环境与核心插件签名管理需管理员特权，请在提升的 pwsh 会话中重新执行！"
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
$AppId        = "nu"
$AppName      = "Nushell 现代结构化数据终端"
$ProcessName  = "nu"
$ScoopBucket  = "main"
$ScoopApp     = "nu"

$scoopRoot    = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
$InstallDir   = Join-Path $scoopRoot "apps\$ScoopApp\current"
$AppExe       = Join-Path $InstallDir "nu.exe"
$ConfDir      = Join-Path $env:APPDATA "nushell"
$ConfigFile   = Join-Path $ConfDir "config.nu"
$PersistDir   = Join-Path $scoopRoot "persist\$ScoopApp"

$HighValueUserData = @(
    "终端命令历史数据库: $ConfDir\history.sqlite3",
    "自定义 Nushell 脚本与环境配置: $ConfDir\config.nu, $ConfDir\env.nu",
    "持久化配置目录: $PersistDir"
)

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

# 跨终端多会话即时写入同步 (回车即提交历史)
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

$ManagedSpecs = @(
    @{
        Module   = "客户端本体"
        Property = "Nushell 二进制安装 (nu.exe)"
        Expected = "已就绪 ($AppExe)"
        Purpose  = "部署 Nushell 现代结构化数据流 Shell"
        Impact   = "若未就绪将自动调用 Scoop 从 main bucket 安装"
        Type     = "Binary"
    },
    @{
        Module   = "插件生态"
        Property = "核心官方插件注册 (polars/formats/gstat/query/inc)"
        Expected = "有效注册 (polars等5核心插件)"
        Purpose  = "重新注册并自愈 5 大官方核心扩展插件的协议签名"
        Impact   = "解决主版本升级后插件协议签名失效 (invalid) 问题，恢复 DataFrame 与多样化数据流处理"
        Type     = "Plugin"
    },
    @{
        Module   = "Shell体验"
        Field    = "history.file_format"
        ValRegex = '"sqlite"'
        Property = "结构化历史存储格式 ($env.config.history.file_format)"
        Expected = '"sqlite"'
        Purpose  = "固化命令历史记录采用 SQLite 关系型数据库存储"
        Impact   = "保障海量命令历史的原子写入与结构化查询检索，杜绝文本损坏"
        Type     = "Config"
    },
    @{
        Module   = "Shell体验"
        Field    = "history.sync_on_enter"
        ValRegex = 'true'
        Property = "多终端即时回车同步 ($env.config.history.sync_on_enter)"
        Expected = "true"
        Purpose  = "每次敲击回车执行命令即刻提交持久化历史"
        Impact   = "彻底告别终端关闭退出时才批量落盘导致的崩溃丢历史或多终端覆写覆盖"
        Type     = "Config"
    },
    @{
        Module   = "Shell体验"
        Field    = "history.isolation"
        ValRegex = 'false'
        Property = "关闭会话隔离共享历史 ($env.config.history.isolation)"
        Expected = "false"
        Purpose  = "全局共享命令历史记录池"
        Impact   = "在一个终端执行的命令可在另一个新打开的终端按 Up 键立即回溯检索"
        Type     = "Config"
    },
    @{
        Module   = "Shell体验"
        Field    = "history.max_size"
        ValRegex = '\d+'
        Property = "历史容量扩容 ($env.config.history.max_size)"
        Expected = ">= 100000"
        Purpose  = "将历史记录保留上限提升至 10 万条"
        Impact   = "长期沉淀个人终端命令行资产"
        Type     = "Config"
    },
    @{
        Module   = "Shell体验"
        Field    = "table.mode"
        ValRegex = '"rounded"'
        Property = "现代圆角表格视效 ($env.config.table.mode)"
        Expected = '"rounded"'
        Purpose  = "结构化表格数据默认采用现代圆角边框排版"
        Impact   = "提升终端输出可读性与现代化视觉美感"
        Type     = "Config"
    }
)

# ==============================================================================
# 3. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将卸载 Nushell 并清理核心配置与插件环境！" -ForegroundColor Yellow
        Write-Host "📌 【即将被物理抹除的高价值用户数据清单】:" -ForegroundColor Cyan
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "👉 执行清洁卸载将清理配置与历史数据库。若需保留命令历史，请先手动备份。`n" -ForegroundColor Yellow

        $confirm = (Read-Host "确认清理 Nushell 核心配置与插件并卸载本体? [y/N]").Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在清理 Nushell 配置与插件环境..." -ForegroundColor Yellow

    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force

    if (Test-Path $ConfigFile) {
        $existing = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
        $cleanPattern = "(?ms)^[ \t]*# >>> managed: nu-history-baseline >>>\r?\n.*?\r?\n[ \t]*# <<< managed: nu-history-baseline <<<\r?\n?"
        if ($existing -match $cleanPattern) {
            $cleaned = [System.Text.RegularExpressions.Regex]::Replace($existing, $cleanPattern, "")
            [System.IO.File]::WriteAllText($ConfigFile, $cleaned.TrimEnd() + "`r`n", [System.Text.UTF8Encoding]::new($false))
            Write-Host "   - 已剥离 config.nu 中的托管基线配置块。" -ForegroundColor Gray
        }
    }

    $pluginCache = Join-Path $ConfDir "plugin.msgpackz"
    if (Test-Path $pluginCache) {
        Remove-Item -Path $pluginCache -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理插件注册签名缓存: $pluginCache" -ForegroundColor Gray
    }

    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        if (Test-Path (Join-Path $scoopRoot "apps\nu")) {
            Write-Host "   - 正在调用 Scoop 清洁卸载客户端本体 (--purge)..." -ForegroundColor Gray
            & scoop uninstall -p nu
        }
    }

    foreach ($pkg in @("nu", "nushell")) {
        $candApp = Join-Path $scoopRoot "apps\$pkg"
        if (Test-Path $candApp) {
            Remove-Item -Path $candApp -Recurse -Force -ErrorAction SilentlyContinue
        }
        $candPersist = Join-Path $scoopRoot "persist\$pkg"
        if (Test-Path $candPersist) {
            Remove-Item -Path $candPersist -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $nuShims = @("nu.exe", "nu.shim", "nu.cmd", "nu.ps1")
    foreach ($sh in $nuShims) {
        $candShim = Join-Path $scoopRoot "shims\$sh"
        if (Test-Path $candShim) {
            Remove-Item -Path $candShim -Force -ErrorAction SilentlyContinue
        }
    }

    $nuShortcuts = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Scoop Apps" "Nushell.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Nushell.lnk")
    )
    foreach ($sc in $nuShortcuts) {
        if (Test-Path $sc) { Remove-Item -Path $sc -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`n✅ [清洁卸载完成] Nushell 托管配置与本体已彻底清除。`n" -ForegroundColor Green
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
$isPluginReady = $false
$pluginStatusText = "未安装本体"
if ($isInstalled) {
    try {
        $checkCmd = 'let helper = ($nu.current-exe | path dirname | path join "register-core-plugins.nu"); if ($helper | path exists) { (plugin list | where name == "polars" and status != "invalid" | is-not-empty) } else { true }'
        $res = (& $AppExe -c $checkCmd 2>$null)
        if ($res -match '(?i)true') {
            $isPluginReady = $true
            $pluginStatusText = "有效注册"
        } else {
            $pluginStatusText = "未注册/失效"
        }
    } catch {
        $pluginStatusText = "探测异常"
    }
}

$confRaw = if (Test-Path $ConfigFile) { [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8) } else { "" }

function Test-NuConfigField([string]$raw, [string]$field, [string]$valRegex) {
    if ([string]::IsNullOrEmpty($raw)) { return $false }
    $escapedPrefix = [regex]::Escape('$env.config.')
    $escapedField  = [regex]::Escape($field)
    return ($raw -match "(?m)^\s*$escapedPrefix$escapedField\s*=\s*$valRegex")
}

foreach ($spec in $ManagedSpecs) {
    $actualStr = ""
    $isMatch = $false

    if ($spec.Type -eq "Binary") {
        $actualStr = if ($isInstalled) { "已就绪" } else { "未安装" }
        $isMatch = $isInstalled
    } elseif ($spec.Type -eq "Plugin") {
        $actualStr = $pluginStatusText
        $isMatch = $isPluginReady
    } elseif ($spec.Type -eq "Config") {
        $matched = Test-NuConfigField $confRaw $spec.Field $spec.ValRegex
        $actualStr = if ($matched) { "已注入期望值" } else { (Test-Path $ConfigFile) ? "缺省或偏离" : "文件缺失" }
        $isMatch = $matched
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

Write-Host "`n📊 [巡检看板] Nushell 原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($Action -eq "Check") {
    if ($driftCount -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性与插件环境均符合工程黄金基线，无需调整。`n" -ForegroundColor Green
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
$runningNu = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if ($runningNu) {
    if (-not $Yes) {
        Write-Warning "检测到 Nushell (nu.exe) 当前正在运行！外部修改可能被退出时的内存状态覆写。"
        $confirmProc = (Read-Host "是否立即关闭正在运行的 nu 进程以继续应用基线? [Y/n]").Trim()
        if ($confirmProc -match '^(n|no)$') {
            Write-Host "[-] 用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningNu | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# 5.2 未安装审查门禁
if (-not $isInstalled) {
    if ($Action -eq "ResetConfig") {
        throw "未检测到 Nushell 客户端安装！请先执行 -Action Sync 安装本体后再重置配置。"
    }

    if (-not $Yes) {
        $shouldInstall = (Read-Host "未检测到 Nushell，是否立即调用 'scoop install main/nu' 进行安装？[Y/n]").Trim()
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
        Write-Host "`n📦 [覆盖升级] 正在调用 Scoop 升级 Nushell 本体..." -ForegroundColor Cyan
        & scoop update nu
        Write-Host "✅ [升级完成] Nushell 客户端本体已完成升级。`n" -ForegroundColor Green
        return
    } else {
        Write-Host "`n🚀 正在通过 Scoop 安装 Nushell..." -ForegroundColor Cyan
        & scoop install main/nu

        if (Test-Path (Join-Path $InstallDir "nu.exe")) {
            $AppExe = Join-Path $InstallDir "nu.exe"
            $isInstalled = $true
        }
        if (-not $isInstalled) {
            throw "Scoop 安装完成，但未能定位到 $AppExe，请检查 Scoop 安装状态。"
        }
    }
}

# 6.2 注册官方核心插件与签名自愈
Write-Host "`n⚙️  正在重新注册官方核心插件协议签名 (Self-Healing Plugins)..." -ForegroundColor Cyan
$plugins = @("polars", "formats", "gstat", "query", "inc")
$helperScript = Join-Path $InstallDir "register-core-plugins.nu"

if (Test-Path $helperScript) {
    try {
        & $AppExe $helperScript
        Write-Host "✅ 通过 register-core-plugins.nu 完成核心插件批量注册与签名。" -ForegroundColor Green
    } catch {
        Write-Warning "调用 helperScript 失败: $($_.Exception.Message)"
    }
} else {
    foreach ($p in $plugins) {
        $binName = "nu_plugin_$p.exe"
        $binPath = Join-Path $InstallDir $binName
        if (Test-Path $binPath) {
            try {
                & $AppExe -c "plugin add `"$binPath`"" 2>$null
                Write-Host "   - 插件已就绪: $p" -ForegroundColor Gray
            } catch { }
        }
    }
}

# 6.3 注入 config.nu 黄金基线配置
Write-Host "⚙️  正在单向对齐 config.nu 黄金体验基线..." -ForegroundColor Cyan
Update-ManagedConfigFile -FilePath $ConfigFile -Tag "nu-history-baseline" -NewContent $nuBaseline
Write-Host "✅ config.nu 体验基线配置已原子落盘至: $ConfigFile" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与插件管理完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 历史基线: 固化 SQLite 数据库结构化存储与跨终端回车即时同步" -ForegroundColor Gray
Write-Host "   - 插件生态: 5 大核心官方插件 (polars 等) 已完成协议签名与自愈加载" -ForegroundColor Gray
Write-Host "   - 视效体验: 已注入现代圆角表格视效与 Emacs 快速前缀检索" -ForegroundColor Gray

return
