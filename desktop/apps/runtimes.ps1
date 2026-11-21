#requires -Version 7.0
<#
.SYNOPSIS
    系统基础运行库与应用底座 (Scoop / VC++ / .NET / WebView2 / Git 通用配置 / 7-Zip 极简集成)

.DESCRIPTION
    Windows 11 桌面与应用底层包管理器底座与核心通用运行库声明式校验与自动化补齐工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 全面迁移至官方权威直链与原厂静默安装，彻底移除对 WinGet / App Installer 的外部脆弱依赖。
    3. 集成 Scoop 应用包管理器自举与核心基础工具链配置 (git, 7zip, aria2, pwsh, extras bucket)。
    4. 涵盖核心基础运行时依赖与通用工具偏好规范：
       - Scoop 包管理器底座与核心工具链 (git, 7zip, aria2, pwsh) 及 aria2 高性能切片配置；
       - Git 全局基础通用偏好规范 (锁定 LF 换行、统一 UTF-8 编码、main 默认分支与分支追踪/清理，不碰个人身份)；
       - 7-Zip 原生外壳集成与核心压缩格式双击只读浏览关联 (平铺模式、掩码 0x104 直出、.zip/.7z/.rar/.tar/.gz 关联)；
       - Visual C++ 2015-2022 Redistributable (x64 与 x86 成对运行库，永久 aka.ms 权威直链)；
       - .NET 10.0 Desktop Runtime (x64 最新 LTS 桌面运行时框架)；
       - Microsoft Edge WebView2 Runtime (Evergreen 独立常青渲染运行时)。
    5. 统一复用仓内 _aria2.ps1 高并发切片下载引擎，具备终态确定性二次校验与 Fail-Fast 硬阻断保障。
    6. 底层共享依赖禁止自动化卸载，遵循安全阻断与人工待办交付规范。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量补齐缺失的基础底座与运行库 (默认，缺失则装，已就绪则零写入)
    - Check     : 只查不改体检巡检 (零写入)
    - Uninstall : 安全保护阻断 (底层共享依赖禁止自动化卸载)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\desktop\apps\runtimes.ps1 -Action Check

    # 交互式检查并增量补齐运行库与底座
    pwsh -File .\desktop\apps\runtimes.ps1

    # 无交互一键全量对齐
    pwsh -File .\desktop\apps\runtimes.ps1 -Yes
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall")]
    [string]$Action = "Sync",

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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and $Action -ne "Check") {
    throw "【权限错误】系统底层基础运行库与应用底座补齐需管理员特权，请在提升的 pwsh 会话中重新执行！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 核心辅助函数与探测算子
# ==============================================================================
$AppId   = "runtimes"
$AppName = "系统基础运行库与应用底座 (Scoop / VC++ / .NET / WebView2 / Git 通用配置 / 7-Zip 极简集成)"

$GitBaselineConfigs = [ordered]@{
    'init.defaultBranch'     = 'main'
    'push.autoSetupRemote'   = 'true'
    'pull.rebase'            = 'false'
    'fetch.prune'            = 'true'
    'core.autocrlf'          = 'false'
    'core.eol'               = 'lf'
    'core.safecrlf'          = 'warn'
    'core.quotepath'         = 'false'
    'i18n.commitEncoding'    = 'utf-8'
    'i18n.logOutputEncoding' = 'utf-8'
}

$SevenZipClsid = "{23170F69-40C1-278A-1000-000100020000}"

$SevenZipBaselineOptions = [ordered]@{
    'CascadedMenu'   = 0
    'ContextMenu'    = 260    # 0x104 = kExtractTo (4) | kCompress (256)
    'MenuIcons'      = 1
    'ElimDupExtract' = 1
}

$SevenZipBaselineExts = @('.7z', '.zip', '.rar', '.tar', '.gz')

$SevenZipBlockedNativeClsids = @(
    '{b8cdcb65-b1bf-4b42-9428-1dfdb7ee92af}',  # Windows 原生 .zip 全部解压缩 (zipfldr.dll)
    '{EE07CEF5-3441-4CFB-870A-4002C724783A}'   # Windows 11 原生 .7z/.rar/.tar 全部解压缩 (libarchive)
)

function Get-GitCommandPath {
    param([string]$ScoopRoot)
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    if ($ScoopRoot) {
        $shimGit = Join-Path $ScoopRoot "shims\git.exe"
        if (Test-Path -LiteralPath $shimGit -PathType Leaf) { return $shimGit }
        $appGit = Join-Path $ScoopRoot "apps\git\current\cmd\git.exe"
        if (Test-Path -LiteralPath $appGit -PathType Leaf) { return $appGit }
    }
    return $null
}

function Get-GitGlobalConfigStatus {
    param([string]$GitExe)

    if (-not $GitExe -or -not (Test-Path -LiteralPath $GitExe -PathType Leaf)) {
        return [PSCustomObject]@{
            Installed      = $false
            StatusText     = "Git 工具未就绪"
            MismatchedKeys = @($GitBaselineConfigs.Keys)
        }
    }

    $global:LASTEXITCODE = $null
    $rawLines = & $GitExe config --global --list 2>$null
    $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }

    $currentMap = @{}
    if ($rawLines) {
        foreach ($line in $rawLines) {
            $eqIdx = $line.IndexOf('=')
            if ($eqIdx -gt 0) {
                $k = $line.Substring(0, $eqIdx).Trim().ToLowerInvariant()
                $v = $line.Substring($eqIdx + 1).Trim()
                $currentMap[$k] = $v
            }
        }
    }

    $mismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $GitBaselineConfigs.Keys) {
        $normK = $k.ToLowerInvariant()
        $expected = $GitBaselineConfigs[$k]
        $actual = $currentMap[$normK]
        if (-not ($actual -ieq $expected)) {
            $mismatches.Add($k)
        }
    }

    $isAligned = ($mismatches.Count -eq 0)
    $statusText = if ($isAligned) {
        "10 项通用配置已对齐"
    } else {
        "偏离: $($mismatches -join ', ')"
    }

    return [PSCustomObject]@{
        Installed      = $isAligned
        StatusText     = $statusText
        MismatchedKeys = @($mismatches)
    }
}

function Get-SevenZipCommandPaths {
    param([string]$ScoopRoot)
    $candidateDirs = [System.Collections.Generic.List[string]]::new()
    if ($ScoopRoot -and (Test-Path -LiteralPath $ScoopRoot -PathType Container)) {
        $candidateDirs.Add((Join-Path $ScoopRoot "apps\7zip\current"))
    }
    $cfgScoop = [Environment]::GetEnvironmentVariable('SCOOP', 'User')
    if ($cfgScoop -and (Test-Path -LiteralPath $cfgScoop -PathType Container)) {
        $candidateDirs.Add((Join-Path $cfgScoop "apps\7zip\current"))
    }
    $candidateDirs.Add("D:\prog\scoop\apps\7zip\current")

    foreach ($dir in $candidateDirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $fm = Join-Path $dir "7zFM.exe"
        $dll = Join-Path $dir "7-zip.dll"
        if ((Test-Path -LiteralPath $fm -PathType Leaf) -and (Test-Path -LiteralPath $dll -PathType Leaf)) {
            return [PSCustomObject]@{
                InstallDir = $dir
                FmExe      = $fm
                Dll        = $dll
            }
        }
    }
    return $null
}

function Get-SevenZipIntegrationStatus {
    param([string]$ScoopRoot)

    $paths = Get-SevenZipCommandPaths -ScoopRoot $ScoopRoot
    if ($null -eq $paths) {
        return [PSCustomObject]@{
            Installed   = $false
            StatusText  = "7-Zip 工具未就绪"
            Mismatches  = @("7zFM.exe 或 7-zip.dll 缺失")
            SevenZipDir = $null
            SevenZipFm  = $null
            SevenZipDll = $null
        }
    }

    $mismatches = [System.Collections.Generic.List[string]]::new()

    # 1. 检查 Options: CascadedMenu=0, ContextMenu=260, MenuIcons=1, ElimDupExtract=1
    $optPath = "HKCU:\Software\7-Zip\Options"
    if (-not (Test-Path -LiteralPath $optPath)) {
        $mismatches.Add("HKCU\Software\7-Zip\Options 注册表项缺失")
    } else {
        foreach ($k in $SevenZipBaselineOptions.Keys) {
            $expected = $SevenZipBaselineOptions[$k]
            $val = (Get-ItemProperty -LiteralPath $optPath -ErrorAction SilentlyContinue).$k
            if ($null -eq $val -or [int]$val -ne $expected) {
                $mismatches.Add("Options\$k (当前: $val, 预期: $expected)")
            }
        }
    }

    # 2. 检查 COM 扩展 CLSID
    $clsidPath = "HKCU:\Software\Classes\CLSID\$SevenZipClsid"
    $inprocPath = "$clsidPath\InprocServer32"
    if (-not (Test-Path -LiteralPath $inprocPath)) {
        $mismatches.Add("CLSID\$SevenZipClsid\InprocServer32 未注册")
    } else {
        $inprocVal = (Get-ItemProperty -LiteralPath $inprocPath -ErrorAction SilentlyContinue)."(default)"
        if (-not $inprocVal -or -not ($inprocVal.Trim('"') -ieq $paths.Dll)) {
            $mismatches.Add("CLSID InprocServer32 路径偏离 (当前: $inprocVal, 预期: $($paths.Dll))")
        }
    }

    # 3. 检查外壳上下文处理器 (*, Directory, Folder)
    $handlers = @(
        "HKCU:\Software\Classes\*\shellex\ContextMenuHandlers\7-Zip",
        "HKCU:\Software\Classes\Directory\shellex\ContextMenuHandlers\7-Zip",
        "HKCU:\Software\Classes\Folder\shellex\ContextMenuHandlers\7-Zip"
    )
    foreach ($h in $handlers) {
        if (-not (Test-Path -LiteralPath $h)) {
            $mismatches.Add("$h 缺失")
        } else {
            $hVal = (Get-ItemProperty -LiteralPath $h -ErrorAction SilentlyContinue)."(default)"
            if (-not ($hVal -ieq $SevenZipClsid)) {
                $mismatches.Add("$h 默认值偏离 (当前: $hVal)")
            }
        }
    }

    # 4. 检查 ProgID 与文件格式关联
    $progIdPath = "HKCU:\Software\Classes\7-Zip.Archive"
    $openCmdPath = "$progIdPath\shell\open\command"
    if (-not (Test-Path -LiteralPath $openCmdPath)) {
        $mismatches.Add("ProgID 7-Zip.Archive 未注册")
    }

    foreach ($ext in $SevenZipBaselineExts) {
        $extPath = "HKCU:\Software\Classes\$ext"
        if (-not (Test-Path -LiteralPath $extPath)) {
            $mismatches.Add("格式关联 $ext 缺失")
        } else {
            $extVal = (Get-ItemProperty -LiteralPath $extPath -ErrorAction SilentlyContinue)."(default)"
            if (-not ($extVal -ieq "7-Zip.Archive")) {
                $mismatches.Add("格式关联 $ext 偏离 (当前: $extVal, 预期: 7-Zip.Archive)")
            }
        }
    }

    # 5. 检查 Windows 原生解压外壳扩展屏蔽名单 (Shell Extensions Blocked)
    $blockedPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"
    if (-not (Test-Path -LiteralPath $blockedPath)) {
        $mismatches.Add("原生解压外壳扩展屏蔽项缺失")
    } else {
        $blockedItem = Get-ItemProperty -LiteralPath $blockedPath -ErrorAction SilentlyContinue
        foreach ($clsid in $SevenZipBlockedNativeClsids) {
            if ($null -eq $blockedItem.PSObject.Properties[$clsid]) {
                $mismatches.Add("原生解压外壳扩展未屏蔽: $clsid")
            }
        }
    }

    $isAligned = ($mismatches.Count -eq 0)
    $statusText = if ($isAligned) {
        "平铺直出 / 掩码 0x104 (260) / 5 格式关联已对齐 / 原生解压已屏蔽"
    } else {
        "偏离: $($mismatches.Count) 项未对齐"
    }

    return [PSCustomObject]@{
        Installed   = $isAligned
        StatusText  = $statusText
        Mismatches  = @($mismatches)
        SevenZipDir = $paths.InstallDir
        SevenZipFm  = $paths.FmExe
        SevenZipDll = $paths.Dll
    }
}

function Set-SevenZipIntegration {
    param([string]$ScoopRoot)

    $paths = Get-SevenZipCommandPaths -ScoopRoot $ScoopRoot
    if ($null -eq $paths) {
        throw "未找到 7-Zip 可执行组件与动态库 (7zFM.exe / 7-zip.dll)，无法应用外壳集成。"
    }

    # 1. 写入 Options (CascadedMenu=0, ContextMenu=260, MenuIcons=1, ElimDupExtract=1)
    $optPath = "HKCU:\Software\7-Zip\Options"
    if (-not (Test-Path -LiteralPath $optPath)) {
        New-Item -Path $optPath -Force -ErrorAction Stop | Out-Null
    }
    foreach ($k in $SevenZipBaselineOptions.Keys) {
        Set-ItemProperty -LiteralPath $optPath -Name $k -Value $SevenZipBaselineOptions[$k] -Type DWord -Force -ErrorAction Stop
    }

    # 2. 注册 COM 扩展外壳服务器 CLSID (HKCU)
    $clsidPath = "HKCU:\Software\Classes\CLSID\$SevenZipClsid"
    $inprocPath = "$clsidPath\InprocServer32"
    if (-not (Test-Path -LiteralPath $inprocPath)) {
        New-Item -Path $inprocPath -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -LiteralPath $clsidPath -Name "(default)" -Value "7-Zip Shell Extension" -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $inprocPath -Name "(default)" -Value $paths.Dll -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $inprocPath -Name "ThreadingModel" -Value "Apartment" -Force -ErrorAction Stop

    # 3. 挂载外壳上下文处理器 (*, Directory, Folder)
    $handlers = @(
        "HKCU:\Software\Classes\*\shellex\ContextMenuHandlers\7-Zip",
        "HKCU:\Software\Classes\Directory\shellex\ContextMenuHandlers\7-Zip",
        "HKCU:\Software\Classes\Folder\shellex\ContextMenuHandlers\7-Zip"
    )
    foreach ($h in $handlers) {
        if (-not (Test-Path -LiteralPath $h)) {
            New-Item -Path $h -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -LiteralPath $h -Name "(default)" -Value $SevenZipClsid -Force -ErrorAction Stop
    }

    # 4. 注册 ProgID 7-Zip.Archive 并绑定双击打开命令
    $progIdPath = "HKCU:\Software\Classes\7-Zip.Archive"
    $iconPath   = "$progIdPath\DefaultIcon"
    $openCmdPath = "$progIdPath\shell\open\command"
    if (-not (Test-Path -LiteralPath $openCmdPath)) {
        New-Item -Path $openCmdPath -Force -ErrorAction Stop | Out-Null
    }
    if (-not (Test-Path -LiteralPath $iconPath)) {
        New-Item -Path $iconPath -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -LiteralPath $progIdPath -Name "(default)" -Value "7-Zip Archive" -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $iconPath -Name "(default)" -Value "`"$($paths.FmExe)`",0" -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $openCmdPath -Name "(default)" -Value "`"$($paths.FmExe)`" `"%1`"" -Force -ErrorAction Stop

    # 5. 绑定核心压缩格式扩展名
    foreach ($ext in $SevenZipBaselineExts) {
        $extPath = "HKCU:\Software\Classes\$ext"
        if (-not (Test-Path -LiteralPath $extPath)) {
            New-Item -Path $extPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -LiteralPath $extPath -Name "(default)" -Value "7-Zip.Archive" -Force -ErrorAction Stop
    }

    # 6. 屏蔽 Windows 原生重复解压外壳扩展 (Shell Extensions Blocked: zipfldr 与 libarchive)
    $blockedPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"
    if (-not (Test-Path -LiteralPath $blockedPath)) {
        New-Item -Path $blockedPath -Force -ErrorAction Stop | Out-Null
    }
    foreach ($clsid in $SevenZipBlockedNativeClsids) {
        Set-ItemProperty -LiteralPath $blockedPath -Name $clsid -Value "" -Type String -Force -ErrorAction Stop
    }

    # 7. Windows 11 FileExts UserChoice 机制：清理核心格式锁定键使其安全回退至 HKCU 声明的 7-Zip.Archive
    foreach ($ext in $SevenZipBaselineExts) {
        $extUserChoice = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice"
        if (Test-Path -LiteralPath $extUserChoice) {
            Remove-Item -LiteralPath $extUserChoice -Force -ErrorAction SilentlyContinue
        }
    }

    # 8. 广播外壳刷新
    if (-not ('ShellSync7z' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ShellSync7z {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
"@ -ErrorAction SilentlyContinue
    }
    if ('ShellSync7z' -as [type]) {
        [ShellSync7z]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    }

    # 9. 写后回读物理终态强校验
    $after = Get-SevenZipIntegrationStatus -ScoopRoot $ScoopRoot
    if (-not $after.Installed) {
        throw "7-Zip 外壳集成写入后校验失败：$($after.Mismatches -join '; ')"
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Description = "文件",
        [long]$MinBytes = 1024,
        [int]$TimeoutSec = 300
    )

    $tool = Join-Path $PSScriptRoot "_aria2.ps1"
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "未在应用域定位到核心下载引擎: _aria2.ps1，请确保仓库完整性！"
    }

    & $tool -Url $Url -OutFile $OutFile -Description $Description -MinBytes $MinBytes -TimeoutSec $TimeoutSec
}

function Install-ScoopFoundation {
    param(
        [Parameter(Mandatory = $true)][string]$scoopPath,
        [switch]$IsAdmin
    )

    if (-not (Test-Path -LiteralPath 'D:\' -PathType Container)) {
        throw 'D 盘未就绪，请先确认分区。'
    }

    if (Test-Path -LiteralPath $scoopPath) {
        if (-not (Test-Path -LiteralPath $scoopPath -PathType Container) -or
            @(Get-ChildItem -LiteralPath $scoopPath -Force).Count -gt 0) {
            throw 'Scoop 目标非空或不是目录；本流程不复原、覆盖或清理旧环境。'
        }
    }

    $configuredScoop = [Environment]::GetEnvironmentVariable('SCOOP', 'User')
    if (($configuredScoop -and $configuredScoop -ne $scoopPath) -or
        ($env:SCOOP -and $env:SCOOP -ne $scoopPath) -or
        (Get-Command scoop -ErrorAction SilentlyContinue)) {
        throw '检测到已有 Scoop 路径或命令，请先确认现有环境；本流程仅用于新装。'
    }

    New-Item -ItemType Directory -Path 'D:\act', 'D:\arc', 'D:\prog', 'D:\res' -Force | Out-Null
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    [Environment]::SetEnvironmentVariable('SCOOP', $scoopPath, 'User')
    $env:SCOOP = $scoopPath

    $global:LASTEXITCODE = 0
    $installer = Invoke-RestMethod -Uri 'https://get.scoop.sh'
    if ($IsAdmin) {
        Invoke-Expression "& { $installer } -RunAsAdmin -ScoopDir `"$scoopPath`""
    } else {
        Invoke-Expression "& { $installer } -ScoopDir `"$scoopPath`""
    }
    if ($LASTEXITCODE -ne 0) { throw "Scoop 安装失败，退出码 $LASTEXITCODE。" }

    $scoop = Join-Path $scoopPath 'shims\scoop.ps1'
    if (-not (Test-Path -LiteralPath $scoop -PathType Leaf)) { throw 'Scoop 安装后未找到入口。' }

    & $scoop install git 7zip aria2 pwsh
    if ($LASTEXITCODE -ne 0) { throw "核心工具安装失败，退出码 $LASTEXITCODE。" }

    & $scoop config aria2-enabled true
    if ($LASTEXITCODE -ne 0) { throw "aria2-enabled 配置失败，退出码 $LASTEXITCODE。" }
    & $scoop config aria2-warning-enabled false
    if ($LASTEXITCODE -ne 0) { throw "aria2-warning-enabled 配置失败，退出码 $LASTEXITCODE。" }
    & $scoop config aria2-max-connection-per-server 16
    if ($LASTEXITCODE -ne 0) { throw "aria2-max-connection-per-server 配置失败，退出码 $LASTEXITCODE。" }
    & $scoop config aria2-split 16
    if ($LASTEXITCODE -ne 0) { throw "aria2-split 配置失败，退出码 $LASTEXITCODE。" }
    & $scoop config aria2-min-split-size 1M
    if ($LASTEXITCODE -ne 0) { throw "aria2-min-split-size 配置失败，退出码 $LASTEXITCODE。" }

    & $scoop bucket add extras
    if ($LASTEXITCODE -ne 0) { throw "extras bucket 添加失败，退出码 $LASTEXITCODE。" }
}

function Get-RuntimeInventory {
    $inventory = [ordered]@{}

    # 1. 查询 Scoop 包管理器底座状态
    $scoopRoot = if ($env:SCOOP -and (Test-Path -LiteralPath $env:SCOOP)) { $env:SCOOP } else {
        $cfg = [Environment]::GetEnvironmentVariable('SCOOP', 'User')
        if ($cfg) { $cfg } else { "D:\prog\scoop" }
    }
    $scoopEntry = Join-Path $scoopRoot "shims\scoop.ps1"
    $scoopInstalled = Test-Path -LiteralPath $scoopEntry -PathType Leaf

    $requiredTools = [string[]]@('git', '7zip', 'aria2', 'pwsh')
    $missingTools = [System.Collections.Generic.List[string]]::new()
    if ($scoopInstalled) {
        foreach ($tool in $requiredTools) {
            $toolDir = Join-Path $scoopRoot "apps\$tool"
            if (-not (Test-Path -LiteralPath $toolDir -PathType Container)) {
                $missingTools.Add($tool)
            }
        }
    } else {
        $missingTools.AddRange($requiredTools)
    }

    $extrasDir = Join-Path $scoopRoot "buckets\extras"
    $extrasInstalled = Test-Path -LiteralPath $extrasDir -PathType Container

    $scoopConfigFile = Join-Path $HOME ".config\scoop\config.json"
    $aria2ConfigAligned = $false
    if (Test-Path -LiteralPath $scoopConfigFile -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $scoopConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $aria2Enabled = [bool]$json.'aria2-enabled'
            $aria2Warning = [bool]$json.'aria2-warning-enabled'
            $aria2MaxConn = [string]$json.'aria2-max-connection-per-server'
            $aria2Split   = [string]$json.'aria2-split'
            $aria2MinSize = [string]$json.'aria2-min-split-size'
            if ($aria2Enabled -and (-not $aria2Warning) -and $aria2MaxConn -eq "16" -and $aria2Split -eq "16" -and $aria2MinSize -eq "1M") {
                $aria2ConfigAligned = $true
            }
        } catch {
            $aria2ConfigAligned = $false
        }
    }

    $scoopReady = ($scoopInstalled -and ($missingTools.Count -eq 0) -and $extrasInstalled -and $aria2ConfigAligned)
    $scoopStatusText = if ($scoopReady) {
        "核心工具与 extras 齐备"
    } elseif (-not $scoopInstalled) {
        "未安装"
    } else {
        $pending = [System.Collections.Generic.List[string]]::new()
        if ($missingTools.Count -gt 0) { $pending.Add("工具缺失: $($missingTools -join ',')") }
        if (-not $extrasInstalled) { $pending.Add("缺少 extras bucket") }
        if (-not $aria2ConfigAligned) { $pending.Add("aria2 参数未对齐") }
        $pending -join "; "
    }

    $inventory["scoop"] = [PSCustomObject]@{
        Key                = "scoop"
        Name               = "Scoop 包管理器与基础底座"
        Module             = "依赖"
        Installed          = $scoopReady
        Version            = $scoopStatusText
        ScoopRoot          = $scoopRoot
        ScoopEntry         = $scoopEntry
        MissingTools       = @($missingTools)
        ExtrasInstalled    = $extrasInstalled
        Aria2ConfigAligned = $aria2ConfigAligned
        Purpose            = "装配现代非侵入式应用包管理器底座与核心下载/解包工具链"
        Impact             = "保障后续自治脚本依赖的并发下载引擎 (aria2c)、解包工具 (7z)、Git 仓库支持与终端环境"
    }

    # 2. 查询 Git 全局基础偏好规范状态
    $gitExe = Get-GitCommandPath -ScoopRoot $scoopRoot
    $gitStatus = Get-GitGlobalConfigStatus -GitExe $gitExe
    $inventory["git"] = [PSCustomObject]@{
        Key            = "git"
        Name           = "Git 全局基础偏好规范"
        Module         = "配置"
        Installed      = $gitStatus.Installed
        Version        = $gitStatus.StatusText
        GitExe         = $gitExe
        MismatchedKeys = $gitStatus.MismatchedKeys
        Purpose        = "锁定 LF 换行、UTF-8 编码、main 默认分支与分支追踪/清理，杜绝换行符与中文路径转义"
        Impact         = "规范跨平台协作提交格式，写入当前用户 ~/.gitconfig，不触碰 user.name 与 user.email 个人身份"
    }

    # 3. 查询 7-Zip 原生外壳集成与核心格式关联状态
    $sevenZipStatus = Get-SevenZipIntegrationStatus -ScoopRoot $scoopRoot
    $inventory["7zip"] = [PSCustomObject]@{
        Key         = "7zip"
        Name        = "7-Zip 极简外壳集成与文件关联"
        Module      = "集成"
        Installed   = $sevenZipStatus.Installed
        Version     = $sevenZipStatus.StatusText
        Mismatches  = $sevenZipStatus.Mismatches
        SevenZipDir = $sevenZipStatus.SevenZipDir
        SevenZipFm  = $sevenZipStatus.SevenZipFm
        SevenZipDll = $sevenZipStatus.SevenZipDll
        Purpose     = "装配极简一级右键解压/打包外壳扩展与 .zip/.7z/.rar 核心压缩格式双击只读浏览关联"
        Impact      = "写入 HKCU 空间 7-Zip 掩码 (0x104) 与 COM 扩展，不触碰系统级 HKLM，保持无折叠极简交互"
    }

    # 4. 查询 64 位与 32 位卸载表
    $uninstKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $uninstEntries = Get-ChildItem -Path $uninstKeys -ErrorAction SilentlyContinue |
                     ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue }

    # 2.1 VC++ 2015-2022 x64
    $vc64Entry = $uninstEntries | Where-Object { $_.DisplayName -match "Visual C\+\+ 2015-.*x64" } | Select-Object -First 1
    $inventory["vc64"] = [PSCustomObject]@{
        Key         = "vc64"
        Name        = "Visual C++ 2015-2022 Redistributable (x64)"
        Module      = "依赖"
        Installed   = ($null -ne $vc64Entry)
        Version     = if ($vc64Entry) { ($vc64Entry.DisplayVersion ?? "已安装") } else { "未安装" }
        Url         = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
        FileName    = "vc_redist.x64.exe"
        InstallArgs = @("/install", "/quiet", "/norestart")
        ExitCodes   = @(0, 3010, 1638)
        Purpose     = "装配 64 位 C/C++ 核心动态链接库运行底座 (MSVCP140.dll 等)"
        Impact      = "保障现代 64 位原生应用（如 Python、Rust 工具、输入法）正常链接运行"
    }

    # 2.2 VC++ 2015-2022 x86
    $vc86Entry = $uninstEntries | Where-Object { $_.DisplayName -match "Visual C\+\+ 2015-.*x86" } | Select-Object -First 1
    $inventory["vc86"] = [PSCustomObject]@{
        Key         = "vc86"
        Name        = "Visual C++ 2015-2022 Redistributable (x86)"
        Module      = "依赖"
        Installed   = ($null -ne $vc86Entry)
        Version     = if ($vc86Entry) { ($vc86Entry.DisplayVersion ?? "已安装") } else { "未安装" }
        Url         = "https://aka.ms/vs/17/release/vc_redist.x86.exe"
        FileName    = "vc_redist.x86.exe"
        InstallArgs = @("/install", "/quiet", "/norestart")
        ExitCodes   = @(0, 3010, 1638)
        Purpose     = "装配 32 位 C/C++ 核心动态链接库兼容底座"
        Impact      = "保障部分依然依赖 32 位底层组件的第三方工具、游戏或安装器正常启动"
    }

    # 2.3 查询 .NET 10.0 Desktop Runtime (x64)
    $net10Base = "C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App"
    $net10Dirs = if (Test-Path -LiteralPath $net10Base -PathType Container) {
        Get-ChildItem -Path $net10Base -Directory -Filter "10.*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    } else { $null }
    $net10Installed = ($net10Dirs -and $net10Dirs.Count -gt 0)
    $net10Ver = if ($net10Installed) { $net10Dirs[0].Name } else { "未安装" }
    $inventory["net10"] = [PSCustomObject]@{
        Key         = "net10"
        Name        = ".NET 10.0 Desktop Runtime (x64)"
        Module      = "依赖"
        Installed   = $net10Installed
        Version     = $net10Ver
        Url         = "https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-x64.exe"
        FileName    = "windowsdesktop-runtime-10.0-win-x64.exe"
        InstallArgs = @("/install", "/quiet", "/norestart")
        ExitCodes   = @(0, 3010)
        Purpose     = "装配微软最新 .NET 10 LTS 桌面应用程序运行时框架"
        Impact      = "为现代 C# / WPF / WinForms 桌面客户端提供高性能托管运行环境"
    }

    # 2.4 查询 Microsoft Edge WebView2 Runtime
    $wv2Installed = $false
    $wv2Ver = "未安装"
    $wv2Key = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -Name "pv" -ErrorAction SilentlyContinue).pv
    if (-not $wv2Key) {
        $wv2Key = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -Name "pv" -ErrorAction SilentlyContinue).pv
    }
    if ($wv2Key -and $wv2Key -ne "0.0.0.0") {
        $wv2Installed = $true
        $wv2Ver = $wv2Key
    } else {
        $wv2Dir = "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"
        if (Test-Path -LiteralPath $wv2Dir -PathType Container) {
            $sub = Get-ChildItem -Path $wv2Dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.' } | Sort-Object Name -Descending | Select-Object -First 1
            if ($sub) {
                $wv2Installed = $true
                $wv2Ver = $sub.Name
            }
        }
    }
    $inventory["wv2"] = [PSCustomObject]@{
        Key         = "wv2"
        Name        = "Microsoft Edge WebView2 Runtime (Evergreen)"
        Module      = "依赖"
        Installed   = $wv2Installed
        Version     = $wv2Ver
        Url         = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
        FileName    = "MicrosoftEdgeWebview2Setup.exe"
        InstallArgs = @("/silent", "/install")
        ExitCodes   = @(0)
        Purpose     = "装配独立常青版 Chromium 渲染运行时底座"
        Impact      = "支持微信、飞书、QQ、输入法等第三方应用内嵌网页交互渲染，完全解耦于 Edge 浏览器本体"
    }

    return $inventory
}

# ==============================================================================
# 3. 独立流转分支：清洁卸载安全阻断 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    Write-Warning "【安全保护阻断】基础运行库与应用底座为系统多个桌面应用与系统的底层共享运行时依赖！"
    Write-Warning "强行自动化卸载会导致依赖这些运行库的应用（如浏览器、输入法、终端、包管理器等）全部崩溃瘫痪。"
    Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData '共享运行库与 Scoop 底座未自动卸载；若确需移除，请确认依赖影响后在 Windows 设置 → 应用 → 安装的应用及 Scoop 目录中手动处理。'
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查")) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$inv = Get-RuntimeInventory
$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$DiffList   = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($key in $inv.Keys) {
    $item = $inv[$key]
    $AuditBoard.Add([PSCustomObject]@{
        状态     = if ($item.Installed) { " ✔" } else { " ▲" }
        模块     = $item.Module
        属性     = $item.Name
        实机     = if ($item.Installed) { "已就绪 ($($item.Version))" } else { $item.Version }
        基线     = "已就绪"
    })

    if (-not $item.Installed) {
        $DiffList.Add($item)
    }
}

if (-not $Yes) {
    Write-Host "`n📊 [巡检看板] 系统底层运行库与应用底座基线审计清单:" -ForegroundColor Cyan
    $AuditBoard | Select-Object 状态, 模块, 属性, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host
}

# 检查模式立即安全退出
if ($Action -eq "Check") {
    if ($DiffList.Count -eq 0) {
        Write-Host "✨ [状态合规] 系统基础底座与核心运行库均已完整就绪，无需补齐。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基础组件偏离/缺失。执行默认模式 (-Action Sync) 即可自动补齐。`n" -f $DiffList.Count) -ForegroundColor Yellow
    }
    return
}

if ($DiffList.Count -eq 0) {
    Write-Host "✨ [状态合规] 系统基础底座与核心运行库均已在机就绪，无需安装补齐。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁 (Gate - Shift-Left: 目的与影响结构化直出)
# ==============================================================================
if (-not $Yes) {
    Write-Host "`n💡 [改动意图与技术边界审查 (Gate)]" -ForegroundColor Cyan
    Write-Host "   本次即将对齐以下偏离项，请逐项评估改动 [目的] 与 [影响]:" -ForegroundColor Gray
    $idx = 1
    foreach ($m in $DiffList) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $m.Name) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: 已就绪" -f $m.Version) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $m.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $m.Impact) -ForegroundColor Gray
        $idx++
    }
    $gateChoice = (Read-Host "`n确认对齐上述基础底座与运行库组件? [Y] 确认执行 / [Q] 退出 (默认 Y)").Trim()
    if ($gateChoice -notin @('', 'Y', 'y', 'YES', 'yes', 'Q', 'q', 'QUIT', 'quit', 'N', 'n', 'NO', 'no')) {
        throw '无效授权输入；未执行本模块写入。'
    }
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 6. 阶段 3: 单向原子补齐 (Apply)
# ==============================================================================
$failures = [System.Collections.Generic.List[string]]::new()

# 6.1 首先对齐 Scoop 包管理器与核心工具链（保障后续 aria2 并发下载引擎就绪）
$scoopItem = $DiffList | Where-Object { $_.Key -eq "scoop" } | Select-Object -First 1
if ($scoopItem) {
    Write-Host "`n🚀 正在对齐底座: $($scoopItem.Name)..." -ForegroundColor Cyan
    try {
        $scoopRoot = $scoopItem.ScoopRoot

        if (-not (Test-Path -LiteralPath $scoopItem.ScoopEntry -PathType Leaf)) {
            Install-ScoopFoundation -scoopPath $scoopRoot -IsAdmin:$isAdmin
        } else {
            # 补齐遗留缺失工具
            if ($scoopItem.MissingTools.Count -gt 0) {
                foreach ($tool in $scoopItem.MissingTools) {
                    Write-Host "   - 正在通过 Scoop 安装核心基础工具: $tool..." -ForegroundColor Gray
                    & $scoopItem.ScoopEntry install $tool
                    if ($LASTEXITCODE -ne 0) {
                        throw "Scoop 基础工具安装失败: $tool (ExitCode: $LASTEXITCODE)"
                    }
                }
            }

            # 补齐 aria2 参数
            if (-not $scoopItem.Aria2ConfigAligned) {
                Write-Host "   - 正在配置 Scoop aria2 高性能切片下载参数..." -ForegroundColor Gray
                & $scoopItem.ScoopEntry config aria2-enabled true
                if ($LASTEXITCODE -ne 0) { throw "aria2-enabled 配置失败" }
                & $scoopItem.ScoopEntry config aria2-warning-enabled false
                if ($LASTEXITCODE -ne 0) { throw "aria2-warning-enabled 配置失败" }
                & $scoopItem.ScoopEntry config aria2-max-connection-per-server 16
                if ($LASTEXITCODE -ne 0) { throw "aria2-max-connection-per-server 配置失败" }
                & $scoopItem.ScoopEntry config aria2-split 16
                if ($LASTEXITCODE -ne 0) { throw "aria2-split 配置失败" }
                & $scoopItem.ScoopEntry config aria2-min-split-size 1M
                if ($LASTEXITCODE -ne 0) { throw "aria2-min-split-size 配置失败" }
            }

            # 补齐 extras bucket
            if (-not $scoopItem.ExtrasInstalled) {
                Write-Host "   - 正在添加 Scoop 官方 extras bucket..." -ForegroundColor Gray
                & $scoopItem.ScoopEntry bucket add extras
                if ($LASTEXITCODE -ne 0) {
                    throw "extras bucket 添加失败 (ExitCode: $LASTEXITCODE)"
                }
            }
        }

        # 确保当前进程 PATH 包含 shims
        $shimDir = Join-Path $scoopRoot "shims"
        if (($env:PATH -split ';') -notcontains $shimDir) {
            $env:PATH = "$shimDir;$env:PATH"
        }

        Write-Host "   ✔ Scoop 包管理器与核心基础底座对齐成功" -ForegroundColor Green
    } catch {
        Write-Host "   ✘ Scoop 底座对齐失败: $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("Scoop 底座 ($($_.Exception.Message))")
        throw "Scoop 底座对齐失败，阻断后续运行库下载；错误: $($_.Exception.Message)"
    }
}

# 6.2 对齐 Git 全局基础偏好规范配置 (LF / UTF-8 / main / remote)
$gitItem = $DiffList | Where-Object { $_.Key -eq "git" } | Select-Object -First 1
if ($gitItem) {
    Write-Host "`n🚀 正在对齐配置: $($gitItem.Name)..." -ForegroundColor Cyan
    try {
        $targetScoopRoot = if ($inv -and $inv["scoop"]) { $inv["scoop"].ScoopRoot } else { $scoopRoot }
        $targetGitExe = if ($gitItem.GitExe -and (Test-Path -LiteralPath $gitItem.GitExe -PathType Leaf)) {
            $gitItem.GitExe
        } else {
            Get-GitCommandPath -ScoopRoot $targetScoopRoot
        }

        if (-not $targetGitExe -or -not (Test-Path -LiteralPath $targetGitExe -PathType Leaf)) {
            throw "未找到 Git 可执行入口，无法应用 Git 通用配置。"
        }

        foreach ($cfgKey in $gitItem.MismatchedKeys) {
            $cfgVal = $GitBaselineConfigs[$cfgKey]
            Write-Host "   - 正在配置 Git 全局参数: $cfgKey = $cfgVal..." -ForegroundColor Gray
            $global:LASTEXITCODE = $null
            & $targetGitExe config --global --replace-all $cfgKey $cfgVal
            $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
            if ($exitCode -ne 0) {
                throw "Git 配置 [$cfgKey = $cfgVal] 写入失败 (ExitCode: $exitCode)"
            }
        }

        Write-Host "   ✔ Git 全局基础偏好规范对齐成功 ($($gitItem.MismatchedKeys.Count) 项)" -ForegroundColor Green
    } catch {
        Write-Host "   ✘ Git 全局配置对齐失败: $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("Git 全局配置 ($($_.Exception.Message))")
    }
}

# 6.3 对齐 7-Zip 极简外壳集成与核心格式关联
$sevenZipItem = $DiffList | Where-Object { $_.Key -eq "7zip" } | Select-Object -First 1
if ($sevenZipItem) {
    Write-Host "`n🚀 正在对齐集成: $($sevenZipItem.Name)..." -ForegroundColor Cyan
    try {
        $targetScoopRoot = if ($inv -and $inv["scoop"]) { $inv["scoop"].ScoopRoot } else { $scoopRoot }
        Set-SevenZipIntegration -ScoopRoot $targetScoopRoot
        Write-Host "   ✔ 7-Zip 极简外壳集成与文件关联对齐成功并完成回读校验" -ForegroundColor Green
    } catch {
        Write-Host "   ✘ 7-Zip 外壳集成对齐失败: $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("7-Zip 外壳集成 ($($_.Exception.Message))")
    }
}

# 6.4 依序下载并安装底层运行库 (VC++ x64/x86, .NET 10, WebView2)
$runtimeItems = @($DiffList | Where-Object { $_.Key -notin @("scoop", "git", "7zip") })
foreach ($m in $runtimeItems) {
    Write-Host "`n🚀 正在对齐运行库: $($m.Name)..." -ForegroundColor Cyan
    $tempFile = Join-Path $env:TEMP $m.FileName
    try {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }

        # 1. 通过 _aria2.ps1 高并发下载官方安装包
        Invoke-DownloadFile -Url $m.Url -OutFile $tempFile -Description $m.Name -TimeoutSec 300

        # 2. 调用原厂安装器静默安装
        Write-Host "   - 正在执行原厂静默安装..." -ForegroundColor Gray
        $proc = Start-Process -FilePath $tempFile -ArgumentList $m.InstallArgs -Wait -PassThru -ErrorAction Stop

        # 3. 校验退出码
        if ($null -eq $proc -or $proc.ExitCode -notin $m.ExitCodes) {
            $exitCodeStr = if ($null -ne $proc) { [string]$proc.ExitCode } else { "未知" }
            throw "原厂安装器返回异常退出码: $exitCodeStr (预期: $($m.ExitCodes -join ', '))"
        }

        Write-Host "   ✔ $($m.Name) 对齐成功 (ExitCode: $($proc.ExitCode))" -ForegroundColor Green
        if ($proc.ExitCode -eq 3010) {
            Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData "$($m.Name) 安装已完成，但系统提示需要重启以使运行库完全生效。"
        }
    } catch {
        Write-Host "   ✘ $($m.Name) 对齐失败: $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("$($m.Name) ($($_.Exception.Message))")
    } finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==============================================================================
# 7. 阶段 4: 终态校验与尾部简报 (Report)
# ==============================================================================
$afterInv = Get-RuntimeInventory
$stillMissing = [System.Collections.Generic.List[string]]::new()
foreach ($k in $afterInv.Keys) {
    if (-not $afterInv[$k].Installed) {
        $stillMissing.Add($afterInv[$k].Name)
    }
}

Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 环境基线对齐检查完毕！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green

if ($failures.Count -gt 0) {
    throw "基础组件部署存在失败项：$($failures -join '; ')；请检查网络或环境配置。"
}

if ($stillMissing.Count -gt 0) {
    throw "基础底座补齐后仍有以下组件未就绪: $($stillMissing -join ', ')。请检查依赖环境或重新对齐。"
} else {
    Write-Host "✨ 全部基础运行库与 Scoop 应用底座均已安装就绪。`n" -ForegroundColor Green
}

return
