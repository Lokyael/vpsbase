#requires -Version 7.0
<#
.SYNOPSIS
    边缘后台服务与遥测计划任务剥离基线

.DESCRIPTION
    Windows 11 操作系统边缘服务裁剪、Xbox 生态剥离与后台遥测计划任务禁用模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线。
    2. 彻底剥离 Xbox 生态、GameDVR 录屏常驻与后台联机服务（XblAuthManager, XblGameSave 等）。
    3. 禁用跨设备流转连接平台 (CDPSvc)、手机服务 (PhoneSvc) 与离线地图代理 (MapsBroker)。
    4. 停用程序兼容性助手服务 (PcaSvc) 与触摸键盘手写面板服务 (TabletInputService)。
    5. 扫描并禁用 Microsoft Office 后台遥测计划任务。
    6. 禁用 AMD 显卡控制台开机常驻与后台服务 (针对 APU/笔记本轻量化)。

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
    pwsh -File .\scripts\windows\services.ps1 -Mode CheckOnly

    # 交互式检查与加固
    pwsh -File .\scripts\windows\services.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\services.ps1 -Yes
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
        Name   = "彻底剥离 Xbox 生态、GameDVR 与后台服务"
        Check  = {
            $dvr = Test-RegDword "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
            $svc = (Get-Service XblAuthManager -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            return ($dvr -and $svc)
        }
        Action = {
            Ensure-Key "HKCU:\System\GameConfigStore"
            Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Type DWord -Value 0 -Force
            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Type DWord -Value 0 -Force

            $xboxServices = @("XblAuthManager", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc")
            foreach ($svc in $xboxServices) {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svc -StartupType Disabled
            }
        }
    },
    [PSCustomObject]@{
        Name   = "禁用连接设备平台 (CDPSvc)、手机与离线地图服务"
        Check  = {
            $c = (Get-Service CDPSvc -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            $p = (Get-Service PhoneSvc -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            $m = (Get-Service MapsBroker -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            return ($c -and $p -and $m)
        }
        Action = {
            $svcs = @("CDPSvc", "PhoneSvc", "MapsBroker")
            foreach ($s in $svcs) {
                Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
                Set-Service -Name $s -StartupType Disabled
            }
        }
    },
    [PSCustomObject]@{
        Name   = "禁用程序兼容性助手服务 (PcaSvc)"
        Check  = {
            return (Get-Service PcaSvc -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
        }
        Action = {
            Stop-Service -Name PcaSvc -Force -ErrorAction SilentlyContinue
            Set-Service -Name PcaSvc -StartupType Disabled
        }
    },
    [PSCustomObject]@{
        Name   = "禁用 Office 后台遥测计划任务"
        Check  = {
            $tasks = Get-ScheduledTask -TaskPath "\Microsoft\Office\" -ErrorAction SilentlyContinue
            if (-not $tasks) { return $true }
            return ($tasks | Where-Object State -ne 'Disabled').Count -eq 0
        }
        Action = {
            Get-ScheduledTask -TaskPath "\Microsoft\Office\" -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
        }
    },
    [PSCustomObject]@{
        Name   = "停用触摸键盘与手写面板服务 (TabletInputService)"
        Check  = {
            $s = Get-Service -Name TabletInputService -ErrorAction SilentlyContinue
            return (-not $s -or $s.StartType -eq 'Disabled')
        }
        Action = {
            Stop-Service -Name TabletInputService -Force -ErrorAction SilentlyContinue
            Set-Service -Name TabletInputService -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Process -Name TabTip -Force -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Name   = "禁用 AMD 显卡控制台开机常驻与后台服务 (APU/笔记本)"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $base = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData"
            $pkgDir = Get-ChildItem -Path $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*AMDRadeonSoftware*" } | Select-Object -First 1
            $appxClean = $true
            if ($pkgDir) {
                $taskPath = Join-Path $pkgDir.PSPath "launcherrsxruntimeTask"
                $state = (Get-ItemProperty -Path $taskPath -Name "State" -ErrorAction SilentlyContinue).State
                $hasProc = [bool](Get-Process -Name "RadeonSoftware", "AMDRSServ", "AMDRSSrcExt" -ErrorAction SilentlyContinue)
                $appxClean = ($state -eq 1 -and -not $hasProc)
            }
            $s1 = Get-Service -Name "AMD Crash Defender Service" -ErrorAction SilentlyContinue
            $s2 = Get-Service -Name "AMD External Events Utility" -ErrorAction SilentlyContinue
            $svcClean = (-not $s1 -or $s1.StartType -eq 'Disabled') -and (-not $s2 -or $s2.StartType -eq 'Disabled')
            return ($appxClean -and $svcClean)
        }
        Action = {
            if ($Profile -eq 'General') { return }
            $base = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData"
            $pkgDir = Get-ChildItem -Path $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*AMDRadeonSoftware*" } | Select-Object -First 1
            if ($pkgDir) {
                $taskPath = Join-Path $pkgDir.PSPath "launcherrsxruntimeTask"
                if (-not (Test-Path $taskPath)) { New-Item -Path $taskPath -Force | Out-Null }
                Set-ItemProperty -Path $taskPath -Name "State" -Type DWord -Value 1 -Force
            }
            Stop-Process -Name "RadeonSoftware", "AMDRSServ", "AMDRSSrcExt" -Force -ErrorAction SilentlyContinue
            @("AMD Crash Defender Service", "AMD External Events Utility") | ForEach-Object {
                $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
                if ($svc) {
                    if ($svc.Status -eq 'Running') { Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue }
                    Set-Service -Name $_ -StartupType Disabled -ErrorAction SilentlyContinue
                }
            }
        }
    }
)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  边缘后台服务与遥测计划任务剥离巡检 (pwsh 7+)" -ForegroundColor Cyan
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
    Write-Host "🎉 [状态完美] 边缘后台服务与遥测计划任务全部合规，无需调整。`n" -ForegroundColor Green
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
    Write-Host "💡 [改动说明与影响范围]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 禁用离线定位、Xbox 游戏录制常驻与程序兼容性助手 (PcaSvc)，释放冷启与后台负载" -ForegroundColor Gray
    Write-Host "   - 兼容边界: 若日常重度依赖 Windows 自带游戏录屏 (Win+G) 或地图定位，请在审查时选择跳过本项" -ForegroundColor Gray
    $choice = Read-Host "`n是否立即对齐上述 $driftCount 项服务基线？[Y/n/q] (回车确认)"
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
Write-Host "`n🚀 正在单向对齐后台服务基线..." -ForegroundColor Cyan
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
Write-Host "`n✅ [服务加固完成] 成功对齐 $successCount / $driftCount 项基线配置。`n" -ForegroundColor Green
