#requires -Version 7.0
<#
.SYNOPSIS
    遥测采集与推广推送阻断基线

.DESCRIPTION
    Windows 11 操作系统遥测阻断、错误报告剥离、广告推送切断与隐私加固基准模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 深度切断 DiagTrack、dmwappushservice、CEIP 与 SQMClient 遥测数据流。
    3. 禁用活动历史跨设备流转 (Project Rome) 与 Windows 错误报告 (WER)。
    4. 禁用跨应用广告标识符 (Advertising ID) 与 ContentDeliveryManager 推广/静默预装通道。
    5. 阻断大版本更新全屏推销 (SCOOBE)、满意度调查 (SIUF) 与开始菜单推广建议。
    6. 启用本地多项剪贴板历史并阻断云端上传，停用 DPS/WDI 诊断策略服务，切断 Edge 后台常驻。
    7. 阻断外设厂商推广套件与驱动协同安装器静默注入 (Razer 等驱动全家桶)。
    8. 组策略底层阻断 Windows 定位系统、物理传感器与位置脚本，强制应用位置权限拒绝 (LetAppsAccessLocation = 2)，停用 lfsvc 服务阻断权限弹窗。
    9. 深度切断键入文本分析、墨迹笔迹识别与通讯录人脉挖掘遥测通道，撤销键入个性化授权。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (只读诊断受控属性对比，零写入安全退出)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\desktop\os\modules\telemetry.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\desktop\os\modules\telemetry.ps1

    # 无交互一键全量对齐
    pwsh -File .\desktop\os\modules\telemetry.ps1 -Yes
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

function Get-ApplicationExperienceTasks {
    $names = @('Microsoft Compatibility Appraiser', 'Microsoft Compatibility Appraiser Exp', 'ProgramDataUpdater', 'StartupAppTask', 'MareBackup', 'PcaPatchDbTask')
    return @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -eq '\Microsoft\Windows\Application Experience\' -and $_.TaskName -cin $names })
}

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 目的与影响明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = 'telemetry-required-diagnostic-data'
        Name    = 'Windows Pro 诊断数据限制为必需级别'
        Purpose = '以 Pro 支持的最低诊断级别关闭可选诊断数据；服务停用另行管理'
        Impact  = 'AllowTelemetry=1 不等于零网络传输，不控制 Defender、更新和额外应用各自的必要服务数据'
        Check   = {
            $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
            return @{ Actual = Get-RegVal $key 'AllowTelemetry'; Expected = '1 (Required)'; IsCompliant = (Test-RegDword $key 'AllowTelemetry' 1) }
        }
        Apply   = { Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1 }
    },
    [PSCustomObject]@{
        Id      = "service-disable-diagtrack"
        Name    = "已连接用户体验和遥测服务 (DiagTrack)"
        Purpose = "停用后台核心遥测采集服务，切断设备使用诊断向微软服务器的定时上报管道，节约系统资源"
        Impact  = "依赖 DiagTrack 的特定微软企业内网运行状况收集 (Endpoint Analytics) 将无法采集该机指标"
        Check   = {
            Get-ServiceDisableState -Name DiagTrack
        }
        Apply   = {
            Disable-ManagedService -Name DiagTrack
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-dmwappushservice"
        Name    = "WAP 设备管理推送路由服务 (dmwappushservice)"
        Purpose = "停用 WAP 设备管理推送消息服务，切断微软下发的静默遥测指令通道"
        Impact  = "若电脑加入由 Microsoft Intune 管理的企业域，通过 WAP 信道下发的部分远程轻量指令可能受影响"
        Check   = {
            Get-ServiceDisableState -Name dmwappushservice
        }
        Apply   = {
            Disable-ManagedService -Name dmwappushservice
        }
    },
    [PSCustomObject]@{
        Id      = "sqm-disable-ceip-enable"
        Name    = "SQMClient 客户体验改善计划策略 (CEIPEnable = 0)"
        Purpose = "组策略级关闭 SQMClient 软件质量度量服务数据采集"
        Impact  = "系统不再生成 SQM 调试记录文件，对日常办公与游戏零负面影响"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows" "CEIPEnable"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows" "CEIPEnable" 0
        }
    },
    [PSCustomObject]@{
        Id      = "wer-disable-policy"
        Name    = "Windows 错误报告全局禁用策略 (WER Disabled = 1)"
        Purpose = "禁止应用程序或系统崩溃时自动向微软提交 Watson 故障 Dump 内存切片与报告，保护内存隐私"
        Impact  = "程序发生异常崩溃后将直接秒级终止，不再弹出「正在检查解决方案」弹窗"
        Check   = {
            $wer = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
            $dis = Get-RegVal $wer "Disabled"
            $dns = Get-RegVal $wer "DontSendAdditionalData"
            $isPass = ($dis -eq "1" -and $dns -eq "1")
            return @{
                Actual      = "Disabled=$dis, DontSendAdditionalData=$dns"
                Expected    = "Disabled=1, DontSendAdditionalData=1"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $wer = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
            Set-RegDword $wer "Disabled" 1
            Set-RegDword $wer "DontSendAdditionalData" 1
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-wersvc"
        Name    = "Windows 错误报告系统服务 (WerSvc)"
        Purpose = "停用后台 WerSvc 服务，崩溃事件直接在本地终止，不再尝试后台排队上报"
        Impact  = "崩溃日志仅保存在系统事件查看器 (Event Viewer)，不再向微软联网同步崩溃记录"
        Check   = {
            Get-ServiceDisableState -Name WerSvc
        }
        Apply   = {
            Disable-ManagedService -Name WerSvc
        }
    },
    [PSCustomObject]@{
        Id      = "tasks-disable-wer-scheduled"
        Name    = "Windows 错误报告后台计划任务 (\Windows Error Reporting\)"
        Purpose = "禁用后台错误报告队列扫描与定期清理计划任务"
        Impact  = "无负面影响"
        Check   = {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Windows Error Reporting\')
            if ($tasks.Count -eq 0) { return @{ Actual = "无 WER 任务"; Expected = "全部禁用"; IsCompliant = $true } }
            $activeCount = ($tasks | Where-Object State -ne 'Disabled').Count
            return @{ Actual = if ($activeCount -eq 0) { "已全部禁用" } else { "$activeCount 项活跃" }; Expected = "全部禁用"; IsCompliant = ($activeCount -eq 0) }
        }
        Apply   = {
            Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Windows Error Reporting\' | Where-Object State -ne 'Disabled' | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            $remaining = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Windows Error Reporting\' | Where-Object State -ne 'Disabled')
            if ($remaining.Count -gt 0) { throw "WER 计划任务禁用后校验失败：$($remaining.TaskName -join ', ')" }
        }
    },
    [PSCustomObject]@{
        Id      = "tasks-disable-ceip-scheduled"
        Name    = "客户体验改善计划后台任务 (\Customer Experience Improvement Program\)"
        Purpose = "禁用 ConsolidatedTelemetry 等定期盘查用户软件使用习惯的后台计划任务"
        Impact  = "无负面影响"
        Check   = {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Customer Experience Improvement Program\')
            if ($tasks.Count -eq 0) { return @{ Actual = "无 CEIP 任务"; Expected = "全部禁用"; IsCompliant = $true } }
            $activeCount = ($tasks | Where-Object State -ne 'Disabled').Count
            return @{ Actual = if ($activeCount -eq 0) { "已全部禁用" } else { "$activeCount 项活跃" }; Expected = "全部禁用"; IsCompliant = ($activeCount -eq 0) }
        }
        Apply   = {
            Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Customer Experience Improvement Program\' | Where-Object State -ne 'Disabled' | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            $remaining = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Customer Experience Improvement Program\' | Where-Object State -ne 'Disabled')
            if ($remaining.Count -gt 0) { throw "CEIP 计划任务禁用后校验失败：$($remaining.TaskName -join ', ')" }
        }
    },
    [PSCustomObject]@{
        Id      = "tasks-disable-appexperience-scheduled"
        Name    = "应用程序体验兼容性后台任务 (\Application Experience\)"
        Purpose = "禁用 Microsoft Compatibility Appraiser 等大量消耗 CPU 盘查已装软件的后台扫描任务"
        Impact  = "Windows 不再向微软服务器提交设备软硬件清单用以评估 Windows 12 潜在升级资格"
        Check   = {
            $tasks = @(Get-ApplicationExperienceTasks)
            if ($tasks.Count -eq 0) { return @{ Actual = "无 AppExperience 遥测任务"; Expected = "全部禁用"; IsCompliant = $true } }
            $active = @($tasks | Where-Object State -ne 'Disabled')
            $actStr = if ($active.Count -eq 0) { "已全部禁用" } else { "$($active.Count) 项活跃 ($($active.TaskName -join ', '))" }
            return @{ Actual = $actStr; Expected = "全部禁用"; IsCompliant = ($active.Count -eq 0) }
        }
        Apply   = {
            Get-ApplicationExperienceTasks | Where-Object State -ne 'Disabled' | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            if (@(Get-ApplicationExperienceTasks | Where-Object State -ne 'Disabled').Count -gt 0) { throw '目标兼容性任务仍有启用项。' }
        }
    },
    [PSCustomObject]@{
        Id      = "project-rome-disable-activity-feed"
        Name    = "活动信息流跨设备流转切断 (EnableActivityFeed = 0)"
        Purpose = "组策略级关闭时间线与活动流，防止桌面操作轨迹在同账号设备间漫游广播"
        Impact  = "无法通过 Windows 时间线回顾几天前打开的文档历史"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0
        }
    },
    [PSCustomObject]@{
        Id      = "project-rome-disable-publish-activities"
        Name    = "用户活动发布切断 (PublishUserActivities = 0)"
        Purpose = "禁止系统向微软 Project Rome 中枢发布打开文件、浏览网页等用户操作"
        Impact  = "其他登录同微软账号的 Windows 设备无法同步此台电脑的操作快照"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" 0
        }
    },
    [PSCustomObject]@{
        Id      = "project-rome-disable-upload-activities"
        Name    = "用户活动云端上传切断 (UploadUserActivities = 0)"
        Purpose = "禁止将活动历史数据同步上传至微软云端服务器"
        Impact  = "微软账号网页端「隐私仪表板」中将不再呈现此设备的活动数据"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" 0
        }
    },
    [PSCustomObject]@{
        Id      = "project-rome-disable-mmx"
        Name    = "跨设备活动体验匹配调度切断 (EnableMmx = 0)"
        Purpose = "切断 Project Rome (Match Maker eXperience) 后台跨设备活动事件匹配与状态推送通道"
        Impact  = "设备不再接收或分发其他关联 Windows 设备的跨机流转事件"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableMmx"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableMmx" 0
        }
    },
    [PSCustomObject]@{
        Id      = "privacy-disable-tailored-experiences"
        Name    = "基于诊断数据的量身定制体验切断 (TailoredExperiences = 0)"
        Purpose = "禁止微软依据收集的遥测与应用数据向用户个性化推送营销建议与广告"
        Impact  = "系统提示与推荐不再结合个人使用习惯做个性化推荐（保持通用纯净）"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "telemetry-disable-advertising-id"
        Name    = "跨应用个性化广告标识符禁用 (AdvertisingInfo Enabled = 0)"
        Purpose = "关闭系统为本机分配的唯一广告 ID，切断应用与第三方广告联盟跨应用的商业行为追踪"
        Impact  = "应用内可能展示通用广告，但不再基于用户跨应用的行为画像推送精准商业广告"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "privacy-disable-http-language-list"
        Name    = "网站访问语言列表优化切断 (HttpAcceptLanguageOptOut = 1)"
        Purpose = "禁止系统向访问的网站泄露用户完整的本地已安装语言优先级列表，降低浏览器指纹暴露面"
        Impact  = "极少数多语言自适应网站可能默认展示英文而非用户偏好的小语种（主流网站走浏览器设置不受影响）"
        Check   = {
            $val = Get-RegVal "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 1
        }
    },
    [PSCustomObject]@{
        Id      = "cdm-disable-content-delivery"
        Name    = "内容传送管理器主通道阻断 (ContentDeliveryAllowed = 0)"
        Purpose = "切断 ContentDeliveryManager 后台主要传送通道，阻断云端商业推广内容静默注入"
        Impact  = "系统不再主动从云端拉取 Windows 推广内容与商业卡片"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "ContentDeliveryAllowed"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "ContentDeliveryAllowed" 0
        }
    },
    [PSCustomObject]@{
        Id      = "cdm-disable-oem-preinstalled-apps"
        Name    = "OEM 出厂合作推广应用静默装配阻断 (OemPreInstalledAppsEnabled = 0)"
        Purpose = "阻断系统依据硬件厂商 OEM 合作协议在后台静默下发第三方预装捆绑软件"
        Impact  = "新用户配置文件创建时不自动拉取硬件厂商关联的推广 UWP 应用"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "OemPreInstalledAppsEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "OemPreInstalledAppsEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "cdm-disable-preinstalled-apps"
        Name    = "微软云端预装推荐应用装配阻断 (PreInstalledAppsEnabled = 0)"
        Purpose = "阻断 ContentDeliveryManager 从微软服务器静默分发精选推广应用"
        Impact  = "消除开始菜单中静默冒出的三方推荐磁贴与应用占位符"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "PreInstalledAppsEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "PreInstalledAppsEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "cdm-disable-silent-installed-apps"
        Name    = "推广应用静默安装开关 (SilentInstalledAppsEnabled = 0)"
        Purpose = "切断 ContentDeliveryManager 后台静默抓取商业推广软件通道"
        Impact  = "无负面影响"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SilentInstalledAppsEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SilentInstalledAppsEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "cdm-disable-system-pane-suggestions"
        Name    = "开始菜单系统窗格建议开关 (SystemPaneSuggestionsEnabled = 0)"
        Purpose = "关闭开始菜单搜索窗格与系统通知中的功能与第三方推广气泡"
        Impact  = "系统不再推荐 Windows 新特性操作技巧"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SystemPaneSuggestionsEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SystemPaneSuggestionsEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "cdm-disable-tips-and-welcome-experience"
        Name    = "Windows 欢迎体验与技巧提示推广切断 (SubscribedContent = 0)"
        Purpose = "切断 ContentDeliveryManager 在设置应用、更新后全屏欢迎页以及日常操作中弹出的使用技巧与功能推广气泡"
        Impact  = "系统不会在更新后弹出「让我们完成设备设置」或「Windows 欢迎体验」建议页面，设置界面不展示推荐广告"
        Check   = {
            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            $keys = @("SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled", "SubscribedContent-310093Enabled", "SubscribedContent-353694Enabled", "SubscribedContent-353696Enabled")
            $isPass = $true
            $nonZero = [System.Collections.Generic.List[string]]::new()
            foreach ($k in $keys) {
                $v = Get-RegVal $cdm $k
                if ($v -ne "0") { $isPass = $false; $nonZero.Add("$k=$v") }
            }
            return @{
                Actual      = if ($isPass) { "已全部切断 (0)" } else { "未关闭: $($nonZero -join ', ')" }
                Expected    = "已全部切断 (0)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            @("SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled", "SubscribedContent-310093Enabled", "SubscribedContent-353694Enabled", "SubscribedContent-353696Enabled") | ForEach-Object {
                Set-RegDword $cdm $_ 0
            }
        }
    },
    [PSCustomObject]@{
        Id      = "scoobe-disable-system-setting"
        Name    = "大版本更新 SCOOBE 全屏推销页面 (ScoobeSystemSettingEnabled = 0)"
        Purpose = "大版本更新或补丁安装后登录时，跳过推销 Microsoft 365/OneDrive 的全屏欢迎页"
        Impact  = "无法查阅微软在大版本更新后展示的新功能全屏幻灯片说明"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "telemetry-disable-siuf-feedback"
        Name    = "系统反馈与满意度调查弹窗切断 (NumberOfSIUFInPeriod = 0)"
        Purpose = "将 Windows 意见反馈与满意度调查（SIUF）触发频率强制固化为 0（从不请求反馈），消除右下角打扰弹窗"
        Impact  = "系统不再主动弹窗询问体验反馈，但用户仍可手动打开「反馈中心」主动提交问题"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod" 0
        }
    },
    [PSCustomObject]@{
        Id      = "clipboard-enable-local-history"
        Name    = "本地多项剪贴板历史记录启用 (EnableClipboardHistory = 1)"
        Purpose = "开启本地多项剪贴板历史功能（快捷键 Win+V 呼出），保留最近复制的多段文本与截图，提升文字处理与编码效率"
        Impact  = "剪贴板可保存敏感文本；固定条目可跨重启保留，关闭云同步不等于本地内容不可读取"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Clipboard" "EnableClipboardHistory"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Clipboard" "EnableClipboardHistory" 1
        }
    },
    [PSCustomObject]@{
        Id      = "clipboard-disable-cross-device"
        Name    = "跨设备剪贴板云端上传切断 (AllowCrossDeviceClipboard = 0)"
        Purpose = "组策略级禁止将 Win+V 剪贴板历史上传至微软云端服务器，保障复制的密码与敏感凭据安全"
        Impact  = "保留本地多项剪贴板历史功能，但在手机或其他电脑上按 Win+V 无法粘贴本台电脑刚刚复制的文字"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "AllowCrossDeviceClipboard"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "AllowCrossDeviceClipboard" 0
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-dps"
        Name    = "诊断策略服务停用 (DPS = Disabled)"
        Purpose = "停用后台诊断策略引擎，消除静默系统事件扫描与日志记录开销"
        Impact  = "系统自带的「疑难解答」向导（如自动检测网络故障并重置适配器）在诊断时可能提示服务未启动"
        Check   = {
            Get-ServiceDisableState -Name DPS
        }
        Apply   = {
            Disable-ManagedService -Name DPS
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-wdiservicehost"
        Name    = "诊断服务主机停用 (WdiServiceHost = Disabled)"
        Purpose = "停用后台诊断宿主服务，消除后台间歇性唤醒扫描"
        Impact  = "Windows 性能监视器中关于开机引导耗时与关机耗时的诊断事件跟踪将停止记录"
        Check   = {
            Get-ServiceDisableState -Name WdiServiceHost
        }
        Apply   = {
            Disable-ManagedService -Name WdiServiceHost
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-wdisystemhost"
        Name    = "诊断系统主机停用 (WdiSystemHost = Disabled)"
        Purpose = "停用底层诊断系统宿主服务，切断本地诊断策略对系统状态的后台定时轮询"
        Impact  = "依赖系统级 Wdi 诊断跟踪的硬件分析工具将无法收集故障日志"
        Check   = {
            Get-ServiceDisableState -Name WdiSystemHost
        }
        Apply   = {
            Disable-ManagedService -Name WdiSystemHost
        }
    },
    [PSCustomObject]@{
        Id      = "task-disable-windows-diagnosis"
        Name    = "系统诊断后台计划任务禁用 (\Microsoft\Windows\Diagnosis\)"
        Purpose = "禁用 Windows 诊断框架下属的后台自启扫描计划任务，释放 CPU 周期与磁盘 I/O 资源"
        Impact  = "系统不再在空闲时段自动执行诊断健康度分析任务"
        Check   = {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Diagnosis\')
            if ($tasks.Count -eq 0) { return @{ Actual = "无诊断任务"; Expected = "全部禁用"; IsCompliant = $true } }
            $activeCount = ($tasks | Where-Object State -ne 'Disabled').Count
            return @{ Actual = if ($activeCount -eq 0) { "已全部禁用" } else { "$activeCount 项活跃" }; Expected = "全部禁用"; IsCompliant = ($activeCount -eq 0) }
        }
        Apply   = {
            Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Diagnosis\' | Where-Object State -ne 'Disabled' | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            $remaining = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskPath -eq '\Microsoft\Windows\Diagnosis\' | Where-Object State -ne 'Disabled')
            if ($remaining.Count -gt 0) { throw "系统诊断计划任务禁用后校验失败：$($remaining.TaskName -join ', ')" }
        }
    },
    [PSCustomObject]@{
        Id      = "edge-disable-background-mode"
        Name    = "Edge 浏览器开机后台常驻切断 (BackgroundModeEnabled = 0)"
        Purpose = "禁止 Edge 浏览器在系统开机时无故在后台常驻多个子进程静默吃内存"
        Impact  = "若使用依赖 Edge 后台推送特定 Web 消息的 PWA 离线应用，关闭 Edge 窗口后可能收不到即时通知"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "BackgroundModeEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "BackgroundModeEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "edge-disable-startup-boost"
        Name    = "Edge 浏览器启动加速预加载切断 (StartupBoostEnabled = 0)"
        Purpose = "关闭 Edge 启动加速，禁止其在后台预加载标签页和渲染引擎"
        Impact  = "首次冷启动 Edge 浏览器时窗口打开速度可能略慢 0.5 秒左右（现代固态硬盘基本无感）"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupBoostEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupBoostEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "peripheral-disable-coinstallers"
        Name    = "外设厂商驱动协同安装器注入阻断 (DisableCoInstallers = 1)"
        Purpose = "插入鼠标/键盘等外设时，禁止驱动程序静默唤醒第三方协同安装向导与捆绑全家桶"
        Impact  = "插入需要专用驱动协同包初始化的特种硬件时，需用户手动前往官网下载驱动安装器"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings" "DisableCoInstallers"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings" "DisableCoInstallers" 1
        }
    },
    [PSCustomObject]@{
        Id      = "peripheral-prevent-device-metadata"
        Name    = "外设元数据网络检索阻断 (PreventDeviceMetadataFromNetwork = 1)"
        Purpose = "禁止系统向微软服务器查询外设高清图标与附加应用包，提升即插即用响应"
        Impact  = "在控制面板「设备和打印机」中，某些特定品牌外设将仅显示通用外设图标，而非渲染图"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata" "PreventDeviceMetadataFromNetwork"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata" "PreventDeviceMetadataFromNetwork" 1
        }
    },
    [PSCustomObject]@{
        Id      = "peripheral-block-razer-installer"
        Name    = "Razer 驱动安装器映像劫持阻断 (IFEO RazerInstaller.exe = systray.exe)"
        Purpose = "通过 IFEO 映像劫持阻断插入雷蛇设备时弹出的强制静默安装全家桶弹窗"
        Impact  = "若用户本身是雷蛇硬件重度用户且需要依赖 Razer Synapse 雷云软件，弹窗被屏蔽后需手动从官网下载雷云"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RazerInstaller.exe" "Debugger"
            return @{ Actual = $val; Expected = "systray.exe"; IsCompliant = ($val -eq "systray.exe") }
        }
        Apply   = {
            $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RazerInstaller.exe"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "Debugger" -Value "systray.exe" -Force
            if ((Get-RegVal $key "Debugger") -ne "systray.exe") {
                throw "Razer IFEO 劫持策略写入后校验失败：$key\Debugger"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "location-disable-system"
        Name    = "全局地理位置系统级阻断 (DisableLocation = 1)"
        Purpose = "企业策略级关闭 Windows 11 全局定位系统，禁止操作系统探测设备物理坐标"
        Impact  = "系统定位功能完全关闭，应用将无法通过系统位置 API 获知地理坐标"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" 1
        }
    },
    [PSCustomObject]@{
        Id      = "location-disable-scripting"
        Name    = "位置脚本接口调用阻断 (DisableLocationScripting = 1)"
        Purpose = "阻断系统脚本与托管环境访问位置 API，防止后台通过脚本刺探物理位置"
        Impact  = "脚本引擎与自动化运行时无法读取物理位置上下文"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocationScripting"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocationScripting" 1
        }
    },
    [PSCustomObject]@{
        Id      = "location-disable-sensors"
        Name    = "环境与物理传感器全局禁用 (DisableSensors = 1)"
        Purpose = "关闭系统环境光、陀螺仪、加速度计等物理传感器接口，消除硬件侧信道探测"
        Impact  = "平板/二合一设备的屏幕自动旋转与环境光感自适应亮度将被关闭"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableSensors"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableSensors" 1
        }
    },
    [PSCustomObject]@{
        Id      = "location-disable-windows-provider"
        Name    = "Windows 定位服务提供程序切断 (DisableWindowsLocationProvider = 1)"
        Purpose = "禁止系统向微软定位云端查询物理位置，切断 Wi-Fi BSSID 扫描与 IP 反查定位"
        Impact  = "Windows 不再向微软服务器发送周边 Wi-Fi 热点 MAC 地址与网络反查请求"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableWindowsLocationProvider"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableWindowsLocationProvider" 1
        }
    },
    [PSCustomObject]@{
        Id      = "appprivacy-deny-location"
        Name    = "应用位置权限策略强制静默拒绝 (LetAppsAccessLocation = 2)"
        Purpose = "通过企业组策略强制将所有应用的位置访问权限置为拒绝，避免系统弹出位置权限请求或访问通知横幅"
        Impact  = "应用请求位置权限时底层直接静默返回拒绝，系统外壳绝不再弹出位置授权提示或通知"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsAccessLocation"
            return @{ Actual = $val; Expected = "2"; IsCompliant = ($val -eq "2") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsAccessLocation" 2
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-lfsvc"
        Name    = "地理位置支持服务停用与禁用 (lfsvc = Disabled)"
        Purpose = "停用底层地理位置支持服务 (lfsvc)，阻断位置 API 轮询与权限弹窗触发通道"
        Impact  = "应用与浏览器调用定位 API 时直接返回失败或不可用，系统外壳绝不再弹出位置授权打扰弹窗"
        Check   = {
            Get-ServiceDisableState -Name lfsvc
        }
        Apply   = {
            Disable-ManagedService -Name lfsvc
        }
    },
    [PSCustomObject]@{
        Id      = "privacy-disable-input-personalization-ink"
        Name    = "输入个性化墨迹分析策略切断 (InputPersonalization RestrictInk = 1)"
        Purpose = "关闭微软手写识别自动学习的墨迹采集，不等于关闭所有网络上传"
        Impact  = "微软识别器的相关自动学习停止；已有学习数据可由该策略删除"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" "RestrictImplicitInkCollection"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" 1
        }
    },
    [PSCustomObject]@{
        Id      = "privacy-disable-input-personalization-text"
        Name    = "输入个性化文本键入分析策略切断 (InputPersonalization RestrictText = 1)"
        Purpose = "关闭微软手写识别自动学习的文本采集，不控制第三方输入法"
        Impact  = "影响微软手写识别个性化，不是系统全局击键记录或网络隔离控制"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" "RestrictImplicitTextCollection"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" 1
        }
    },
    [PSCustomObject]@{
        Id      = "privacy-disable-contacts-harvesting"
        Name    = "输入法通讯录人脉挖掘切断 (HarvestContacts = 0)"
        Purpose = "禁止输入法从人脉与通讯录中挖掘联系人姓名与关系网用作联想词库"
        Impact  = "输入法不会自动将通讯录人名作为高频联想词"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore" "HarvestContacts"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore" "HarvestContacts" 0
        }
    },
    [PSCustomObject]@{
        Id      = "privacy-disable-personalization-accepted"
        Name    = "墨迹书写与键入个性化隐私授权撤销 (AcceptedPrivacyPolicy = 0)"
        Purpose = "撤销墨迹书写和键入个性化隐私协议授权，将系统内部键入画像重置为未授权状态"
        Impact  = "系统不再在后台建立用户的专属键入行为画像"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Personalization\Settings" "AcceptedPrivacyPolicy"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Personalization\Settings" "AcceptedPrivacyPolicy" 0
        }
    }
)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  遥测采集与推广推送阻断基线巡检 (pwsh 7+)" -ForegroundColor Cyan
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

Write-Host "`n📊 [巡检看板] 遥测阻断原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Select-Object 状态, 规则, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host

if ($probeErrors.Count -gt 0) {
    throw "本模块存在无法确认的属性，未执行任何写入：$($probeErrors -join '; ')"
}

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 遥测采集与推广推送阻断基线全部合规，无需调整。`n" -ForegroundColor Green
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

    $gateInput = (Read-Host "`n确认对齐上述 $driftCount 项遥测阻断基线？[Y] 确认执行 / [N] 跳过本模块 / [Q] 退出 (默认 Y)").Trim()
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
Write-Host "`n🚀 正在单向对齐遥测与推广阻断基线..." -ForegroundColor Cyan
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
Write-Host ("  ✅ [遥测加固完成] 成功对齐 {0} / {1} 项基线配置" -f $appliedCount, $driftCount) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
