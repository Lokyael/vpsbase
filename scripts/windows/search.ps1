#requires -Version 7.0
<#
.SYNOPSIS
    搜索与 AI 助理切断基线

.DESCRIPTION
    Windows 11 搜索功能纯净化、Copilot 助理阻断与联机必应建议切断基准模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 双层策略 (HKCU + HKLM) 彻底禁用 Windows Copilot，剥离外壳呼出通道。
    3. 停用原生 WSearch 索引服务，降低后台磁盘与 CPU 静默开销。
    4. 切断搜索框联机必应搜索建议、云端搜索与动态推荐内容，恢复纯本地精确搜索。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (100% 只读诊断受控属性对比，零写入安全退出)

.PARAMETER Profile
    加固预设:
    - Full    : 个人黄金深度基线 (默认，极致性能与全域深度加固)
    - General : 通用稳健基线 (保守兼容)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\scripts\windows\search.ps1 -Action Check

    # 交互式检查并应用黄金深度基线
    pwsh -File .\scripts\windows\search.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\search.ps1 -Yes
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check")]
    [string]$Action = "Sync",

    [ValidateSet("Full", "General")]
    [string]$Profile = "Full",

    [switch]$Yes
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# 1. 运行时环境硬门禁与权限安全防御
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "【版本错误】此脚本针对 PowerShell 7 (pwsh) 现代运行时深度定制，严禁在 Windows PowerShell 5.1 下执行！"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and $Action -ne "Check") {
    throw "【权限错误】此脚本必须以管理员身份运行！请右键 pwsh 选择 [以管理员身份运行] 后重新执行。"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】当前终端运行身份 [$currentUser] 与桌面登录用户 [$consoleUser] 不一致！为防配置污染，请直接在桌面登录用户会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 内置原生轻量辅助函数库 (Self-Contained Mini-Kit)
# ==============================================================================
function Ensure-RegKey {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
}

function Set-RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    Ensure-RegKey $Path
    $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($cur -ne $Value) {
        try {
            Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value -Force -ErrorAction Stop
        } catch {
            $regPath = $Path -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
            & reg.exe add $regPath /v $Name /t REG_DWORD /d $Value /f *>$null
        }
    }
}

function Get-RegVal {
    param([string]$Path, [string]$Name, [string]$Default = "<未配置>")
    if (-not (Test-Path $Path)) { return $Default }
    $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    return if ($null -ne $val) { "$val" } else { $Default }
}

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 作用与风险明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "copilot-policy-hkcu"
        Name    = "Windows Copilot 用户策略切断 (HKCU TurnOffWindowsCopilot)"
        Profile = "General"
        Purpose = "禁用当前用户会话下的 Copilot 侧栏呼出与热键响应，剥离外壳 AI 助理通道"
        Impact  = "Win+C 热键将不再唤出 Copilot 侧边栏，依赖内置 AI 助理对话的用户将无法使用"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
        }
    },
    [PSCustomObject]@{
        Id      = "copilot-policy-hklm"
        Name    = "Windows Copilot 机器策略切断 (HKLM TurnOffWindowsCopilot)"
        Profile = "General"
        Purpose = "从系统全局组策略层锁死 Copilot 功能，彻底阻止其随系统补丁更新自动复活"
        Impact  = "全机所有本地账户均无法启用 Windows 原生 Copilot 侧边栏集成"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
        }
    },
    [PSCustomObject]@{
        Id      = "search-disable-web-search-hklm"
        Name    = "开始菜单联机搜索停用 (HKLM DisableSearch)"
        Profile = "General"
        Purpose = "切断 Windows 搜索组件的联机查询引擎，仅检索本地程序、设置与文件"
        Impact  = "无法直接在开始菜单键入关键词跳转 Edge 必应搜索互联网网页"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableSearch"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableSearch" 1
        }
    },
    [PSCustomObject]@{
        Id      = "search-disallow-cloud-search"
        Name    = "搜索框云端内容检索切断 (HKLM AllowCloudSearch)"
        Profile = "General"
        Purpose = "禁止开始菜单搜索通过微软账号云端索取个人 OneDrive/SharePoint 联机索引内容"
        Impact  = "开始菜单不再实时联机检索未同步到本地的 OneDrive 个人云端文档"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCloudSearch"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCloudSearch" 0
        }
    },
    [PSCustomObject]@{
        Id      = "search-disable-dynamic-content"
        Name    = "搜索框动态热点内容切断 (HKLM EnableDynamicContentInWSB)"
        Profile = "General"
        Purpose = "关闭搜索窗口中的今日热搜、动态插画、节日卡片与联机新闻资讯推送"
        Impact  = "搜索主面板变为纯色本地空白面板，不再展示任何网络热搜词条"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "EnableDynamicContentInWSB"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "EnableDynamicContentInWSB" 0
        }
    },
    [PSCustomObject]@{
        Id      = "search-disable-box-suggestions"
        Name    = "搜索框输入建议切断 (HKCU DisableSearchBoxSuggestions)"
        Profile = "General"
        Purpose = "禁止在搜索框键入字符时向微软服务器回传按键以换取搜索联想建议词，保护输入隐私"
        Impact  = "键入字符时不再出现联网联想词，仅根据本地应用名称进行前缀模糊匹配"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
        }
    },
    [PSCustomObject]@{
        Id      = "search-disable-bing-search-enabled"
        Name    = "必应搜索集成切断 (HKCU BingSearchEnabled)"
        Profile = "General"
        Purpose = "关闭任务栏与开始菜单中的 Bing 网页搜索结果卡片，消除多余网络请求"
        Impact  = "搜索面板右侧不再出现必应网页内容预览卡片"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "search-disable-device-history"
        Name    = "本机搜索历史收集切断 (HKCU IsDeviceSearchHistoryEnabled)"
        Profile = "General"
        Purpose = "关闭搜索框对用户本地搜索关键词与历史记录的常驻收集，保护桌面隐私"
        Impact  = "搜索主界面不再自动展示上一次搜索过的关键词历史记录"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-wsearch"
        Name    = "Windows Search 后台文件索引服务 (WSearch)"
        Profile = "General"
        Purpose = "停用后台 Windows Search 索引扫描服务，消除后台静默磁盘与 CPU 读写，延长固态硬盘寿命"
        Impact  = "开始菜单与资源管理器检索未索引目录的文件时将退化为全盘暴力枚举（推荐配合 Everything 毫秒级检索）；Outlook 本地邮件全文索引功能将受影响"
        Check   = {
            $svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
            $act = if ($svc) { "$($svc.StartType) ($($svc.Status))" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($svc -and $svc.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
            Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }
)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  搜索与 AI 助理切断基线巡检 (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 加固预设: {1} | 授权放行: {2}" -f $Action, $Profile, ($Yes ? "自动放行 (-Yes)" : "交互审查")) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$ActiveRules = @($Rules | Where-Object {
    if ($Profile -eq "General") { $_.Profile -eq "General" } else { $true }
})

$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$PendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($rule in $ActiveRules) {
    $res = $null
    try {
        $res = & $rule.Check
    } catch {
        $res = @{
            Actual      = "<探测异常: $($_.Exception.Message)>"
            Expected    = "<未知>"
            IsCompliant = $false
        }
    }

    $isPass = [bool]$res.IsCompliant
    $actualStr = "$($res.Actual)"
    $expectedStr = "$($res.Expected)"

    $AuditBoard.Add([PSCustomObject]@{
        受控规则 = $rule.Name
        预设级别 = $rule.Profile
        实机状态 = $actualStr
        期望基线 = $expectedStr
        状态判定 = if ($isPass) { "✔ 合规" } else { "✘ 偏离" }
    })

    if (-not $isPass) {
        $PendingItems.Add([PSCustomObject]@{
            Rule        = $rule
            Actual      = $actualStr
            Expected    = $expectedStr
        })
    }
}

Write-Host "`n📊 [巡检看板] 搜索与 Copilot 原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 搜索与 AI 助理切断基线全部合规，无需调整。`n" -ForegroundColor Green
    return
}

Write-Host ("⚠️  共检测到 {0} 项原子受控属性偏离工程基线。" -f $driftCount) -ForegroundColor Yellow

if ($Action -eq "Check") {
    Write-Host "💡 当前处于 -Action Check 只读巡检模式，未执行任何系统改动。`n" -ForegroundColor DarkGray
    return
}

# 阶段 2: Gate (Shift-Left: 目的与影响结构化直出)
if (-not $Yes) {
    Write-Host "`n💡 [改动意图与技术边界审查 (Gate)]" -ForegroundColor Cyan
    Write-Host "   本次即将对齐以下偏离项，请逐项评估改动 [目的] 与 [影响]:" -ForegroundColor Gray
    $idx = 1
    foreach ($p in $PendingItems) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.Rule.Name) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.Actual, $p.Expected) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $p.Rule.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $p.Rule.Impact) -ForegroundColor Gray
        $idx++
    }

    $gateInput = (Read-Host "`n确认对齐上述 $driftCount 项搜索加固基线？[Y] 确认执行 / [N] 跳过本模块 / [Q] 退出 (默认 Y)").Trim()
    if ($gateInput -match '^[Qq]') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
    if ($gateInput -match '^[Nn]') {
        Write-Host "[-] 跳过本模块基准对齐。`n" -ForegroundColor DarkGray
        return
    }
}

# 阶段 3: Apply
Write-Host "`n🚀 正在单向对齐搜索与 Copilot 切断基线..." -ForegroundColor Cyan
$appliedCount = 0

foreach ($p in $PendingItems) {
    Write-Host -NoNewline ("   - 正在配置: {0} ... " -f $p.Rule.Name)
    try {
        & $p.Rule.Apply
        Write-Host -ForegroundColor Green "[OK]"
        $appliedCount++
    } catch {
        Write-Host -ForegroundColor Red "[FAIL]"
        Write-Warning "执行规则 [$($p.Rule.Name)] 失败: $($_.Exception.Message)"
    }
}

# 阶段 4: Report
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host ("  ✅ [搜索加固完成] 成功对齐 {0} / {1} 项基线配置 (预设: {2})" -f $appliedCount, $driftCount, $Profile) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
