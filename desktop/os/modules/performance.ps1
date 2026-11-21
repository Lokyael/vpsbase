#requires -Version 7.0
<#
.SYNOPSIS
    硬件调度与性能底层基准

.DESCRIPTION
    Windows 11 硬件底层调度、电源计划巡检、快速启动禁用与内核性能优化模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 巡检活动电源计划（锁定平衡方案，避免单核睿频被压制与待机积热）。
    3. 通过关闭休眠同时关闭快速启动，不单独纳管 HiberbootEnabled。
    4. 解除 MAX_PATH 260 字符长路径限制。
    5. 固化硬件时钟为 UTC (RealTimeIsUniversal) 并停用自动时区服务，消除双系统/装机时钟漂移与位置遥测。
    6. 固化系统时区为 Singapore Standard Time (UTC+8 / Asia/Singapore)。
    7. 启用全局 Unicode UTF-8 代码页 (ACP/OEMCP/MACCP = 65001)，根除现代工具链与终端乱码。
    8. 关闭休眠与休眠文件，不保留断电工作集或 reduced 文件。
    9. 系统崩溃蓝屏停止自动重启并锁定小型转储 (AutoReboot=0, Minidump)，保护排障现场与内存隐私。
    10. 配置 PreventDeviceEncryption=1，并将系统卷及固定数据卷完全解密；移动卷不纳管，转换未完成不报合规。
    11. USB 选择性挂起：接通电源禁用以优先保障 USB 音频稳定性，电池供电保持启用；效果取决于外设和驱动。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (只读诊断受控属性对比，零写入安全退出)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\desktop\os\modules\performance.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\desktop\os\modules\performance.ps1

    # 无交互一键全量对齐
    pwsh -File .\desktop\os\modules\performance.ps1 -Yes
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

function Get-PowerSettingIndices {
    param(
        [Parameter(Mandatory = $true)][guid]$Subgroup,
        [Parameter(Mandatory = $true)][guid]$Setting,
        [guid]$SchemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
    )

    if (-not ('WindowsPower.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WindowsPower {
    public static class NativeMethods {
        [DllImport("powrprof.dll", ExactSpelling = true)]
        public static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
        [DllImport("powrprof.dll", ExactSpelling = true)]
        public static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    }
}
'@ -ErrorAction Stop
    }

    [uint32]$ac = 0
    [uint32]$dc = 0
    $code = [WindowsPower.NativeMethods]::PowerReadACValueIndex([IntPtr]::Zero, [ref]$SchemeGuid, [ref]$Subgroup, [ref]$Setting, [ref]$ac)
    if ($code -ne 0) { throw "PowerReadACValueIndex 失败 (Win32=$code)。" }
    $code = [WindowsPower.NativeMethods]::PowerReadDCValueIndex([IntPtr]::Zero, [ref]$SchemeGuid, [ref]$Subgroup, [ref]$Setting, [ref]$dc)
    if ($code -ne 0) { throw "PowerReadDCValueIndex 失败 (Win32=$code)。" }
    return @{ AC = $ac; DC = $dc }
}

function Get-HibernationState {
    $enabled = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    $file = Join-Path $env:SystemDrive 'hiberfil.sys'
    try { $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
        $item = $null
    }
    return @{
        Actual = "HibernateEnabled=$enabled, HiberFilePresent=$($null -ne $item)"
        Expected = 'HibernateEnabled=0, HiberFilePresent=False (配置终态)'
        IsCompliant = ($enabled -eq '0' -and $null -eq $item)
    }
}

function Invoke-BitLockerVolumeMethod {
    param(
        [Parameter(Mandatory = $true)]$Volume,
        [Parameter(Mandatory = $true)][string]$Method
    )
    $result = Invoke-CimMethod -InputObject $Volume -MethodName $Method -ErrorAction Stop
    [uint32]$code = 0
    if ($null -eq $result -or -not [uint32]::TryParse([string]$result.ReturnValue, [ref]$code)) {
        throw "BitLocker [$($Volume.DeviceID)] $Method 返回码未知。"
    }
    if ($code -ne 0) {
        if ($Method -ceq 'Decrypt' -and $code -eq 0x80310029u) {
            throw "BitLocker 卷 [$($Volume.DeviceID)] 存在自动解锁密钥依赖 (Win32=0x80310029)；先确认相关卷及独立恢复材料并人工处理，不自动清除密钥。"
        }
        throw ("BitLocker [{0}] {1} 失败 (Win32=0x{2:X8})。" -f $Volume.DeviceID, $Method, $code)
    }
    return $result
}

function Get-BitLockerFixedVolumeState {
    $volumes = @(Get-CimInstance -Namespace 'Root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $states = @(
        foreach ($volume in $volumes) {
            [uint32]$type = 0
            if ($null -eq $volume -or -not [uint32]::TryParse([string]$volume.VolumeType, [ref]$type) -or $type -notin @(0, 1, 2)) {
                throw 'BitLocker 卷类型未知，无法确认固定卷范围。'
            }
            if ($type -eq 2) { continue }
            $id = [string]$volume.DeviceID
            if ([string]::IsNullOrWhiteSpace($id) -or -not $seen.Add($id)) { throw 'BitLocker 固定卷 DeviceID 缺失或重复。' }
            if ($type -eq 0 -and ([string]::IsNullOrWhiteSpace($env:SystemDrive) -or $volume.DriveLetter -ine $env:SystemDrive)) {
                throw 'BitLocker 系统卷身份无法确认。'
            }
            $lock = Invoke-BitLockerVolumeMethod $volume GetLockStatus
            [uint32]$lockStatus = 0
            if (-not [uint32]::TryParse([string]$lock.LockStatus, [ref]$lockStatus) -or $lockStatus -ne 0) {
                throw "BitLocker 固定卷 [$id] 锁定或锁定状态未知；请确认恢复材料并自行解锁后重跑。"
            }
            # 使用方法读取当前状态，不依赖枚举时的缓存属性。
            $conversion = Invoke-BitLockerVolumeMethod $volume GetConversionStatus
            $protection = Invoke-BitLockerVolumeMethod $volume GetProtectionStatus
            [uint32]$status = 0; [uint32]$percent = 0; [uint32]$protected = 0
            if (-not [uint32]::TryParse([string]$conversion.ConversionStatus, [ref]$status) -or $status -gt 5 -or
                -not [uint32]::TryParse([string]$conversion.EncryptionPercentage, [ref]$percent) -or $percent -gt 100 -or
                -not [uint32]::TryParse([string]$protection.ProtectionStatus, [ref]$protected) -or $protected -gt 1 -or
                ($status -eq 0 -and ($percent -ne 0 -or $protected -ne 0))) {
                throw "BitLocker 固定卷 [$id] 转换／保护状态未知或矛盾。"
            }
            $name = if ([string]::IsNullOrWhiteSpace($volume.DriveLetter)) { $id } else { "$($volume.DriveLetter) [$id]" }
            $statusName = @('FullyDecrypted', 'FullyEncrypted', 'EncryptionInProgress', 'DecryptionInProgress', 'EncryptionPaused', 'DecryptionPaused')[$status]
            [pscustomobject]@{
                Volume = $volume; DeviceID = $id; VolumeType = $type; Status = $status
                IsCompliant = ($status -eq 0 -and $percent -eq 0 -and $protected -eq 0)
                Actual = "$name ${statusName}, $percent%, Protection=$protected"
            }
        }
    )
    if (@($states | Where-Object VolumeType -EQ 0).Count -ne 1) { throw 'BitLocker 当前系统卷缺失或不唯一。' }
    return $states
}

function Get-BitLockerDisabledState {
    $volumes = @(Get-BitLockerFixedVolumeState)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
    $policy = Test-RegDword $key 'PreventDeviceEncryption' 1
    return @{
        Actual = "PreventDeviceEncryption=$(Get-RegVal $key 'PreventDeviceEncryption'); $($volumes.Actual -join '; ')"
        Expected = 'PreventDeviceEncryption=1 (DWORD); 系统卷及固定数据卷 FullyDecrypted, 0%, Protection=0'
        IsCompliant = ($policy -and @($volumes | Where-Object { -not $_.IsCompliant }).Count -eq 0)
        Volumes = $volumes
    }
}

function Disable-ManagedBitLocker {
    # 完整复查后才写策略；不以解密补偿查询失败，不清除任何自动解锁密钥。
    $before = Get-BitLockerDisabledState
    Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($target in ($before.Volumes | Sort-Object VolumeType -Descending)) {
        try {
            $current = @(Get-BitLockerFixedVolumeState | Where-Object DeviceID -IEQ $target.DeviceID)
            if ($current.Count -ne 1) { throw "BitLocker 固定卷 [$($target.DeviceID)] 已消失或身份变化。" }
            $state = $current[0]
            if ($state.IsCompliant -or $state.Status -eq 3) { continue }
            $null = Invoke-BitLockerVolumeMethod $state.Volume Decrypt
            $after = @(Get-BitLockerFixedVolumeState | Where-Object DeviceID -IEQ $target.DeviceID)
            if ($after.Count -ne 1 -or (-not $after[0].IsCompliant -and $after[0].Status -ne 3)) {
                throw "BitLocker 卷 [$($target.DeviceID)] 解密调用后未进入解密中或完全解密状态。"
            }
        } catch { $errors.Add($_.Exception.Message) }
    }
    try {
        $final = Get-BitLockerDisabledState
        $pending = @($final.Volumes | Where-Object { -not $_.IsCompliant })
        if (-not $final.IsCompliant) {
            $detail = $pending.Actual -join '; '
            Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData "BitLocker 尚未关闭完成：$detail。解密中请等待后重跑 Check；锁定／自动解锁依赖按错误处理。"
            $errors.Add("BitLocker 尚未达到完全解密终态：$($final.Actual)")
        }
    } catch { $errors.Add($_.Exception.Message) }
    if ($errors.Count -gt 0) { throw ($errors -join '; ') }
}

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 作用与风险明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "power-scheme-balanced"
        Name    = "锁定活动电源计划为平衡方案 (Balanced)"
        Purpose = "锁定平衡电源计划，保留系统根据 CPU 负载动态调度单核睿频机制，消除待机积热"
        Impact  = "某些希望无视发热与能耗、强行压榨最高持续全核主频的极限超频跑分场景不适用"
        Check   = {
            $activeScheme = powercfg /getactivescheme 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "查询电源方案失败 (退出码 $LASTEXITCODE)：$activeScheme" }
            $isPass = ($activeScheme -match "381b4222-f694-41f0-9685-ff5bb260df2e")
            return @{
                Actual      = if ($isPass) { "平衡方案" } else { "非平衡方案" }
                Expected    = "平衡方案 (381b4222-...)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            & powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e
            if ($LASTEXITCODE -ne 0) { throw "设置平衡电源方案失败 (退出码 $LASTEXITCODE)。" }
            $active = powercfg /getactivescheme 2>&1 | Out-String
            if ($active -notmatch "381b4222-f694-41f0-9685-ff5bb260df2e") {
                throw "设置平衡电源方案后活动方案校验失败。"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "usb-selective-suspend-ac-disabled"
        Name    = "USB 选择性挂起策略 (接通电源禁用 / 电池保持启用)"
        Purpose = "接通电源时禁用 USB 选择性挂起，优先保障 USB 音频及外设的挂起恢复稳定性；电池供电时保持启用"
        Impact  = "AC 禁用作用于目标平衡方案的 USB 设备，可能增加设备及整机功耗、影响深度省电；这是音频优先策略，不保证解决具体外设故障，DC 保留节电配置"
        Check   = {
            $subgroup = "2a737441-1930-4402-8d77-b2bebba308a3"
            $setting  = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
            # 按最终目标平衡方案探测，不受本轮切换前活动方案影响。
            $indices  = Get-PowerSettingIndices -Subgroup $subgroup -Setting $setting -SchemeGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
            $acVal    = $indices.AC
            $dcVal    = $indices.DC
            $isPass   = ($acVal -eq 0 -and $dcVal -eq 1)
            return @{
                Actual      = "AC=$($acVal ?? '未知'), DC=$($dcVal ?? '未知')"
                Expected    = "AC=0 (Disabled), DC=1 (Enabled)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $subgroup = "2a737441-1930-4402-8d77-b2bebba308a3"
            $setting  = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
            & powercfg /setacvalueindex 381b4222-f694-41f0-9685-ff5bb260df2e $subgroup $setting 0
            if ($LASTEXITCODE -ne 0) { throw "设置 USB AC 策略失败 (退出码 $LASTEXITCODE)。" }
            & powercfg /setdcvalueindex 381b4222-f694-41f0-9685-ff5bb260df2e $subgroup $setting 1
            if ($LASTEXITCODE -ne 0) { throw "设置 USB DC 策略失败 (退出码 $LASTEXITCODE)。" }
            & powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
            if ($LASTEXITCODE -ne 0) { throw "加载 USB 电源策略失败 (退出码 $LASTEXITCODE)。" }
            $after = Get-PowerSettingIndices -Subgroup $subgroup -Setting $setting -SchemeGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
            if ($after.AC -ne 0 -or $after.DC -ne 1) { throw 'USB 电源策略写入后配置校验失败。' }
        }
    },
    [PSCustomObject]@{
        Id      = "enable-long-paths"
        Name    = "MAX_PATH 260 字符文件路径限制解除 (LongPathsEnabled = 1)"
        Purpose = "突破 Win32 260 字符限制，保障深层嵌套工程正常读写与编译构建"
        Impact  = "极少数 20 年前未适配长路径 API 的上古老旧 32 位工具可能无法正确处理超长路径"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled" 1
        }
    },
    [PSCustomObject]@{
        Id      = "hardware-clock-realtime-is-universal"
        Name    = "固化主板 CMOS 硬件时钟为 UTC (RealTimeIsUniversal = 1)"
        Purpose = "将主板 CMOS 硬件时钟锚定为国际标准 UTC 时间，消除双系统与冷启动离线时钟漂移"
        Impact  = "主板硬件时钟将直接存储 UTC 时间而非本地时间"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" "RealTimeIsUniversal"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" "RealTimeIsUniversal" 1
        }
    },
    [PSCustomObject]@{
        Id      = "service-disable-tzautoupdate"
        Name    = "自动时区更新服务停用与禁用 (tzautoupdate = Disabled)"
        Purpose = "停用后台通过网络与位置探测自动修改时区的服务，切断地理位置遥测轮询"
        Impact  = "时区不会随物理地理位置变换而自动漂移，需手动或通过工程基线固定"
        Check   = {
            Get-ServiceDisableState -Name tzautoupdate
        }
        Apply   = {
            Disable-ManagedService -Name tzautoupdate
        }
    },
    [PSCustomObject]@{
        Id      = "timezone-target-singapore"
        Name    = "系统时区锚定 Singapore Standard Time (UTC+8 / Asia/Singapore)"
        Purpose = "固定系统时区为新加坡标准时间 (UTC+8)，无夏令时切换"
        Impact  = "本地时间呈现为 UTC+8，底层时间戳保持按 UTC 管理"
        Check   = {
            $tzId = (Get-TimeZone).Id
            return @{ Actual = $tzId; Expected = "Singapore Standard Time"; IsCompliant = ($tzId -eq "Singapore Standard Time") }
        }
        Apply   = {
            Set-TimeZone -Id "Singapore Standard Time" -ErrorAction Stop
            if ((Get-TimeZone).Id -ne "Singapore Standard Time") {
                throw "时区设置后校验失败：$((Get-TimeZone).Id)"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "codepage-utf8-global"
        Name    = "启用全局 Unicode UTF-8 代码页 (ACP/OEMCP/MACCP = 65001)"
        Purpose = "将系统 ANSI/OEM 代码页锁定为 65001 (UTF-8)，消除现代开发工具链、终端与跨平台文本中文乱码"
        Impact  = "极少数未采用 Unicode 的数十年前老旧非 Unicode 软件可能出现界面文本异常（需重启计算机生效）"
        Check   = {
            $nls = "HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage"
            $acp = Get-RegVal $nls "ACP"
            $oemcp = Get-RegVal $nls "OEMCP"
            $maccp = Get-RegVal $nls "MACCP"
            $isPass = ($acp -eq "65001" -and $oemcp -eq "65001" -and $maccp -eq "65001")
            return @{
                Actual      = "ACP=$acp, OEMCP=$oemcp, MACCP=$maccp"
                Expected    = "ACP=65001, OEMCP=65001, MACCP=65001"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $nls = "HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage"
            Ensure-RegKey $nls
            Set-ItemProperty -Path $nls -Name "ACP" -Type String -Value "65001" -Force
            Set-ItemProperty -Path $nls -Name "OEMCP" -Type String -Value "65001" -Force
            Set-ItemProperty -Path $nls -Name "MACCP" -Type String -Value "65001" -Force
            if ((Get-RegVal $nls "ACP") -ne "65001" -or (Get-RegVal $nls "OEMCP") -ne "65001" -or (Get-RegVal $nls "MACCP") -ne "65001") {
                throw "全局 UTF-8 代码页写入后校验失败。"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "hibernation-disabled"
        Name    = "关闭休眠及休眠文件"
        Purpose = "通过 powercfg 关闭断电休眠，不保留 reduced 休眠文件"
        Impact  = "不再支持断电保留工作集、混合睡眠及快速启动；不影响普通睡眠本身"
        Check   = { Get-HibernationState }
        Apply   = {
            & powercfg /hibernate off
            if ($LASTEXITCODE -ne 0) { throw "关闭休眠失败 (退出码 $LASTEXITCODE)。" }
            $after = Get-HibernationState
            if (-not $after.IsCompliant) { throw "休眠关闭后未达到配置终态：$($after.Actual)" }
        }
    },
    [PSCustomObject]@{
        Id      = "crashcontrol-dump-governance"
        Name    = "系统崩溃蓝屏停止自动重启与转储轻量化 (AutoReboot = 0, Minidump)"
        Purpose = "蓝屏死机时禁止自动重启，保留屏幕错误代码与驱动文件名以供排障；转储模式锁定为 256KB 小型转储 (Minidump)，消除巨型 Dump 占用磁盘与内存敏感数据外泄风险"
        Impact  = "发生罕见蓝屏时需长按电源键手动重启系统；无法提取全量物理内存镜像用于深度驱动逆向"
        Check   = {
            $ar = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" "AutoReboot"
            $cd = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" "CrashDumpEnabled"
            $isPass = ($ar -eq "0" -and $cd -eq "3")
            return @{ Actual = "AutoReboot=$ar, CrashDump=$cd"; Expected = "AutoReboot=0, CrashDump=3"; IsCompliant = $isPass }
        }
        Apply   = {
            $ccKey = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
            Set-RegDword $ccKey "AutoReboot" 0
            Set-RegDword $ccKey "CrashDumpEnabled" 3
        }
    },
    [PSCustomObject]@{
        Id      = "bitlocker-prevent-device-encryption"
        Name    = "关闭固定卷 BitLocker 并禁止自动设备加密"
        Purpose = "系统卷及固定数据卷达到完全解密、0%、保护关闭，并配置 PreventDeviceEncryption=1"
        Impact  = "将解密所有受控固定卷（含被识别为固定卷的外接盘），失去 BitLocker 离线保护；先备份数据和恢复材料。不改移动卷，不自动解锁或清除自动解锁密钥；后台解密未完成不算合规。不保证阻止管理员或组织策略重新启用"
        Check   = { Get-BitLockerDisabledState }
        Apply   = { Disable-ManagedBitLocker }
    }
)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  硬件调度与性能底层基准巡检 (pwsh 7+)" -ForegroundColor Cyan
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

Write-Host "`n📊 [巡检看板] 性能底层原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Select-Object 状态, 规则, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host

if ($probeErrors.Count -gt 0) {
    throw "本模块存在无法确认的属性，未执行任何写入：$($probeErrors -join '; ')"
}

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 硬件调度与性能底层基准全部合规，无需调整。`n" -ForegroundColor Green
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

    $gateInput = (Read-Host "`n确认对齐上述 $driftCount 项性能与硬件基线？[Y] 确认执行 / [N] 跳过本模块 / [Q] 退出 (默认 Y)").Trim()
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
Write-Host "`n🚀 正在单向对齐硬件调度与性能基线..." -ForegroundColor Cyan
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
Write-Host ("  ✅ [性能优化完成] 成功对齐 {0} / {1} 项基线配置" -f $appliedCount, $driftCount) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
