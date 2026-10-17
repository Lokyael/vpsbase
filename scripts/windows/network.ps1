#requires -Version 7.0
<#
.SYNOPSIS
    网络协议加固与系统更新通道策略基线

.DESCRIPTION
    Windows 11 网络协议加固、阿里公共原生 DoH 模板下发、LLMNR 阻断与更新通道策略加固模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线。
    2. 注册阿里公共 DoH 加密模板 (https://dns.alidns.com/dns-query)，并自动下发到当前活动物理网卡 (223.5.5.5 / 223.6.6.6)。
    3. 禁用本地多播名称解析 (LLMNR)，阻断局域网毒化与投毒嗅探。
    4. 禁止 Windows Update 自动覆盖第三方显卡/芯片组驱动，阻断 MRT 恶意软件删除工具推送。
    5. 禁止系统更新后有用户登录状态下自动重启，关闭 P2P 局域网/公网传递优化以节约带宽。
    6. 禁用 Microsoft Store 应用在后台静默自动下载与更新。

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
    pwsh -File .\scripts\windows\network.ps1 -Mode CheckOnly

    # 交互式检查与加固
    pwsh -File .\scripts\windows\network.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\network.ps1 -Yes
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
        Name   = "注册阿里公共 DoH 模板并下发活动物理网卡 (223.5.5.5 / 223.6.6.6)"
        Check  = {
            $doh5 = [bool](Get-DnsClientDohServerAddress -ServerAddress "223.5.5.5" -ErrorAction SilentlyContinue)
            $doh6 = [bool](Get-DnsClientDohServerAddress -ServerAddress "223.6.6.6" -ErrorAction SilentlyContinue)
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
            $netMatch = $true
            if ($adapters) {
                foreach ($nic in $adapters) {
                    $dns = (Get-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                    if (-not ($dns -contains "223.5.5.5" -and $dns -contains "223.6.6.6")) {
                        $netMatch = $false
                        break
                    }
                }
            }
            return ($doh5 -and $doh6 -and $netMatch)
        }
        Action = {
            $doh5 = Get-DnsClientDohServerAddress -ServerAddress "223.5.5.5" -ErrorAction SilentlyContinue
            if (-not $doh5) {
                Add-DnsClientDohServerAddress -ServerAddress "223.5.5.5" -DohTemplate "https://dns.alidns.com/dns-query" -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction SilentlyContinue | Out-Null
            }
            $doh6 = Get-DnsClientDohServerAddress -ServerAddress "223.6.6.6" -ErrorAction SilentlyContinue
            if (-not $doh6) {
                Add-DnsClientDohServerAddress -ServerAddress "223.6.6.6" -DohTemplate "https://dns.alidns.com/dns-query" -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction SilentlyContinue | Out-Null
            }

            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
            if ($adapters) {
                foreach ($nic in $adapters) {
                    Set-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -ServerAddresses @("223.5.5.5", "223.6.6.6") -ErrorAction SilentlyContinue
                }
            }

            Write-Host "`n  [+] 已为活动物理网卡下发阿里公共 DNS (223.5.5.5 / 223.6.6.6)，系统原生 DoH 加密已就绪。" -ForegroundColor Cyan
            Write-Host "  👉 [环境提示] 若在酒店、公共 Wi-Fi 或校园网遇到 Web 认证弹窗受阻，可执行以下命令恢复自动获取 (DHCP)：" -ForegroundColor DarkGray
            Write-Host "     Get-NetAdapter -Physical | Set-DnsClientServerAddress -ResetServerAddresses" -ForegroundColor DarkGray
        }
    },
    [PSCustomObject]@{
        Name   = "禁用 LLMNR 本地多播名称解析"
        Check  = {
            return Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" "EnableMulticast" 0
        }
        Action = {
            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "禁止 Windows Update 覆盖第三方驱动"
        Check  = {
            return Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "ExcludeWUDriversInQualityUpdate" 1
        }
        Action = {
            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "阻断 Windows 恶意软件删除工具 (MRT) 推送"
        Check  = {
            return Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\MRT" "DontOfferThroughWUAU" 1
        }
        Action = {
            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\MRT"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\MRT" -Name "DontOfferThroughWUAU" -Type DWord -Value 1 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "禁止更新后自动重启与关闭 P2P 传递优化"
        Check  = {
            $u = Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "NoAutoRebootWithLoggedOnUsers" 1
            $d = Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 0
            return ($u -and $d)
        }
        Action = {
            $au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            Ensure-Key $au
            Set-ItemProperty -Path $au -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1 -Force
            Set-ItemProperty -Path $au -Name "AUOptions" -Type DWord -Value 2 -Force

            $do = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
            Ensure-Key $do
            Set-ItemProperty -Path $do -Name "DODownloadMode" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "禁用 Microsoft Store 应用后台自动更新与下载"
        Check  = {
            return Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "AutoDownload" 2
        }
        Action = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "AutoDownload" 2
        }
    }
)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  网络协议加固与系统更新策略基线巡检 (pwsh 7+)" -ForegroundColor Cyan
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
    Write-Host "🎉 [状态完美] 网络协议与系统更新通道策略全部合规，无需调整。`n" -ForegroundColor Green
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
    Write-Host "💡 [改动说明与生效机制]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 启用系统原生 DoH 加密 DNS、切断 LLMNR 多播投毒、锁定 WU 仅推送安全质量更新" -ForegroundColor Gray
    Write-Host "   - 运维须知: 驱动更新已锁定为手动公版，如在特定校园网/Portal Web 认证受阻可执行恢复 DHCP 指令" -ForegroundColor Gray
    $choice = Read-Host "`n是否立即对齐上述 $driftCount 项网络与更新基线？[Y/n/q] (回车确认)"
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
Write-Host "`n🚀 正在单向对齐网络加固与更新通道基线..." -ForegroundColor Cyan
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
Write-Host "`n✅ [网络加固完成] 成功对齐 $successCount / $driftCount 项基线配置。`n" -ForegroundColor Green
