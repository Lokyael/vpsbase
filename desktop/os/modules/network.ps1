#requires -Version 7.0
<#
.SYNOPSIS
    网络协议加固与系统更新通道策略基线

.DESCRIPTION
    Windows 11 网络协议加固、系统安全配置与更新通道策略基线模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 物理网卡保留网络提供的默认 DNS 与 IPv6 链路，底座不承担代理隐私隔离；禁用 LLMNR 本地多播解析 (EnableMulticast=0)。
    3. 禁用 TCP/IP 上的 NetBIOS (NetbiosOptions=2)，切断 137/138/139 广播名称解析，收敛至标准 DNS 栈。
    4. 启用 TCP 显式拥塞通知 (ECN，RFC 3168)，降低长时延链路丢包重传率。
    5. 强制远程桌面网络级别身份验证 (NLA)，阻断未设密码本地账户的网络远程登录。
    6. 禁止 Windows Update 自动覆盖第三方显卡/芯片组驱动，阻断 MRT 恶意软件删除工具推送。
    7. 配置 Windows 更新通道为下载与安装前通知 (AUOptions=2)，限制登录用户重启，切断 P2P 传递优化以节约带宽。
    8. 禁用 Microsoft Store 应用在后台静默自动下载与更新。
    9. Windows Defender 防火墙全域安全基线：锁定 Domain/Private/Public 配置文件全域开启，默认阻断所有未受控入站并允许正常出站。
    10. 切换中立全球 Anycast 高可用 NTP 时间同步集群 (Cloudflare / Pool / Apple)，加固 3600s 轮询。
    11. 操作系统分支版本锁定 (TargetReleaseVersion=1)，阻断跨年度大版本静默强升。
    12. 物理无线网卡漫游灵敏度设为 Low / Lowest，偏向固定位置使用；不关闭漫游，多 AP 移动效果须验收。
    13. 保留空闲节电 Low 与 MSPower_DeviceEnable=False 目标，控制取决于驱动，不保证延迟或续航收益。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (只读诊断受控属性对比，零写入安全退出)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\desktop\os\modules\network.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\desktop\os\modules\network.ps1

    # 无交互一键全量对齐
    pwsh -File .\desktop\os\modules\network.ps1 -Yes
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

function Get-PhysicalWifiAdapters {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
    foreach ($nic in $adapters) {
        if ($null -eq $nic.NdisPhysicalMedium) { throw "无法确认网卡 [$($nic.Name)] 的物理介质类型。" }
        if ($nic.NdisPhysicalMedium -in @(1, 9)) { $nic }
    }
}

function Get-WifiAdvancedState {
    param(
        [Parameter(Mandatory)][ValidateSet('Roaming', 'Leisure')][string]$Kind
    )
    $items = @()
    foreach ($nic in @(Get-PhysicalWifiAdapters)) {
        if ([string]::IsNullOrWhiteSpace($nic.InterfaceDescription)) { throw "网卡 [$($nic.Name)] 的设备描述不可读。" }
        $props = @(Get-NetAdapterAdvancedProperty -InterfaceDescription $nic.InterfaceDescription -AllProperties -ErrorAction Stop | Where-Object {
            if ($Kind -ceq 'Roaming') { $_.RegistryKeyword -cin @('RegROAMSensitiveLevel', 'RoamAggressiveness') }
            else { $_.RegistryKeyword -ceq 'LpsEn' }
        })
        if ($props.Count -ne 1) { throw "无法唯一确认网卡 [$($nic.Name)] 的 $Kind 高级属性。" }
        $prop = $props[0]
        if ($prop.InterfaceDescription -cne $nic.InterfaceDescription) {
            throw "网卡 [$($nic.Name)] 的 $Kind 属性设备归属无法确认。"
        }
        $labels = @($prop.ValidDisplayValues)
        $values = @($prop.ValidRegistryValues)
        if ($labels.Count -eq 0 -or $labels.Count -ne $values.Count) {
            throw "网卡 [$($nic.Name)] 的 $Kind 枚举映射不可读。"
        }
        # 仅解析驱动公开的英文目标标签（含 Intel 的编号标签），不猜厂商数字语义。
        $targets = @(for ($i = 0; $i -lt $labels.Count; $i++) {
            if ($labels[$i] -ceq 'Low') { $i }
        })
        if ($targets.Count -eq 0 -and $Kind -ceq 'Roaming') {
            $targets = @(for ($i = 0; $i -lt $labels.Count; $i++) {
                if ($labels[$i] -cmatch '^(?:[0-9]+\.\s*)?Lowest$') { $i }
            })
        }
        if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace($values[$targets[0]])) {
            throw "网卡 [$($nic.Name)] 无法唯一解析 $Kind 的英文 Low/Lowest 目标。"
        }
        $index = $targets[0]
        if (@($values | Where-Object { $_ -ceq $values[$index] }).Count -ne 1) {
            throw "网卡 [$($nic.Name)] 的 $Kind 目标枚举值不唯一。"
        }
        $current = @($prop.RegistryValue)
        if ($current.Count -ne 1 -or [string]::IsNullOrWhiteSpace($current[0])) {
            throw "网卡 [$($nic.Name)] 的 $Kind 当前值不可读。"
        }
        $items += [pscustomobject]@{
            Property = $prop
            Target = [string]$values[$index]
            Actual = "$($nic.Name): $($prop.DisplayValue) [$($current[0])]"
            Expected = "$($nic.Name): $($labels[$index]) [$($values[$index])]"
            IsCompliant = ($current[0] -ceq $values[$index])
        }
    }
    return $items
}

function Get-WifiAdvancedCheck {
    param([Parameter(Mandatory)][string]$Kind)
    $items = @(Get-WifiAdvancedState -Kind $Kind)
    return @{
        Actual = if ($items.Count) { $items.Actual -join '; ' } else { '未检测到物理 Wi-Fi 网卡' }
        Expected = if ($items.Count) { $items.Expected -join '; ' } else { '无受控设备' }
        IsCompliant = (@($items | Where-Object { -not $_.IsCompliant }).Count -eq 0)
    }
}

function Set-WifiAdvancedTarget {
    param([Parameter(Mandatory)][string]$Kind)
    $items = @(Get-WifiAdvancedState -Kind $Kind)
    foreach ($item in $items) {
        if ($item.IsCompliant) { continue }
        $prop = $item.Property
        Set-NetAdapterAdvancedProperty -InputObject $prop -RegistryValue $item.Target -NoRestart -ErrorAction Stop
        # 重新按设备与枚举定位，核验实际值及本次目标；不把命令成功当作失写成功。
        $after = @(Get-WifiAdvancedState -Kind $Kind | Where-Object {
            $_.Property.InterfaceDescription -ceq $prop.InterfaceDescription
        })
        if ($after.Count -ne 1 -or -not $after[0].IsCompliant -or $after[0].Target -cne $item.Target) {
            throw "网卡 [$($prop.Name)] 的 $Kind 属性写入后配置校验失败。"
        }
        Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData "网卡 [$($prop.Name)] $Kind 属性已写入，未重启适配器；请按驱动要求手动重启系统后验收。"
    }
}

function Get-WifiPowerNodes {
    $items = @()
    foreach ($nic in @(Get-PhysicalWifiAdapters)) {
        if ([string]::IsNullOrWhiteSpace($nic.PnPDeviceID)) { throw "网卡 [$($nic.Name)] 的 PnP 身份不可读。" }
        # 接受设备实例名及数字实例后缀；其他命名不猜测归属。
        $pattern = '^' + [regex]::Escape($nic.PnPDeviceID) + '(?:_[0-9]+)?$'
        $nodes = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop |
            Where-Object { $_.InstanceName -imatch $pattern })
        if ($nodes.Count -eq 0 -or @($nodes | Where-Object { $_.Enable -isnot [bool] }).Count -gt 0) {
            throw "无法确认网卡 [$($nic.Name)] 的系统节电节点或布尔属性。"
        }
        $items += [pscustomobject]@{ Adapter = $nic; Nodes = $nodes }
    }
    return $items
}

function Get-NtpConfigurationState {
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($null -eq $computer.PartOfDomain) { throw '无法确认域成员状态，未推断独立 NTP 配置。' }
    if ($computer.PartOfDomain) { throw '此基线仅配置独立工作站 NTP；域成员的时间源须由域策略管理。' }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $peers = Get-RegVal $key 'NtpServer'
    $type = Get-RegVal $key 'Type'
    $interval = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient' 'SpecialPollInterval'
    $target = 'time.cloudflare.com,0x9 pool.ntp.org,0x9 time.apple.com,0x9'
    return @{
        Actual = "Peers=$peers; Type=$type; SpecialPollInterval=$interval"
        Expected = "$target; Type=NTP; SpecialPollInterval=3600 (仅配置值，不代表已加载／校时)"
        IsCompliant = ($peers -ceq $target -and $type -ceq 'NTP' -and $interval -eq '3600')
    }
}

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 目的与影响明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "disable-llmnr-multicast"
        Name    = "LLMNR 本地多播名称解析禁用 (EnableMulticast = 0)"
        Purpose = "切断局域网未加密链路本地多播名称解析，降低同局域网下 Responder 恶意哈希窃取与投毒风险"
        Impact  = "在没有 DNS 服务器的无头工作组局域网中，无法直接通过单机计算机名互相发现"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" "EnableMulticast"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" "EnableMulticast" 0
        }
    },
    [PSCustomObject]@{
        Id      = "disable-netbios-over-tcpip"
        Name    = "NetBIOS over TCP/IP 广播协议禁用 (NetbiosOptions = 2)"
        Purpose = "禁用网络适配器上的 NetBIOS over TCP/IP，阻断 137/138/139 广播名称解析，使网络名称解析收敛于纯 DNS 栈"
        Impact  = "无法通过古老的 NetBIOS 单机名访问未经现代 DNS 解析的极老旧内网设备（现代 SMB 445 端口直连完全不受影响）"
        Check   = {
            $physicalNics = @(Get-NetAdapter -Physical -ErrorAction Stop)
            if ($physicalNics.Count -eq 0) { return @{ Actual = "无物理网卡"; Expected = "全部为 2 (已禁用)"; IsCompliant = $true } }
            $nics = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object { $_.IPEnabled -and $_.InterfaceIndex -in $physicalNics.InterfaceIndex })
            if (@($nics | Where-Object { $null -eq $_.TcpipNetbiosOptions }).Count -gt 0) { throw '无法确认网卡 NetBIOS 配置。' }
            if ($nics.Count -eq 0) { return @{ Actual = "无活动 IP 物理网卡"; Expected = "全部为 2 (已禁用)"; IsCompliant = $true } }
            $nonCompliant = @($nics | Where-Object { $_.TcpipNetbiosOptions -ne 2 })
            $isPass = ($nonCompliant.Count -eq 0)
            $actualStr = if ($isPass) { "全部已禁用 (2)" } else { "$($nonCompliant.Count) 块网卡未禁用 ($($nonCompliant.Description -join '; '))" }
            return @{ Actual = $actualStr; Expected = "全部为 2 (已禁用)"; IsCompliant = $isPass }
        }
        Apply   = {
            $physicalNics = @(Get-NetAdapter -Physical -ErrorAction Stop)
            $nics = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object { $_.IPEnabled -and $_.InterfaceIndex -in $physicalNics.InterfaceIndex })
            foreach ($nic in $nics) {
                if ($null -eq $nic.TcpipNetbiosOptions) { throw '无法确认网卡 NetBIOS 配置。' }
                if ($nic.TcpipNetbiosOptions -ne 2) {
                    $result = Invoke-CimMethod -InputObject $nic -MethodName 'SetTcpipNetbios' -Arguments @{ TcpipNetbiosOptions = [uint32]2 } -ErrorAction Stop
                    if ($null -eq $result.ReturnValue -or $result.ReturnValue -notin @(0, 1)) { throw "设置网卡 NetBIOS 失败 (返回值 $($result.ReturnValue))。" }
                    if ($result.ReturnValue -eq 1) {
                        Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData 'NetBIOS 禁用配置已接受，需要重启后重新巡检；当前运行效果未验收。'
                    } else {
                        $after = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object InterfaceIndex -eq $nic.InterfaceIndex)
                        if ($after.Count -ne 1 -or $after[0].TcpipNetbiosOptions -ne 2) { throw 'NetBIOS 写入后配置校验失败。' }
                    }
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "tcp-ecn-capability"
        Name    = "TCP 显式拥塞通知启用 (EcnCapability = Enabled)"
        Purpose = "启用 TCP 显式拥塞通知（ECN，RFC 3168），在路由器轻度拥塞时标记 CE 代替直接丢包，降低长时延链路丢包重传率"
        Impact  = "若接入不兼容 ECN 的特定老旧网络设备，可能导致特定握手丢包；现代主流网络环境大多已支持"
        Check   = {
            $tcpSetting = Get-NetTCPSetting -SettingName "Internet" -ErrorAction Stop
            $val = if ($tcpSetting) { "$($tcpSetting.EcnCapability)" } else { "<未找到>" }
            return @{ Actual = $val; Expected = "Enabled"; IsCompliant = ($val -ieq "Enabled") }
        }
        Apply   = {
            Set-NetTCPSetting -SettingName "Internet" -EcnCapability Enabled -ErrorAction Stop | Out-Null
            $after = Get-NetTCPSetting -SettingName "Internet" -ErrorAction Stop
            if ($null -eq $after -or $after.EcnCapability -ine "Enabled") {
                throw "TCP ECN 写入后配置校验失败。"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "rdp-require-nla"
        Name    = "远程桌面网络级别身份验证强制 (NLA UserAuthentication = 1)"
        Purpose = "强制 RDP 远程桌面连接必须先完成网络级身份认证方可分配图形会话资源，防御未认证远程溢出与 DoS 攻击"
        Impact  = "不支持现代 CredSSP 认证协议的极老旧第三方 RDP 客户端将无法连接"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "UserAuthentication"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "UserAuthentication" 1
        }
    },
    [PSCustomObject]@{
        Id      = "access-limit-blank-password-use"
        Name    = "空密码网络远程登录硬阻断 (LimitBlankPasswordUse = 1)"
        Purpose = "若系统本地账户未设密码，强制切断一切通过网络发起该账户认证的远程交互通道（RDP/SMB/WinRM），阻断横向渗透"
        Impact  = "免密账户仅能在本地物理屏幕前交互式登录，无法通过网络跨机访问"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LimitBlankPasswordUse"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LimitBlankPasswordUse" 1
        }
    },
    [PSCustomObject]@{
        Id      = "disable-wu-driver-overwrite"
        Name    = "Windows Update 排除驱动更新 (ExcludeWUDriversInQualityUpdate = 1)"
        Purpose = "阻断系统自动更新静默覆盖显卡公版驱动与主板芯片组驱动，保障驱动完全受控稳定"
        Impact  = "插入全新即插即用外设时，系统不会自动从 Windows Update 库联网静默安装驱动，需手动安装公版驱动"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "ExcludeWUDriversInQualityUpdate"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "ExcludeWUDriversInQualityUpdate" 1
        }
    },
    [PSCustomObject]@{
        Id      = "disable-mrt-push"
        Name    = "恶意软件删除工具 (MRT) 推送阻断 (DontOfferThroughWUAU = 1)"
        Purpose = "阻断 Windows 每月累积更新中重复下载并后台慢速扫描的 MRT，节约磁盘与 CPU 周期"
        Impact  = "系统不再接收每月 MRT 静态特征扫描（第三方专业杀毒或 Windows Defender 实时防护已完全覆盖）"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\MRT" "DontOfferThroughWUAU"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\MRT" "DontOfferThroughWUAU" 1
        }
    },
    [PSCustomObject]@{
        Id      = "wu-automatic-security-updates"
        Name    = "Windows 更新通道手动控制 (AUOptions = 2，下载与安装前通知)"
        Purpose = "配置更新策略为下载前通知、安装前通知，由用户完全自主决定下载与安装时机，杜绝后台静默下载与安装"
        Impact  = "系统检测到可用更新时仅在桌面推送通知，不自动下载补丁包，绝不自动重启；必须由用户手动点击下载并安装"
        Check   = {
            $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
            $expected = @{ NoAutoUpdate = 0; AUOptions = 2; NoAutoRebootWithLoggedOnUsers = 1 }
            $actual = @($expected.Keys | Sort-Object | ForEach-Object { "$_=$(Get-RegVal $key $_)" })
            $pass = @($expected.Keys | Where-Object { (Get-RegVal $key $_) -ne "$($expected[$_])" }).Count -eq 0
            return @{ Actual = $actual -join ', '; Expected = '自动更新=启用, 更新控制=下载/安装前通知 (AUOptions=2), 登录用户重启限制=启用'; IsCompliant = $pass }
        }
        Apply   = {
            $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
            $values = @{ NoAutoUpdate = 0; AUOptions = 2; NoAutoRebootWithLoggedOnUsers = 1 }
            foreach ($name in $values.Keys) { Set-RegDword $key $name $values[$name] }
        }
    },
    [PSCustomObject]@{
        Id      = "disable-delivery-optimization-p2p"
        Name    = "传递优化 P2P 局域网/公网上传切断 (DODownloadMode = 0)"
        Purpose = "将更新传递优化模式设为仅从微软服务器下载 (0)，严禁向局域网或公网其他电脑上传更新补丁，节约上行带宽"
        Impact  = "同一局域网内有多台电脑同时更新 Windows 时，无法互相通过内网 P2P 共享补丁包，各电脑独立外网下载"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 0
        }
    },
    [PSCustomObject]@{
        Id      = "disable-store-autodownload"
        Name    = "Microsoft Store 自动下载更新切断 (AutoDownload = 2)"
        Purpose = "禁止应用商店在后台未经许可静默下载巨型游戏或应用更新，由用户完全自主决定更新时机"
        Impact  = "应用商店中的应用不会在夜间静默升级，需用户手动打开商店点击检查更新"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "AutoDownload"
            return @{ Actual = $val; Expected = "2 (已禁用)"; IsCompliant = ($val -eq "2") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "AutoDownload" 2
        }
    },
    [PSCustomObject]@{
        Id      = "firewall-inbound-block-all"
        Name    = "Defender 防火墙全域入站阻断基线 (Domain/Private/Public Block Inbound)"
        Purpose = "强制开启 Windows Defender 防火墙三大配置文件，锁定默认入站全部阻断，坚守网络安全最小暴露面"
        Impact  = "本地运行临时网络服务（如临时起 Python HTTP 服务、本地调试端口）时，若未明确放行入站规则，外部设备将无法访问"
        Check   = {
            $profiles = Get-NetFirewallProfile -ErrorAction Stop
            if (-not $profiles -or $profiles.Count -lt 3) { throw '无法确认三个防火墙配置文件。' }
            $isPass = $true
            $statusList = @()
            foreach ($p in $profiles) {
                $statusList += "$($p.Name): $($p.DefaultInboundAction)"
                if (-not $p.Enabled -or $p.DefaultInboundAction -ne "Block") { $isPass = $false }
            }
            return @{
                Actual      = if ($isPass) { "3 域全阻断" } else { "$($statusList -join ', ')" }
                Expected    = "Enabled=True, Inbound=Block"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block -ErrorAction Stop | Out-Null
            $profiles = Get-NetFirewallProfile -ErrorAction Stop
            foreach ($p in $profiles) {
                if (-not $p.Enabled -or $p.DefaultInboundAction -ne "Block") {
                    throw "防火墙入站阻断策略写入后校验失败：$($p.Name)"
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "firewall-outbound-allow-all"
        Name    = "Defender 防火墙全域出站放行基线 (Domain/Private/Public Allow Outbound)"
        Purpose = "确保 Windows Defender 防火墙全域默认出站放行，保障本地应用程序正常请求互联网"
        Impact  = "恶意软件发起的出站流量默认不会被出站规则硬阻断，需依赖 Defender 实时防护查杀"
        Check   = {
            $profiles = Get-NetFirewallProfile -ErrorAction Stop
            if (-not $profiles -or $profiles.Count -lt 3) { throw '无法确认三个防火墙配置文件。' }
            $isPass = $true
            $statusList = @()
            foreach ($p in $profiles) {
                $statusList += "$($p.Name): $($p.DefaultOutboundAction)"
                if ($p.DefaultOutboundAction -ne "Allow") { $isPass = $false }
            }
            return @{
                Actual      = if ($isPass) { "3 域全放行" } else { "$($statusList -join ', ')" }
                Expected    = "Outbound=Allow"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Allow -ErrorAction Stop | Out-Null
            $profiles = Get-NetFirewallProfile -ErrorAction Stop
            foreach ($p in $profiles) {
                if ($p.DefaultOutboundAction -ne "Allow") {
                    throw "防火墙出站放行策略写入后校验失败：$($p.Name)"
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "ntp-client-configuration"
        Name    = "独立 NTP 客户端配置（Cloudflare / Pool / Apple）"
        Purpose = "统一配置手动时间源、NTP 模式和 3600 秒特殊轮询间隔，变化后一次通知服务加载"
        Impact  = "仅以配置值为巡检终态；加载失败保留已写值并交付待办，重跑配置匹配时不重试加载。实际加载、上游可达及校时另行验收"
        Check   = { Get-NtpConfigurationState }
        Apply   = {
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
            $state = Get-NtpConfigurationState
            if ($state.IsCompliant) { return }
            Ensure-RegKey $key
            Set-ItemProperty -LiteralPath $key -Name 'NtpServer' -Value 'time.cloudflare.com,0x9 pool.ntp.org,0x9 time.apple.com,0x9' -Force -ErrorAction Stop
            Set-ItemProperty -LiteralPath $key -Name 'Type' -Value 'NTP' -Force -ErrorAction Stop
            Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient' 'SpecialPollInterval' 3600
            if (-not (Get-NtpConfigurationState).IsCompliant) { throw 'NTP 写入后配置校验失败。' }
            try {
                $service = Get-Service -Name W32Time -ErrorAction Stop
                if ($null -eq $service) { throw '无法确认 W32Time 服务。' }
                if ($service.Status -ne 'Running') { Start-Service -Name W32Time -ErrorAction Stop }
                & w32tm /config /update
                if ($LASTEXITCODE -ne 0) { throw "请求加载失败 (退出码 $LASTEXITCODE)。" }
            } catch {
                Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData 'NTP 配置已匹配但加载请求未完成；请检查 W32Time 服务后在管理员 pwsh 执行 w32tm /config /update，并另行验收校时。配置匹配的重跑不会重试加载。'
                throw
            }
        }
    },
    [PSCustomObject]@{
        Id      = "wu-target-release-version-lock"
        Name    = "操作系统分支版本锁定 (TargetReleaseVersion = 1)"
        Purpose = "企业策略级将 Windows 11 锚定在当前稳定分支，正常接收每月安全累积更新 (B类补丁)，硬性阻断跨年度大版本静默强升"
        Impact  = "系统不会在后台自动下载并升级至下一个未经验证的年度大版本；需跨大版本升级时只需清空该策略"
        Check   = {
            $curVer = Get-RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" "DisplayVersion"
            if ($curVer -eq "<未配置>") {
                $curVer = Get-RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" "ReleaseId"
            }
            if ($curVer -eq "<未配置>" -or [string]::IsNullOrWhiteSpace($curVer)) {
                throw "无法确认当前系统 Windows 版本号 (DisplayVersion / ReleaseId)。"
            }
            $wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            $trv = Get-RegVal $wuKey "TargetReleaseVersion"
            $trvi = Get-RegVal $wuKey "TargetReleaseVersionInfo"
            $pv = Get-RegVal $wuKey "ProductVersion"
            $isPass = ($trv -eq "1" -and $trvi -eq "$curVer" -and $pv -eq "Windows 11")
            return @{
                Actual      = "TargetReleaseVersion=$trv, VersionInfo=$trvi, Product=$pv"
                Expected    = "TargetReleaseVersion=1, VersionInfo=$curVer, Product=Windows 11"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $curVer = Get-RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" "DisplayVersion"
            if ($curVer -eq "<未配置>") {
                $curVer = Get-RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" "ReleaseId"
            }
            if ($curVer -eq "<未配置>" -or [string]::IsNullOrWhiteSpace($curVer)) {
                throw "无法确认当前系统 Windows 版本号 (DisplayVersion / ReleaseId)，拒绝写入版本锁定策略。"
            }
            $wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            Ensure-RegKey $wuKey
            Set-RegDword $wuKey "TargetReleaseVersion" 1
            Set-ItemProperty -Path $wuKey -Name "TargetReleaseVersionInfo" -Type String -Value "$curVer" -Force
            Set-ItemProperty -Path $wuKey -Name "ProductVersion" -Type String -Value "Windows 11" -Force
            if ((Get-RegVal $wuKey "TargetReleaseVersion") -ne "1" -or
                (Get-RegVal $wuKey "TargetReleaseVersionInfo") -ne "$curVer" -or
                (Get-RegVal $wuKey "ProductVersion") -ne "Windows 11") {
                throw "操作系统版本锁定策略写入后校验失败。"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "wlan-roaming-sensitivity-suppressed"
        Name    = "物理无线网卡漫游灵敏度 (Low / Lowest)"
        Purpose = "降低漫游触发灵敏度，偏向固定位置使用；保持漫游能力，不关闭 WLAN 自动连接"
        Impact  = "移动或多 AP 环境可能更晚切换、停留在弱信号 AP；并非原厂通用推荐值，不保证减少延迟。仅解析驱动英文 Low/Lowest 枚举，无法确认则报告未知"
        Check   = { Get-WifiAdvancedCheck -Kind Roaming }
        Apply   = { Set-WifiAdvancedTarget -Kind Roaming }
    },
    [PSCustomObject]@{
        Id      = "wlan-leisure-power-save-suppressed"
        Name    = "物理无线网卡空闲节电抑制 (Leisure Power Save = Low)"
        Purpose = "将驱动提供的 LpsEn 空闲节电设为 Low，偏向实时网络响应"
        Impact  = "可能增加 AC/DC 功耗、缩短续航；Low 不直接等于禁止设备 D2/D3。延迟效果取决于驱动和负载；仅解析英文 Low 枚举，无法确认则报告未知"
        Check   = { Get-WifiAdvancedCheck -Kind Leisure }
        Apply   = { Set-WifiAdvancedTarget -Kind Leisure }
    },
    [PSCustomObject]@{
        Id      = "wlan-device-power-saving-disabled"
        Name    = "物理无线网卡系统节能挂起阻断 (MSPower_DeviceEnable = False)"
        Purpose = "在提供 MSPower_DeviceEnable 控制的物理无线网卡上关闭该节电配置，优先保障实时响应"
        Impact  = "可能增加功耗；配置不证明驱动运行行为或延迟收益。节点缺失、查询失败或属性不可读仍报告未知并阻断本模块，不据空结果推断不适用"
        Check   = {
            $items = @(Get-WifiPowerNodes)
            if ($items.Count -eq 0) {
                return @{ Actual = "未检测到物理 Wi-Fi 网卡"; Expected = "False (已阻断)"; IsCompliant = $true }
            }
            $allCompliant = $true
            $actualSummary = @()
            foreach ($item in $items) {
                $isPass = (@($item.Nodes | Where-Object Enable -ne $false).Count -eq 0)
                $actualSummary += "$($item.Adapter.Name): $(if ($isPass) { 'False (已关闭)' } else { 'True (仍有节点启用)' })"
                if (-not $isPass) { $allCompliant = $false }
            }
            return @{
                Actual      = $actualSummary -join "; "
                Expected    = "False (已阻断)"
                IsCompliant = $allCompliant
            }
        }
        Apply   = {
            $items = @(Get-WifiPowerNodes)
            foreach ($item in $items) {
                foreach ($node in $item.Nodes) {
                    if (-not $node.Enable) { continue }
                    Set-CimInstance -InputObject $node -Property @{ Enable = $false } -ErrorAction Stop | Out-Null
                    $after = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop |
                        Where-Object { $_.InstanceName -ieq $node.InstanceName })
                    if ($after.Count -ne 1 -or $after[0].Enable -isnot [bool] -or $after[0].Enable) {
                        throw "网卡 [$($item.Adapter.Name)] 系统节电设置写入后校验失败。"
                    }
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
Write-Host "  网络协议加固与系统更新策略基线巡检 (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查")) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$PendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()
$probeErrors = [Collections.Generic.List[string]]::new()

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

Write-Host "`n📊 [巡检看板] 网络协议与系统更新原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Select-Object 状态, 规则, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host

if ($probeErrors.Count -gt 0) {
    throw "本模块存在无法确认的属性，未执行任何写入：$($probeErrors -join '; ')"
}

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 网络协议与系统更新通道策略全部合规，无需调整。`n" -ForegroundColor Green
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

    $gateInput = (Read-Host "`n确认对齐上述 $driftCount 项网络与更新基线？[Y] 确认执行 / [N] 跳过本模块 / [Q] 退出 (默认 Y)").Trim()
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
Write-Host "`n🚀 正在单向对齐网络加固与更新通道基线..." -ForegroundColor Cyan
$appliedCount = 0
$applyErrors = [Collections.Generic.List[string]]::new()

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
Write-Host ("  ✅ [网络加固完成] 成功对齐 {0} / {1} 项基线配置" -f $appliedCount, $driftCount) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
