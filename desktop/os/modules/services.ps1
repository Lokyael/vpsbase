#requires -Version 7.0
<#
.SYNOPSIS
    边缘后台服务裁剪基线

.DESCRIPTION
    Windows 11 操作系统边缘服务裁剪与 Xbox 生态管理模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 彻底剥离 Xbox 生态、GameDVR 录屏常驻与后台联机服务（XblAuthManager, XblGameSave 等），阻断 AppCapture 与 GameBar DCOM 超时唤醒。
    3. 禁用跨设备流转连接平台 (CDPSvc)、手机服务 (PhoneSvc) 与离线地图代理 (MapsBroker)。
    4. 停用程序兼容性助手服务 (PcaSvc) 与触摸键盘手写面板服务 (TabletInputService)。
    5. 禁用 AMD 显卡控制台开机常驻与后台服务 (针对 APU/笔记本轻量化)。
    6. 停用 Nahimic 音效伴生驱动注入服务 (NahimicService)，消除 audiodg.exe 持续异常高负荷与应用冷启动迟滞。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (只读诊断受控属性对比，零写入安全退出)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\desktop\os\modules\services.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\desktop\os\modules\services.ps1

    # 无交互一键全量对齐
    pwsh -File .\desktop\os\modules\services.ps1 -Yes
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check")]
    [string]$Action = "Sync",

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

function Get-RegKind {
    param([string]$Path, [string]$Name)
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        try {
            if ($Name -notin $key.GetValueNames()) { return '<未配置>' }
            return [string]$key.GetValueKind($Name)
        } finally { $key.Dispose() }
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return '<未配置>' }
        throw
    }
}

function Set-RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    Ensure-RegKey $Path
    if ((Get-RegVal $Path $Name) -ne "$Value" -or (Get-RegKind $Path $Name) -ne 'DWord') {
        Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value -Force -ErrorAction Stop
        if ((Get-RegVal $Path $Name) -ne "$Value" -or (Get-RegKind $Path $Name) -ne 'DWord') { throw "注册表写入后校验失败：$Path\$Name" }
    }
}

function Get-RegVal {
    param([string]$Path, [string]$Name, [string]$Default = "<未配置>")
    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return $Default }
        throw
    }
    # RegistryProvider 对没有任何值的键正常返回空输出。
    if ($null -eq $item) { return $Default }
    $value = $item.PSObject.Properties[$Name]
    if ($null -ne $value -and $null -ne $value.Value) { return [string]$value.Value }
    return $Default
}

function Test-RegDword {
    param([string]$Path, [string]$Name, [int]$ExpectedValue)
    return (Get-RegVal $Path $Name) -eq "$ExpectedValue" -and (Get-RegKind $Path $Name) -eq 'DWord'
}

function Get-ServiceDisableState {
    param([Parameter(Mandatory = $true)][string]$Name)
    $expected = '未安装或 Disabled + Stopped'
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
    } catch {
        if (($_.FullyQualifiedErrorId -split ',')[0] -eq 'NoServiceFoundForGivenName') {
            return @{ Actual = '未安装 / 无需处理'; Expected = $expected; IsCompliant = $true; Service = $null }
        }
        throw
    }
    if ($null -eq $service -or "$($service.StartType)" -notin @('Automatic', 'Manual', 'Disabled', 'Boot', 'System') -or
        "$($service.Status)" -notin @('Stopped', 'StartPending', 'StopPending', 'Running', 'ContinuePending', 'PausePending', 'Paused')) {
        throw "服务 [$Name] 的启动类型或运行状态无法确认。"
    }
    return @{
        Actual = "$($service.StartType) + $($service.Status)"
        Expected = $expected
        IsCompliant = ($service.StartType -eq 'Disabled' -and $service.Status -eq 'Stopped')
        Service = $service
    }
}

function Disable-ManagedService {
    param([Parameter(Mandatory = $true)][string]$Name)
    $state = Get-ServiceDisableState -Name $Name
    $service = $state.Service
    if ($null -eq $service) { return }
    if ($service.StartType -ne 'Disabled') {
        Set-Service -InputObject $service -StartupType Disabled -ErrorAction Stop
    }
    if ($service.Status -ne 'Stopped') {
        # 不使用 Force，不自动停止依赖服务；只等待当前目标服务。
        if ($service.Status -ne 'StopPending') {
            Stop-Service -InputObject $service -NoWait -ErrorAction Stop
        }
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [timespan]::FromSeconds(10))
    }
    $after = Get-ServiceDisableState -Name $Name
    if (-not $after.IsCompliant) {
        throw "服务 [$Name] 未达到停用终态：$($after.Actual)。"
    }
}

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 目的与影响明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "disable-gamedvr-user-setting"
        Name    = "GameDVR 游戏录制功能禁用 (HKCU GameDVR_Enabled = 0)"
        Purpose = "关闭当前用户会话的游戏后台自动录像常驻，降低显存占用与显卡硬件编码器静默开销"
        Impact  = "Win+Alt+R 快捷键将无法调起 Windows 自带录屏（推荐使用 OBS 或显卡原生驱动录制）"
        Check   = {
            $val = Get-RegVal "HKCU:\System\GameConfigStore" "GameDVR_Enabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "disable-gamedvr-group-policy"
        Name    = "GameDVR 组策略级全局阻断 (HKLM AllowGameDVR = 0)"
        Purpose = "从系统全局策略阻断 Windows 游戏录像引擎，避免游戏时自动唤醒后台录屏"
        Impact  = "全机所有用户均无法使用 Xbox Game Bar 自带的游戏后台循环回放录制功能"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0
        }
    },
    [PSCustomObject]@{
        Id      = "disable-appcapture-group-policy"
        Name    = "AppCapture 游戏捕获与状态汇报全局阻断 (AppCaptureEnabled = 0)"
        Purpose = "阻断系统级游戏捕获与 GameBar 状态存在 (PresenceWriter) 服务的后台 DCOM 唤起，消除应用启动时的 DCOM 注册超时死等"
        Impact  = "系统彻底停止游戏活动探测与自动游戏录制捕获组件的后台唤醒"
        Check   = {
            $hklm = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AppCaptureEnabled"
            $hkcu = Get-RegVal "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled"
            $isPass = ($hklm -eq "0" -and $hkcu -eq "0")
            return @{
                Actual      = "HKLM=$hklm, HKCU=$hkcu"
                Expected    = "HKLM=0, HKCU=0"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AppCaptureEnabled" 0
            Set-RegDword "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-xblauthmanager"
        Name    = "Xbox Live 身份验证管理服务 (XblAuthManager)"
        Purpose = "停用后台 Xbox 登录与令牌维护服务，消除后台静默轮询请求"
        Impact  = "若玩依赖微软第一方 Xbox Live 账号认证的游戏（如极限竞速地平线），可能会提示无法自动登录 Xbox 账号"
        Check   = {
            Get-ServiceDisableState -Name XblAuthManager
        }
        Apply   = {
            Disable-ManagedService -Name XblAuthManager
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-xblgamesave"
        Name    = "Xbox Live 游戏保存服务 (XblGameSave)"
        Purpose = "停用微软 Xbox 云存档同步后台常驻服务，节约内存"
        Impact  = "Xbox 商店购买的游戏云存档将无法自动双向同步（Steam、Epic 游戏不受任何影响）"
        Check   = {
            Get-ServiceDisableState -Name XblGameSave
        }
        Apply   = {
            Disable-ManagedService -Name XblGameSave
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-xboxgipsvc"
        Name    = "Xbox Accessory 手柄配件管理服务 (XboxGipSvc)"
        Purpose = "停用专属 Xbox 精英手柄配置管理后台服务，降低系统句柄开销"
        Impact  = "标准 Xbox 手柄即插即用（走系统原生 XInput/DInput 驱动）不受影响；仅通过微软官方 Xbox 配件 App 自定义按键映射与震动曲线的功能将不可用"
        Check   = {
            Get-ServiceDisableState -Name XboxGipSvc
        }
        Apply   = {
            Disable-ManagedService -Name XboxGipSvc
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-xboxnetapisvc"
        Name    = "Xbox Live 网络连接配置服务 (XboxNetApiSvc)"
        Purpose = "停用后台 Xbox 对等网络 NAT 探测与 Teredo 隧道连接服务"
        Impact  = "Xbox 主机串流到 PC 或特定使用 Teredo 隧道的 Xbox 联机大厅可能会提示网络类型为中度或受限"
        Check   = {
            Get-ServiceDisableState -Name XboxNetApiSvc
        }
        Apply   = {
            Disable-ManagedService -Name XboxNetApiSvc
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-cdpsvc"
        Name    = "已连接设备平台服务 (CDPSvc)"
        Purpose = "停用跨设备活动漫游与互联发现服务，减少后台局域网广播数据包"
        Impact  = "在手机与电脑之间使用微软官方「继续在电脑上浏览」或邻近共享功能将无法流转会话"
        Check   = {
            Get-ServiceDisableState -Name CDPSvc
        }
        Apply   = {
            Disable-ManagedService -Name CDPSvc
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-phonesvc"
        Name    = "手机连接辅助服务 (PhoneSvc)"
        Purpose = "停用 Windows 手机连接后台服务，消除后台常驻通信通道"
        Impact  = "Windows 11 内置「手机连接」App（与安卓手机同步短信、接打电话、屏幕镜像）将无法连接"
        Check   = {
            Get-ServiceDisableState -Name PhoneSvc
        }
        Apply   = {
            Disable-ManagedService -Name PhoneSvc
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-mapsbroker"
        Name    = "离线地图更新代理服务 (MapsBroker)"
        Purpose = "停用后台离线地图静默轮询与瓦片下载服务，降低磁盘写入"
        Impact  = "Windows 原生自带「地图」App 无法在后台自动静默下载离线城市地图包"
        Check   = {
            Get-ServiceDisableState -Name MapsBroker
        }
        Apply   = {
            Disable-ManagedService -Name MapsBroker
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-pcasvc"
        Name    = "程序兼容性助手服务 (PcaSvc)"
        Purpose = "关闭旧程序运行后的兼容性诊断弹窗，消除应用程序退出后的静默分析挂起"
        Impact  = "运行 15 年以上未适配现代系统的上古老旧安装包时，若发生崩溃，系统不再弹出自动兼容性建议向导"
        Check   = {
            Get-ServiceDisableState -Name PcaSvc
        }
        Apply   = {
            Disable-ManagedService -Name PcaSvc
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-tabletinputservice"
        Name    = "触摸键盘与手写面板服务 (TabletInputService)"
        Purpose = "非触屏设备停用触摸键盘与手写面板后台服务，释放系统句柄"
        Impact  = "在二合一平板模式或触控屏设备上，点击输入框将不会自动弹出屏幕虚拟触摸软键盘（带物理键盘设备完全无影响）"
        Check   = {
            Get-ServiceDisableState -Name TabletInputService
        }
        Apply   = {
            $state = Get-ServiceDisableState -Name TabletInputService
            if ($null -eq $state.Service) { return }
            Disable-ManagedService -Name TabletInputService
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-amd-radeon-bloat"
        Name    = "AMD 显卡控制台开机常驻与后台服务 (APU/笔记本)"
        Purpose = "禁用 AMD Radeon 开机崩溃捕获服务与后台自启任务，降低资源开销"
        Impact  = "AMD 显卡底层图形驱动不受影响，但任务栏托盘不再常驻 Radeon Software 图标，不再提供常驻控制台的游戏滤镜快捷入口"
        Check   = {
            $repo = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages"
            $base = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData"
            $appxClean = $true
            $installedPkgs = @()
            try {
                $installedPkgs = @(Get-ChildItem -Path $repo -ErrorAction Stop | Where-Object { $_.PSChildName -like "*AMDRadeonSoftware*" })
            } catch {
                if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
            }
            if ($installedPkgs.Count -gt 0) {
                foreach ($pkg in $installedPkgs) {
                    $familyName = if ($pkg.PSChildName -match '^([^_]+)_.+_([^_]+)$') { "$($Matches[1])_$($Matches[2])" } else { $pkg.PSChildName }
                    $taskPath = Join-Path (Join-Path $base $familyName) "launcherrsxruntimeTask"
                    try {
                        $item = Get-ItemProperty -Path $taskPath -Name "State" -ErrorAction Stop
                        if ($null -eq $item -or $item.State -ne 1) { $appxClean = $false; break }
                    } catch {
                        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $appxClean = $false; break }
                        throw
                    }
                }
            }
            $s1 = Get-ServiceDisableState -Name 'AMD Crash Defender Service'
            $s2 = Get-ServiceDisableState -Name 'AMD External Events Utility'
            $isPass = ($appxClean -and $s1.IsCompliant -and $s2.IsCompliant)
            return @{
                Actual = "AppxReady=$appxClean; CrashDefender=$($s1.Actual); ExternalEvents=$($s2.Actual)"
                Expected = 'TaskState=1, Services=未安装或 Disabled + Stopped'
                IsCompliant = $isPass
            }
        }
        Apply   = {
            # 服务查询失败时，不先变更此复合项的 Appx 配置。
            $null = Get-ServiceDisableState -Name 'AMD Crash Defender Service'
            $null = Get-ServiceDisableState -Name 'AMD External Events Utility'
            $repo = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages"
            $base = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData"
            $installedPkgs = @()
            try {
                $installedPkgs = @(Get-ChildItem -Path $repo -ErrorAction Stop | Where-Object { $_.PSChildName -like "*AMDRadeonSoftware*" })
            } catch {
                if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
            }
            foreach ($pkg in $installedPkgs) {
                $familyName = if ($pkg.PSChildName -match '^([^_]+)_.+_([^_]+)$') { "$($Matches[1])_$($Matches[2])" } else { $pkg.PSChildName }
                $taskPath = Join-Path (Join-Path $base $familyName) "launcherrsxruntimeTask"
                Ensure-RegKey $taskPath
                Set-RegDword $taskPath "State" 1
            }
            @("AMD Crash Defender Service", "AMD External Events Utility") | ForEach-Object {
                Disable-ManagedService -Name $_
            }
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-nahimicservice"
        Name    = "Nahimic 音效伴生服务 (NahimicService)"
        Purpose = "停用联想等 OEM 预装的 Nahimic 驱动注入服务，根除 audiodg.exe 持续异常高 CPU 负荷与 GUI 进程钩子延迟"
        Impact  = "Nahimic 专属环绕声效控制台不可用；系统原生立体声、Realtek 高清音频与播放设备正常工作"
        Check   = {
            Get-ServiceDisableState -Name NahimicService
        }
        Apply   = {
            Disable-ManagedService -Name NahimicService
        }
    }
)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  边缘后台服务裁剪巡检 (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查")) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$PendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()
$probeErrors = [System.Collections.Generic.List[string]]::new()

foreach ($rule in $Rules) {
    $res = $null
    try {
        $res = & $rule.Check
    } catch {
        $probeErrors.Add("$($rule.Name): $($_.Exception.Message)")
        $res = @{
            Actual      = "<探测异常: $($_.Exception.Message)>"
            Expected    = "<未知>"
            IsCompliant = $false
            IsUnknown   = $true
        }
    }

    $isPass = [bool]$res.IsCompliant
    $actualStr = "$($res.Actual)"
    $expectedStr = "$($res.Expected)"

    $AuditBoard.Add([PSCustomObject]@{
        状态     = if ($isPass) { " ✔" } else { " ▲" }
        规则     = $rule.Name
        实机     = $actualStr
        基线     = $expectedStr
        状态判定 = if ($res.IsUnknown) { "? 未知" } elseif ($isPass) { "✔ 合规" } else { "✘ 偏离" }
    })

    if (-not $isPass -and -not $res.IsUnknown) {
        $PendingItems.Add([PSCustomObject]@{
            Rule        = $rule
            Actual      = $actualStr
            Expected    = $expectedStr
        })
    }
}

Write-Host "`n📊 [巡检看板] 边缘服务原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Select-Object 状态, 规则, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host

if ($probeErrors.Count -gt 0) {
    throw "本模块存在无法确认的属性，未执行任何写入：$($probeErrors -join '; ')"
}

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 边缘后台服务受控属性全部合规，无需调整。`n" -ForegroundColor Green
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

    $gateInput = (Read-Host "`n确认对齐上述 $driftCount 项服务基线？[Y] 确认执行 / [N] 跳过本模块 / [Q] 退出 (默认 Y)").Trim()
    if ($gateInput -notin @('', 'Y', 'N', 'Q')) { throw '无效授权输入；未执行本模块写入。' }
    if ($gateInput -match '^[Qq]$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
    if ($gateInput -match '^[Nn]') {
        Write-Host "[-] 跳过本模块基准对齐。`n" -ForegroundColor DarkGray
        return
    }
}

# 阶段 3: Apply
Write-Host "`n🚀 正在单向对齐边缘服务基线..." -ForegroundColor Cyan
$appliedCount = 0
$applyErrors = [System.Collections.Generic.List[string]]::new()

foreach ($p in $PendingItems) {
    Write-Host -NoNewline ("   - 正在配置: {0} ... " -f $p.Rule.Name)
    try {
        & $p.Rule.Apply
        Write-Host -ForegroundColor Green "[OK]"
        $appliedCount++
    } catch {
        Write-Host -ForegroundColor Red "[FAIL]"
        $applyErrors.Add("$($p.Rule.Name): $($_.Exception.Message)")
        Write-Warning "执行规则 [$($p.Rule.Name)] 失败: $($_.Exception.Message)"
    }
}

if ($applyErrors.Count -gt 0) {
    throw "本模块部分配置失败，已完成 $appliedCount / $driftCount 项：$($applyErrors -join '; ')"
}

# 阶段 4: Report
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host ("  ✅ [服务加固完成] 成功对齐 {0} / {1} 项基线配置" -f $appliedCount, $driftCount) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
