#requires -Version 7.0
<#
.SYNOPSIS
    天翼云盘客户端

.DESCRIPTION
    天翼云盘官方 Windows 客户端自动化部署、开机项管控、防火墙安全防护与生命周期管理工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 独立原生维护架构：程序本体解包部署于 D:\prog\ecloud\，与系统盘完全解耦。
    3. 单主干确定性交付：通过官方 API 动态探测最新版本与安装包直链，利用 aria2c 高速并发拉取，经 7z 纯净解包展开，彻底规避官方安装器外壳因命令行签名/时间戳认证阻断导致的静默安装失败。
    4. 三层全域原子受控基线：
       - 程序本体层：64 位客户端核心 (eCloud.exe) 与动态库生态，版本语义化精准对齐 (主干对齐算法，自适应 .0/.1 构建位)；
       - 系统集成层：开始菜单快捷方式物理路径校验与 Unicode 安全创建、Windows 应用管理列表 (HKCU Uninstall) 规范登记；
       - 网络安全层：全网段入站连接彻底阻断 (TCP/UDP Inbound Block)，根治 Windows 防火墙打扰弹窗，消除端口暴露面；
       - 偏好策略层：跨视图 (HKCU/HKLM/WOW64) 开机常驻自启动彻底压制、资源管理器「此电脑」虚拟同步盘 CLSID 入口纯净化治理 (禁用本地同步盘)。
    5. 数据隔离与安全卸载：
       - 明确划定用户配置与凭据持久化边界 (%APPDATA%\ecloud、%LOCALAPPDATA%\ecloud)，默认下载保持系统原生 Downloads 目录；
       - 默认增量对齐 (Sync) 与清洁卸载 (Uninstall) 严格保留用户私有数据；仅在显式指定 -Purge 时执行物理粉碎；
       - 卸载流转支持原生卸载器 5 秒超时非阻塞脱钩与全权接管深度物理粉碎 (OffScrub Deep Shredding)，连带注销防火墙规则。
    6. 终端矩阵呈现与决策交互统一委派内部辅助算子 _console.ps1 闭环承接。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失/版本漂移则装、偏离则修)
    - Check     : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - Uninstall : 清洁卸载与注销系统关联 (默认保留用户持久化配置与凭据)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制重新拉取最新官方安装包覆盖解包并全量回正基线。

.PARAMETER Purge
    配合 Uninstall 使用，连带深度物理粉碎用户数据与本地凭据目录。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\ecloud.ps1 -Action Check

    # 交互式检查并增量对齐工程基线
    pwsh -File .\scripts\apps\ecloud.ps1

    # 强制重新部署覆盖本体并回正基线 (保留用户凭据)
    pwsh -File .\scripts\apps\ecloud.ps1 -Force

    # 安全清洁卸载 (保留个人凭据与下载记录)
    pwsh -File .\scripts\apps\ecloud.ps1 -Action Uninstall

    # 深度粉碎卸载 (全量抹除一切残留痕迹)
    pwsh -File .\scripts\apps\ecloud.ps1 -Action Uninstall -Purge
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall")]
    [string]$Action = "Sync",

    [switch]$Yes,
    [switch]$Force,
    [switch]$Purge
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

$uninstallRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\天翼云盘"

# 防火墙安全入站阻断规则规格 (全网段入站阻断，消除弹窗与端口暴露面)
$fwRules = @(
    @{ Name = "eCloud-Client-Block-In-TCP"; Protocol = "TCP"; Desc = "天翼云盘客户端 TCP 入站阻断" },
    @{ Name = "eCloud-Client-Block-In-UDP"; Protocol = "UDP"; Desc = "天翼云盘客户端 UDP 入站阻断" }
)

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

    $locParts = $locClean.Split('.')
    $tgtParts = $tgtClean.Split('.')

    # 若云端基准为 3 段 (如 7.2.4)，本地主干前 3 段匹配即判定对齐 (兼容本地私有构建位 .0、.1 等)
    if ($tgtParts.Length -eq 3 -and $locParts.Length -ge 3) {
        return ($locParts[0] -eq $tgtParts[0] -and $locParts[1] -eq $tgtParts[1] -and $locParts[2] -eq $tgtParts[2])
    }

    # 否则执行严格逐位数值比对 (缺位补 0)
    $maxLen = [Math]::Max($locParts.Length, $tgtParts.Length)
    for ($i = 0; $i -lt $maxLen; $i++) {
        $p1 = if ($i -lt $locParts.Length) { [int]($locParts[$i] -replace '\D') } else { 0 }
        $p2 = if ($i -lt $tgtParts.Length) { [int]($tgtParts[$i] -replace '\D') } else { 0 }
        if ($p1 -ne $p2) { return $false }
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

    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($tempLnk)
    $sc.TargetPath = $TargetPath
    if ($WorkingDir) { $sc.WorkingDirectory = $WorkingDir }
    if ($Description) { $sc.Description = $Description }
    if ($IconLocation) { $sc.IconLocation = $IconLocation }
    $sc.Save()

    Move-Item -Path $tempLnk -Destination $LnkPath -Force
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
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null }
}

function Stop-AppProcesses {
    $cleanDir = if (Test-Path $InstallDir) { $InstallDir.TrimEnd('\') } else { $null }

    # 1. 贪婪扫描：按预设进程名或加载路径命中 $InstallDir 前缀的所有进程
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            ($ProcessNames -contains $_.ProcessName) -or ($cleanDir -and $_.Path -and $_.Path.StartsWith($cleanDir, [System.StringComparison]::OrdinalIgnoreCase))
        } catch { $false }
    }

    if ($procs) {
        Write-Host "⚠️  正在安全终止天翼云盘及其关联进程 ($($procs.Count) 个实例)..." -ForegroundColor Yellow
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue

        # 2. 轮询等待进程句柄与内核文件映射段彻底释放 (最多等待 6 秒)
        $swWait = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swWait.ElapsedMilliseconds -lt 6000) {
            $remaining = Get-Process -ErrorAction SilentlyContinue | Where-Object {
                try {
                    ($ProcessNames -contains $_.ProcessName) -or ($cleanDir -and $_.Path -and $_.Path.StartsWith($cleanDir, [System.StringComparison]::OrdinalIgnoreCase))
                } catch { $false }
            }
            if (-not $remaining) {
                # 进一步测试核心文件锁是否完全释放
                $isLocked = $false
                $probeFiles = @($AppExe, (Join-Path $InstallDir "libcef.dll"), (Join-Path $InstallDir "DirectRender.dll"))
                foreach ($f in $probeFiles) {
                    if (Test-Path $f) {
                        try {
                            $st = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                            $st.Close()
                            $st.Dispose()
                        } catch {
                            $isLocked = $true
                            break
                        }
                    }
                }
                if (-not $isLocked) {
                    break
                }
            }
            Start-Sleep -Milliseconds 250
        }
    }
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
            throw "【网络探测阻断】从天翼云盘官方 API 获取版本信息失败: $_"
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
    $found = [System.Collections.Generic.List[string]]::new()
    $nsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Mycomputer\NameSpace"
    if (Test-Path $nsPath) {
        $subKeys = Get-ChildItem -Path $nsPath -ErrorAction SilentlyContinue
        foreach ($k in $subKeys) {
            $val = (Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue)."(default)"
            if ($val -match "天翼云盘|ecloud") {
                $found.Add($k.PSChildName)
            }
        }
    }
    return $found.ToArray()
}

function Clean-SyncDiskNamespace {
    $nsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Mycomputer\NameSpace"
    if (Test-Path $nsPath) {
        $subKeys = Get-ChildItem -Path $nsPath -ErrorAction SilentlyContinue
        foreach ($k in $subKeys) {
            $val = (Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue)."(default)"
            if ($val -match "天翼云盘|ecloud") {
                Remove-Item -Path $k.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ==============================================================================
# 3. 独立流转分支：清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    $proceed = & $console -Task ConfirmUninstall -AppName $AppName -UserDataList $HighValueUserData -Purge:$Purge -Yes:$Yes
    if (-not $proceed) {
        Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在终止常驻进程并清理天翼云盘系统集成..." -ForegroundColor Yellow

    # 1. 原生卸载器脱钩探测 (5秒非阻塞超时轮询)
    $uninstExe = Join-Path $InstallDir "uninst.exe"
    if (Test-Path $uninstExe) {
        Write-Host "🔄 正在尝试调用官方原生卸载器 (超时脱钩保护: 5 秒)..." -ForegroundColor Cyan
        try {
            $p = Start-Process -FilePath $uninstExe -ArgumentList "/S" -PassThru -ErrorAction SilentlyContinue
            if ($p) {
                $finished = $p.WaitForExit(5000)
                if (-not $finished) {
                    Write-Host "⚠️  官方卸载器未在超时内退出，自动强行脱钩接管..." -ForegroundColor Yellow
                    $p | Stop-Process -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }

    # 2. 脚本全权接管底层深度物理粉碎 (OffScrub Deep Shredding)
    Stop-AppProcesses

    # 3. 注销快捷方式
    if (Test-Path $startMenuLnk) {
        Remove-Item -Path $startMenuLnk -Force -ErrorAction SilentlyContinue
        Write-Host "✔ 已移除开始菜单快捷方式。" -ForegroundColor Green
    }

    # 4. 跨视图清除开机自启动项
    foreach ($rPath in $runKeyCandidatePaths) {
        if (Get-ItemProperty -Path $rPath -Name $runKeyName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $rPath -Name $runKeyName -Force -ErrorAction SilentlyContinue
            Write-Host "✔ 已清除开机自启项 ($rPath)。" -ForegroundColor Green
        }
    }

    # 5. 注销 Windows 卸载项
    if (Test-Path $uninstallRegPath) {
        Remove-Item -Path $uninstallRegPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✔ 已注销 Windows 应用管理列表登记 ($uninstallRegPath)。" -ForegroundColor Green
    }

    # 6. 注销防火墙规则
    foreach ($fw in $fwRules) {
        if (Get-NetFirewallRule -Name $fw.Name -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -Name $fw.Name -ErrorAction SilentlyContinue
            Write-Host "✔ 已移除防火墙规则 ($($fw.Name))。" -ForegroundColor Green
        }
    }

    # 7. 清理资源管理器虚拟盘入口
    Clean-SyncDiskNamespace

    # 8. 抹除程序本体目录
    if (Test-Path $InstallDir) {
        Write-Host "🗑️  正在抹除程序本体目录 ($InstallDir)..." -ForegroundColor Cyan
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✔ 软件本体目录已清除。" -ForegroundColor Green
    }

    # 9. 用户私有数据处理 (Purge 或保留提示)
    if ($Purge) {
        Write-Host "`n🔥 [-Purge] 正在深度物理粉碎用户私有数据与缓存..." -ForegroundColor Red
        foreach ($d in @("$env:APPDATA\ecloud", "$env:LOCALAPPDATA\ecloud")) {
            if (Test-Path $d) {
                Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   - 已抹除数据目录: $d" -ForegroundColor DarkGray
            }
        }
        Write-Host "✔ 用户私有数据与本地凭据已彻底粉碎。`n" -ForegroundColor Green
    } else {
        Write-Host "`n🔒 [数据安全保留] 已保留用户个人凭据与下载缓存:" -ForegroundColor Green
        foreach ($d in $HighValueUserData) {
            Write-Host "   - $d" -ForegroundColor Gray
        }
        Write-Host "👉 如需彻底抹除个人数据，请使用: pwsh -File scripts\apps\ecloud.ps1 -Action Uninstall -Purge`n" -ForegroundColor DarkGray
    }

    return
}

# ==============================================================================
# 4. 阶段 1 & 2: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

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

# 4.2 嗅探云端最新版本 (Sync 模式下实行 Fail-Fast 硬阻断)
$latestInfo = Get-Cloud189LatestInfo -ThrowOnFailure:($Action -eq "Sync" -and (-not $isInstalled -or $Force))
$targetVersion = if ($latestInfo) {
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

# 4.5 跨视图嗅探 Windows 卸载注册表登记
$uninstProp = Get-ItemProperty -Path $uninstallRegPath -ErrorAction SilentlyContinue
$isUninstallRegValid = ($null -ne $uninstProp -and $uninstProp.DisplayName -eq "天翼云盘" -and $uninstProp.InstallLocation -eq $InstallDir)

# 4.6 嗅探资源管理器「此电脑」同步盘虚拟入口 (禁用同步盘基线)
$syncDiskEntries = Get-SyncDiskNamespaceEntries
$hasSyncDiskDrift = ($syncDiskEntries.Length -gt 0)
$actualSyncDiskDesc = if ($hasSyncDiskDrift) { "存在虚拟盘残留 (" + ($syncDiskEntries -join ", ") + ")" } else { "已清除 (纯净视图)" }

# 4.7 嗅探 Windows 防火墙全网段入站阻断规则
$fwTcpRule = Get-NetFirewallRule -Name "eCloud-Client-Block-In-TCP" -ErrorAction SilentlyContinue
$isFwTcpAligned = ($null -ne $fwTcpRule -and $fwTcpRule.Action -eq "Block" -and $fwTcpRule.Enabled -eq "True")
$actualFwTcpDesc = if ($isFwTcpAligned) { "已阻断 (Any Profile)" } elseif ($fwTcpRule) { "配置偏离 ($($fwTcpRule.Action))" } else { "未配置 (可能触发拦截弹窗)" }

$fwUdpRule = Get-NetFirewallRule -Name "eCloud-Client-Block-In-UDP" -ErrorAction SilentlyContinue
$isFwUdpAligned = ($null -ne $fwUdpRule -and $fwUdpRule.Action -eq "Block" -and $fwUdpRule.Enabled -eq "True")
$actualFwUdpDesc = if ($isFwUdpAligned) { "已阻断 (Any Profile)" } elseif ($fwUdpRule) { "配置偏离 ($($fwUdpRule.Action))" } else { "未配置 (可能触发拦截弹窗)" }

# 4.8 组装全域原子受控规格清单
$Specs = @(
    [PSCustomObject]@{
        Module   = "程序本体层"
        Property = "客户端本体 (eCloud.exe)"
        Expected = "已部署 (v$targetVersion)"
        Actual   = if ($isInstalled) { "已部署 (v$installedVersion)" } else { "未安装" }
        IsMatch  = ($isInstalled -and (Compare-VersionAligned -LocalVer $installedVersion -TargetVer $targetVersion) -and -not $Force)
        Purpose  = "部署 64 位天翼云盘官方原生客户端核心，提供文件秒传与多端同步能力"
        Impact   = "解包部署至 $InstallDir，占用物理磁盘空间约 520MB"
    },
    [PSCustomObject]@{
        Module   = "系统集成层"
        Property = "开始菜单启动快捷方式"
        Expected = "已对齐 ($startMenuLnk -> $AppExe)"
        Actual   = if ($isLnkAligned) { "已对齐 ($startMenuLnk -> $AppExe)" } elseif ($hasLnk) { "指向偏离 ($actualLnkTarget)" } else { "未配置" }
        IsMatch  = $isLnkAligned
        Purpose  = "向 Windows 开始菜单注册直观的启动入口与高分辨率图标索引"
        Impact   = "便于通过开始菜单或任务栏检索框进行秒级拼音检索与快速唤起"
    },
    [PSCustomObject]@{
        Module   = "系统集成层"
        Property = "Windows 已安装应用列表登记"
        Expected = "已规范登记 (HKCU Uninstall)"
        Actual   = if ($isUninstallRegValid) { "已规范登记 (HKCU Uninstall)" } else { "未登记或信息偏离" }
        IsMatch  = $isUninstallRegValid
        Purpose  = "在 Windows 设置与控制面板中规范注册应用元数据"
        Impact   = "使系统级资产清单、体检大盘与卸载工具能够准确识别版本与安装路径"
    },
    [PSCustomObject]@{
        Module   = "网络安全层"
        Property = "防火墙 TCP 全网段入站阻断"
        Expected = "已阻断 (Any Profile)"
        Actual   = $actualFwTcpDesc
        IsMatch  = $isFwTcpAligned
        Purpose  = "阻断 TCP 入站监听，消除 Windows 防火墙拦截弹窗"
        Impact   = "阻止局域网对客户端端口的任何扫描与探测，不影响客户端正常的出站上传/下载"
    },
    [PSCustomObject]@{
        Module   = "网络安全层"
        Property = "防火墙 UDP 全网段入站阻断"
        Expected = "已阻断 (Any Profile)"
        Actual   = $actualFwUdpDesc
        IsMatch  = $isFwUdpAligned
        Purpose  = "阻断非必要的 UDP 组播接收与局域网广播，消除防火墙弹窗"
        Impact   = "彻底切断 UDP 入站暴露面，保障移动与办公网络环境安全"
    },
    [PSCustomObject]@{
        Module   = "偏好策略层"
        Property = "开机常驻自启动 (跨视图 Run 项)"
        Expected = "已清除 (禁用自启)"
        Actual   = $actualRunDesc
        IsMatch  = (-not $hasRunDrift)
        Purpose  = "跨原生 64 位与 32 位视图彻底切断天翼云盘开机常驻自启动项"
        Impact   = "冷启动时不再自动拉起 500MB+ 的 CEF/Flutter 进程栈与后台轮询，释放内存与 CPU"
    },
    [PSCustomObject]@{
        Module   = "偏好策略层"
        Property = "资源管理器虚拟同步盘入口 (NameSpace)"
        Expected = "已清除 (纯净视图)"
        Actual   = $actualSyncDiskDesc
        IsMatch  = (-not $hasSyncDiskDrift)
        Purpose  = '清理并抑制资源管理器「此电脑」中未经授权的虚拟同步盘 CLSID 命名空间入口'
        Impact   = "保持资源管理器设备与驱动器列表的原生纯净，杜绝死链图标与未配置挂载盘的视觉污染"
    }
)

# 渲染差异矩阵表格
& $console -Task RenderDiff -Specs $Specs

# ==============================================================================
# 5. 阶段 3: 审查门禁决策 (Gate)
# ==============================================================================
$diffs = @($Specs | Where-Object { -not $_.IsMatch })

$proceed = & $console -Task ConfirmGate -Specs $diffs -Action $Action -Yes:$Yes
if ($Action -eq "Check" -or -not $proceed) {
    return
}

# ==============================================================================
# 6. 阶段 4: 单向原子落盘 (Apply)
# ==============================================================================
$appliedCount = 0

# 6.1 程序本体解包部署或强制更新
$needBinaryDeploy = (-not $isInstalled) -or (-not (Compare-VersionAligned -LocalVer $installedVersion -TargetVer $targetVersion)) -or $Force
if ($needBinaryDeploy) {
    if (-not $latestInfo) {
        $latestInfo = Get-Cloud189LatestInfo -ThrowOnFailure
    }

    Write-Host "`n🚀 正在准备部署天翼云盘客户端本体 (v$($latestInfo.Version))..." -ForegroundColor Cyan

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "ecloud_pkg_$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    Ensure-Dir $tempDir
    $installerPkg = Join-Path $tempDir "ecloud_setup.exe"

    try {
        # 1. 通过 aria2 极速并发拉取官方安装包
        Invoke-DownloadFile -Url $latestInfo.DownloadUrl -OutFile $installerPkg -Description "天翼云盘官方安装包 (v$($latestInfo.Version))" -MinBytes (100 * 1024 * 1024)

        # 2. 终止运行中关联进程 (防文件锁定并发破坏)
        Stop-AppProcesses

        # 3. 校验并定位 7z 引擎
        $7zExe = (Get-Command "7z.exe" -ErrorAction SilentlyContinue).Source
        if (-not $7zExe) {
            $scoopRoot = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
            $7zCandidate = Join-Path $scoopRoot "shims\7z.exe"
            if (Test-Path $7zCandidate) { $7zExe = $7zCandidate }
        }
        if (-not $7zExe -or -not (Test-Path $7zExe)) {
            throw "【依赖缺失】未找到 7z 解压缩引擎，请先安装: scoop install 7zip"
        }

        # 4. 7z 增量展开至目标目录 D:\prog\ecloud\ (带句柄自愈重试保护)
        Ensure-Dir $InstallDir
        Write-Host "📦 正在解包天翼云盘运行时至 $InstallDir..." -ForegroundColor Cyan

        $retryCount = 0
        $unpackSuccess = $false
        while ($retryCount -lt 3 -and -not $unpackSuccess) {
            & $7zExe x $installerPkg -o"$InstallDir" -y -xr'!$PLUGINSDIR' -xr'!$TEMP' | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $unpackSuccess = $true
            } else {
                $retryCount++
                if ($retryCount -lt 3) {
                    Write-Host "⚠️  解包遇到文件占用，正在重新释放进程句柄并于 1 秒后重试 ($retryCount/3)..." -ForegroundColor Yellow
                    Stop-AppProcesses
                    Start-Sleep -Seconds 1
                }
            }
        }

        if (-not $unpackSuccess) {
            throw "7z 解包天翼云盘安装包失败 (退出代码 $LASTEXITCODE)！请检查是否有常驻杀毒软件持续锁定 $InstallDir"
        }

        if (-not (Test-Path $AppExe)) {
            throw "解包完成但未定位到核心执行文件: $AppExe，请检查安装包完整性！"
        }

        Write-Host "✔ 天翼云盘二进制本体解包部署完成。" -ForegroundColor Green
        $appliedCount++
    } finally {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 6.2 注册开始菜单快捷方式 (Unicode 安全写入)
if (-not $isLnkAligned -or $needBinaryDeploy) {
    Write-Host "🔗 正在创建/校准开始菜单快捷方式..." -ForegroundColor Cyan
    Save-ShortcutUnicode -LnkPath $startMenuLnk -TargetPath $AppExe -WorkingDir $InstallDir -Description "天翼云盘客户端" -IconLocation "$AppExe,0"
    Write-Host "✔ 开始菜单快捷方式校准完成 ($startMenuLnk)。" -ForegroundColor Green
    $appliedCount++
}

# 6.3 跨视图压制开机常驻自启动项
if ($hasRunDrift) {
    Write-Host "⚙️  正在清除跨视图开机常驻自启动注册表项..." -ForegroundColor Cyan
    foreach ($rPath in $runKeyCandidatePaths) {
        if (Get-ItemProperty -Path $rPath -Name $runKeyName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $rPath -Name $runKeyName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "✔ 已成功禁用天翼云盘所有开机自启动项。" -ForegroundColor Green
    $appliedCount++
}

# 6.4 规范登记 Windows 卸载注册表信息并清理旧视图残留
if (-not $isUninstallRegValid -or $needBinaryDeploy) {
    Write-Host "📝 正在规范登记 Windows 应用列表元数据..." -ForegroundColor Cyan
    Ensure-RegKey $uninstallRegPath

    $currentVer = if ($latestInfo) { $latestInfo.Version } else { $targetVersion }
    $uninstScript = $PSCommandPath

    Set-ItemProperty -Path $uninstallRegPath -Name "DisplayName" -Value "天翼云盘" -Force
    Set-ItemProperty -Path $uninstallRegPath -Name "DisplayVersion" -Value $currentVer -Force
    Set-ItemProperty -Path $uninstallRegPath -Name "Publisher" -Value "中国电信 (天翼数字生活科技有限公司)" -Force
    Set-ItemProperty -Path $uninstallRegPath -Name "InstallLocation" -Value $InstallDir -Force
    Set-ItemProperty -Path $uninstallRegPath -Name "DisplayIcon" -Value "$AppExe,0" -Force
    Set-ItemProperty -Path $uninstallRegPath -Name "UninstallString" -Value "pwsh.exe -File `"$uninstScript`" -Action Uninstall" -Force
    Set-ItemProperty -Path $uninstallRegPath -Name "QuietUninstallString" -Value "pwsh.exe -File `"$uninstScript`" -Action Uninstall -Yes" -Force
    Set-ItemProperty -Path $uninstallRegPath -Name "NoModify" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $uninstallRegPath -Name "NoRepair" -Value 1 -Type DWord -Force

    Write-Host "✔ Windows 应用管理列表登记完成。" -ForegroundColor Green
    $appliedCount++
}

# 6.5 治理资源管理器虚拟同步盘入口 (禁用同步盘)
if ($hasSyncDiskDrift) {
    Write-Host "🧹 正在清理资源管理器「此电脑」中的虚拟同步盘残留入口..." -ForegroundColor Cyan
    Clean-SyncDiskNamespace
    Write-Host "✔ 资源管理器同步盘虚拟入口治理完成。" -ForegroundColor Green
    $appliedCount++
}

# 6.6 预置防火墙全网段入站阻断规则 (TCP/UDP Inbound Block, 防弹窗且 0 暴露面)
if (-not $isFwTcpAligned -or -not $isFwUdpAligned) {
    Write-Host "🛡️  正在预置防火墙入站阻断规则 (消除弹窗与端口暴露面)..." -ForegroundColor Cyan
    foreach ($fw in $fwRules) {
        $existing = Get-NetFirewallRule -Name $fw.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -Name $fw.Name -DisplayName $fw.Desc `
                -Direction Inbound -Program $AppExe -Protocol $fw.Protocol -Action Block `
                -Profile Any -Enabled True -ErrorAction SilentlyContinue | Out-Null
            $appliedCount++
        } else {
            if ($existing.Action -ne "Block" -or $existing.Enabled -ne "True") {
                Set-NetFirewallRule -Name $fw.Name -Action Block -Profile Any -Enabled True -ErrorAction SilentlyContinue
                $appliedCount++
            }
        }
    }
    Write-Host "✔ 防火墙全网段入站阻断规则已配置 (TCP/UDP Block)。" -ForegroundColor Green
}

# ==============================================================================
# 7. 阶段 5: 尾部简报与闭环交付 (Report)
# ==============================================================================
$sw.Stop()
& $console -Task Summary -Duration $sw.Elapsed -AppliedCount $appliedCount

# 动态真待办：若已部署但从未登录过（AppData 不存在凭据），输出高价值登录指引
$hasCredentials = Test-Path (Join-Path $env:APPDATA "ecloud")
if ((Test-Path $AppExe) -and -not $hasCredentials -and $Action -eq "Sync") {
    Write-Host "📌 【后续操作交接】:" -ForegroundColor Cyan
    Write-Host "   - 启动天翼云盘并使用手机客户端扫码或输入天翼账号登录以激活云端同步。`n" -ForegroundColor Gray
}
