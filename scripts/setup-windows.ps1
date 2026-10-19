#requires -Version 7.0
<#
.SYNOPSIS
    工作站 Windows 操作系统基线总编排门面 (Thin Orchestrator Facade)。

.DESCRIPTION
    1. 专为 PowerShell 7+ (pwsh) 架构开发，统筹纳管 scripts\windows\ 目录下的独立自闭合系统加固模块。
    2. 践行门面编排与子模块自治原则：
       - 基于 AST 静态内省自动发现 scripts\windows\ 下符合契约规范的模块脚本，零运行时黑盒探针；
       - 受控属性逐项巡检与落盘完全内聚于子模块内部，门面仅负责发现、粗粒度勾选、参数透传调度与全局流水线汇总；
       - 严格精确匹配模块标识（Exact Match Only），拒绝隐式猜测，保障基础设施操作的 100% 确定性。
    3. 支持系统加固正交二要素：
       - 操作意图 (Action)  : Sync (增量对齐收敛/默认) 或 Check (只查不改/体检巡检)；
       - 加固预设 (Profile) : Full (全量工程基线/默认) 或 General (通用基线，跳过深度裁剪项)。
    4. 审查门禁：默认逐模块交互确认；亦支持 -Yes 免交互全量流水线。
    5. 内置远程一键执行适配层 (Remote Fallback)，在 irm ... | iex 无落盘内存态下自动拉取子模块执行并自愈销毁临时目录。

.PARAMETER Action
    指定生命周期模式，可选值: Sync (执行加固), Check (只查不改/体检巡检)。默认交互选择。

.PARAMETER Profile
    指定配置预设，可选值: Full (全量工程基线), General (通用基线)。默认交互选择。

.PARAMETER Modules
    指定要执行的模块标识列表 (以逗号分隔，如 'telemetry,shell' 或 'all')。默认全量有序调度。

.PARAMETER Yes
    免交互全量确认放行开关。跳过模块审查交互，直接全量执行指定基线。

.EXAMPLE
    # 交互式全流程引导 (自动发现大盘 -> 模式决策 -> 调度自治执行)
    pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1

    # 全量工程基线加固 (应用全量受控规则)
    pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile Full -Yes

    # 通用基线加固 (仅应用通用项)
    pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile General -Yes

    # 只读全量巡检体检 (绝不修改任何系统配置)
    pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Action Check

    # 仅定向巡检/加固外壳与性能底层
    pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Modules shell,performance
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "")]
    [string]$Action = "",

    [ValidateSet("Full", "General", "")]
    [string]$Profile = "",

    [string[]]$Modules,

    [switch]$Yes
)

$ErrorActionPreference = "Continue"

# ==============================================================================
# 1. 执行环境硬门禁 (严格限定 PowerShell 7+，杜绝旧版 5.1)
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host -ForegroundColor Red '【版本错误】此脚本针对 PowerShell 7 (pwsh) 现代运行时深度定制，严禁在 Windows PowerShell 5.1 下执行！'
    Write-Host -ForegroundColor Yellow '请启动 PowerShell 7 终端 (pwsh.exe) 后重新运行此脚本。'
    return
}

# ==============================================================================
# 2. 权限自检 (RID 544 即 BUILTIN\Administrators 管理员组)
# ==============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin) {
    Write-Host -ForegroundColor Red '【权限错误】此脚本必须以管理员身份运行！请右键 pwsh 选择 [以管理员身份运行] 后重新执行。'
    return
}

# ==============================================================================
# 3. 跨账号提权防范校验 (防范在受限多用户环境下将 HKCU 写入错误账户)
# ==============================================================================
$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
if ($rawConsoleUser) {
    $consoleUser = ($rawConsoleUser -replace '.*\\') ?? $currentUser
    if ($currentUser -ne $consoleUser) {
        Write-Warning "【跨账号提权警告】当前桌面登录用户为 [$consoleUser]，但当前管理员终端身份为 [$currentUser]！"
        Write-Warning "继续执行会导致当前用户 (HKCU) 优化配置写入 [$currentUser] 账户，而非当前桌面用户。"
        if ($Yes) {
            Write-Host -ForegroundColor Red '【自动化模式阻断】检测到跨账号提权状态，已自动终止任务以保护账户环境。'
            return
        }
        $ans = Read-Host "是否仍要强行继续？(y/N)"
        if ($ans -ne 'y') { return }
    }
}

# ==============================================================================
# 4. 定位模块目录 (本地对应路径优先，无本地脚本则拉取至临时沙盒)
# ==============================================================================
$WindowsDir = $null
$TempSandboxDir = $null

$localCandidates = @(
    $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "windows" }),
    (Join-Path $PWD "scripts\windows"),
    (Join-Path $PWD "windows")
) | Where-Object { $_ -and (Test-Path $_) }

if ($localCandidates.Count -gt 0) {
    $WindowsDir = (Get-Item $localCandidates[0]).FullName
} else {
    Write-Host "[*] 本地未检测到模块目录，正在并发拉取子模块至临时沙盒..." -ForegroundColor Cyan
    $TempSandboxDir = Join-Path $env:TEMP ("vpsbase-setup-" + [Guid]::NewGuid().ToString("N"))
    $targetWinDir = Join-Path $TempSandboxDir "windows"
    New-Item -ItemType Directory -Path $targetWinDir -Force | Out-Null

    $remoteBaseUrl = $env:VPSBASE_REMOTE_BASE ?? "https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/windows"
    $moduleList = @("telemetry", "shell", "search", "services", "network", "components", "performance")

    $downloadErrors = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $base = $remoteBaseUrl
    $destDir = $targetWinDir
    $errBag = $downloadErrors
    $moduleList | ForEach-Object -Parallel {
        $mName = $_
        $url = "$using:base/$mName.ps1"
        $dest = Join-Path $using:destDir "$mName.ps1"
        try {
            Invoke-RestMethod -Uri $url -OutFile $dest -TimeoutSec 15
        } catch {
            $bag = $using:errBag
            $bag.Add("$mName.ps1: $($_.Exception.Message)")
        }
    }

    if ($downloadErrors.Count -gt 0) {
        throw "拉取子模块失败 ($($downloadErrors.Count) 项异常):`n" + ($downloadErrors -join "`n")
    }

    $WindowsDir = $targetWinDir
}

if (-not (Test-Path -Path $WindowsDir -PathType Container)) {
    throw "系统加固模块归档目录不存在: [$WindowsDir]。"
}

try {
    # ==============================================================================
    # 5. 基于 AST 静态内省自动发现模块 (Zero-Cost AST Introspection)
    # ==============================================================================
    $CanonicalOrder = @("telemetry", "shell", "search", "services", "network", "components", "performance")
    $DiscoveredModules = [ordered]@{}

    foreach ($mId in $CanonicalOrder) {
        $file = Join-Path $WindowsDir "$mId.ps1"
        if (-not (Test-Path $file)) { continue }

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)

        if ($errors -and $errors.Count -gt 0) {
            Write-Warning "子模块 [$mId.ps1] 存在语法解析错误，已跳过。"
            continue
        }

        # 校验系统加固模块正交参数契约支持度 (-Action / -Profile)
        $paramNames = @()
        if ($ast.ParamBlock -and $ast.ParamBlock.Parameters) {
            $paramNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        }

        $hasStandardContract = ($paramNames -contains "Action") -and ($paramNames -contains "Profile")
        if (-not $hasStandardContract) {
            Write-Warning "子模块 [$mId.ps1] 未完整实现系统加固正交参数契约 (-Action / -Profile)，已跳过。"
            continue
        }

        # 提取 .SYNOPSIS 首行作为展示名称
        $displayName = $mId
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

        $DiscoveredModules[$mId] = [PSCustomObject]@{
            Id       = $mId
            Name     = $displayName
            FullName = $file
            FileLeaf = "$mId.ps1"
        }
    }

    # ==============================================================================
    # 6. 解析受控模块切片 (严格精确匹配 Exact Match)
    # ==============================================================================
    $TargetModules = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($Modules) {
        $flattened = @($Modules | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
        if ($flattened -contains 'all') {
            foreach ($m in $DiscoveredModules.Values) { $TargetModules.Add($m) }
        } else {
            foreach ($req in $flattened) {
                if ($DiscoveredModules.Contains($req)) {
                    $TargetModules.Add($DiscoveredModules[$req])
                } else {
                    throw "未知的系统加固模块标识: [$req]。支持的模块列表: $($DiscoveredModules.Keys -join ', ')"
                }
            }
        }
    } else {
        foreach ($m in $DiscoveredModules.Values) { $TargetModules.Add($m) }
    }

    # ==============================================================================
    # 7. 第一阶段：大盘总览 (Plan)
    # ==============================================================================
    Write-Host "=================== Windows 11 全量系统基线巡检 (pwsh 7+) ===================" -ForegroundColor Cyan
    Write-Host "[*] 正在准备纳管调度，请稍候...`n" -ForegroundColor DarkGray

    Write-Host "┌── [系统模块纳管大盘] ────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    $idx = 1
    foreach ($m in $TargetModules) {
        Write-Host ("│ [{0}] [基线] {1,-16} : {2,-40} │" -f $idx, $m.Id, $m.Name) -ForegroundColor White
        $idx++
    }
    Write-Host "└──────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan

    # 交互式模块切片勾选 (若未传 -Modules 且非静默模式)
    if ($null -eq $Modules -and -not $Yes) {
        Write-Host "`n💡 请选择要纳入本次调度的系统模块 [直接回车全选]:" -ForegroundColor Cyan
        Write-Host "   - 输入序号多选 (例如: 1,2,5)" -ForegroundColor Gray
        Write-Host "   - 直接回车调度全量 7 大模块" -ForegroundColor Gray
        Write-Host "   - 输入 'Q' 退出`n" -ForegroundColor Gray

        $modChoice = (Read-Host "选择要调度的模块编号 [默认: 全部调度]").Trim()
        if ($modChoice -match '^[Qq]$') {
            Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor DarkGray
            return
        } elseif (-not [string]::IsNullOrWhiteSpace($modChoice) -and $modChoice.ToUpper() -ne "A" -and $modChoice.ToLower() -ne "all") {
            $TargetModules.Clear()
            $indices = @($modChoice.Split(',') | ForEach-Object { $_.Trim() })
            foreach ($idxStr in $indices) {
                if ($idxStr -match '^\d+$') {
                    $pickedIdx = [int]$idxStr
                    if ($pickedIdx -ge 1 -and $pickedIdx -le $CanonicalOrder.Count) {
                        $pickedKey = $CanonicalOrder[$pickedIdx - 1]
                        if ($DiscoveredModules.Contains($pickedKey)) {
                            $TargetModules.Add($DiscoveredModules[$pickedKey])
                        }
                    }
                }
            }
            if ($TargetModules.Count -eq 0) {
                Write-Warning "未选定任何有效模块，编排器退出。"
                return
            }
        }
    }

    # ==============================================================================
    # 8. 第二阶段：模式决策 (Gate & Profile Decision)
    # ==============================================================================
    if ([string]::IsNullOrWhiteSpace($Action)) {
        if ($Yes) {
            $Action = "Sync"
            if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = "Full" }
        } else {
            Write-Host "`n=========================== 请选择配置执行模式 ===========================" -ForegroundColor Cyan
            Write-Host "  [1] 全量模式 (免交互: 7 大领域全量工程基线加固)" -ForegroundColor White
            Write-Host "  [2] 通用模式 (免交互: 7 大领域通用基线加固，跳过深度裁剪项)" -ForegroundColor White
            Write-Host "  [3] 逐块审查模式 (全交互 [默认回车]: 逐模块展示待优化项，交互确认执行)" -ForegroundColor White
            Write-Host "  [4] 只查不改模式 (体检巡检: 预览全部模块待加固项明细，绝不触碰系统)" -ForegroundColor White
            Write-Host "  [Q] 退出脚本 (不执行任何命令)" -ForegroundColor DarkGray
            Write-Host "--------------------------------------------------------------------------" -ForegroundColor Cyan
            Write-Host -NoNewline "请输入执行模式编号 [1/2/3/4/Q] (直接回车默认 [3] 逐块审查全交互): " -ForegroundColor Yellow

            $inputChoice = (Read-Host).Trim()
            switch ($inputChoice) {
                '1' {
                    $Action = "Sync"
                    $Profile = "Full"
                    $Yes = $true
                    Write-Host "  [+] 已选择: 全量模式 (Profile: Full, 免交互自动确认)" -ForegroundColor Green
                }
                '2' {
                    $Action = "Sync"
                    $Profile = "General"
                    $Yes = $true
                    Write-Host "  [+] 已选择: 通用模式 (Profile: General, 免交互自动确认)" -ForegroundColor Cyan
                }
                '4' {
                    $Action = "Check"
                    $Profile = "Full"
                    Write-Host "  [+] 已选择: 只查不改体检巡检模式" -ForegroundColor White
                }
                { $_ -match '^[Qq]' } {
                    Write-Host "[-] 用户取消操作，脚本安全退出。" -ForegroundColor DarkGray
                    return
                }
                Default {
                    $Action = "Sync"
                    $Profile = "Full"
                    $Yes = $false
                    Write-Host "  [+] 已选择: 逐块审查全交互模式 (默认)" -ForegroundColor White
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        $Profile = "Full"
    }

    # ==============================================================================
    # 9. 第三阶段：调度各模块自治执行 (Apply & Orchestration)
    # ==============================================================================
    Write-Host "`n======================= 开始流水线调度系统模块加固 =======================" -ForegroundColor Cyan
    Write-Host ("  [执行参数] 操作意图: {0} | 配置预设: {1} | 交互放行: {2}`n" -f $Action, $Profile, ($Yes ? "自动确认 (-Yes)" : "交互审查")) -ForegroundColor DarkGray

    $executionReport = [System.Collections.Generic.List[PSCustomObject]]::new()
    $moduleExecuted = 0
    foreach ($mod in $TargetModules) {
        $moduleExecuted++
        Write-Host ("`n▶ [{0}/{1}] 调度模块: {2} ({3})" -f $moduleExecuted, $TargetModules.Count, $mod.Name, $mod.Id) -ForegroundColor Yellow

        $subParams = @{
            Action  = $Action
            Profile = $Profile
        }
        if ($Yes) { $subParams["Yes"] = $true }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            & $mod.FullName @subParams
            $sw.Stop()

            $executionReport.Add([PSCustomObject]@{
                模块名称 = $mod.Name
                模块标识 = $mod.Id
                操作意图 = $Action
                执行预设 = $Profile
                执行耗时 = "$([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
                状态     = "✔ 成功"
            })
        } catch {
            $sw.Stop()
            Write-Error "子模块 [$($mod.Id)] 执行异常: $($_.Exception.Message)"
            $executionReport.Add([PSCustomObject]@{
                模块名称 = $mod.Name
                模块标识 = $mod.Id
                操作意图 = $Action
                执行预设 = $Profile
                执行耗时 = "$([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
                状态     = "✘ 失败"
            })
        }
    }

    # 统一自愈重启资源管理器
    if ($Action -eq "Sync") {
        Write-Host "`n[*] 正在重启资源管理器使系统外壳与个性化配置即刻生效..." -ForegroundColor Cyan
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }

    # ==============================================================================
    # 10. 第四阶段：尾部简报汇总 (Report)
    # ==============================================================================
    Write-Host "`n====================================================================" -ForegroundColor Green
    Write-Host "                      系统加固最终执行简报                        " -ForegroundColor Green
    Write-Host "====================================================================" -ForegroundColor Green
    $executionReport | Format-Table -Property 模块名称, 模块标识, 操作意图, 执行预设, 执行耗时, 状态 -AutoSize

} finally {
    if ($TempSandboxDir -and (Test-Path $TempSandboxDir)) {
        Remove-Item -Path $TempSandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
