#requires -Version 7.0
<#
.SYNOPSIS
    应用生命周期控制台呈现与守门算子 (Console & Gatekeeper)

.DESCRIPTION
    PowerShell 7+ 无状态终端视觉与交互辅助算子。
    - 纯属性数据输入，视觉排版直出控制台 (Write-Host)，管道仅回传布尔决策值，避免管道污染；
    - 绝不调用 exit 或抛出阻断异常（除无效授权输入），决策权交付子脚本；
    - 支持 RenderDiff (受控属性看板)、ConfirmGate (变更授权门禁)、ConfirmUninstall (退役确认)。

.PARAMETER Task
    执行的任务能力: RenderDiff, ConfirmGate, ConfirmUninstall。

.PARAMETER Specs
    受控属性规格对象数组 (Module, Property, Expected, Actual, IsMatch, Purpose, Impact)。

.PARAMETER Action
    当前生命周期操作动词 (Sync, Check, Uninstall)。

.PARAMETER Yes
    免交互全量确认放行开关。

.PARAMETER AppName
    应用展示名称。

.PARAMETER UserDataList
    用户数据路径列表，用于 ConfirmUninstall 呈现受控配置与数据清理范围。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("RenderDiff", "ConfirmGate", "ConfirmUninstall")]
    [string]$Task,

    [System.Collections.IList]$Specs,

    [string]$Action = "Sync",

    [switch]$Yes,

    [string]$AppName = "应用",

    [string[]]$UserDataList = @()
)

$ErrorActionPreference = "Stop"

function Truncate-Cell([string]$Text, [int]$MaxLength = 24) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "-" }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, $MaxLength - 3) + "..."
}

# ==============================================================================
# Task: RenderDiff (受控属性看板呈现)
# ==============================================================================
if ($Task -eq "RenderDiff") {
    if ($Yes) {
        # -Yes 与静默模式深度绑定：非交互场景下抑制全量差异矩阵看板，保持输出极简
        return
    }

    if (-not $Specs -or $Specs.Count -eq 0) {
        Write-Host "[-] 未传入受控规格清单，跳过看板渲染。" -ForegroundColor DarkGray
        return
    }

    $alignedCount = 0
    $rows = foreach ($s in $Specs) {
        $isMatch = if ($null -ne $s.IsMatch) { [bool]$s.IsMatch } else { [string]$s.Expected -eq [string]$s.Actual }
        if ($isMatch) { $alignedCount++ }

        $statusSymbol = if ($isMatch) { " ✔" } else { " ▲" }

        $actualRaw = if ($null -ne $s.Actual) { [string]$s.Actual } else { "-" }

        [PSCustomObject]@{
            状态 = $statusSymbol
            模块 = if ($s.Module) { [string]$s.Module } else { "受控" }
            属性 = Truncate-Cell ([string]$s.Property) 28
            实机 = Truncate-Cell $actualRaw 22
            基线 = Truncate-Cell ([string]$s.Expected) 22
        }
    }

    $targetWidth = try {
        $w = [System.Console]::WindowWidth
        if ($w -ge 100) { $w } else { 120 }
    } catch { 120 }

    Write-Host "`n📊 [巡检看板] 原子受控属性审计清单:" -ForegroundColor Cyan
    $rows | Format-Table -AutoSize | Out-String -Width $targetWidth | Write-Host
    Write-Host ("巡检统计: 共 {0} 项受控属性 | 已就绪 {1} 项 | 存在偏离 {2} 项`n" -f $rows.Count, $alignedCount, ($rows.Count - $alignedCount)) -ForegroundColor Cyan
    return
}

# ==============================================================================
# Task: ConfirmGate (变更授权门禁与放行决策)
# ==============================================================================
if ($Task -eq "ConfirmGate") {
    $diffs = @()
    if ($Specs -and $Specs.Count -gt 0) {
        $diffs = @($Specs | Where-Object {
            if ($null -ne $_.IsMatch) { -not $_.IsMatch } else { [string]$_.Expected -ne [string]$_.Actual }
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
        if ($d.Purpose) { Write-Host ("   [目的] {0}" -f $d.Purpose) -ForegroundColor Gray }
        if ($d.Impact) { Write-Host ("   [影响] {0}" -f $d.Impact) -ForegroundColor DarkYellow }
    }
    Write-Host ""

    if ($Action -eq "Check") {
        Write-Host "[-] 当前为只查不改模式 (-Action Check)，已输出受控属性偏离审计，安全退出。`n" -ForegroundColor DarkGray
        return $false
    }

    if ($Yes) {
        Write-Host "[+] 检测到 -Yes 免交互参数，已自动放行执行流水线。`n" -ForegroundColor Green
        return $true
    }

    $gateInput = (Read-Host "按回车 [Enter] 确认执行上述请求，或输入 [Q] 退出").Trim()
    if ($gateInput -notin @('', 'Y', 'y', 'YES', 'yes', 'Q', 'q', 'QUIT', 'quit', 'N', 'n', 'NO', 'no')) {
        throw '无效授权输入；未执行本模块写入。'
    }
    if ($gateInput -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户已主动取消执行，安全退出。`n" -ForegroundColor DarkGray
        return $false
    }

    Write-Host "[+] 变更授权已通过，正在应用基线...`n" -ForegroundColor Cyan
    return $true
}

# ==============================================================================
# Task: ConfirmUninstall (退役确认与数据保护防呆)
# ==============================================================================
if ($Task -eq "ConfirmUninstall") {
    if ($Yes) {
        return $true
    }

    $hasDeclaredData = $UserDataList -and $UserDataList.Count -gt 0
    if ($hasDeclaredData) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将退役 $AppName 本体并彻底清理受控配置与声明残留！" -ForegroundColor Yellow
    } else {
        Write-Host "`n⚠️  即将退役 $AppName 本体；未声明用户数据清理。" -ForegroundColor Yellow
    }
    if ($hasDeclaredData) {
        Write-Host "📌 【即将被清理的受控配置与声明数据】:" -ForegroundColor Cyan
        foreach ($d in $UserDataList) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "🛡️  注：个人文档、外部项目等非声明数据受硬边界保护，绝不触碰。`n" -ForegroundColor DarkCyan
    }

    $promptText = if ($hasDeclaredData) { "确认退役 $AppName 并清理其声明数据? [y/N]" } else { "确认退役 $AppName 本体（保留用户数据）? [y/N]" }
    $confirm = (Read-Host $promptText).Trim()
    if ($confirm -match '^(y|yes)$') {
        return $true
    } else {
        Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
        return $false
    }
}
