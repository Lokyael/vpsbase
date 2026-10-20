#requires -Version 7.0
<#
.SYNOPSIS
    Zen Browser

.DESCRIPTION
    Zen Browser (Windows) 自动化纯净安装与企业策略配置脚本。
    1. 专为 PowerShell 7+ (pwsh) 编写，充分运用现代 pwsh 语言特性与原生无 BOM UTF-8 输出。
    2. 严格遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)：对二进制、离线扩展包、语言包及策略文件全流程先检后配，杜绝重复下载与脏写入。
    3. 纯净提取官方安装包的核心组件，杜绝特权维护服务 (MozillaMaintenance)、计划任务及注册表广域污染。
    4. 遵循企业策略优先准则 (Policies Priority)：分离 Gecko 原生白名单策略与 Zen 专属特性，
       通过 defaults\pref\ 全局首选项底座与 policies.json 顶层注入，涵盖 49 项现代极简视效、紧凑模式、Glance 悬浮快窥、多工作区隔离与体验优化全量基线，零侵入用户 Profile。
    5. 企业策略 policies.json 顶层固化：强制常驻显示书签工具栏 (DisplayBookmarksToolbar = always)、配置黄金三角搜索引擎矩阵 (默认高可用必应 + @g 谷歌技术 + @gh 开源码直达) 与切除流氓百度引擎。
    6. 智能注册 Windows 系统级浏览器功能与文件/协议关联 (HTTP, HTTPS, HTML)，幂等配置 Zen Browser 为系统默认浏览器。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - Uninstall : 清洁卸载、注销系统协议注册并移除安装目录 (默认保留用户 Profile)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制重新拉取官方安装包解包覆盖部署程序本体并回正基线配置。

.PARAMETER Purge
    配合 Uninstall 使用，深度粉碎用户 Profile 数据目录 (%APPDATA%\zen)。

.PARAMETER InstallDir
    Zen Browser 安装部署目标目录，默认为 D:\prog\zen-browser。

.PARAMETER InstallerPath
    可选，Zen Browser 本地离线安装包路径（如 zen.installer.exe）。指定后优先使用离线包，免除网络下载。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\zen-browser.ps1 -Action Check

    # 交互式全流程安装与配置
    pwsh -File .\scripts\apps\zen-browser.ps1

    # 强制重新部署覆盖本体并对齐基线
    pwsh -File .\scripts\apps\zen-browser.ps1 -Force

    # 安全清洁卸载 (保留用户数据)
    pwsh -File .\scripts\apps\zen-browser.ps1 -Action Uninstall

    # 深度粉碎卸载 (全抹除)
    pwsh -File .\scripts\apps\zen-browser.ps1 -Action Uninstall -Purge
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall")]
    [string]$Action = "Sync",

    [switch]$Yes,
    [switch]$Force,
    [switch]$Purge,
    [string]$InstallDir,
    [string]$InstallerPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ==============================================================================
# 1. 运行时环境硬门禁与权限安全防御
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "【版本错误】本脚本已全面转向 PowerShell 7+ (pwsh)，不兼容旧版 Windows PowerShell 5.1。请使用 'pwsh' 执行本脚本。"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and $Action -ne "Check") {
    throw "【权限错误】Zen Browser 自动化部署与系统级协议注册需管理员特权，请在提升的 pwsh 会话中重新执行！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将受控配置错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 应用元数据与辅助函数
# ==============================================================================
$AppId       = "zen-browser"
$AppName     = "Zen Browser"
$ProcessName = "zen"

$rawOsArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$osArch = switch ($rawOsArch) {
    "X64"   { "X64" }
    "Arm64" { "Arm64" }
    default { $rawOsArch }
}

$targetInstallerName = switch ($osArch) {
    "Arm64" { "zen.installer-arm64.exe" }
    "X64"   { "zen.installer.exe" }
    default { throw "Zen Browser 仅官方支持 X64 与 Arm64 架构 Windows，当前系统架构为 [$osArch]。" }
}

$scoopRoot = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = "D:\prog\zen-browser"
}
$AppExe = Join-Path $InstallDir "zen.exe"

# 官方安装器会为安装目录授予该 LPAC capability 的读取/执行权限。
# 脚本通过 7z + Copy-Item 部署时不会自动复现该 ACL，必须显式补齐。
$ZenLpacSid = "S-1-15-3-1024-1238444810-1356253261-2257478630-1143196962-1563090664-2414759320-1282101916-4218287853"

$HighValueUserData = @(
    "用户 Profile 数据根目录: %APPDATA%\zen 及 %APPDATA%\Mozilla\Zen",
    "浏览器书签与收藏夹: %APPDATA%\zen\Profiles\*\places.sqlite",
    "保存的登录密码与凭据: %APPDATA%\zen\Profiles\*\logins.json",
    "历史记录与会话: %APPDATA%\zen\Profiles\*\sessionstore.jsonlz4",
    "扩展插件本地离线数据与客制规则 (uBlock, Bitwarden 等)"
)

function Get-PeArchitecture {
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $null }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $null }

    try {
        $fileItem = Get-Item -LiteralPath $FilePath -ErrorAction Stop
        if ($fileItem.Length -lt 4096) { return $null }

        $fs = [System.IO.File]::OpenRead($FilePath)
        try {
            $reader = [System.IO.BinaryReader]::new($fs)
            if ($reader.ReadUInt16() -ne 0x5A4D) { return $null }
            $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
            $peOffset = $reader.ReadInt32()
            if ($peOffset -le 0 -or $peOffset -ge ($fileItem.Length - 24)) { return $null }
            $fs.Seek($peOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            if ($reader.ReadUInt32() -ne 0x00004550) { return $null }
            $machine = $reader.ReadUInt16()
            switch ($machine) {
                0x8664 { return "X64" }
                0xAA64 { return "Arm64" }
                0x014c { return "X86" }
                default { return "Unknown($($machine.ToString('X4')))" }
            }
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $null
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Description = "文件",
        [long]$MinBytes = 1024,
        [int]$TimeoutSec = 600
    )

    $tool = Join-Path $PSScriptRoot "_aria2.ps1"
    if (-not (Test-Path $tool)) {
        throw "未在应用域定位到核心下载引擎: _aria2.ps1，请确保仓库完整性！"
    }

    & $tool -Url $Url -OutFile $OutFile -Description $Description -MinBytes $MinBytes -TimeoutSec $TimeoutSec
}

function Test-ZenLpacAccess {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $requiredRights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize
    $requiredInheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit

    try {
        $rootRules = @((Get-Acl -LiteralPath $Path -ErrorAction Stop).GetAccessRules(
            $true,
            $false,
            [System.Security.Principal.SecurityIdentifier]
        ) | Where-Object {
            $_.IdentityReference.Value -eq $ZenLpacSid -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            -not $_.IsInherited -and
            ($_.FileSystemRights -band $requiredRights) -eq $requiredRights -and
            ($_.InheritanceFlags -band $requiredInheritance) -eq $requiredInheritance
        })
        if ($rootRules.Count -eq 0) {
            return $false
        }

        foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                return $false
            }
            $childRules = @((Get-Acl -LiteralPath $item.FullName -ErrorAction Stop).GetAccessRules(
                $true,
                $true,
                [System.Security.Principal.SecurityIdentifier]
            ) | Where-Object {
                $_.IdentityReference.Value -eq $ZenLpacSid -and
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
            })
            if ($childRules.Count -eq 0) {
                return $false
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Ensure-ZenLpacAccess {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "无法为不存在的安装目录授予 LPAC 权限: $Path"
    }

    $requiredRights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $sid = [System.Security.Principal.SecurityIdentifier]::new($ZenLpacSid)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $existing = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.IdentityReference.Value -eq $ZenLpacSid -and
        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        -not $_.IsInherited -and
        ($_.FileSystemRights -band $requiredRights) -eq $requiredRights -and
        ($_.InheritanceFlags -band $inheritance) -eq $inheritance
    })

    if ($existing.Count -eq 0) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            $requiredRights,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }

    if (-not (Test-ZenLpacAccess -Path $Path)) {
        throw "Zen 安装目录 LPAC 读取/执行权限终态校验失败: $Path"
    }
}

function Remove-ZenPathBoundSystemResidue {
    param([Parameter(Mandatory = $true)][string]$Path)

    $installRoot = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $appExe = Join-Path $installRoot "zen.exe"

    # 仅删除程序路径精确指向当前安装目录的防火墙规则。
    $firewallFilters = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {
        $_.Program -and [string]::Equals(([System.IO.Path]::GetFullPath($_.Program)), $appExe, [System.StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($filter in $firewallFilters) {
        foreach ($rule in @($filter | Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
            Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        }
    }

    # 仅删除动作路径或工作目录明确指向当前安装目录的计划任务。
    $installPattern = [regex]::Escape($installRoot)
    foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $actionText = (@($task.Actions | ForEach-Object {
            "$($_.Execute) $($_.Arguments) $($_.WorkingDirectory)"
        }) -join "`n")
        if ($actionText -match "(?i)$installPattern") {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    # 清理 Windows 通知 AppUserModelId 中仍引用当前安装目录的条目。
    foreach ($root in @(
        "HKCU:\Software\Classes\AppUserModelId",
        "HKLM:\SOFTWARE\Classes\AppUserModelId",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\AppUserModelId"
    )) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $valueText = (@($properties.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { [string]$_.Value }) -join "`n")
            if ($valueText -match "(?i)$installPattern") {
                Remove-Item -LiteralPath $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 清理当前安装路径对应的 App Paths 注册项。
    foreach ($keyPath in @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\zen.exe",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zen.exe",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\zen.exe"
    )) {
        if (Test-Path -LiteralPath $keyPath) {
            $properties = Get-ItemProperty -LiteralPath $keyPath -ErrorAction SilentlyContinue
            $defaultValue = [string]$properties.'(default)'
            $pathValue = [string]$properties.Path
            if (
                [string]::Equals($defaultValue, $appExe, [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($pathValue.TrimEnd('\'), $installRoot, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                Remove-Item -LiteralPath $keyPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    foreach ($root in @(
        "HKCU:\Software\RegisteredApplications",
        "HKLM:\SOFTWARE\RegisteredApplications",
        "HKLM:\SOFTWARE\WOW6432Node\RegisteredApplications"
    )) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $registered = Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue
        foreach ($property in @($registered.PSObject.Properties | Where-Object Name -notmatch '^PS')) {
            $reference = [string]$property.Value
            $targetKey = if ($root -like 'HKCU:*') {
                "HKCU:\$reference"
            } else {
                "HKLM:\$reference"
            }
            $targetValues = @()
            if (Test-Path -LiteralPath $targetKey) {
                $targetValues = @(Get-ChildItem -LiteralPath $targetKey -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                    Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                })
            }
            $valueText = (@($targetValues | ForEach-Object {
                $_.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { [string]$_.Value }
            }) -join "`n")
            if ($property.Name -in @('Zen', 'Zen Browser') -or $valueText -match "(?i)$installPattern") {
                Remove-ItemProperty -LiteralPath $root -Name $property.Name -Force -ErrorAction SilentlyContinue
            }
        }
    }

    foreach ($root in @(
        "HKCU:\Software\Clients\StartMenuInternet",
        "HKLM:\SOFTWARE\Clients\StartMenuInternet",
        "HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet"
    )) {
        foreach ($candidate in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = @(Get-ChildItem -LiteralPath $candidate.PSPath -Recurse -ErrorAction SilentlyContinue) |
                ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue }
            $valueText = (@($properties | ForEach-Object {
                $_.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { [string]$_.Value }
            }) -join "`n")
            if ($valueText -match "(?i)$installPattern") {
                Remove-Item -LiteralPath $candidate.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    foreach ($root in @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )) {
        foreach ($candidate in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $candidate.PSPath -ErrorAction SilentlyContinue
            $valueText = (@($properties.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { [string]$_.Value }) -join "`n")
            if ($valueText -match "(?i)$installPattern") {
                Remove-Item -LiteralPath $candidate.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    foreach ($root in @(
        "HKCU:\Software\Classes\Applications",
        "HKLM:\SOFTWARE\Classes\Applications",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\Applications"
    )) {
        $candidate = Join-Path $root "zen.exe"
        if (Test-Path -LiteralPath $candidate) {
            $properties = @(Get-ChildItem -LiteralPath $candidate -Recurse -ErrorAction SilentlyContinue) |
                ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue }
            $valueText = (@($properties | ForEach-Object {
                $_.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { [string]$_.Value }
            }) -join "`n")
            if ($valueText -match "(?i)$installPattern") {
                Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    foreach ($root in @(
        "HKCU:\Software\Classes",
        "HKLM:\SOFTWARE\Classes",
        "HKLM:\SOFTWARE\WOW6432Node\Classes"
    )) {
        foreach ($candidate in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Where-Object {
            $_.PSChildName -match '^Firefox(HTML|URL|PDF)-[0-9A-Fa-f]+$'
        })) {
            $properties = @(Get-ChildItem -LiteralPath $candidate.PSPath -Recurse -ErrorAction SilentlyContinue) |
                ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue }
            $valueText = (@($properties | ForEach-Object {
                $_.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { [string]$_.Value }
            }) -join "`n")
            if ($valueText -match "(?i)$installPattern") {
                Remove-Item -LiteralPath $candidate.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -and $_.PathName -match "(?i)$installPattern"
    })) {
        Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
        & "$env:SystemRoot\System32\sc.exe" delete $service.Name *> $null
    }

    foreach ($mozillaRoot in @(Get-ChildItem -LiteralPath $env:ProgramData -Directory -Filter "Mozilla-*" -ErrorAction SilentlyContinue)) {
        $zenMarkers = @(Get-ChildItem -LiteralPath $mozillaRoot.FullName -Recurse -Force -ErrorAction SilentlyContinue | Where-Object Name -like "Zen_*")
        if ($zenMarkers.Count -gt 0) {
            Remove-Item -LiteralPath $mozillaRoot.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $mozillaTemp = Join-Path $env:TEMP "mozilla-temp-files"
    if (Test-Path -LiteralPath $mozillaTemp) {
        Remove-Item -LiteralPath $mozillaTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Sync-ZenShortcuts {
    param([switch]$AuditOnly)

    $canonicalLnk = Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Zen.lnk"
    $isLnkReady = (Test-Path $canonicalLnk)
    if ($isLnkReady) {
        try {
            $wsh = New-Object -ComObject WScript.Shell
            $scObj = $wsh.CreateShortcut($canonicalLnk)
            $isLnkReady = ($scObj.TargetPath -eq (Join-Path $InstallDir "zen.exe"))
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        } catch { $isLnkReady = $false }
    }

    if ($AuditOnly) {
        return [PSCustomObject]@{
            IsReady    = $isLnkReady
            StatusText = if ($isLnkReady) { "已就绪" } else { "快捷方式缺失/路径偏离" }
        }
    }

    if (-not $isLnkReady) {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($canonicalLnk)
        $shortcut.TargetPath = Join-Path $InstallDir "zen.exe"
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.IconLocation = "$(Join-Path $InstallDir "zen.exe"),0"
        $shortcut.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        Write-Host "   - 已对齐开始菜单快捷方式: $canonicalLnk" -ForegroundColor Green
    }
    @(
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zen.lnk"),
        "C:\Users\Public\Desktop\Zen.lnk"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==============================================================================
# 首选项基线定义与 JS 格式化/增量合并工具
# ==============================================================================
$zenBaselinePrefs = [ordered]@{
    # 国际化与语言环境
    "intl.locale.requested"                                        = "zh-CN"
    "intl.accept_languages"                                        = "zh-CN, zh, en-US, en"

    # 书签栏与搜索流转体验
    "browser.toolbars.bookmarks.visibility"                        = "always"
    "browser.tabs.loadBookmarksInTabs"                             = $true
    "browser.search.openintab"                                     = $true
    "browser.search.suggest.enabled"                               = $false
    "browser.urlbar.suggest.searches"                              = $false

    # 启动与系统行为
    "browser.startup.page"                                         = 3
    "browser.download.useDownloadDir"                              = $true
    "browser.shell.checkDefaultBrowser"                            = $false
    "browser.tabs.unloadOnLowMemory"                               = $true
    "mousewheel.min_line_scroll_amount"                            = 20

    # 首次启动与欢迎页跳过
    "zen.welcome-screen.seen"                                      = $true
    "browser.aboutwelcome.enabled"                                 = $false
    "trailhead.firstrun.didSeeAboutWelcome"                        = $true
    "browser.startup.homepage_override.mstone"                     = "ignore"

    # 紧凑模式与视口布局
    "zen.view.compact.enable-at-startup"                           = $true
    "zen.view.compact.hide-toolbar"                                = $true
    "zen.view.compact.hide-tabbar"                                 = $true
    "zen.view.compact.show-sidebar-and-toolbar-on-hover"           = $true
    "zen.view.compact.sidebar-keep-hover.duration"                 = 150
    "zen.view.hide-window-controls"                                = $true
    "zen.view.borderless-fullscreen"                               = $true

    # 视觉风格与材质 (4px 微卡片留白)
    "zen.theme.acrylic-sidebar"                                    = $true
    "zen.theme.acrylic-urlbar"                                     = $true
    "zen.theme.border-radius"                                      = -1
    "zen.theme.content-element-separation"                         = 4
    "zen.theme.hide-unified-extensions-button"                     = $true
    "zen.theme.hide-tab-throbber"                                  = $true

    # 侧边栏与地址栏
    "zen.view.use-single-toolbar"                                  = $true
    "zen.tabs.vertical.right-side"                                 = $false
    "zen.view.sidebar-expanded"                                    = $true
    "zen.urlbar.behavior"                                          = "floating-on-type"
    "zen.urlbar.show-domain-only-in-sidebar"                       = $true
    "zen.urlbar.single-toolbar-show-copy-url"                      = $false
    "zen.urlbar.hide-one-offs"                                     = $true
    "zen.urlbar.replace-newtab"                                    = $true

    # 多工作区与分屏
    "zen.workspaces.separate-essentials"                           = $true
    "zen.workspaces.swipe-actions"                                 = $false
    "zen.workspaces.wrap-around-navigation"                        = $true
    "zen.workspaces.open-new-tab-if-last-unpinned-tab-is-closed"    = $true
    "zen.splitView.enable-drag-over-split"                         = $true

    # Glance 悬浮快窥与标签流转
    "zen.glance.enabled"                                           = $true
    "zen.glance.activation-method"                                 = "alt"
    "zen.glance.enable-contextmenu-search"                         = $true
    "zen.tabs.select-recently-used-on-close"                       = $true
    "zen.tabs.rename-tabs"                                         = $true
    "zen.tabs.open-pinned-in-new-tab"                              = $true
    "zen.tabs.close-on-back-with-no-history"                       = $false

    # 流媒体硬解支持
    "media.wmf.hevc.enabled"                                       = 1
}

function Format-JsValue($val) {
    if ($val -is [bool]) { return $val ? "true" : "false" }
    if ($val -is [int] -or $val -is [long]) { return "$val" }
    return "`"$($val.ToString().Replace('\', '\\').Replace('"', '\"'))`""
}

function Get-DefaultsPrefContent {
    param([System.Collections.IDictionary]$DesiredPrefs)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('// Zen Browser Global Default Preferences (Deployed by Automation Baseline)')
    foreach ($key in $DesiredPrefs.Keys) {
        $val = $DesiredPrefs[$key]
        $formatted = Format-JsValue $val
        $lines.Add("pref(`"$key`", $formatted);")
    }
    return ($lines -join "`n") + "`n"
}

# ==============================================================================
# 3. 独立流转分支：清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将卸载 Zen Browser 并清理系统关联！" -ForegroundColor Yellow
        if ($Purge) {
            Write-Host "🔥 【检测到 -Purge 参数：以下高价值用户数据将被深度物理粉碎】:" -ForegroundColor Red
            foreach ($d in $HighValueUserData) {
                Write-Host ("   - {0}" -f $d) -ForegroundColor DarkRed
            }
            Write-Host "👉 该操作不可逆，用户 Profile 与本地数据将被彻底抹除！`n" -ForegroundColor Red
        } else {
            Write-Host "🛡️  【数据安全保护：以下高价值用户数据将默认保留在实机】:" -ForegroundColor Green
            foreach ($d in $HighValueUserData) {
                Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
            }
            Write-Host "👉 默认卸载仅移除程序本体与系统注册项。若需连带粉碎用户 Profile，请指定 -Purge 开关。`n" -ForegroundColor Cyan
        }

        $promptText = if ($Purge) {
            "确认彻底清除 Zen Browser 二进制本体、系统关联与所有用户数据? [y/N]"
        } else {
            "确认注销系统关联并清理 Zen Browser 本体（保留用户数据）? [y/N]"
        }
        $confirm = (Read-Host $promptText).Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在执行系统反注册与环境清理..." -ForegroundColor Yellow

    # 1. 终止进程
    Get-Process -Name "zen" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 600

    # 2. 清理当前安装路径绑定的防火墙、计划任务、通知注册与 App Paths。
    Write-Host "   - 正在清理当前安装路径绑定的系统残留..." -ForegroundColor Gray
    Remove-ZenPathBoundSystemResidue -Path $InstallDir

    # 3. 清理系统默认浏览器与注册表关联 (含 Gecko 动态派生条目)
    Write-Host "   - 正在注销系统 StartMenuInternet 与 RegisteredApplications..." -ForegroundColor Gray

    # 清理 StartMenuInternet 客户端项 (静态 + 动态哈希)
    @(
        "HKCU:\Software\Clients\StartMenuInternet\Zen",
        "HKLM:\SOFTWARE\Clients\StartMenuInternet\Zen",
        "HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet\Zen"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # 清理 Classes ProgID 与 Applications 映射
    Write-Host "   - 正在清理 COM ProgID 与文件类型关联注册..." -ForegroundColor Gray
    @(
        "HKCU:\Software\Classes\ZenHTML",
        "HKCU:\Software\Classes\ZenURL",
        "HKCU:\Software\Classes\ZenPDF",
        "HKLM:\SOFTWARE\Classes\ZenHTML",
        "HKLM:\SOFTWARE\Classes\ZenURL",
        "HKLM:\SOFTWARE\Classes\ZenPDF",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\ZenHTML",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\ZenURL",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\ZenPDF",
        "HKCU:\Software\Classes\Applications\zen.exe",
        "HKCU:\Software\Mozilla\Zen",
        "HKLM:\SOFTWARE\Policies\Zen Browser",
        "HKCU:\Software\Policies\Zen Browser"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path "HKCU:\Software\Classes") {
        Get-ChildItem "HKCU:\Software\Classes" -ErrorAction SilentlyContinue | Where-Object {
            $_.PSChildName -match "^Firefox(HTML|URL|PDF)-[0-9A-Fa-f]+$"
        } | ForEach-Object {
            $cmdPath = Join-Path $_.PSPath "shell\open\command"
            $cmdVal = if (Test-Path $cmdPath) { (Get-ItemProperty $cmdPath -ErrorAction SilentlyContinue)."(default)" } else { "" }
            if ($cmdVal -match "zen\.exe" -or $_.PSChildName -match "18512695A464EF26") {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 清理 Windows 通知中心配置与推送记录
    Write-Host "   - 正在清理 Windows 通知与推送残留..." -ForegroundColor Gray
    @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Get-ChildItem $_ -ErrorAction SilentlyContinue | Where-Object {
                $_.PSChildName -match "^Zen"
            } | ForEach-Object {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 清理默认应用提示 (ApplicationAssociationToasts)
    $toastKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"
    if (Test-Path $toastKey) {
        $toastProps = Get-ItemProperty $toastKey -ErrorAction SilentlyContinue
        $toastProps.PSObject.Properties | Where-Object {
            $_.Name -match "^ZenURL" -or $_.Name -match "zen\.exe"
        } | ForEach-Object {
            Remove-ItemProperty -Path $toastKey -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
    }

    # 清理右键打开方式与扩展名候选 (FileExts OpenWithProgids / OpenWithList)
    Write-Host "   - 正在清理系统扩展名打开方式历史候选..." -ForegroundColor Gray
    Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts" -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.PSChildName -eq "OpenWithProgids"
    } | ForEach-Object {
        $p = $_.PSPath
        $props = Get-ItemProperty $p -ErrorAction SilentlyContinue
        $props.PSObject.Properties | Where-Object {
            $_.Name -match "^Firefox(HTML|URL|PDF)-" -or $_.Name -match "Zen"
        } | ForEach-Object {
            Remove-ItemProperty -Path $p -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
    }
    Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts" -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.PSChildName -eq "OpenWithList"
    } | ForEach-Object {
        $p = $_.PSPath
        $props = Get-ItemProperty $p -ErrorAction SilentlyContinue
        $props.PSObject.Properties | Where-Object {
            $_.Value -match "zen\.exe"
        } | ForEach-Object {
            Remove-ItemProperty -Path $p -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
    }

    # 检查默认协议关联死链
    $deadlinkDetected = $false
    @("http", "https") | ForEach-Object {
        $ucPath = "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$_\UserChoice"
        if (Test-Path $ucPath) {
            $currentProg = (Get-ItemProperty $ucPath -ErrorAction SilentlyContinue).ProgId
            if ($currentProg -match "Zen|Firefox.*-[0-9A-Fa-f]+") {
                $deadlinkDetected = $true
            }
        }
    }
    if ($deadlinkDetected) {
        Write-Host "⚠️  [系统默认浏览器提示] 检测到当前 Windows 默认 Web 浏览器曾指定为 Zen。" -ForegroundColor Yellow
        Write-Host "   因 Windows 用户协议哈希保护机制，建议前往「Windows 设置 -> 应用 -> 默认应用」重新指定常用浏览器以防死链。`n" -ForegroundColor Cyan
    }

    # 4. 清理快捷方式
    $shortcutCandidates = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Zen.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zen.lnk"),
        "C:\Users\Public\Desktop\Zen.lnk"
    )
    foreach ($sc in $shortcutCandidates) {
        if (Test-Path $sc) { Remove-Item -Path $sc -Force -ErrorAction SilentlyContinue }
    }

    # 5. 清理安装目录与本地用户数据缓存
    if (Test-Path $InstallDir) {
        Write-Host "   - 正在清理安装目录: $InstallDir" -ForegroundColor Gray
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $zenAppDataPaths = @(
        (Join-Path $env:APPDATA "zen"),
        (Join-Path $env:APPDATA "Mozilla\Zen")
    )
    $zenLocalAppDataPaths = @(
        (Join-Path $env:LOCALAPPDATA "zen"),
        (Join-Path $env:LOCALAPPDATA "Mozilla\Zen")
    )

    if ($Purge) {
        foreach ($p in $zenAppDataPaths) {
            if (Test-Path $p) {
                Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   - [已粉碎] 用户 Profile 目录: $p" -ForegroundColor Red
            }
        }
    } else {
        foreach ($p in $zenAppDataPaths) {
            if (Test-Path $p) {
                Write-Host "   - [数据安全保护] 用户 Profile 目录已安全保留在: $p" -ForegroundColor Green
            }
        }
    }

    foreach ($p in $zenLocalAppDataPaths) {
        if (Test-Path $p) {
            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "   - 已清理本地临时缓存: $p" -ForegroundColor Gray
        }
    }

    $cleanCacheCandidates = @(
        (Join-Path $env:TEMP "zen.installer-x64.exe"),
        (Join-Path $env:TEMP "zen.installer-arm64.exe")
    )
    foreach ($cp in $cleanCacheCandidates) {
        if (Test-Path $cp) { Remove-Item -Path $cp -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "`n✅ [清洁卸载完成] Zen Browser 二进制本体与系统关联已清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 部署路径: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $InstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$DiffList   = [System.Collections.Generic.List[PSCustomObject]]::new()

# 4.1 程序本体与架构校验
$isInstalled = Test-Path -LiteralPath $AppExe -PathType Leaf
$actualArch = if ($isInstalled) { Get-PeArchitecture $AppExe } else { $null }
$isArchMatch = ($actualArch -eq $osArch)

$exeStatusText = if (-not $isInstalled) {
    "未安装"
} elseif (-not $isArchMatch) {
    "架构冲突 (实机: $actualArch / 系统: $osArch)"
} else {
    "已就绪 ($actualArch)"
}

$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "客户端本体"
    受控属性 = "主执行文件 (zen.exe)"
    期望基线 = "已就绪 ($osArch)"
    实机状态 = $exeStatusText
    状态判定 = if ($isInstalled -and $isArchMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not ($isInstalled -and $isArchMatch)) {
    $DiffList.Add([PSCustomObject]@{
        Property = "主执行文件 (zen.exe)"
        Actual   = $exeStatusText
        Expected = "已就绪 ($osArch)"
        Purpose  = "部署基于 Firefox 内核且与宿主 CPU 架构精确匹配的现代化垂直标签页浏览器"
        Impact   = if (-not $isInstalled) { "首次部署程序本体至 $InstallDir" } else { "清除架构冲突的无效二进制并重新部署 $osArch 核心" }
    })
}

# 4.2 快捷方式
$scAudit = Sync-ZenShortcuts -AuditOnly
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "系统集成"
    受控属性 = "开始菜单快捷方式 (Zen.lnk)"
    期望基线 = "已对齐至安装目录"
    实机状态 = $scAudit.StatusText
    状态判定 = if ($scAudit.IsReady) { "✔ 匹配" } else { "✘ 偏离" }
})

# 4.2.1 官方安装器 LPAC 目录访问权限
$isLpacReady = if ($isInstalled -and $isArchMatch) { Test-ZenLpacAccess -Path $InstallDir } else { $false }
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "系统集成"
    受控属性 = "安装目录 LPAC 读取/执行权限"
    期望基线 = "根目录显式授权并向全部子项继承"
    实机状态 = if ($isLpacReady) { "已对齐" } else { "缺失或继承不完整" }
    状态判定 = if ($isLpacReady) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isLpacReady) {
    $DiffList.Add([PSCustomObject]@{
        Property = "安装目录 LPAC 读取/执行权限"
        Actual   = "缺失或继承不完整"
        Expected = "根目录显式授权并向全部子项继承"
        Purpose  = "复现官方安装器为受限应用容器授予的安装目录读取/执行权限，确保沙盒媒体组件可加载本体资源"
        Impact   = "缺少该权限可能导致沙盒媒体组件读取解码器或运行时资源失败，影响直播播放"
    })
}
if (-not $scAudit.IsReady) {
    $DiffList.Add([PSCustomObject]@{
        Property = "开始菜单快捷方式 (Zen.lnk)"
        Actual   = $scAudit.StatusText
        Expected = "已对齐至安装目录"
        Purpose  = "在开始菜单生成官方标准程序启动快捷方式并清理派生冗余"
        Impact   = "方便按 Win 键搜索快速唤起浏览器"
    })
}

# 4.3 StartMenuInternet 启动命令与 Capabilities 注册
$smiCmd = (Get-ItemProperty "HKLM:\SOFTWARE\Clients\StartMenuInternet\Zen\shell\open\command" -ErrorAction SilentlyContinue)."(default)"
$isSmiCmdMatch = ($smiCmd -eq "`"$AppExe`"")

$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "系统集成"
    受控属性 = "系统 StartMenuInternet 启动入口"
    期望基线 = "`"$AppExe`""
    实机状态 = if ($isSmiCmdMatch) { "已对齐" } else { if ($smiCmd) { $smiCmd } else { "未配置" } }
    状态判定 = if ($isSmiCmdMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isSmiCmdMatch) {
    $DiffList.Add([PSCustomObject]@{
        Property = "系统 StartMenuInternet 启动入口"
        Actual   = if ($smiCmd) { $smiCmd } else { "未配置" }
        Expected = "`"$AppExe`""
        Purpose  = "为 Windows 默认应用与系统外壳提供浏览器主启动可执行文件入口"
        Impact   = "缺少此键将导致 Windows 11 默认应用无法识别或唤起 Zen Browser"
    })
}

$regAppVal = (Get-ItemProperty "HKLM:\SOFTWARE\RegisteredApplications" -Name "Zen Browser" -ErrorAction SilentlyContinue)."Zen Browser"
$isRegAppMatch = ($regAppVal -eq "SOFTWARE\Clients\StartMenuInternet\Zen\Capabilities")
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "系统集成"
    受控属性 = "系统 RegisteredApplications (点亮默认应用)"
    期望基线 = "SOFTWARE\Clients\StartMenuInternet\Zen\Capabilities"
    实机状态 = if ($isRegAppMatch) { "已注册" } else { if ($regAppVal) { $regAppVal } else { "未注册" } }
    状态判定 = if ($isRegAppMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isRegAppMatch) {
    $DiffList.Add([PSCustomObject]@{
        Property = "系统 RegisteredApplications (点亮默认应用)"
        Actual   = if ($regAppVal) { $regAppVal } else { "未注册" }
        Expected = "SOFTWARE\Clients\StartMenuInternet\Zen\Capabilities"
        Purpose  = "注册 ProgID、协议关联并在 Win11 设置「默认应用」中点亮"
        Impact   = "支持在系统设置中一键将 Zen 设为默认 Web 浏览器"
    })
}

# 4.4 企业策略 policies.json 受控细项深入审计
$policyFile = Join-Path $InstallDir "distribution\policies.json"
$policyJson = $null
if (Test-Path $policyFile) {
    try {
        $policyJson = (Get-Content -Path $policyFile -Raw -Encoding utf8NoBOM | ConvertFrom-Json).policies
    } catch { }
}

$corePolicySpecs = @(
    @{ Path = "DisableTelemetry";           Expected = "True";      Desc = "切断浏览器遥测数据上传"; Purpose = "彻底关闭浏览器后台使用情况与崩溃诊断数据上传"; Impact = "保护浏览隐私，消除静默网络请求" },
    @{ Path = "DisableFirefoxAccounts";      Expected = "True";      Desc = "禁用 Firefox 云端账号同步"; Purpose = "禁用 Mozilla 账号体系强制登录与漫游"; Impact = "保持本地独立 Profile，数据不向云端漫游" },
    @{ Path = "OfferToSaveLogins";           Expected = "False";     Desc = "关闭内置密码保存提示"; Purpose = "关闭浏览器内置的保存密码提示"; Impact = "账号密码凭据交由外部密码管理器托管" },
    @{ Path = "PasswordManagerEnabled";      Expected = "False";     Desc = "关闭内置密码管理器"; Purpose = "彻底停用浏览器内置明文密码库"; Impact = "杜绝明文或未加密密码留存在本地 profile" },
    @{ Path = "DNSOverHTTPS.Locked";         Expected = "True";      Desc = "内置 DoH 锁定 (委托系统原生 DoH)"; Purpose = "锁定并关闭浏览器内置 DoH 抢跑"; Impact = "浏览器 DNS 解析完全遵从 Windows 11 原生 DoH 与代理分流" },
    @{ Path = "ExtensionSettings.uBlock";   Expected = "已强制配置"; Desc = "uBlock Origin 强制安装声明"; Purpose = "通过企业策略静默强制安装 uBlock Origin 广告拦截插件"; Impact = "新 Profile 无需手动前往应用商店即可自带全功能广告拦截" },
    @{ Path = "ExtensionSettings.Bitwarden"; Expected = "已强制配置"; Desc = "Bitwarden 密码管理器强制安装声明"; Purpose = "通过企业策略静默强制安装 Bitwarden 密码管理器"; Impact = "保障所有工作区环境密码填充统一可用" },
    @{ Path = "ExtensionSettings.uBlacklist"; Expected = "已强制配置"; Desc = "uBlacklist 搜索结果净化扩展声明"; Purpose = "通过企业策略安装 uBlacklist 扩展，过滤特定内容农场站点"; Impact = "Google/Bing/Brave 搜索结果自动过滤内容农场与低质站点" },
    @{ Path = "DisplayBookmarksToolbar";    Expected = "always";    Desc = "强制常驻显示书签工具栏"; Purpose = "通过企业策略顶层指令强制界面常驻显示书签栏"; Impact = "无需用户手动按快捷键调出，开箱即见书签工具栏" },
    @{ Path = "SearchEngines.Default";       Expected = "Bing";      Desc = "默认搜索引擎 (Bing 高可用)"; Purpose = "将默认搜索引擎锁定为国内高可用的微软必应"; Impact = "无代理环境下仍可秒级搜索，免受网络不可达困扰" },
    @{ Path = "SearchEngines.GoogleAlias";   Expected = "@g";        Desc = "谷歌技术搜索捷径 (@g)"; Purpose = "配置 Google 搜索别名快捷方式 @g"; Impact = "地址栏输入「@g 关键词」直达 Google 搜索" },
    @{ Path = "SearchEngines.GitHubAlias";   Expected = "@gh";       Desc = "GitHub 源码搜索捷径 (@gh)"; Purpose = "配置 GitHub 仓库搜索别名快捷方式 @gh"; Impact = "地址栏输入「@gh 仓库名」直达 GitHub 全局代码搜索" },
    @{ Path = "Preferences.webrtc-leak";     Expected = "True";      Desc = "WebRTC 默认路由防泄漏"; Purpose = "锁定 WebRTC 仅使用默认出口路由，防止通过副网卡/物理网卡泄漏真实公网 IP"; Impact = "消除 WebRTC 绕过代理泄露真实 IP 风险，同时保障腾讯会议/飞书等网页会议正常通信" },
    @{ Path = "Preferences.geo-disable";     Expected = "False";    Desc = "系统地理位置 API 全局物理阻断"; Purpose = "通过企业策略禁用浏览器 Geolocation 定位，禁止网页获取物理位置"; Impact = "网页请求定位时静默拒绝，不弹出权限授权弹窗" },
    @{ Path = "Preferences.private-shortcut"; Expected = "True";     Desc = "阻断私密浏览残破快捷方式生成"; Purpose = "锁定私密浏览独立快捷方式状态为已生成，规避上游 Fluent 模板缺失导致生成 {-brand-shortcut-name} 占位符快捷方式"; Impact = "保持开始菜单仅有标准 Zen 入口，从根源杜绝幽灵快捷方式" }
)

foreach ($ps in $corePolicySpecs) {
    $actVal = "<未配置>"
    if ($policyJson) {
        if ($ps.Path -eq "DisableTelemetry") { $actVal = "$($policyJson.DisableTelemetry)" }
        elseif ($ps.Path -eq "DisableFirefoxAccounts") { $actVal = "$($policyJson.DisableFirefoxAccounts)" }
        elseif ($ps.Path -eq "OfferToSaveLogins") { $actVal = "$($policyJson.OfferToSaveLogins)" }
        elseif ($ps.Path -eq "PasswordManagerEnabled") { $actVal = "$($policyJson.PasswordManagerEnabled)" }
        elseif ($ps.Path -eq "DNSOverHTTPS.Locked") { $actVal = if ($policyJson.DNSOverHTTPS) { "$($policyJson.DNSOverHTTPS.Locked)" } else { "<未配置>" } }
        elseif ($ps.Path -eq "ExtensionSettings.uBlock") {
            $actVal = if ($policyJson.ExtensionSettings -and $policyJson.ExtensionSettings."uBlock0@raymondhill.net") { "已强制配置" } else { "未配置" }
        }
        elseif ($ps.Path -eq "ExtensionSettings.Bitwarden") {
            $actVal = if ($policyJson.ExtensionSettings -and $policyJson.ExtensionSettings."{446900e4-71c2-419f-a6a7-df9c091e268b}") { "已强制配置" } else { "未配置" }
        }
        elseif ($ps.Path -eq "ExtensionSettings.uBlacklist") {
            $actVal = if ($policyJson.ExtensionSettings -and $policyJson.ExtensionSettings."@ublacklist") { "已强制配置" } else { "未配置" }
        }
        elseif ($ps.Path -eq "DisplayBookmarksToolbar") {
            $actVal = if ($policyJson.DisplayBookmarksToolbar) { "$($policyJson.DisplayBookmarksToolbar)" } else { "<未配置>" }
        }
        elseif ($ps.Path -eq "SearchEngines.Default") {
            $actVal = if ($policyJson.SearchEngines) { "$($policyJson.SearchEngines.Default)" } else { "<未配置>" }
        }
        elseif ($ps.Path -eq "SearchEngines.GoogleAlias") {
            $gEng = if ($policyJson.SearchEngines -and $policyJson.SearchEngines.Add) { @($policyJson.SearchEngines.Add | Where-Object { $_.Name -eq "Google" })[0] } else { $null }
            $actVal = if ($gEng) { "$($gEng.Alias)" } else { "<未配置>" }
        }
        elseif ($ps.Path -eq "SearchEngines.GitHubAlias") {
            $ghEng = if ($policyJson.SearchEngines -and $policyJson.SearchEngines.Add) { @($policyJson.SearchEngines.Add | Where-Object { $_.Name -eq "GitHub" })[0] } else { $null }
            $actVal = if ($ghEng) { "$($ghEng.Alias)" } else { "<未配置>" }
        }
        elseif ($ps.Path -eq "Preferences.webrtc-leak") {
            $actVal = if ($policyJson.Preferences -and $policyJson.Preferences."media.peerconnection.ice.default_address_only") { "$($policyJson.Preferences."media.peerconnection.ice.default_address_only".Value)" } else { "<未配置>" }
        }
        elseif ($ps.Path -eq "Preferences.geo-disable") {
            $actVal = if ($policyJson.Preferences -and $null -ne $policyJson.Preferences."geo.enabled") { "$($policyJson.Preferences."geo.enabled".Value)" } else { "<未配置>" }
        }
        elseif ($ps.Path -eq "Preferences.private-shortcut") {
            $actVal = if ($policyJson.Preferences -and $null -ne $policyJson.Preferences."browser.privacySegmentation.createdShortcut") { "$($policyJson.Preferences."browser.privacySegmentation.createdShortcut".Value)" } else { "<未配置>" }
        }
    }

    $isMatch = ($actVal.ToLower() -eq $ps.Expected.ToLower())
    $AuditBoard.Add([PSCustomObject]@{
        分层模块 = "企业策略"
        受控属性 = "$($ps.Desc) [$($ps.Path)]"
        期望基线 = $ps.Expected
        实机状态 = $actVal
        状态判定 = if ($isMatch) { "✔ 匹配" } else { "✘ 偏离" }
    })

    if (-not $isMatch) {
        $DiffList.Add([PSCustomObject]@{
            Property = "$($ps.Desc) [$($ps.Path)]"
            Actual   = $actVal
            Expected = $ps.Expected
            Purpose  = $ps.Purpose
            Impact   = $ps.Impact
        })
    }
}

# 4.5 全局默认首选项底座 (defaults\pref\zen-overrides.js)
$defaultsPrefDir = Join-Path $InstallDir "defaults\pref"
$defaultsPrefFile = Join-Path $defaultsPrefDir "zen-overrides.js"
$expectedDefaultsPrefText = Get-DefaultsPrefContent -DesiredPrefs $zenBaselinePrefs

$isDefaultsPrefReady = $false
if (Test-Path $defaultsPrefFile) {
    try {
        $actualPrefText = [System.IO.File]::ReadAllText($defaultsPrefFile, [System.Text.UTF8Encoding]::new($false)).Trim()
        $isDefaultsPrefReady = ($actualPrefText -eq $expectedDefaultsPrefText.Trim())
    } catch { }
}

$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好配置"
    受控属性 = "全局默认首选项 (defaults\pref\zen-overrides.js)"
    期望基线 = "涵盖紧凑模式/Glance/多工作区等 $($zenBaselinePrefs.Count) 项基线"
    实机状态 = if ($isDefaultsPrefReady) { "已对齐 ($($zenBaselinePrefs.Count) 项)" } elseif (-not (Test-Path $defaultsPrefFile)) { "<缺失未配置>" } else { "内容偏离基线" }
    状态判定 = if ($isDefaultsPrefReady) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isDefaultsPrefReady) {
    $DiffList.Add([PSCustomObject]@{
        Property = "全局默认首选项 (defaults\pref\zen-overrides.js)"
        Actual   = if (-not (Test-Path $defaultsPrefFile)) { "<缺失未配置>" } else { "内容偏离基线" }
        Expected = "涵盖紧凑模式/Glance/多工作区等 $($zenBaselinePrefs.Count) 项基线"
        Purpose  = "通过 Gecko 原生 defaults\pref\ 机制注入全局默认首选项，为新建与未覆写的 Profile 提供纯净默认环境"
        Impact   = "锁定单工具栏、地址栏悬浮、无边框全屏等现代化 Zen 视觉与交互体验"
    })
}

Write-Host "`n📊 [巡检看板] Zen Browser 受控属性基线审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($DiffList.Count -gt 0) {
    Write-Host "`n📋 [差异清单] 检测到以下受控属性偏离工程基线:" -ForegroundColor Cyan
    $DiffList | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

if ($Action -eq "Check") {
    if ($DiffList.Count -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性与策略均符合工程基线，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $DiffList.Count) -ForegroundColor Yellow
    }
    return
}

if ($DiffList.Count -eq 0 -and $isInstalled -and -not $Force) {
    Write-Host "✨ [状态合规] 所有受控属性均已符合工程基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate - Shift-Left Transparency)
# ==============================================================================

# 5.1 运行态并发防覆写硬门禁
$runningZen = Get-Process -Name "zen" -ErrorAction SilentlyContinue
if ($runningZen) {
    if (-not $Yes) {
        Write-Warning "检测到 Zen Browser 当前正在运行！外部修改会被退出时的内存状态覆写。"
        $confirmProc = (Read-Host "是否立即关闭正在运行的 zen 进程以继续应用基线? [Y/n]").Trim()
        if ($confirmProc -match '^(n|no)$') {
            Write-Host "[-] 用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningZen | Stop-Process -Force
    Start-Sleep -Milliseconds 600
}

# 5.2 未安装或架构冲突审查门禁
$needBinaryDeploy = (-not $isInstalled) -or (-not $isArchMatch) -or $Force
if ($needBinaryDeploy) {
    if (-not $Yes) {
        $promptMsg = if (-not $isInstalled) {
            "未检测到 Zen Browser，是否立即拉取官方安装包进行部署？[Y/n]"
        } elseif ($Force) {
            "已开启强制重新部署 (-Force)，是否重新解包覆盖安装 [$osArch] 本体？[Y/n]"
        } else {
            "检测到当前 Zen Browser 二进制架构冲突，是否重新拉取并部署 [$osArch] 核心？[Y/n]"
        }
        $shouldInstall = (Read-Host $promptMsg).Trim()
        if ($shouldInstall -match '^(n|no)$') {
            Write-Host "[-] 操作已由用户取消，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
}

# 5.3 策略审查门禁 (Shift-Left Gate: 目的与影响结构化逐项直出)
if (-not $Yes) {
    Write-Host "`n💡 [改动意图与技术边界审查 (Gate)]" -ForegroundColor Cyan
    Write-Host "   本次即将对齐以下偏离项，请逐项评估改动 [目的] 与 [影响]:" -ForegroundColor Gray
    $idx = 1
    foreach ($p in $DiffList) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.Property) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.Actual, $p.Expected) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $p.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $p.Impact) -ForegroundColor Gray
        $idx++
    }

    $gateChoice = (Read-Host "`n确认应用上述工程基线配置? [Y] 确认执行 / [Q] 退出 (默认 Y)").Trim()
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体解包安装或覆盖升级
if ($needBinaryDeploy) {
    Write-Host "`n🚀 正在准备安装 Zen Browser 核心本体 ($osArch)..." -ForegroundColor Cyan
    $pkgPath = $InstallerPath
    $archCachePkg = Join-Path $env:TEMP ("zen.installer-" + $osArch.ToLower() + ".exe")

    if (-not $pkgPath -or -not (Test-Path $pkgPath)) {
        $pkgPath = $archCachePkg
        $isCacheHit = $false
        if (-not $Force -and (Test-Path $pkgPath)) {
            $cachedArch = Get-PeArchitecture $pkgPath
            if ($cachedArch -eq $osArch -and (Get-Item $pkgPath).Length -ge 50MB) {
                $isCacheHit = $true
                Write-Host "   ✔ 命中已缓存的安装包: $pkgPath ($([math]::Round((Get-Item $pkgPath).Length / 1MB, 2)) MB, $cachedArch)" -ForegroundColor Green
            } else {
                Remove-Item -Path $pkgPath -Force -ErrorAction SilentlyContinue
            }
        }

        if (-not $isCacheHit) {
            $apiUrl = "https://api.github.com/repos/zen-browser/desktop/releases/latest"
            Write-Host "   - 正在查询 GitHub 最新 Release ($targetInstallerName)..." -ForegroundColor Gray
            $rel = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "vpsbase-zen-script" } -TimeoutSec 15
            $asset = $rel.assets | Where-Object { $_.name -ceq $targetInstallerName } | Select-Object -First 1
            if (-not $asset) { throw "未在 GitHub 最新 Release 中匹配到架构 [$osArch] 对应的安装包 ($targetInstallerName)" }

            Invoke-DownloadFile -Url $asset.browser_download_url -OutFile $pkgPath -Description "Zen 安装包 ($osArch)"
        }
    } else {
        $offlineArch = Get-PeArchitecture $pkgPath
        if ($offlineArch -ne $osArch) {
            throw "指定的离线安装包 [$pkgPath] 机器架构为 [$offlineArch]，与当前操作系统架构 [$osArch] 不匹配！"
        }
    }

    # 提取 core 组件至安装目录 (使用 7z)
    $7zExe = (Join-Path $scoopRoot "apps\7zip\current\7z.exe")
    if (-not (Test-Path $7zExe)) { $7zExe = (Join-Path $scoopRoot "shims\7z.exe") }
    if (-not (Test-Path $7zExe)) { $7zExe = (Get-Command "7z.exe" -ErrorAction SilentlyContinue).Source }
    if (-not $7zExe) { throw "未检测到 7z 解包工具，请确保已安装 7zip！" }

    $extractTemp = Join-Path $env:TEMP ("zenextract-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null

    try {
        Write-Host "   - 正在解包安装包核心文件..." -ForegroundColor Gray
        & $7zExe x $pkgPath "-o$extractTemp" -y *>$null
        if ($LASTEXITCODE -ne 0) { throw "7z 解包失败，退出代码: $LASTEXITCODE" }

        $coreDir = Join-Path $extractTemp "core"
        if (-not (Test-Path $coreDir)) { $coreDir = $extractTemp }

        if (-not (Test-Path $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }

        Copy-Item -Path "$coreDir\*" -Destination $InstallDir -Recurse -Force

        # 终态物理存在与二进制架构双重硬门禁
        if (-not (Test-Path $AppExe)) { throw "解包完成但未能定位到 $AppExe！" }
        $installedArch = Get-PeArchitecture $AppExe
        if ($installedArch -ne $osArch) {
            throw "【终态校验失败】部署完成的 $AppExe 机器架构为 [$installedArch]，与当前操作系统架构 [$osArch] 不匹配！"
        }

        $isInstalled = $true
        $isArchMatch = $true
        Write-Host "✅ Zen Browser 核心程序已部署至: $InstallDir (架构: $installedArch)" -ForegroundColor Green
    } finally {
        if (Test-Path $extractTemp) { Remove-Item -Path $extractTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# 6.2 复现官方安装器 LPAC 目录访问权限
Write-Host "`n🔐 正在对齐安装目录 LPAC 读取/执行权限..." -ForegroundColor Cyan
Ensure-ZenLpacAccess -Path $InstallDir
Write-Host "✅ 安装目录 LPAC 权限已对齐并完成继承校验: $InstallDir" -ForegroundColor Green

# 6.3 注册系统关联与开始菜单快捷方式
Write-Host "`n⚙️  正在注册系统级默认浏览器与能力 (Capabilities)..." -ForegroundColor Cyan
Sync-ZenShortcuts

$appKey = "HKLM:\SOFTWARE\Clients\StartMenuInternet\Zen"
if (-not (Test-Path $appKey)) { New-Item -Path $appKey -Force | Out-Null }
Set-ItemProperty -Path $appKey -Name "(default)" -Value "Zen Browser" -Force

# DefaultIcon
$iconKey = "$appKey\DefaultIcon"
if (-not (Test-Path $iconKey)) { New-Item -Path $iconKey -Force | Out-Null }
Set-ItemProperty -Path $iconKey -Name "(default)" -Value "$AppExe,0" -Force

# shell\open\command
$cmdKey = "$appKey\shell\open\command"
if (-not (Test-Path $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
Set-ItemProperty -Path $cmdKey -Name "(default)" -Value "`"$AppExe`"" -Force

# InstallInfo
$installInfoKey = "$appKey\InstallInfo"
if (-not (Test-Path $installInfoKey)) { New-Item -Path $installInfoKey -Force | Out-Null }
Set-ItemProperty -Path $installInfoKey -Name "IconsVisible" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $installInfoKey -Name "ReinstallCommand" -Value "`"$AppExe`" -silent -reinstall" -Force

# Capabilities
$capKey = "$appKey\Capabilities"
if (-not (Test-Path $capKey)) { New-Item -Path $capKey -Force | Out-Null }
Set-ItemProperty -Path $capKey -Name "ApplicationName" -Value "Zen Browser" -Force
Set-ItemProperty -Path $capKey -Name "ApplicationDescription" -Value "Zen Browser - Experience tranquillity while browsing the web." -Force
Set-ItemProperty -Path $capKey -Name "ApplicationIcon" -Value "$AppExe,0" -Force

$startmenuKey = "$capKey\Startmenu"
if (-not (Test-Path $startmenuKey)) { New-Item -Path $startmenuKey -Force | Out-Null }
Set-ItemProperty -Path $startmenuKey -Name "StartmenuInternet" -Value "Zen" -Force

$urlKey = "$capKey\URLAssociations"
if (-not (Test-Path $urlKey)) { New-Item -Path $urlKey -Force | Out-Null }
Set-ItemProperty -Path $urlKey -Name "http" -Value "ZenURL" -Force
Set-ItemProperty -Path $urlKey -Name "https" -Value "ZenURL" -Force

$fileKey = "$capKey\FileAssociations"
if (-not (Test-Path $fileKey)) { New-Item -Path $fileKey -Force | Out-Null }
@(
    @{ Ext = ".htm";   ProgId = "ZenHTML" },
    @{ Ext = ".html";  ProgId = "ZenHTML" },
    @{ Ext = ".shtml"; ProgId = "ZenHTML" },
    @{ Ext = ".xht";   ProgId = "ZenHTML" },
    @{ Ext = ".xhtml"; ProgId = "ZenHTML" },
    @{ Ext = ".svg";   ProgId = "ZenHTML" },
    @{ Ext = ".pdf";   ProgId = "ZenPDF" }
) | ForEach-Object {
    Set-ItemProperty -Path $fileKey -Name $_.Ext -Value $_.ProgId -Force
}

Set-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "Zen Browser" -Value "SOFTWARE\Clients\StartMenuInternet\Zen\Capabilities" -Force

# 注册 ProgID 实体
@(
    @{ Key = "HKLM:\SOFTWARE\Classes\ZenHTML"; Name = "Zen HTML Document"; Icon = "$AppExe,1" },
    @{ Key = "HKLM:\SOFTWARE\Classes\ZenURL";  Name = "Zen URL";           Icon = "$AppExe,0" },
    @{ Key = "HKLM:\SOFTWARE\Classes\ZenPDF";  Name = "Zen PDF Document";  Icon = "$AppExe,0" }
) | ForEach-Object {
    $k = $_.Key
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    Set-ItemProperty -Path $k -Name "(default)" -Value $_.Name -Force

    $progIconKey = "$k\DefaultIcon"
    if (-not (Test-Path $progIconKey)) { New-Item -Path $progIconKey -Force | Out-Null }
    Set-ItemProperty -Path $progIconKey -Name "(default)" -Value $_.Icon -Force

    $cmd = "$k\shell\open\command"
    if (-not (Test-Path $cmd)) { New-Item -Path $cmd -Force | Out-Null }
    Set-ItemProperty -Path $cmd -Name "(default)" -Value "`"$AppExe`" -osint -url `"%1`"" -Force
}
Write-Host "✅ 系统 Capabilities 与 默认浏览器关联注册完成。" -ForegroundColor Green

# 6.4 注入企业策略 policies.json
Write-Host "⚙️  正在单向对齐企业策略 (distribution/policies.json)..." -ForegroundColor Cyan
$distDir = Join-Path $InstallDir "distribution"
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

$policiesObj = [ordered]@{
    RequestedLocales           = @("zh-CN", "en-US")
    DisableFirefoxAccounts     = $true
    DisableTelemetry           = $true
    DisableFirefoxStudies      = $true
    DisableDefaultBrowserAgent = $true
    DontCheckDefaultBrowser    = $true
    DisablePocket              = $true
    DisableFeedbackCommands    = $true
    OfferToSaveLogins          = $false
    PasswordManagerEnabled     = $false
    SearchSuggestEnabled       = $false
    DisplayBookmarksToolbar    = "always"
    SearchEngines              = [ordered]@{
        Default         = "Bing"
        PreventInstalls = $false
        Remove          = @("Baidu", "百度")
        Add             = @(
            [ordered]@{
                Name        = "Google"
                URLTemplate = "https://www.google.com/search?q={searchTerms}"
                Method      = "GET"
                IconURL     = "https://www.google.com/favicon.ico"
                Alias       = "@g"
            },
            [ordered]@{
                Name        = "GitHub"
                URLTemplate = "https://github.com/search?q={searchTerms}&type=repositories"
                Method      = "GET"
                IconURL     = "https://github.com/favicon.ico"
                Alias       = "@gh"
            }
        )
    }
    DNSOverHTTPS               = [ordered]@{
        Enabled = $false
        Locked  = $true
    }
    ExtensionSettings          = [ordered]@{
        "uBlock0@raymondhill.net" = [ordered]@{
            installation_mode = "force_installed"
            install_url       = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
            default_area      = "navbar"
        }
        "{446900e4-71c2-419f-a6a7-df9c091e268b}" = [ordered]@{
            installation_mode = "force_installed"
            install_url       = "https://addons.mozilla.org/firefox/downloads/latest/bitwarden-password-manager/latest.xpi"
            default_area      = "navbar"
        }
        "@ublacklist" = [ordered]@{
            installation_mode = "force_installed"
            install_url       = "https://addons.mozilla.org/firefox/downloads/latest/ublacklist/latest.xpi"
            default_area      = "navbar"
        }
    }
    Preferences                = [ordered]@{
        "geo.enabled"                                 = [ordered]@{ Value = $false; Status = "locked" }
        "media.peerconnection.ice.default_address_only" = [ordered]@{ Value = $true; Status = "locked" }
        "network.prefetch-next"                       = [ordered]@{ Value = $false; Status = "locked" }
        "network.dns.disablePrefetch"                 = [ordered]@{ Value = $true; Status = "locked" }
        "browser.privacySegmentation.createdShortcut" = [ordered]@{ Value = $true; Status = "locked" }
    }
}

$policyOutput = [ordered]@{ policies = $policiesObj } | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText((Join-Path $distDir "policies.json"), $policyOutput, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ 企业策略已原子写入: $distDir\policies.json" -ForegroundColor Green

# 6.5 注入全局首选项 defaults\pref\ (程序级全局默认底座，零侵入用户 Profile)
Write-Host "⚙️  正在固化全局默认首选项 (defaults\pref\zen-overrides.js)..." -ForegroundColor Cyan
if (-not (Test-Path $defaultsPrefDir)) {
    New-Item -ItemType Directory -Path $defaultsPrefDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($defaultsPrefFile, $expectedDefaultsPrefText, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ 全局默认首选项已原子写入: $defaultsPrefFile" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 工程基线与策略部署完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 部署路径: $InstallDir" -ForegroundColor Gray
Write-Host "   - 系统关联: Capabilities 已注册，点亮 Win11 默认浏览器设置" -ForegroundColor Gray
Write-Host "   - 策略扩展: policies.json 已固化 uBlock Origin / Bitwarden / uBlacklist 与遥测切断" -ForegroundColor Gray
Write-Host "   - 搜索矩阵: 默认高可用 Bing + @g 谷歌技术 + @gh 开源码直达；书签工具栏强制常驻" -ForegroundColor Gray
Write-Host "   - 偏好基线: defaults\pref\ 已固化紧凑模式、Glance 快窥与多工作区等 49 项体验基线" -ForegroundColor Gray

$isDefaultBrowser = $false
try {
    $httpChoice = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    if ($httpChoice -like "*Zen*") { $isDefaultBrowser = $true }
} catch { }

Write-Host "`n--------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📋 [手动收尾清单 (Actionable Handoff)]" -ForegroundColor Cyan
if (-not $isDefaultBrowser) {
    Write-Host "  1. 设为默认: 在系统【默认应用】中将 Zen Browser 设为默认 Web 浏览器" -ForegroundColor Yellow
}
Write-Host "  2. uBlacklist 搜索净化订阅 (扩展图标 → 选项 → 添加订阅，粘贴后每日自动更新):" -ForegroundColor Cyan
Write-Host "     - 中文技术社区与采集站 (屏蔽 CSDN/脚本之家/代码抄袭/机翻站):" -ForegroundColor Gray
Write-Host "       https://raw.githubusercontent.com/cobaltdisco/Google-Chinese-Results-Blocklist/master/uBlacklist_subscription.txt" -ForegroundColor DarkCyan
Write-Host "     - 中文泛生活与内容农场 (大体量清洗生活/健康/娱乐类内容农场):" -ForegroundColor Gray
Write-Host "       https://raw.githubusercontent.com/dallaslu/penzai-list/main/uBlacklist.txt" -ForegroundColor DarkCyan
Write-Host "     - 全球 AI/SEO 垃圾农场 (屏蔽自动化 AI 生成垃圾文章与点击诱饵站):" -ForegroundColor Gray
Write-Host "       https://raw.githubusercontent.com/laylavish/uBlockOrigin-HUGE-AI-Blocklist/main/list_uBlacklist.txt" -ForegroundColor DarkCyan
Write-Host "     - 技术问答机翻镜像专杀 (精准抹除 StackOverflow 中文机翻倒卖站):" -ForegroundColor Gray
Write-Host "       https://raw.githubusercontent.com/arosh/ublacklist-stackoverflow-translation/master/uBlacklist.txt" -ForegroundColor DarkCyan
Write-Host "--------------------------------------------------------------------`n" -ForegroundColor DarkGray

return
