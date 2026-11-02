#requires -Version 7.0
<#
.SYNOPSIS
    天翼云盘客户端

.DESCRIPTION
    天翼云盘官方 Windows 客户端自动化部署、开机项管控、防火墙安全防护与生命周期管理工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 纯净静默解包交付架构：基于官方安装包通过 7z 纯净解包展开至 D:\prog\ecloud\，彻底规避官方安装器外壳因命令行签名/时间戳认证阻断导致的弹窗与强制拉起后台流氓常驻。
    3. 安装包全生命周期管理：通过官方 API 动态探测最新版本与官方 CDN 直链，利用 aria2c 高速并发拉取，版本化缓存于临时目录并深度核验 Authenticode 数字签名；支持 -InstallerPath 离线安装。
    4. 核心系统侵入与原厂完全同构：
       - 本体：64 位客户端核心 (eCloud.exe) 与动态库生态，版本语义化精准对齐 (主干对齐算法，自适应 .0/.1 构建位)；
       - 系统：100% 对齐原厂安装目录注册索引 (HKLM WOW6432Node\ecloud -> InstallDir)；
       - 集成：Windows 卸载列表规范登记原厂元数据，UninstallString 精准指向包内官方签名的 uninst.exe，彻底根除自指向递归反模式；
       - 集成：开始菜单快捷方式物理路径校验与 Unicode 安全创建、清理公共桌面等流氓图标；
       - 网络：巡检并收敛本地 TCP/UDP 入站阻断规则的方向、配置文件、程序、协议、地址与端口，写入后回读；不修改系统默认策略；
       - 配置：跨视图 (HKCU/HKLM/WOW64) 开机常驻自启动彻底压制、资源管理器「此电脑」虚拟同步盘 CLSID 入口纯净化治理 (禁用本地同步盘)。
    5. 数据隔离与安全卸载：
       - 明确划定用户配置与凭据持久化边界 (%APPDATA%\ecloud、%LOCALAPPDATA%\ecloud)，默认下载保持系统原生 Downloads 目录；
       - 卸载由官方原生卸载核心 (uninst.exe) 承接，支持有限等待与终态独立核验；成功退役后定点清理声明的持久化配置与防火墙规则，绝不强杀用户进程或卸载器。
    6. 终端矩阵呈现与决策交互统一委派内部辅助算子 _console.ps1 闭环承接；入站阻断防火墙规则探测与收敛委派内部辅助算子 _firewall.ps1 闭环承接。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失/版本漂移则装、偏离则修)
    - Check     : 只查不改体检巡检 (只读比对受控属性 Diff)
    - Uninstall : 清洁卸载与清理声明残留 (调用官方卸载器退役并清理受控配置与缓存目录)

.PARAMETER InstallerPath
    可选，指定本地天翼云盘官方离线安装包路径。指定后优先使用离线包并核验有效数字签名，免除网络下载。

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\desktop\apps\ecloud.ps1 -Action Check

    # 交互式检查并增量对齐工程基线
    pwsh -File .\desktop\apps\ecloud.ps1

    # 使用指定离线安装包增量对齐
    pwsh -File .\desktop\apps\ecloud.ps1 -InstallerPath "D:\Downloads\ecloud_setup.exe"

    # 安全清洁卸载 (调用官方卸载器并清理声明残留)
    pwsh -File .\desktop\apps\ecloud.ps1 -Action Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall")]
    [string]$Action = "Sync",

    [string]$InstallerPath,

    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ==============================================================================
# 1. 运行时环境硬门禁与权限安全防御
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "【版本错误】本脚本已全面转向 PowerShell 7+ (pwsh)，不兼容旧版 Windows PowerShell 5.1。请使用 'pwsh' 执行本脚本。"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将受控配置与注册表错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中运行。"
}

$console = Join-Path $PSScriptRoot "_console.ps1"
if (-not (Test-Path $console)) {
    throw "未在应用域定位到核心终端交互组件: _console.ps1，请确保仓库完整性！"
}

$aria2 = Join-Path $PSScriptRoot "_aria2.ps1"
if (-not (Test-Path $aria2)) {
    throw "未在应用域定位到核心下载引擎: _aria2.ps1，请确保仓库完整性！"
}

$firewall = Join-Path $PSScriptRoot "_firewall.ps1"
if (-not (Test-Path $firewall)) {
    throw "未在应用域定位到核心防火墙工具: _firewall.ps1，请确保仓库完整性！"
}

# ==============================================================================
# 2. 应用元数据与部署基准路径锁定 (Golden Baseline Paths)
# ==============================================================================
$AppId        = "ecloud"
$AppName      = "天翼云盘客户端"
$ProcessNames = @("eCloud", "ecloudUMountDisk", "eCloudUDiskLauncher")

$InstallDir   = "D:\prog\ecloud"
$AppExe       = Join-Path $InstallDir "eCloud.exe"

$startMenuDir = [Environment]::GetFolderPath("Programs")
$startMenuLnk = Join-Path $startMenuDir "天翼云盘.lnk"

# 跨视图注册表路径定义 (涵盖 HKCU、原生 64 位 HKLM 与 32 位 WOW6432Node)
$runKeyCandidatePaths = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
)
$runKeyName = "ecloud"

# 核心原厂注册表定位项 (与官方安装器 100% 同构)
$hklmAppKey = "HKLM:\SOFTWARE\WOW6432Node\ecloud"
$officialUninstallKey = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\天翼云盘"

$uninstallRegCandidates = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\天翼云盘",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\天翼云盘",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\天翼云盘",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ecloud",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ecloud",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\ecloud"
)

$syncDiskNamespacePaths = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace"
)

# 防火墙安全入站阻断规则规格 (全网段入站阻断，消除弹窗与端口暴露面)
$fwRules = @(
    @{ Name = "eCloud-Client-Block-In-TCP"; Program = $AppExe; Protocol = "TCP"; Desc = "天翼云盘客户端 TCP 入站阻断" },
    @{ Name = "eCloud-Client-Block-In-UDP"; Program = $AppExe; Protocol = "UDP"; Desc = "天翼云盘客户端 UDP 入站阻断" }
)

function Get-AppFirewallState {
    param([hashtable]$Spec)
    & $firewall -Task GetState -Spec $Spec
}

function Sync-AppFirewallRules {
    param([object[]]$Specs)
    & $firewall -Task SyncRules -Specs $Specs
}

$HighValueUserData = @(
    "$env:APPDATA\ecloud (用户登录凭据、传输历史与账号配置)",
    "$env:LOCALAPPDATA\ecloud (本地缓存与索引数据)"
)

function Compare-VersionAligned {
    param(
        [string]$LocalVer,
        [string]$TargetVer
    )
    if ([string]::IsNullOrWhiteSpace($LocalVer) -or [string]::IsNullOrWhiteSpace($TargetVer)) {
        return $false
    }
    if ($LocalVer -eq $TargetVer) { return $true }

    $locClean = ($LocalVer -split '\s+')[0].Trim()
    $tgtClean = ($TargetVer -split '\s+')[0].Trim()

    $vLoc = $null; $vTgt = $null
    if ([version]::TryParse($locClean, [ref]$vLoc) -and [version]::TryParse($tgtClean, [ref]$vTgt)) {
        return ($vLoc -ge $vTgt)
    }

    $locParts = $locClean.Split('.')
    $tgtParts = $tgtClean.Split('.')

    # 若云端基准为 3 段 (如 7.2.4)，本地主干前 3 段匹配即判定对齐 (兼容本地私有构建位 .0、.1 等)
    if ($tgtParts.Length -eq 3 -and $locParts.Length -ge 3) {
        if ($locParts[0] -eq $tgtParts[0] -and $locParts[1] -eq $tgtParts[1] -and $locParts[2] -eq $tgtParts[2]) {
            return $true
        }
    }

    # 逐位数值比对：本地大于等于目标即判定为已对齐或更新
    $maxLen = [Math]::Max($locParts.Length, $tgtParts.Length)
    for ($i = 0; $i -lt $maxLen; $i++) {
        $p1 = if ($i -lt $locParts.Length) { [int]($locParts[$i] -replace '\D') } else { 0 }
        $p2 = if ($i -lt $tgtParts.Length) { [int]($tgtParts[$i] -replace '\D') } else { 0 }
        if ($p1 -gt $p2) { return $true }
        if ($p1 -lt $p2) { return $false }
    }
    return $true
}

function Save-ShortcutUnicode {
    param(
        [Parameter(Mandatory = $true)][string]$LnkPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$WorkingDir,
        [string]$Description,
        [string]$IconLocation
    )
    $dir = Split-Path -Path $LnkPath -Parent
    Ensure-Dir $dir
    $tempName = "_temp_$([Guid]::NewGuid().ToString('N')).lnk"
    $tempLnk = Join-Path $dir $tempName

    try {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($tempLnk)
        $sc.TargetPath = $TargetPath
        if ($WorkingDir) { $sc.WorkingDirectory = $WorkingDir }
        if ($Description) { $sc.Description = $Description }
        if ($IconLocation) { $sc.IconLocation = $IconLocation }
        $sc.Save()

        Move-Item -LiteralPath $tempLnk -Destination $LnkPath -Force
    } finally {
        if (Test-Path -LiteralPath $tempLnk) {
            Remove-Item -LiteralPath $tempLnk -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ShortcutTargetUnicode {
    param([string]$LnkPath)
    if (-not (Test-Path $LnkPath)) { return $null }
    try {
        $dir = Split-Path -Path $LnkPath -Parent
        $leaf = Split-Path -Path $LnkPath -Leaf
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace($dir)
        $item = $folder.ParseName($leaf)
        if ($item -and $item.GetLink) {
            return $item.GetLink.Target.Path
        }
    } catch { }
    return $null
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Ensure-RegKey {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null }
}

function Get-Cloud189LatestInfo {
    param([switch]$ThrowOnFailure)

    $apiUrl = "https://cloud.189.cn/api/portal/getClientByType.action?clientType=TELEPC"
    try {
        $resp = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 15 -ErrorAction Stop
        if ($resp -and $resp.res_code -eq 0 -and $resp.clientVO) {
            $ver = [string]$resp.clientVO.clientVersion
            $dlUrl = [string]$resp.clientVO.downloadUrl
            if ($dlUrl.StartsWith("//")) { $dlUrl = "https:" + $dlUrl }
            return @{
                Version     = $ver
                DownloadUrl = $dlUrl
                Size        = [long]$resp.clientVO.size
            }
        }
        throw "API 响应格式异常，未包含有效 clientVO 数据"
    } catch {
        if ($ThrowOnFailure) {
            throw "从天翼云盘官方 API 获取版本信息失败: $_"
        }
    }
    return $null
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Description = "文件",
        [long]$MinBytes = 1024,
        [int]$TimeoutSec = 300
    )

    & $aria2 -Url $Url -OutFile $OutFile -Description $Description -MinBytes $MinBytes -TimeoutSec $TimeoutSec
}

function Get-SyncDiskNamespaceEntries {
    $paths = if ($null -ne (Get-Variable -Name 'syncDiskNamespacePaths' -Scope 1 -ErrorAction SilentlyContinue)) {
        $syncDiskNamespacePaths
    } elseif ($null -ne (Get-Variable -Name 'syncDiskNamespacePaths' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:syncDiskNamespacePaths
    } else {
        @(
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace"
        )
    }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($nsPath in $paths) {
        if (Test-Path -LiteralPath $nsPath) {
            $subKeys = Get-ChildItem -LiteralPath $nsPath -ErrorAction SilentlyContinue
            foreach ($k in $subKeys) {
                try {
                    $item = Get-Item -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                    $val = if ($null -ne $item) {
                        if ($item -is [Microsoft.Win32.RegistryKey]) {
                            [string]$item.GetValue('')
                        } elseif ($item.PSObject.Properties['(default)']) {
                            [string]$item.'(default)'
                        } else { '' }
                    } else { '' }
                    if ($val -match "天翼云盘|ecloud") {
                        $found.Add($k.PSChildName)
                    }
                } catch { }
            }
        }
    }
    return ,$found.ToArray()
}

function Clean-SyncDiskNamespace {
    $paths = if ($null -ne (Get-Variable -Name 'syncDiskNamespacePaths' -Scope 1 -ErrorAction SilentlyContinue)) {
        $syncDiskNamespacePaths
    } elseif ($null -ne (Get-Variable -Name 'syncDiskNamespacePaths' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:syncDiskNamespacePaths
    } else {
        @(
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace"
        )
    }
    foreach ($nsPath in $paths) {
        if (Test-Path -LiteralPath $nsPath) {
            $subKeys = Get-ChildItem -LiteralPath $nsPath -ErrorAction SilentlyContinue
            foreach ($k in $subKeys) {
                try {
                    $item = Get-Item -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                    $val = if ($null -ne $item) {
                        if ($item -is [Microsoft.Win32.RegistryKey]) {
                            [string]$item.GetValue('')
                        } elseif ($item.PSObject.Properties['(default)']) {
                            [string]$item.'(default)'
                        } else { '' }
                    } else { '' }
                    if ($val -match "天翼云盘|ecloud") {
                        Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } catch { }
            }
        }
    }
}

function Get-ECloudUninstallRegistration {
    $candidates = if ($null -ne (Get-Variable -Name 'uninstallRegCandidates' -Scope 1 -ErrorAction SilentlyContinue)) {
        $uninstallRegCandidates
    } elseif ($null -ne (Get-Variable -Name 'uninstallRegCandidates' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:uninstallRegCandidates
    } else {
        @(
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\天翼云盘",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\天翼云盘",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\天翼云盘",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ecloud",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ecloud",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\ecloud"
        )
    }
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            if ($null -ne $item) {
                $uninstStr = if ($item.PSObject.Properties['UninstallString']) { [string]$item.UninstallString } else { '' }
                $dispName  = if ($item.PSObject.Properties['DisplayName']) { [string]$item.DisplayName } else { '' }
                $dispVer   = if ($item.PSObject.Properties['DisplayVersion']) { [string]$item.DisplayVersion } else { '' }
                $loc       = if ($item.PSObject.Properties['InstallLocation']) { [string]$item.InstallLocation } else { '' }
                $isSelfRef = ($uninstStr -like '*ecloud.ps1*')
                $results.Add([pscustomobject]@{
                    Path              = $path
                    DisplayName       = $dispName
                    DisplayVersion    = $dispVer
                    UninstallString   = $uninstStr
                    InstallLocation   = $loc
                    IsSelfReferencing = $isSelfRef
                })
            }
        }
    }
    return $results.ToArray()
}

function Remove-SelfReferencingUninstall {
    $registrations = Get-ECloudUninstallRegistration
    foreach ($reg in $registrations) {
        if ($reg.IsSelfReferencing) {
            Write-Host "   - 正在清除残留的自指向卸载注册表项 ($($reg.Path))..." -ForegroundColor DarkGray
            Remove-Item -LiteralPath $reg.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==============================================================================
# 3. 独立流转分支：清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    $proceed = & $console -Task ConfirmUninstall -AppName $AppName -UserDataList $HighValueUserData -Yes:$Yes
    if (-not $proceed) {
        Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在调用官方卸载器并清理天翼云盘受控基线..." -ForegroundColor Yellow

    # 1. 运行态并发防覆写硬门禁
    if (Get-Process -ErrorAction Stop | Where-Object ProcessName -in $ProcessNames) {
        throw '天翼云盘仍在运行，请结束传输并退出应用后重新执行卸载。'
    }

    # 2. 清除残留的自指向卸载项，防止 BCU 递归调用
    Remove-SelfReferencingUninstall

    # 3. 原生卸载器调用与终态独立核验
    $uninstExe = Join-Path $InstallDir "uninst.exe"
    if (Test-Path -LiteralPath $uninstExe) {
        Write-Host "🔄 正在调用官方原生卸载核心 (uninst.exe /S)..." -ForegroundColor Cyan
        $cleanDir = $InstallDir.TrimEnd('\')
        $uninstArgs = @("/S", "_?=$cleanDir")
        $p = Start-Process -FilePath $uninstExe -ArgumentList $uninstArgs -PassThru -ErrorAction Stop
        if (-not $p.WaitForExit(60000)) {
            throw '天翼云盘官方卸载器执行超过 60 秒未退出；请排查卸载器界面或重试。'
        }
        if ($p.ExitCode -ne 0) {
            throw "天翼云盘官方卸载器异常退出 (退出代码 $($p.ExitCode))；未清理声明残留。"
        }
    }

    # 4. 独立核验本体是否已完全退出与退役 (含 NSIS 异步解除轮询)
    $retries = 0
    while ($retries -lt 20 -and (Test-Path -LiteralPath $AppExe)) {
        Start-Sleep -Milliseconds 500
        $retries++
    }
    if (Test-Path -LiteralPath $AppExe) {
        throw '天翼云盘卸载命令已执行，但核心文件仍存在；请排查卸载状态。'
    }

    # 5. 注销开始菜单快捷方式与公共图标残留
    if (Test-Path $startMenuLnk) {
        Remove-Item -Path $startMenuLnk -Force -ErrorAction SilentlyContinue
        Write-Host "✔ 已移除开始菜单快捷方式。" -ForegroundColor Green
    }
    $publicDesktopLnk = 'C:\Users\Public\Desktop\天翼云盘.lnk'
    if (Test-Path $publicDesktopLnk) {
        Remove-Item -Path $publicDesktopLnk -Force -ErrorAction SilentlyContinue
    }
    $commonProgramsDir = "$([Environment]::GetFolderPath('CommonPrograms'))\天翼云盘"
    if (Test-Path $commonProgramsDir) {
        Remove-Item -Path $commonProgramsDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 6. 跨视图清除开机自启动项
    foreach ($rPath in $runKeyCandidatePaths) {
        if (Get-ItemProperty -Path $rPath -Name $runKeyName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $rPath -Name $runKeyName -Force -ErrorAction SilentlyContinue
            Write-Host "✔ 已清除开机自启项 ($rPath)。" -ForegroundColor Green
        }
    }

    # 7. 清理核心原厂注册表项与卸载登记项
    if (Test-Path -LiteralPath $hklmAppKey) {
        Remove-Item -LiteralPath $hklmAppKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✔ 已注销核心原厂定位项 ($hklmAppKey)。" -ForegroundColor Green
    }
    foreach ($path in $uninstallRegCandidates) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 8. 注销防火墙规则
    foreach ($fw in $fwRules) {
        if (Get-NetFirewallRule -Name $fw.Name -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -Name $fw.Name -ErrorAction SilentlyContinue
            Write-Host "✔ 已移除防火墙规则 ($($fw.Name))。" -ForegroundColor Green
        }
    }

    # 9. 清理资源管理器虚拟盘入口
    Clean-SyncDiskNamespace

    # 10. 清理程序本体残留目录 (若有空目录)
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✔ 软件本体残留目录已清除。" -ForegroundColor Green
    }

    # 11. 声明配置与缓存目录清理 (默认清洁退役)
    foreach ($d in @("$env:APPDATA\ecloud", "$env:LOCALAPPDATA\ecloud")) {
        if (Test-Path -LiteralPath $d) {
            $item = Get-Item -LiteralPath $d -Force -ErrorAction Stop
            if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   - 已清理声明配置与缓存目录: $d" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host "`n✅ [清洁卸载完成] 天翼云盘客户端本体已退役，声明残留已审计清理。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1 & 2: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 部署路径: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $InstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

# 4.1 嗅探实机程序状态与版本
$isInstalled = Test-Path $AppExe
$installedVersion = $null
if ($isInstalled) {
    try {
        $rawVer = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($AppExe).FileVersion
        if ($rawVer) {
            $installedVersion = ($rawVer -split '\s+')[0].Trim()
        }
    } catch {
        $installedVersion = "未知版本"
    }
}

# 4.2 嗅探云端最新版本 (Sync 模式且未指定离线安装包时实行 Fail-Fast 硬阻断)
$latestInfo = $null
if (-not $InstallerPath -or -not (Test-Path -LiteralPath $InstallerPath)) {
    $latestInfo = Get-Cloud189LatestInfo -ThrowOnFailure:($Action -eq "Sync" -and (-not $isInstalled))
}
$targetVersion = if ($InstallerPath -and (Test-Path -LiteralPath $InstallerPath)) {
    try {
        $pkgVer = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($InstallerPath).FileVersion
        if ($pkgVer) { ($pkgVer -split '\s+')[0].Trim() } else { "离线包" }
    } catch { "离线包" }
} elseif ($latestInfo) {
    ($latestInfo.Version -split '\s+')[0].Trim()
} elseif ($installedVersion) {
    $installedVersion
} else {
    "<需联网探测>"
}

# 4.3 嗅探开始菜单快捷方式物理指向终态 (Unicode 安全解析)
$actualLnkTarget = Get-ShortcutTargetUnicode -LnkPath $startMenuLnk
$hasLnk = Test-Path $startMenuLnk
$isLnkAligned = ($hasLnk -and $actualLnkTarget -and (($actualLnkTarget -replace '/', '\') -eq $AppExe))

# 4.4 跨视图深度融合探测开机自启动项 (防单视图短路)
$activeRunEntries = [System.Collections.Generic.List[string]]::new()
foreach ($rPath in $runKeyCandidatePaths) {
    $prop = Get-ItemProperty -Path $rPath -Name $runKeyName -ErrorAction SilentlyContinue
    if ($null -ne $prop -and $null -ne $prop.$runKeyName) {
        $activeRunEntries.Add("$rPath -> $([string]$prop.$runKeyName)")
    }
}
$hasRunDrift = ($activeRunEntries.Count -gt 0)
$actualRunDesc = if ($hasRunDrift) { ($activeRunEntries -join "; ") } else { "已清除 (禁用自启)" }

# 4.5 嗅探核心原厂定位项 (HKLM WOW6432Node\ecloud -> InstallDir)
$hklmAppProp = Get-ItemProperty -Path $hklmAppKey -ErrorAction SilentlyContinue
$isHklmAppAligned = ($isInstalled -and $null -ne $hklmAppProp -and $hklmAppProp.InstallDir -eq $InstallDir)
$actualHklmAppDesc = if ($isHklmAppAligned) {
    "已对齐 ($hklmAppKey)"
} elseif ($null -ne $hklmAppProp) {
    "偏离 ($($hklmAppProp.InstallDir))"
} elseif ($isInstalled) {
    "缺失 (需写入定位键)"
} else {
    "未安装"
}

# 4.6 跨视图嗅探 Windows 卸载注册表登记 (核验官方原厂格式、物理存在性且杜绝自指向残留)
$uninstRegistrations = Get-ECloudUninstallRegistration
$hasSelfRefUninst = (@($uninstRegistrations | Where-Object { $_.IsSelfReferencing }).Count -gt 0)
$officialUninst = @($uninstRegistrations | Where-Object { -not $_.IsSelfReferencing -and $_.Path -like '*WOW6432Node*' }) | Select-Object -First 1
$uninstExePath = Join-Path $InstallDir "uninst.exe"
$hasUninstExe = Test-Path -LiteralPath $uninstExePath -PathType Leaf
$isUninstallRegValid = ($isInstalled -and $hasUninstExe -and $null -ne $officialUninst -and -not $hasSelfRefUninst -and $officialUninst.UninstallString -match 'uninst\.exe')
$actualUninstDesc = if ($hasSelfRefUninst) {
    "存在旧自指向卸载登记 (需清理)"
} elseif ($officialUninst -and $officialUninst.UninstallString -match 'uninst\.exe' -and -not $hasUninstExe) {
    "卸载程序物理文件丢失 (uninst.exe 缺失)"
} elseif ($officialUninst -and $officialUninst.UninstallString -match 'uninst\.exe') {
    "已对齐官方卸载格式 (uninst.exe)"
} elseif ($officialUninst) {
    "存在卸载条目 ($($officialUninst.UninstallString))"
} elseif ($isInstalled) {
    "官方卸载登记缺失"
} else {
    "未安装 (无登记)"
}

# 4.7 嗅探资源管理器「此电脑」同步盘虚拟入口 (禁用同步盘基线)
$syncDiskEntries = Get-SyncDiskNamespaceEntries
$hasSyncDiskDrift = ($syncDiskEntries.Length -gt 0)
$actualSyncDiskDesc = if ($hasSyncDiskDrift) { "存在虚拟盘残留 (" + ($syncDiskEntries -join ", ") + ")" } else { "已清除 (纯净视图)" }

# 4.8 读取本地持久化规则及应用、协议、地址与端口过滤器
$fwTcpState = Get-AppFirewallState $fwRules[0]
$fwUdpState = Get-AppFirewallState $fwRules[1]

# 4.9 组装全域原子受控规格清单
$isClientAligned = ($isInstalled -and (Compare-VersionAligned -LocalVer $installedVersion -TargetVer $targetVersion))
$expectedClientVer = if ($isClientAligned) { $installedVersion } else { $targetVersion }
$Specs = @(
    [PSCustomObject]@{
        Module   = "本体"
        Property = "客户端本体 (eCloud.exe)"
        Expected = "已部署 (v$expectedClientVer)"
        Actual   = if ($isInstalled) { "已部署 (v$installedVersion)" } else { "未安装" }
        IsMatch  = $isClientAligned
        Purpose  = "通过 7z 纯净展开 64 位天翼云盘原生客户端，彻底规避官方安装器外壳弹窗与强制常驻"
        Impact   = "部署至 $InstallDir，占用物理磁盘空间约 520MB，零流氓后台常驻"
    },
    [PSCustomObject]@{
        Module   = "系统"
        Property = "原厂定位索引 (InstallDir)"
        Expected = "已对齐 ($hklmAppKey)"
        Actual   = $actualHklmAppDesc
        IsMatch  = if ($isInstalled) { $isHklmAppAligned } else { $true }
        Purpose  = "100% 对齐原厂 HKLM 注册表安装定位键，保证客户端子模块能完整检索自身安装目录"
        Impact   = "与官方安装器写入的系统索引完全同构，消除解包环境下的路径寻址异常"
    },
    [PSCustomObject]@{
        Module   = "集成"
        Property = "开始菜单启动快捷方式"
        Expected = "已对齐 ($startMenuLnk -> $AppExe)"
        Actual   = if ($isLnkAligned) { "已对齐 ($startMenuLnk -> $AppExe)" } elseif ($hasLnk) { "指向偏离 ($actualLnkTarget)" } else { "未配置" }
        IsMatch  = $isLnkAligned
        Purpose  = "向 Windows 开始菜单注册直观的启动入口与高分辨率图标索引"
        Impact   = "便于通过开始菜单或任务栏检索框进行秒级拼音检索与快速唤起"
    },
    [PSCustomObject]@{
        Module   = "集成"
        Property = "Windows 已安装应用列表登记"
        Expected = "已对齐官方卸载格式 (uninst.exe)"
        Actual   = $actualUninstDesc
        IsMatch  = if ($isInstalled) { $isUninstallRegValid } else { (-not $hasSelfRefUninst) }
        Purpose  = "对齐原厂 Uninstall 登记格式并将卸载命令指向 uninst.exe，彻底切断脚本自指向反模式"
        Impact   = "使系统设置与 BCU 能原生识别原厂卸载核心，杜绝递归循环调用与卸载挽留弹窗"
    },
    [PSCustomObject]@{
        Module   = "网络"
        Property = "防火墙 TCP 全网段入站阻断"
        Expected = "已阻断入站 (Block)"
        Actual   = if ($fwTcpState.IsMatch) { "已阻断入站 (Block)" } elseif ($fwTcpState.Exists) { "规则配置偏离" } else { "本地受控规则缺失" }
        IsMatch  = $fwTcpState.IsMatch
        Purpose  = "配置客户端本地 TCP 入站阻断规则，覆盖所有网络配置文件、地址与端口"
        Impact   = "仅管理本地应用规则；出站上传/下载不在此规则范围内，未进行实际流量验收"
    },
    [PSCustomObject]@{
        Module   = "网络"
        Property = "防火墙 UDP 全网段入站阻断"
        Expected = "已阻断入站 (Block)"
        Actual   = if ($fwUdpState.IsMatch) { "已阻断入站 (Block)" } elseif ($fwUdpState.Exists) { "规则配置偏离" } else { "本地受控规则缺失" }
        IsMatch  = $fwUdpState.IsMatch
        Purpose  = "配置客户端本地 UDP 入站阻断规则，覆盖所有网络配置文件、地址与端口"
        Impact   = "仅管理本地应用规则；规则缺失不直接等于端口暴露，仍受系统及上级策略影响"
    },
    [PSCustomObject]@{
        Module   = "配置"
        Property = "开机常驻自启动 (跨视图 Run 项)"
        Expected = "已清除 (禁用自启)"
        Actual   = $actualRunDesc
        IsMatch  = (-not $hasRunDrift)
        Purpose  = "跨原生 64 位与 32 位视图切断天翼云盘开机常驻自启动项"
        Impact   = "冷启动时不再自动拉起 500MB+ 的 CEF/Flutter 进程栈与后台轮询，释放内存与 CPU"
    },
    [PSCustomObject]@{
        Module   = "配置"
        Property = "资源管理器虚拟同步盘入口 (NameSpace)"
        Expected = "已清除 (纯净视图)"
        Actual   = $actualSyncDiskDesc
        IsMatch  = (-not $hasSyncDiskDrift)
        Purpose  = '清理并抑制资源管理器「此电脑」中未经授权的虚拟同步盘 CLSID 命名空间入口'
        Impact   = "保持资源管理器设备与驱动器列表整洁，避免死链图标与未配置挂载盘的视觉污染"
    }
)

# 渲染差异矩阵表格
& $console -Task RenderDiff -Specs $Specs

# ==============================================================================
# 5. 阶段 3: 审查门禁决策 (Gate)
# ==============================================================================
$diffs = @($Specs | Where-Object { -not $_.IsMatch })

function Assert-AppStopped {
    if (Get-Process -ErrorAction Stop | Where-Object ProcessName -in $ProcessNames) {
        throw '天翼云盘仍在运行，请结束传输并自行退出后重新执行。'
    }
}
if ($Action -eq 'Sync' -and $diffs.Count -gt 0) { Assert-AppStopped }

$proceed = & $console -Task ConfirmGate -Specs $diffs -Action $Action -Yes:$Yes -AppName $AppName
if ($Action -eq "Check" -or -not $proceed) {
    return
}

# ==============================================================================
# 6. 阶段 4: 单向原子落盘 (Apply)
# ==============================================================================
Assert-AppStopped
$appliedCount = 0

# 6.1 清理历史自指向卸载项，杜绝 BCU 递归
Remove-SelfReferencingUninstall

# 6.2 程序本体 7z 纯净解包交付与版本化缓存
$needBinaryDeploy = (-not $isInstalled) -or (-not (Compare-VersionAligned -LocalVer $installedVersion -TargetVer $targetVersion))
if ($needBinaryDeploy) {
    $installerPkg = $InstallerPath
    if (-not $installerPkg -or -not (Test-Path -LiteralPath $installerPkg)) {
        if (-not $latestInfo) {
            $latestInfo = Get-Cloud189LatestInfo -ThrowOnFailure
        }
        $targetVerClean = ($latestInfo.Version -split '\s+')[0].Trim()
        $cachedPkg = Join-Path $env:TEMP "ecloud-installer-$targetVerClean.exe"
        $isCacheHit = $false

        if (Test-Path -LiteralPath $cachedPkg) {
            $item = Get-Item -LiteralPath $cachedPkg -ErrorAction SilentlyContinue
            if ($item -and $item.Length -ge 100MB) {
                $sig = Get-AuthenticodeSignature -LiteralPath $cachedPkg -ErrorAction SilentlyContinue
                if ($sig -and $sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match '天翼数字生活科技有限公司') {
                    $isCacheHit = $true
                    Write-Host "   ✔ 命中已缓存的官方安装包: $cachedPkg ($([math]::Round($item.Length / 1MB, 1)) MB)" -ForegroundColor Green
                }
            }
            if (-not $isCacheHit) {
                Remove-Item -LiteralPath $cachedPkg -Force -ErrorAction SilentlyContinue
            }
        }

        if (-not $isCacheHit) {
            Write-Host "`n🚀 正在准备获取天翼云盘官方安装包 (v$($latestInfo.Version))..." -ForegroundColor Cyan
            Write-Host "⬇️  正在通过 aria2 并发下载 天翼云盘官方安装包 (v$($latestInfo.Version))..." -ForegroundColor Cyan
            Invoke-DownloadFile -Url $latestInfo.DownloadUrl -OutFile $cachedPkg -Description "天翼云盘官方安装包 (v$($latestInfo.Version))" -MinBytes (100 * 1024 * 1024)
        }
        $installerPkg = $cachedPkg
    } else {
        $sig = Get-AuthenticodeSignature -LiteralPath $installerPkg -ErrorAction SilentlyContinue
        if (-not $sig -or $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '天翼数字生活科技有限公司') {
            throw "指定的离线安装包 [$installerPkg] 未通过官方有效数字签名核验。"
        }
    }

    # 解包前复查运行态
    Assert-AppStopped

    # 定位 7z 引擎
    $7zExe = (Get-Command "7z.exe" -ErrorAction SilentlyContinue).Source
    if (-not $7zExe) {
        $scoopRoot = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
        $7zCandidate = Join-Path $scoopRoot "shims\7z.exe"
        if (Test-Path $7zCandidate) { $7zExe = $7zCandidate }
    }
    if (-not $7zExe -or -not (Test-Path $7zExe)) {
        throw "未找到 7z 解压引擎，请先就绪 7zip。"
    }

    Write-Host "`n📦 正在通过 7z 纯净解包天翼云盘至 $InstallDir (0 弹窗，零流氓后台常驻)..." -ForegroundColor Cyan
    Ensure-Dir $InstallDir

    $global:LASTEXITCODE = $null
    & $7zExe x $installerPkg -o"$InstallDir" -y -xr'!$PLUGINSDIR' -xr'!$TEMP' | Out-Null
    $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "7z 解包天翼云盘安装包失败 (退出代码 $exitCode)，请排查安装包或重试。"
    }

    $cleanUninstExe = Join-Path $InstallDir "uninst.exe"
    if (-not (Test-Path -LiteralPath $AppExe) -or -not (Test-Path -LiteralPath $cleanUninstExe)) {
        throw "解包完成但未能定位到核心执行文件 ($AppExe) 或卸载核心 ($cleanUninstExe)；请检查安装包完整性。"
    }

    Write-Host "✔ 天翼云盘二进制本体解包完成。" -ForegroundColor Green
    $appliedCount++
}

# 6.3 原厂注册表定位索引与 Windows 卸载登记 (100% 对齐官方结构，杜绝自指向)
if (-not $isHklmAppAligned -or -not $isUninstallRegValid -or $needBinaryDeploy) {
    Write-Host "⚙️  正在单向对齐原厂注册表定位项 ($hklmAppKey)..." -ForegroundColor Cyan
    Ensure-RegKey $hklmAppKey
    Set-ItemProperty -Path $hklmAppKey -Name "InstallDir" -Value $InstallDir -Force

    Write-Host "📝 正在规范登记 Windows 应用列表元数据 (原生对接 uninst.exe)..." -ForegroundColor Cyan
    Ensure-RegKey $officialUninstallKey

    $currentVer = if ($latestInfo) { $latestInfo.Version } else { $targetVersion }
    $cleanUninstExe = Join-Path $InstallDir "uninst.exe"

    Set-ItemProperty -Path $officialUninstallKey -Name "DisplayName" -Value "天翼云盘 $currentVer" -Force
    Set-ItemProperty -Path $officialUninstallKey -Name "DisplayVersion" -Value $currentVer -Force
    Set-ItemProperty -Path $officialUninstallKey -Name "Publisher" -Value "天翼数字生活科技有限公司" -Force
    Set-ItemProperty -Path $officialUninstallKey -Name "InstallLocation" -Value $InstallDir -Force
    Set-ItemProperty -Path $officialUninstallKey -Name "DisplayIcon" -Value "$AppExe,0" -Force
    Set-ItemProperty -Path $officialUninstallKey -Name "UninstallString" -Value $cleanUninstExe -Force

    Write-Host "✔ 原厂注册表定位项与应用列表登记完成 (杜绝自指向反模式)。" -ForegroundColor Green
    $appliedCount += 2
}

# 6.4 校准开始菜单快捷方式并跨视图压制开机自启动项
if (-not $isLnkAligned -or $needBinaryDeploy) {
    Write-Host "🔗 正在校准开始菜单快捷方式..." -ForegroundColor Cyan
    Save-ShortcutUnicode -LnkPath $startMenuLnk -TargetPath $AppExe -WorkingDir $InstallDir -Description "天翼云盘客户端" -IconLocation "$AppExe,0"
    Write-Host "✔ 开始菜单快捷方式校准完成 ($startMenuLnk)。" -ForegroundColor Green
    $appliedCount++
}
$publicDesktopLnk = 'C:\Users\Public\Desktop\天翼云盘.lnk'
if (Test-Path $publicDesktopLnk) {
    Remove-Item -Path $publicDesktopLnk -Force -ErrorAction SilentlyContinue
}
$commonProgramsDir = "$([Environment]::GetFolderPath('CommonPrograms'))\天翼云盘"
if (Test-Path $commonProgramsDir) {
    Remove-Item -Path $commonProgramsDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($hasRunDrift -or $needBinaryDeploy) {
    Write-Host "⚙️  正在清除跨视图开机常驻自启动注册表项..." -ForegroundColor Cyan
    foreach ($rPath in $runKeyCandidatePaths) {
        if (Get-ItemProperty -Path $rPath -Name $runKeyName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $rPath -Name $runKeyName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "✔ 已成功禁用天翼云盘所有开机自启动项。" -ForegroundColor Green
    $appliedCount++
}

# 6.5 治理资源管理器虚拟同步盘入口 (禁用同步盘)
if ($hasSyncDiskDrift -or $needBinaryDeploy) {
    Write-Host "🧹 正在清理资源管理器「此电脑」中的虚拟同步盘残留入口..." -ForegroundColor Cyan
    Clean-SyncDiskNamespace
    Write-Host "✔ 资源管理器同步盘虚拟入口治理完成。" -ForegroundColor Green
    $appliedCount++
}

# 6.6 按同一规格收敛本地入站阻断规则并回读
$appliedCount += Sync-AppFirewallRules -Specs $fwRules
Write-Host '✔ 本地 TCP/UDP 入站阻断规则及受控过滤器已回读核验；未验证实际流量或上级策略。' -ForegroundColor Green

# ==============================================================================
# 7. 阶段 5: 尾部简报与闭环交付 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 工程基线与策略配置完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green

# 动态真待办：若已部署但从未登录过（AppData 不存在凭据），输出高价值登录指引
$hasCredentials = Test-Path (Join-Path $env:APPDATA "ecloud")
if ((Test-Path $AppExe) -and -not $hasCredentials -and $Action -eq "Sync") {
    Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData '启动天翼云盘，使用手机客户端扫码或输入账号登录；脚本未检测到配置目录，请在应用内确认登录及同步状态。'
}
