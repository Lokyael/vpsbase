#requires -Version 7.0
<#
.SYNOPSIS
    消费级预装与废弃系统组件裁剪基线

.DESCRIPTION
    Windows 11 消费级预装应用卸载、废弃按需功能 (FOD) 剥离与过时 CBS 可选特性裁剪模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 批量清理 31 项消费级 UWP 预装应用（Xbox 全套、Copilot、Clipchamp、DevHome、新闻天气、Solitaire 等）。
    3. 移除明确不使用的 10 项按需功能（含经典 WMP、文档查看、OpenSSH Server、OneSync、Fax/Scan 与旧 Quick Assist）。
    4. 禁用 8 项淘汰 CBS 可选特性 (SMBv1、PSv2、Telnet、TFTP 等)。
    5. 禁用系统保留存储 (DISM Reserved Storage)，释放 7GB+ 固态磁盘物理空间。
    6. 禁用存储感知企业组策略 (Storage Sense)，避免后台静默删除文件与云端脱水。
    7. 配置不新增 UEFI 锁的 LSA 保护，并关闭 WDigest 明文凭据缓存。
    8. 启用 Windows Defender ASR Office 防衍生子进程规则。
    9. 卸载微软照片预装应用 (Photos)。
    10. 在 Windows 11 专业版 en-US 上移除 Edge 浏览器及当前用户数据，保留完整 Evergreen WebView2、共享引擎与自动更新组件（卸载解锁采用社区机制）。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (只读诊断受控属性对比，零写入安全退出)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\desktop\os\modules\components.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\desktop\os\modules\components.ps1

    # 无交互一键全量对齐
    pwsh -File .\desktop\os\modules\components.ps1 -Yes
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

# Edge 浏览器仅纳管 Stable 系统安装；共享引擎与更新器由原厂维护。
$EdgeBrowserRoots = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge')
)
$EdgeUninstallKeys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
)
$EdgeBrowserFiles = @($EdgeBrowserRoots) + @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk'),
    (Join-Path $env:PUBLIC 'Desktop\Microsoft Edge.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Microsoft Edge.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Tombstones\Microsoft Edge.lnk')
)

function Test-EdgeBrowserReference {
    param([string]$Text)
    foreach ($root in $EdgeBrowserRoots) {
        if ($Text -match ('(?i)(?<![\w\\])' + [regex]::Escape($root) + '\\')) { return $true }
    }
    return $false
}

function Test-EdgeBrowserServiceReference {
    # 服务 PathName 包含启动参数，仅按实际执行文件判断归属。
    param([string]$PathName)
    $exe = if ($PathName -match '^"([^"]+)"(?:\s|$)') { $Matches[1] }
            elseif ($PathName -match '^([^\s"]+)(?:\s|$)') { $Matches[1] }
            else { return $false }
    if (-not [IO.Path]::IsPathFullyQualified($exe)) { return $false }
    try { $exe = [IO.Path]::GetFullPath($exe) } catch { return $false }
    return Test-EdgeBrowserReference $exe
}

function Get-EdgeBrowserInventory {
    $registrations = @($EdgeUninstallKeys | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
        Get-ItemProperty -LiteralPath $_ -ErrorAction Stop
    })
    $registryKeys = [Collections.Generic.List[string]]::new()
    foreach ($hive in @('HKCU:\Software', 'HKLM:\SOFTWARE')) {
        foreach ($relative in @(
            'Clients\StartMenuInternet\Microsoft Edge',
            'Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
            'Classes\Applications\msedge.exe',
            'Classes\MSEdgeHTM', 'Classes\MSEdgePDF', 'Classes\microsoft-edge'
        )) {
            $key = Join-Path $hive $relative
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $commandKey = Join-Path $key 'shell\open\command'
            $command = if (Test-Path -LiteralPath $commandKey) {
                (Get-ItemProperty -LiteralPath $commandKey -ErrorAction Stop).'(default)'
            } else { (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)' }
            if (Test-EdgeBrowserReference $command) { $registryKeys.Add($key) }
        }
    }
    $values = [Collections.Generic.List[object]]::new()
    foreach ($hive in @('HKCU:\Software', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
        foreach ($relative in @('Microsoft\Windows\CurrentVersion\Run', 'RegisteredApplications')) {
            if ($hive -eq 'HKLM:\SOFTWARE\WOW6432Node' -and $relative -eq 'RegisteredApplications') { continue }
            $key = Join-Path $hive $relative
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
                $owned = Test-EdgeBrowserReference ([string]$p.Value)
                if ($relative -eq 'RegisteredApplications') {
                    $owned = $p.Name -eq 'Microsoft Edge' -and
                        [string]$p.Value -eq 'Software\Clients\StartMenuInternet\Microsoft Edge\Capabilities'
                }
                if ($owned) { $values.Add(@{ Path = $key; Name = $p.Name }) }
            }
        }
    }
    $services = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
        Test-EdgeBrowserServiceReference $_.PathName
    })
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.Actions.Count -gt 0 -and
            @($_.Actions | Where-Object { -not (Test-EdgeBrowserReference $_.Execute) }).Count -eq 0
    })
    return [PSCustomObject]@{
        Executables = @($EdgeBrowserRoots | ForEach-Object { Join-Path $_ 'Application\msedge.exe' } | Where-Object { Test-Path -LiteralPath $_ })
        Registrations = $registrations
        Files = @($EdgeBrowserFiles | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
        RegistryKeys = @($registryKeys.ToArray())
        RegistryValues = @($values.ToArray())
        Services = $services
        Tasks = $tasks
    }
}

function Test-EdgeBrowserAbsent {
    param($Inventory)
    return ($Inventory.Executables.Count + $Inventory.Registrations.Count + $Inventory.Files.Count +
        $Inventory.RegistryKeys.Count + $Inventory.RegistryValues.Count + $Inventory.Services.Count + $Inventory.Tasks.Count) -eq 0
}

function Get-WebView2Runtime {
    $id = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    foreach ($location in @(
        @{ Key = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$id"; Root = ${env:ProgramFiles(x86)} },
        @{ Key = "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$id"; Root = $env:LOCALAPPDATA }
    )) {
        if (-not (Test-Path -LiteralPath $location.Key)) { continue }
        $pv = (Get-ItemProperty -LiteralPath $location.Key -ErrorAction Stop).pv
        $version = $null
        if (-not [version]::TryParse([string]$pv, [ref]$version) -or $version -le [version]'0.0.0.0') { continue }
        $exe = Join-Path $location.Root "Microsoft\EdgeWebView\Application\$pv\msedgewebview2.exe"
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            return [PSCustomObject]@{ Version = $version; Executable = $exe }
        }
    }
    throw '未发现有效的 Evergreen WebView2 注册与运行文件；请先通过官方安装器或 winget 就绪运行时。'
}

function Invoke-EdgeBrowserRemoval {
    $null = Get-WebView2Runtime
    $inventory = Get-EdgeBrowserInventory
    if ($inventory.Executables.Count -gt 0 -or $inventory.Registrations.Count -gt 0) {
        $installers = @($inventory.Registrations | ForEach-Object {
            if ($_.UninstallString -notmatch '^"([^"]+\\setup\.exe)"\s+.*--uninstall(?:\s|$)') {
                throw 'Edge 原厂卸载登记无效；未删除浏览器文件。'
            }
            $path = $Matches[1]
            $allowed = @($EdgeBrowserRoots | Where-Object {
                $path -match ('(?i)^' + [regex]::Escape($_) + '\\Application\\\d+(?:\.\d+){3}\\Installer\\setup\.exe$')
            })
            if ($allowed.Count -eq 0 -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw 'Edge 卸载器不在受控的浏览器版本目录；未删除浏览器文件。'
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)CN=Microsoft Corporation(?:,|$)') {
                throw 'Edge 卸载器 Microsoft 签名校验失败。'
            }
            $path
        } | Select-Object -Unique)
        if ($installers.Count -ne 1) { throw '无法唯一定位 Edge 原厂卸载器；未删除浏览器文件。' }

        $runningEdge = @(Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'msedge')
        if ($runningEdge.Count -gt 0) {
            throw 'Edge 当前仍在运行；请保存工作并退出所有 Edge 窗口后重新巡检。'
        }
        $stubDir = Join-Path $env:SystemRoot 'SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe'
        $stubFile = Join-Path $stubDir 'MicrosoftEdge.exe'
        $createdDir = -not (Test-Path -LiteralPath $stubDir)
        $createdFile = -not (Test-Path -LiteralPath $stubFile)
        try {
            # 社区卸载解锁：临时提供旧版 Edge 占位文件，不覆盖既有对象。
            if ($createdDir) { New-Item -ItemType Directory -Path $stubDir -ErrorAction Stop | Out-Null }
            if ($createdFile) { New-Item -ItemType File -Path $stubFile -ErrorAction Stop | Out-Null }
            if (@(Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'msedge').Count -gt 0) {
                throw 'Edge 在卸载前重新启动；请保存工作并退出后重试。'
            }
            $process = Start-Process -FilePath $installers[0] -ArgumentList '--uninstall --msedge --system-level --force-uninstall --delete-profile' -PassThru -ErrorAction Stop
            if (-not $process.WaitForExit(120000)) {
                throw 'Edge 卸载超过 120 秒；请等待卸载完成后重新巡检。'
            }
            # Edge 卸载器在成功移除后仍可能返回 19；不单凭退出码判定，终态由下方清单核验。
            if ($process.ExitCode -notin @(0, 19)) { throw "Edge 卸载器退出码 $($process.ExitCode)；未达到受控终态。" }
        } finally {
            if ($createdFile -and (Test-Path -LiteralPath $stubFile)) { Remove-Item -LiteralPath $stubFile -Force -ErrorAction Stop }
            if ($createdDir -and (Test-Path -LiteralPath $stubDir)) { [IO.Directory]::Delete($stubDir, $false) }
        }
        $inventory = Get-EdgeBrowserInventory
        if ($inventory.Executables.Count -gt 0 -or $inventory.Registrations.Count -gt 0) {
            throw '原厂卸载后 Edge 本体或安装登记仍存在；未进入残留清理。'
        }
    }
    $null = Get-WebView2Runtime
    foreach ($service in $inventory.Services) {
        if ($service.State -ne 'Stopped') { Stop-Service -Name $service.Name -ErrorAction Stop }
        & sc.exe delete $service.Name
        if ($LASTEXITCODE -ne 0) { throw "注销 Edge 专属服务失败：$($service.Name)" }
    }
    foreach ($task in $inventory.Tasks) {
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
    }
    foreach ($value in $inventory.RegistryValues) { Remove-ItemProperty -LiteralPath $value.Path -Name $value.Name -ErrorAction SilentlyContinue }
    foreach ($key in $inventory.RegistryKeys) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop }
    foreach ($file in $inventory.Files) { Remove-Item -LiteralPath $file -Recurse -Force -ErrorAction Stop }
    if (-not (Test-EdgeBrowserAbsent (Get-EdgeBrowserInventory))) { throw 'Edge 受控残留未清理完毕。' }
    $null = Get-WebView2Runtime
    Write-Host 'Edge 浏览器及受控残留已移除，WebView2 注册与运行文件保留；依赖应用渲染仍需实机验收。' -ForegroundColor Green
}

function Get-OfficeAsrState {
    $mp = Get-MpPreference -ErrorAction Stop
    if ($null -eq $mp) { throw '无法读取 Defender 配置。' }
    $ids = @($mp.AttackSurfaceReductionRules_Ids)
    $actions = @($mp.AttackSurfaceReductionRules_Actions)
    if ($ids.Count -ne $actions.Count) { throw 'Defender ASR 标识与动作列表不完整。' }
    $action = '<未配置>'
    for ($i = 0; $i -lt $ids.Count; $i++) {
        if ($ids[$i] -eq 'd4f940ab-401b-4efc-aadc-ad5f3c50688a') { $action = [string]$actions[$i]; break }
    }
    return @{ Actual = $action; Expected = '1 (Block)'; IsCompliant = ($action -in @('1', 'Enabled')) }
}

function Get-ManagedAppxInventory {
    param([string[]]$Names)
    return [pscustomobject]@{
        Registered = @(Get-AppxPackage -AllUsers -PackageTypeFilter Main, Bundle -ErrorAction Stop | Where-Object { $_.Name -cin $Names -and -not $_.NonRemovable })
        Provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -cin $Names })
    }
}

function Remove-ManagedAppx {
    param([string[]]$Names)
    $inventory = Get-ManagedAppxInventory $Names
    $bundles = @($inventory.Registered | Where-Object IsBundle)
    $standalone = @($inventory.Registered | Where-Object { -not $_.IsBundle -and $_.PackageFamilyName -notin $bundles.PackageFamilyName })
    # 预配登记必须先移除：用户注册的 -AllUsers 卸载会删除 WindowsApps 内的暂存载荷，
    # 之后 DISM 无法初始化包适配器而返回 0x80070003。
    foreach ($package in $inventory.Provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
        } catch {
            throw "预配包 $($package.PackageName) 移除失败：$($_.Exception.Message)"
        }
    }
    foreach ($package in @($bundles) + @($standalone)) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            throw "注册包 $($package.PackageFullName) 移除失败：$($_.Exception.Message)"
        }
    }
    $after = Get-ManagedAppxInventory $Names
    if ($after.Registered.Count + $after.Provisioned.Count -gt 0) {
        throw '目标 Appx 注册包或预配包仍存在；未报告完成。'
    }
}

$ConsumerAppxNames = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GamingApp',
    'Microsoft.XboxApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.XboxGameOverlay', 'Microsoft.Xbox.TCUI',
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps',
    'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice', 'Microsoft.Windows.Ai.Copilot.Provider',
    'Microsoft.Copilot', 'Microsoft.OutlookForWindows', 'Clipchamp.Clipchamp',
    'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.549981C3F5F10',
    'MicrosoftTeams', 'MSTeams', 'Microsoft.BingSearch', 'Microsoft.Windows.DevHome'
)

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 目的与影响明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "uwp-consumer-bloatware"
        Name    = "消费级 Appx 清理（明确的 31 项清单）"
        Purpose = "移除目标应用的现有用户注册与系统预配包"
        Impact  = "目标应用及其本地应用数据可能被移除；不停止 OneDrive，不按名称片段扩张包清单"
        Check   = {
            $inventory = Get-ManagedAppxInventory $ConsumerAppxNames
            return @{
                Actual = "注册包=$($inventory.Registered.Count), 预配包=$($inventory.Provisioned.Count)"
                Expected = '注册包=0, 预配包=0'
                IsCompliant = ($inventory.Registered.Count + $inventory.Provisioned.Count -eq 0)
            }
        }
        Apply   = { Remove-ManagedAppx $ConsumerAppxNames }
    },
    [PSCustomObject]@{
        Id      = "fod-legacy-capabilities"
        Name    = "不使用的按需功能移除（明确的 10 项清单）"
        Purpose = "移除不使用的媒体、文档查看、录制、数学识别、SSH 服务端、同步、传真扫描和远程协助能力；不以仍受支持等同于本基线必需"
        Impact  = "移除经典 WMP、写字板、步骤记录器、XPS、数学识别、OpenSSH Server、OneSync、Fax/Scan、IE 和旧 Quick Assist capability；相关媒体、RTF/XPS、同步、传真扫描及远程入口不可用，不删除用户文档"
        Check   = {
            $fodList = @(
                "Media.WindowsMediaPlayer~~~~0.0.12.0", "Microsoft.Windows.WordPad~~~~0.0.1.0",
                "App.StepsRecorder~~~~0.0.1.0", "XPS.Viewer~~~~0.0.1.0",
                "MathRecognizer~~~~0.0.1.0", "OpenSSH.Server~~~~0.0.1.0",
                "OneCoreUAP.OneSync~~~~0.0.1.0", "Print.Fax.Scan~~~~0.0.1.0",
                "Browser.InternetExplorer~~~~0.0.11.0", "App.Support.QuickAssist~~~~0.0.1.0"
            )
            $installed = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { ($fodList -contains $_.Name) -and ($_.State -notin @('NotPresent', 'Removed')) })
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
            $capabilities = @(Get-WindowsCapability -Online -ErrorAction Stop)
            foreach ($f in $fodList) {
                $cap = $capabilities | Where-Object Name -eq $f
                if ($cap -and $cap.State -eq 'Installed') {
                    $result = Remove-WindowsCapability -Online -Name $f -ErrorAction Stop
                    if ($result.RestartNeeded) {
                        Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData "按需功能 [$f] 已接受移除请求；需要重启后重新巡检。"
                    }
                }
            }
            $after = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
                ($fodList -contains $_.Name) -and ($_.State -notin @('NotPresent', 'Removed'))
            })
            if ($after.Count -gt 0) {
                throw "FOD 移除后尚未达到缺失终态：$($after.Name -join ', ')"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "cbs-legacy-optional-features"
        Name    = "淘汰 CBS 可选特性禁用 (SMBv1/PSv2/Telnet/TFTP等8项)"
        Purpose = "禁用存在已知高危远程溢出风险的淘汰协议特性 (SMB1、Telnet、TFTP、PSv2)"
        Impact  = "若局域网内存在 15 年前上古 NAS 设备仅支持旧版 SMBv1 协议共享文件，禁用后将无法通过网络邻居连接该老旧设备"
        Check   = {
            $cbsFeatures = @(
                "SMB1Protocol", "MicrosoftWindowsPowerShellV2Root", "MicrosoftWindowsPowerShellV2",
                "TelnetClient", "TFTP", "SimpleTCP", "TIFFIFilter", "WCF-NonHTTP-Activation"
            )
            $enabled = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { ($cbsFeatures -contains $_.FeatureName) -and ($_.State -eq 'Enabled') })
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
            $features = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)
            foreach ($c in $cbsFeatures) {
                $feat = $features | Where-Object FeatureName -eq $c
                if ($feat -and $feat.State -eq 'Enabled') {
                    $result = Disable-WindowsOptionalFeature -Online -FeatureName $c -NoRestart -ErrorAction Stop
                    if ($result -and $result.RestartNeeded) {
                        Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData "可选特性 [$c] 已接受禁用请求；需要重启后重新巡检。"
                    }
                }
            }
            $after = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object {
                ($cbsFeatures -contains $_.FeatureName) -and ($_.State -eq 'Enabled')
            })
            if ($after.Count -gt 0) {
                throw "CBS 可选特性禁用后尚未达到终态：$($after.FeatureName -join ', ')"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "dism-disable-reserved-storage"
        Name    = "系统保留存储禁用 (DISM Reserved Storage，释放 7GB+ 固态物理空间)"
        Purpose = "禁用 Windows Update 强占的 7GB 固态硬盘保留存储，释放巨额系统根盘物理空间"
        Impact  = "系统盘若处于极限严重空间不足（剩余容量低于 2GB）时，后续大版本补丁更新可能提示磁盘空间不足需先手动腾出空间"
        Check   = {
            $res = Get-WindowsReservedStorageState -ErrorAction Stop
            $state = if ($null -ne $res -and $null -ne $res.ReservedStorageState) { "$($res.ReservedStorageState)" } else { "Unknown" }
            if ($state -notin @('Enabled', 'Disabled')) { throw '保留存储状态无法确认。' }
            $isPass = ($state -eq 'Disabled')
            return @{ Actual = $state; Expected = "Disabled"; IsCompliant = $isPass }
        }
        Apply   = {
            Set-WindowsReservedStorageState -State Disabled -ErrorAction Stop | Out-Null
            $after = Get-WindowsReservedStorageState -ErrorAction Stop
            $afterState = if ($null -ne $after -and $null -ne $after.ReservedStorageState) { "$($after.ReservedStorageState)" } else { "Unknown" }
            if ($afterState -ne 'Disabled') {
                throw "系统保留存储禁用后状态校验失败：$afterState"
            }
        }
    },
    [PSCustomObject]@{
        Id      = "storage-sense-disable-policy"
        Name    = "存储感知企业组策略禁用 (Storage Sense AllowStorageSense = 0)"
        Purpose = "组策略级关闭存储感知静默删除用户下载文件或脱水云端文档的行为，保持数据受控"
        Impact  = "不再使用 Storage Sense 自动清理临时文件或回收站；该功能默认并不自动清理下载文件，云内容脱水取决于配置"
        Check   = {
            $val = Get-RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSense"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSense" 0
        }
    },
    [PSCustomObject]@{
        Id      = "lsa-runasppl-protection"
        Name    = "LSA 保护配置 (RunAsPPL = 2，无新增 UEFI 锁)"
        Purpose = "在 Windows 11 22H2 及以后启用 LSA 保护，不新增固件锁"
        Impact  = "需重启；可能影响不兼容的认证插件。只核验配置值，不证明运行态保护，不解除已有 UEFI 锁"
        Check   = {
            $value = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
            return @{ Actual = $value; Expected = '2 (配置值，运行态待验)'; IsCompliant = (Test-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL' 2) }
        }
        Apply   = {
            Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL' 2
            Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData 'LSA 保护配置已写入；重启后验证保护状态与认证插件。未解除已有 UEFI 锁。'
        }
    },
    [PSCustomObject]@{
        Id      = "wdigest-disable-logon-credential"
        Name    = "WDigest 协议内存明文凭据缓存切断 (UseLogonCredential = 0)"
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
        Name    = "Defender ASR：阻断 Office 创建子进程"
        Purpose = "阻断 Office 文档触发子进程执行链；LSASS 保护由 LSA 主线负责"
        Impact  = "依赖 Office 启动外部程序的工作流可能受限；要求 Defender 防病毒处于适用状态，配置不证明运行效果"
        Check   = { Get-OfficeAsrState }
        Apply   = {
            Add-MpPreference -AttackSurfaceReductionRules_Ids 'd4f940ab-401b-4efc-aadc-ad5f3c50688a' -AttackSurfaceReductionRules_Actions Enabled -ErrorAction Stop
            if (-not (Get-OfficeAsrState).IsCompliant) { throw 'Office ASR 写入后配置校验失败。' }
        }
    },
    [PSCustomObject]@{
        Id      = "photos-app-uninstall"
        Name    = "微软照片应用与预配包移除"
        Purpose = "移除 Microsoft.Windows.Photos 注册包及预配包"
        Impact  = "图片查看与编辑改用替代应用；应用本地数据可能被卸载器移除"
        Check   = {
            $inventory = Get-ManagedAppxInventory @('Microsoft.Windows.Photos')
            return @{
                Actual = "注册包=$($inventory.Registered.Count), 预配包=$($inventory.Provisioned.Count)"
                Expected = '注册包=0, 预配包=0'
                IsCompliant = ($inventory.Registered.Count + $inventory.Provisioned.Count -eq 0)
            }
        }
        Apply   = { Remove-ManagedAppx @('Microsoft.Windows.Photos') }
    },
    [PSCustomObject]@{
        Id      = "edge-browser-removal"
        Name    = "Edge Stable 浏览器、当前用户数据与专属集成移除"
        Purpose = "通过当前原厂卸载器移除 Edge，并按浏览器路径清理专属残留；不裁剪 WebView2 与共享维护组件"
        Impact  = "永久删除当前用户 Edge 数据；运行中要求用户自行退出，脚本不强杀。依赖浏览器的 PWA 和 microsoft-edge: 链接可能失效。社区解锁可能随版本失效，不保证永不复装；失败停止本项，不转入文件粉碎"
        Check   = {
            $inventory = Get-EdgeBrowserInventory
            $isPass = Test-EdgeBrowserAbsent $inventory
            $null = Get-WebView2Runtime
            return @{
                Actual = if ($isPass) { '浏览器与受控残留已移除；WebView2 文件就绪' } else { '浏览器、数据或专属集成仍存在；WebView2 文件就绪' }
                Expected = 'Edge=Absent；WebView2 保留'
                IsCompliant = $isPass
            }
        }
        Apply   = { Invoke-EdgeBrowserRemoval }
    },
    [PSCustomObject]@{
        Id      = "webview2-runtime-allow-policy"
        Name    = "Evergreen WebView2 自动更新允许"
        Purpose = "使用官方 WebView2 更新策略允许 Evergreen 自动更新，保留共享更新器、任务与服务"
        Impact  = "更新由 Microsoft Edge Update 调度；策略值不证明更新服务健康，运行文件存在也不等于依赖应用渲染验收通过"
        Check   = {
            $value = Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
            return @{ Actual = $value; Expected = '1'; IsCompliant = ($value -eq '1') }
        }
        Apply   = {
            Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' 1
            if (-not (Test-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' 1)) {
                throw 'WebView2 自动更新策略写入后校验失败。'
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

Write-Host "`n📊 [巡检看板] 系统组件裁剪原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Select-Object 状态, 规则, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host

if ($probeErrors.Count -gt 0) {
    throw "本模块存在无法确认的属性，未执行任何写入：$($probeErrors -join '; ')"
}

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
Write-Host "`n🚀 正在单向对齐系统组件裁剪基线..." -ForegroundColor Cyan
$appliedCount = 0
$failedRules = [Collections.Generic.List[string]]::new()

foreach ($p in $PendingItems) {
    Write-Host -NoNewline ("   - 正在配置: {0} ... " -f $p.Rule.Name)
    try {
        & $p.Rule.Apply
        Write-Host -ForegroundColor Green "[OK]"
        $appliedCount++
    } catch {
        Write-Host -ForegroundColor Red "[FAIL]"
        Write-Warning "执行规则 [$($p.Rule.Name)] 失败: $($_.Exception.Message)"
        $failedRules.Add($p.Rule.Name)
    }
}

if ($failedRules.Count -gt 0) {
    throw "组件基线存在失败项：$($failedRules -join ', ')；已完成 $appliedCount / $driftCount 项，请处理失败项后重试。"
}

# 阶段 4: Report
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host ("  ✅ [组件裁剪完成] 成功对齐 {0} / {1} 项基线配置" -f $appliedCount, $driftCount) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
