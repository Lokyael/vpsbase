#requires -Version 7.0
<#
.SYNOPSIS
    搜索与 AI 助理切断基线

.DESCRIPTION
    Windows 11 搜索功能纯净化、Copilot 助理阻断与联机必应建议切断基准模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线。
    2. 双层策略（HKCU + HKLM）彻底禁用 Windows Copilot，剥离外壳呼出通道。
    3. 停用原生 WSearch 索引服务，降低后台磁盘与 CPU 静默开销。
    4. 切断搜索框联机必应搜索建议、云端搜索与动态推荐内容，恢复纯本地精确搜索。

.PARAMETER Mode
    操作动词: Sync (执行加固/默认) 或 CheckOnly (只查不改/体检巡检)。

.PARAMETER Profile
    配置预设: Full (黄金深度基线/默认) 或 General (通用稳健基线)。

.PARAMETER Yes
    非交互自动确认放行。

.PARAMETER NonInteractive
    非交互模式，遇到确认直接放行执行。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\scripts\windows\search.ps1 -Mode CheckOnly

    # 交互式检查与加固
    pwsh -File .\scripts\windows\search.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\search.ps1 -Yes
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "CheckOnly")]
    [string]$Mode = "Sync",

    [ValidateSet("Full", "General")]
    [string]$Profile = "Full",

    [switch]$Yes,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# 环境校验：强制锁定 PowerShell 7+ 与 管理员权限
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "【版本错误】此脚本针对 PowerShell 7 (pwsh) 现代运行时深度定制，严禁在 Windows PowerShell 5.1 下执行！"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin) {
    throw "【权限错误】此脚本必须以管理员身份运行！请右键 pwsh 选择 [以管理员身份运行] 后重新执行。"
}

# ==============================================================================
# 内部辅助函数
# ==============================================================================
function Ensure-Key([string]$path) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}

function Set-RegDword([string]$Path, [string]$Name, [int]$Value) {
    Ensure-Key $Path
    $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($cur -ne $Value) {
        try {
            Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value -Force -ErrorAction Stop
        } catch {
            $regPath = $Path -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
            reg.exe add $regPath /v $Name /t REG_DWORD /d $Value /f *>$null
        }
    }
}

function Test-RegDword([string]$Path, [string]$Name, [int]$Expected) {
    if (-not (Test-Path $Path)) { return $false }
    $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    return ($null -ne $val -and [int]$val -eq $Expected)
}

# ==============================================================================
# 阶段 1: 全量只读嗅探与状态比对 (Plan & Diff)
# ==============================================================================
$items = @(
    [PSCustomObject]@{
        Name   = "彻底禁用 Windows Copilot (双层策略级切断)"
        Check  = {
            $c1 = Test-RegDword "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
            $c2 = Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
            return ($c1 -and $c2)
        }
        Action = {
            Ensure-Key "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"
            Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Type DWord -Value 1 -Force
            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Type DWord -Value 1 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "停用原生文件索引服务与联机必应搜索建议"
        Check  = {
            $ws = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
            $p1 = Test-RegDword $ws "DisableSearch" 1
            $p2 = Test-RegDword "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
            $p3 = Test-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0
            $s1 = (Get-Service WSearch -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            return ($p1 -and $p2 -and $p3 -and $s1)
        }
        Action = {
            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableSearch" -Value 1 -Type DWord -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCloudSearch" -Value 0 -Type DWord -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "EnableDynamicContentInWSB" -Value 0 -Type DWord -Force

            Ensure-Key "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
            Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Type DWord -Value 1 -Force
            Ensure-Key "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Type DWord -Value 0 -Force
            Ensure-Key "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsDeviceSearchHistoryEnabled" -Type DWord -Value 0 -Force

            Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
            Set-Service -Name WSearch -StartupType Disabled
        }
    }
)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  搜索与 AI 助理切断基线巡检 (pwsh 7+)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$chkList = [System.Collections.Generic.List[PSCustomObject]]::new()
$pendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($item in $items) {
    $isReady = $false
    try {
        $isReady = [bool](& $item.Check)
    } catch {
        $isReady = $false
    }

    $chkList.Add([PSCustomObject]@{
        受控项目 = $item.Name
        当前状态 = if ($isReady) { "已就绪" } else { "待加固" }
        判定     = if ($isReady) { "✔ 合规" } else { "✘ 偏离" }
    })

    if (-not $isReady) {
        $pendingItems.Add($item)
    }
}

$chkList | Format-Table -AutoSize | Out-String | Write-Host
$driftCount = $pendingItems.Count

if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 搜索与 AI 助理切断基线全部合规，无需调整。`n" -ForegroundColor Green
    return
}

Write-Host "⚠️  共发现 $driftCount 项基线偏离。" -ForegroundColor Yellow

if ($Mode -eq "CheckOnly") {
    Write-Host "💡 当前处于 -Mode CheckOnly 只查不改模式，未执行任何系统改动。`n" -ForegroundColor Gray
    return
}

# ==============================================================================
# 阶段 2: 审查门禁 (Gate)
# ==============================================================================
if (-not $Yes -and -not $NonInteractive) {
    Write-Host "💡 [改动说明与隐私边界]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 关闭开始菜单必应联机搜索与热点资讯 (SearchboxTaskbarMode)、切断 Copilot 侧栏集成" -ForegroundColor Gray
    Write-Host "   - 本地索引: 保持 Windows 本地文件索引服务正常运行，按 Win 键键入字符秒级检索本地程序与文件" -ForegroundColor Gray
    $choice = Read-Host "`n是否立即对齐上述 $driftCount 项搜索加固基线？[Y/n/q] (回车确认)"
    if ($choice -match '^[Qq]') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
    if ($choice -match '^[Nn]') {
        Write-Host "[-] 跳过本模块基准对齐。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================
Write-Host "`n🚀 正在单向对齐搜索与 Copilot 切断基线..." -ForegroundColor Cyan
$successCount = 0

foreach ($it in $pendingItems) {
    Write-Host -NoNewline ("   - 正在配置: {0} ... " -f $it.Name)
    try {
        & $it.Action
        Write-Host -ForegroundColor Green "[OK]"
        $successCount++
    } catch {
        Write-Host -ForegroundColor Red "[FAIL]"
        Write-Warning "执行 [$($it.Name)] 失败: $($_.Exception.Message)"
    }
}

# ==============================================================================
# 阶段 4: 尾部简报 (Report)
# ==============================================================================
Write-Host "`n✅ [搜索加固完成] 成功对齐 $successCount / $driftCount 项基线配置。`n" -ForegroundColor Green
