#requires -Version 7.0
<#
.SYNOPSIS
    mpv 播放器

.DESCRIPTION
    mpv 极简现代播放器 (Windows) 系统文件关联注册与 GPU 硬解画质基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循“先检查后配置、幂等无冗余”原则。
    2. 基于 Scoop 纳管的二进制本体（D:\prog\scoop\apps\mpv\current\mpv.exe），前置安装状态探测。
    3. 系统级关联与默认程序注册：直接调用 mpv 原生 --register 注册系统播放器协议、ProgID (io.mpv.file) 与 RegisteredApplications（在 Win11 默认应用中点亮）。
    4. 现代化画质与硬解黄金基线：注入 portable_config\mpv.conf，固化 auto-safe GPU 硬解、新一代高质量渲染器 (vo=gpu-next/d3d11)、断点记忆、窗口居中自适应、字幕/音频模糊匹配、微软雅黑中文字体与无损 PNG 截图。

.PARAMETER Clean
    清洁卸载模式。调用原生 --unregister 注销系统关联，清理 portable_config 配置，并通过 Scoop 卸载客户端本体。
    别名: -Fresh, -Reset

.PARAMETER CheckOnly
    只查不改模式（体检巡检）。逐项比对 mpv 安装状态、系统文件关联注册表与 mpv.conf 核心参数基线，高亮输出 Diff，零写入安全退出。
    别名: -Audit

.PARAMETER ConfigOnly
    仅执行系统文件关联注册与 mpv.conf 黄金基线注入，不重新安装或更新二进制程序。

.PARAMETER InstallOnly
    仅执行通过 Scoop 更新或安装 mpv 本体，不修改配置。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线（用于自动化流水线）。

.PARAMETER InstallDir
    mpv 安装目标目录，默认优先自适应探测 Scoop 路径（如 D:\prog\scoop\apps\mpv\current）。

.PARAMETER ConfDir
    mpv 配置目录，默认为安装目录下的 portable_config。

.EXAMPLE
    # 交互式全流程检查与配置
    pwsh -File .\scripts\apps\mpv.ps1

    # 只查不改体检巡检
    pwsh -File .\scripts\apps\mpv.ps1 -CheckOnly

    # 仅修复系统关联与硬解基线配置
    pwsh -File .\scripts\apps\mpv.ps1 -ConfigOnly

    # 彻底清洁重装
    pwsh -File .\scripts\apps\mpv.ps1 -Clean
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
    [string]$InstallDir,
    [string]$ConfDir
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
# 0. 路径自适应探测与初始化
# ==============================================================================
$scoopRoots = @($env:SCOOP, "D:\prog\scoop", (Join-Path $env:USERPROFILE "scoop")) | Where-Object { $_ -and (Test-Path $_) }
$defaultScoop = if ($scoopRoots.Count -gt 0) { $scoopRoots[0] } else { "D:\prog\scoop" }

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    foreach ($root in $scoopRoots) {
        $cand = Join-Path $root "apps\mpv\current"
        if (Test-Path (Join-Path $cand "mpv.exe")) {
            $InstallDir = $cand
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = Join-Path $defaultScoop "apps\mpv\current"
    }
}

$mpvExe = Join-Path $InstallDir "mpv.exe"
$isInstalled = Test-Path $mpvExe

if ([string]::IsNullOrWhiteSpace($ConfDir)) {
    $ConfDir = Join-Path $InstallDir "portable_config"
}

$confFile = Join-Path $ConfDir "mpv.conf"

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "  mpv 极简现代播放器系统注册与画质自愈工具 (pwsh 7+)" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "📂 部署基准目录: 安装目录 [$InstallDir] | 配置目录 [$ConfDir]`n" -ForegroundColor Cyan

# 辅助函数：更新标记配置块 (Managed Config Block)
function Update-ManagedConfigFile {
    param(
        [string]$FilePath,
        [string]$Tag,
        [string]$NewContent
    )
    $startMarker = "# >>> managed: $Tag >>>"
    $endMarker   = "# <<< managed: $Tag <<<"
    $managedBlock = "$startMarker`r`n$NewContent`r`n$endMarker"

    if (-not (Test-Path $FilePath)) {
        $parent = Split-Path $FilePath -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($FilePath, "$managedBlock`r`n", [System.Text.UTF8Encoding]::new($false))
        return
    }

    $existing = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $pattern = "(?ms)^[ \t]*\Q$startMarker\E\r?\n.*?\r?\n[ \t]*\Q$endMarker\E[ \t]*\r?\n?"

    if ($existing -match $pattern) {
        $updated = [System.Text.RegularExpressions.Regex]::Replace($existing, $pattern, "$managedBlock`r`n")
    } else {
        $trimmed = $existing.TrimEnd()
        $updated = if ($trimmed.Length -gt 0) { "$trimmed`r`n`r`n$managedBlock`r`n" } else { "$managedBlock`r`n" }
    }
    [System.IO.File]::WriteAllText($FilePath, $updated, [System.Text.UTF8Encoding]::new($false))
}

$mpvBaseline = @'
# 启用 GPU 硬件加速解码与新一代高质量渲染器 (保障 4K/HDR 流畅低功耗与色彩高保真)
hwdec=auto-safe
vo=gpu-next
gpu-api=d3d11
profile=high-quality

# 退出时自动记忆播放进度与断点
save-position-on-quit=yes

# 播放完毕后保持窗口开启 (不自动退出，方便定位与连播)
keep-open=yes

# 初始窗口大小自适应屏幕 80% 并居中呈现
autofit-larger=80%x80%
geometry=50%:50%

# 智能外挂字幕与音频流模糊匹配 (同目录下相近文件名自动加载，优选中/日英字幕与音轨)
sub-auto=fuzzy
audio-file-auto=fuzzy
slang=chi,zh-CN,zh-TW,zh,chs,cht,eng
alang=chi,zh-CN,zh-TW,zh,chs,cht,jpn,eng

# 固化字幕渲染字体为系统微软雅黑 (防生僻汉字与特殊符号缺字乱码)
sub-font="Microsoft YaHei"
blend-subtitles=video

# 允许最大音量软增益至 200% 与变速播放原声音调保真
volume-max=200
audio-pitch-correction=yes

# 截屏输出格式与自动归档收敛 (PNG 无损质量，自动归档至系统图片目录)
screenshot-format=png
screenshot-template="~/Pictures/mpv/mpv-screen-%F-%p-%n"
'@

# ==============================================================================
# 阶段 A: 清洁卸载与环境重置 (-Clean)
# ==============================================================================
if ($Clean) {
    Write-Host "🧹 [清洁重装模式] 正在注销系统关联并清理 mpv 环境..." -ForegroundColor Yellow

    # 1. 终止进程
    Get-Process -Name "mpv" -ErrorAction SilentlyContinue | Stop-Process -Force

    # 2. 注销系统级文件类型关联与快捷方式
    if ($isInstalled) {
        Write-Host "   - 正在调用 mpv --unregister 注销系统级文件类型关联..." -ForegroundColor Gray
        Start-Process -FilePath $mpvExe -ArgumentList "--unregister" -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }
    $mpvShortcuts = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "mpv.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Scoop Apps" "mpv.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "mpv.lnk"),
        "C:\Users\Public\Desktop\mpv.lnk"
    )
    foreach ($sc in $mpvShortcuts) {
        if (Test-Path $sc) { Remove-Item -Path $sc -Force -ErrorAction SilentlyContinue }
    }

    # 3. 清理配置目录
    if (Test-Path $ConfDir) {
        Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理配置目录: $ConfDir" -ForegroundColor Gray
    }

    # 4. 卸载程序本体
    if (Test-Path $InstallDir) {
        if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
            Write-Host "   - 正在调用 Scoop 卸载客户端本体..." -ForegroundColor Gray
            & scoop uninstall mpv 2>$null | Out-Null
        } else {
            Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "✅ [清洁完成] mpv 系统注册与本体已彻底清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 阶段 B: 只查不改体检巡检 (-CheckOnly / -Audit)
# ==============================================================================
if ($CheckOnly) {
    Write-Host "🔍 [只查不改模式] 正在对 mpv 播放器与系统级偏好执行逐项巡检..." -ForegroundColor Cyan

    $chkList = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. 二进制安装
    $chkList.Add([PSCustomObject]@{
        "配置模块" = "客户端本体"
        "受控属性" = "二进制程序 (mpv.exe)"
        "期望基线" = "已安装于 Scoop 环境"
        "实机状态" = $isInstalled ? "已安装 ($mpvExe)" : "未安装"
        "判定"     = $isInstalled ? "✔ 匹配" : "✘ 缺失"
    })

    # 2. 系统 RegisteredApplications 注册
    $regApp = (Get-ItemProperty "HKLM:\SOFTWARE\RegisteredApplications" -Name "mpv" -ErrorAction SilentlyContinue).mpv
    if (-not $regApp) {
        $regApp = (Get-ItemProperty "HKCU:\Software\RegisteredApplications" -Name "mpv" -ErrorAction SilentlyContinue).mpv
    }
    $progId = (Test-Path "HKLM:\SOFTWARE\Classes\io.mpv.file") -or (Test-Path "HKCU:\Software\Classes\io.mpv.file")
    $isRegistered = ($null -ne $regApp -and $progId)

    $chkList.Add([PSCustomObject]@{
        "配置模块" = "系统集成"
        "受控属性" = "系统媒体文件类型关联 (io.mpv.file)"
        "期望基线" = "已向系统注册 (可在默认应用中点亮)"
        "实机状态" = $isRegistered ? "已注册 (RegisteredApplications)" : "未注册"
        "判定"     = $isRegistered ? "✔ 匹配" : "✘ 缺失 (需执行 --register)"
    })

    # 3. mpv.conf 基线配置就绪度
    $hasConfig = $false
    if (Test-Path $confFile) {
        $confRaw = Get-Content -Path $confFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        $hasConfig = ($confRaw -match "# >>> managed: mpv-baseline >>>") -and
                     ($confRaw -match "vo=gpu-next") -and
                     ($confRaw -match "hwdec=auto-safe") -and
                     ($confRaw -match "sub-auto=fuzzy")
    }

    $chkList.Add([PSCustomObject]@{
        "配置模块" = "播放配置"
        "受控属性" = "画质与硬解基线 (mpv.conf)"
        "期望基线" = "gpu-next + d3d11 + auto-safe + fuzzy字幕"
        "实机状态" = $hasConfig ? "已就绪 (managed 托管块)" : (Test-Path $confFile ? "偏离期望" : "文件缺失")
        "判定"     = $hasConfig ? "✔ 匹配" : "✘ 缺失/漂移"
    })

    Write-Host "`n📊 [巡检看板] mpv 受控属性基线审计清单:" -ForegroundColor Cyan
    $chkList | Format-Table -AutoSize | Out-String | Write-Host

    $driftCount = ($chkList | Where-Object { $_.判定 -like "✘*" }).Count
    if ($driftCount -eq 0) {
        Write-Host "🎉 状态完美！所有受控属性均与工程黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host "⚠️  共发现 $driftCount 项偏离或缺失。执行本脚本默认模式 (-Sync) 或纯配置重置 (-ConfigOnly) 即可自动对齐自愈。`n" -ForegroundColor Yellow
        if (-not $isInstalled) {
            Write-Host "💡 提示: 未检测到客户端安装，请先执行 'scoop install extras/mpv' 安装本体。" -ForegroundColor Gray
        }
    }
    return
}

# ==============================================================================
# 前置门禁断言：验证是否已安装 (除 CheckOnly/Clean 外其余模式强制要求)
# ==============================================================================
if (-not $isInstalled) {
    if ($ConfigOnly) {
        throw "未检测到 mpv 客户端安装。本工具专注于系统注册与画质加固，请先执行 'scoop install extras/mpv' 安装后再执行配置。"
    }

    Write-Host "⚠️  未在 Scoop 路径检测到已安装的 mpv 播放器。" -ForegroundColor Yellow
    if ($NonInteractive) {
        throw "非交互模式下检测到未安装 mpv，拒绝盲目静默安装。请先在交互环境中确认安装。"
    }

    $shouldInstall = Read-Host "是否立即调用 'scoop install extras/mpv' 进行安装？(y/N)"
    if ($shouldInstall.Trim().ToLower() -eq 'y') {
        if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
            throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
        }
        Write-Host "🚀 正在通过 Scoop 安装 mpv..." -ForegroundColor Cyan
        & scoop bucket add extras 2>$null | Out-Null
        & scoop install extras/mpv

        # 重新探测
        foreach ($root in $scoopRoots) {
            $cand = Join-Path $root "apps\mpv\current"
            if (Test-Path (Join-Path $cand "mpv.exe")) {
                $InstallDir = $cand
                $mpvExe = Join-Path $InstallDir "mpv.exe"
                $isInstalled = $true
                break
            }
        }
        if (-not $isInstalled) {
            throw "Scoop 安装完成，但未能定位到 $mpvExe，请检查 Scoop 安装状态。"
        }
    } else {
        Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor Yellow
        return
    }
}

# ==============================================================================
# 阶段 C: 覆盖更新本体 (-InstallOnly)
# ==============================================================================
if ($InstallOnly) {
    Write-Host "📦 [覆盖升级模式] 正在调用 Scoop 升级 mpv 本体..." -ForegroundColor Cyan
    Get-Process -Name "mpv" -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        & scoop update mpv
        Write-Host "✅ [升级完成] mpv 客户端本体已通过 Scoop 完成升级。`n" -ForegroundColor Green
    } else {
        throw "未检测到 scoop 命令，无法执行自动更新。"
    }
    return
}

# ==============================================================================
# 阶段 D: 增量对齐 (-Sync / 默认) 与 纯配置重置 (-ConfigOnly)
# ==============================================================================
Write-Host "⚙️  正在执行系统关联注册与 mpv 现代化画质配置对齐..." -ForegroundColor Cyan

# 1. 注册 mpv 系统级文件类型关联与自动播放功能
Write-Host "   - 正在调用 mpv --register 向系统注册媒体格式关联与 RegisteredApplications..." -ForegroundColor Gray
Start-Process -FilePath $mpvExe -ArgumentList "--register" -Wait -NoNewWindow

# mpv --register 会在开始菜单根目录自动生成 mpv.lnk，将其收敛为 Scoop 纳管路径
$strayMpvLnk = Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "mpv.lnk"
if (Test-Path $strayMpvLnk) {
    Remove-Item -Path $strayMpvLnk -Force -ErrorAction SilentlyContinue
}
Write-Host "✅ 系统文件类型关联与默认应用注册完成。" -ForegroundColor Green

# 2. 注入/更新 mpv.conf 现代化硬解与画质体验基线配置
if (-not (Test-Path $ConfDir)) {
    New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
}

Update-ManagedConfigFile $confFile "mpv-baseline" $mpvBaseline
Write-Host "✅ 现代化 GPU 硬解 (gpu-next/d3d11) 与微软雅黑字幕基线已原子落盘至: $confFile" -ForegroundColor Green

# ==============================================================================
# 尾部结报与手动引导清单
# ==============================================================================
Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  ✅ mpv 播放器基线与系统注册管理完成！" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "   - 关联注册: 已通过 --register 向 Windows 注册 io.mpv.file 媒体关联" -ForegroundColor Gray
Write-Host "   - 渲染基线: 固化 auto-safe GPU 硬解、gpu-next/d3d11 与断点进度记忆" -ForegroundColor Gray
Write-Host "   - 字幕排版: 固化 sub-auto=fuzzy 模糊匹配与微软雅黑高质量平滑渲染" -ForegroundColor Gray

Write-Host "`n--------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📋 [手动收尾引导清单 (Manual Checklist)]" -ForegroundColor Cyan
Write-Host " 1. 设为默认: 在 Windows 11【设置 - 应用 - 默认应用】中将 mpv 设为视频文件默认播放器" -ForegroundColor Gray
Write-Host " 2. 硬解验证: 播放 4K/HDR 视频时按键盘 'i' 或 'Shift + i' 调出状态面板，确认 hwdec 显示硬件解码" -ForegroundColor Gray
Write-Host " 3. 截屏目录: 按 's' 截屏，检查截屏文件是否按期望归档至系统图片目录 (~/Pictures/mpv/)" -ForegroundColor Gray
Write-Host "--------------------------------------------------`n" -ForegroundColor DarkGray
