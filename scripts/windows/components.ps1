#requires -Version 7.0
<#
.SYNOPSIS
    消费级预装与废弃系统组件裁剪基线

.DESCRIPTION
    Windows 11 消费级预装应用卸载、废弃按需功能 (FOD) 剥离与过时 CBS 可选特性裁剪模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 批量清理 31 项消费级 UWP 预装应用（Xbox 全套、Copilot、Clipchamp、DevHome、新闻天气、Solitaire 等）。
    3. 剥离 8 项废弃按需功能 (FOD: 经典 WMP、写字板、步骤记录器、XPS 查看器等)。
    4. 禁用 8 项淘汰 CBS 可选特性 (SMBv1、PSv2、Telnet、TFTP 等)。
    5. 禁用系统保留存储 (DISM Reserved Storage)，释放 7GB+ 固态磁盘物理空间。
    6. 禁用存储感知企业组策略 (Storage Sense)，杜绝后台静默删除文件与云端脱水。
    7. 开启 PowerShell 现代解混淆脚本块日志记录 (ScriptBlockLogging=1)。
    8. 开启 LSA 受保护进程光模式 (RunAsPPL) 并切断 WDigest 内存明文凭据。
    9. 启用 Windows Defender ASR 核心攻击面减少高价值规则 (LSASS防窃取/Office防衍生子进程)。
    10. 固化 Windows Defender 特征库更新周期为 72 小时 (3 天)，保障安全智能定时静默拉取并杜绝过期警报。
    11. 卸载微软照片预装应用 (Photos，仅 Full)。
    12. 彻底卸载 Edge 浏览器 (欧盟 DMA 合规、物理粉碎与 WebView2 原生静默分流，仅 Full)。
    13. 清理驱动解包临时目录与系统出厂残留 (C:\AMD, PerfLogs 等，仅 Full)。

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
    pwsh -File .\scripts\windows\components.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\scripts\windows\components.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\components.ps1 -Yes
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
        Id      = "uwp-consumer-bloatware"
        Name    = "消费级 UWP 预装应用清理 (Xbox全套/Copilot/Clipchamp等31项)"
        Profile = "General"
        Purpose = "从所有用户账户中物理移除微软预装的商业推广应用、天气新闻与消费级全家桶，释放系统盘"
        Impact  = "若用户日常依赖特定原生应用（如 Xbox 录屏 App、微软待办 Microsoft To Do、照片视频剪辑 Clipchamp），卸载后需在微软应用商店中手动重新安装"
        Check   = {
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
                "MicrosoftTeams", "MSTeams", "Microsoft.BingSearch", "Microsoft.Windows.DevHome"
            )
            $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { ($bloatware -contains $_.Name) -and -not $_.NonRemovable })
            $isPass = ($installed.Count -eq 0)
            $actualNames = if ($isPass) { "0 项残留" } else { ($installed | ForEach-Object { $_.Name.Replace("Microsoft.", "") }) -join ', ' }
            return @{
                Actual      = $actualNames
                Expected    = "0 项残留 (全部卸载)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
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
                "MicrosoftTeams", "MSTeams", "Microsoft.BingSearch", "Microsoft.Windows.DevHome"
            )
            foreach ($pkg in $bloatware) {
                Get-AppxPackage -Name $pkg -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $pkg -or $_.PackageName -like "*$pkg*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
            }
        }
    },
    [PSCustomObject]@{
        Id      = "fod-legacy-capabilities"
        Name    = "淘汰按需功能剥离 (经典WMP/写字板/步骤记录器/XPS等10项)"
        Profile = "General"
        Purpose = "卸载经典 Media Player、写字板、步骤记录器、XPS 查看器、IE 引擎与旧版快速助手等已被现代化方案取代的过时 FOD 组件"
        Impact  = "双击 .rtf 文档或 .xps 文档时将不再自动由写字板或 XPS 查看器打开（推荐使用 Office Word 或现代 PDF 阅读器）"
        Check   = {
            $fodList = @(
                "Media.WindowsMediaPlayer~~~~0.0.12.0", "Microsoft.Windows.WordPad~~~~0.0.1.0",
                "App.StepsRecorder~~~~0.0.1.0", "XPS.Viewer~~~~0.0.1.0",
                "MathRecognizer~~~~0.0.1.0", "OpenSSH.Server~~~~0.0.1.0",
                "OneCoreUAP.OneSync~~~~0.0.1.0", "Print.Fax.Scan~~~~0.0.1.0",
                "Browser.InternetExplorer~~~~0.0.11.0", "App.Support.QuickAssist~~~~0.0.1.0"
            )
            $installed = @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { ($fodList -contains $_.Name) -and ($_.State -eq 'Installed') })
            $isPass = ($installed.Count -eq 0)
            $actualNames = if ($isPass) { "0 项已装" } else { ($installed | ForEach-Object { $_.Name -replace '~~~~.*', '' }) -join ', ' }
            return @{
                Actual      = $actualNames
                Expected    = "0 项已装 (全部剥离)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $fodList = @(
                "Media.WindowsMediaPlayer~~~~0.0.12.0", "Microsoft.Windows.WordPad~~~~0.0.1.0",
                "App.StepsRecorder~~~~0.0.1.0", "XPS.Viewer~~~~0.0.1.0",
                "MathRecognizer~~~~0.0.1.0", "OpenSSH.Server~~~~0.0.1.0",
                "OneCoreUAP.OneSync~~~~0.0.1.0", "Print.Fax.Scan~~~~0.0.1.0",
                "Browser.InternetExplorer~~~~0.0.11.0", "App.Support.QuickAssist~~~~0.0.1.0"
            )
            foreach ($f in $fodList) {
                $cap = Get-WindowsCapability -Online -Name $f -ErrorAction SilentlyContinue
                if ($cap -and $cap.State -eq 'Installed') {
                    Remove-WindowsCapability -Online -Name $f -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "cbs-legacy-optional-features"
        Name    = "淘汰 CBS 可选特性禁用 (SMBv1/PSv2/Telnet/TFTP等8项)"
        Profile = "General"
        Purpose = "彻底禁用存在已知高危远程溢出风险的淘汰协议特性 (SMB1、Telnet、TFTP、PSv2)"
        Impact  = "若局域网内存在 15 年前上古 NAS 设备仅支持旧版 SMBv1 协议共享文件，禁用后将无法通过网络邻居连接该老旧设备"
        Check   = {
            $cbsFeatures = @(
                "SMB1Protocol", "MicrosoftWindowsPowerShellV2Root", "MicrosoftWindowsPowerShellV2",
                "TelnetClient", "TFTP", "SimpleTCP", "TIFFIFilter", "WCF-NonHTTP-Activation"
            )
            $enabled = @(Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { ($cbsFeatures -contains $_.FeatureName) -and ($_.State -eq 'Enabled') })
            $isPass = ($enabled.Count -eq 0)
            $actualNames = if ($isPass) { "0 项启用" } else { ($enabled | ForEach-Object { $_.FeatureName }) -join ', ' }
            return @{
                Actual      = $actualNames
                Expected    = "0 项启用 (全部禁用)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $cbsFeatures = @(
                "SMB1Protocol", "MicrosoftWindowsPowerShellV2Root", "MicrosoftWindowsPowerShellV2",
                "TelnetClient", "TFTP", "SimpleTCP", "TIFFIFilter", "WCF-NonHTTP-Activation"
            )
            foreach ($c in $cbsFeatures) {
                $feat = Get-WindowsOptionalFeature -Online -FeatureName $c -ErrorAction SilentlyContinue
                if ($feat -and $feat.State -eq 'Enabled') {
                    Disable-WindowsOptionalFeature -Online -FeatureName $c -NoRestart -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "dism-disable-reserved-storage"
        Name    = "系统保留存储禁用 (DISM Reserved Storage，释放 7GB+ 固态物理空间)"
        Profile = "General"
        Purpose = "禁用 Windows Update 强占的 7GB 固态硬盘保留存储，释放巨额系统根盘物理空间"
        Impact  = "系统盘若处于极限严重空间不足（剩余容量低于 2GB）时，后续大版本补丁更新可能提示磁盘空间不足需先手动腾出空间"
        Check   = {
            $res = Get-WindowsReservedStorageState -ErrorAction SilentlyContinue
            $state = if ($null -ne $res -and $null -ne $res.ReservedStorageState) { "$($res.ReservedStorageState)" } else { "Unknown" }
            $isPass = ($state -eq 'Disabled')
            return @{ Actual = $state; Expected = "Disabled"; IsCompliant = $isPass }
        }
        Apply   = {
            Set-WindowsReservedStorageState -State Disabled -ErrorAction SilentlyContinue | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "storage-sense-disable-policy"
        Name    = "存储感知企业组策略禁用 (Storage Sense AllowStorageSense = 0)"
        Profile = "General"
        Purpose = "组策略级关闭存储感知静默删除用户下载文件或脱水云端文档的行为，保持数据受控"
        Impact  = "用户需要手动定期清空回收站或清理临时文件夹，系统不再会在后台静默替用户删除 30 天未打开的下载目录文件"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSense"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSense" 0
        }
    },
    [PSCustomObject]@{
        Id      = "powershell-enable-script-block-logging"
        Name    = "PowerShell 现代解混淆脚本块日志记录 (ScriptBlockLogging = 1)"
        Profile = "General"
        Purpose = "开启系统级 PowerShell 脚本块完整性审计 (Event ID 4104)，对内存管道与动态反射代码拥有解混淆后的完整可观测性"
        Impact  = "在事件查看器 Operational 日志中记录执行文本，对系统性能与日常使用零负面影响"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" "EnableScriptBlockLogging"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" "EnableScriptBlockLogging" 1
        }
    },
    [PSCustomObject]@{
        Id      = "lsa-runasppl-protection"
        Name    = "LSA 本地安全机构受保护进程光模式 (RunAsPPL = 1)"
        Profile = "General"
        Purpose = "将核心认证进程 lsass.exe 置于 PPL 保护级别，免疫未签名驱动或管理员特权下的内存转储 (Mimikatz 抓密码)"
        Impact  = "彻底阻断内存明文凭据外泄；若使用非微软官方驱动级认证插件可能受限（现代系统标准基线）"
        Check   = {
            $r1 = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "RunAsPPL"
            $r2 = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "RunAsPPLBoot"
            $isPass = ($r1 -eq "1" -and $r2 -eq "2")
            return @{ Actual = "RunAsPPL=$r1, RunAsPPLBoot=$r2"; Expected = "RunAsPPL=1, RunAsPPLBoot=2"; IsCompliant = $isPass }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "RunAsPPL" 1
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "RunAsPPLBoot" 2
        }
    },
    [PSCustomObject]@{
        Id      = "wdigest-disable-logon-credential"
        Name    = "WDigest 协议内存明文凭据缓存切断 (UseLogonCredential = 0)"
        Profile = "General"
        Purpose = "禁止 Windows 在内核内存中保留旧式 WDigest 协议的明文密码副本，消除内存明文泄漏隐患"
        Impact  = "现代网络认证完全兼容，零负面影响"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" "UseLogonCredential"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" "UseLogonCredential" 0
        }
    },
    [PSCustomObject]@{
        Id      = "defender-asr-core-rules"
        Name    = "Windows Defender 攻击面减少核心高价值规则 (ASR LSASS凭据防御/Office宏阻断)"
        Profile = "General"
        Purpose = "启用 Defender 攻击面减少规则，硬性阻断凭据从 LSASS 子系统窃取 (9e6c4e1f...)，并阻断 Office 应用程序衍生子进程 (d4f940ab...)"
        Impact  = "强力切断恶意注入与钓鱼文档执行链，开发与常规办公环境误报率极低"
        Check   = {
            $mp = Get-MpPreference -ErrorAction SilentlyContinue
            $targetRules = @{
                "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2" = "LSASS防凭据窃取"
                "d4f940ab-401b-4efc-aadc-ad5f3c50688a" = "Office防衍生子进程"
            }
            $activeCount = 0
            if ($mp -and $mp.AttackSurfaceReductionRules_Ids) {
                for ($i = 0; $i -lt $mp.AttackSurfaceReductionRules_Ids.Count; $i++) {
                    $id = "$($mp.AttackSurfaceReductionRules_Ids[$i])".ToLower()
                    $action = $mp.AttackSurfaceReductionRules_Actions[$i]
                    if ($targetRules.ContainsKey($id) -and ($action -eq 1 -or "$action" -eq "Enabled")) {
                        $activeCount++
                    }
                }
            }
            $isPass = ($activeCount -eq $targetRules.Count)
            return @{
                Actual      = if ($isPass) { "已全部启用 ($activeCount/2)" } else { "仅启用 $activeCount/2" }
                Expected    = "全部启用 (2/2)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            Add-MpPreference -AttackSurfaceReductionRules_Ids "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2" -AttackSurfaceReductionRules_Actions Enabled -ErrorAction SilentlyContinue
            Add-MpPreference -AttackSurfaceReductionRules_Ids "d4f940ab-401b-4efc-aadc-ad5f3c50688a" -AttackSurfaceReductionRules_Actions Enabled -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "defender-signature-update-interval"
        Name    = "Windows Defender 特征更新周期固化 (SignatureUpdateInterval = 72h)"
        Profile = "General"
        Purpose = "固化 Defender 独立特征更新轮询周期为 72 小时 (3 天)，在系统更新截停模式下保障病毒库定时静默拉取，根治黄色感叹号"
        Impact  = "Defender 每 3 天在后台利用闲置网络静默拉取增量特征补丁（单次约几 MB），前台游戏与编译完全零感知、零卡顿"
        Check   = {
            $mp = Get-MpPreference -ErrorAction SilentlyContinue
            $val = $mp.SignatureUpdateInterval
            $isPass = ($val -eq 72)
            return @{
                Actual      = if ($null -eq $val -or $val -eq 0) { "系统默认 (0 / 听从WindowsUpdate)" } else { "${val}h" }
                Expected    = "72h"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            Set-MpPreference -SignatureUpdateInterval 72 -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "photos-app-uninstall"
        Name    = "微软照片预装应用卸载 (Microsoft.Windows.Photos)"
        Profile = "Full"
        Purpose = "卸载原生内置照片应用，配合 PicView 极简快速看图实现秒开（若需保留原生照片请选 General）"
        Impact  = "双击图片文件将无法再使用微软原生自带的照片编辑器与幻灯片放映，需依赖第三方图片查看器（如 PicView）"
        Check   = {
            $pkg = Get-AppxPackage -Name "Microsoft.Windows.Photos" -ErrorAction SilentlyContinue
            $isPass = ($null -eq $pkg)
            return @{ Actual = if ($isPass) { "已卸载" } else { "已安装" }; Expected = "已卸载"; IsCompliant = $isPass }
        }
        Apply   = {
            Get-AppxPackage -Name "Microsoft.Windows.Photos" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.PackageName -like "*Microsoft.Windows.Photos*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "edge-browser-binary-shredding"
        Name    = "Edge 浏览器本体物理移除 (欧盟 DMA 合规卸载)"
        Profile = "Full"
        Purpose = "物理粉碎并卸载 Edge 浏览器程序本体，彻底阻断其后台常驻（若重度使用 Edge 浏览器请选 General）"
        Impact  = "系统中将不再存在 Edge 浏览器可执行程序；若使用特定只绑定 microsoft-edge:// 协议启动的极老旧应用，该链接将无法打开"
        Check   = {
            $edgeExe = (Test-Path "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe") -or
                       (Test-Path "C:\Program Files\Microsoft\Edge\Application\msedge.exe")
            $edgeReg = (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge") -or
                       (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge")
            $edgeShortcuts = @(
                "C:\Users\Public\Desktop\Microsoft Edge.lnk",
                "$([Environment]::GetFolderPath('Desktop'))\Microsoft Edge.lnk",
                "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
                "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
            ) | Where-Object { Test-Path $_ }
            $isPass = (-not $edgeExe -and -not $edgeReg -and $edgeShortcuts.Count -eq 0)
            return @{ Actual = if ($isPass) { "已物理移除" } else { "本体/卸载项/快捷方式残留" }; Expected = "已物理移除"; IsCompliant = $isPass }
        }
        Apply   = {
            Stop-Process -Name "msedge", "pwahelper", "edge_feedback", "notification_helper" -Force -ErrorAction SilentlyContinue
            @("MicrosoftEdgeElevationService", "edgeupdate", "edgeupdatem") | ForEach-Object {
                Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
            }

            $setupExe = Get-ChildItem -Path "C:\Program Files (x86)\Microsoft\Edge\Application" -Filter "setup.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($setupExe) {
                try {
                    $p = Start-Process -FilePath $setupExe.FullName -ArgumentList "--uninstall --system-level --verbose-logging --force-uninstall" -PassThru
                    $exited = $p.WaitForExit(10000)
                    if (-not $exited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
                } catch { }
            }

            @(
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
            ) | ForEach-Object {
                if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
            }

            @("MicrosoftEdgeElevationService", "edgeupdate", "edgeupdatem") | ForEach-Object {
                & sc.exe stop $_ *>$null
                & sc.exe delete $_ *>$null
            }

            @(
                "C:\Users\Public\Desktop\Microsoft Edge.lnk",
                "$([Environment]::GetFolderPath('Desktop'))\Microsoft Edge.lnk",
                "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
                "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
                "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk"
            ) | ForEach-Object {
                if (Test-Path $_) { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
            }

            @(
                "C:\Program Files (x86)\Microsoft\Edge",
                "C:\Program Files (x86)\Microsoft\EdgeCore",
                "C:\Program Files (x86)\Microsoft\EdgeUpdate",
                "$env:LOCALAPPDATA\Microsoft\Edge"
            ) | ForEach-Object {
                if (Test-Path $_) {
                    try {
                        Get-ChildItem -Path $_ -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
                        (Get-Item -Path $_ -Force).Attributes = 'Normal'
                        Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue
                    } catch { }
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "edge-update-block-policy"
        Name    = "Edge 浏览器静默更新与复活策略阻断 (EdgeUpdate Install/Update = 0)"
        Profile = "Full"
        Purpose = "组策略级锁死 Edge 浏览器重新自动下载与静默安装通道，杜绝补丁更新后复活"
        Impact  = "即使通过 Edge 安装包手动安装，系统也会因该策略阻止其安装，需先清除此组策略才允许重新装回 Edge"
        Check   = {
            $polPath = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
            $b1 = Test-RegDword $polPath "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0
            $b2 = Test-RegDword $polPath "Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0
            $b3 = Test-RegDword $polPath "DoNotUpdateToEdgeWithChromium" 1
            $isPass = ($b1 -and $b2 -and $b3)
            return @{ Actual = if ($isPass) { "已锁定阻断" } else { "未配置策略阻断" }; Expected = "Install/Update=0, DoNotUpdate=1"; IsCompliant = $isPass }
        }
        Apply   = {
            $polPath = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
            Set-RegDword $polPath "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0
            Set-RegDword $polPath "Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" 0
            Set-RegDword $polPath "DoNotUpdateToEdgeWithChromium" 1
            Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachineUA*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Id      = "webview2-runtime-allow-policy"
        Name    = "WebView2 渲染运行时原生更新放行策略 (Update{F3017226...} = 1)"
        Profile = "Full"
        Purpose = "精准策略分流：在锁死 Edge 浏览器的同时，原生放行独立 WebView2 渲染底座，确保第三方桌面应用正常渲染"
        Impact  = "零负面风险，此规则专门用于保护微信、飞书、QQ、输入法等依赖 WebView2 的第三方应用不受 Edge 卸载影响"
        Check   = {
            $polPath = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
            $w1 = Test-RegDword $polPath "Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" 1
            $w2 = Test-RegDword $polPath "Update{F3017226-FE2A-4295-8BDF-F600A7E70394}" 1
            $isPass = ($w1 -or $w2)
            return @{ Actual = if ($isPass) { "已放行 (Update=1)" } else { "未显式放行" }; Expected = "Update=1 (WebView2)"; IsCompliant = $isPass }
        }
        Apply   = {
            $polPath = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
            Set-RegDword $polPath "Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" 1
            Set-RegDword $polPath "Update{F3017226-FE2A-4295-8BDF-F600A7E70394}" 1
        }
    },
    [PSCustomObject]@{
        Id      = "clean-oem-unpacked-junk"
        Name    = "驱动解包与系统出厂残留目录清理 (C:\AMD, PerfLogs 等)"
        Profile = "Full"
        Purpose = "物理抹除 OEM 厂商出厂遗留在根盘的解包临时目录 (C:\AMD, C:\NVIDIA, C:\Intel, C:\PerfLogs)"
        Impact  = "若用户自行在这些出厂临时目录下存储了个人开发文件或未归档文档，物理抹除前请先做好检查与备份"
        Check   = {
            $junkPaths = @("C:\AMD", "C:\NVIDIA", "C:\Intel", "C:\PerfLogs")
            $exists = @($junkPaths | Where-Object { Test-Path $_ })
            $isPass = ($exists.Count -eq 0)
            return @{ Actual = if ($isPass) { "无出厂残留" } else { "存在 $($exists -join ', ')" }; Expected = "无出厂残留"; IsCompliant = $isPass }
        }
        Apply   = {
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

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  消费级预装与废弃系统组件裁剪巡检 (pwsh 7+)" -ForegroundColor Cyan
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

Write-Host "`n📊 [巡检看板] 系统组件裁剪原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 消费级预装与废弃系统组件全部合规，无需调整。`n" -ForegroundColor Green
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

    $gateInput = (Read-Host "`n确认对齐上述 $driftCount 项组件裁剪基线？[Y] 确认执行 / [N] 跳过本模块 / [Q] 退出 (默认 Y)").Trim()
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
Write-Host "`n🚀 正在单向对齐系统组件裁剪基线..." -ForegroundColor Cyan
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
Write-Host ("  ✅ [组件裁剪完成] 成功对齐 {0} / {1} 项基线配置 (预设: {2})" -f $appliedCount, $driftCount, $Profile) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
