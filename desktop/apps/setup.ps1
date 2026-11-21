#requires -Version 7.0
<#
.SYNOPSIS
    工作站核心原生应用生命周期轻聚合编排门面 (Thin Orchestrator Facade)。

.DESCRIPTION
    统筹调度 desktop\apps\ 目录下的自治原生应用脚本。
    - 门面编排与子脚本自治：基于 AST 静态内省自动发现子脚本，门面仅负责发现、粗粒度勾选、参数透传与显式待办收集，不维护影子状态机；
    - 精确匹配应用标识（Exact Match Only），拒绝隐式模糊匹配；
    - 支持正交生命周期模式：Sync (增量对齐)、Check (只读巡检)、Uninstall (退役清理)；
    - 全局免交互放行：-Yes。

.PARAMETER Action
    生命周期操作模式: Sync, Check, Uninstall。缺省时交互选择。

.PARAMETER Apps
    指定执行的应用标识列表 (以逗号分隔，如 'zen-browser,steam' 或 'all')。缺省时交互选择。

.PARAMETER Yes
    免交互全量确认放行开关。

.EXAMPLE
    # 交互引导
    pwsh -File .\desktop\apps\setup.ps1

    # 只读巡检全部应用
    pwsh -File .\desktop\apps\setup.ps1 -Action Check -Apps all

    # 增量对齐指定应用
    pwsh -File .\desktop\apps\setup.ps1 -Action Sync -Apps zen-browser,steam -Yes

    # 清洁卸载指定应用
    pwsh -File .\desktop\apps\setup.ps1 -Action Uninstall -Apps steam
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall", "")]
    [string]$Action = "",

    [string[]]$Apps,

    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ==============================================================================
# 环境校验：PowerShell 7+ 与当前交互用户管理员提权校验
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "本编排门面已全面转向 PowerShell 7+ (pwsh)，不兼容旧版 Windows PowerShell 5.1。请使用 'pwsh' 执行本脚本。"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and $Action -ne "Check") {
    throw "【权限错误】应用生命周期编排涉及系统特权、服务与系统级关联，必须以管理员身份运行！请右键 pwsh 选择 [以管理员身份运行] 后重新执行。"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将受控应用配置与注册表错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

$localCandidates = @(
    @(
        $(if ($PSScriptRoot) { $PSScriptRoot }),
        $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "apps" }),
        (Join-Path $PWD "desktop/apps"),
        (Join-Path $PWD "scripts/apps"),
        (Join-Path $PWD "apps")
    ) | Where-Object { $_ -and (Test-Path $_) }
)

if ($localCandidates.Count -gt 0) {
    $AppsDir = (Get-Item $localCandidates[0]).FullName
} else {
    throw "应用脚本归档目录不存在: 未找到本地 apps 归档目录。"
}

# ==============================================================================
# 阶段 1: 基于契约的静态发现与元数据提取 (Plan - Zero-Cost AST Introspection)
# ==============================================================================
$DiscoveredApps = [ordered]@{}
$scriptFiles = Get-ChildItem -Path $AppsDir -Filter "*.ps1" -File | Where-Object { -not $_.Name.StartsWith('_') -and $_.Name -ne 'setup.ps1' -and $_.Name -ne 'setup-apps.ps1' } | Sort-Object Name

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

    # 校验生命周期核心参数契约支持度 (-Action)
    $paramNames = @()
    if ($ast.ParamBlock -and $ast.ParamBlock.Parameters) {
        $paramNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
    }

    $hasStandardContract = ($paramNames -contains "Action")
    if (-not $hasStandardContract) {
        Write-Warning "子脚本 [$($file.Name)] 未实现生命周期参数契约 (-Action)，已自动过滤。"
        continue
    }

    $DiscoveredApps[$appId] = [PSCustomObject]@{
        Id       = $appId
        Name     = $displayName
        FullName = $file.FullName
        FileLeaf = $file.Name
    }
}

# 基础运行时底座置顶优化 (确保应用全量流水线中优先对齐依赖底座)
if ($DiscoveredApps.Contains("runtimes")) {
    $rtObj = $DiscoveredApps["runtimes"]
    $DiscoveredApps.Remove("runtimes")
    $reordered = [ordered]@{ "runtimes" = $rtObj }
    foreach ($k in $DiscoveredApps.Keys) {
        $reordered[$k] = $DiscoveredApps[$k]
    }
    $DiscoveredApps = $reordered
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

if ($selectedIds.Count -eq 0 -and -not $Yes) {
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
if ([string]::IsNullOrWhiteSpace($Action) -and -not $Yes) {
    Write-Host "`n⚙️  请选择生命周期模式:" -ForegroundColor Cyan
    Write-Host "  [1] 增量对齐受控基线 (Sync)     - 推荐：缺失/版本漂移则装、偏离则修，保留用户数据" -ForegroundColor White
    Write-Host "  [2] 状态体检只读巡检 (Check)    - 只读比对受控属性 Diff，零写入安全退出" -ForegroundColor Green
    Write-Host "  [3] 清洁卸载退役 (Uninstall)    - 调用固定提供者退役本体并清理声明残留 (默认保留数据)" -ForegroundColor Yellow
    Write-Host "  [Q] 退出编排器`n" -ForegroundColor Gray

    $modeChoice = Read-Host "选择操作模式 [默认: 1 (Sync 增量对齐)]"
    if ($modeChoice.Trim().ToUpper() -eq "Q") {
        Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor Yellow
        return
    }
    $Action = switch ($modeChoice.Trim()) {
        "2" { "Check" }
        "3" { "Uninstall" }
        default { "Sync" }
    }
} elseif ([string]::IsNullOrWhiteSpace($Action)) {
    $Action = "Sync"
}

# BCU 自身由 Scoop 退役；仅调整调度顺序，不在门面探测应用状态。
if ($Action -eq 'Uninstall' -and $selectedIds.Contains('bulk-crap-uninstaller')) {
    [void]$selectedIds.Remove('bulk-crap-uninstaller')
    $selectedIds.Add('bulk-crap-uninstaller')
}

Write-Host "`n🎯 编排目标: [ $($selectedIds -join ', ') ] | 执行模式: [ $Action ]`n" -ForegroundColor Green

# ==============================================================================
# 阶段 3: 单向流水线调度 (Apply)
# ==============================================================================
$humanHints = [Collections.Generic.List[object]]::new()
$hasModuleFailure = $false

foreach ($key in $selectedIds) {
    if ($Action -eq 'Uninstall' -and $key -ceq 'bulk-crap-uninstaller' -and $hasModuleFailure) {
        Write-Warning '前序应用卸载失败或未完成，保留 BCU 管理工具；请处理后单独退役。'
        continue
    }
    $app = $DiscoveredApps[$key]
    Write-Host "`n════════════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "▶ 正在调度应用子系统: $($app.Name) [$($app.Id)]" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan

    try {
        $splat = @{ Action = $Action }
        if ($Yes) { $splat["Yes"] = $true }
        & $app.FullName @splat 6>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.InformationRecord]) {
                if ($_.Tags -contains 'HumanHandoff') {
                    $humanHints.Add([pscustomobject]@{ Source = $app.Name; Message = [string]$_.MessageData })
                } elseif ($_.Tags -contains 'PSHOST') {
                    $hostMessage = @{ Object = $_.MessageData.Message; NoNewline = $_.MessageData.NoNewLine }
                    if ($null -ne $_.MessageData.ForegroundColor) { $hostMessage.ForegroundColor = $_.MessageData.ForegroundColor }
                    if ($null -ne $_.MessageData.BackgroundColor) { $hostMessage.BackgroundColor = $_.MessageData.BackgroundColor }
                    Write-Host @hostMessage
                } else {
                    Write-Information -MessageData $_.MessageData -Tags $_.Tags -InformationAction Continue
                }
            } else {
                Write-Output $_
            }
        }
    } catch {
        $hasModuleFailure = $true
        Write-Error "应用 [$($app.Name)] 执行异常: $_" -ErrorAction Continue
    }
}

# ==============================================================================
# 阶段 4: 仅汇集子脚本明确交付的人类待办
# ==============================================================================
if ($humanHints.Count -gt 0) {
    Write-Host "`n📋 [人类待办] 以下提示由对应子脚本交付，不表示执行成功或基线合规：" -ForegroundColor Cyan
    $seenHints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hint in $humanHints) {
        if ($seenHints.Add("$($hint.Source)`n$($hint.Message)")) {
            Write-Host "`n[$($hint.Source)] $($hint.Message)" -ForegroundColor Yellow
        }
    }
}
if ($hasModuleFailure) { throw '应用生命周期调度包含失败模块；请处理实时错误和人类待办后重试。' }
