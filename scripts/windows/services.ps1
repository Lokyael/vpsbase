#requires -Version 7.0
<#
.SYNOPSIS
    边缘后台服务与遥测计划任务剥离基线

.DESCRIPTION
    Windows 11 操作系统边缘服务裁剪、Xbox 生态剥离与后台遥测计划任务禁用模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 彻底剥离 Xbox 生态、GameDVR 录屏常驻与后台联机服务（XblAuthManager, XblGameSave 等）。
    3. 禁用跨设备流转连接平台 (CDPSvc)、手机服务 (PhoneSvc) 与离线地图代理 (MapsBroker)。
    4. 停用程序兼容性助手服务 (PcaSvc) 与触摸键盘手写面板服务 (TabletInputService)。
    5. 扫描并禁用 Microsoft Office 后台遥测计划任务。
    6. 禁用 AMD 显卡控制台开机常驻与后台服务 (针对 APU/笔记本轻量化，仅 Full)。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (100% 只读诊断受控属性对比，零写入安全退出)

.PARAMETER Profile
    加固预设:
    - Full    : 全量基线 (默认，覆盖全量受控规则)
    - General : 通用基线 (仅覆盖通用受控规则，跳过深度裁剪项)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\scripts\windows\services.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\scripts\windows\services.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\services.ps1 -Yes
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
    if ($null -ne $val) { return "$val" }
    return $Default
}

function Test-RegDword {
    param([string]$Path, [string]$Name, [int]$ExpectedValue)
    if (-not (Test-Path $Path)) { return $false }
    $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    return ($null -ne $val -and [int]$val -eq $ExpectedValue)
}

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 目的与影响明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "disable-gamedvr-user-setting"
        Name    = "GameDVR 游戏录制功能禁用 (HKCU GameDVR_Enabled = 0)"
        Profile = "General"
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
        Profile = "General"
        Purpose = "从系统全局策略阻断 Windows 游戏录像引擎，杜绝游戏时自动唤醒后台录屏"
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
        Id      = "service-disable-xblauthmanager"
        Name    = "Xbox Live 身份验证管理服务 (XblAuthManager)"
        Profile = "General"
        Purpose = "停用后台 Xbox 登录与令牌维护服务，消除后台静默轮询请求"
        Impact  = "若玩依赖微软第一方 Xbox Live 账号认证的游戏（如极限竞速地平线），可能会提示无法自动登录 Xbox 账号"
        Check   = {
            $s = Get-Service -Name XblAuthManager -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name XblAuthManager -Force -ErrorAction SilentlyContinue
            Set-Service -Name XblAuthManager -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-xblgamesave"
        Name    = "Xbox Live 游戏保存服务 (XblGameSave)"
        Profile = "General"
        Purpose = "停用微软 Xbox 云存档同步后台常驻服务，节约内存"
        Impact  = "Xbox 商店购买的游戏云存档将无法自动双向同步（Steam、Epic 游戏不受任何影响）"
        Check   = {
            $s = Get-Service -Name XblGameSave -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name XblGameSave -Force -ErrorAction SilentlyContinue
            Set-Service -Name XblGameSave -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-xboxgipsvc"
        Name    = "Xbox Accessory 手柄配件管理服务 (XboxGipSvc)"
        Profile = "General"
        Purpose = "停用专属 Xbox 精英手柄配置管理后台服务，降低系统句柄开销"
        Impact  = "标准 Xbox 手柄即插即用（走系统原生 XInput/DInput 驱动）不受影响；仅通过微软官方 Xbox 配件 App 自定义按键映射与震动曲线的功能将不可用"
        Check   = {
            $s = Get-Service -Name XboxGipSvc -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name XboxGipSvc -Force -ErrorAction SilentlyContinue
            Set-Service -Name XboxGipSvc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-xboxnetapisvc"
        Name    = "Xbox Live 网络连接配置服务 (XboxNetApiSvc)"
        Profile = "General"
        Purpose = "停用后台 Xbox 对等网络 NAT 探测与 Teredo 隧道连接服务"
        Impact  = "Xbox 主机串流到 PC 或特定使用 Teredo 隧道的 Xbox 联机大厅可能会提示网络类型为中度或受限"
        Check   = {
            $s = Get-Service -Name XboxNetApiSvc -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name XboxNetApiSvc -Force -ErrorAction SilentlyContinue
            Set-Service -Name XboxNetApiSvc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-cdpsvc"
        Name    = "已连接设备平台服务 (CDPSvc)"
        Profile = "General"
        Purpose = "停用跨设备活动漫游与互联发现服务，减少后台局域网广播数据包"
        Impact  = "在手机与电脑之间使用微软官方「继续在电脑上浏览」或邻近共享功能将无法流转会话"
        Check   = {
            $s = Get-Service -Name CDPSvc -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name CDPSvc -Force -ErrorAction SilentlyContinue
            Set-Service -Name CDPSvc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-phonesvc"
        Name    = "手机连接辅助服务 (PhoneSvc)"
        Profile = "General"
        Purpose = "停用 Windows 手机连接后台服务，消除后台常驻通信通道"
        Impact  = "Windows 11 内置「手机连接」App（与安卓手机同步短信、接打电话、屏幕镜像）将无法连接"
        Check   = {
            $s = Get-Service -Name PhoneSvc -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name PhoneSvc -Force -ErrorAction SilentlyContinue
            Set-Service -Name PhoneSvc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-mapsbroker"
        Name    = "离线地图更新代理服务 (MapsBroker)"
        Profile = "General"
        Purpose = "停用后台离线地图静默轮询与瓦片下载服务，降低磁盘写入"
        Impact  = "Windows 原生自带「地图」App 无法在后台自动静默下载离线城市地图包"
        Check   = {
            $s = Get-Service -Name MapsBroker -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name MapsBroker -Force -ErrorAction SilentlyContinue
            Set-Service -Name MapsBroker -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-pcasvc"
        Name    = "程序兼容性助手服务 (PcaSvc)"
        Profile = "General"
        Purpose = "关闭旧程序运行后的兼容性诊断弹窗，消除应用程序退出后的静默分析挂起"
        Impact  = "运行 15 年以上未适配现代系统的上古老旧安装包时，若发生崩溃，系统不再弹出自动兼容性建议向导"
        Check   = {
            $s = Get-Service -Name PcaSvc -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name PcaSvc -Force -ErrorAction SilentlyContinue
            Set-Service -Name PcaSvc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "task-disable-office-telemetry"
        Name    = "Office 后台遥测计划任务禁用 (\Microsoft\Office\)"
        Profile = "General"
        Purpose = "停用 Microsoft Office 安装自带的每日遥测与使用数据上传计划任务"
        Impact  = "微软将无法收集 Office 崩溃上报与使用习惯度量；Office 本地 Word/Excel/PPT 离线功能完全不受任何影响"
        Check   = {
            $tasks = @(Get-ScheduledTask -TaskPath "\Microsoft\Office\" -ErrorAction SilentlyContinue)
            if ($tasks.Count -eq 0) { return @{ Actual = "无 Office 任务"; Expected = "全部禁用"; IsCompliant = $true } }
            $activeCount = ($tasks | Where-Object State -ne 'Disabled').Count
            return @{ Actual = if ($activeCount -eq 0) { "已全部禁用" } else { "$activeCount 项活跃" }; Expected = "全部禁用"; IsCompliant = ($activeCount -eq 0) }
        }
        Apply   = {
            Get-ScheduledTask -TaskPath "\Microsoft\Office\" -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-tabletinputservice"
        Name    = "触摸键盘与手写面板服务 (TabletInputService)"
        Profile = "General"
        Purpose = "非触屏台式机/笔记本停用触控键盘常驻，释放系统句柄并强杀 TabTip 进程"
        Impact  = "在二合一平板模式或触控屏设备上，点击输入框将不会自动弹出屏幕虚拟触摸软键盘（带物理键盘设备完全无影响）"
        Check   = {
            $s = Get-Service -Name TabletInputService -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = (-not $s -or $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name TabletInputService -Force -ErrorAction SilentlyContinue
            Set-Service -Name TabletInputService -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Process -Name TabTip -Force -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-amd-radeon-bloat"
        Name    = "AMD 显卡控制台开机常驻与后台服务 (APU/笔记本)"
        Profile = "Full"
        Purpose = "禁用 AMD Radeon 开机崩溃捕获服务与托盘进程，释放 200MB+ 内存"
        Impact  = "AMD 显卡底层图形驱动不受影响，但任务栏托盘不再常驻 Radeon Software 图标，若需随时通过快捷键调出游戏滤镜请选 General"
        Check   = {
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
            $isPass = ($appxClean -and $svcClean)
            return @{ Actual = if ($isPass) { "已纯净化" } else { "未完全禁用" }; Expected = "TaskState=1, Services=Disabled"; IsCompliant = $isPass }
        }
        Apply   = {
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

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  边缘后台服务与遥测计划任务剥离巡检 (pwsh 7+)" -ForegroundColor Cyan
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

Write-Host "`n📊 [巡检看板] 边缘服务与计划任务原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 边缘后台服务与遥测计划任务全部合规，无需调整。`n" -ForegroundColor Green
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
Write-Host "`n🚀 正在单向对齐服务与计划任务基线..." -ForegroundColor Cyan
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
Write-Host ("  ✅ [服务加固完成] 成功对齐 {0} / {1} 项基线配置 (预设: {2})" -f $appliedCount, $driftCount, $Profile) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
