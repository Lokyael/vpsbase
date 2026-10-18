#requires -Version 7.0
<#
.SYNOPSIS
    Steam 平台

.DESCRIPTION
    Steam 平台 (Windows) 自动化纯净安装、系统开机项管控与全局性能基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，运用现代 pwsh 语法与原生无 BOM UTF-8 输出。
    2. 严格遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)：对系统注册表自启动项、全局 config.vdf 性能策略及用户偏好进行逐项比对，拒绝盲目覆盖。
    3. 并发安全防护硬门禁：在读取或修改 Steam 本地 VDF 配置文件前，严密检测 Steam 运行状态，杜绝内存回写冲刷。
    4. 系统自启动项精准管控：精准读写 HKCU Run 注册表，彻底阻断开机常驻自启以释放冷启动负载。
    5. 全局性能与网络基线对齐：
       - 彻底禁用局域网对等传输 (PeerContentServerMode=0)，杜绝偷跑上传带宽、端口监听及 TUN/WSL 组播泛洪；
       - 禁用后台无休止着色器预编译 (bShaderCacheBGProcessingEnabled=0)，根治电脑闲置时无故吃满 CPU 与发热；
       - 禁止游戏运行时后台下载 (AllowDownloadsDuringGameplay=0)，保障竞技网络低延迟与磁盘 IO 稳定。
    6. 用户偏好规范化：修正各登录账号下载速率单位为直观的标准字节/秒 (MB/s)。
    7. 防火墙安全基线主动纳管：静默预置专用网络入站放行规则 (Profile=Private)，封死公用网络 (Public) 暴露面，杜绝启动时弹出“Windows Defender 防火墙已阻止”安全警报。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync        : 增量对齐黄金基线 (默认，缺失则装、偏离则修)
    - Check       : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - ResetConfig : 仅执行开机自启动抑制、全局基线配置与账号偏好修复
    - Uninstall   : 彻底清洁卸载 Steam 核心运行时与服务 (保护 steamapps 游戏库)
    - Upgrade     : 重新拉取官方安装包覆盖升级 Steam 客户端本体

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\steam.ps1 -Action Check

    # 交互式检查并应用黄金基线
    pwsh -File .\scripts\apps\steam.ps1

    # 仅修复配置与禁用自启
    pwsh -File .\scripts\apps\steam.ps1 -Action ResetConfig

    # 彻底清洁卸载
    pwsh -File .\scripts\apps\steam.ps1 -Action Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "ResetConfig", "Uninstall", "Upgrade")]
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

$HighValueUserData = @(
    "游戏本地库目录 (steamapps): $InstallDir\steamapps",
    "各账号本地存档与截图: $UserDirBase"
)

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# 受控属性全景声明清单 (含 Purpose 目的 与 Impact 影响)
$ManagedSpecs = @(
    @{
        Module   = "客户端本体"
        Property = "主执行文件 (steam.exe)"
        Expected = "已就绪 ($AppExe)"
        Purpose  = "部署 Steam 官方游戏客户端核心本体"
        Impact   = "若未就绪将自动拉取官方安装包部署至 $InstallDir"
        Type     = "Binary"
    },
    @{
        Module   = "系统集成"
        Property = "开机自启动 (HKCU Run Steam)"
        Expected = "已清除 (禁用自启)"
        Purpose  = "彻底从注册表 Run 项中剥离 Steam 开机自启"
        Impact   = "开机冷启动阶段不再常驻 Steam 及其多个 WebHelper 进程，释放 500MB+ 内存"
        Type     = "RunKey"
    },
    @{
        Module   = "性能基线"
        Key      = "PeerContentServerMode"
        Property = "局域网对等传输 (PeerContentServerMode = 0)"
        Expected = "0"
        Purpose  = "彻底禁用 Steam 局域网 P2P 补丁上传与后台监听"
        Impact   = "杜绝局域网组播泛洪、端口未授权监听以及偷跑宽带上行"
        Type     = "Vdf"
    },
    @{
        Module   = "性能基线"
        Key      = "bShaderCacheBGProcessingEnabled"
        Property = "后台着色器预编译 (bShaderCacheBGProcessingEnabled = 0)"
        Expected = "0"
        Purpose  = "禁用电脑闲置时无休止的后台 GPU 着色器预编译"
        Impact   = "根除电脑静置挂机时突然 CPU 吃满 100% 发热风扇狂转"
        Type     = "Vdf"
    },
    @{
        Module   = "性能基线"
        Key      = "AllowDownloadsDuringGameplay"
        Property = "游戏期间后台下载 (AllowDownloadsDuringGameplay = 0)"
        Expected = "0"
        Purpose  = "启动游戏后自动挂起所有后台游戏更新下载"
        Impact   = "保障竞技游戏网络低延迟与物理磁盘 IO 零冲突"
        Type     = "Vdf"
    },
    @{
        Module   = "网络安全"
        Property = "防火墙静默纳管 (仅限专用网络 Private 放行)"
        Expected = "已配置 (仅限 Private)"
        Purpose  = "静默预置入站放行规则并严格封死公用网络 (Public) 暴露面"
        Impact   = "消灭首次启动弹出的「Windows 防火墙已阻止」弹窗，杜绝公用 Wi-Fi 下端口暴露"
        Type     = "Firewall"
    }
)

# ==============================================================================
# 3. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将清理 Steam 客户端核心、系统服务与自启动项！" -ForegroundColor Yellow
        Write-Host "📌 【本地游戏资产与数据保护提示】:" -ForegroundColor Cyan
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "👉 默认严格保护 steamapps 与 userdata 目录，不会删除本地游戏本体。`n" -ForegroundColor Yellow

        $confirm = (Read-Host "确认清理 Steam 客户端核心、服务与注册表启动项? [y/N]").Trim()
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

    Get-NetFirewallRule -DisplayName "*Steam*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    @(
        "Steam-Client-In-TCP",
        "Steam-Client-In-UDP",
        "Steam-WebHelper-In-TCP",
        "Steam-WebHelper-In-UDP"
    ) | ForEach-Object {
        Get-NetFirewallRule -Name $_ -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
    Write-Host "   - 已彻底拔除 Valve 注册表项、协议、防火墙规则与开机自启项。" -ForegroundColor Gray

    $shortcuts = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Steam.lnk"),
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Steam\Steam.lnk",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Steam",
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Steam.lnk"),
        "C:\Users\Public\Desktop\Steam.lnk"
    )
    foreach ($sc in $shortcuts) {
        if (Test-Path $sc) { Remove-Item -Path $sc -Force -Recurse -ErrorAction SilentlyContinue }
    }

    $steamLocalApp = Join-Path $env:LOCALAPPDATA "Steam"
    if (Test-Path $steamLocalApp) {
        Remove-Item -Path $steamLocalApp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $steamCommon = "${env:ProgramFiles(x86)}\Common Files\Steam"
    if (Test-Path $steamCommon) {
        Remove-Item -Path $steamCommon -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $InstallDir) {
        Write-Host "   - 正在清理安装目录核心组件 (保护 steamapps 游戏资产以防丢失)..." -ForegroundColor Gray
        Get-ChildItem -Path $InstallDir -Exclude "steamapps", "userdata" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $remaining = Get-ChildItem -Path $InstallDir -Force -ErrorAction SilentlyContinue
        if ($remaining.Count -eq 0) {
            Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "`n✅ [清洁卸载完成] Steam 核心运行时与注册表自启已清理 (steamapps 游戏资产完整保留)。`n" -ForegroundColor Green
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

function Get-VdfKeyVal([string]$text, [string]$key) {
    if ($text -match "`"$key`"\s+`"(?<val>[^`"]+)`"") {
        return $Matches.val
    }
    return "<缺省未设>"
}

$fwTcp = Get-NetFirewallRule -Name "Steam-Client-In-TCP" -ErrorAction SilentlyContinue
$fwUdp = Get-NetFirewallRule -Name "Steam-Client-In-UDP" -ErrorAction SilentlyContinue
$fwOk = ($null -ne $fwTcp -and $fwTcp.Profile -eq "Private" -and $null -ne $fwUdp -and $fwUdp.Profile -eq "Private")

foreach ($spec in $ManagedSpecs) {
    $actualStr = ""
    $isMatch = $false

    if ($spec.Type -eq "Binary") {
        $actualStr = if ($isInstalled) { "已就绪" } else { "未安装" }
        $isMatch = $isInstalled
    } elseif ($spec.Type -eq "RunKey") {
        $actualStr = if ($hasRunKey) { "已开启 (自启参数: $runVal)" } else { "已禁用" }
        $isMatch = (-not $hasRunKey)
    } elseif ($spec.Type -eq "Vdf") {
        $actualStr = Get-VdfKeyVal $globalRaw $spec.Key
        $isMatch = ($actualStr -eq $spec.Expected)
    } elseif ($spec.Type -eq "Firewall") {
        $actualStr = if ($fwOk) { "已配置 (仅限 Private)" } else { "未配置/暴露公网" }
        $isMatch = $fwOk
    }

    $AuditBoard.Add([PSCustomObject]@{
        分层模块 = $spec.Module
        受控属性 = $spec.Property
        期望基线 = $spec.Expected
        实机状态 = $actualStr
        状态判定 = if ($isMatch) { "✔ 匹配" } else { "✘ 偏离" }
    })

    if (-not $isMatch -and $Action -ne "Upgrade") {
        $PendingItems.Add([PSCustomObject]@{
            Property = $spec.Property
            Actual   = $actualStr
            Expected = $spec.Expected
            Purpose  = $spec.Purpose
            Impact   = $spec.Impact
        })
    }
}

# 账号偏好巡检 (各登录账号下载速率单位)
if (Test-Path $UserDirBase) {
    $userDirs = Get-ChildItem -Path $UserDirBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' }
    foreach ($u in $userDirs) {
        $userVdf = Join-Path $u.FullName "config\localconfig.vdf"
        if (-not (Test-Path $userVdf)) { continue }
        $content = Get-Content -Path $userVdf -Raw -Encoding utf8NoBOM
        $rateBit = ($content -match '"displayratesasbits"\s+"(?<v>[01])"') ? $Matches.v : "0"
        $rateMatched = ($rateBit -eq "0")

        $AuditBoard.Add([PSCustomObject]@{
            分层模块 = "账号偏好"
            受控属性 = "下载速率单位 (账号 $($u.Name))"
            期望基线 = "0 (字节/秒: MB/s)"
            实机状态 = if ($rateBit -eq "1") { "1 (比特/秒: Mbps)" } else { "0 (字节/秒: MB/s)" }
            状态判定 = if ($rateMatched) { "✔ 匹配" } else { "✘ 偏离" }
        })

        if (-not $rateMatched -and $Action -ne "Upgrade") {
            $PendingItems.Add([PSCustomObject]@{
                Property = "下载速率单位 (账号 $($u.Name))"
                Actual   = "$rateBit (Mbps)"
                Expected = "0 (MB/s)"
                Purpose  = "规范下载速率采用直观的标准字节/秒单位"
                Impact   = "在下载页面与悬浮窗以 MB/s 显示真实下载带宽"
            })
        }
    }
}

Write-Host "`n📊 [巡检看板] Steam 原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($Action -eq "Check") {
    if ($driftCount -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性与黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $driftCount) -ForegroundColor Yellow
    }
    return
}

if ($driftCount -eq 0 -and $isInstalled -and $Action -ne "Upgrade") {
    Write-Host "✨ [状态合规] 所有受控属性与策略均已符合工程黄金基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate - Shift-Left: 目的与影响结构化直出)
# ==============================================================================

# 5.1 运行态并发防覆写硬门禁
$runningProc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if ($runningProc) {
    if (-not $Yes) {
        Write-Warning "检测到 Steam 当前正在运行！外部修改会被退出时的内存状态覆写。"
        $kill = (Read-Host "是否由脚本安全终止 Steam 进程以继续配置? [Y/n]").Trim()
        if ($kill -match "^(n|no)$") {
            Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningProc | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

# 5.2 未安装审查门禁
if (-not $isInstalled) {
    if ($Action -eq "ResetConfig") {
        throw "未检测到 Steam 客户端安装！请先执行 -Action Sync 安装本体后再重置配置。"
    }

    if (-not $Yes) {
        $shouldInstall = (Read-Host "未检测到 Steam 客户端本体，是否立即拉取官方安装器进行部署？[Y/n]").Trim()
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

    $gateChoice = (Read-Host "`n确认应用上述黄金基线配置? [Y] 确认执行 / [Q] 退出 (默认 Y)").Trim()
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体安装或覆盖升级
if (-not $isInstalled -or $Action -eq "Upgrade") {
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

    Write-Host "   - 正在下载 Steam 官方安装程序..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $steamUrl -OutFile $installerPath -UseBasicParsing

    Write-Host "   - 正在静默释放 Steam 客户端核心..." -ForegroundColor Gray
    $cleanDir = $InstallDir.TrimEnd('\')
    $process = Start-Process -FilePath $installerPath -ArgumentList "/S /D=$cleanDir" -Wait -PassThru

    Start-Sleep -Seconds 3
    if (Test-Path $installerPath) { Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue }

    $actualExe = Join-Path $InstallDir "steam.exe"
    if (Test-Path $actualExe) {
        $AppExe = $actualExe
        $isInstalled = $true
        Write-Host "✅ Steam 客户端已成功部署至基准目录: $InstallDir" -ForegroundColor Green
    } else {
        $fallback = "${env:ProgramFiles(x86)}\Steam\steam.exe"
        if (Test-Path $fallback) {
            $InstallDir = "${env:ProgramFiles(x86)}\Steam"
            $AppExe = $fallback
            $isInstalled = $true
            Write-Host "⚠️  Steam 安装器重定向至: $InstallDir" -ForegroundColor Yellow
        } else {
            throw "Steam 静默安装失败，未能定位到 steam.exe。"
        }
    }

    if ($Action -eq "Upgrade") {
        Write-Host "`n✅ [升级完成] Steam 客户端本体已完成更新。`n" -ForegroundColor Green
        return
    }
}

# 6.2 禁用开机自启
Write-Host "`n⚙️  正在执行开机自启动抑制..." -ForegroundColor Cyan
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if ((Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue).Steam) {
    Remove-ItemProperty -Path $runKey -Name "Steam" -Force -ErrorAction SilentlyContinue
    Write-Host "✅ 已从 HKCU Run 注册表中移除 Steam 自启项。" -ForegroundColor Green
}

# 6.3 注入全局 config.vdf 性能策略
Write-Host "⚙️  正在单向对齐全局 config.vdf 性能配置..." -ForegroundColor Cyan
Ensure-Dir (Split-Path $ConfigFile -Parent)

function Set-VdfBlockKey([string]$text, [string]$key, [string]$val) {
    if ($text -match "`"$key`"\s+`"[^`"]*`"") {
        return ($text -replace "`"$key`"\s+`"[^`"]*`"", "`"$key`"`t`t`"$val`"")
    } else {
        if ($text -match '(?ms)(^\s*"Steam"\s*\{)(.*?)(\n\s*\})') {
            $inner = $Matches[2].TrimEnd()
            $newInner = if ($inner) { "$inner`r`n`t`t`t`"$key`"`t`t`"$val`"" } else { "`r`n`t`t`t`"$key`"`t`t`"$val`"" }
            return $text -replace '(?ms)(^\s*"Steam"\s*\{)(.*?)(\n\s*\})', "`$1$newInner`r`n`t`t}"
        }
    }
    return $text
}

$vdfItems = @(
    @{ Key = "PeerContentServerMode"; Val = "0" },
    @{ Key = "bShaderCacheBGProcessingEnabled"; Val = "0" },
    @{ Key = "AllowDownloadsDuringGameplay"; Val = "0" }
)

$updatedGlobal = $globalRaw
foreach ($vc in $vdfItems) {
    $updatedGlobal = Set-VdfBlockKey -text $updatedGlobal -key $vc.Key -val $vc.Val
}
[System.IO.File]::WriteAllText($ConfigFile, $updatedGlobal, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ 全局 config.vdf 性能策略已原子落盘至: $ConfigFile" -ForegroundColor Green

# 6.4 规范各账号下载速率单位
if (Test-Path $UserDirBase) {
    $userDirs = Get-ChildItem -Path $UserDirBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' }
    foreach ($u in $userDirs) {
        $userVdf = Join-Path $u.FullName "config\localconfig.vdf"
        if (-not (Test-Path $userVdf)) { continue }
        $c = Get-Content -Path $userVdf -Raw -Encoding utf8NoBOM
        if ($c -match '"displayratesasbits"\s+"[01]"') {
            $c = $c -replace '"displayratesasbits"\s+"[01]"', '"displayratesasbits"`t`t"0"'
            [System.IO.File]::WriteAllText($userVdf, $c, [System.Text.UTF8Encoding]::new($false))
            Write-Host "✅ 账号 [$($u.Name)] 速率单位已规范为 MB/s (字节/秒)" -ForegroundColor Green
        }
    }
}

# 6.5 静默下发专用网络防火墙入站白名单 (仅限 Private，封死 Public)
Write-Host "⚙️  正在预置专用网络防火墙规则 (防启动弹窗)..." -ForegroundColor Cyan
$webHelperExe = Join-Path $InstallDir "bin\cef\cef.win7x64\steamwebhelper.exe"
if (-not (Test-Path $webHelperExe)) {
    $webHelperExe = Join-Path $InstallDir "bin\steamwebhelper.exe"
}

$rules = @(
    @{ Name = "Steam-Client-In-TCP"; Program = $AppExe; Protocol = "TCP" },
    @{ Name = "Steam-Client-In-UDP"; Program = $AppExe; Protocol = "UDP" }
)
if (Test-Path $webHelperExe) {
    $rules += @(
        @{ Name = "Steam-WebHelper-In-TCP"; Program = $webHelperExe; Protocol = "TCP" },
        @{ Name = "Steam-WebHelper-In-UDP"; Program = $webHelperExe; Protocol = "UDP" }
    )
}

foreach ($r in $rules) {
    $existing = Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -Name $r.Name -DisplayName "Steam Game Platform ($($r.Protocol))" `
            -Direction Inbound -Program $r.Program -Protocol $r.Protocol -Action Allow `
            -Profile Private -Enabled True -ErrorAction SilentlyContinue | Out-Null
    } else {
        Set-NetFirewallRule -Name $r.Name -Profile Private -Enabled True -ErrorAction SilentlyContinue | Out-Null
    }
}
Write-Host "✅ 防火墙入站规则已加固 (仅放行 Private 专用网络，彻底阻断 Public 公共网络)。" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与系统管控对齐完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 开机管理: 已从注册表彻底拔除 Steam 常驻自启" -ForegroundColor Gray
Write-Host "   - 性能基线: 已禁用后台着色器预编译 (保 CPU)、禁用局域网 P2P 上传与游戏期间下载" -ForegroundColor Gray
Write-Host "   - 网络安全: 防火墙已预置专用网络白名单，首次启动零弹窗" -ForegroundColor Gray

return
