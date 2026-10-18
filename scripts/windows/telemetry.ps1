#requires -Version 7.0
<#
.SYNOPSIS
    遥测采集与推广推送阻断基线

.DESCRIPTION
    Windows 11 操作系统遥测阻断、错误报告剥离、广告推送切断与隐私加固基准模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 深度切断 DiagTrack、dmwappushservice、CEIP 与 SQMClient 遥测数据流。
    3. 禁用活动历史跨设备流转 (Project Rome) 与 Windows 错误报告 (WER)。
    4. 阻断 CloudContent 消费级静默预装、更新全屏推销 (SCOOBE) 与开始菜单推广建议。
    5. 限制剪贴板历史仅限本地，停用 DPS/WDI 诊断策略服务，切断 Edge 后台常驻。
    6. 阻断外设厂商推广套件与驱动协同安装器静默注入 (Razer 等驱动全家桶，仅 Full)。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (100% 只读诊断受控属性对比，零写入安全退出)

.PARAMETER Profile
    加固预设:
    - Full    : 个人黄金深度基线 (默认，极致性能与全域深度加固)
    - General : 通用稳健基线 (保守兼容，跳过阻断外设厂商驱动协同安装器等激进项)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\scripts\windows\telemetry.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\scripts\windows\telemetry.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\telemetry.ps1 -Yes
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
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 目的与影响明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "telemetry-allow-telemetry-zero"
        Name    = "诊断遥测数据收集级别 (AllowTelemetry = 0)"
        Profile = "General"
        Purpose = "通过企业组策略将 Windows 11 遥测数据收集级别强制锁定为关闭 (0)，禁止上传使用数据"
        Impact  = "微软将不再接收系统故障与功能使用率度量，无法参与 Windows 预览体验计划诊断"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "MaxTelemetryAllowed" 0
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-diagtrack"
        Name    = "已连接用户体验和遥测服务 (DiagTrack)"
        Profile = "General"
        Purpose = "停用后台核心遥测采集服务，切断设备使用诊断向微软服务器的定时上报管道，节约系统资源"
        Impact  = "依赖 DiagTrack 的特定微软企业内网运行状况收集 (Endpoint Analytics) 将无法采集该机指标"
        Check   = {
            $s = Get-Service -Name DiagTrack -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name DiagTrack -Force -ErrorAction SilentlyContinue
            Set-Service -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-dmwappushservice"
        Name    = "WAP 设备管理推送路由服务 (dmwappushservice)"
        Profile = "General"
        Purpose = "停用 WAP 设备管理推送消息服务，切断微软下发的静默遥测指令通道"
        Impact  = "若电脑加入由 Microsoft Intune 管理的企业域，通过 WAP 信道下发的部分远程轻量指令可能受影响"
        Check   = {
            $s = Get-Service -Name dmwappushservice -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name dmwappushservice -Force -ErrorAction SilentlyContinue
            Set-Service -Name dmwappushservice -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "sqm-disable-ceip-enable"
        Name    = "SQMClient 客户体验改善计划策略 (CEIPEnable = 0)"
        Profile = "General"
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
        Profile = "General"
        Purpose = "禁止应用程序或系统崩溃时自动向微软提交 Watson 故障 Dump 内存切片与报告，保护内存隐私"
        Impact  = "程序发生异常崩溃后将直接秒级终止，不再弹出「正在检查解决方案」弹窗"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            $wer = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
            Set-RegDword $wer "Disabled" 1
            Set-RegDword $wer "DoNotSendAdditionalData" 1
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-wersvc"
        Name    = "Windows 错误报告系统服务 (WerSvc)"
        Profile = "General"
        Purpose = "停用后台 WerSvc 服务，崩溃事件直接在本地终止，不再尝试后台排队上报"
        Impact  = "崩溃日志仅保存在系统事件查看器 (Event Viewer)，不再向微软联网同步崩溃记录"
        Check   = {
            $s = Get-Service -Name WerSvc -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name WerSvc -Force -ErrorAction SilentlyContinue
            Set-Service -Name WerSvc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "tasks-disable-wer-scheduled"
        Name    = "Windows 错误报告后台计划任务 (\Windows Error Reporting\)"
        Profile = "General"
        Purpose = "禁用后台错误报告队列扫描与定期清理计划任务"
        Impact  = "无负面影响"
        Check   = {
            $tasks = @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\Windows Error Reporting\" -ErrorAction SilentlyContinue)
            if ($tasks.Count -eq 0) { return @{ Actual = "无 WER 任务"; Expected = "全部禁用"; IsCompliant = $true } }
            $activeCount = ($tasks | Where-Object State -ne 'Disabled').Count
            return @{ Actual = if ($activeCount -eq 0) { "已全部禁用" } else { "$activeCount 项活跃" }; Expected = "全部禁用"; IsCompliant = ($activeCount -eq 0) }
        }
        Apply   = {
            Get-ScheduledTask -TaskPath "\Microsoft\Windows\Windows Error Reporting\" -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "tasks-disable-ceip-scheduled"
        Name    = "客户体验改善计划后台任务 (\Customer Experience Improvement Program\)"
        Profile = "General"
        Purpose = "禁用 ConsolidatedTelemetry 等定期盘查用户软件使用习惯的后台计划任务"
        Impact  = "无负面影响"
        Check   = {
            $tasks = @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\Customer Experience Improvement Program\" -ErrorAction SilentlyContinue)
            if ($tasks.Count -eq 0) { return @{ Actual = "无 CEIP 任务"; Expected = "全部禁用"; IsCompliant = $true } }
            $activeCount = ($tasks | Where-Object State -ne 'Disabled').Count
            return @{ Actual = if ($activeCount -eq 0) { "已全部禁用" } else { "$activeCount 项活跃" }; Expected = "全部禁用"; IsCompliant = ($activeCount -eq 0) }
        }
        Apply   = {
            Get-ScheduledTask -TaskPath "\Microsoft\Windows\Customer Experience Improvement Program\" -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "tasks-disable-appexperience-scheduled"
        Name    = "应用程序体验兼容性后台任务 (\Application Experience\)"
        Profile = "General"
        Purpose = "禁用 Microsoft Compatibility Appraiser 等大量消耗 CPU 盘查已装软件的后台扫描任务"
        Impact  = "Windows 不再向微软服务器提交设备软硬件清单用以评估 Windows 12 潜在升级资格"
        Check   = {
            $tasks = @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\Application Experience\" -ErrorAction SilentlyContinue)
            if ($tasks.Count -eq 0) { return @{ Actual = "无 AppExperience 任务"; Expected = "全部禁用"; IsCompliant = $true } }
            $activeCount = ($tasks | Where-Object State -ne 'Disabled').Count
            return @{ Actual = if ($activeCount -eq 0) { "已全部禁用" } else { "$activeCount 项活跃" }; Expected = "全部禁用"; IsCompliant = ($activeCount -eq 0) }
        }
        Apply   = {
            Get-ScheduledTask -TaskPath "\Microsoft\Windows\Application Experience\" -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "project-rome-disable-activity-feed"
        Name    = "活动信息流跨设备流转切断 (EnableActivityFeed = 0)"
        Profile = "General"
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
        Profile = "General"
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
        Profile = "General"
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
        Id      = "privacy-disable-tailored-experiences"
        Name    = "基于诊断数据的量身定制体验切断 (TailoredExperiences = 0)"
        Profile = "General"
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
        Id      = "privacy-disable-http-language-list"
        Name    = "网站访问语言列表优化切断 (HttpAcceptLanguageOptOut = 1)"
        Profile = "General"
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
        Id      = "cloudcontent-disable-consumer-features"
        Name    = "云端消费级功能静默预装组策略 (DisableWindowsConsumerFeatures = 1)"
        Profile = "General"
        Purpose = "企业策略级禁止 Windows 自动从云端静默推荐并下载安装第三方商业推广应用（如连环消消乐等）"
        Impact  = "新用户首次登录时不会自动获得微软合作伙伴推荐的应用磁贴"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
        }
    },
    [PSCustomObject]@{
        Id      = "cdm-disable-silent-installed-apps"
        Name    = "推广应用静默安装开关 (SilentInstalledAppsEnabled = 0)"
        Profile = "General"
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
        Profile = "General"
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
        Id      = "scoobe-disable-system-setting"
        Name    = "大版本更新 SCOOBE 全屏推销页面 (ScoobeSystemSettingEnabled = 0)"
        Profile = "General"
        Purpose = "大版本更新或补丁安装后登录时，彻底跳过强制全屏推销 Microsoft 365/OneDrive 的全屏欢迎页"
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
        Id      = "clipboard-disable-cross-device"
        Name    = "跨设备剪贴板云端上传切断 (AllowCrossDeviceClipboard = 0)"
        Profile = "General"
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
        Profile = "General"
        Purpose = "停用后台诊断策略引擎，消除静默系统事件扫描与日志记录开销"
        Impact  = "系统自带的「疑难解答」向导（如自动检测网络故障并重置适配器）在诊断时可能提示服务未启动"
        Check   = {
            $s = Get-Service -Name DPS -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name DPS -Force -ErrorAction SilentlyContinue
            Set-Service -Name DPS -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-wdiservicehost"
        Name    = "诊断服务主机停用 (WdiServiceHost = Disabled)"
        Profile = "General"
        Purpose = "停用后台诊断宿主服务，消除后台间歇性唤醒扫描"
        Impact  = "Windows 性能监视器中关于开机引导耗时与关机耗时的诊断事件跟踪将停止记录"
        Check   = {
            $s = Get-Service -Name WdiServiceHost -ErrorAction SilentlyContinue
            $act = if ($s) { "$($s.StartType)" } else { "未安装" }
            return @{ Actual = $act; Expected = "Disabled"; IsCompliant = ($s -and $s.StartType -eq 'Disabled') }
        }
        Apply   = {
            Stop-Service -Name WdiServiceHost -Force -ErrorAction SilentlyContinue
            Set-Service -Name WdiServiceHost -StartupType Disabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "edge-disable-background-mode"
        Name    = "Edge 浏览器开机后台常驻切断 (BackgroundModeEnabled = 0)"
        Profile = "General"
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
        Profile = "General"
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
        Profile = "Full"
        Purpose = "插入鼠标/键盘等外设时，禁止驱动程序静默唤醒第三方协同安装向导与捆绑全家桶"
        Impact  = "插入需要专用驱动协同包初始化的特种硬件时，需用户手动前往官网下载驱动安装器（仅 Full 启用）"
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
        Profile = "Full"
        Purpose = "禁止系统向微软服务器查询外设高清图标与附加应用包，提升即插即用响应"
        Impact  = "在控制面板「设备和打印机」中，某些特定品牌外设将仅显示通用外设图标，而非渲染图（仅 Full 启用）"
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
        Profile = "Full"
        Purpose = "通过 IFEO 映像劫持阻断插入雷蛇设备时弹出的强制静默安装全家桶弹窗"
        Impact  = "若用户本身是雷蛇硬件重度用户且需要依赖 Razer Synapse 雷云软件，弹窗被屏蔽后需手动从官网下载雷云（仅 Full 启用）"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RazerInstaller.exe" "Debugger"
            return @{ Actual = $val; Expected = "systray.exe"; IsCompliant = ($val -eq "systray.exe") }
        }
        Apply   = {
            $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RazerInstaller.exe"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "Debugger" -Value "systray.exe" -Force
        }
    }
)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  遥测采集与推广推送阻断基线巡检 (pwsh 7+)" -ForegroundColor Cyan
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

Write-Host "`n📊 [巡检看板] 遥测阻断原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

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
Write-Host "`n🚀 正在单向对齐遥测与推广阻断基线..." -ForegroundColor Cyan
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
Write-Host ("  ✅ [遥测加固完成] 成功对齐 {0} / {1} 项基线配置 (预设: {2})" -f $appliedCount, $driftCount, $Profile) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
