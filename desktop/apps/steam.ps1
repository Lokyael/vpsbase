#requires -Version 7.0
<#
.SYNOPSIS
    Steam 平台

.DESCRIPTION
    Steam 平台 (Windows) 自动化纯净安装、系统开机项管控与全局性能基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，运用现代 pwsh 语法与原生无 BOM UTF-8 输出。
    2. 严格遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)：对系统注册表自启动项、全局 config.vdf 性能策略及用户偏好进行逐项比对，拒绝盲目覆盖。
    3. 配置 Apply 确认 Steam 已退出后重读当前 VDF，基于最新内容合并；写入前复查进程、文件存在性及内容，检测到冲突即报错，不自动重试。不承诺检查与写入之间对外部进程的绝对互斥。
    4. 系统自启动项精准管控：精准读写 HKCU Run 注册表，阻断开机常驻自启以释放冷启动负载。
    5. 全局性能与网络基线对齐：
       - 禁用局域网对等传输 (PeerContentServerMode=0)，消除后台上传、端口监听及组播泛洪；
       - 禁用后台着色器预编译 (bShaderCacheBGProcessingEnabled=0)，避免电脑闲置时后台编译占用 CPU 资源；
       - 禁止游戏运行时后台下载 (AllowDownloadsDuringGameplay=0)，保障竞技网络低延迟与磁盘 IO 稳定。
    6. 用户偏好规范化：将 Steam 客户端默认界面语言锁定为简体中文 (schinese)。
    7. 防火墙基线：按当前 Steam 与已发现 WebHelper 组件共用规则规格，委派内部辅助算子 _firewall.ps1 巡检、修复和回读本地入站阻断规则；不修改系统默认策略，不将配置检查等同实际流量验收。
    8. config.vdf 按 InstallConfigStore/Software/Valve/Steam 完整路径读取并定点更新直接子键，保留其他内容；已有文件损坏、目标路径缺失/歧义或含条件/包含指令时阻断，写入后回读校验受控值。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (只读比对受控属性 Diff)
    - Uninstall : 移除 Steam 核心运行时与服务，默认保留安装目录内 steamapps、userdata

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制重新拉取官方安装包覆盖部署 Steam 客户端核心并回正配置。

.PARAMETER Purge
    配合 Uninstall 使用，删除安装目录内 steamapps 游戏库与 userdata 用户数据；不追踪外部游戏库或目录外存档，不等于安全擦除。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\desktop\apps\steam.ps1 -Action Check

    # 交互式检查并应用工程基线
    pwsh -File .\desktop\apps\steam.ps1

    # 强制重新部署覆盖本体并对齐基线
    pwsh -File .\desktop\apps\steam.ps1 -Force

    # 安全清洁卸载 (保留游戏库与存档)
    pwsh -File .\desktop\apps\steam.ps1 -Action Uninstall

    # 卸载并删除安装目录内游戏库与用户数据 (不处理外部库与目录外存档)
    pwsh -File .\desktop\apps\steam.ps1 -Action Uninstall -Purge
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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and $Action -ne "Check") {
    throw "【权限错误】Steam 自动化部署与系统开机项管控需管理员特权，请在提升的 pwsh 会话中重新执行！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将受控配置与注册表错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 应用元数据与部署基准路径锁定 (Golden Baseline Paths)
# ==============================================================================
$AppId        = "steam"
$AppName      = "Steam 游戏平台"
$ProcessName  = "steam"

$steamReg     = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
$InstallDir   = if ($steamReg.SteamPath) { $steamReg.SteamPath -replace '/', '\' } else { "D:\prog\Steam" }
$AppExe       = Join-Path $InstallDir "steam.exe"
$ConfigFile   = Join-Path $InstallDir "config\config.vdf"
$UserDirBase  = Join-Path $InstallDir "userdata"
$SteamVdfPath = @("InstallConfigStore", "Software", "Valve", "Steam")

$HighValueUserData = @(
    "游戏本地库目录 (steamapps): $InstallDir\steamapps",
    "各账号本地存档与截图: $UserDirBase"
)

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Get-SteamFirewallSpecs {
    $specs = @(
        @{ Name = 'Steam-Client-Block-In-TCP'; Program = $AppExe; Protocol = 'TCP'; Desc = 'Steam 客户端 TCP 入站阻断' },
        @{ Name = 'Steam-Client-Block-In-UDP'; Program = $AppExe; Protocol = 'UDP'; Desc = 'Steam 客户端 UDP 入站阻断' }
    )
    $webHelperExe = @(
        (Join-Path $InstallDir 'bin\cef\cef.win7x64\steamwebhelper.exe'),
        (Join-Path $InstallDir 'bin\steamwebhelper.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction Stop } | Select-Object -First 1
    if ($webHelperExe) {
        foreach ($protocol in @('TCP', 'UDP')) {
            $specs += @{ Name = "Steam-WebHelper-Block-In-$protocol"; Program = $webHelperExe; Protocol = $protocol; Desc = "Steam WebHelper $protocol 入站阻断" }
        }
    }
    return ,$specs
}

$firewall = Join-Path $PSScriptRoot "_firewall.ps1"
if (-not (Test-Path $firewall)) {
    throw "未在应用域定位到核心防火墙工具: _firewall.ps1，请确保仓库完整性！"
}

function Get-AppFirewallState {
    param([hashtable]$Spec)
    & $firewall -Task GetState -Spec $Spec
}

function Sync-AppFirewallRules {
    param([object[]]$Specs)
    & $firewall -Task SyncRules -Specs $Specs
}

# 受控属性全景声明清单 (含 Purpose 目的 与 Impact 影响)
$ManagedSpecs = @(
    @{
        Module   = "本体"
        Property = "主执行文件 (steam.exe)"
        Expected = "已就绪 ($AppExe)"
        Purpose  = "部署 Steam 官方游戏客户端核心本体"
        Impact   = "若未就绪将自动拉取官方安装包部署至 $InstallDir"
        Type     = "Binary"
    },
    @{
        Module   = "集成"
        Property = "开机自启动 (HKCU Run Steam)"
        Expected = "已清除 (禁用自启)"
        Purpose  = "从注册表 Run 项中移除 Steam 开机自启"
        Impact   = "开机冷启动阶段不再常驻 Steam 及其多个 WebHelper 进程，释放 500MB+ 内存"
        Type     = "RunKey"
    },
    @{
        Module   = "集成"
        Property = "注册表界面语言 (HKCU Valve\Steam Language)"
        Expected = "schinese"
        Purpose  = "锁定当前用户注册表中 Steam 客户端首选界面语言"
        Impact   = "Steam 启动和 CEF 登录窗口将按简体中文加载"
        Type     = "RegLanguage"
    },
    @{
        Module   = "配置"
        Key      = "Language"
        Property = "客户端默认语言 (Language = schinese)"
        Expected = "schinese"
        Purpose  = "将 Steam 客户端界面语言固定为简体中文"
        Impact   = "Steam 重启后以简体中文显示；游戏本身的语言设置不受影响"
        Type     = "Vdf"
    },
    @{
        Module   = "配置"
        Key      = "PeerContentServerMode"
        Property = "局域网对等传输 (PeerContentServerMode = 0)"
        Expected = "0"
        Purpose  = "禁用 Steam 局域网 P2P 补丁上传与后台监听"
        Impact   = "消除局域网组播泛洪、端口未受控监听与后台带宽占用"
        Type     = "Vdf"
    },
    @{
        Module   = "配置"
        Key      = "bShaderCacheBGProcessingEnabled"
        Property = "后台着色器预编译 (bShaderCacheBGProcessingEnabled = 0)"
        Expected = "0"
        Purpose  = "禁用电脑闲置时的后台 GPU 着色器预编译"
        Impact   = "避免电脑闲置时后台编译占用 CPU 产生发热与功耗"
        Type     = "Vdf"
    },
    @{
        Module   = "配置"
        Key      = "AllowDownloadsDuringGameplay"
        Property = "游戏期间后台下载 (AllowDownloadsDuringGameplay = 0)"
        Expected = "0"
        Purpose  = "启动游戏后自动挂起所有后台游戏更新下载"
        Impact   = "保障竞技游戏网络低延迟与物理磁盘 IO 零冲突"
        Type     = "Vdf"
    }
)

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

function Get-SteamCleanupItem {
    param([string]$Path)

    try {
        return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    }
}

function Assert-SteamCleanupRoot {
    param([string]$Path)

    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or -not [System.IO.Path]::IsPathFullyQualified($Path)) {
        throw 'Steam 清理目录必须是本地盘符绝对路径。'
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($fullPath -eq [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')) {
        throw '拒绝清理磁盘根目录。'
    }
    $cursor = $fullPath
    while ($cursor) {
        $item = Get-SteamCleanupItem $cursor
        if ($null -ne $item -and (-not $item.PSIsContainer -or
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
            throw 'Steam 安装目录或父目录不是普通目录，拒绝沿重解析路径清理。'
        }
        $cursor = [System.IO.Path]::GetDirectoryName($cursor)
    }
    return $fullPath
}

function Remove-SteamCleanupEntry {
    param([string]$Path)

    $item = Get-SteamCleanupItem $Path
    if ($null -eq $item) { return }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        # 仅移除链接本身，不遍历或删除其目标。
        if ($item.PSIsContainer) { [System.IO.Directory]::Delete($item.FullName) }
        else { [System.IO.File]::Delete($item.FullName) }
    } else {
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
                Remove-SteamCleanupEntry -Path $child.FullName
            }
        }
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
    }
    if ($null -ne (Get-SteamCleanupItem $Path)) { throw "Steam 清理目标仍存在: $Path" }
}

function Remove-SteamInstallContent {
    param([string]$Path, [switch]$Purge)

    $root = Assert-SteamCleanupRoot $Path
    if ($null -eq (Get-SteamCleanupItem $root)) { return }
    $preserved = @('steamapps', 'userdata')
    foreach ($child in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        if (-not $Purge -and $child.Name -in $preserved) { continue }
        Remove-SteamCleanupEntry -Path $child.FullName
    }
    $remaining = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)
    if ($Purge -and $remaining.Count -gt 0) { throw 'Steam Purge 后安装目录仍有内容。' }
    if (@($remaining | Where-Object Name -notin $preserved).Count -gt 0) {
        throw 'Steam 普通卸载后仍有非保留对象。'
    }
    if ($remaining.Count -eq 0) { Remove-SteamCleanupEntry -Path $root }
}

# ==============================================================================
# 3. 独立流转分支：清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    $cleanupRoot = Assert-SteamCleanupRoot $InstallDir
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将清理 Steam 客户端核心、系统服务与自启动项！" -ForegroundColor Yellow
        Write-Host "   安装目录: $cleanupRoot" -ForegroundColor Gray
        Write-Host $(if ($Purge) { '🔥 以下安装目录内游戏库与用户数据将被删除，无法由脚本恢复:' } else { '🔒 以下安装目录内游戏库与用户数据将保留:' }) -ForegroundColor Yellow
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "   不处理其他磁盘游戏库或目录外存档；重解析点仅删除链接本身，不进入外部目标。`n" -ForegroundColor Gray
        $prompt = if ($Purge) { '确认卸载并删除上述安装目录内游戏库与用户数据? [y/N]' } else { '确认卸载 Steam（保留安装目录内游戏库与用户数据）? [y/N]' }
        $confirm = (Read-Host $prompt).Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在终止常驻进程并清理 Steam 环境..." -ForegroundColor Yellow

    Get-Process -Name "steam", "steamwebhelper", "steamservice", "gameoverlayui" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800

    if (Get-Service -Name "Steam Client Service" -ErrorAction SilentlyContinue) {
        Stop-Service -Name "Steam Client Service" -Force -ErrorAction SilentlyContinue
        & sc.exe delete "Steam Client Service" 2>&1 | Out-Null
        Write-Host "   - 已停止并注销 Steam Client Service 系统服务。" -ForegroundColor Gray
    }

    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Steam" -ErrorAction SilentlyContinue
    @(
        "HKCU:\Software\Valve",
        "HKLM:\SOFTWARE\Valve",
        "HKLM:\SOFTWARE\WOW6432Node\Valve",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam",
        "HKCU:\Software\Classes\steam",
        "HKLM:\SOFTWARE\Classes\steam"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Get-NetFirewallRule -Name "Steam-*-Block-In-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Write-Host "   - 已移除 Valve 注册表项、协议、防火墙规则与开机自启项。" -ForegroundColor Gray

    $shortcuts = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Steam.lnk"),
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Steam\Steam.lnk",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Steam",
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Steam.lnk"),
        "C:\Users\Public\Desktop\Steam.lnk"
    )
    foreach ($sc in $shortcuts) {
        Remove-SteamCleanupEntry -Path $sc
    }

    $steamLocalApp = Join-Path $env:LOCALAPPDATA "Steam"
    Remove-SteamCleanupEntry -Path $steamLocalApp

    $steamCommon = "${env:ProgramFiles(x86)}\Common Files\Steam"
    Remove-SteamCleanupEntry -Path $steamCommon

    Write-Host "   - 正在清理安装目录（Purge=$([bool]$Purge)）..." -ForegroundColor Gray
    Remove-SteamInstallContent -Path $cleanupRoot -Purge:$Purge

    $dataResult = if ($Purge) { '安装目录已删除；目录内游戏库与用户数据已清理' } else { '安装目录核心组件已清理；其中原有 steamapps、userdata 已保留（若存在）' }
    Write-Host "`n✅ [安装目录清理已核验] $dataResult。系统注销步骤已执行；其他磁盘游戏库与目录外存档不在清理范围。`n" -ForegroundColor Green
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
$PendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()

$isInstalled = Test-Path $AppExe
$runVal = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue).Steam
$hasRunKey = -not [string]::IsNullOrEmpty($runVal)

$initialConfigTemplate = @"
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
			}
		}
	}
}
"@
$globalRaw = if (Test-Path $ConfigFile) { Get-Content -Path $ConfigFile -Raw -Encoding utf8NoBOM } else { $initialConfigTemplate }

function Read-VdfDocument {
    param([string]$Text)

    # 保留源码偏移，仅解析文本 KeyValues；条件、指令及损坏语法不作推测。
    $pattern = '\G(?:(?<Skip>\s+|//[^\r\n]*|/\*[\s\S]*?\*/)|(?<Quoted>"(?:\\.|[^"\\])*")|(?<Open>\{)|(?<Close>\})|(?<Bare>(?!//|/\*)[^\s{}"\[\]#]+))'
    $lexer = [regex]::new($pattern)
    $root = [PSCustomObject]@{ Children = [Collections.Generic.List[object]]::new() }
    $stack = [Collections.Generic.List[object]]::new()
    $stack.Add($root)
    $pendingKey = $null
    $pendingKeyEnd = 0
    $offset = 0

    while ($offset -lt $Text.Length) {
        $token = $lexer.Match($Text, $offset)
        if (-not $token.Success) { throw "VDF 语法不受支持或损坏，位置: $offset。" }
        $offset += $token.Length
        if ($token.Groups['Skip'].Success) { continue }

        if ($token.Groups['Close'].Success) {
            if ($null -ne $pendingKey -or $stack.Count -eq 1) { throw "VDF 块未正确闭合。" }
            $stack[$stack.Count - 1].CloseStart = $token.Index
            $stack.RemoveAt($stack.Count - 1)
            continue
        }
        if ($token.Groups['Open'].Success) {
            if ($null -eq $pendingKey) { throw "VDF 块缺少名称。" }
            $block = [PSCustomObject]@{
                Name = $pendingKey
                IsBlock = $true
                Children = [Collections.Generic.List[object]]::new()
                CloseStart = -1
            }
            $stack[$stack.Count - 1].Children.Add($block)
            $stack.Add($block)
            $pendingKey = $null
            continue
        }

        $value = $token.Value
        if ($token.Groups['Quoted'].Success) {
            $value = $value.Substring(1, $value.Length - 2)
            $value = [regex]::Replace($value, '\\(["\\])', '$1')
        }
        if ($null -eq $pendingKey) {
            $pendingKey = $value
            $pendingKeyEnd = $offset
        } else {
            $stack[$stack.Count - 1].Children.Add([PSCustomObject]@{
                Name = $pendingKey
                KeyEnd = $pendingKeyEnd
                IsBlock = $false
                Value = $value
                ValueStart = $token.Index
                ValueLength = $token.Length
            })
            $pendingKey = $null
        }
    }
    if ($null -ne $pendingKey -or $stack.Count -ne 1) { throw "VDF 文件不完整。" }
    return $root
}

function Find-VdfChild {
    param($Block, [string]$Name)

    $found = @($Block.Children | Where-Object { [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) })
    if ($found.Count -gt 1) { throw "VDF 目标路径存在同名项，无法唯一定位。" }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Get-VdfBlock {
    param($Document, [string[]]$Path)

    $block = $Document
    foreach ($part in $Path) {
        $block = Find-VdfChild -Block $block -Name $part
        if ($null -eq $block -or -not $block.IsBlock) { throw "VDF 目标块缺失或类型错误: $($Path -join '/')。" }
    }
    return $block
}

function Get-VdfKeyVal {
    param($Block, [string]$Key)

    $entry = Find-VdfChild -Block $Block -Name $Key
    if ($null -eq $entry) { return $null }
    if ($entry.IsBlock) { throw "VDF 目标键应为标量。" }
    return $entry.Value
}

function Set-VdfBlockKey {
    param([string]$Text, [string[]]$Path, [string]$Key, [string]$Value)

    if ([string]::IsNullOrEmpty($Key) -or $Key -match '[\x00-\x1f]' -or $Value -match '[\x00-\x1f]') {
        throw "VDF 键值含不支持的控制字符。未修改配置。"
    }
    $block = Get-VdfBlock -Document (Read-VdfDocument $Text) -Path $Path
    $actual = Get-VdfKeyVal -Block $block -Key $Key
    if ($null -ne $actual -and $actual -ceq $Value) { return $Text }

    $quotedKey = '"' + $Key.Replace('\', '\\').Replace('"', '\"') + '"'
    $quotedValue = '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
    $entry = Find-VdfChild -Block $block -Name $Key
    if ($null -ne $entry) {
        return $Text.Remove($entry.ValueStart, $entry.ValueLength).Insert($entry.ValueStart, $quotedValue)
    }

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lineStart = $Text.LastIndexOf("`n", $block.CloseStart) + 1
    $prefix = $Text.Substring($lineStart, $block.CloseStart - $lineStart)
    if ($prefix -match '^[\t ]*$') {
        $insertion = "$prefix`t$quotedKey`t`t$quotedValue$newline"
        return $Text.Insert($lineStart, $insertion)
    }
    $indent = [regex]::Match($prefix, '^[\t ]*').Value
    return $Text.Insert($block.CloseStart, "$newline$indent`t$quotedKey`t`t$quotedValue$newline$indent")
}

function Assert-SteamStopped {
    if (Get-Process -ErrorAction Stop | Where-Object ProcessName -in @('steam', 'steamwebhelper', 'gameoverlayui')) {
        throw 'Steam 仍在运行或已重新启动，未写入当前配置；请结束游戏并退出 Steam 后重新执行。'
    }
}

function Read-SteamConfigSnapshot {
    param([string]$Path)

    try {
        return [PSCustomObject]@{ Exists = $true; Text = [System.IO.File]::ReadAllText($Path) }
    } catch [System.IO.FileNotFoundException] {
        return [PSCustomObject]@{ Exists = $false; Text = $null }
    } catch [System.IO.DirectoryNotFoundException] {
        return [PSCustomObject]@{ Exists = $false; Text = $null }
    }
}

function Assert-SteamConfigUnchanged {
    param([string]$Path, $Snapshot)

    Assert-SteamStopped
    $current = Read-SteamConfigSnapshot $Path
    if ($current.Exists -ne $Snapshot.Exists -or $current.Text -cne $Snapshot.Text) {
        throw 'Steam 配置在合并期间发生变化，未写入当前配置；请重新执行。'
    }
}

$globalDocument = Read-VdfDocument $globalRaw
$globalSteamBlock = Get-VdfBlock -Document $globalDocument -Path $SteamVdfPath

$fwRules = Get-SteamFirewallSpecs
foreach ($fw in $fwRules) {
    $state = Get-AppFirewallState $fw
    $ManagedSpecs += @{
        Module = '网络'; Property = $fw.Name
        Expected = $state.Expected; Actual = $state.Actual; IsMatch = $state.IsMatch
        Purpose = '为当前程序配置所有网络配置文件、地址与端口的 TCP/UDP 入站阻断'
        Impact = '仅管理本地应用规则，不更改系统默认策略；出站连接不在此规则范围内'
        Type = 'Firewall'
    }
}

foreach ($spec in $ManagedSpecs) {
    $actualStr = ""
    $isMatch = $false

    if ($spec.Type -eq "Binary") {
        $actualStr = if ($isInstalled) { "已就绪 ($AppExe)" } else { "未安装" }
        $isMatch = $isInstalled
    } elseif ($spec.Type -eq "RunKey") {
        $actualStr = if ($hasRunKey) { "已开启 (自启参数: $runVal)" } else { "已清除 (禁用自启)" }
        $isMatch = (-not $hasRunKey)
    } elseif ($spec.Type -eq "RegLanguage") {
        $regLangVal = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).Language
        $actualStr = if ([string]::IsNullOrEmpty($regLangVal)) { "<缺省未设>" } else { $regLangVal }
        $isMatch = ($actualStr -ceq $spec.Expected)
    } elseif ($spec.Type -eq "Vdf") {
        $value = Get-VdfKeyVal -Block $globalSteamBlock -Key $spec.Key
        $actualStr = if ($null -eq $value) { "<缺省未设>" } else { $value }
        $isMatch = ($null -ne $value -and $value -ceq $spec.Expected)
    } elseif ($spec.Type -eq "Firewall") {
        $actualStr = if ($spec.IsMatch) { "已阻断入站 (Block)" } elseif ($spec.Actual -eq '本地受控规则缺失') { "本地受控规则缺失" } else { "规则配置偏离" }
        $isMatch = $spec.IsMatch
    }

    $expDisplay = if ($spec.Type -eq "Firewall") { "已阻断入站 (Block)" } else { $spec.Expected }
    $AuditBoard.Add([PSCustomObject]@{
        状态     = if ($isMatch) { " ✔" } else { " ▲" }
        模块     = $spec.Module
        属性     = $spec.Property
        实机     = $actualStr
        基线     = $expDisplay
        状态判定 = if ($isMatch) { "✔ 匹配" } else { "✘ 偏离" }
    })

    if (-not $isMatch) {
        $actualPending = if ($spec.Type -eq "Firewall" -and $spec.Actual) { $spec.Actual } else { $actualStr }
        $PendingItems.Add([PSCustomObject]@{
            Property = $spec.Property
            Actual   = $actualPending
            Expected = $spec.Expected
            Purpose  = $spec.Purpose
            Impact   = $spec.Impact
        })
    }
}

Write-Host "`n📊 [巡检看板] Steam 原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Select-Object 状态, 模块, 属性, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($Action -eq "Check") {
    if ($driftCount -eq 0) {
        Write-Host "✨ [巡检完成] 所有受控属性与工程基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $driftCount) -ForegroundColor Yellow
    }
    return
}

if ($driftCount -eq 0 -and $isInstalled -and -not $Force) {
    Write-Host "✨ [巡检完成] 所有受控属性与策略均已符合工程基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate - Shift-Left: 目的与影响结构化直出)
# ==============================================================================

# 5.1 运行态并发防覆写硬门禁
Assert-SteamStopped

# 5.2 未安装或强制重装审查门禁
$needBinaryDeploy = (-not $isInstalled) -or $Force
if ($needBinaryDeploy) {
    if (-not $Yes) {
        $promptMsg = if (-not $isInstalled) {
            "未检测到 Steam 客户端本体，是否立即拉取官方安装器进行部署？[Y/n]"
        } else {
            "已开启强制重新部署 (-Force)，是否重新拉取并覆盖安装 Steam 核心？[Y/n]"
        }
        $shouldInstall = (Read-Host $promptMsg).Trim()
        if ($shouldInstall -match "^(n|no)$") {
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
    foreach ($p in $PendingItems) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.Property) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.Actual, $p.Expected) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $p.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $p.Impact) -ForegroundColor Gray
        $idx++
    }

    $gateChoice = (Read-Host "`n确认应用上述工程基线配置? [Y] 确认执行 / [Q] 退出 (默认 Y)").Trim()
    if ($gateChoice -notin @('', 'Y', 'y', 'YES', 'yes', 'Q', 'q', 'QUIT', 'quit', 'N', 'n', 'NO', 'no')) {
        throw '无效授权输入；未执行本模块写入。'
    }
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体安装或覆盖升级
Assert-SteamStopped
if ($needBinaryDeploy) {
    Write-Host "`n⬇️  正在准备通过官方安装器部署 Steam 至: $InstallDir..." -ForegroundColor Cyan

    @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-ItemProperty -Path $_ -Name "InstallPath" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $_ -Name "SteamPath" -ErrorAction SilentlyContinue
        }
    }

    Ensure-Dir $InstallDir
    $installerPath = Join-Path $env:TEMP "SteamSetup.exe"
    $steamUrl = "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"

    Invoke-DownloadFile -Url $steamUrl -OutFile $installerPath -Description "Steam 官方安装程序" -TimeoutSec 180

    Write-Host "   - 正在静默释放 Steam 客户端核心..." -ForegroundColor Gray
    $cleanDir = $InstallDir.TrimEnd('\')
    Assert-SteamStopped
    $process = Start-Process -FilePath $installerPath -ArgumentList "/S /LANGUAGE=schinese /D=$cleanDir" -Wait -PassThru

    Start-Sleep -Seconds 3
    if (Test-Path $installerPath) { Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue }

    if ($null -eq $process -or $process.ExitCode -ne 0) {
        $exitCode = if ($null -ne $process) { $process.ExitCode } else { '<未知>' }
        throw "Steam 官方安装程序异常退出 (退出码: $exitCode)；未继续配置。"
    }

    $actualExe = Join-Path $InstallDir "steam.exe"
    if (-not (Test-Path $actualExe)) {
        throw "Steam 静默安装完成，但在目标基准目录 [$InstallDir] 下未能定位到 steam.exe！"
    }
    $AppExe = $actualExe
    $isInstalled = $true
    Write-Host "✅ Steam 客户端已成功部署至基准目录: $InstallDir" -ForegroundColor Green
}

# 6.2 禁用开机自启与注册表基线对齐
Assert-SteamStopped
Write-Host "`n⚙️  正在执行开机自启动抑制与注册表基线对齐..." -ForegroundColor Cyan
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if ((Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue).Steam) {
    Remove-ItemProperty -Path $runKey -Name "Steam" -Force -ErrorAction SilentlyContinue
    Write-Host "✅ 已从 HKCU Run 注册表中移除 Steam 自启项。" -ForegroundColor Green
}

$steamUserReg = "HKCU:\Software\Valve\Steam"
if (-not (Test-Path $steamUserReg)) {
    New-Item -Path $steamUserReg -Force | Out-Null
}
$currentRegLang = (Get-ItemProperty -Path $steamUserReg -ErrorAction SilentlyContinue).Language
if ($currentRegLang -cne "schinese") {
    Set-ItemProperty -Path $steamUserReg -Name "Language" -Value "schinese" -Force -ErrorAction Stop
}
$verifyRegLang = (Get-ItemProperty -Path $steamUserReg -ErrorAction SilentlyContinue).Language
if ($verifyRegLang -cne "schinese") {
    throw "HKCU Valve\Steam 注册表界面语言回读校验失败，未匹配基线。"
}
Write-Host "✅ 已核验 HKCU Valve\Steam 注册表界面语言为 schinese。" -ForegroundColor Green

$hklmSteamReg = "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam"
if (Test-Path $hklmSteamReg) {
    $currentHklmLang = (Get-ItemProperty -Path $hklmSteamReg -ErrorAction SilentlyContinue).Language
    if ($currentHklmLang -cne "schinese") {
        Set-ItemProperty -Path $hklmSteamReg -Name "Language" -Value "schinese" -Force -ErrorAction SilentlyContinue
    }
}

# 6.3 注入全局 config.vdf 性能策略
Write-Host "⚙️  正在单向对齐全局 config.vdf 性能配置..." -ForegroundColor Cyan
Ensure-Dir (Split-Path $ConfigFile -Parent)

Assert-SteamStopped
$configSnapshot = Read-SteamConfigSnapshot $ConfigFile
$currentGlobal = if ($configSnapshot.Exists) { $configSnapshot.Text } else { $initialConfigTemplate }
$vdfItems = @($ManagedSpecs | Where-Object Type -eq "Vdf")
$updatedGlobal = $currentGlobal
foreach ($vc in $vdfItems) {
    $updatedGlobal = Set-VdfBlockKey -Text $updatedGlobal -Path $SteamVdfPath -Key $vc.Key -Value $vc.Expected
}
$updatedBlock = Get-VdfBlock -Document (Read-VdfDocument $updatedGlobal) -Path $SteamVdfPath
foreach ($vc in $vdfItems) {
    if ((Get-VdfKeyVal -Block $updatedBlock -Key $vc.Key) -cne $vc.Expected) {
        throw "VDF 受控键更新校验失败，未写入配置。"
    }
}
Assert-SteamConfigUnchanged -Path $ConfigFile -Snapshot $configSnapshot
$globalWritten = $false
if (-not $configSnapshot.Exists -or $updatedGlobal -cne $currentGlobal) {
    try {
        [System.IO.File]::WriteAllText($ConfigFile, $updatedGlobal, [System.Text.UTF8Encoding]::new($false))
        $globalWritten = $true
    } catch {
        throw "config.vdf 写入失败，文件可能已部分改变，请核验: $($_.Exception.Message)"
    }
}
try {
    $savedBlock = Get-VdfBlock -Document (Read-VdfDocument ([System.IO.File]::ReadAllText($ConfigFile))) -Path $SteamVdfPath
    foreach ($vc in $vdfItems) {
        if ((Get-VdfKeyVal -Block $savedBlock -Key $vc.Key) -cne $vc.Expected) { throw '受控值不符。' }
    }
} catch {
    throw "config.vdf 回读校验失败（本次已写入: $globalWritten）: $($_.Exception.Message)"
}
Write-Host "✅ config.vdf 受控值回读校验通过（本次已写入: $globalWritten）: $ConfigFile" -ForegroundColor Green

# 6.5 安装后重新发现当前组件，按同一规格收敛并回读本地规则
$fwRules = Get-SteamFirewallSpecs
$firewallApplied = Sync-AppFirewallRules -Specs $fwRules
Write-Host "✅ 本地入站阻断规则及受控过滤器已回读核验，本次修改 $firewallApplied 条；未验证实际流量或上级策略。" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与系统管控对齐完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 开机管理: 已从注册表移除 Steam 常驻自启" -ForegroundColor Gray
Write-Host "   - 界面偏好: Steam 默认语言已锁定为简体中文 (schinese)" -ForegroundColor Gray
Write-Host "   - 性能基线: 已禁用后台着色器预编译 (保 CPU)、禁用局域网 P2P 上传与游戏期间下载" -ForegroundColor Gray
Write-Host '   - 网络安全: 已核验当前 Steam/已发现 WebHelper 的本地入站阻断配置，不将配置检查等同实际流量验收' -ForegroundColor Gray

Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData 'Steam 客户端基线已就绪；首次启动请登录账号并确认 Steam 令牌，游戏下载库路径请在客户端内管理。'

return
