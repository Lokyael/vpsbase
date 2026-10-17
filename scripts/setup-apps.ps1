#requires -Version 7.0
<#
.SYNOPSIS
    工作站核心原生应用生命周期轻聚合编排门面 (Thin Orchestrator Facade)。

.DESCRIPTION
    1. 专为 PowerShell 7+ (pwsh) 打造，统筹纳管 scripts\apps\ 目录下的独立自闭合原生应用脚本。
    2. 践行门面编排与子脚本自治原则：
       - 基于 AST 静态内省自动发现 scripts\apps\ 下符合契约规范的子脚本，零运行时黑盒探针；
       - 应用私有配置、逐项 Diff 与收尾清单完全内聚于子脚本内部，门面仅负责发现、粗粒度勾选与参数透传调度；
       - 严格精确匹配应用标识（Exact Match Only），拒绝隐式前缀猜测，保障基础设施操作的 100% 确定性。
    3. 与包管理器的协同契约：
       - 纳管对象涵盖 D:\prog\<app> 独立原生维护应用，以及具备系统特权提权（免 UAC 计划任务）、TUN 网络集成或运行态并发保护的 Scoop 增强应用；
       - 针对 Scoop 托管的应用，恪守“二进制版本迭代委托 Scoop 原生管道、配置持久化尊重 persist 规范、系统提权与基线巡检由子脚本自治闭环”的协同契约。
    4. 支持现代正交生命周期操作模式与复合编排：
       - Sync (增量对齐/默认): 缺失则安装，偏离则单向修复，保留既有用户数据；
       - ConfigOnly (纯配置重置): 本体不动，强制将受控策略、注册表与软链接重写为黄金基线；
       - Uninstall (彻底清洁卸载): 终止进程，注销系统关联与快捷方式，抹除软件目录与数据；
       - Reinstall (深度清洁重装): 双阶流水线编排——先调用 Uninstall 彻底抹除，再调用 Sync 全新构建；
       - CheckOnly (状态体检巡检): 逐项比对所有受控属性，高亮输出 Diff，零写入安全退出；
       - InstallOnly (覆盖升级本体): 仅解包覆盖程序本体，不重写配置。

.PARAMETER Mode
    指定全局生命周期模式，可选值: Sync, ConfigOnly, Uninstall, Reinstall, CheckOnly, InstallOnly。默认交互选择。

.PARAMETER Apps
    指定要执行的应用标识列表 (以逗号分隔，如 'zen-browser,steam' 或 'all')。默认交互选择。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线 (适用于全新装机自动化流水线)。

.EXAMPLE
    # 交互式全流程引导 (自动发现大盘 -> 序号勾选应用 -> 选模式 -> 调度自治执行)
    pwsh -File .\scripts\setup-apps.ps1

    # 只查不改体检巡检全量应用
    pwsh -File .\scripts\setup-apps.ps1 -Mode CheckOnly -Apps all

    # 静默增量对齐 Zen Browser 与 Steam
    pwsh -File .\scripts\setup-apps.ps1 -Mode Sync -Apps zen-browser,steam -NonInteractive

    # 深度清洁重装指定应用 (双阶自动流转: 先彻底卸载，再全新构建)
    pwsh -File .\scripts\setup-apps.ps1 -Mode Reinstall -Apps zen-browser

    # 彻底清洁卸载指定应用 (下线退役并扫除一切关联)
    pwsh -File .\scripts\setup-apps.ps1 -Mode Uninstall -Apps steam
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "ConfigOnly", "Uninstall", "Reinstall", "CheckOnly", "InstallOnly", "")]
    [string]$Mode = "",

    [string[]]$Apps,

    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ==============================================================================
# 环境校验：强制锁定 PowerShell 7+
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "本编排门面已全面转向 PowerShell 7+ (pwsh)，不兼容旧版 Windows PowerShell 5.1。请使用 'pwsh' 执行本脚本。"
}

$localCandidates = @(
    $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "apps" }),
    (Join-Path $PWD "scripts/apps"),
    (Join-Path $PWD "apps")
) | Where-Object { $_ -and (Test-Path $_) }

if ($localCandidates.Count -gt 0) {
    $AppsDir = (Get-Item $localCandidates[0]).FullName
} else {
    throw "应用脚本归档目录不存在: 未找到本地 apps 归档目录。"
}

# ==============================================================================
# 阶段 1: 基于契约的静态发现与元数据提取 (Plan - Zero-Cost AST Introspection)
# ==============================================================================
$DiscoveredApps = [ordered]@{}
$scriptFiles = Get-ChildItem -Path $AppsDir -Filter "*.ps1" -File | Sort-Object Name

foreach ($file in $scriptFiles) {
    $appId = $file.BaseName.ToLower()

    # 使用 PowerShell 7+ 原生 AST 解析器，零执行、零副作用提取元数据与参数契约
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        Write-Warning "子脚本 [$($file.Name)] 存在语法解析错误，跳过该项。"
        continue
    }

    # 从注释 Token 中高精度提取 .SYNOPSIS 首行作为展示名称
    $displayName = $appId
    $commentTokens = @($tokens | Where-Object { $_.Kind -eq "Comment" })
    foreach ($c in $commentTokens) {
        if ($c.Text -match '(?ms)\.SYNOPSIS\s*\r?\n\s*(.*?)(?=\r?\n\s*\.[A-Z]+|\r?\n\s*#>)') {
            $firstLine = ($matches[1].Trim() -split '\r?\n')[0].Trim()
            if (-not [string]::IsNullOrWhiteSpace($firstLine)) {
                $displayName = $firstLine
                break
            }
        }
    }

    # 校验五大正交参数契约支持度
    $paramNames = @()
    if ($ast.ParamBlock -and $ast.ParamBlock.Parameters) {
        $paramNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
    }

    $hasStandardContract = ($paramNames -contains "CheckOnly") -and ($paramNames -contains "Uninstall")
    if (-not $hasStandardContract) {
        Write-Warning "子脚本 [$($file.Name)] 未完整实现生命周期正交参数契约 (-CheckOnly / -Uninstall)，已自动过滤。"
        continue
    }

    $DiscoveredApps[$appId] = [PSCustomObject]@{
        Id       = $appId
        Name     = $displayName
        FullName = $file.FullName
        FileLeaf = $file.Name
    }
}

$allAppIds = @($DiscoveredApps.Keys)
if ($allAppIds.Count -eq 0) {
    throw "未在 [$AppsDir] 下发现任何符合规范契约的应用子脚本。"
}

# ==============================================================================
# 辅助函数：严格精确应用标识校验 (Exact Match Only)
# ==============================================================================
function Resolve-AppId {
    param(
        [string]$InputKey,
        [string[]]$AvailableIds
    )

    $key = $InputKey.Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($key)) { return $null }

    # 100% 精确匹配 (Exact Match Only)，严禁模糊推测或隐式前缀匹配
    if ($AvailableIds -contains $key) {
        return $key
    }

    throw "未找到匹配标识 [-Apps $InputKey] 的受控应用。当前可用应用: [$($AvailableIds -join ', ')]。"
}

# ==============================================================================
# 阶段 2: 交互式审查门禁与模式选择 (Gate)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Yellow
Write-Host "   工作站核心原生应用轻聚合编排门面 (Thin Orchestrator pwsh 7+)  " -ForegroundColor Yellow
Write-Host "====================================================================" -ForegroundColor Yellow

$StatusBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$index = 1
foreach ($k in $allAppIds) {
    $item = $DiscoveredApps[$k]
    $StatusBoard.Add([PSCustomObject]@{
        序号     = $index
        应用标识 = $item.Id
        描述名称 = $item.Name
        物理脚本 = $item.FileLeaf
    })
    $index++
}
$StatusBoard | Format-Table -AutoSize

$selectedIds = [System.Collections.Generic.List[string]]::new()

# 1. 判定目标应用范围
if ($null -ne $Apps -and $Apps.Count -gt 0) {
    $rawKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Apps) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            foreach ($sub in $entry.Split(',')) {
                $trimmed = $sub.Trim()
                if ($trimmed) { $rawKeys.Add($trimmed) }
            }
        }
    }

    if ($rawKeys -contains "all" -or $rawKeys -contains "*") {
        foreach ($k in $allAppIds) { $selectedIds.Add([string]$k) }
    } else {
        foreach ($s in $rawKeys) {
            $resolved = Resolve-AppId -InputKey $s -AvailableIds $allAppIds
            if ($resolved -and -not $selectedIds.Contains($resolved)) {
                $selectedIds.Add($resolved)
            }
        }
    }
}

if ($selectedIds.Count -eq 0 -and -not $NonInteractive) {
    Write-Host "💡 请选择要纳入本次编排的应用:" -ForegroundColor Cyan
    Write-Host "   - 输入序号多选 (例如: 1,3)" -ForegroundColor Gray
    Write-Host "   - 输入 'A' 或 'all' 选中全量应用" -ForegroundColor Gray
    Write-Host "   - 输入 'Q' 退出`n" -ForegroundColor Gray

    $inputChoice = Read-Host "选择要处理的软件 [默认: A 全选]"
    if ([string]::IsNullOrWhiteSpace($inputChoice) -or $inputChoice.Trim().ToUpper() -eq "A" -or $inputChoice.Trim().ToLower() -eq "all") {
        foreach ($k in $allAppIds) { $selectedIds.Add([string]$k) }
    } elseif ($inputChoice.Trim().ToUpper() -eq "Q") {
        Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor Yellow
        return
    } else {
        $indices = @($inputChoice.Split(',') | ForEach-Object { $_.Trim() })
        foreach ($idxStr in $indices) {
            if ($idxStr -match '^\d+$') {
                $idx = [int]$idxStr
                if ($idx -ge 1 -and $idx -le $allAppIds.Count) {
                    $picked = $allAppIds[$idx - 1]
                    if (-not $selectedIds.Contains($picked)) {
                        $selectedIds.Add($picked)
                    }
                }
            }
        }
    }
} elseif ($selectedIds.Count -eq 0) {
    foreach ($k in $allAppIds) { $selectedIds.Add([string]$k) }
}

if ($selectedIds.Count -eq 0) {
    Write-Warning "未选定任何有效应用，编排器退出。"
    return
}

# 2. 判定生命周期操作模式
if ([string]::IsNullOrWhiteSpace($Mode) -and -not $NonInteractive) {
    Write-Host "`n⚙️  请选择要执行的通用生命周期模式:" -ForegroundColor Cyan
    Write-Host "  [1] 增量对齐 (Sync)          - 推荐：缺失则装、偏离则修，保留用户数据" -ForegroundColor White
    Write-Host "  [2] 纯配置重置 (ConfigOnly)   - 强制回正策略、注册表与软链为黄金基线" -ForegroundColor White
    Write-Host "  [3] 彻底清洁卸载 (Uninstall) - 终止进程、注销系统关联并抹除软件与数据" -ForegroundColor Yellow
    Write-Host "  [4] 深度清洁重装 (Reinstall) - 双阶流水线：先清洁卸载抹除，再全新构建基线" -ForegroundColor Magenta
    Write-Host "  [5] 状态体检巡检 (CheckOnly)  - 100% 只读比对所有配置项 Diff，零写入安全退出" -ForegroundColor Green
    Write-Host "  [6] 覆盖升级程序 (InstallOnly)- 重新解包/升级程序本体，绝不触碰用户数据" -ForegroundColor White
    Write-Host "  [Q] 退出编排器`n" -ForegroundColor Gray

    $modeChoice = Read-Host "选择操作模式 [默认: 1 (Sync 增量对齐)]"
    if ($modeChoice.Trim().ToUpper() -eq "Q") {
        Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor Yellow
        return
    }
    $Mode = switch ($modeChoice.Trim()) {
        "2" { "ConfigOnly" }
        "3" { "Uninstall" }
        "4" { "Reinstall" }
        "5" { "CheckOnly" }
        "6" { "InstallOnly" }
        default { "Sync" }
    }
} elseif ([string]::IsNullOrWhiteSpace($Mode)) {
    $Mode = "Sync"
}

Write-Host "`n🚀 编排目标锁定: [ $($selectedIds -join ', ') ] | 执行模式: [ $Mode ]`n" -ForegroundColor Green

# ==============================================================================
# 阶段 3: 单向流水线调度 (Apply)
# ==============================================================================
$executionReport = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($key in $selectedIds) {
    $app = $DiscoveredApps[$key]
    Write-Host "`n════════════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "▶ 正在调度应用子系统: $($app.Name) [$($app.Id)]" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Mode -eq "Reinstall") {
            Write-Host "  ▶ [流水线 1/2] 正在彻底清洁卸载: $($app.Name)..." -ForegroundColor Yellow
            $uninstSplat = @{ Uninstall = $true }
            if ($NonInteractive) { $uninstSplat["NonInteractive"] = $true }
            & $app.FullName @uninstSplat

            Write-Host "`n  ▶ [流水线 2/2] 正在全新装配黄金基线: $($app.Name)..." -ForegroundColor Cyan
            $syncSplat = @{}
            if ($NonInteractive) { $syncSplat["NonInteractive"] = $true }
            & $app.FullName @syncSplat
        } else {
            $splat = @{}
            if ($NonInteractive) { $splat["NonInteractive"] = $true }
            switch ($Mode) {
                "ConfigOnly"  { $splat["ConfigOnly"]  = $true }
                "InstallOnly" { $splat["InstallOnly"] = $true }
                "Uninstall"   { $splat["Uninstall"]   = $true }
                "CheckOnly"   { $splat["CheckOnly"]   = $true }
            }
            & $app.FullName @splat
        }
        $sw.Stop()

        $executionReport.Add([PSCustomObject]@{
            应用名称 = $app.Name
            应用标识 = $app.Id
            执行模式 = $Mode
            执行耗时 = "$([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
            状态     = "✔ 成功"
        })
    } catch {
        $sw.Stop()
        Write-Error "应用 [$($app.Name)] 执行异常: $_"
        $executionReport.Add([PSCustomObject]@{
            应用名称 = $app.Name
            应用标识 = $app.Id
            执行模式 = $Mode
            执行耗时 = "$([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
            状态     = "✘ 失败"
        })
    }
}

# ==============================================================================
# 阶段 4: 汇报阶段 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "                      编排流水线最终执行简报                        " -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green

$executionReport | Format-Table -Property 应用名称, 应用标识, 执行模式, 执行耗时, 状态 -AutoSize
