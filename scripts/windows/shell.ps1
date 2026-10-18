#requires -Version 7.0
<#
.SYNOPSIS
    交互体验与系统外壳视觉裁剪基线

.DESCRIPTION
    Windows 11 外壳交互纯净化、小组件切断、任务栏轻量化与资源管理器极简基准模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 资源管理器默认打开“此电脑”，全景显示已知文件扩展名与隐藏文件。
    3. 剥离任务栏小组件 (Widgets) 资讯流与 Teams 聊天 (Chat) 图标。
    4. 禁用连按 5 次 Shift 触发粘滞键与筛选键劫持（杜绝游戏与编程中断）。
    5. 禁用 Windows 聚焦锁屏动态建议、广告推销与开始菜单推荐项目。
    6. 禁用 USB 移动介质自动播放 (AutoPlay) 阻断蠕虫自启传播。
    7. 解除耳机音量 37% 限制警告弹窗 (VolumeLimiter)。
    8. 彻底卸载 OneDrive、清理用户目录并剥离资源管理器侧边栏驻留 (仅 Full)。
    9. 剥离资源管理器图库 (Gallery) 驻留与遗留已知文件夹沙盒化 (仅 Full)。
    10. 从左侧导航窗格隐藏网络 (Network) 网上邻居图标 (仅 Full)。
    11. 从左侧导航窗格隐藏小房子主页与用户个人主文件夹，直达此电脑 (仅 Full)。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (100% 只读诊断受控属性对比，零写入安全退出)

.PARAMETER Profile
    加固预设:
    - Full    : 个人黄金深度基线 (默认，极致性能与全域深度加固)
    - General : 通用稳健基线 (保守兼容，跳过卸载 OneDrive 与隐藏侧边栏快捷导航)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\scripts\windows\shell.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\scripts\windows\shell.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\shell.ps1 -Yes
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
        Id      = "explorer-launch-to-this-pc"
        Name    = "资源管理器默认打开此电脑 (LaunchTo = 1)"
        Profile = "General"
        Purpose = "按 Win+E 打开文件资源管理器时，默认直达磁盘驱动器根大盘，跳过快速访问卡片"
        Impact  = "打开资源管理器不再自动呈现频繁访问的常用文件夹与最近文件列表"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "LaunchTo"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "LaunchTo" 1
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-show-file-extensions"
        Name    = "全景透传显示文件扩展名 (HideFileExt = 0)"
        Profile = "General"
        Purpose = "始终透传呈现 .ps1, .exe, .sh, .txt 等所有真实文件后缀名，避免伪装双扩展名欺骗"
        Impact  = "重命名文件时必须保留原后缀名，若误删后缀可能导致双击无法自动识别关联程序"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" 0
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-show-hidden-files"
        Name    = "显示点开头与隐藏配置文件 (Hidden = 1)"
        Profile = "General"
        Purpose = "直接在资源管理器中半透明呈现 .git, .config, .vscode 等隐藏开发配置文件"
        Impact  = "普通系统文件夹下会看到半透明的隐藏系统属性文件（如 desktop.ini），请勿误删"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Hidden"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Hidden" 1
        }
    },
    [PSCustomObject]@{
        Id      = "taskbar-disable-widgets-icon"
        Name    = "任务栏小组件资讯流图标剥离 (TaskbarDa = 0)"
        Profile = "General"
        Purpose = "移除任务栏左侧天气温度与八卦新闻流小组件悬浮图标，释放桌面注意力"
        Impact  = "任务栏左侧将不再常驻天气与温度提示，鼠标悬停不再弹出新闻画板"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 0
        }
    },
    [PSCustomObject]@{
        Id      = "taskbar-disable-chat-icon"
        Name    = "任务栏 Teams 聊天图标剥离 (TaskbarMn = 0)"
        Profile = "General"
        Purpose = "从任务栏剥离内置的个人版 Microsoft Teams 聊天快速图标"
        Impact  = "任务栏快捷托盘不再显示个人 Teams 聊天入口（企业版 Teams 独立客户端完全不受影响）"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn" 0
        }
    },
    [PSCustomObject]@{
        Id      = "taskbar-disable-dsh-policy"
        Name    = "新闻资讯流组策略全局阻断 (AllowNewsAndInterests = 0)"
        Profile = "General"
        Purpose = "从组策略层彻底切断新闻与兴趣资讯流后台刷新通道，杜绝开机静默消耗网络"
        Impact  = "系统中所有本地账户均无法重新开启任务栏小组件新闻流"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
        }
    },
    [PSCustomObject]@{
        Id      = "accessibility-disable-sticky-keys"
        Name    = "粘滞键连按 5 次 Shift 快捷键劫持禁用 (StickyKeys Flags = 506)"
        Profile = "General"
        Purpose = "彻底消除在游戏连招或代码编写时连续敲击 5 次 Shift 触发全屏弹出的粘滞键中断对话框"
        Impact  = "依赖连按 Shift 锁定组合键的行动不便人士将无法通过快捷键呼出辅助功能"
        Check   = {
            $val = Get-RegVal "HKCU:\Control Panel\Accessibility\StickyKeys" "Flags"
            return @{ Actual = $val; Expected = "506"; IsCompliant = ($val -eq "506") }
        }
        Apply   = {
            $key = "HKCU:\Control Panel\Accessibility\StickyKeys"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "Flags" -Type String -Value "506" -Force
        }
    },
    [PSCustomObject]@{
        Id      = "accessibility-disable-toggle-keys"
        Name    = "切换键长按 5 秒 NumLock 快捷键劫持禁用 (ToggleKeys Flags = 58)"
        Profile = "General"
        Purpose = "关闭长按 NumLock 键 5 秒弹出的切换键提示音劫持对话框"
        Impact  = "长按 NumLock 不再发出系统滴滴蜂鸣提示音"
        Check   = {
            $val = Get-RegVal "HKCU:\Control Panel\Accessibility\ToggleKeys" "Flags"
            return @{ Actual = $val; Expected = "58"; IsCompliant = ($val -eq "58") }
        }
        Apply   = {
            $key = "HKCU:\Control Panel\Accessibility\ToggleKeys"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "Flags" -Type String -Value "58" -Force
        }
    },
    [PSCustomObject]@{
        Id      = "accessibility-disable-filter-keys"
        Name    = "筛选键长按 8 秒 Shift 快捷键劫持禁用 (FilterKeys Flags = 122)"
        Profile = "General"
        Purpose = "关闭长按右 Shift 键 8 秒弹出的筛选键键盘响应劫持对话框"
        Impact  = "长按右 Shift 键时不再自动忽略重复按键"
        Check   = {
            $val = Get-RegVal "HKCU:\Control Panel\Accessibility\Keyboard Response" "Flags"
            return @{ Actual = $val; Expected = "122"; IsCompliant = ($val -eq "122") }
        }
        Apply   = {
            $key = "HKCU:\Control Panel\Accessibility\Keyboard Response"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "Flags" -Type String -Value "122" -Force
        }
    },
    [PSCustomObject]@{
        Id      = "lockscreen-disable-spotlight-overlay"
        Name    = "锁屏 Windows 聚焦热点提示切断 (RotatingLockScreenOverlayEnabled = 0)"
        Profile = "General"
        Purpose = "锁屏界面切断热点推介与微软商业气泡，保持桌面壁纸纯净"
        Impact  = "锁屏时不再显示「喜欢当前图片吗？」或壁纸地理位置的交互热点小图标"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenOverlayEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenOverlayEnabled" 0
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338387Enabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "start-disable-track-docs"
        Name    = "开始菜单最近打开文档跟踪切断 (Start_TrackDocs = 0)"
        Profile = "General"
        Purpose = "收缩开始菜单下半部分推荐区块，关闭最近访问文档历史，保护隐私"
        Impact  = "开始菜单推荐区域不再列出刚刚编辑过的 Office 文档或下载的文件"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackDocs"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackDocs" 0
        }
    },
    [PSCustomObject]@{
        Id      = "start-disable-track-progs"
        Name    = "开始菜单常用程序列表跟踪切断 (Start_TrackProgs = 0)"
        Profile = "General"
        Purpose = "切断最常使用程序的自动统计与展示，保持开始菜单纯净"
        Impact  = "开始菜单应用列表顶部不再高亮展示「最常用」的应用程序分组"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackProgs"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackProgs" 0
        }
    },
    [PSCustomObject]@{
        Id      = "autoplay-disable-removable-media"
        Name    = "移动介质自动播放禁用 (AutoPlay DisableAutoplay = 1)"
        Profile = "General"
        Purpose = "插入 U 盘与移动硬盘时不再静默弹出自动执行对话框，防范 U 盘蠕虫自动运行"
        Impact  = "插入 U 盘后需要手动点击打开文件资源管理器查看文件，系统不会主动弹窗询问操作"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "DisableAutoplay"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "DisableAutoplay" 1
        }
    },
    [PSCustomObject]@{
        Id      = "audio-disable-volume-limiter"
        Name    = "耳机音量超出 37% 警告弹窗解除 (VolumeLimiter = 0)"
        Profile = "General"
        Purpose = "接入耳机或音箱拉大音量时不再阻断并弹出所谓高音量听力保护警告弹窗"
        Impact  = "在接大功率高灵敏度耳机时，调大系统音量时系统不再保护性强制截断，需用户自行留心音量大小"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Audio" "VolumeLimiter"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\Audio" "VolumeLimiter" 0
        }
    },
    [PSCustomObject]@{
        Id      = "onedrive-complete-shredding"
        Name    = "OneDrive 客户端物理卸载与侧边栏剥离"
        Profile = "Full"
        Purpose = "卸载并组策略阻断 OneDrive 同步引擎，拔除资源管理器左侧侧边栏图标（若使用个人网盘请选 General）"
        Impact  = "电脑上的个人 OneDrive 文件夹将停止云端同步；若依赖微软官方网盘备份桌面和文档的用户请勿在 Full 模式下启用本项"
        Check   = {
            $p = Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue
            $exe1 = Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
            $exe2 = Test-Path "C:\Program Files\Microsoft OneDrive\OneDrive.exe"
            $clsidPaths = @(
                "HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                "HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
            )
            $isPinned = $false
            foreach ($cp in $clsidPaths) {
                if (Test-Path $cp) {
                    $v = (Get-ItemProperty -Path $cp -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
                    if ($null -ne $v -and [int]$v -ne 0) { $isPinned = $true; break }
                }
            }
            $gpoOk = Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1
            $isPass = ($null -eq $p -and -not $exe1 -and -not $exe2 -and (-not $isPinned) -and $gpoOk)
            return @{ Actual = if ($isPass) { "已物理卸载且未驻留" } else { "未完全卸载/已驻留" }; Expected = "OneDrive=Absent, Pinned=0, GPO=Disabled"; IsCompliant = $isPass }
        }
        Apply   = {
            Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
            $odSetup = "$env:LOCALAPPDATA\Microsoft\OneDrive\Update\OneDriveSetup.exe"
            if (-not (Test-Path $odSetup)) { $odSetup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe" }
            if (-not (Test-Path $odSetup)) { $odSetup = "$env:SystemRoot\System32\OneDriveSetup.exe" }
            if (Test-Path $odSetup) {
                Start-Process $odSetup -ArgumentList "/uninstall" -Wait -NoNewWindow
            }
            Start-Sleep -Milliseconds 500
            Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue

            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1

            $clsidPaths = @(
                "HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                "HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
            )
            foreach ($cp in $clsidPaths) {
                if (Test-Path $cp) {
                    Set-ItemProperty -Path $cp -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
                }
            }

            Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path "HKCU:\Environment" -Name "OneDrive" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path "HKCU:\Environment" -Name "OneDriveCommercial" -Force -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable("OneDrive", $null, "User")
            [Environment]::SetEnvironmentVariable("OneDriveCommercial", $null, "User")
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-hide-gallery-node"
        Name    = "资源管理器图库 (Gallery) 侧边栏节点剥离"
        Profile = "Full"
        Purpose = "从文件资源管理器侧边栏抹除 Win11 图库 (Gallery) 树节点，消除静默图片与视频索引扫描"
        Impact  = "左侧导航栏不再显示图库大图标，需查看相册可通过此电脑进入特定磁盘文件夹"
        Check   = {
            $galleryClsid = "{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
            $clsidPath = "HKCU:\Software\Classes\CLSID\$galleryClsid"
            $pinnedVal = if (Test-Path $clsidPath) {
                (Get-ItemProperty -Path $clsidPath -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
            } else { 0 }
            $desktop = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$galleryClsid"
            $isPass = ($pinnedVal -eq 0 -and -not $desktop)
            return @{ Actual = if ($isPass) { "已剥离 (Pinned=0)" } else { "未剥离/已驻留" }; Expected = "Pinned=0, DesktopNameSpace=Absent"; IsCompliant = $isPass }
        }
        Apply   = {
            $galleryClsid = "{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
            $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$galleryClsid"
            if (Test-Path $hklmPath) { Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction SilentlyContinue }

            $hkcuClsid = "HKCU:\Software\Classes\CLSID\$galleryClsid"
            Ensure-RegKey $hkcuClsid
            Set-ItemProperty -Path $hkcuClsid -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-hide-network-neighborhood"
        Name    = "资源管理器左侧网上邻居图标隐藏 (Network Pinned = 0)"
        Profile = "Full"
        Purpose = "从文件资源管理器左侧侧边栏拔除网上邻居图标，消除局域网节点背景广播发现与延迟"
        Impact  = "左侧无法直接点击进入「网络」，但通过在地址栏输入 \\IP 访问内网共享完全正常不受影响"
        Check   = {
            $netGuid = "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"
            $hklmNet = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$netGuid"
            $hkcuNet = "HKCU:\Software\Classes\CLSID\$netGuid"
            $hkcuPinned = if (Test-Path $hkcuNet) {
                (Get-ItemProperty -Path $hkcuNet -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
            } else { $null }
            $isPass = (-not $hklmNet -and ($hkcuPinned -eq 0))
            return @{ Actual = if ($isPass) { "已隐藏" } else { "未隐藏" }; Expected = "Pinned=0, DesktopNameSpace=Absent"; IsCompliant = $isPass }
        }
        Apply   = {
            $netGuid = "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"
            $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$netGuid"
            if (Test-Path $hklmPath) { Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction SilentlyContinue }

            $hkcuNet = "HKCU:\Software\Classes\CLSID\$netGuid"
            Ensure-RegKey $hkcuNet
            Set-ItemProperty -Path $hkcuNet -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-hide-home-userprofile"
        Name    = "资源管理器主页 (Home) 与个人主文件夹隐藏"
        Profile = "Full"
        Purpose = "从资源管理器侧边栏拔除多余的 Home 小房子与用户名文件夹，只保留此电脑直达大盘，视觉极简"
        Impact  = "左侧导航窗格不再出现当前 Windows 用户名命名的快捷跳转节点"
        Check   = {
            $homeGuid = "{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
            $userGuid = "{59031a47-3f72-44a7-89c5-5595fe6b30ee}"
            $hklmHome = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$homeGuid"
            $hklmUser = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$userGuid"
            $hkcuHome = "HKCU:\Software\Classes\CLSID\$homeGuid"
            $hkcuHomePinned = if (Test-Path $hkcuHome) {
                (Get-ItemProperty -Path $hkcuHome -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
            } else { $null }
            $isPass = (-not $hklmHome -and -not $hklmUser -and ($hkcuHomePinned -eq 0))
            return @{ Actual = if ($isPass) { "已隐藏" } else { "未隐藏" }; Expected = "Home=0, UserProfile=0"; IsCompliant = $isPass }
        }
        Apply   = {
            $homeGuid = "{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
            $userGuid = "{59031a47-3f72-44a7-89c5-5595fe6b30ee}"
            foreach ($g in @($homeGuid, $userGuid)) {
                $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$g"
                if (Test-Path $hklmPath) { Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction SilentlyContinue }

                $hkcuPath = "HKCU:\Software\Classes\CLSID\$g"
                Ensure-RegKey $hkcuPath
                Set-ItemProperty -Path $hkcuPath -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force
            }
        }
    }
)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  交互体验与系统外壳视觉裁剪巡检 (pwsh 7+)" -ForegroundColor Cyan
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

Write-Host "`n📊 [巡检看板] 外壳交互原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 交互体验与系统外壳视觉基线全部合规，无需调整。`n" -ForegroundColor Green
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

    $gateInput = (Read-Host "`n确认对齐上述 $driftCount 项外壳视觉加固基线？[Y] 确认执行 / [N] 跳过本模块 / [Q] 退出 (默认 Y)").Trim()
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
Write-Host "`n🚀 正在单向对齐系统外壳视觉基线..." -ForegroundColor Cyan
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
Write-Host ("  ✅ [外壳加固完成] 成功对齐 {0} / {1} 项基线配置 (预设: {2})" -f $appliedCount, $driftCount, $Profile) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
