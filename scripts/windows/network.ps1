#requires -Version 7.0
<#
.SYNOPSIS
    网络协议加固与系统更新通道策略基线

.DESCRIPTION
    Windows 11 网络协议加固、阿里公共原生 DoH 模板下发、禁用物理网卡 IPv6 并固化 RFC 6724 优先 IPv4 策略、LLMNR 阻断与更新通道加固模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 注册阿里公共 DoH 加密模板 (https://dns.alidns.com/dns-query)，并自动下发到当前活动物理网卡 (223.5.5.5 / 223.6.6.6)。
    3. 彻底解绑物理网卡 ms_tcpip6，配置内核策略 (DisabledComponents=0x20) 并调整前缀策略 (::ffff:0:0/96 优先级 50)，根除 2001::1 投毒与双栈卡顿。
    4. 禁用本地多播名称解析 (LLMNR)，阻断局域网毒化与投毒嗅探。
    5. 禁止 Windows Update 自动覆盖第三方显卡/芯片组驱动，阻断 MRT 恶意软件删除工具推送。
    6. 禁止系统更新后有用户登录状态下自动重启，关闭 P2P 局域网/公网传递优化以节约带宽。
    7. 禁用 Microsoft Store 应用在后台静默自动下载与更新。
    8. Windows Defender 防火墙全域安全基线：锁定 Domain/Private/Public 配置文件全域开启，默认阻断所有未受控入站并允许正常出站。
    9. 禁用 TCP/IP 上的 NetBIOS (NetbiosOptions=2)，切断 137/138/139 广播名称解析，收敛至纯 DNS/DoH。
    10. 强制远程桌面网络级别身份验证 (NLA)，阻断未设密码本地账户的网络远程登录。
    11. 切换中立全球 Anycast 高可用 NTP 时间同步集群 (Cloudflare / Pool / Apple)，加固 3600s 轮询，消除握手丢包与遥测心跳。

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
    pwsh -File .\scripts\windows\network.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\scripts\windows\network.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\network.ps1 -Yes
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
        Id      = "doh-template-223-5"
        Name    = "阿里公共 DoH 加密模板注册 (223.5.5.5)"
        Profile = "General"
        Purpose = "向 Windows 11 DNS 客户端注册阿里公共 DNS 的 HTTPS 加密模板，启用原生 DoH 加密通道"
        Impact  = "若阿里 DNS 服务端发生网络抖动或被网络防火墙拦截，系统会自适应回退到 UDP 53，无单点故障"
        Check   = {
            $doh = Get-DnsClientDohServerAddress -ServerAddress "223.5.5.5" -ErrorAction SilentlyContinue
            $isPass = [bool]$doh
            return @{
                Actual      = if ($isPass) { "已注册 ($($doh.DohTemplate))" } else { "未注册" }
                Expected    = "https://dns.alidns.com/dns-query"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $doh = Get-DnsClientDohServerAddress -ServerAddress "223.5.5.5" -ErrorAction SilentlyContinue
            if (-not $doh) {
                Add-DnsClientDohServerAddress -ServerAddress "223.5.5.5" -DohTemplate "https://dns.alidns.com/dns-query" -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction SilentlyContinue | Out-Null
            }
        }
    },
    [PSCustomObject]@{
        Id      = "doh-template-223-6"
        Name    = "阿里公共 DoH 加密模板注册 (223.6.6.6)"
        Profile = "General"
        Purpose = "向 Windows 11 DNS 客户端注册备用阿里公共 DNS 的 HTTPS 加密模板，提供高可用加密冗余"
        Impact  = "同主模板，支持自适应回退至标准 UDP 端口"
        Check   = {
            $doh = Get-DnsClientDohServerAddress -ServerAddress "223.6.6.6" -ErrorAction SilentlyContinue
            $isPass = [bool]$doh
            return @{
                Actual      = if ($isPass) { "已注册 ($($doh.DohTemplate))" } else { "未注册" }
                Expected    = "https://dns.alidns.com/dns-query"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $doh = Get-DnsClientDohServerAddress -ServerAddress "223.6.6.6" -ErrorAction SilentlyContinue
            if (-not $doh) {
                Add-DnsClientDohServerAddress -ServerAddress "223.6.6.6" -DohTemplate "https://dns.alidns.com/dns-query" -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction SilentlyContinue | Out-Null
            }
        }
    },
    [PSCustomObject]@{
        Id      = "nic-dns-server-addresses"
        Name    = "活动物理网卡 DNS 下发 (223.5.5.5 / 223.6.6.6)"
        Profile = "General"
        Purpose = "将活动物理网卡 DNS 指向阿里公共 DNS，配合模板自动激活端到端 DoH 加密，彻底免疫运营商 LocalDNS 劫持"
        Impact  = "在酒店、机场或校园网 Portal Web 认证页面环境下，由于阻断了局域网私有 DNS 劫持，可能无法自动弹出 Wi-Fi 登录页（需临时恢复 DHCP 获取）"
        Check   = {
            $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
            if ($adapters.Count -eq 0) {
                return @{ Actual = "无活动物理网卡"; Expected = "223.5.5.5 / 223.6.6.6"; IsCompliant = $true }
            }
            $allMatch = $true
            $actualDnsList = @()
            foreach ($nic in $adapters) {
                $dns = (Get-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                $actualDnsList += "$($nic.Name): $($dns -join ',')"
                if (-not ($dns -contains "223.5.5.5" -and $dns -contains "223.6.6.6")) {
                    $allMatch = $false
                }
            }
            return @{
                Actual      = if ($allMatch) { "已下发 ($($actualDnsList -join '; '))" } else { "$($actualDnsList -join '; ')" }
                Expected    = "223.5.5.5, 223.6.6.6"
                IsCompliant = $allMatch
            }
        }
        Apply   = {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
            foreach ($nic in $adapters) {
                Set-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -ServerAddresses @("223.5.5.5", "223.6.6.6") -ErrorAction SilentlyContinue
            }
        }
    },
    [PSCustomObject]@{
        Id      = "disable-nic-ms-tcpip6-binding"
        Name    = "物理网卡 IPv6 组件解绑 (ms_tcpip6)"
        Profile = "General"
        Purpose = "彻底解除物理网络适配器上的 IPv6 协议驱动绑定，消除劣质双栈路由带来的首包延迟与 2001::1 伪递归投毒"
        Impact  = "若处于教育网纯 IPv6 独占网络或特定仅限 IPv6 下载的 PT 节点，解绑后将无法走原生 v6 链路"
        Check   = {
            $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
            if ($adapters.Count -eq 0) { return @{ Actual = "无物理网卡"; Expected = "全部解绑"; IsCompliant = $true } }
            $enabledNics = @()
            foreach ($nic in $adapters) {
                $binding = $nic | Get-NetAdapterBinding -ComponentID "ms_tcpip6" -ErrorAction SilentlyContinue
                if ($binding -and $binding.Enabled) { $enabledNics += $nic.Name }
            }
            $isPass = ($enabledNics.Count -eq 0)
            return @{
                Actual      = if ($isPass) { "已全部解绑" } else { "绑定中 ($($enabledNics -join ', '))" }
                Expected    = "全部解绑 (Disabled)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
            foreach ($nic in $adapters) {
                $nic | Disable-NetAdapterBinding -ComponentID "ms_tcpip6" -ErrorAction SilentlyContinue
            }
        }
    },
    [PSCustomObject]@{
        Id      = "tcpip6-disabled-components-policy"
        Name    = "内核 IPv6 优先组件策略 (DisabledComponents = 0x20)"
        Profile = "General"
        Purpose = "配置 Tcpip6 协议栈偏好 IPv4 超过 IPv6 (DisabledComponents=32)，保持内核双栈兼容同时天生免疫投毒"
        Impact  = "无负面兼容副作用，符合微软官方企业级双栈网络收敛标准"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" "DisabledComponents"
            return @{ Actual = $val; Expected = "32 (0x20)"; IsCompliant = ($val -eq "32") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" "DisabledComponents" 32
        }
    },
    [PSCustomObject]@{
        Id      = "rfc6724-ipv4-prefix-precedence"
        Name    = "RFC 6724 优先 IPv4 前缀策略 (::ffff:0:0/96 优先级 50)"
        Profile = "General"
        Purpose = "依据 RFC 6724 规范调整系统地址选择前缀表，将 IPv4 映射地址优先级置于原生 IPv6 之上"
        Impact  = "系统将始终优先发起 IPv4 网络通信握手，消除双栈网络下因等待 v6 超时导致的网页打开转圈"
        Check   = {
            $policyMatch = $false
            $currentPrecedence = "<未找到>"
            $out = netsh interface ipv6 show prefixpolicies 2>$null
            foreach ($line in $out) {
                if ($line -match "^\s*(\d+)\s+\d+\s+::ffff:0:0/96") {
                    $currentPrecedence = $matches[1]
                    if ([int]$matches[1] -ge 45) { $policyMatch = $true }
                }
            }
            return @{ Actual = "Precedence=$currentPrecedence"; Expected = "Precedence=50"; IsCompliant = $policyMatch }
        }
        Apply   = {
            netsh interface ipv6 set prefixpolicy ::ffff:0:0/96 50 0 persistent | Out-Null
            netsh interface ipv6 set prefixpolicy ::/0 40 1 persistent | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "disable-llmnr-multicast"
        Name    = "LLMNR 本地多播名称解析禁用 (EnableMulticast = 0)"
        Profile = "General"
        Purpose = "切断局域网未加密链路本地多播名称解析，免疫同局域网下 Responder 恶意哈希窃取与投毒"
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
        Profile = "General"
        Purpose = "禁用网络适配器上的 NetBIOS over TCP/IP，彻底阻断 137/138/139 广播名称解析与局域网欺骗，使网络名称解析全面收敛于 DNS/DoH"
        Impact  = "无法通过古老的 NetBIOS 单机名访问未经现代 DNS 解析的极老旧内网设备（现代 SMB 445 端口直连完全不受影响）"
        Check   = {
            $nics = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object IPEnabled -eq $true)
            if ($nics.Count -eq 0) { return @{ Actual = "无 IP 适配器"; Expected = "全部为 2 (已禁用)"; IsCompliant = $true } }
            $nonCompliant = @($nics | Where-Object { $_.TcpipNetbiosOptions -ne 2 })
            $isPass = ($nonCompliant.Count -eq 0)
            $actualStr = if ($isPass) { "全部已禁用 (2)" } else { "$($nonCompliant.Count) 块网卡未禁用 ($($nonCompliant.Description -join '; '))" }
            return @{ Actual = $actualStr; Expected = "全部为 2 (已禁用)"; IsCompliant = $isPass }
        }
        Apply   = {
            $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object IPEnabled -eq $true
            foreach ($nic in $nics) {
                if ($nic.TcpipNetbiosOptions -ne 2) {
                    $nic.SetTcpipNetbios(2) | Out-Null
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "rdp-require-nla"
        Name    = "远程桌面网络级别身份验证强制 (NLA UserAuthentication = 1)"
        Profile = "General"
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
        Profile = "General"
        Purpose = "若系统本地账户未设密码，强制切断一切通过网络发起该账户认证的远程交互通道（RDP/SMB/WinRM），杜绝横向渗透"
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
        Profile = "General"
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
        Profile = "General"
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
        Id      = "disable-wu-auto-reboot"
        Name    = "登录状态系统更新强制自动重启阻断 (NoAutoRebootWithLoggedOnUsers = 1)"
        Profile = "General"
        Purpose = "有用户登录会话时，系统更新安装完毕后严禁强行触发自动重启，杜绝未保存工作与编译状态丢失"
        Impact  = "安装重要系统安全累积补丁后，若长期不手动重启，新补丁不会最终生效"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "NoAutoRebootWithLoggedOnUsers"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            $au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            Set-RegDword $au "NoAutoRebootWithLoggedOnUsers" 1
            Set-RegDword $au "AUOptions" 2
        }
    },
    [PSCustomObject]@{
        Id      = "disable-delivery-optimization-p2p"
        Name    = "传递优化 P2P 局域网/公网上传切断 (DODownloadMode = 0)"
        Profile = "General"
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
        Profile = "General"
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
        Profile = "General"
        Purpose = "强制开启 Windows Defender 防火墙三大配置文件，锁定默认入站全部阻断，坚守网络安全最小暴露面"
        Impact  = "本地运行临时网络服务（如临时起 Python HTTP 服务、本地调试端口）时，若未明确放行入站规则，外部设备将无法访问"
        Check   = {
            $profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
            if (-not $profiles -or $profiles.Count -lt 3) {
                return @{ Actual = "未获取到防火墙配置"; Expected = "3 域全部 Block"; IsCompliant = $false }
            }
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
            Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block -ErrorAction SilentlyContinue | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "firewall-outbound-allow-all"
        Name    = "Defender 防火墙全域出站放行基线 (Domain/Private/Public Allow Outbound)"
        Profile = "General"
        Purpose = "确保 Windows Defender 防火墙全域默认出站放行，保障本地应用程序正常请求互联网"
        Impact  = "恶意软件发起的出站流量默认不会被出站规则硬阻断，需依赖 Defender 实时防护查杀"
        Check   = {
            $profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
            if (-not $profiles -or $profiles.Count -lt 3) {
                return @{ Actual = "未获取到防火墙配置"; Expected = "3 域全部 Allow"; IsCompliant = $false }
            }
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
            Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Allow -ErrorAction SilentlyContinue | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "ntp-time-servers-anycast"
        Name    = "Anycast 高可用中立 NTP 时间服务器集群 (Cloudflare / Pool / Apple)"
        Profile = "General"
        Purpose = "将时间同步源由微软遥测节点 (time.windows.com) 替换为全球 Anycast 高可用中立集群，消除握手超时并杜绝存活心跳遥测"
        Impact  = "系统时间同步直接向 Cloudflare / Pool.ntp.org / Apple 发送校时报文，不再向微软 time.windows.com 发送请求"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" "NtpServer"
            $isPass = ($val -match "time\.cloudflare\.com" -and $val -match "pool\.ntp\.org")
            return @{
                Actual      = $val
                Expected    = "time.cloudflare.com,0x9 pool.ntp.org,0x9 time.apple.com,0x9"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "NtpServer" -Value "time.cloudflare.com,0x9 pool.ntp.org,0x9 time.apple.com,0x9" -Force
            Restart-Service w32time -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "ntp-sync-type-standard"
        Name    = "时间客户端同步协议模式 (Type = NTP)"
        Profile = "General"
        Purpose = "强制将 Windows Time 客户端模式锁定为标准独立 NTP 模式，阻断域时间层次结构覆盖"
        Impact  = "工作站脱离活动目录域控的时间强制覆盖，完全按本地配置的 NTP 服务器独立校时"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" "Type"
            return @{ Actual = $val; Expected = "NTP"; IsCompliant = ($val -eq "NTP") }
        }
        Apply   = {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "Type" -Value "NTP" -Force
        }
    },
    [PSCustomObject]@{
        Id      = "ntp-special-poll-interval"
        Name    = "NTP 校时间隔固化 (SpecialPollInterval = 3600s)"
        Profile = "General"
        Purpose = "将时间同步周期固化为 3600 秒 (1 小时)，保障时钟精度并防止漂移超过 3 分钟触发 TLS 证书与 TOTP 鉴权失效"
        Impact  = "时间同步客户端每小时发起一次校时查询，维持高精度本地时钟"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient" "SpecialPollInterval"
            return @{ Actual = $val; Expected = "3600"; IsCompliant = ($val -eq "3600") }
        }
        Apply   = {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient"
            Ensure-RegKey $key
            Set-RegDword $key "SpecialPollInterval" 3600
        }
    }
)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  网络协议加固与系统更新策略基线巡检 (pwsh 7+)" -ForegroundColor Cyan
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

Write-Host "`n📊 [巡检看板] 网络协议与系统更新原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

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
Write-Host "`n🚀 正在单向对齐网络加固与更新通道基线..." -ForegroundColor Cyan
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
Write-Host ("  ✅ [网络加固完成] 成功对齐 {0} / {1} 项基线配置 (预设: {2})" -f $appliedCount, $driftCount, $Profile) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
