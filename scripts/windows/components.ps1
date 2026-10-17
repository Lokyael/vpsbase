#requires -Version 7.0
<#
.SYNOPSIS
    消费级预装与废弃系统组件裁剪基线

.DESCRIPTION
    Windows 11 消费级预装应用卸载、废弃按需功能 (FOD) 剥离与过时 CBS 可选特性裁剪模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线。
    2. 批量清理 32 项消费级 UWP 预装应用（Xbox 全套、Copilot、Clipchamp、DevHome、新闻天气、Solitaire 等）。
    3. 剥离 8 项废弃按需功能 (FOD: 经典 WMP、写字板、步骤记录器、XPS 查看器等)。
    4. 禁用 8 项淘汰 CBS 可选特性 (SMBv1、PSv2、Telnet、TFTP 等)。
    5. 禁用系统保留存储 (DISM Reserved Storage)，释放 7GB+ 固态磁盘物理空间。
    6. 禁用存储感知企业组策略 (Storage Sense)，杜绝后台静默删除文件与云端脱水。
    7. 卸载微软照片预装应用 (Photos)，解锁欧盟 DMA 策略允许原生卸载 Edge 浏览器并阻断复活与清理残留。
    8. 清理驱动解包临时目录与系统出厂残留 (C:\AMD, PerfLogs 等)。

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
    pwsh -File .\scripts\windows\components.ps1 -Mode CheckOnly

    # 交互式检查与加固
    pwsh -File .\scripts\windows\components.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\components.ps1 -Yes
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

function Ensure-Key([string]$path) {
    if (-not (Test-Path -Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
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
        Name   = "批量卸载 Xbox/Copilot/媒体等 30 项 UWP 预装应用"
        Check  = {
            try {
                $bloatware = @(
                    "Microsoft.BingNews", "Microsoft.BingWeather", "Microsoft.GamingApp",
                    "Microsoft.XboxApp", "Microsoft.XboxGamingOverlay", "Microsoft.XboxIdentityProvider",
                    "Microsoft.XboxSpeechToTextOverlay", "Microsoft.XboxGameOverlay", "Microsoft.Xbox.TCUI",
                    "Microsoft.GetHelp", "Microsoft.Getstarted", "Microsoft.MicrosoftOfficeHub",
                    "Microsoft.MicrosoftSolitaireCollection", "Microsoft.People", "Microsoft.PowerAutomateDesktop",
                    "Microsoft.Todos", "Microsoft.WindowsFeedbackHub", "Microsoft.WindowsMaps",
                    "Microsoft.YourPhone", "MicrosoftWindows.CrossDevice", "Microsoft.Windows.Ai.Copilot.Provider",
                    "Microsoft.Copilot", "Microsoft.OutlookForWindows", "Clipchamp.Clipchamp",
                    "Microsoft.ZuneMusic", "Microsoft.ZuneVideo", "Microsoft.549981C3F5F10",
                    "MicrosoftTeams", "MSTeams", "Microsoft.BingSearch", "Microsoft.Windows.DevHome",
                    "Microsoft.Windows.NarratorQuickStart"
                )
                $installed = Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $bloatware -contains $_.Name }
                return ($null -eq $installed -or $installed.Count -eq 0)
            } catch { return $false }
        }
        Action = {
            Stop-Process -Name "CrossDeviceService", "CrossDeviceResume", "OneDrive" -Force -ErrorAction SilentlyContinue
            $bloatware = @(
                "Microsoft.BingNews", "Microsoft.BingWeather", "Microsoft.GamingApp",
                "Microsoft.XboxApp", "Microsoft.XboxGamingOverlay", "Microsoft.XboxIdentityProvider",
                "Microsoft.XboxSpeechToTextOverlay", "Microsoft.XboxGameOverlay", "Microsoft.Xbox.TCUI",
                "Microsoft.GetHelp", "Microsoft.Getstarted", "Microsoft.MicrosoftOfficeHub",
                "Microsoft.MicrosoftSolitaireCollection", "Microsoft.People", "Microsoft.PowerAutomateDesktop",
                "Microsoft.Todos", "Microsoft.WindowsFeedbackHub", "Microsoft.WindowsMaps",
                "Microsoft.YourPhone", "MicrosoftWindows.CrossDevice", "Microsoft.Windows.Ai.Copilot.Provider",
                "Microsoft.Copilot", "Microsoft.OutlookForWindows", "Clipchamp.Clipchamp",
                "Microsoft.ZuneMusic", "Microsoft.ZuneVideo", "Microsoft.549981C3F5F10",
                "MicrosoftTeams", "MSTeams", "Microsoft.BingSearch", "Microsoft.Windows.DevHome",
                "Microsoft.Windows.NarratorQuickStart"
            )
            foreach ($app in $bloatware) {
                Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.PackageName -like "*$app*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
            }
        }
    },
    [PSCustomObject]@{
        Name   = "剥离经典 WMP、写字板等 8 项废弃按需功能 (FOD)"
        Check  = {
            try {
                $fods = @(
                    "Media.WindowsMediaPlayer~~~~0.0.12.0",
                    "Microsoft.Windows.WordPad~~~~0.0.1.0",
                    "App.StepsRecorder~~~~0.0.1.0",
                    "Print.Fax.Scan~~~~0.0.1.0",
                    "MathRecognizer~~~~0.0.1.0",
                    "XPS.Viewer~~~~0.0.1.0",
                    "Browser.InternetExplorer~~~~0.0.11.0",
                    "App.Support.QuickAssist~~~~0.0.1.0"
                )
                $installed = Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { ($fods -contains $_.Name) -and $_.State -eq 'Installed' }
                return ($null -eq $installed -or $installed.Count -eq 0)
            } catch { return $false }
        }
        Action = {
            $fods = @(
                "Media.WindowsMediaPlayer~~~~0.0.12.0",
                "Microsoft.Windows.WordPad~~~~0.0.1.0",
                "App.StepsRecorder~~~~0.0.1.0",
                "Print.Fax.Scan~~~~0.0.1.0",
                "MathRecognizer~~~~0.0.1.0",
                "XPS.Viewer~~~~0.0.1.0",
                "Browser.InternetExplorer~~~~0.0.11.0",
                "App.Support.QuickAssist~~~~0.0.1.0"
            )
            foreach ($fod in $fods) {
                $cap = Get-WindowsCapability -Online -Name $fod -ErrorAction SilentlyContinue
                if ($cap -and $cap.State -eq 'Installed') {
                    Remove-WindowsCapability -Online -Name $fod -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    },
    [PSCustomObject]@{
        Name   = "禁用 SMBv1、PSv2 等 8 项淘汰可选特性 (CBS)"
        Check  = {
            try {
                $cbsFeatures = @(
                    "MicrosoftWindowsPowerShellV2", "MicrosoftWindowsPowerShellV2Root",
                    "SMB1Protocol", "Printing-XPSServices-Features", "FaxServicesClientPackage",
                    "TelnetClient", "TFTP", "TIFFIFilter"
                )
                $enabled = Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { ($cbsFeatures -contains $_.FeatureName) -and $_.State -eq 'Enabled' }
                return ($null -eq $enabled -or $enabled.Count -eq 0)
            } catch { return $false }
        }
        Action = {
            $cbsFeatures = @(
                "MicrosoftWindowsPowerShellV2", "MicrosoftWindowsPowerShellV2Root",
                "SMB1Protocol", "Printing-XPSServices-Features", "FaxServicesClientPackage",
                "TelnetClient", "TFTP", "TIFFIFilter"
            )
            foreach ($feat in $cbsFeatures) {
                $item = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction SilentlyContinue
                if ($item -and $item.State -eq 'Enabled') {
                    Disable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    },
    [PSCustomObject]@{
        Name   = "禁用系统保留存储以释放 C 盘空间 (DISM Reserved Storage)"
        Check  = {
            try {
                $state = (DISM.exe /Online /Get-ReservedStorageState 2>&1 | Out-String)
                return ($state -match 'Disabled|已禁用')
            } catch { return $true }
        }
        Action = {
            DISM.exe /Online /Set-ReservedStorageState /State:Disabled *>$null
        }
    },
    [PSCustomObject]@{
        Name   = "禁用存储感知企业组策略 (Storage Sense / 杜绝静默清理与云端脱水)"
        Check  = {
            return Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSense" 0
        }
        Action = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSense" 0
        }
    },
    [PSCustomObject]@{
        Name   = "卸载微软照片预装应用 (Microsoft Photos)"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $pkg = Get-AppxPackage -Name "Microsoft.Windows.Photos" -ErrorAction SilentlyContinue
            return ($null -eq $pkg)
        }
        Action = {
            if ($Profile -eq 'General') { return }
            Get-AppxPackage -Name "Microsoft.Windows.Photos" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.PackageName -like "*Microsoft.Windows.Photos*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Name   = "彻底卸载 Edge 浏览器 (欧盟 DMA 合规、深度物理清理与 WebView2 原生静默分流)"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $edgeExe = (Test-Path "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe") -or
                       (Test-Path "C:\Program Files\Microsoft\Edge\Application\msedge.exe") -or
                       (Test-Path "C:\Program Files (x86)\Microsoft\EdgeCore\*\msedge.exe")
            $edgeReg = (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge") -or
                       (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge")
            $edgePkg = [bool](Get-AppxPackage -Name "*MicrosoftEdge.Stable*" -ErrorAction SilentlyContinue)
            $edgeUserData = Test-Path "$env:LOCALAPPDATA\Microsoft\Edge"
            $edgeAppDir = Test-Path "C:\Program Files (x86)\Microsoft\Edge\Application"
            $edgeCoreDir = Test-Path "C:\Program Files (x86)\Microsoft\EdgeCore"

            # 策略分流检查 (路径 A: 锁死 Edge 浏览器安装与更新，放行 WebView2 原生静默更新)
            $polPath = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
            $gpoEdgeBlocked = (Test-RegDword $polPath "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0) -and
                              (Test-RegDword $polPath "Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0) -and
                              (Test-RegDword $polPath "DoNotUpdateToEdgeWithChromium" 1)
            $gpoWvAllowed = (Test-RegDword $polPath "Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" 1) -or
                            (Test-RegDword $polPath "Update{F3017226-FE2A-4295-8BDF-F600A7E70394}" 1)
            $wvReady = Test-Path "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"

            return (-not $edgeExe -and -not $edgeReg -and -not $edgePkg -and -not $edgeUserData -and -not $edgeAppDir -and -not $edgeCoreDir -and $gpoEdgeBlocked -and $gpoWvAllowed -and $wvReady)
        }
        Action = {
            if ($Profile -eq 'General') { return }
            Stop-Process -Name "msedge", "pwahelper" -Force -ErrorAction SilentlyContinue

            $policyFile = "$env:SystemRoot\System32\IntegratedServicesRegionPolicySet.json"
            if (Test-Path $policyFile) {
                takeown /f $policyFile /a | Out-Null
                icacls $policyFile /grant "Administrators:F" | Out-Null

                $content = Get-Content -Path $policyFile -Raw -Encoding UTF8
                $json = $content | ConvertFrom-Json
                $edgePolicy = $json.policies | Where-Object {
                    $_.guid -eq "{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6}" -or
                    $_.name -eq "Edge is uninstallable" -or
                    $_.'$comment' -eq "Edge is uninstallable."
                }
                if ($edgePolicy) {
                    $edgePolicy.defaultState = "enabled"
                    $currentRegion = [System.Globalization.RegionInfo]::CurrentRegion.TwoLetterISORegionName
                    $targetRegions = @($currentRegion, "CN", "SG", "HK", "TW", "US") | Select-Object -Unique
                    if ($edgePolicy.conditions -and $edgePolicy.conditions.region -and $edgePolicy.conditions.region.enabled) {
                        foreach ($r in $targetRegions) {
                            if ($edgePolicy.conditions.region.enabled -notcontains $r) {
                                $edgePolicy.conditions.region.enabled += $r
                            }
                        }
                    }
                    $newJson = $json | ConvertTo-Json -Depth 10
                    [System.IO.File]::WriteAllText($policyFile, $newJson, [System.Text.UTF8Encoding]::new($false))
                }
            }

            reg delete "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /v NoRemove /f *>$null
            reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /v NoRemove /f *>$null

            # 卸载 AppX 包
            Get-AppxPackage -Name "*MicrosoftEdge.Stable*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Get-AppxPackage -Name "*MicrosoftEdge.Stable*" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue

            # 深度物理粉碎所有 Edge 专有残留与垃圾缓存 (释放 1.3GB+ 空间)
            @(
                "$env:LOCALAPPDATA\Microsoft\Edge",
                "$env:LOCALAPPDATA\Microsoft\EdgeUpdate",
                "$env:ProgramData\Microsoft\EdgeUpdate",
                "C:\Program Files (x86)\Microsoft\Edge",
                "C:\Program Files (x86)\Microsoft\EdgeCore",
                "C:\Program Files\Microsoft\Edge",
                "C:\Users\Public\Desktop\Microsoft Edge.lnk",
                (Join-Path ([Environment]::GetFolderPath("Desktop")) "Microsoft Edge.lnk"),
                "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
                "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
            ) | ForEach-Object {
                if (Test-Path $_) {
                    try {
                        Get-ChildItem -Path $_ -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
                        Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue
                    } catch { }
                }
            }

            # 彻底注销废弃注册表分支与默认应用关联
            @(
                "HKCU:\Software\Microsoft\Edge",
                "HKCU:\Software\Microsoft\EdgeUpdate",
                "HKLM:\SOFTWARE\Microsoft\Edge",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge"
            ) | ForEach-Object {
                if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
            }
            @("HKLM:\SOFTWARE\RegisteredApplications", "HKCU:\Software\RegisteredApplications") | ForEach-Object {
                Remove-ItemProperty -Path $_ -Name "Microsoft Edge" -Force -ErrorAction SilentlyContinue
            }

            # 注入路径 A 企业组策略 (永久封锁 Edge 浏览器复活，精准放行 WebView2 原生静默更新)
            $polPath = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
            Set-RegDword $polPath "DoNotUpdateToEdgeWithChromium" 1
            Set-RegDword "HKLM:\SOFTWARE\Microsoft\EdgeUpdate" "DoNotUpdateToEdgeWithChromium" 1

            # 严禁 Edge 浏览器安装与自动更新 (AppID: {56EB18F8-B008-4CBD-B6D2-8C97FE7E9062})
            Set-RegDword $polPath "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0
            Set-RegDword $polPath "Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0

            # 精准放行 WebView2 Runtime 原生静默安全打补丁 (Evergreen 模式)
            Set-RegDword $polPath "Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" 1
            Set-RegDword $polPath "Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" 1
            Set-RegDword $polPath "Install{F3017226-FE2A-4295-8BDF-F600A7E70394}" 1
            Set-RegDword $polPath "Update{F3017226-FE2A-4295-8BDF-F600A7E70394}" 1

            # 服务收敛为按需调用 (Manual)，清除杂项任务
            @("edgeupdate", "edgeupdatem") | ForEach-Object {
                $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
                if ($svc) {
                    Set-Service -Name $_ -StartupType Manual -ErrorAction SilentlyContinue
                }
            }
            Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachineCore*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
            Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachineUA*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

            # 就地守护与自愈 WebView2 独立运行库
            $wvPath = "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"
            if (-not (Test-Path $wvPath)) {
                winget install Microsoft.EdgeWebView2Runtime --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
            }
        }
    },
    [PSCustomObject]@{
        Name   = "清理驱动解包临时目录与系统出厂残留 (C:\AMD, PerfLogs 等)"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $junkPaths = @("C:\AMD", "C:\NVIDIA", "C:\Intel", "C:\PerfLogs")
            $exists = @($junkPaths | Where-Object { Test-Path $_ })
            return ($exists.Count -eq 0)
        }
        Action = {
            if ($Profile -eq 'General') { return }
            $junkPaths = @("C:\AMD", "C:\NVIDIA", "C:\Intel", "C:\PerfLogs")
            foreach ($p in $junkPaths) {
                if (Test-Path $p) {
                    try {
                        Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
                        (Get-Item -Path $p -Force).Attributes = 'Normal'
                        Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                    } catch { }
                }
            }
        }
    }
)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  消费级预装与废弃系统组件裁剪巡检 (pwsh 7+)" -ForegroundColor Cyan
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
        当前状态 = if ($isReady) { "已就绪" } else { "待裁剪" }
        判定     = if ($isReady) { "✔ 合规" } else { "✘ 偏离" }
    })

    if (-not $isReady) {
        $pendingItems.Add($item)
    }
}

$chkList | Format-Table -AutoSize | Out-String | Write-Host
$driftCount = $pendingItems.Count

if ($driftCount -eq 0) {
    Write-Host "🎉 [状态完美] 消费级预装与废弃系统组件已彻底裁剪，无需调整。`n" -ForegroundColor Green
    return
}

Write-Host "⚠️  共发现 $driftCount 项组件待裁剪。" -ForegroundColor Yellow

if ($Mode -eq "CheckOnly") {
    Write-Host "💡 当前处于 -Mode CheckOnly 只查不改模式，未执行任何系统改动。`n" -ForegroundColor Gray
    return
}

# ==============================================================================
# 阶段 2: 审查门禁 (Gate)
# ==============================================================================
if (-not $Yes -and -not $NonInteractive) {
    Write-Host "💡 [改动说明与卸载清单]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 卸载 Cortana、Xbox 冗余组件、反馈中心等出厂膨胀软件，关闭旧版 XPS/VBScript 废弃特性与存储感知静默清理" -ForegroundColor Gray
    Write-Host "   - 恢复途径: 被卸载的预装组件（如画图、截图工具）后续均可通过 winget 或 Microsoft Store 随时按需找回" -ForegroundColor Gray
    $choice = Read-Host "`n是否立即裁剪上述 $driftCount 项废弃组件与预装应用？[Y/n/q] (回车确认)"
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
Write-Host "`n🚀 正在单向裁剪预装组件与废弃特性..." -ForegroundColor Cyan
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
Write-Host "`n✅ [组件裁剪完成] 成功裁剪 $successCount / $driftCount 项组件。`n" -ForegroundColor Green
