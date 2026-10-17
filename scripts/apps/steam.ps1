#requires -Version 7.0
<#
.SYNOPSIS
    Steam 平台

.DESCRIPTION
    Steam 平台 (Windows) 自动化纯净安装、系统开机项管控、全局性能基线与无浏览器模式 (No-Browser) 配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，运用现代 pwsh 语法与原生无 BOM UTF-8 输出。
    2. 严格遵循“先检查后配置、幂等无冗余”原则：对系统注册表自启动项、全局 config.vdf 性能策略及用户偏好进行逐项比对，拒绝盲目覆盖。
    3. 并发安全防护硬门禁：在读取或修改 Steam 本地 VDF 配置文件前，严密检测 Steam 运行状态，杜绝内存回写冲刷。
    4. 系统自启动项精准管控：精准读写 HKCU Run 注册表，彻底阻断开机常驻自启以释放冷启动负载。
    5. 全局性能与网络基线对齐：
       - 彻底禁用局域网对等传输 (PeerContentServerMode=0)，杜绝偷跑上传带宽、端口监听及 TUN/WSL 组播泛洪；
       - 禁用后台无休止着色器预编译 (bShaderCacheBGProcessingEnabled=0)，根治电脑闲置时无故吃满 CPU 与发热；
       - 禁止游戏运行时后台下载 (AllowDownloadsDuringGameplay=0)，保障竞技网络低延迟与磁盘 IO 稳定。
    6. 用户偏好规范化：修正各登录账号下载速率单位为直观的标准字节/秒 (MB/s)。
    7. 交付 No-Browser 快捷方式：生成无嵌入式浏览器模式快捷方式 (-no-browser)，内存占用从 1GB+ 降至约 50MB，秒级极速拉起。

.PARAMETER Clean
    清洁重装模式。终止运行进程、清理开机自启注册表与快捷方式、彻底抹除安装目录核心程序（保护 steamapps 游戏本体以防丢失）并重新拉取部署。
    别名: -Fresh, -Reset

.PARAMETER CheckOnly
    只查不改模式（体检巡检）。逐项比对 Steam 安装状态、开机自启项、全局网络/CPU 策略与账号偏好，高亮输出 Diff，零写入安全退出。
    别名: -Audit

.PARAMETER ConfigOnly
    仅执行开机自启动抑制、全局基线配置、账号偏好修复与 No-Browser 快捷方式生成，不重新下载安装 Steam 客户端本体。

.PARAMETER InstallOnly
    仅执行 Steam 官方安装程序的下载与静默提取安装，不修改任何配置项。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线（用于自动化装机流）。

.PARAMETER InstallDir
    Steam 安装目标目录，默认优先检测已有安装或落地至 D:\prog\Steam。

.EXAMPLE
    # 交互式全流程检查与配置
    pwsh -File .\scripts\apps\steam.ps1

    # 只查不改体检巡检
    pwsh -File .\scripts\apps\steam.ps1 -CheckOnly

    # 仅修复配置、禁用自启与生成 No-Browser 快捷方式
    pwsh -File .\scripts\apps\steam.ps1 -ConfigOnly

    # 彻底清洁重装
    pwsh -File .\scripts\apps\steam.ps1 -Clean
#>

[CmdletBinding()]
param(
    [Alias("Fresh", "Reset")]
    [switch]$Clean,

    [Alias("Audit")]
    [switch]$CheckOnly,

    [switch]$ConfigOnly,
    [switch]$InstallOnly,
    [switch]$NonInteractive,
    [string]$InstallDir
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ==============================================================================
# 环境校验：强制锁定 PowerShell 7+
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "本脚本已全面转向 PowerShell 7+ (pwsh)，不兼容旧版 Windows PowerShell 5.1。请使用 'pwsh' 执行本脚本。"
}

# ==============================================================================
# 0. 路径探测与初始化
# ==============================================================================
$steamReg = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if ($Clean) {
        # 清洁重装模式下强制锚定工程黄金基线，彻底切断对历史旧路径的继承
        $InstallDir = (Test-Path "D:\") ? "D:\prog\Steam" : (Join-Path $env:ProgramFiles "(x86)\Steam")
    } elseif ($steamReg.SteamPath) {
        $InstallDir = $steamReg.SteamPath -replace '/', '\'
    } else {
        $InstallDir = (Test-Path "D:\") ? "D:\prog\Steam" : (Join-Path $env:ProgramFiles "(x86)\Steam")
    }
}

$steamExe = Join-Path $InstallDir "steam.exe"
$globalConfigFile = Join-Path $InstallDir "config\config.vdf"
$desktopNoBrowserLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Steam (No-Browser).lnk"

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "  Steam 平台系统管控与性能基线工具 (pwsh 7+)" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "📂 部署基准目录: 安装目录 [$InstallDir]`n" -ForegroundColor Cyan

# ==============================================================================
# 阶段 A: 清洁卸载与环境重置 (-Clean)
# ==============================================================================
if ($Clean) {
    Write-Host "🧹 [清洁重装模式] 正在终止常驻进程并清理 Steam 环境..." -ForegroundColor Yellow

    # 1. 强力终止 Steam 进程
    Get-Process -Name "steam", "steamwebhelper", "gameoverlayui" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800

    # 2. 清理自启动项
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Steam" -ErrorAction SilentlyContinue

    # 3. 清理快捷方式 (涵盖用户与公用目录)
    $shortcuts = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Steam.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "Steam (No-Browser).lnk"),
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Steam\Steam.lnk",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Steam",
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Steam.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Steam (No-Browser).lnk"),
        "C:\Users\Public\Desktop\Steam.lnk",
        "C:\Users\Public\Desktop\Steam (No-Browser).lnk"
    )
    foreach ($sc in $shortcuts) {
        if (Test-Path $sc) { Remove-Item -Path $sc -Force -Recurse -ErrorAction SilentlyContinue }
    }

    # 4. 清除安装目录（保护 steamapps 游戏下载本体与用户存档数据）
    if (Test-Path $InstallDir) {
        Write-Host "   - 正在清理安装目录核心组件 (保护 steamapps 游戏资产以防丢失)..." -ForegroundColor Gray
        Get-ChildItem -Path $InstallDir -Exclude "steamapps", "userdata" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "✅ [清洁完成] Steam 核心运行时与注册表自启已清理。`n" -ForegroundColor Green
}

# ==============================================================================
# 阶段 B: 只查不改体检巡检 (-CheckOnly / -Audit)
# ==============================================================================
if ($CheckOnly) {
    Write-Host "`n🔍 [只查不改模式] 正在对 Steam 客户端与系统级偏好执行逐项巡检..." -ForegroundColor Cyan

    $chkList = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. 二进制安装
    $isInstalled = Test-Path $steamExe
    $chkList.Add([PSCustomObject]@{
        "配置模块" = "客户端本体"
        "受控属性" = "二进制程序 (steam.exe)"
        "期望基线" = "已安装于 $InstallDir"
        "实机状态" = $isInstalled ? "已就绪" : "未安装"
        "判定"     = $isInstalled ? "✔ 匹配" : "✘ 缺失"
    })

    # 2. 开机自启动
    $runVal = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue).Steam
    $chkList.Add([PSCustomObject]@{
        "配置模块" = "系统集成"
        "受控属性" = "开机自启动 (Run Key)"
        "期望基线" = "禁用 (释放冷启负载)"
        "实机状态" = [string]::IsNullOrEmpty($runVal) ? "已禁用" : "已开启 (常驻自启)"
        "判定"     = [string]::IsNullOrEmpty($runVal) ? "✔ 匹配" : "✘ 漂移 (需禁用)"
    })

    # 3. 全局基线配置 (config\config.vdf)
    $hasGlobalCfg = Test-Path $globalConfigFile
    $globalContent = $hasGlobalCfg ? (Get-Content -Path $globalConfigFile -Raw -Encoding utf8NoBOM) : ""

    # 3.1 局域网对等传输
    $peerMode = ($globalContent -match '"PeerContentServerMode"\s+"(?<v>[^"]+)"') ? $Matches.v : $null
    $chkList.Add([PSCustomObject]@{
        "配置模块" = "全局网络"
        "受控属性" = "局域网对等传输 (PeerContentServerMode)"
        "期望基线" = "0 (彻底禁用/防偷跑/闭端口)"
        "实机状态" = ($peerMode -eq "0") ? "0 (已禁用)" : ($null -eq $peerMode ? "未显式配置 (默认常驻)" : "$peerMode (已开启)")
        "判定"     = ($peerMode -eq "0") ? "✔ 匹配" : "✘ 漂移 (需禁用)"
    })

    # 3.2 后台着色器预编译
    $shaderBg = ($globalContent -match '"bShaderCacheBGProcessingEnabled"\s+"(?<v>[^"]+)"') ? $Matches.v : $null
    $chkList.Add([PSCustomObject]@{
        "配置模块" = "全局性能"
        "受控属性" = "后台着色器编译 (bShaderCacheBGProcessingEnabled)"
        "期望基线" = "0 (禁用后台编译/杜绝闲置吃满CPU)"
        "实机状态" = ($shaderBg -eq "0") ? "0 (已禁用)" : ($null -eq $shaderBg ? "未显式配置 (默认后台处理)" : "$shaderBg (已开启)")
        "判定"     = ($shaderBg -eq "0") ? "✔ 匹配" : "✘ 漂移 (需禁用)"
    })

    # 3.3 游戏运行时禁止下载更新
    $gameDl = ($globalContent -match '"AllowDownloadsDuringGameplay"\s+"(?<v>[^"]+)"') ? $Matches.v : $null
    $chkList.Add([PSCustomObject]@{
        "配置模块" = "全局网络"
        "受控属性" = "游戏时后台下载 (AllowDownloadsDuringGameplay)"
        "期望基线" = "0 (禁止游戏中下载/保障低延迟与IO)"
        "实机状态" = ($gameDl -eq "0") ? "0 (游戏中暂停)" : ($null -eq $gameDl ? "未显式配置 (默认暂停)" : "$gameDl (允许下载)")
        "判定"     = ($gameDl -eq "0" -or $null -eq $gameDl) ? "✔ 匹配" : "✘ 漂移 (需禁用)"
    })

    # 4. No-Browser 模式快捷方式
    $hasNoBrowser = Test-Path $desktopNoBrowserLnk
    $chkList.Add([PSCustomObject]@{
        "配置模块" = "桌面交付"
        "受控属性" = "无浏览器模式快捷方式 (Steam (No-Browser).lnk)"
        "期望基线" = "存在 (-no-browser 轻量模式)"
        "实机状态" = $hasNoBrowser ? "已就绪" : "未生成"
        "判定"     = $hasNoBrowser ? "✔ 匹配" : "💡 可选生成"
    })

    # 5. 账号级偏好巡检
    $userDirs = (Test-Path "$InstallDir\userdata") ? (Get-ChildItem -Path "$InstallDir\userdata" -Directory -ErrorAction SilentlyContinue) : @()
    if ($userDirs.Count -eq 0) {
        $chkList.Add([PSCustomObject]@{
            "配置模块" = "用户数据"
            "受控属性" = "登录账号资料库"
            "期望基线" = "至少一个已登录账号"
            "实机状态" = "未检测到本地账号资料"
            "判定"     = "💡 待首次登录"
        })
    } else {
        foreach ($u in $userDirs) {
            $userVdf = Join-Path $u.FullName "config\localconfig.vdf"
            if (-not (Test-Path $userVdf)) { continue }
            $content = Get-Content -Path $userVdf -Raw -Encoding utf8NoBOM

            # 下载速率单位
            $rateBit = ($content -match '"displayratesasbits"\s+"(?<v>[01])"') ? $Matches.v : "0"
            $chkList.Add([PSCustomObject]@{
                "配置模块" = "账号: $($u.Name)"
                "受控属性" = "下载速率单位 (displayratesasbits)"
                "期望基线" = "0 (字节/秒: MB/s)"
                "实机状态" = ($rateBit -eq "1") ? "1 (比特/秒: Mbps)" : "0 (字节/秒: MB/s)"
                "判定"     = ($rateBit -eq "0") ? "✔ 匹配" : "✘ 漂移"
            })

            # 启动时是否自动连好友
            $signFriend = ($content -match '"SignIntoFriends"\s+"(?<v>[01])"') ? $Matches.v : "1"
            $chkList.Add([PSCustomObject]@{
                "配置模块" = "账号: $($u.Name)"
                "受控属性" = "好友自动登录 (SignIntoFriends)"
                "期望基线" = "用户自定义 (建议: 0 离线)"
                "实机状态" = ($signFriend -eq "1") ? "1 (自动登录)" : "0 (不自动登录)"
                "判定"     = "✔ 观测"
            })

            # 默认在线/隐身状态
            if ($content -match '"FriendStoreLocalPrefs_\d+"\s+"(?<json>[^"]+)"') {
                try {
                    $pref = $Matches.json.Replace('\"', '"') | ConvertFrom-Json
                    $stateName = switch ($pref.ePersonaState) {
                        0 { "离线 (Offline)" }
                        1 { "在线 (Online)" }
                        7 { "隐身 (Invisible)" }
                        default { "状态码: $($pref.ePersonaState)" }
                    }
                    $chkList.Add([PSCustomObject]@{
                        "配置模块" = "账号: $($u.Name)"
                        "受控属性" = "好友默认呈现状态 (ePersonaState)"
                        "期望基线" = "用户按需 (7: 隐身 / 1: 在线)"
                        "实机状态" = $stateName
                        "判定"     = "✔ 观测"
                    })
                } catch {}
            }
        }
    }

    $chkList | Format-Table -AutoSize
    Write-Host "✔ 巡检完成，未对磁盘与注册表执行任何写入。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 阶段 1: 二进制安装与提取 (-InstallOnly / 缺失时自动安装)
# ==============================================================================
if (-not $ConfigOnly) {
    $needInstall = -not (Test-Path $steamExe)

    if ($needInstall -or $Clean) {
        Write-Host "⬇️  正在准备安装 Steam 客户端至: $InstallDir..." -ForegroundColor Cyan

        # 前置抹除注册表中历史安装路径残留，杜绝 NSIS 安装器内核逻辑强制回退覆盖命令行目标目录
        Remove-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "SteamPath", "SteamExe" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Valve\Steam" -Name "InstallPath" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -Name "InstallPath" -ErrorAction SilentlyContinue

        $tempInstaller = Join-Path $env:TEMP "SteamSetup_$(Get-Random).exe"
        try {
            $steamUrl = "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"
            Write-Host "   - 正在拉取官方安装器: $steamUrl..." -ForegroundColor Gray
            Invoke-WebRequest -Uri $steamUrl -OutFile $tempInstaller

            Write-Host "   - 正在执行静默安装至 $InstallDir..." -ForegroundColor Cyan
            # Steam 官方安装器基于 NSIS: /S 静默模式, /D 指定安装目录 (严格恪守 /D 必须置于最后且绝对无引号传递契约)
            $installProc = Start-Process -FilePath $tempInstaller -ArgumentList "/S /D=$InstallDir" -PassThru -Wait
            if ($installProc.ExitCode -ne 0) {
                Write-Warning "Steam 安装器返回退出码: $($installProc.ExitCode)，正在校验最终文件..."
            }
        }
        finally {
            if (Test-Path $tempInstaller) { Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue }
        }

        # 闭环验证物理落地状态并自适应自愈
        $postReg = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
        if ($postReg -and $postReg.SteamPath) {
            $actualInstalled = $postReg.SteamPath -replace '/', '\'
            if ($actualInstalled.TrimEnd('\') -ne $InstallDir.TrimEnd('\')) {
                Write-Warning "⚠️ 检测到安装器根据系统组策略重定向至: $actualInstalled (期望: $InstallDir)"
                $InstallDir = $actualInstalled
                $steamExe = Join-Path $InstallDir "steam.exe"
                $globalConfigFile = Join-Path $InstallDir "config\config.vdf"
            }
        }

        if (-not (Test-Path $steamExe)) {
            throw "Steam 安装失败，未能找到可执行文件: $steamExe"
        }
        Write-Host "✅ Steam 客户端本体安装就绪: $steamExe" -ForegroundColor Green
    } else {
        Write-Host "⏭️  [已就绪] 检测到 Steam 二进制本体 ($steamExe)，跳过重复安装。" -ForegroundColor Gray
    }
}

if ($InstallOnly) {
    return
}

# ==============================================================================
# 阶段 2: 核心配置与基线管控 (先检后配，严格防并发覆写)
# ==============================================================================
Write-Host "`n⚙️  正在执行 Steam 系统级基线与偏好配置..." -ForegroundColor Cyan

# 运行状态安全硬门禁：写入配置前必须确认 Steam 未常驻
$runningProc = Get-Process -Name "steam" -ErrorAction SilentlyContinue
if ($runningProc) {
    if (-not $NonInteractive) {
        Write-Warning "检测到 Steam 当前正在运行！外部修改会被 Steam 退出时的内存状态覆写。"
        $kill = Read-Host "是否由脚本安全终止 Steam 进程以继续配置? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($kill) -or ($kill -match "^(y|yes|true|1)$")) {
            $runningProc | Stop-Process -Force
            Start-Sleep -Milliseconds 800
            Write-Host "   - 已安全终止 Steam 进程。" -ForegroundColor Gray
        } else {
            throw "用户取消操作。请手动退出 Steam 后重新运行此脚本。"
        }
    } else {
        $runningProc | Stop-Process -Force
        Start-Sleep -Milliseconds 800
    }
}

Write-Host "`n⚙️  [受控配置基线] 正在应用以下黄金策略:" -ForegroundColor Cyan
Write-Host "   ▶ [开机启动] 彻底禁用开机自启 (释放工作站冷启动负载)" -ForegroundColor White
Write-Host "   ▶ [网络优化] 禁用局域网对等传输 (PeerContentServerMode=0，防偷跑与组播污染)" -ForegroundColor White
Write-Host "   ▶ [性能减负] 禁用后台着色器预编译 (bShaderCacheBGProcessingEnabled=0，杜绝闲置吃满CPU)" -ForegroundColor White
Write-Host "   ▶ [网络保障] 游戏时禁止后台下载更新 (AllowDownloadsDuringGameplay=0，防高延迟丢包)" -ForegroundColor White
Write-Host "   ▶ [下载偏好] 规范下载速率单位为直观的标准字节/秒 (MB/s)" -ForegroundColor White
Write-Host "   ▶ [启动加速] 生成无浏览器模式快捷方式 (-no-browser，约 50MB 内存轻量拉起)`n" -ForegroundColor White

# 1. 开机自启动项管控 (默认彻底阻断)
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$currentRun = (Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue).Steam
if ($currentRun) {
    Remove-ItemProperty -Path $runKey -Name "Steam" -Force -ErrorAction SilentlyContinue
    Write-Host "✅ [自启动] 已禁用 Steam 开机自启动注册表项 (释放冷启动系统资源)。" -ForegroundColor Green
} else {
    Write-Host "✅ [自启动] 状态合规：开机自启动此前已处于禁用状态。" -ForegroundColor Gray
}

# 2. 全局性能与网络配置对齐 (config\config.vdf)
$configDir = Join-Path $InstallDir "config"
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

$initialConfigTemplate = @"
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"PeerContentServerMode"		"0"
				"AllowDownloadsDuringGameplay"		"0"
				"ShaderCache"
				{
					"bShaderCacheBGProcessingEnabled"		"0"
				}
			}
		}
	}
}
"@

$globalRaw = (Test-Path $globalConfigFile) ? (Get-Content -Path $globalConfigFile -Raw -Encoding utf8NoBOM) : $initialConfigTemplate
$modifiedGlobal = $globalRaw

# 2.1 PeerContentServerMode -> 0
if ($modifiedGlobal -match '"PeerContentServerMode"\s+"([^"]+)"') {
    $modifiedGlobal = $modifiedGlobal -replace '"PeerContentServerMode"\s+"[^"]+"', '"PeerContentServerMode"		"0"'
} elseif ($modifiedGlobal -match '("Steam"\s*\{)') {
    $modifiedGlobal = $modifiedGlobal -replace '("Steam"\s*\{)', "`$1`r`n				`"PeerContentServerMode`"		`"0`""
}

# 2.2 AllowDownloadsDuringGameplay -> 0
if ($modifiedGlobal -match '"AllowDownloadsDuringGameplay"\s+"([^"]+)"') {
    $modifiedGlobal = $modifiedGlobal -replace '"AllowDownloadsDuringGameplay"\s+"[^"]+"', '"AllowDownloadsDuringGameplay"		"0"'
} elseif ($modifiedGlobal -match '("Steam"\s*\{)') {
    $modifiedGlobal = $modifiedGlobal -replace '("Steam"\s*\{)', "`$1`r`n				`"AllowDownloadsDuringGameplay`"		`"0`""
}

# 2.3 ShaderCache.bShaderCacheBGProcessingEnabled -> 0
if ($modifiedGlobal -match '"bShaderCacheBGProcessingEnabled"\s+"([^"]+)"') {
    $modifiedGlobal = $modifiedGlobal -replace '"bShaderCacheBGProcessingEnabled"\s+"[^"]+"', '"bShaderCacheBGProcessingEnabled"		"0"'
} elseif ($modifiedGlobal -match '("ShaderCache"\s*\{)') {
    $modifiedGlobal = $modifiedGlobal -replace '("ShaderCache"\s*\{)', "`$1`r`n					`"bShaderCacheBGProcessingEnabled`"		`"0`""
} elseif ($modifiedGlobal -match '("Steam"\s*\{)') {
    $scBlock = "`r`n				`"ShaderCache`"`r`n				{`r`n					`"bShaderCacheBGProcessingEnabled`"		`"0`"`r`n				}"
    $modifiedGlobal = $modifiedGlobal -replace '("Steam"\s*\{)', "`$1$scBlock"
}

if ($modifiedGlobal -ne $globalRaw -or (-not (Test-Path $globalConfigFile))) {
    Set-Content -Path $globalConfigFile -Value $modifiedGlobal -Encoding utf8NoBOM
    Write-Host "✅ [全局配置] 已回正 config.vdf 性能与网络策略 (局域网对传/着色器后台预编译已彻底禁用)。" -ForegroundColor Green
} else {
    Write-Host "✅ [全局配置] 全局性能策略与网络配置此前已处于黄金基线状态。" -ForegroundColor Gray
}

# 3. 用户偏好修复 (规范下载单位为 MB/s 字节显示)
$userDataDir = Join-Path $InstallDir "userdata"
if (Test-Path $userDataDir) {
    $userDirs = Get-ChildItem -Path $userDataDir -Directory -ErrorAction SilentlyContinue
    foreach ($u in $userDirs) {
        $vdfPath = Join-Path $u.FullName "config\localconfig.vdf"
        if (-not (Test-Path $vdfPath)) { continue }

        $rawText = Get-Content -Path $vdfPath -Raw -Encoding utf8NoBOM
        if ($rawText -match '"displayratesasbits"\s+"1"') {
            $updated = $rawText -replace '"displayratesasbits"\s+"1"', '"displayratesasbits"		"0"'
            Set-Content -Path $vdfPath -Value $updated -Encoding utf8NoBOM
            Write-Host "✅ [账号 $($u.Name)] 下载单位已修正为标准字节/秒 (MB/s)。" -ForegroundColor Green
        }
    }
}

# 4. 交付无浏览器模式快捷方式 (-no-browser)
try {
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($desktopNoBrowserLnk)
    $sc.TargetPath = $steamExe
    $sc.Arguments = "-no-browser +open steam://open/minigameslist"
    $sc.IconLocation = "$steamExe,0"
    $sc.Description = "Steam (No-Browser Mode)"
    $sc.Save()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
    Write-Host "✅ [桌面交付] 已在桌面生成 Steam (No-Browser) 快捷方式。" -ForegroundColor Green
} catch {
    Write-Warning "创建 No-Browser 快捷方式时出现警告: $_"
}

# ==============================================================================
# 尾部结报与手动引导清单
# ==============================================================================
Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  ✅ Steam 客户端基线加固与无浏览器模式配置完成！" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "   - 自启动项: 开机自启已被禁用，释放工作站冷启动负载" -ForegroundColor Gray
Write-Host "   - 全局网络: 禁用局域网对传与游戏中下载，杜绝偷跑与抢占带宽" -ForegroundColor Gray
Write-Host "   - 性能负载: 彻底关闭着色器后台预编译，杜绝闲置吃满 CPU 发热" -ForegroundColor Gray
Write-Host "   - 桌面集成: 桌面快捷方式 [-no-browser]，提供约 50MB 内存的轻量启动入口" -ForegroundColor Gray

Write-Host "`n--------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📋 [手动收尾引导清单 (Manual Checklist)]" -ForegroundColor Cyan
Write-Host " 1. 首次登录认证: 若尚未登录，请先启动常规 Steam 客户端，使用手机移动端扫码登录并勾选【记住我】" -ForegroundColor Gray
Write-Host " 2. 日常启动分流:" -ForegroundColor Gray
Write-Host "    - 本地已装游戏: 直接双击桌面【Steam (No-Browser)】(无 CEF 浏览器常驻负载，低内存开销)" -ForegroundColor Gray
Write-Host "    - 商店/社区/下载: 启动常规【Steam】客户端进入商店、下载管理或创意工坊" -ForegroundColor Gray
Write-Host " 3. 多盘库自动挂载: 若游戏分布在外部盘，首次在【设置 - 存储空间】添加对应磁盘目录一次即可" -ForegroundColor Gray
Write-Host "--------------------------------------------------`n" -ForegroundColor DarkGray
