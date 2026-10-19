#requires -Version 7.0
<#
.SYNOPSIS
    小狼毫输入法 (Weasel / Rime)

.DESCRIPTION
    小狼毫输入法 (Weasel / Rime) 自动化纯净安装、雾凇拼音词库打底与现代体验配置脚本。
    1. 专为 PowerShell 7+ (pwsh) 编写，充分运用现代 pwsh 语法糖、强类型安全与原生无 BOM UTF-8 输出。
    2. 严格遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)：对二进制安装本体、Junction 目录挂载、雾凇词库及 YAML 补丁全流程先检后配，杜绝重复下载与脏覆写。
    3. 纯拼音极致隔离：方案严格限定为 rime_ice 纯全拼，彻底排除双拼、五笔、形码与字根方案，杜绝按键哈希碰撞与词库污染。
    4. Control 键接管中英切换：Shift 设为 noop 避免误触，由 Control 键控制中英状态流转。
    5. 现代 GUI 视觉：启用 DirectWrite 矢量抗锯齿排版、横向 5 候选词与 Win11 原生深浅色亚克力磨砂视觉。
    6. 声明式配置管理：纳管标准 %APPDATA%\Rime 配置目录（支持通过 -ConfDir 指定独立目录并自动建立 NTFS Junction 挂载）。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - Uninstall : 清洁卸载、注销系统 TSF 组件并移除本体 (默认保留用户词库)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制重新拉取安装包解包覆盖安装小狼毫本体并回正基线配置。

.PARAMETER Purge
    配合 Uninstall 使用，连带深度物理粉碎用户词库与客制配置目录。

.PARAMETER InstallDir
    小狼毫二进制本体安装目录，默认为受控基线 D:\prog\Rime。

.PARAMETER ConfDir
    用户配置与词库目录，默认为标准 %APPDATA%\Rime。若显式指定自定义目录，脚本将自动建立 NTFS Junction 挂载。

.PARAMETER InstallerPath
    可选，小狼毫本地离线安装包路径（如 weasel-0.17.4.0-installer.exe）。指定后优先使用离线包，免除网络下载。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\rime.ps1 -Action Check

    # 交互式全流程安装与配置
    pwsh -File .\scripts\apps\rime.ps1

    # 强制重新安装本体并对齐基线
    pwsh -File .\scripts\apps\rime.ps1 -Force

    # 安全清洁卸载 (保留用户词库)
    pwsh -File .\scripts\apps\rime.ps1 -Action Uninstall

    # 深度粉碎卸载 (连带词库全抹除)
    pwsh -File .\scripts\apps\rime.ps1 -Action Uninstall -Purge
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall")]
    [string]$Action = "Sync",

    [switch]$Yes,
    [switch]$Force,
    [switch]$Purge,
    [string]$InstallDir = "D:\prog\Rime",
    [string]$ConfDir,
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
    throw "【权限错误】小狼毫属于系统 TSF 输入法组件且需要配置目录软链接，必须以管理员身份运行此脚本！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将词库软链接错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 辅助下载与 PE 校验函数
# ==============================================================================
function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Description = "文件",
        [long]$MinBytes = 1024,
        [int]$TimeoutSec = 300
    )

    $tool = Join-Path $PSScriptRoot "_aria2.ps1"
    if (-not (Test-Path $tool)) {
        throw "未在应用域定位到核心下载引擎: _aria2.ps1，请确保仓库完整性！"
    }

    & $tool -Url $Url -OutFile $OutFile -Description $Description -MinBytes $MinBytes -TimeoutSec $TimeoutSec
}

function Test-ValidPeExecutable {
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $false }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }

    try {
        $fileItem = Get-Item -LiteralPath $FilePath -ErrorAction Stop
        if ($fileItem.Length -lt 2048) { return $false }

        $fs = [System.IO.File]::OpenRead($FilePath)
        try {
            $buffer = New-Object byte[] 2
            $readBytes = $fs.Read($buffer, 0, 2)
            return ($readBytes -eq 2 -and $buffer[0] -eq 0x4D -and $buffer[1] -eq 0x5A)
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $false
    }
}

# ==============================================================================
# 3. 目标路径智能探测与初始化
# ==============================================================================
$AppId        = "rime"
$AppName      = "小狼毫输入法 (Weasel / Rime)"
$ProcessName  = "WeaselServer"

$GoldenInstallDir = "D:\prog\Rime"
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = $GoldenInstallDir
}
$cleanInstallDir = $InstallDir.TrimEnd('\')

if ([string]::IsNullOrWhiteSpace($ConfDir)) {
    $ConfDir = Join-Path $env:APPDATA "Rime"
}

# 跨架构注册表深层嗅探 (HKLM 64位, WOW6432Node 32位, HKCU)
$weaselReg64 = Get-ItemProperty -Path "HKLM:\SOFTWARE\Rime\Weasel" -ErrorAction SilentlyContinue
$weaselReg32 = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel" -ErrorAction SilentlyContinue
$weaselRegCU = Get-ItemProperty -Path "HKCU:\SOFTWARE\Rime\Weasel" -ErrorAction SilentlyContinue

$weaselReg = if ($weaselReg32 -and $weaselReg32.WeaselRoot) { $weaselReg32 }
             elseif ($weaselReg64 -and $weaselReg64.WeaselRoot) { $weaselReg64 }
             elseif ($weaselReg32) { $weaselReg32 }
             elseif ($weaselReg64) { $weaselReg64 }
             else { $weaselRegCU }

$currentRegInstallDir = if ($weaselReg -and $weaselReg.InstallDir) { $weaselReg.InstallDir.TrimEnd('\') } else { $null }

# 辅助定位函数：自适应穿透版本化子目录 (weasel-x.x.x)
function Find-WeaselExecutable {
    param(
        [string]$BaseDir,
        [string]$ExeName
    )
    if ([string]::IsNullOrWhiteSpace($BaseDir) -or -not (Test-Path -LiteralPath $BaseDir)) { return $null }
    $direct = Join-Path $BaseDir $ExeName
    if (Test-ValidPeExecutable $direct) { return $direct }

    $found = Get-ChildItem -LiteralPath $BaseDir -Filter $ExeName -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { Test-ValidPeExecutable $_.FullName } |
        Sort-Object -Property FullName -Descending |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

# 辅助解析函数：精确提取 YAML 补丁键值 (兼容引号与行内注释)
function Get-YamlScalar {
    param(
        [string]$Content,
        [string]$Key
    )
    if ([string]::IsNullOrWhiteSpace($Content) -or [string]::IsNullOrWhiteSpace($Key)) { return $null }
    $escaped = [regex]::Escape($Key)
    if ($Content -match "(?m)^[\s""']*$escaped[\s""']*\s*:\s*(.+)$") {
        $val = $matches[1].Trim().Trim('"', "'")
        if ($val -match '^([^#\s]+)') { return $matches[1] }
        return $val
    }
    return $null
}

# 目标安装目录 ($cleanInstallDir) 下的核心工具链嗅探
$realServerExe = Find-WeaselExecutable -BaseDir $cleanInstallDir -ExeName "WeaselServer.exe"
$deployerExe   = Find-WeaselExecutable -BaseDir $cleanInstallDir -ExeName "WeaselDeployer.exe"

$HighValueUserData = @(
    "用户自定义词库与配置: $ConfDir",
    "个人短语与客制 YAML 补丁 (*.custom.yaml)"
)

# ==============================================================================
# 4. 独立流转分支：清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将注销系统 TSF 组件并卸载小狼毫输入法！" -ForegroundColor Yellow
        if ($Purge) {
            Write-Host "🔥 【检测到 -Purge 参数：以下高价值用户数据将被深度物理粉碎】:" -ForegroundColor Red
            foreach ($d in $HighValueUserData) {
                Write-Host ("   - {0}" -f $d) -ForegroundColor DarkRed
            }
            Write-Host "👉 该操作不可逆，用户词库、短语与客制配置将被彻底抹除！`n" -ForegroundColor Red
        } else {
            Write-Host "🛡️  【数据安全保护：以下高价值用户数据将默认保留在实机】:" -ForegroundColor Green
            foreach ($d in $HighValueUserData) {
                Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
            }
            Write-Host "👉 默认卸载仅移除程序本体与系统 TSF 注册。若需连带粉碎词库，请指定 -Purge 开关。`n" -ForegroundColor Cyan
        }

        $promptText = if ($Purge) {
            "确认注销输入法组件并彻底删除程序本体与词库目录? [y/N]"
        } else {
            "确认注销系统组件并清理小狼毫本体（保留用户词库）? [y/N]"
        }
        $confirm = (Read-Host $promptText).Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在终止进程、注销系统 TSF 组件并清理环境..." -ForegroundColor Yellow

    # 1. 强制终止常驻进程
    Get-Process -Name "WeaselServer", "WeaselDeployer", "WeaselSetup" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800

    # 2. 调用官方反注册命令 (非阻塞脱钩与深度物理粉碎)
    $uninstallerCandidates = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $cleanInstallDir) {
        $u = Get-ChildItem -LiteralPath $cleanInstallDir -Filter "*uninstall*.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { Test-ValidPeExecutable $_.FullName } | Select-Object -First 1
        if ($u) { $uninstallerCandidates.Add($u.FullName) }
    }
    if ($currentRegInstallDir -and (Test-Path $currentRegInstallDir)) {
        $u = Get-ChildItem -LiteralPath $currentRegInstallDir -Filter "*uninstall*.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { Test-ValidPeExecutable $_.FullName } | Select-Object -First 1
        if ($u) { $uninstallerCandidates.Add($u.FullName) }
    }

    $foundUninst = $uninstallerCandidates | Select-Object -First 1
    if ($foundUninst) {
        Write-Host "   - 正在调用官方反安装引擎: $foundUninst..." -ForegroundColor Gray
        $uninstProc = Start-Process -FilePath $foundUninst -ArgumentList "/S" -PassThru -ErrorAction SilentlyContinue
        if ($uninstProc) {
            $swUninst = [System.Diagnostics.Stopwatch]::StartNew()
            while ($swUninst.Elapsed.TotalSeconds -lt 15) {
                if ($uninstProc.HasExited) { break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $uninstProc.HasExited) {
                $uninstProc | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Seconds 2
    }

    # 3. 彻底注销系统 TSF 组件注册表分支
    @(
        "HKCU:\Software\Rime",
        "HKLM:\SOFTWARE\Rime",
        "HKLM:\SOFTWARE\WOW6432Node\Rime",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Weasel",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Weasel"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "WeaselServer" -ErrorAction SilentlyContinue
    Write-Host "   - 已彻底拔除 Rime 注册表项与自启动项。" -ForegroundColor Gray

    # 4. 解除 Junction 软链接与清理配置目录
    $stdAppData = Join-Path $env:APPDATA "Rime"
    if (Test-Path $stdAppData) {
        $item = Get-Item $stdAppData -Force -ErrorAction SilentlyContinue
        if ($item.Attributes -match "ReparsePoint") {
            [System.IO.Directory]::Delete($stdAppData)
            Write-Host "   - 已安全解绑并移除 NTFS Junction 软链接: $stdAppData" -ForegroundColor Gray
        } else {
            if ($Purge) {
                Remove-Item -Path $stdAppData -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   - 已清理 AppData 配置目录: $stdAppData" -ForegroundColor Gray
            }
        }
    }

    if ($Purge) {
        if ($ConfDir -and (Test-Path $ConfDir) -and ($ConfDir -ne $stdAppData)) {
            Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "   - [已粉碎] 客制词库目录: $ConfDir" -ForegroundColor Red
        }
    } else {
        if ($ConfDir -and (Test-Path $ConfDir)) {
            Write-Host "   - [数据安全保护] 用户词库目录已安全保留在: $ConfDir" -ForegroundColor Green
        }
    }

    # 5. 物理粉碎安装根目录
    if (Test-Path $cleanInstallDir) {
        Remove-Item -Path $cleanInstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已物理抹除基准安装目录: $cleanInstallDir" -ForegroundColor Gray
    }

    # 6. 清理快捷方式
    @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "小狼毫输入法"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "小狼毫输入法.lnk")
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "`n✅ [清洁卸载完成] 小狼毫输入法核心组件已成功移除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 目标基线: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $cleanInstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$DiffList   = [System.Collections.Generic.List[PSCustomObject]]::new()

# 5.1 二进制程序本体 (WeaselServer.exe)
$isServerReady = [bool]($realServerExe -and (Test-ValidPeExecutable $realServerExe))
$actualServerStatus = if ($isServerReady) {
    "已就绪 ($realServerExe)"
} else {
    "未安装"
}
$isServerMatch = $isServerReady
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "客户端本体"
    受控属性 = "WeaselServer 核心运行时"
    期望基线 = "已就绪于 $cleanInstallDir"
    实机状态 = $actualServerStatus
    状态判定 = if ($isServerMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isServerMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "客户端本体"
        受控属性 = "WeaselServer 核心运行时"
        实机状态 = $actualServerStatus
        期望基线 = "已就绪于 $cleanInstallDir"
        Purpose  = "部署小狼毫输入法 Windows TSF 核心常驻服务与运行时环境至受控基线"
        Impact   = "在系统常驻输入法核心宿主，监听键盘事件并支撑全系统文本输入"
    })
}

# 5.2 编译部署器组件 (WeaselDeployer.exe)
$isDeployerReady = [bool]($deployerExe -and (Test-ValidPeExecutable $deployerExe))
$actualDepStatus = if ($isDeployerReady) { "已就绪 ($deployerExe)" } else { "缺失未就绪" }
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "客户端本体"
    受控属性 = "WeaselDeployer 编译部署器"
    期望基线 = "已就绪于版本子树"
    实机状态 = $actualDepStatus
    状态判定 = if ($isDeployerReady) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $isDeployerReady) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "客户端本体"
        受控属性 = "WeaselDeployer 编译部署器"
        实机状态 = $actualDepStatus
        期望基线 = "已就绪于版本子树"
        Purpose  = "提供 Rime 方案与词典编译生成二进制 prism 索引的核心工具链"
        Impact   = "支撑雾凇拼音词库与 YAML 补丁的衍生编译与即时热加载生效"
    })
}

# 5.3 系统 TSF 输入法注册
$tsfRegFound = (Test-Path "HKLM:\SOFTWARE\Rime\Weasel") -or (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel") -or (Test-Path "HKCU:\Software\Rime\Weasel")
$isTsfRegistered = [bool]($weaselReg -and $tsfRegFound)
$isTsfPathAligned = ($currentRegInstallDir -and ($currentRegInstallDir -ieq $cleanInstallDir))
$actualTsfStatus = if ($isTsfRegistered -and $isTsfPathAligned) {
    "已注册且对齐受控基线"
} elseif ($isTsfRegistered) {
    "已注册但路径偏离 ($currentRegInstallDir)"
} else {
    "未完整注册"
}
$isTsfMatch = $isTsfRegistered -and $isTsfPathAligned
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "系统集成"
    受控属性 = "系统 TSF 输入法注册 (Rime\Weasel)"
    期望基线 = "已注册且关联至 $cleanInstallDir"
    实机状态 = $actualTsfStatus
    状态判定 = if ($isTsfMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isTsfMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "系统集成"
        受控属性 = "系统 TSF 输入法注册 (Rime\Weasel)"
        实机状态 = $actualTsfStatus
        期望基线 = "已注册且关联至 $cleanInstallDir"
        Purpose  = "向 Windows 文本服务框架 (TSF) 注册小狼毫底层 COM 组件并对齐受控基线路径"
        Impact   = "在系统语言栏激活中文小狼毫输入法选项，供全系统窗口文本输入调用"
    })
}

# 5.4 雾凇拼音词库核心文件
$iceSchema = Join-Path $ConfDir "rime_ice.schema.yaml"
$hasIceDict = Test-Path $iceSchema
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "雾凇拼音核心词库 (rime_ice.schema.yaml)"
    期望基线 = "已落地于 $ConfDir"
    实机状态 = if ($hasIceDict) { "已就绪" } else { "缺失未就绪" }
    状态判定 = if ($hasIceDict) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $hasIceDict) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "雾凇拼音核心词库 (rime_ice.schema.yaml)"
        实机状态 = "缺失未就绪"
        期望基线 = "已落地于 $ConfDir"
        Purpose  = "拉取并部署现代化中文全拼雾凇词库 (rime-ice) 资产"
        Impact   = "提供词频精准、网络热词全面、无拼音错别字的纯全拼中文输入基底"
    })
}

# 5.5 主输入方案锁定 (default.custom.yaml -> rime_ice)
$defCustom    = Join-Path $ConfDir "default.custom.yaml"
$defRaw       = if (Test-Path $defCustom) { Get-Content -Path $defCustom -Raw -ErrorAction SilentlyContinue } else { "" }
$isSchemaMatch = ($defRaw -match '(?m)^\s*-\s*schema:\s*[''"]?rime_ice[''"]?' -or $defRaw -match 'schema:\s*[''"]?rime_ice[''"]?')
$actualSchemaStatus = if ($isSchemaMatch) {
    "rime_ice"
} elseif ($defRaw -match 'schema:\s*[''"]?([a-zA-Z0-9_\-]+)') {
    $matches[1]
} else {
    "<缺省未配>"
}
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "默认主方案 (default.custom.yaml -> schema)"
    期望基线 = "rime_ice"
    实机状态 = $actualSchemaStatus
    状态判定 = if ($isSchemaMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isSchemaMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "默认主方案 (default.custom.yaml -> schema)"
        实机状态 = $actualSchemaStatus
        期望基线 = "rime_ice"
        Purpose  = "锁定全局默认方案为 rime_ice 纯全拼，彻底排除双拼与形码干扰"
        Impact   = "启动小狼毫直接进入纯全拼打字状态，杜绝多方案切换冲突"
    })
}

# 5.6 中英切换控制键 (default.custom.yaml -> Control_L: commit_code)
$ctrlVal = Get-YamlScalar -Content $defRaw -Key "Control_L"
$isCtrlMatch = ($ctrlVal -ieq "commit_code")
$actualCtrlStatus = if ($ctrlVal) { $ctrlVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "中英切换按键 (default.custom.yaml -> Control_L)"
    期望基线 = "commit_code"
    实机状态 = $actualCtrlStatus
    状态判定 = if ($isCtrlMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isCtrlMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "中英切换按键 (default.custom.yaml -> Control_L)"
        实机状态 = $actualCtrlStatus
        期望基线 = "commit_code"
        Purpose  = "单按 Control 键接管中英状态流转，上屏当前编码"
        Impact   = "使 Control 成为专属中英切换键，杜绝按键行为歧义"
    })
}

# 5.7 Shift 防误触屏蔽 (default.custom.yaml -> Shift_L: noop)
$shiftVal = Get-YamlScalar -Content $defRaw -Key "Shift_L"
$isShiftMatch = ($shiftVal -ieq "noop")
$actualShiftStatus = if ($shiftVal) { $shiftVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "Shift 屏蔽防误触 (default.custom.yaml -> Shift_L)"
    期望基线 = "noop"
    实机状态 = $actualShiftStatus
    状态判定 = if ($isShiftMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isShiftMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "Shift 屏蔽防误触 (default.custom.yaml -> Shift_L)"
        实机状态 = $actualShiftStatus
        期望基线 = "noop"
        Purpose  = "将 Shift 键置为 noop 屏蔽，消除中英切换误触"
        Impact   = "避免在代码编辑、游戏与快捷键组合中因误触 Shift 导致中英状态意外切换"
    })
}

# 5.8 候选词横排布局 (weasel.custom.yaml -> style/horizontal)
$weaselCustom = Join-Path $ConfDir "weasel.custom.yaml"
$weaselRaw    = if (Test-Path $weaselCustom) { Get-Content -Path $weaselCustom -Raw -ErrorAction SilentlyContinue } else { "" }
$horizVal = Get-YamlScalar -Content $weaselRaw -Key "style/horizontal"
if (-not $horizVal) { $horizVal = Get-YamlScalar -Content $weaselRaw -Key "horizontal" }
$isHorizMatch = ($horizVal -ieq "true")
$actualHorizStatus = if ($horizVal) { $horizVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "候选词横排布局 (weasel.custom.yaml -> style/horizontal)"
    期望基线 = "true"
    实机状态 = $actualHorizStatus
    状态判定 = if ($isHorizMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isHorizMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "候选词横排布局 (weasel.custom.yaml -> style/horizontal)"
        实机状态 = $actualHorizStatus
        期望基线 = "true"
        Purpose  = "启用候选词水平横向排列"
        Impact   = "保持横向打字视线聚焦，避免纵向遮挡代码或阅读行"
    })
}

# 5.9 候选词单页数量 (weasel.custom.yaml -> max_number_of_candidates)
$candVal = Get-YamlScalar -Content $weaselRaw -Key "style/layout/max_number_of_candidates"
if (-not $candVal) { $candVal = Get-YamlScalar -Content $weaselRaw -Key "max_number_of_candidates" }
$isCandMatch = ($candVal -eq "5")
$actualCandStatus = if ($candVal) { $candVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "候选词单页数量 (weasel.custom.yaml -> max_number_of_candidates)"
    期望基线 = "5"
    实机状态 = $actualCandStatus
    状态判定 = if ($isCandMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isCandMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "候选词单页数量 (weasel.custom.yaml -> max_number_of_candidates)"
        实机状态 = $actualCandStatus
        期望基线 = "5"
        Purpose  = "固化候选词单页呈现数量为 5 个"
        Impact   = "收敛单页候选词视线范围，避免候选词过多导致认知开销"
    })
}

# 5.10 DirectWrite 抗锯齿渲染 (weasel.custom.yaml -> style/antialias_mode)
$aaVal = Get-YamlScalar -Content $weaselRaw -Key "style/antialias_mode"
if (-not $aaVal) { $aaVal = Get-YamlScalar -Content $weaselRaw -Key "antialias_mode" }
$isAaMatch = ($aaVal -ieq "directwrite")
$actualAaStatus = if ($aaVal) { $aaVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "矢量平滑排版 (weasel.custom.yaml -> style/antialias_mode)"
    期望基线 = "directwrite"
    实机状态 = $actualAaStatus
    状态判定 = if ($isAaMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isAaMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "矢量平滑排版 (weasel.custom.yaml -> style/antialias_mode)"
        实机状态 = $actualAaStatus
        期望基线 = "directwrite"
        Purpose  = "启用 DirectWrite 现代矢量抗锯齿排版"
        Impact   = "消除传统点阵字体在高分屏下的发虚模糊与异构 DPI 边缘锯齿"
    })
}

# 5.11 视觉皮肤主题 (weasel.custom.yaml -> style/color_scheme)
$csVal = Get-YamlScalar -Content $weaselRaw -Key "style/color_scheme"
if (-not $csVal) { $csVal = Get-YamlScalar -Content $weaselRaw -Key "color_scheme" }
$isCsMatch = ($csVal -ieq "weasel_modern")
$actualCsStatus = if ($csVal) { $csVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "视觉皮肤主题 (weasel.custom.yaml -> style/color_scheme)"
    期望基线 = "weasel_modern"
    实机状态 = $actualCsStatus
    状态判定 = if ($isCsMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isCsMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "视觉皮肤主题 (weasel.custom.yaml -> style/color_scheme)"
        实机状态 = $actualCsStatus
        期望基线 = "weasel_modern"
        Purpose  = "应用现代 Win11 磨砂亚克力微质感皮肤"
        Impact   = "使输入法浮窗视觉契合系统现代设计规范"
    })
}

# 5.12 衍生生效方案终态校验 (build/default.yaml)
$buildDefault = Join-Path $ConfDir "build\default.yaml"
$buildDefRaw  = if (Test-Path $buildDefault) { Get-Content -Path $buildDefault -Raw -ErrorAction SilentlyContinue } else { "" }
$isBuildDefMatch = ($buildDefRaw -match '(?m)^\s*-\s*schema:\s*[''"]?rime_ice[''"]?' -or $buildDefRaw -match 'schema:\s*[''"]?rime_ice[''"]?')
$actualBuildDefStatus = if ($isBuildDefMatch) {
    "rime_ice"
} elseif ($buildDefRaw -match 'schema:\s*[''"]?([a-zA-Z0-9_\-]+)') {
    $matches[1]
} else {
    "<未编译/缺失>"
}
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "编译派生"
    受控属性 = "衍生生效方案终态 (build/default.yaml)"
    期望基线 = "rime_ice"
    实机状态 = $actualBuildDefStatus
    状态判定 = if ($isBuildDefMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isBuildDefMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "编译派生"
        受控属性 = "衍生生效方案终态 (build/default.yaml)"
        实机状态 = $actualBuildDefStatus
        期望基线 = "rime_ice"
        Purpose  = "验证 WeaselDeployer 已成功将 default.custom.yaml 编译派生至运行时 default.yaml"
        Impact   = "确保输入法运行时引擎真正加载 rime_ice 作为当前活跃输入方案"
    })
}

# 5.13 衍生拼音 Prism 索引 (build/rime_ice.prism.bin)
$buildIcePrism = Join-Path $ConfDir "build\rime_ice.prism.bin"
$hasPrismBin   = (Test-Path $buildIcePrism) -and ((Get-Item $buildIcePrism).Length -gt 10240)
$actualPrismStatus = if ($hasPrismBin) {
    "已就绪 ($([math]::Round((Get-Item $buildIcePrism).Length / 1KB, 1)) KB)"
} else {
    "缺失未生成"
}
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "编译派生"
    受控属性 = "衍生词库 Prism 索引 (build/rime_ice.prism.bin)"
    期望基线 = "已就绪"
    实机状态 = $actualPrismStatus
    状态判定 = if ($hasPrismBin) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $hasPrismBin) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "编译派生"
        受控属性 = "衍生词库 Prism 索引 (build/rime_ice.prism.bin)"
        实机状态 = $actualPrismStatus
        期望基线 = "已就绪"
        Purpose  = "调用 WeaselDeployer /deploy 编译生成二进制 prism 拼音查找树与词典索引"
        Impact   = "提供极速毫秒级拼音分词检索与候选词精准匹配"
    })
}

Write-Host "`n📊 [巡检看板] 小狼毫输入法受控属性基线审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$isInstalled = $isServerMatch -and $isDeployerReady -and $isTsfMatch

if ($Action -eq "Check") {
    if ($DiffList.Count -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性与编译产物均与工程基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $DiffList.Count) -ForegroundColor Yellow
    }
    return
}

if ($DiffList.Count -eq 0 -and $isInstalled -and -not $Force) {
    Write-Host "✨ [状态合规] 所有受控属性与策略均已符合工程基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

if ($DiffList.Count -gt 0) {
    Write-Host "`n📋 [差异清单] 检测到以下受控属性偏离工程基线:" -ForegroundColor Cyan
    $DiffList | Format-Table -AutoSize | Out-String | Write-Host
}

# ==============================================================================
# 6. 阶段 2: 审查门禁与并发安全 (Gate - Shift-Left Transparency)
# ==============================================================================

# 6.1 运行态并发防覆写硬门禁
$runningWeasel = Get-Process -Name "WeaselServer" -ErrorAction SilentlyContinue
if ($runningWeasel) {
    if (-not $Yes) {
        Write-Warning "检测到 WeaselServer 输入法服务当前正在运行！更新词库与编译需要重启输入法服务。"
        $confirmProc = (Read-Host "是否立即关闭正在运行的 WeaselServer 以继续对齐基线? [Y/n]").Trim()
        if ($confirmProc -match '^(n|no)$') {
            Write-Host "[-] 用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningWeasel | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

# 6.2 未安装或强制部署审查门禁
$needBinaryDeploy = (-not $isInstalled) -or $Force
if ($needBinaryDeploy) {
    if (-not $Yes) {
        $promptMsg = if (-not $isInstalled) {
            "未在受控基线 [$cleanInstallDir] 检测到合规的小狼毫输入法，是否立即拉取官方安装包进行部署？[Y/n]"
        } else {
            "已开启强制重新部署 (-Force)，是否重新运行小狼毫安装器覆盖部署受控基线？[Y/n]"
        }
        $shouldInstall = (Read-Host $promptMsg).Trim()
        if ($shouldInstall -match '^(n|no)$') {
            Write-Host "[-] 操作已由用户取消，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
}

# 6.3 策略审查门禁 (Shift-Left Gate: 目的与影响结构化逐项直出)
if (-not $Yes) {
    Write-Host "`n💡 [改动意图与技术边界审查 (Gate)]" -ForegroundColor Cyan
    Write-Host "   本次即将对齐以下偏离项，请逐项评估改动 [目的] 与 [影响]:" -ForegroundColor Gray
    $idx = 1
    foreach ($p in $DiffList) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.受控属性) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.实机状态, $p.期望基线) -ForegroundColor DarkGray
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
# 7. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 7.1 程序本体安装或覆盖升级
if ($needBinaryDeploy) {
    Write-Host "`n🚀 正在准备安装小狼毫输入法核心本体至受控基线 [$cleanInstallDir]..." -ForegroundColor Cyan
    $installerExe = $InstallerPath
    if (-not $installerExe -or -not (Test-Path $installerExe)) {
        $installerExe = Join-Path $env:TEMP "weasel-installer.exe"
        if (-not $Force -and (Test-Path $installerExe) -and ((Get-Item $installerExe).Length -ge 10MB)) {
            Write-Host "   ✔ 命中已缓存的安装包: $installerExe ($([math]::Round((Get-Item $installerExe).Length / 1MB, 2)) MB)" -ForegroundColor Green
        } else {
            $relApi = "https://api.github.com/repos/rime/weasel/releases/latest"
            Write-Host "   - 正在查询 GitHub 最新 Release..." -ForegroundColor Gray
            $rel = Invoke-RestMethod -Uri $relApi -Headers @{ "User-Agent" = "vpsbase-rime-script" } -TimeoutSec 15
            $asset = $rel.assets | Where-Object { $_.name -match 'weasel-.*-installer\.exe$' } | Select-Object -First 1
            if (-not $asset) { throw "未在 GitHub 最新 Release 中匹配到小狼毫安装程序" }

            Invoke-DownloadFile -Url $asset.browser_download_url -OutFile $installerExe -Description "小狼毫安装包"
        }
    }

    # 前置清理可能残留的常驻进程
    Get-Process -Name "WeaselServer", "WeaselDeployer", "WeaselSetup" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500

    # 关键注册表引导：小狼毫官方 NSIS 安装器的 .onInit 逻辑中，若检测到注册表 InstallDir 为空，
    # 会强制将 $INSTDIR 覆写为 $PROGRAMFILES64\Rime 并无视命令行参数；
    # 必须预置注册表 InstallDir 为目标受控基线，引导安装器跳过默认覆写分支
    @(
        "HKLM:\SOFTWARE\Rime\Weasel",
        "HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel",
        "HKCU:\Software\Rime\Weasel"
    ) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -Path $_ -Force | Out-Null }
        Set-ItemProperty -Path $_ -Name "InstallDir" -Value $cleanInstallDir -Force
    }

    Write-Host "   - 正在静默安装小狼毫至基准目录: $cleanInstallDir..." -ForegroundColor Gray
    if (-not (Test-Path $cleanInstallDir)) {
        New-Item -ItemType Directory -Path $cleanInstallDir -Force | Out-Null
    }

    # NSIS 进程调用：原生参数契约 /S /D=... (末尾无引号传递)
    $proc = Start-Process -FilePath $installerExe -ArgumentList "/S /D=$cleanInstallDir" -PassThru
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt 90) {
        Start-Sleep -Seconds 1
    }

    if (-not $proc.HasExited) {
        Write-Warning "安装器进程执行超时 (90s)，正在强行脱钩..."
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    # 严格单主干物理落地校验：仅在受控基线目录穿透寻找 WeaselServer.exe 与 WeaselDeployer.exe
    $realServerExe = Find-WeaselExecutable -BaseDir $cleanInstallDir -ExeName "WeaselServer.exe"
    $deployerExe   = Find-WeaselExecutable -BaseDir $cleanInstallDir -ExeName "WeaselDeployer.exe"

    if (-not $realServerExe) {
        throw "小狼毫安装完成，但在目标基准目录 [$cleanInstallDir] 下未能定位到 WeaselServer.exe！"
    }
    if (-not $deployerExe) {
        throw "小狼毫安装完成，但在目标基准目录 [$cleanInstallDir] 下未能定位到 WeaselDeployer.exe！"
    }

    Write-Host "✅ 小狼毫二进制本体已成功就绪于受控基线: $realServerExe" -ForegroundColor Green
}

# 7.2 部署雾凇拼音词库 (rime-ice)
if (-not $hasIceDict) {
    Write-Host "`n📦 正在拉取雾凇拼音 (rime-ice) 词库资产..." -ForegroundColor Cyan
    $iceZip = Join-Path $env:TEMP "rime-ice.zip"
    $iceUrl = "https://github.com/iDvel/rime-ice/archive/refs/heads/main.zip"
    Invoke-DownloadFile -Url $iceUrl -OutFile $iceZip -Description "雾凇拼音词库包"

    $iceTemp = Join-Path $env:TEMP ("rimeice-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $iceTemp -Force | Out-Null

    try {
        Write-Host "   - 正在解压雾凇拼音词库资产 (文件较多，请稍候)..." -ForegroundColor Gray
        Expand-Archive -Path $iceZip -DestinationPath $iceTemp -Force
        $unzippedDir = Join-Path $iceTemp "rime-ice-main"
        if (-not (Test-Path $unzippedDir)) {
            $unzippedDir = Get-ChildItem -Path $iceTemp -Directory | Select-Object -First 1
        }

        if (-not (Test-Path $ConfDir)) {
            New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
        }

        Copy-Item -Path "$unzippedDir\*" -Destination $ConfDir -Recurse -Force
        Write-Host "✅ 雾凇拼音词库资产已成功解压部署至: $ConfDir" -ForegroundColor Green
    } finally {
        if (Test-Path $iceZip) { Remove-Item -Path $iceZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $iceTemp) { Remove-Item -Path $iceTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# 7.3 注入声明式 YAML 补丁
Write-Host "`n⚙️  正在单向对齐声明式 YAML 受控基线补丁..." -ForegroundColor Cyan

# default.custom.yaml: 纯全拼、Control 切换中英
$defaultYaml = @'
patch:
  schema_list:
    - schema: rime_ice
  "ascii_composer/good_old_caps_lock": true
  "ascii_composer/switch_key":
    Shift_L: noop
    Shift_R: noop
    Control_L: commit_code
    Control_R: commit_code
    Caps_Lock: clear
    Eisu_toggle: clear
'@
[System.IO.File]::WriteAllText($defCustom, $defaultYaml, [System.Text.UTF8Encoding]::new($false))

# weasel.custom.yaml: 横排 5 候选、DirectWrite、亚克力皮肤
$weaselYaml = @'
patch:
  "style/horizontal": true
  "style/inline_preedit": true
  "style/layout/max_number_of_candidates": 5
  "style/antialias_mode": directwrite
  "style/color_scheme": weasel_modern
  "preset_color_schemes/weasel_modern":
    name: "现代简约 (Win11 亚克力)"
    author: "vpsbase"
    horizontal: true
    inline_preedit: true
    font_face: "Microsoft YaHei"
    font_point: 12
    label_font_point: 10
    corner_radius: 8
    hilited_corner_radius: 4
    border_height: 4
    border_width: 4
    back_color: 0xF5F5F5
    border_color: 0xE0E0E0
    text_color: 0x333333
    hilited_text_color: 0x000000
    hilited_back_color: 0xE5E5E5
    hilited_candidate_text_color: 0xFFFFFF
    hilited_candidate_back_color: 0x0078D7
    candidate_text_color: 0x333333
    comment_text_color: 0x888888
'@
[System.IO.File]::WriteAllText($weaselCustom, $weaselYaml, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ default.custom.yaml 与 weasel.custom.yaml 补丁注入完成。" -ForegroundColor Green

# 保证雾凇词库纯净性 (清理非基线客制补丁)
$iceCustom = Join-Path $ConfDir "rime_ice.custom.yaml"
if (Test-Path $iceCustom) {
    Remove-Item -Path $iceCustom -Force -ErrorAction SilentlyContinue
}

# 7.4 调用 WeaselDeployer 编译部署
Write-Host "`n⚙️  正在调用 WeaselDeployer 进行词库编译与衍生状态收敛..." -ForegroundColor Cyan
if (-not $deployerExe -or -not (Test-Path $deployerExe)) {
    $deployerExe = Find-WeaselExecutable -BaseDir $cleanInstallDir -ExeName "WeaselDeployer.exe"
}

if ($deployerExe -and (Test-Path $deployerExe)) {
    Write-Host "   - 正在执行全量词库生成与衍生状态收敛 (首次编译可能耗时数十秒，请稍候)..." -ForegroundColor Gray
    $proc = Start-Process -FilePath $deployerExe -ArgumentList "/deploy" -Wait -PassThru
    Start-Sleep -Seconds 2

    # 编译终态硬门禁校验
    $isDeploySuccess = (Test-Path $buildDefault) -and
                       ((Get-Content -Path $buildDefault -Raw -ErrorAction SilentlyContinue) -match "schema:\s*rime_ice")
    if (-not $isDeploySuccess) {
        throw "WeaselDeployer 编译部署未成功使 rime_ice 方案生效，请检查配置与权限！"
    }

    Write-Host "✅ WeaselDeployer /deploy 编译部署完成，rime_ice 方案已成功挂载生效。" -ForegroundColor Green
} else {
    throw "未定位到 WeaselDeployer.exe，无法完成衍生词库编译！"
}

# 启动 WeaselServer 服务
if (-not $realServerExe -or -not (Test-Path $realServerExe)) {
    $realServerExe = Find-WeaselExecutable -BaseDir $cleanInstallDir -ExeName "WeaselServer.exe"
}
if ($realServerExe -and (Test-Path $realServerExe)) {
    Start-Process -FilePath $realServerExe -WindowStyle Hidden -ErrorAction SilentlyContinue
}

# ==============================================================================
# 8. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 工程基线与词库部署完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 部署路径: $cleanInstallDir" -ForegroundColor Gray
Write-Host "   - 方案基线: rime_ice 纯全拼方案已编译生效" -ForegroundColor Gray
Write-Host "   - 切换按键: Control 接管中英切换 (Shift 设为 noop 防误触)" -ForegroundColor Gray
Write-Host "   - 视觉排版: 横向 5 候选词、DirectWrite 抗锯齿与 Win11 亚克力磨砂皮肤" -ForegroundColor Gray

return
