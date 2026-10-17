#requires -Version 7.0
<#
.SYNOPSIS
    遥测采集与推广推送阻断基线

.DESCRIPTION
    Windows 11 操作系统遥测阻断、错误报告剥离、广告推送切断与隐私加固基准模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线（Plan -> Diff -> Gate -> Apply -> Report）。
    2. 深度切断 DiagTrack、dmwappushservice、CEIP 与 SQMClient 遥测数据流。
    3. 禁用活动历史跨设备流转 (Project Rome) 与 Windows 错误报告 (WER)。
    4. 阻断 CloudContent 消费级静默预装、更新全屏推销 (SCOOBE) 与开始菜单推广建议。
    5. 限制剪贴板历史仅限本地，停用 DPS/WDI 诊断策略服务，切断 Edge 后台常驻。
    6. 阻断外设厂商推广套件与驱动协同安装器静默注入 (Razer 等驱动全家桶)。

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
    pwsh -File .\scripts\windows\telemetry.ps1 -Mode CheckOnly

    # 交互式检查与加固
    pwsh -File .\scripts\windows\telemetry.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\telemetry.ps1 -Yes
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
# 内部辅助函数 (自包含自闭合)
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
        Name   = "禁用系统诊断遥测与推送服务 (DiagTrack / dmwappushservice)"
        Check  = {
            $p1 = Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
            $s1 = (Get-Service DiagTrack -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            $s2 = (Get-Service dmwappushservice -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            $p2 = Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows" "CEIPEnable" 0
            $p3 = Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
            return ($p1 -and $s1 -and $s2 -and $p2 -and $p3)
        }
        Action = {
            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Type DWord -Value 0 -Force
            Stop-Service -Name DiagTrack -Force -ErrorAction SilentlyContinue
            Set-Service -Name DiagTrack -StartupType Disabled
            Stop-Service -Name dmwappushservice -Force -ErrorAction SilentlyContinue
            Set-Service -Name dmwappushservice -StartupType Disabled
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows" "CEIPEnable" 0
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
        }
    },
    [PSCustomObject]@{
        Name   = "禁用活动历史记录上报与跨设备流转 (Project Rome)"
        Check  = {
            $s = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
            return (Test-RegDword $s "EnableActivityFeed" 0) -and
                   (Test-RegDword $s "PublishUserActivities" 0) -and
                   (Test-RegDword $s "UploadUserActivities" 0) -and
                   (Test-RegDword $s "EnableMmx" 0)
        }
        Action = {
            $sys = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
            Ensure-Key $sys
            Set-ItemProperty -Path $sys -Name "EnableActivityFeed" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $sys -Name "PublishUserActivities" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $sys -Name "UploadUserActivities" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $sys -Name "EnableMmx" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "禁用 Windows 错误报告 (WER)"
        Check  = {
            $wer = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
            $p = Test-RegDword $wer "Disabled" 1
            $s = (Get-Service WerSvc -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            return ($p -and $s)
        }
        Action = {
            $wer = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
            Ensure-Key $wer
            Set-ItemProperty -Path $wer -Name "Disabled" -Type DWord -Value 1 -Force
            Stop-Service -Name WerSvc -Force -ErrorAction SilentlyContinue
            Set-Service -Name WerSvc -StartupType Disabled
        }
    },
    [PSCustomObject]@{
        Name   = "禁用广告 ID 与内容推广推送"
        Check  = {
            $ad = Test-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0
            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            $c1 = Test-RegDword $cdm "ContentDeliveryAllowed" 0
            $c2 = Test-RegDword $cdm "OemPreInstalledAppsEnabled" 0
            $c3 = (Test-RegDword $cdm "SubscribedContent-338388Enabled" 0) -and (Test-RegDword $cdm "SubscribedContent-338387Enabled" 0) -and (Test-RegDword $cdm "SubscribedContent-353694Enabled" 0)
            $adv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            $t = Test-RegDword $adv "Start_TrackProgs" 0
            return ($ad -and $c1 -and $c2 -and $c3 -and $t)
        }
        Action = {
            Ensure-Key "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Type DWord -Value 0 -Force

            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            Ensure-Key $cdm
            Set-ItemProperty -Path $cdm -Name "ContentDeliveryAllowed" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "OemPreInstalledAppsEnabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "PreInstalledAppsEnabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "SilentInstalledAppsEnabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "SubscribedContent-338387Enabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "SubscribedContent-338388Enabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "SubscribedContent-338389Enabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "SubscribedContent-310093Enabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "SubscribedContent-353694Enabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "SubscribedContent-353696Enabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $cdm -Name "RotatingLockScreenOverlayEnabled" -Type DWord -Value 0 -Force

            Ensure-Key "HKCU:\Control Panel\International\User Profile"
            Set-ItemProperty -Path "HKCU:\Control Panel\International\User Profile" -Name "HttpAcceptLanguageOptOut" -Type DWord -Value 1 -Force
            Ensure-Key "HKCU:\Software\Microsoft\Personalization\Settings"
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Personalization\Settings" -Name "AcceptedPrivacyPolicy" -Type DWord -Value 0 -Force
            Ensure-Key "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_TrackProgs" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "禁用 Windows 消费级体验与云端静默预装 (CloudContent)"
        Check  = {
            return Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
        }
        Action = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
        }
    },
    [PSCustomObject]@{
        Name   = "阻断更新全屏推销 (SCOOBE) 与满意度调查 (SIUF)"
        Check  = {
            $u = Test-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 0
            $s = Test-RegDword "HKCU:\Software\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod" 0
            return ($u -and $s)
        }
        Action = {
            $upe = "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
            Ensure-Key $upe
            Set-ItemProperty -Path $upe -Name "ScoobeSystemSettingEnabled" -Type DWord -Value 0 -Force
            Ensure-Key "HKCU:\Software\Microsoft\Siuf\Rules"
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Siuf\Rules" -Name "NumberOfSIUFInPeriod" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "限制剪贴板历史仅限本地 (切断云同步)"
        Check  = {
            $cb = "HKCU:\Software\Microsoft\Clipboard"
            $c1 = Test-RegDword $cb "EnableClipboardHistory" 1
            $c2 = Test-RegDword $cb "AllowCrossDeviceClipboard" 0
            return ($c1 -and $c2)
        }
        Action = {
            Ensure-Key "HKCU:\Software\Microsoft\Clipboard"
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Clipboard" -Name "EnableClipboardHistory" -Type DWord -Value 1 -Force
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Clipboard" -Name "AllowCrossDeviceClipboard" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "停用系统诊断策略服务与辅助主机 (DPS / WDI / 诊断任务)"
        Check  = {
            $s1 = (Get-Service DPS -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            $s2 = (Get-Service WdiServiceHost -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            $s3 = (Get-Service WdiSystemHost -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            $tasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Diagnosis\" -ErrorAction SilentlyContinue
            $tReady = ($null -eq $tasks -or ($tasks | Where-Object State -ne 'Disabled').Count -eq 0)
            return ($s1 -and $s2 -and $s3 -and $tReady)
        }
        Action = {
            @("DPS", "WdiServiceHost", "WdiSystemHost") | ForEach-Object {
                Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
                Set-Service -Name $_ -StartupType Disabled -ErrorAction SilentlyContinue
            }
            Get-ScheduledTask -TaskPath "\Microsoft\Windows\Diagnosis\" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
        }
    },
    [PSCustomObject]@{
        Name   = "禁止 Edge 浏览器后台常驻与预加载"
        Check  = {
            $e = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            return (Test-RegDword $e "BackgroundModeEnabled" 0) -and (Test-RegDword $e "StartupBoostEnabled" 0)
        }
        Action = {
            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "BackgroundModeEnabled" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "StartupBoostEnabled" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "阻断外设厂商推广套件与驱动共同安装器 (Razer 等)"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $devMeta = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue).PreventDeviceMetadataFromNetwork
            $coInst = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings" -Name "DisableCoInstallers" -ErrorAction SilentlyContinue).DisableCoInstallers
            $ifeo = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RazerInstaller.exe" -Name "Debugger" -ErrorAction SilentlyContinue).Debugger
            return ($devMeta -eq 1 -and $coInst -eq 1 -and $ifeo -eq "systray.exe")
        }
        Action = {
            if ($Profile -eq 'General') { return }
            $devMetaKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"
            Ensure-Key $devMetaKey
            Set-ItemProperty -Path $devMetaKey -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1 -Force

            Ensure-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings" -Name "DisableCoInstallers" -Type DWord -Value 1 -Force

            Ensure-Key "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RazerInstaller.exe"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RazerInstaller.exe" -Name "Debugger" -Value "systray.exe" -Force
        }
    }
)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  遥测采集与推广推送阻断基线巡检 (pwsh 7+)" -ForegroundColor Cyan
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
    Write-Host "✨ [状态合规] 遥测阻断与推广切断基准全部合规，无需调整。`n" -ForegroundColor Green
    return
}

Write-Host "⚠️  共发现 $driftCount 项基线偏离。" -ForegroundColor Yellow

# 只查不改模式直接退出
if ($Mode -eq "CheckOnly") {
    Write-Host "💡 当前处于 -Mode CheckOnly 只查不改模式，未执行任何系统改动。`n" -ForegroundColor Gray
    return
}

# ==============================================================================
# 阶段 2: 审查门禁 (Gate)
# ==============================================================================
if (-not $Yes -and -not $NonInteractive) {
    Write-Host "💡 [改动说明与生效机制]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 阻断 DiagTrack 遥测回传、禁用活动历史跨设备流转 (Rome) 与错误报告 (WER)" -ForegroundColor Gray
    Write-Host "   - 隐私保障: 限制剪贴板历史仅限纯本地（不上传云端），阻断 CloudContent 消费级静默推广" -ForegroundColor Gray
    $choice = Read-Host "`n是否立即对齐上述 $driftCount 项遥测阻断基线？[Y/n/q] (回车确认)"
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
Write-Host "`n🚀 正在单向对齐遥测阻断基线..." -ForegroundColor Cyan
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
Write-Host "`n✅ [遥测加固完成] 成功对齐 $successCount / $driftCount 项基线配置。`n" -ForegroundColor Green
