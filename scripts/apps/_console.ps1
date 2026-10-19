#requires -Version 7.0
<#
.SYNOPSIS
    应用生命周期域通用控制台呈现与交互守门算子 (Console & Gatekeeper)

.DESCRIPTION
    1. 专为 PowerShell 7+ (pwsh) 打造的无状态终端视觉与交互辅助算子。
    2. 严格践行物理解耦与机制分离契约：
       - 只接收纯属性数据（标量、数组、哈希表），严禁接收可执行代码块（ScriptBlock）；
       - 视觉排版直出控制台 (Write-Host)，标准管道输出流唯一仅回传布尔决策值，杜绝管道污染；
       - 绝不调用 exit 或抛出阻断异常，决策权完全后置交付应用子脚本；
       - 命名采用下划线前缀 (_console.ps1) 明确标识为领域私有辅助算子，隔离于编排门面实体清单。
    3. 支持四大标准化终端交互能力：
       - RenderDiff       : 自适应终端列宽、全角中文等宽对齐与 ANSI 差异矩阵表格渲染；
       - ConfirmGate      : 结构化呈现 [目的] 与 [影响]，单向语义 (Enter/Q/-Yes/Check) 决策守门；
       - ConfirmUninstall : 呈现高危用户数据抹除告警与 y/N 二次确认；
       - Summary          : 闭环耗时度量与已对齐项汇总。

.PARAMETER Task
    指定执行的任务能力，可选值: RenderDiff, ConfirmGate, ConfirmUninstall, Summary。

.PARAMETER Specs
    受控属性规格对象数组。每个属性项包含:
    - Module   : [string] 所属模块/分类 (可选，默认 "受控属性")
    - Property : [string] 受控属性标识 (必填)
    - Expected : [string] 期望基线值 (必填)
    - Actual   : [string] 实机当前探测真实值 (必填)
    - IsMatch  : [bool]   是否符合基线 (可选，缺省时自动比对 Expected 与 Actual)
    - Purpose  : [string] 改动技术目的与性能/安全性收益
    - Impact   : [string] 改动对工作负载与兼容性的潜在影响

.PARAMETER Action
    当前生命周期操作动词 (Sync, Check, Uninstall)。用于 ConfirmGate 决策。

.PARAMETER Yes
    免交互全量确认放行开关。

.PARAMETER Purge
    配合 Uninstall 使用的深度粉碎开关。若指定，将连带物理抹除用户数据目录。

.PARAMETER AppName
    应用友好展示名称，用于 ConfirmUninstall 告警。

.PARAMETER UserDataList
    即将被物理抹除的高价值用户数据路径列表，用于 ConfirmUninstall 告警。

.PARAMETER Duration
    执行耗时时间间隔 (TimeSpan)，用于 Summary 汇总。

.PARAMETER AppliedCount
    本次已成功对齐或修改的受控项数量，用于 Summary 汇总。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("RenderDiff", "ConfirmGate", "ConfirmUninstall", "Summary")]
    [string]$Task,

    [System.Collections.IList]$Specs,

    [string]$Action = "Sync",

    [switch]$Yes,

    [switch]$Purge,

    [string]$AppName = "应用",

    [string[]]$UserDataList = @(),

    [timespan]$Duration = [timespan]::Zero,

    [int]$AppliedCount = 0
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# 内部纯辅助工具：终端列宽与中文全角计算
# ==============================================================================
function Get-DisplayWidth {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        # Unicode 0x2e80 以上涵盖 CJK 字符与全角标点，在终端占用 2 个列宽
        if ([int]$ch -ge 0x2e80) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

function Pad-RightDisplay {
    param(
        [string]$Text,
        [int]$TargetWidth
    )
    $currentWidth = Get-DisplayWidth $Text
    if ($currentWidth -ge $TargetWidth) { return $Text }
    return $Text + (' ' * ($TargetWidth - $currentWidth))
}

# ==============================================================================
# Task: RenderDiff (差异矩阵渲染)
# ==============================================================================
if ($Task -eq "RenderDiff") {
    if (-not $Specs -or $Specs.Count -eq 0) {
        Write-Host "[-] 未传入受控规格清单，跳过矩阵渲染。" -ForegroundColor DarkGray
        return
    }

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $alignedCount = 0
    $driftCount = 0

    foreach ($s in $Specs) {
        $module = if ($s.Module) { [string]$s.Module } else { "受控属性" }
        $prop = if ($s.Property) { [string]$s.Property } else { "未知属性" }
        $expected = if ($null -ne $s.Expected) { [string]$s.Expected } else { "-" }
        $actual = if ($null -ne $s.Actual) { [string]$s.Actual } else { "-" }

        $isMatch = if ($null -ne $s.IsMatch) {
            [bool]$s.IsMatch
        } else {
            $expected -eq $actual
        }

        if ($isMatch) {
            $alignedCount++
            $statusText = "✔ 对齐"
        } else {
            $driftCount++
            $statusText = "▲ 偏离"
        }

        $rows.Add([PSCustomObject]@{
            Module     = $module
            Property   = $prop
            Expected   = $expected
            Actual     = $actual
            IsMatch    = $isMatch
            StatusText = $statusText
        })
    }

    # 动态计算各列最大宽度 (设置硬性安全阈值，防止超长配置撑爆终端)
    $maxModLen = 4
    $maxPropLen = 8
    $maxExpLen = 8
    $maxActLen = 8

    foreach ($r in $rows) {
        $maxModLen  = [math]::Max($maxModLen,  (Get-DisplayWidth $r.Module))
        $maxPropLen = [math]::Max($maxPropLen, (Get-DisplayWidth $r.Property))
        $maxExpLen  = [math]::Max($maxExpLen,  (Get-DisplayWidth $r.Expected))
        $maxActLen  = [math]::Max($maxActLen,  (Get-DisplayWidth $r.Actual))
    }

    # 封顶约束，保障排版优雅
    $wMod  = [math]::Min($maxModLen, 16)
    $wProp = [math]::Min($maxPropLen, 36)
    $wExp  = [math]::Min($maxExpLen, 28)
    $wAct  = [math]::Min($maxActLen, 28)
    $wStat = 8

    # 边框定义
    $line = "+" + ("-" * ($wMod + 2)) + "+" + ("-" * ($wProp + 2)) + "+" + ("-" * ($wExp + 2)) + "+" + ("-" * ($wAct + 2)) + "+" + ("-" * ($wStat + 2)) + "+"

    Write-Host "`n$line" -ForegroundColor DarkGray
    $headerMod  = Pad-RightDisplay " 模块" ($wMod + 2)
    $headerProp = Pad-RightDisplay " 受控属性" ($wProp + 2)
    $headerExp  = Pad-RightDisplay " 期望基线值" ($wExp + 2)
    $headerAct  = Pad-RightDisplay " 实机当前状态" ($wAct + 2)
    $headerStat = Pad-RightDisplay " 状态" ($wStat + 2)
    Write-Host "|$headerMod|$headerProp|$headerExp|$headerAct|$headerStat|" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray

    foreach ($r in $rows) {
        $colMod  = Pad-RightDisplay (" " + $r.Module) ($wMod + 2)
        $colProp = Pad-RightDisplay (" " + $r.Property) ($wProp + 2)
        $colExp  = Pad-RightDisplay (" " + $r.Expected) ($wExp + 2)
        $colAct  = Pad-RightDisplay (" " + $r.Actual) ($wAct + 2)
        $colStat = Pad-RightDisplay (" " + $r.StatusText) ($wStat + 2)

        Write-Host -NoNewline "|$colMod|$colProp|$colExp|$colAct|" -ForegroundColor Gray

        if ($r.IsMatch) {
            Write-Host "$colStat|" -ForegroundColor Green
        } else {
            Write-Host "$colStat|" -ForegroundColor Yellow
        }
    }

    Write-Host $line -ForegroundColor DarkGray
    Write-Host ("📊 巡检统计: 共 {0} 项受控属性 | 已就绪 {1} 项 | 存在偏离 {2} 项`n" -f $rows.Count, $alignedCount, $driftCount) -ForegroundColor Cyan
    return
}

# ==============================================================================
# Task: ConfirmGate (审查门禁与决策放行)
# ==============================================================================
if ($Task -eq "ConfirmGate") {
    # 提取所有不符合基线的偏离项
    $diffs = @()
    if ($Specs -and $Specs.Count -gt 0) {
        $diffs = @($Specs | Where-Object {
            if ($null -ne $_.IsMatch) {
                -not $_.IsMatch
            } else {
                [string]$_.Expected -ne [string]$_.Actual
            }
        })
    }

    if ($diffs.Count -eq 0) {
        Write-Host "✔ 全部原子受控属性均已符合工程基线，无需任何配置变更。`n" -ForegroundColor Green
        return $false
    }

    Write-Host "⚠️  检测到以下 $($diffs.Count) 处受控属性偏离工程基线，待执行对齐变更:" -ForegroundColor Yellow
    foreach ($d in $diffs) {
        $propName = if ($d.Property) { $d.Property } else { "未指定属性" }
        Write-Host ("`n▶ 属性: {0}" -f $propName) -ForegroundColor Cyan
        if ($d.Purpose) {
            Write-Host ("   [目的] {0}" -f $d.Purpose) -ForegroundColor Gray
        }
        if ($d.Impact) {
            Write-Host ("   [影响] {0}" -f $d.Impact) -ForegroundColor DarkYellow
        }
    }
    Write-Host ""

    # 只查不改体检模式
    if ($Action -eq "Check") {
        Write-Host "[-] 当前为只查不改模式 (-Action Check)，已输出受控属性偏离审计，安全退出。`n" -ForegroundColor DarkGray
        return $false
    }

    # 免交互放行
    if ($Yes) {
        Write-Host "[+] 检测到 -Yes 免交互参数，已自动放行执行流水线。`n" -ForegroundColor Green
        return $true
    }

    # 默认交互确认 (单向语义: 回车继续，Q 退出)
    $input = (Read-Host "按回车 [Enter] 确认执行上述基线配置变更，或输入 [Q] 退出").Trim()
    if ($input -match '^(q|quit|exit)$') {
        Write-Host "[-] 用户已主动取消执行，安全退出。`n" -ForegroundColor DarkGray
        return $false
    }

    Write-Host "[+] 变更授权已通过，正在应用基线...`n" -ForegroundColor Cyan
    return $true
}

# ==============================================================================
# Task: ConfirmUninstall (高危用户数据防呆告警与卸载确认)
# ==============================================================================
if ($Task -eq "ConfirmUninstall") {
    if ($Yes) {
        return $true
    }

    Write-Host "`n⚠️  [清洁卸载警示] 即将注销系统关联并清理 $AppName！" -ForegroundColor Yellow
    if ($UserDataList -and $UserDataList.Count -gt 0) {
        if ($Purge) {
            Write-Host "🔥 【检测到 -Purge 参数：以下高价值用户数据将被深度物理粉碎】:" -ForegroundColor Red
            foreach ($d in $UserDataList) {
                Write-Host ("   - {0}" -f $d) -ForegroundColor DarkRed
            }
            Write-Host "👉 该操作不可逆，所有本地数据与配置将被彻底清空！`n" -ForegroundColor Red
        } else {
            Write-Host "🛡️  【数据安全保护：以下高价值用户数据将默认保留在实机】:" -ForegroundColor Green
            foreach ($d in $UserDataList) {
                Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
            }
            Write-Host "👉 默认卸载仅移除程序本体与系统注册项。若需连带彻底粉碎用户数据，请指定 -Purge 开关。`n" -ForegroundColor Cyan
        }
    }

    $promptText = if ($Purge) {
        "确认彻底注销并深度粉碎 $AppName 及其全部数据? [y/N]"
    } else {
        "确认注销系统关联并移除 $AppName 本体（保留用户数据）? [y/N]"
    }

    $confirm = (Read-Host $promptText).Trim()
    if ($confirm -match '^(y|yes)$') {
        return $true
    } else {
        Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
        return $false
    }
}

# ==============================================================================
# Task: Summary (执行耗时与已对齐项汇总)
# ==============================================================================
if ($Task -eq "Summary") {
    $sec = if ($Duration) { $Duration.TotalSeconds } else { 0 }
    Write-Host ("🏁 [执行简报] 耗时: {0:N2}s | 已完成/对齐变更: {1} 项`n" -f $sec, $AppliedCount) -ForegroundColor Green
    return
}
