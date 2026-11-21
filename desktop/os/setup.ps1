#requires -Version 7.0
<#
.SYNOPSIS
    工作站 Windows 操作系统基线总编排门面 (Thin Orchestrator Facade)。

.DESCRIPTION
    1. 专为 PowerShell 7+ (pwsh) 架构开发，统筹纳管 desktop\os\modules\ 目录下的独立自闭合系统加固模块。
    2. 践行门面编排与子模块自治原则：
       - 基于 AST 静态内省自动发现 desktop\os\modules\ 下符合契约规范的模块脚本，零运行时黑盒探针；
       - 受控属性逐项巡检、落盘与人类待办由子模块定义，门面仅负责发现、粗粒度勾选、参数透传与显式待办收集，不生成执行状态或耗时简报；
       - 严格精确匹配模块标识（Exact Match Only），拒绝隐式猜测，保障基础设施操作确定性。
    3. 仅维护一条系统基线，面向新装与已使用系统，精简不使用的功能和软件并统一系统配置；
       操作意图 (Action) 为 Sync (增量对齐收敛/默认) 或 Check (只查不改/体检巡检)。
    4. 审查门禁：默认逐模块交互确认；亦支持 -Yes 免交互全量流水线。
    5. 内置远程一键执行适配层 (Remote Fallback)，在 irm ... | iex 无落盘内存态下自动拉取子模块执行并自愈销毁临时目录。

.PARAMETER Action
    指定操作，可选值: Sync (增量对齐基线/默认), Check (只查不改/体检巡检)。

.PARAMETER Modules
    指定要执行的模块标识列表 (以逗号分隔，如 'telemetry,shell' 或 'all')。默认全量有序调度。

.PARAMETER Yes
    免交互全量确认放行开关。跳过模块审查交互，直接全量执行指定基线。

.EXAMPLE
    # 交互式模块选择与逐模块审查
    pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1

    # 免交互收敛全量系统基线
    pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1 -Yes

    # 只读全量巡检体检 (绝不修改任何系统配置)
    pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1 -Action Check

    # 仅定向巡检/加固外壳与性能底层
    pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1 -Modules shell,performance
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check")]
    [string]$Action = "Sync",

    [string[]]$Modules,

    [switch]$Yes
)

$ErrorActionPreference = "Continue"

# ==============================================================================
# 1. 执行环境硬门禁 (严格限定 PowerShell 7+，不支持旧版 5.1)
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw '【版本错误】此脚本针对 PowerShell 7 (pwsh) 现代运行时深度定制，严禁在 Windows PowerShell 5.1 下执行！'
}

# ==============================================================================
# 2. 权限自检 (RID 544 即 BUILTIN\Administrators 管理员组)
# ==============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and $Action -ne "Check") {
    throw '【权限错误】此脚本必须以管理员身份运行！请右键 pwsh 选择 [以管理员身份运行] 后重新执行。'
}

# ==============================================================================
# 3. 跨账号提权防范校验 (防范在受限多用户环境下将 HKCU 写入错误账户)
# ==============================================================================
$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】当前终端运行身份 [$currentUser] 与桌面登录用户 [$consoleUser] 不一致！为防止将受控配置与注册表 (HKCU) 错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

# ==============================================================================
# 4. 定位模块目录 (本地对应路径优先，无本地脚本则拉取至临时沙盒)
# ==============================================================================
$WindowsDir = $null
$TempSandboxDir = $null

try {
    $localCandidates = @(
        @(
            $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "modules" }),
            $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "windows" }),
            (Join-Path $PWD "desktop\os\modules"),
            (Join-Path $PWD "modules"),
            (Join-Path $PWD "scripts\windows"),
            (Join-Path $PWD "windows")
        ) | Where-Object { $_ -and (Test-Path $_) }
    )

    if ($localCandidates.Count -gt 0) {
        $WindowsDir = (Get-Item $localCandidates[0]).FullName
    } else {
        Write-Host "[*] 本地未检测到模块目录，正在并发拉取子模块至临时沙盒..." -ForegroundColor Cyan
        $TempSandboxDir = Join-Path $env:TEMP ("vpsbase-setup-" + [Guid]::NewGuid().ToString("N"))
        $targetWinDir = Join-Path $TempSandboxDir "windows"
        New-Item -ItemType Directory -Path $targetWinDir -Force | Out-Null

        $remoteBaseUrl = $env:VPSBASE_REMOTE_BASE ?? "https://raw.githubusercontent.com/Lokyael/vpsbase/main/desktop/os/modules"
        if ($remoteBaseUrl -notmatch '^https://') {
            throw "远程源地址必须使用安全 HTTPS 传输通道: [$remoteBaseUrl]。"
        }
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

        # 校验系统基线模块参数契约 (-Action / -Yes)
        $paramNames = @()
        if ($ast.ParamBlock -and $ast.ParamBlock.Parameters) {
            $paramNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        }

        $hasStandardContract = ($paramNames -contains "Action") -and ($paramNames -contains "Yes")
        if (-not $hasStandardContract) {
            Write-Warning "子模块 [$mId.ps1] 未完整实现系统基线参数契约 (-Action / -Yes)，已跳过。"
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
                    $mod = $DiscoveredModules[$req]
                    if (-not $TargetModules.Contains($mod)) {
                        $TargetModules.Add($mod)
                    }
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
            $displayedList = @($TargetModules)
            $TargetModules.Clear()
            $indices = @($modChoice.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            foreach ($idxStr in $indices) {
                if ($idxStr -match '^\d+$') {
                    $pickedIdx = [int]$idxStr
                    if ($pickedIdx -ge 1 -and $pickedIdx -le $displayedList.Count) {
                        $candidate = $displayedList[$pickedIdx - 1]
                        if (-not $TargetModules.Contains($candidate)) {
                            $TargetModules.Add($candidate)
                        }
                    } else {
                        throw "模块编号超出有效范围 [1-$($displayedList.Count)]: $idxStr"
                    }
                } else {
                    throw "无效的模块编号输入: '$idxStr'。请输入有效数字编号、'all' 或 'Q' 退出。"
                }
            }
            if ($TargetModules.Count -eq 0) {
                throw "未选定任何有效模块，编排器退出。"
            }
        }
    }

    # ==============================================================================
    # 8. 调度各模块自治巡检与收敛
    # ==============================================================================
    Write-Host "`n======================= 开始流水线调度系统模块加固 =======================" -ForegroundColor Cyan
    Write-Host ("  [执行参数] 操作意图: {0} | 交互放行: {1}`n" -f $Action, ($Yes ? "自动确认 (-Yes)" : "交互审查")) -ForegroundColor DarkGray

    $humanHints = [Collections.Generic.List[object]]::new()
    $moduleFailed = $false
    $moduleExecuted = 0
    foreach ($mod in $TargetModules) {
        $moduleExecuted++
        Write-Host ("`n▶ [{0}/{1}] 调度模块: {2} ({3})" -f $moduleExecuted, $TargetModules.Count, $mod.Name, $mod.Id) -ForegroundColor Yellow

        $subParams = @{ Action = $Action }
        if ($Yes) { $subParams["Yes"] = $true }

        try {
            & $mod.FullName @subParams 6>&1 | ForEach-Object {
                if ($_ -is [Management.Automation.InformationRecord]) {
                    if ($_.Tags -contains 'HumanHandoff') {
                        $humanHints.Add([pscustomobject]@{ Source = $mod.Name; Message = [string]$_.MessageData })
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
            $moduleFailed = $true
            Write-Error "子模块 [$($mod.Id)] 执行异常: $($_.Exception.Message)" -ErrorAction Continue
        }
    }

    # ==============================================================================
    # 9. 仅汇集子模块明确交付的人类待办
    # ==============================================================================
    if ($humanHints.Count -gt 0) {
        Write-Host "`n📋 [人类待办] 以下提示由对应子模块交付，不表示执行成功或基线合规：" -ForegroundColor Cyan
        $seenHints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($hint in $humanHints) {
            if ($seenHints.Add("$($hint.Source)`n$($hint.Message)")) {
                Write-Host "`n[$($hint.Source)] $($hint.Message)" -ForegroundColor Yellow
            }
        }
    }

    if ($Action -eq "Sync") {
        Write-Host "`n💡 [按需刷新] 脚本未自动重启 Windows Explorer。若修改了外壳配置且界面尚未更新，可自行刷新：" -ForegroundColor Cyan
        Write-Host "   按 Ctrl+Shift+Esc 打开 Task Manager，在 Processes 中选中 Windows Explorer，点击 Restart task。" -ForegroundColor Gray
        Write-Host "   刷新会暂时关闭文件夹窗口并重载桌面、任务栏；可能中断由资源管理器执行的文件复制、移动、删除及剪切/粘贴操作。请先等待文件操作完成。" -ForegroundColor Yellow
        Write-Host "   刷新 Explorer 不能使所有配置立即生效，部分设置仍需重启相关应用、注销或重启系统。`n" -ForegroundColor Gray
    }

    if ($moduleFailed) { throw '系统基线调度包含失败模块；请处理实时错误和人类待办后重试。' }
} finally {
    if ($TempSandboxDir -and (Test-Path $TempSandboxDir)) {
        Remove-Item -Path $TempSandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
