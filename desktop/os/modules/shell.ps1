#requires -Version 7.0
<#
.SYNOPSIS
    交互体验与系统外壳视觉裁剪基线

.DESCRIPTION
    Windows 11 外壳交互纯净化、小组件切断、任务栏轻量化与资源管理器极简基准模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 资源管理器默认打开“此电脑”，全景显示已知文件扩展名、隐藏文件与完整物理路径。
    3. 恢复 Windows 10 经典完整右键上下文菜单并极净化桌面空白处右键项，新建快捷方式免除「- 快捷方式」文本后缀。
    4. 剥离任务栏小组件 (Widgets) 资讯流、Teams 聊天、任务视图与 Copilot 图标，系统时钟显示秒数。
    5. 资源管理器切断服务商横幅广告通知，切断快速访问常用文件夹与最近文件记录。
    6. 禁用连按 5 次 Shift 触发粘滞键与筛选键劫持，关闭鼠标指针加速度并锁定 1:1 纯线性位移。
    7. 将当前聚焦背景改为静态图片并隐藏遗留的「了解此图片」桌面图标，跳过锁屏壁纸画幅直达登录框，切断锁屏热点建议与开始菜单推荐项目。
    8. 禁用 USB 移动介质自动播放 (AutoPlay) 阻断蠕虫自启传播。
    9. 解除耳机音量 37% 限制警告弹窗 (VolumeLimiter)。
    10. 卸载并策略阻断 OneDrive，剥离资源管理器侧边栏驻留。
    11. 剥离资源管理器图库 (Gallery) 侧边栏树节点驻留。
    12. 从左侧导航窗格隐藏网络 (Network) 网上邻居图标。
    13. 从左侧导航窗格隐藏小房子主页与用户个人主文件夹，直达此电脑。
    14. 用户主目录媒体与遗留已知文件夹沙盒化受保护隐藏 (Searches/Links/Contacts 等 +h +s)。
    15. 开始菜单辅助功能目录及其快捷方式沙盒化受保护隐藏 (Accessibility +h +s)。
    16. 开始菜单冗余维护目录与快捷方式沙盒化受保护隐藏 (Weasel/Office 工具/文件资源管理器/Steam 客服/7-Zip 帮助/Git CMD/Git GUI +h +s)。
    17. 维护原生 US 键盘输入配置，不添加系统自带输入法。
    18. 固化短时间与长时间为标准 24 小时制 (HH:mm / HH:mm:ss)。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (只读诊断受控属性对比，零写入安全退出)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\desktop\os\modules\shell.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\desktop\os\modules\shell.ps1

    # 无交互一键全量对齐
    pwsh -File .\desktop\os\modules\shell.ps1 -Yes
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

$OneDriveUninstallKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
    'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe'
)
$OneDriveRoots = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive'),
    (Join-Path $env:ProgramFiles 'Microsoft OneDrive'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive')
) | Select-Object -Unique
$OneDriveNamespaceKeys = @(
    'HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
    'HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
    'HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
)

function Get-OneDriveInventory {
    $registrations = @($OneDriveUninstallKeys | Where-Object { Test-Path -LiteralPath $_ -ErrorAction Stop } | ForEach-Object {
        Get-ItemProperty -LiteralPath $_ -ErrorAction Stop
    })
    $candidates = @(
        (Join-Path $env:USERPROFILE 'OneDrive')
        if ($env:OneDrive) { $env:OneDrive }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and [IO.Path]::IsPathFullyQualified($_) } | Select-Object -Unique
    $emptyDirs = [System.Collections.Generic.List[string]]::new()
    $nonEmptyDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in $candidates) {
        if (Test-Path -LiteralPath $dir -PathType Container -ErrorAction Stop) {
            $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop | Where-Object { $_.Name -ne 'desktop.ini' })
            if ($items.Count -eq 0) {
                $emptyDirs.Add($dir)
            } else {
                $nonEmptyDirs.Add($dir)
            }
        }
    }
    return [pscustomobject]@{
        Registrations = $registrations
        Executables = @($OneDriveRoots | ForEach-Object { Join-Path $_ 'OneDrive.exe' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction Stop })
        Processes = @(Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'OneDrive')
        Pinned = @($OneDriveNamespaceKeys | Where-Object {
            $value = Get-RegVal $_ 'System.IsPinnedToNameSpaceTree'
            $value -notin @('<未配置>', '0')
        })
        EmptyDirs = @($emptyDirs)
        NonEmptyDirs = @($nonEmptyDirs)
    }
}

function Invoke-OneDriveRemoval {
    $inventory = Get-OneDriveInventory
    if ($inventory.Registrations.Count -gt 0 -or $inventory.Executables.Count -gt 0 -or $inventory.Processes.Count -gt 0) {
        if ($inventory.Registrations.Count -eq 0) { throw 'OneDrive 本体存在但没有卸载登记；未修改本体或同步数据。' }
        $commands = @($inventory.Registrations | ForEach-Object {
            $command = [string]$_.UninstallString
            if ($command -notmatch '^(?:"([^"\r\n]+\\OneDriveSetup\.exe)"|([^"\r\n]+?\\OneDriveSetup\.exe))\s+(/uninstall(?:\s+/allusers)?|/allusers\s+/uninstall)\s*$') {
                throw 'OneDrive 卸载登记格式不受支持；未执行卸载。'
            }
            $path = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            $arguments = $Matches[3]
            if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'OneDrive 卸载器路径不是绝对路径。' }
            $exe = [IO.Path]::GetFullPath($path)
            $systemInstallers = @((Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'), (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'))
            $owned = $exe -in $systemInstallers -or @($OneDriveRoots | Where-Object { $exe.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            if (-not $owned -or -not (Test-Path -LiteralPath $exe -PathType Leaf -ErrorAction Stop)) {
                throw 'OneDrive 登记的卸载器不在安装目录或文件缺失。'
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)CN=Microsoft (?:Corporation|Windows)(?:,|$)') {
                throw 'OneDrive 卸载器 Microsoft 签名校验失败。'
            }
            [pscustomobject]@{ Executable = $exe; Arguments = $arguments }
        } | Sort-Object Executable, Arguments -Unique)
        foreach ($command in $commands) {
            $process = Start-Process -FilePath $command.Executable -ArgumentList $command.Arguments -PassThru -ErrorAction Stop
            try {
                if (-not $process.WaitForExit(120000)) { throw 'OneDrive 卸载超过 120 秒；请等待卸载完成后重新巡检。' }
                if ($process.ExitCode -ne 0) { throw "OneDrive 卸载器失败 (退出码 $($process.ExitCode))。" }
            } finally { $process.Dispose() }
        }
        $after = Get-OneDriveInventory
        if ($after.Registrations.Count + $after.Executables.Count + $after.Processes.Count -gt 0) {
            throw 'OneDrive 卸载后本体、安装登记或进程仍存在；未报告完成。'
        }
        $inventory = $after
    }
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    foreach ($key in $inventory.Pinned) { Set-RegDword $key 'System.IsPinnedToNameSpaceTree' 0 }
    $emptyDirs = @(if ($inventory.EmptyDirs) { $inventory.EmptyDirs })
    foreach ($dir in $emptyDirs) {
        if (Test-Path -LiteralPath $dir -PathType Container -ErrorAction Stop) {
            $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop | Where-Object { $_.Name -ne 'desktop.ini' })
            if ($items.Count -gt 0) {
                throw "OneDrive 同步目录已检测到非空内容，已阻断删除保护数据：$dir"
            }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $dir -ErrorAction Stop) {
                throw "清理 OneDrive 空目录失败：$dir"
            }
        }
    }
    $after = Get-OneDriveInventory
    $afterEmptyDirs = @(if ($after.EmptyDirs) { $after.EmptyDirs })
    if ($after.Registrations.Count + $after.Executables.Count + $after.Processes.Count + $after.Pinned.Count + $afterEmptyDirs.Count -gt 0) {
        throw 'OneDrive 受控终态校验失败。'
    }
}

function Get-InputBaselineState {
    $languages = Get-WinUserLanguageList -ErrorAction Stop
    if ($null -eq $languages -or $languages.Count -eq 0) { throw '无法确认当前用户语言与输入法列表。' }
    foreach ($language in $languages) {
        if ($null -eq $language.LanguageTag -or $null -eq $language.InputMethodTips) { throw '用户语言属性无法确认。' }
    }
    $tips = @($languages | ForEach-Object { $_.InputMethodTips })
    return [pscustomobject]@{ Languages = $languages; HasUS = ($tips -contains '0409:00000409') }
}

function Get-DesktopBackgroundState {
    $wallpaper = Get-RegVal 'HKCU:\Control Panel\Desktop' 'WallPaper'
    $mode = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' 'BackgroundType'
    if ($mode -notin @('<未配置>', '0', '1', '2', '3')) { throw "无法确认桌面背景类型：$mode" }
    $spotlight = if ($mode -eq '<未配置>') {
        $wallpaper -match '(?i)[\\/]DesktopSpotlight[\\/]|[\\/]Web[\\/]Wallpaper[\\/]spotlight[\\/]'
    } else { $mode -eq '3' }
    $actual = if ($mode -eq '3') {
        'BackgroundType=3 (Windows聚焦)'
    } elseif ($spotlight) {
        "BackgroundType=$mode, Wallpaper=$wallpaper (聚焦缓存)"
    } else {
        "BackgroundType=$mode, Wallpaper=$wallpaper"
    }
    return @{ Actual = $actual; IsSpotlight = $spotlight }
}

function Set-DesktopWallpaper {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) { throw '静态壁纸文件缺失。' }
    if (-not ([System.Management.Automation.PSTypeName]'WallpaperHelper').Type) {
        $sig = @"
using System;
using System.Runtime.InteropServices;
public class WallpaperHelper {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
        Add-Type -TypeDefinition $sig -ErrorAction Stop
    }
    if ([WallpaperHelper]::SystemParametersInfo(0x0014, 0, $Path, 0x01 -bor 0x02) -eq 0) {
        throw "设置静态壁纸失败 (Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))。"
    }
}

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 目的与影响明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "explorer-launch-to-this-pc"
        Name    = "资源管理器默认打开此电脑 (LaunchTo = 1)"
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
        Id      = "explorer-launch-separate-process"
        Name    = "资源管理器独立进程模式开启 (SeparateProcess = 1)"
        Purpose = "开启「在单独的进程中打开文件夹窗口」，每个资源管理器窗口运行于独立进程，降低单个窗口卡死影响桌面宿主的概率"
        Impact  = "每个文件夹窗口占用约数十 MB 独立进程内存，显著提升系统外壳容灾防崩能力"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SeparateProcess"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SeparateProcess" 1
        }
    },
    [PSCustomObject]@{
        Id      = "window-disable-snap-assist"
        Name    = "窗口贴靠助手推荐窗口切断 (SnapAssist = 0)"
        Purpose = "窗口拖拽至屏幕边缘触发贴靠分屏时，不再强制弹窗推荐其余未分屏窗口，保持桌面极简专注"
        Impact  = "贴靠后屏幕另一侧不会自动展示候选窗口大图，需手动点击选择目标窗口"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapAssist"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapAssist" 0
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-cabinet-state-full-path"
        Name    = "资源管理器标题栏显示完整路径 (FullPath = 1)"
        Purpose = "在文件资源管理器顶部标题栏始终呈现当前文件夹完整路径，方便快速确认工作区层级"
        Impact  = "顶部标题栏文本变长，在多窗口窄屏并排时路径过长可能部分截断"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState" "FullPath"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState" "FullPath" 1
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-disable-sync-provider-notifications"
        Name    = "资源管理器同步服务商横幅广告切断 (ShowSyncProviderNotifications = 0)"
        Purpose = "切断文件资源管理器顶部可能弹出的 OneDrive 与 Microsoft 365 订阅促销与横幅广告推送"
        Impact  = "资源管理器顶部不再呈现云同步营销提示"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowSyncProviderNotifications"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowSyncProviderNotifications" 0
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-disable-shortcut-suffix"
        Name    = "新建快捷方式免除「- 快捷方式」后缀 (link = 00 00 00 00)"
        Purpose = "创建文件或程序快捷方式时直接继承源名称，不再自动追加「 - 快捷方式」文字后缀，消除手动重命名冗余"
        Impact  = "快捷方式与本体同名（文件扩展名仍为 .lnk），依赖左下角小箭头图标区分快捷方式与源文件"
        Check   = {
            $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
            $val = $null
            try {
                $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                if ($null -ne $item) { $val = $item.link }
            } catch {
                if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
            }
            $isZero = ($null -ne $val -and $val.Length -ge 4 -and $val[0] -eq 0 -and $val[1] -eq 0 -and $val[2] -eq 0 -and $val[3] -eq 0)
            $act = if ($isZero) { "00 00 00 00" } elseif ($null -ne $val) { ($val | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' } else { "<未配置>" }
            return @{ Actual = $act; Expected = "00 00 00 00"; IsCompliant = $isZero }
        }
        Apply   = {
            $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "link" -Type Binary -Value ([byte[]](0, 0, 0, 0)) -Force
            $written = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).link
            if ($null -eq $written -or $written.Length -lt 4 -or $written[0] -ne 0 -or $written[1] -ne 0 -or $written[2] -ne 0 -or $written[3] -ne 0) {
                throw "快捷方式后缀策略写入后校验失败：$key\link"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-disable-recent-frequent-recommendations"
        Name    = "快速访问常用文件夹与最近文件记录切断"
        Purpose = "切断资源管理器主页与快速访问对常用文件夹、最近打开文件及云端文件的自动收集与展示，保护隐私防窥探"
        Impact  = "文件资源管理器「主页」不再自动陈列常用目录与近期文档历史"
        Check   = {
            $exp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
            $frequent = Get-RegVal $exp "ShowFrequent"
            $recent = Get-RegVal $exp "ShowRecent"
            $cloud = Get-RegVal $exp "ShowCloudFilesInQuickAccess"
            $isPass = ($frequent -eq "0" -and $recent -eq "0" -and $cloud -eq "0")
            return @{
                Actual      = "Frequent=$frequent, Recent=$recent, Cloud=$cloud"
                Expected    = "Frequent=0, Recent=0, Cloud=0"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $exp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
            Set-RegDword $exp "ShowFrequent" 0
            Set-RegDword $exp "ShowRecent" 0
            Set-RegDword $exp "ShowCloudFilesInQuickAccess" 0
        }
    },
    [PSCustomObject]@{
        Id      = "taskbar-show-seconds-in-system-clock"
        Name    = "任务栏系统时钟显示秒数 (ShowSecondsInSystemClock = 1)"
        Purpose = "任务栏右下角系统时钟精确呈现时:分:秒，方便毫秒级排障、时间审计与工作节拍把控"
        Impact  = "任务栏时钟每秒刷新一次，对极低功耗待机设备略微增加极微小唤醒开销（正常使用可忽略）"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowSecondsInSystemClock"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowSecondsInSystemClock" 1
        }
    },
    [PSCustomObject]@{
        Id      = "taskbar-hide-task-view-button"
        Name    = "任务栏任务视图图标隐藏 (ShowTaskViewButton = 0)"
        Purpose = "从任务栏剥离常驻的任务视图图标，释放任务栏紧凑空间"
        Impact  = "任务栏不再显示多任务切换图标，多桌面切换可通过原生快捷键 Win+Tab 或 Win+Ctrl+左/右 调度"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton" 0
        }
    },
    [PSCustomObject]@{
        Id      = "taskbar-hide-copilot-button"
        Name    = "任务栏 Copilot 图标隐藏 (ShowCopilotButton = 0)"
        Purpose = "从任务栏剥离常驻的 Copilot AI 悬浮按钮，净化桌面任务栏空间"
        Impact  = "任务栏右侧或托盘旁不再显示 Copilot 入口图标"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0
        }
    },
    [PSCustomObject]@{
        Id      = "taskbar-disable-chat-icon"
        Name    = "任务栏 Teams 聊天图标剥离 (TaskbarMn = 0)"
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
        Name    = "任务栏小组件与新闻资讯流全局阻断 (AllowNewsAndInterests = 0)"
        Purpose = "从组策略层切断新闻资讯流后台通道并移除任务栏小组件悬浮图标，释放桌面注意力与网络带宽"
        Impact  = "任务栏左侧不再呈现小组件天气与温度提示，鼠标悬停不再弹出新闻画板，系统中所有本地账户均生效"
        Check   = {
            $dsh = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests"
            $da  = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa"
            $isPass = ($dsh -eq "0" -and $da -in @("0", "<未配置>"))
            return @{
                Actual      = "AllowNewsAndInterests=$dsh, TaskbarDa=$da"
                Expected    = "AllowNewsAndInterests=0, TaskbarDa=0 或 <未配置>"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
            $da = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa"
            if ($da -ne "0" -and $da -ne "<未配置>") {
                try {
                    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 0
                } catch [UnauthorizedAccessException] {
                    Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData "任务栏 TaskbarDa 受到系统 UCPD 内核防篡改保护；组策略已全局阻断小组件生效。"
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-classic-context-menu"
        Name    = "恢复经典完整右键上下文菜单 (InprocServer32 Override)"
        Purpose = "剥离 Windows 11 折叠式二级右键菜单，恢复 Windows 10 经典完整右键菜单，所有扩展菜单项一级直达"
        Impact  = "右键菜单回归传统紧凑样式，7-Zip、Git、VS Code 等第三方菜单项直接呈现，无需点击「显示更多选项」"
        Check   = {
            $clsid = "{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
            $keyPath = "HKCU:\Software\Classes\CLSID\$clsid\InprocServer32"
            $defaultVal = Get-RegVal $keyPath "(Default)"
            $isPass = ($defaultVal -eq "")
            return @{ Actual = if ($isPass) { "经典菜单 (Default=空串)" } else { "<未正确配置>" }; Expected = "经典菜单 (Default=空串)"; IsCompliant = $isPass }
        }
        Apply   = {
            $clsid = "{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
            $keyPath = "HKCU:\Software\Classes\CLSID\$clsid\InprocServer32"
            Ensure-RegKey $keyPath
            Set-ItemProperty -Path $keyPath -Name "(Default)" -Value "" -Force
            if ((Get-RegVal $keyPath "(Default)") -ne "") {
                throw "经典右键菜单策略写入后校验失败：$keyPath\(Default)"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "desktop-context-menu-clean"
        Name    = "桌面空白处右键菜单极简化修剪 (NvCpl / Display / Personalize / Spotlight)"
        Purpose = "清理桌面背景第三方显卡驱动 (NvCplDesktopContext) 及幻灯片 (DesktopSlideshow) 扩展，并在当前用户类 (HKCU) 屏蔽显示设置、个性化与聚焦切图动词"
        Impact  = "桌面右键菜单仅保留新建、刷新、查看、排序与终端等核心操作；系统 Display/Personalize 原生权限完好，仍可通过 Win+I 或设置中心正常进入"
        Check   = {
            $nvKey = "HKLM:\SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers\NvCplDesktopContext"
            $slideKey = "HKLM:\SOFTWARE\Classes\DesktopBackground\shellex\ContextMenuHandlers\DesktopSlideshow"
            $hasNv = Test-Path -LiteralPath $nvKey
            $hasSlide = Test-Path -LiteralPath $slideKey

            $verbs = @("Display", "Personalize", ".SpotlightNextImage", ".SpotlightLearnMore")
            $missingVerbs = @(foreach ($v in $verbs) {
                $p = "HKCU:\Software\Classes\DesktopBackground\Shell\$v"
                if ((Get-RegKind $p "ProgrammaticAccessOnly") -ne "String") { $v }
            })

            $isCompliant = (-not $hasNv) -and (-not $hasSlide) -and ($missingVerbs.Count -eq 0)
            $actual = if ($isCompliant) {
                "纯净化修剪 (NvCpl/Slide已移除, 4动词已屏蔽)"
            } else {
                $drift = @()
                if ($hasNv) { $drift += "NvCpl常驻" }
                if ($hasSlide) { $drift += "DesktopSlideshow常驻" }
                if ($missingVerbs.Count -gt 0) { $drift += "未屏蔽:($($missingVerbs -join ','))" }
                "存在偏离 ($($drift -join '; '))"
            }
            return @{ Actual = $actual; Expected = "纯净化修剪 (NvCpl/Slide已移除, 4动词已屏蔽)"; IsCompliant = $isCompliant }
        }
        Apply   = {
            $nvKey = "HKLM:\SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers\NvCplDesktopContext"
            if (Test-Path -LiteralPath $nvKey) {
                Remove-Item -LiteralPath $nvKey -Recurse -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $nvKey) { throw "清理 NvCplDesktopContext 失败：$nvKey" }
            }

            $slideKey = "HKLM:\SOFTWARE\Classes\DesktopBackground\shellex\ContextMenuHandlers\DesktopSlideshow"
            if (Test-Path -LiteralPath $slideKey) {
                Remove-Item -LiteralPath $slideKey -Recurse -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $slideKey) { throw "清理 DesktopSlideshow 失败：$slideKey" }
            }

            $verbs = @("Display", "Personalize", ".SpotlightNextImage", ".SpotlightLearnMore")
            foreach ($v in $verbs) {
                $p = "HKCU:\Software\Classes\DesktopBackground\Shell\$v"
                Ensure-RegKey $p
                Set-ItemProperty -Path $p -Name "ProgrammaticAccessOnly" -Type String -Value "" -Force -ErrorAction Stop
                if ((Get-RegKind $p "ProgrammaticAccessOnly") -ne "String") {
                    throw "写入 ProgrammaticAccessOnly 失败：$p"
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "accessibility-disable-sticky-keys"
        Name    = "粘滞键连按 5 次 Shift 快捷键劫持禁用 (StickyKeys Flags = 506)"
        Purpose = "关闭在游戏或代码编写时连续敲击 5 次 Shift 触发全屏弹出的粘滞键中断对话框"
        Impact  = "依赖连按 Shift 锁定组合键的行动不便人士将无法通过快捷键呼出辅助功能"
        Check   = {
            $val = Get-RegVal "HKCU:\Control Panel\Accessibility\StickyKeys" "Flags"
            return @{ Actual = $val; Expected = "506"; IsCompliant = ($val -eq "506") }
        }
        Apply   = {
            $key = "HKCU:\Control Panel\Accessibility\StickyKeys"
            Ensure-RegKey $key
            Set-ItemProperty -Path $key -Name "Flags" -Type String -Value "506" -Force
            if ((Get-RegVal $key "Flags") -ne "506") {
                throw "粘滞键策略写入后校验失败：$key\Flags"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "accessibility-disable-toggle-keys"
        Name    = "切换键长按 5 秒 NumLock 快捷键劫持禁用 (ToggleKeys Flags = 58)"
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
            if ((Get-RegVal $key "Flags") -ne "58") {
                throw "切换键策略写入后校验失败：$key\Flags"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "accessibility-disable-filter-keys"
        Name    = "筛选键长按 8 秒 Shift 快捷键劫持禁用 (FilterKeys Flags = 122)"
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
            if ((Get-RegVal $key "Flags") -ne "122") {
                throw "筛选键策略写入后校验失败：$key\Flags"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "mouse-disable-pointer-precision-acceleration"
        Name    = "鼠标指针加速禁用与 1:1 纯线性位移锁定 (MouseSpeed = 0)"
        Purpose = "关闭系统「提高指针精确度」非线性曲线加速，将灵敏度锁定在 6/11 标准刻度 (10)，保持光标位移线性映射"
        Impact  = "消除光标非线性插值漂移，为高精度操控与肌肉记忆打底；习惯了加速插值的用户可能需要短暂适应"
        Check   = {
            $p = "HKCU:\Control Panel\Mouse"
            $speed = Get-RegVal $p "MouseSpeed"
            $t1 = Get-RegVal $p "MouseThreshold1"
            $t2 = Get-RegVal $p "MouseThreshold2"
            $sens = Get-RegVal $p "MouseSensitivity"
            $isPass = ($speed -eq "0" -and $t1 -eq "0" -and $t2 -eq "0" -and $sens -eq "10")
            return @{
                Actual      = "Speed=$speed, T1=$t1, T2=$t2, Sens=$sens"
                Expected    = "Speed=0, T1=0, T2=0, Sens=10"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $p = "HKCU:\Control Panel\Mouse"
            Ensure-RegKey $p
            Set-ItemProperty -Path $p -Name "MouseSpeed" -Type String -Value "0" -Force
            Set-ItemProperty -Path $p -Name "MouseThreshold1" -Type String -Value "0" -Force
            Set-ItemProperty -Path $p -Name "MouseThreshold2" -Type String -Value "0" -Force
            Set-ItemProperty -Path $p -Name "MouseSensitivity" -Type String -Value "10" -Force
            if ((Get-RegVal $p "MouseSpeed") -ne "0" -or
                (Get-RegVal $p "MouseThreshold1") -ne "0" -or
                (Get-RegVal $p "MouseThreshold2") -ne "0" -or
                (Get-RegVal $p "MouseSensitivity") -ne "10") {
                throw "鼠标线性位移策略写入后校验失败：$p"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "desktop-wallpaper-spotlight-decoupling"
        Name    = "当前桌面 Windows 聚焦背景改为静态图片"
        Purpose = "将当前聚焦背景切换为本地静态图片，不修改主题文件或删除图片缓存"
        Impact  = "当前聚焦背景替换为 Windows 默认图片；个人静态图片保持不变。Pro 不支持禁用聚焦集合策略，用户仍可重新启用聚焦"
        Check   = {
            $state = Get-DesktopBackgroundState
            return @{ Actual = $state.Actual; Expected = '当前非聚焦背景'; IsCompliant = (-not $state.IsSpotlight) }
        }
        Apply   = {
            $state = Get-DesktopBackgroundState
            if (-not $state.IsSpotlight) { return }
            $defaultWp = Join-Path $env:SystemRoot 'Web\Wallpaper\Windows\img0.jpg'
            Set-DesktopWallpaper $defaultWp
            Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' 'BackgroundType' 0
            if ((Get-DesktopBackgroundState).IsSpotlight) { throw '桌面背景仍为聚焦配置。' }
        }
    },
    [PSCustomObject]@{
        Id      = "desktop-system-icons-hidden"
        Name    = "桌面出厂系统图标与聚焦入口隐藏 (HideDesktopIcons = 1)"
        Purpose = "将 Windows 11 出厂预设的用户主文件夹、此电脑、控制面板、网络、库以及聚焦残留「了解此图片」标记为隐藏，保持桌面仅呈现用户个人文件"
        Impact  = "桌面不再显示主文件夹 (当前用户名)、此电脑、控制面板、网络、库以及「了解此图片」图标；不删除 NameSpace 注册项或文件本身。需刷新桌面或重启资源管理器后呈现"
        Check   = {
            $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
            $targetClsids = @(
                "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}", # 聚焦「了解此图片」
                "{59031a47-3f72-44a7-89c5-5595fe6b30ee}", # 用户个人主文件夹
                "{20D04FE0-3AEA-1069-A2D8-08002B30309D}", # 此电脑
                "{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}", # 控制面板
                "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}", # 网络
                "{031E4825-7B94-4dc3-B131-E946B44C8DD5}"  # 库
            )
            $unhidden = [System.Collections.Generic.List[string]]::new()
            foreach ($clsid in $targetClsids) {
                $val = Get-RegVal $path $clsid
                $kind = Get-RegKind $path $clsid
                if ($val -notin @("<未配置>", "0", "1")) { throw "无法确认桌面图标隐藏状态：$clsid = $val" }
                if ($val -ne "1" -or $kind -ne "DWord") {
                    $unhidden.Add("$clsid ($val, $kind)")
                }
            }
            $isPass = ($unhidden.Count -eq 0)
            return @{
                Actual      = if ($isPass) { "全部已隐藏 (6项 DWord=1)" } else { "未隐藏: $($unhidden.Count) 项" }
                Expected    = "全部已隐藏 (6项 DWord=1)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
            $targetClsids = @(
                "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}", # 聚焦「了解此图片」
                "{59031a47-3f72-44a7-89c5-5595fe6b30ee}", # 用户个人主文件夹
                "{20D04FE0-3AEA-1069-A2D8-08002B30309D}", # 此电脑
                "{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}", # 控制面板
                "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}", # 网络
                "{031E4825-7B94-4dc3-B131-E946B44C8DD5}"  # 库
            )
            foreach ($clsid in $targetClsids) {
                Set-RegDword $path $clsid 1
            }
        }
    },
    [PSCustomObject]@{
        Id      = "lockscreen-bypass-to-pin-entry"
        Name    = "开机与唤醒跳过锁屏壁纸直达登录框并切断未解锁硬件调用 (NoLockScreen = 1)"
        Purpose = "开机或按 Win+L 锁屏后，跳过冗余的向上滑动壁纸过渡层，直接呼出密码或 PIN 码键入界面；硬性阻断在未解锁状态下直接调用物理摄像头 (NoLockScreenCamera=1)，并切断后台相册幻灯片扫描轮播 (NoLockScreenSlideshow=1)"
        Impact  = "轻触任意键直接进入凭据输入界面；关闭锁屏界面相机快捷入口，消除闲置时的相册索引与磁盘 I/O 唤醒开销"
        Check   = {
            $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
            $nls = Get-RegVal $pol "NoLockScreen"
            $cam = Get-RegVal $pol "NoLockScreenCamera"
            $slide = Get-RegVal $pol "NoLockScreenSlideshow"
            $isPass = ($nls -eq "1" -and $cam -eq "1" -and $slide -eq "1")
            return @{
                Actual      = "NoLockScreen=$nls, NoCamera=$cam, NoSlideshow=$slide"
                Expected    = "NoLockScreen=1, NoCamera=1, NoSlideshow=1"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
            Set-RegDword $pol "NoLockScreen" 1
            Set-RegDword $pol "NoLockScreenCamera" 1
            Set-RegDword $pol "NoLockScreenSlideshow" 1
        }
    },
    [PSCustomObject]@{
        Id      = "lockscreen-disable-spotlight-overlay"
        Name    = "锁屏 Windows 聚焦轮换与热点提示切断 (RotatingLockScreen = 0)"
        Purpose = "关闭锁屏界面后台静默轮换必应聚焦壁纸通道，切断锁屏交互热点推介与商业气泡，保持桌面壁纸纯净"
        Impact  = "锁屏时不再从必应下载动态新图片，不再显示「喜欢当前图片吗？」或壁纸地理位置的交互热点小图标"
        Check   = {
            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            $r1 = Get-RegVal $cdm "RotatingLockScreenEnabled"
            $r2 = Get-RegVal $cdm "RotatingLockScreenOverlayEnabled"
            $r3 = Get-RegVal $cdm "SubscribedContent-338387Enabled"
            $isPass = ($r1 -eq "0" -and $r2 -eq "0" -and $r3 -eq "0")
            return @{
                Actual      = "RotatingEnabled=$r1, OverlayEnabled=$r2, Subscribed338387=$r3"
                Expected    = "RotatingEnabled=0, OverlayEnabled=0, Subscribed338387=0"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            Set-RegDword $cdm "RotatingLockScreenEnabled" 0
            Set-RegDword $cdm "RotatingLockScreenOverlayEnabled" 0
            Set-RegDword $cdm "SubscribedContent-338387Enabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "start-disable-track-docs"
        Name    = "开始菜单最近打开文档跟踪切断 (Start_TrackDocs = 0)"
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
        Id      = "start-layout-more-pins"
        Name    = "开始菜单布局收缩推荐并展示更多固定项 (Start_Layout = 1)"
        Purpose = "将 Windows 11 开始菜单布局调整为「更多固定项」，大幅压缩下半部分无用的推荐项目区域，增加应用固定格位"
        Impact  = "开始菜单顶部展示更多图标，下半部「推荐的项目」高度压缩至仅留单行"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_Layout"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_Layout" 1
        }
    },
    [PSCustomObject]@{
        Id      = "start-disable-track-progs"
        Name    = "开始菜单常用程序列表跟踪切断 (Start_TrackProgs = 0)"
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
        Id      = "start-disable-account-notifications"
        Name    = "开始菜单账户通知徽章与推销红点切断 (Start_AccountNotifications = 0)"
        Purpose = "切断开始菜单左下角用户头像上弹出的微软账户设置、OneDrive 备份与 Microsoft 365 营销红点气泡"
        Impact  = "用户头像不再展示推销性质的提示小圆点，保持开始菜单纯净无干扰"
        Check   = {
            $val = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_AccountNotifications"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_AccountNotifications" 0
        }
    },
    [PSCustomObject]@{
        Id      = "start-hide-recently-added-apps"
        Name    = "开始菜单最近添加应用列表隐藏 (HideRecentlyAddedApps = 1)"
        Purpose = "组策略级移除开始菜单所有应用列表顶部的「最近添加」临时分组，消除装机与工具升级后的列表抖动"
        Impact  = "新安装的应用程序直接按字母排序并入应用列表，不再在顶栏生成额外的高亮推介区域"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecentlyAddedApps"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecentlyAddedApps" 1
        }
    },
    [PSCustomObject]@{
        Id      = "start-disable-recommended-sites-and-section"
        Name    = "开始菜单推荐区个性化网页与云端推荐阻断 (HideRecommendedPersonalizedSites = 1)"
        Purpose = "组策略切断微软依据 Edge 浏览记录向开始菜单推荐区注入的推广网址，协同关闭 Iris 云端推荐引擎与抹除推荐区块"
        Impact  = "开始菜单切断个性化商业网页分发通道，消除云端推荐卡片"
        Check   = {
            $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
            $adv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            $pSites = Get-RegVal $pol "HideRecommendedPersonalizedSites"
            $pSec = Get-RegVal $pol "HideRecommendedSection"
            $iris = Get-RegVal $adv "Start_IrisRecommendations"
            $isPass = ($pSites -eq "1" -and $pSec -eq "1" -and $iris -eq "0")
            return @{
                Actual      = "Sites=$pSites, Section=$pSec, Iris=$iris"
                Expected    = "Sites=1, Section=1, Iris=0"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
            $adv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-RegDword $pol "HideRecommendedPersonalizedSites" 1
            Set-RegDword $pol "HideRecommendedSection" 1
            Set-RegDword $adv "Start_IrisRecommendations" 0
        }
    },
    [PSCustomObject]@{
        Id      = "start-accessibility-shortcuts-hidden"
        Name    = "开始菜单辅助功能快捷方式沙盒化受保护隐藏 (Accessibility +h +s)"
        Purpose = "将开始菜单当前用户与公用目录下的辅助功能 (Accessibility) 文件夹及其快捷方式标记为 Hidden + System，从开始菜单所有应用列表中消除该目录"
        Impact  = "开始菜单所有应用列表中不再呈现「辅助功能」分组；不删除快捷方式或系统二进制，系统全局快捷键 (如 Win+Ctrl+Enter、Win++) 与设置面板辅助功能不受影响"
        Check   = {
            $targetDirs = @(
                (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Accessibility'),
                (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Accessibility')
            )
            $unhidden = [System.Collections.Generic.List[string]]::new()
            foreach ($dir in $targetDirs) {
                if (Test-Path -LiteralPath $dir) {
                    $dirItem = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
                    $isDirHidden = ($dirItem.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
                                    $dirItem.Attributes.HasFlag([System.IO.FileAttributes]::System))
                    if (-not $isDirHidden) { $unhidden.Add($dirItem.Name) }

                    foreach ($child in Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction Stop) {
                        $isChildHidden = ($child.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
                                          $child.Attributes.HasFlag([System.IO.FileAttributes]::System))
                        if (-not $isChildHidden) { $unhidden.Add($child.Name) }
                    }
                }
            }
            $isPass = ($unhidden.Count -eq 0)
            return @{
                Actual      = if ($isPass) { "全部已受保护隐藏 (+h +s)" } else { "未受保护隐藏: $($unhidden -join ', ')" }
                Expected    = "全部已受保护隐藏 (+h +s)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $targetDirs = @(
                (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Accessibility'),
                (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Accessibility')
            )

            foreach ($dir in $targetDirs) {
                if (Test-Path -LiteralPath $dir) {
                    foreach ($child in Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction Stop) {
                        $newChildAttrs = $child.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
                        [System.IO.File]::SetAttributes($child.FullName, $newChildAttrs)
                        $afterChild = Get-Item -LiteralPath $child.FullName -Force -ErrorAction Stop
                        if (-not ($afterChild.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and $afterChild.Attributes.HasFlag([System.IO.FileAttributes]::System))) {
                            throw "辅助功能项隐藏属性设置失败：$($child.FullName)"
                        }
                    }

                    $dirItem = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
                    $newDirAttrs = $dirItem.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
                    [System.IO.File]::SetAttributes($dir, $newDirAttrs)
                    $afterDir = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
                    if (-not ($afterDir.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and $afterDir.Attributes.HasFlag([System.IO.FileAttributes]::System))) {
                        throw "辅助功能目录隐藏属性设置失败：$dir"
                    }
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "start-redundant-shortcuts-hidden"
        Name    = "开始菜单冗余维护目录与快捷方式隐藏 (Rime/Office/Explorer/Steam/7-Zip/Git +h +s)"
        Purpose = "将原厂小狼毫维护目录、Office 工具目录、文件资源管理器及 Steam 客服、7-Zip 帮助、Git CMD、Git GUI 快捷方式标记为 Hidden + System，减少开始菜单应用列表入口"
        Impact  = "保留管理工具快捷方式 (Administrative Tools)，不删除快捷方式或程序；小狼毫仍可通过托盘管理，文件资源管理器仍可通过 Win+E 打开。按原厂精确名称识别小狼毫英文、简体及繁体目录；Office 工具和 Steam 客服名称受显示／客户端语言影响，未命中则跳过。无受控目标单独呈现，属性合规不代证开始菜单实际刷新"
        Check   = {
            $programsRoots = @(
                (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
                (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
            )
            $targetDirs = @("Weasel", "小狼毫输入法", "小狼毫輸入法", "Microsoft Office 工具")
            $targetFiles = @(
                "File Explorer.lnk",
                "Steam\Steam Support Center.url",
                "Scoop Apps\7-Zip\7-Zip Help.lnk",
                "Scoop Apps\Git\Git CMD.lnk",
                "Scoop Apps\Git\Git GUI.lnk"
            )

            $matched = 0
            $unhidden = [System.Collections.Generic.List[string]]::new()

            foreach ($root in $programsRoots) {
                foreach ($dirName in $targetDirs) {
                    $dirPath = Join-Path $root $dirName
                    if (Test-Path -LiteralPath $dirPath -ErrorAction Stop) {
                        $dirItem = Get-Item -LiteralPath $dirPath -Force -ErrorAction Stop
                        $matched++
                        $isDirHidden = ($dirItem.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
                                        $dirItem.Attributes.HasFlag([System.IO.FileAttributes]::System))
                        if (-not $isDirHidden) { $unhidden.Add($dirItem.Name) }

                        foreach ($child in Get-ChildItem -LiteralPath $dirPath -Recurse -Force -ErrorAction Stop) {
                            $matched++
                            $isChildHidden = ($child.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
                                              $child.Attributes.HasFlag([System.IO.FileAttributes]::System))
                            if (-not $isChildHidden) { $unhidden.Add("$dirName\$($child.Name)") }
                        }
                    }
                }

                foreach ($fileName in $targetFiles) {
                    $filePath = Join-Path $root $fileName
                    if (Test-Path -LiteralPath $filePath -ErrorAction Stop) {
                        $fileItem = Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
                        $matched++
                        $isFileHidden = ($fileItem.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
                                         $fileItem.Attributes.HasFlag([System.IO.FileAttributes]::System))
                        if (-not $isFileHidden) { $unhidden.Add($fileName) }
                    }
                }
            }

            $isPass = ($unhidden.Count -eq 0)
            $expected = if ($matched -eq 0) { "无受控目标" } else { "已检测 $matched 项均具备 Hidden/System (+h +s)" }
            return @{
                Actual      = if ($isPass) { $expected } else { "未受保护隐藏: $($unhidden -join ', ')" }
                Expected    = $expected
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $programsRoots = @(
                (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
                (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
            )
            $targetDirs = @("Weasel", "小狼毫输入法", "小狼毫輸入法", "Microsoft Office 工具")
            $targetFiles = @(
                "File Explorer.lnk",
                "Steam\Steam Support Center.url",
                "Scoop Apps\7-Zip\7-Zip Help.lnk",
                "Scoop Apps\Git\Git CMD.lnk",
                "Scoop Apps\Git\Git GUI.lnk"
            )

            foreach ($root in $programsRoots) {
                foreach ($dirName in $targetDirs) {
                    $dirPath = Join-Path $root $dirName
                    if (Test-Path -LiteralPath $dirPath -ErrorAction Stop) {
                        foreach ($child in Get-ChildItem -LiteralPath $dirPath -Recurse -Force -ErrorAction Stop) {
                            $newChildAttrs = $child.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
                            if ($child.Attributes -eq $newChildAttrs) { continue }
                            $child.Attributes = $newChildAttrs
                            $afterChild = Get-Item -LiteralPath $child.FullName -Force -ErrorAction Stop
                            if (-not ($afterChild.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and $afterChild.Attributes.HasFlag([System.IO.FileAttributes]::System))) {
                                throw "项隐藏属性设置失败：$($child.FullName)"
                            }
                        }

                        $dirItem = Get-Item -LiteralPath $dirPath -Force -ErrorAction Stop
                        $newDirAttrs = $dirItem.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
                        if ($dirItem.Attributes -eq $newDirAttrs) { continue }
                        $dirItem.Attributes = $newDirAttrs
                        $afterDir = Get-Item -LiteralPath $dirPath -Force -ErrorAction Stop
                        if (-not ($afterDir.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and $afterDir.Attributes.HasFlag([System.IO.FileAttributes]::System))) {
                            throw "目录隐藏属性设置失败：$dirPath"
                        }
                    }
                }

                foreach ($fileName in $targetFiles) {
                    $filePath = Join-Path $root $fileName
                    if (Test-Path -LiteralPath $filePath -ErrorAction Stop) {
                        $fileItem = Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
                        $newFileAttrs = $fileItem.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
                        if ($fileItem.Attributes -eq $newFileAttrs) { continue }
                        $fileItem.Attributes = $newFileAttrs
                        $afterFile = Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
                        if (-not ($afterFile.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and $afterFile.Attributes.HasFlag([System.IO.FileAttributes]::System))) {
                            throw "快捷方式隐藏属性设置失败：$filePath"
                        }
                    }
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "autoplay-disable-removable-media"
        Name    = "移动介质自动播放禁用 (AutoPlay DisableAutoplay = 1)"
        Purpose = "插入 U 盘与移动硬盘时不再静默弹出自动执行对话框，防范 U 盘蠕虫自动运行"
        Impact  = "插入 U 盘后需要手动点击打开文件资源管理器查看文件，系统不会主动弹窗询问操作"
        Check   = {
            $a = Get-RegVal "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "DisableAutoplay"
            $b = Get-RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDriveTypeAutoRun"
            $isPass = ($a -eq "1" -and $b -eq "255")
            return @{
                Actual      = "DisableAutoplay=$a, NoDriveTypeAutoRun=$b"
                Expected    = "DisableAutoplay=1, NoDriveTypeAutoRun=255"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "DisableAutoplay" 1
            Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDriveTypeAutoRun" 255
        }
    },
    [PSCustomObject]@{
        Id      = "audio-disable-volume-limiter"
        Name    = "耳机音量超出 37% 警告弹窗解除 (VolumeLimiter = 0)"
        Purpose = "接入耳机或音频设备拉大音量时解除音量限制，不再弹出听力保护提示弹窗"
        Impact  = "调大系统音量时系统不再自动截断，需注意音量控制"
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
        Name    = "OneDrive 原厂卸载、同步禁用与导航项隐藏"
        Purpose = "按实际登记调用原厂卸载器，移除本体并阻断同步；若同步目录为空则清理残留"
        Impact  = "同步停止；不下载云端占位文件、不迁移桌面文档；同步目录包含个人文件时完整保留，仅在为空（或仅含 desktop.ini）时清理"
        Check   = {
            $inventory = Get-OneDriveInventory
            $policy = Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC'
            $emptyCount = @(if ($inventory.EmptyDirs) { $inventory.EmptyDirs }).Count
            $actual = "登记=$($inventory.Registrations.Count), 本体=$($inventory.Executables.Count), 进程=$($inventory.Processes.Count), 导航项=$($inventory.Pinned.Count), 空目录=$emptyCount, 策略=$policy"
            $expected = '登记/本体/进程/导航项/空目录=0, DisableFileSyncNGSC=1'
            $isPass = ($inventory.Registrations.Count + $inventory.Executables.Count + $inventory.Processes.Count + $inventory.Pinned.Count + $emptyCount -eq 0 -and $policy -eq '1')
            return @{
                Actual      = $actual
                Expected    = $expected
                IsCompliant = $isPass
            }
        }
        Apply   = { Invoke-OneDriveRemoval }
    },
    [PSCustomObject]@{
        Id      = "explorer-hide-gallery-node"
        Name    = "资源管理器图库 (Gallery) 侧边栏节点剥离"
        Purpose = "从文件资源管理器侧边栏抹除 Win11 图库 (Gallery) 树节点，消除静默图片与视频索引扫描"
        Impact  = "左侧导航栏不再显示图库大图标，需查看相册可通过此电脑进入特定磁盘文件夹"
        Check   = {
            $galleryClsid = "{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
            $clsidPath = "HKCU:\Software\Classes\CLSID\$galleryClsid"
            $pinnedVal = Get-RegVal $clsidPath "System.IsPinnedToNameSpaceTree"
            $desktop = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$galleryClsid"
            $isPass = (-not $desktop -and ($pinnedVal -eq "0"))
            return @{ Actual = if ($isPass) { "已剥离 (Pinned=0)" } else { "未剥离/已驻留 (Pinned=$pinnedVal)" }; Expected = "Pinned=0, DesktopNameSpace=Absent"; IsCompliant = $isPass }
        }
        Apply   = {
            $galleryClsid = "{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
            $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$galleryClsid"
            if (Test-Path $hklmPath) {
                Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction Stop
                if (Test-Path $hklmPath) { throw "移除 HKLM 图库命名空间节点失败：$hklmPath" }
            }

            $hkcuClsid = "HKCU:\Software\Classes\CLSID\$galleryClsid"
            Ensure-RegKey $hkcuClsid
            Set-ItemProperty -Path $hkcuClsid -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force
            if ((Get-RegVal $hkcuClsid "System.IsPinnedToNameSpaceTree") -ne "0") {
                throw "图库节点隐藏策略写入后校验失败：$hkcuClsid\System.IsPinnedToNameSpaceTree"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-hide-network-neighborhood"
        Name    = "资源管理器左侧网上邻居图标隐藏 (Network Pinned = 0)"
        Purpose = "从文件资源管理器左侧侧边栏拔除网上邻居图标，消除局域网节点背景广播发现与延迟"
        Impact  = "左侧无法直接点击进入「网络」，但通过在地址栏输入 \\IP 访问内网共享完全正常不受影响"
        Check   = {
            $netGuid = "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"
            $hklmNet = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$netGuid"
            $hkcuNet = "HKCU:\Software\Classes\CLSID\$netGuid"
            $hkcuPinned = Get-RegVal $hkcuNet "System.IsPinnedToNameSpaceTree"
            $isPass = (-not $hklmNet -and ($hkcuPinned -eq "0"))
            return @{ Actual = if ($isPass) { "已隐藏" } else { "未隐藏" }; Expected = "Pinned=0, DesktopNameSpace=Absent"; IsCompliant = $isPass }
        }
        Apply   = {
            $netGuid = "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"
            $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$netGuid"
            if (Test-Path $hklmPath) {
                Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction Stop
                if (Test-Path $hklmPath) { throw "移除 HKLM 网上邻居命名空间节点失败：$hklmPath" }
            }

            $hkcuNet = "HKCU:\Software\Classes\CLSID\$netGuid"
            Ensure-RegKey $hkcuNet
            Set-ItemProperty -Path $hkcuNet -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force
            if ((Get-RegVal $hkcuNet "System.IsPinnedToNameSpaceTree") -ne "0") {
                throw "网上邻居隐藏策略写入后校验失败：$hkcuNet\System.IsPinnedToNameSpaceTree"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-hide-home-userprofile"
        Name    = "资源管理器主页 (Home) 与个人主文件夹隐藏"
        Purpose = "从资源管理器侧边栏拔除多余的 Home 小房子与用户名文件夹，只保留此电脑直达大盘，视觉极简"
        Impact  = "左侧导航窗格不再出现当前 Windows 用户名命名的快捷跳转节点"
        Check   = {
            $homeGuid = "{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
            $userGuid = "{59031a47-3f72-44a7-89c5-5595fe6b30ee}"
            $hklmHome = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$homeGuid"
            $hklmUser = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$userGuid"
            $hkcuHome = "HKCU:\Software\Classes\CLSID\$homeGuid"
            $hkcuHomePinned = Get-RegVal $hkcuHome "System.IsPinnedToNameSpaceTree"
            $hkcuUser = "HKCU:\Software\Classes\CLSID\$userGuid"
            $hkcuUserPinned = Get-RegVal $hkcuUser "System.IsPinnedToNameSpaceTree"
            $isPass = (-not $hklmHome -and -not $hklmUser -and ($hkcuHomePinned -eq "0") -and ($hkcuUserPinned -eq "0"))
            return @{ Actual = if ($isPass) { "已隐藏" } else { "未隐藏" }; Expected = "Home=0, UserProfile=0"; IsCompliant = $isPass }
        }
        Apply   = {
            $homeGuid = "{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
            $userGuid = "{59031a47-3f72-44a7-89c5-5595fe6b30ee}"
            foreach ($g in @($homeGuid, $userGuid)) {
                $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$g"
                if (Test-Path $hklmPath) {
                    Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction Stop
                    if (Test-Path $hklmPath) { throw "移除 HKLM 命名空间节点失败：$hklmPath" }
                }

                $hkcuPath = "HKCU:\Software\Classes\CLSID\$g"
                Ensure-RegKey $hkcuPath
                Set-ItemProperty -Path $hkcuPath -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force
                if ((Get-RegVal $hkcuPath "System.IsPinnedToNameSpaceTree") -ne "0") {
                    throw "命名空间节点隐藏策略写入后校验失败：$hkcuPath\System.IsPinnedToNameSpaceTree"
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "userprofile-sandbox-known-folders"
        Name    = "用户目录媒体与遗留已知文件夹沙盒化隐藏 (+h +s)"
        Purpose = "将用户主目录中明确列出的已知文件夹标记为 Hidden + System，仅调整显示属性"
        Impact  = "文件夹即使包含内容也会隐藏；不删除文件、收藏夹、保存搜索或快捷方式，不迁移媒体内容"
        Check   = {
            $targetFolders = @("3D Objects", "Contacts", "Links", "Searches", "Favorites", "Saved Games", "Music", "Videos", "Pictures", "Recorded Calls")
            $unhidden = [System.Collections.Generic.List[string]]::new()
            foreach ($f in $targetFolders) {
                $p = Join-Path $env:USERPROFILE $f
                if (Test-Path -LiteralPath $p) {
                    $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
                    $isSuperHidden = ($item.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
                                      $item.Attributes.HasFlag([System.IO.FileAttributes]::System))
                    if (-not $isSuperHidden) { $unhidden.Add($f) }
                }
            }
            $isPass = ($unhidden.Count -eq 0)
            return @{
                Actual      = if ($isPass) { "全部已受保护隐藏 (+h +s)" } else { "未受保护隐藏: $($unhidden -join ', ')" }
                Expected    = "全部已受保护隐藏 (+h +s)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $targetFolders = @("3D Objects", "Contacts", "Links", "Searches", "Favorites", "Saved Games", "Music", "Videos", "Pictures", "Recorded Calls")

            foreach ($f in $targetFolders) {
                $p = Join-Path $env:USERPROFILE $f
                if (Test-Path -LiteralPath $p) {
                    $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
                    $newAttrs = $item.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
                    [System.IO.File]::SetAttributes($p, $newAttrs)
                    $after = Get-Item -LiteralPath $p -Force -ErrorAction Stop
                    if (-not ($after.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and $after.Attributes.HasFlag([System.IO.FileAttributes]::System))) {
                        throw "已知文件夹隐藏属性设置失败：$p"
                    }
                }
            }
        }
    },
    [PSCustomObject]@{
        Id      = "explorer-unpin-stock-quickaccess-folders"
        Name    = "快速访问出厂预置文件夹穿透取消固定 (Unpin Documents/Pictures等)"
        Purpose = "从文件资源管理器主页/快速访问中穿透取消固定系统出厂强塞的文档、图片、音乐、视频等大图标，仅保留桌面与下载等核心生产力工作区"
        Impact  = "资源管理器「主页」顶部不再陈列庞大的出厂媒体文件夹图标，界面回归紧凑极简"
        Check   = {
            $shell = New-Object -ComObject Shell.Application
            try {
                $qa = $shell.Namespace("shell:::{f874310e-b6b7-47dc-bc84-b9e6b38f5903}")
                if (-not $qa -or $qa.Items().Count -eq 0) {
                    $qa = $shell.Namespace("shell:Quick Access")
                }
                if (-not $qa) {
                    return @{ Actual = "无主页命名空间"; Expected = "无出厂媒体项固定"; IsCompliant = $true }
                }

                $stockNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                @("Documents", "文档", "Pictures", "图片", "Music", "音乐", "Videos", "视频", "3D Objects", "3D 对象") | ForEach-Object {
                    [void]$stockNames.Add($_)
                }

                $pinnedStock = [System.Collections.Generic.List[string]]::new()
                foreach ($item in $qa.Items()) {
                    if ($stockNames.Contains($item.Name)) {
                        $pinnedStock.Add($item.Name)
                    }
                }

                $isPass = ($pinnedStock.Count -eq 0)
                return @{
                    Actual      = if ($isPass) { "已纯净化 (无预置项)" } else { "仍固定: $($pinnedStock -join ', ')" }
                    Expected    = "无出厂媒体项固定"
                    IsCompliant = $isPass
                }
            } finally {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
            }
        }
        Apply   = {
            $shell = New-Object -ComObject Shell.Application
            try {
                $qa = $shell.Namespace("shell:::{f874310e-b6b7-47dc-bc84-b9e6b38f5903}")
                if (-not $qa -or $qa.Items().Count -eq 0) {
                    $qa = $shell.Namespace("shell:Quick Access")
                }
                if ($qa) {
                    $stockNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    @("Documents", "文档", "Pictures", "图片", "Music", "音乐", "Videos", "视频", "3D Objects", "3D 对象") | ForEach-Object {
                        [void]$stockNames.Add($_)
                    }

                    foreach ($item in $qa.Items()) {
                        if ($stockNames.Contains($item.Name)) {
                            $verbs = $item.Verbs()
                            $unpinned = $false
                            for ($i = 0; $i -lt $verbs.Count(); $i++) {
                                $v = $verbs.Item($i)
                                $cleanVerb = $v.Name -replace '[&()]', ''
                                if ($cleanVerb -match 'Unpin from Quick access|Unpin from Home|从快速访问取消固定|从主页取消固定') {
                                    $v.DoIt()
                                    $unpinned = $true
                                    break
                                }
                            }
                            if (-not $unpinned) {
                                Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData "无法通过本地化上下文菜单自动取消固定快速访问项 [$($item.Name)]，请手动从资源管理器右键取消固定。"
                            }
                        }
                    }
                }
            } finally {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
            }
        }
    },
    [PSCustomObject]@{
        Id      = "locale-time-format-24h"
        Name    = "标准 24 小时制时间格式"
        Purpose = "将短时间与长时间固化为标准 24 小时制 (HH:mm / HH:mm:ss)"
        Impact  = "消除 AM/PM 歧义，时间显示锁定前导零；需重启应用或注销生效"
        Check   = {
            $intl = "HKCU:\Control Panel\International"
            $short = Get-RegVal $intl "sShortTime"
            $time  = Get-RegVal $intl "sTimeFormat"
            $itime = Get-RegVal $intl "iTime"
            $itz   = Get-RegVal $intl "iTLZero"
            $isPass = ("$short" -eq "HH:mm" -and "$time" -eq "HH:mm:ss" -and "$itime" -eq "1" -and "$itz" -eq "1")
            return @{
                Actual      = "sShortTime=$short, sTimeFormat=$time, iTime=$itime, iTLZero=$itz"
                Expected    = "sShortTime=HH:mm, sTimeFormat=HH:mm:ss, iTime=1, iTLZero=1"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $intl = "HKCU:\Control Panel\International"
            Ensure-RegKey $intl
            Set-ItemProperty -Path $intl -Name "sShortTime" -Value "HH:mm" -Force
            Set-ItemProperty -Path $intl -Name "sTimeFormat" -Value "HH:mm:ss" -Force
            Set-ItemProperty -Path $intl -Name "iTime" -Value "1" -Force
            Set-ItemProperty -Path $intl -Name "iTLZero" -Value "1" -Force
            if ((Get-RegVal $intl "sShortTime") -ne "HH:mm" -or
                (Get-RegVal $intl "sTimeFormat") -ne "HH:mm:ss" -or
                (Get-RegVal $intl "iTime") -ne "1" -or
                (Get-RegVal $intl "iTLZero") -ne "1") {
                throw "24 小时制时间格式写入后校验失败：$intl"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "input-us-keyboard"
        Name    = "原生 US 键盘输入配置"
        Purpose = "确保语言列表中就绪原生 US 键盘 (0409:00000409)，不添加系统自带输入法"
        Impact  = "保留现有语言列表与已配置输入法；缺失 US 键盘时安全补齐"
        Check   = {
            $state = Get-InputBaselineState
            return @{ Actual = "US=$($state.HasUS)"; Expected = 'US=True'; IsCompliant = [bool]$state.HasUS }
        }
        Apply   = {
            $state = Get-InputBaselineState
            if (-not $state.HasUS) {
                $english = $state.Languages | Where-Object LanguageTag -eq 'en-US' | Select-Object -First 1
                if ($null -eq $english) {
                    $english = (New-WinUserLanguageList -Language 'en-US')[0]
                    $state.Languages.Add($english)
                } elseif (-not $english.InputMethodTips.Contains('0409:00000409')) {
                    $english.InputMethodTips.Add('0409:00000409')
                }
                Set-WinUserLanguageList -LanguageList $state.Languages -Force -ErrorAction Stop
            }
            $after = Get-InputBaselineState
            if (-not $after.HasUS) { throw "原生 US 键盘配置未达到期望终态。" }
        }
    }

)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  交互体验与系统外壳视觉裁剪巡检 (pwsh 7+)" -ForegroundColor Cyan
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

Write-Host "`n📊 [巡检看板] 外壳交互原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Select-Object 状态, 规则, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host

if ($probeErrors.Count -gt 0) {
    throw "本模块存在无法确认的属性，未执行任何写入：$($probeErrors -join '; ')"
}

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
Write-Host "`n🚀 正在单向对齐系统外壳视觉基线..." -ForegroundColor Cyan
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
Write-Host ("  ✅ [外壳加固完成] 成功对齐 {0} / {1} 项基线配置" -f $appliedCount, $driftCount) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
