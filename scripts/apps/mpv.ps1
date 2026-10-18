#requires -Version 7.0
<#
.SYNOPSIS
    mpv 播放器

.DESCRIPTION
    mpv 极简现代播放器 (Windows) 系统文件关联注册与 GPU 硬解画质基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 基于 Scoop 纳管的二进制本体 (D:\prog\scoop\apps\mpv\current\mpv.exe)。
    3. 系统级关联与默认程序注册：直接调用 mpv 原生 --register 注册系统播放器协议、ProgID (io.mpv.file) 与 RegisteredApplications（在 Win11 默认应用中点亮）。
    4. 现代化画质与硬解黄金基线：注入 portable_config\mpv.conf，固化 auto-safe GPU 硬解、新一代高质量渲染器 (vo=gpu-next/d3d11)、断点记忆、窗口居中自适应、字幕/音频模糊匹配、微软雅黑中文字体与无损 PNG 截图。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync        : 增量对齐黄金基线 (默认，缺失则装、偏离则修)
    - Check       : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - ResetConfig : 仅执行系统文件关联注册与 mpv.conf 黄金基线注入
    - Uninstall   : 彻底清洁卸载与注销系统媒体关联，抹除软件与配置
    - Upgrade     : 覆盖升级客户端本体 (调用 Scoop update)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\mpv.ps1 -Action Check

    # 交互式检查并应用黄金基线
    pwsh -File .\scripts\apps\mpv.ps1

    # 仅修复系统关联与硬解基线配置
    pwsh -File .\scripts\apps\mpv.ps1 -Action ResetConfig

    # 彻底清洁卸载
    pwsh -File .\scripts\apps\mpv.ps1 -Action Uninstall
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
    throw "【权限错误】mpv 系统媒体关联注册与默认程序配置需管理员特权，请在提升的 pwsh 会话中重新执行！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防配置污染，请直接在桌面登录用户会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 应用元数据与部署基准路径锁定 (Golden Baseline Paths)
# ==============================================================================
$AppId        = "mpv"
$AppName      = "mpv 极简现代播放器"
$ProcessName  = "mpv"
$ScoopBucket  = "extras"
$ScoopApp     = "mpv"

$scoopRoot    = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
$InstallDir   = Join-Path $scoopRoot "apps\$ScoopApp\current"
$AppExe       = Join-Path $InstallDir "mpv.exe"
$ConfDir      = Join-Path $InstallDir "portable_config"
$ConfigFile   = Join-Path $ConfDir "mpv.conf"
$PersistDir   = Join-Path $scoopRoot "persist\$ScoopApp"

$HighValueUserData = @(
    "播放器自定义配置与脚本: $ConfDir\mpv.conf, $ConfDir\scripts\",
    "视频断点记忆与观看历史: $ConfDir\watch_later\",
    "持久化目录: $PersistDir"
)

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
    $startEscaped = [regex]::Escape($startMarker)
    $endEscaped   = [regex]::Escape($endMarker)
    $pattern = "(?ms)^[ \t]*$startEscaped\r?\n.*?\r?\n[ \t]*$endEscaped[ \t]*\r?\n?"

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

$ManagedSpecs = @(
    @{
        Module   = "客户端本体"
        Property = "主执行文件 (mpv.exe)"
        Expected = "已安装于 Scoop 环境"
        Purpose  = "部署极简现代画质播放器本体"
        Impact   = "若未就绪将自动调用 Scoop 从 extras bucket 安装"
        Type     = "Binary"
    },
    @{
        Module   = "系统集成"
        Property = "系统媒体文件关联 (io.mpv.file)"
        Expected = "已向系统注册 (RegisteredApplications)"
        Purpose  = "注册音视频格式关联并在 Windows 11 设置「默认应用」中点亮 mpv"
        Impact   = "支持一键将 mpv 设为系统默认视频播放器"
        Type     = "Integration"
    },
    @{
        Module   = "播放配置"
        Key      = "vo"
        Property = "高质量视频渲染器 (vo = gpu-next)"
        Expected = "gpu-next"
        Purpose  = "启用 mpv 新一代基于 libplacebo 的高质量渲染器"
        Impact   = "提供更高的色彩精度与高质量色调映射，老旧核显若掉帧可切换回 gpu"
        Type     = "Config"
    },
    @{
        Module   = "播放配置"
        Key      = "hwdec"
        Property = "GPU 硬件加速解码 (hwdec = auto-safe)"
        Expected = "auto-safe"
        Purpose  = "优先调用 GPU 硬件解码器硬解 4K/HDR 视频流"
        Impact   = "大幅降低播放高码率视频时的 CPU 占用与发热，不兼容时自动安全回退软解"
        Type     = "Config"
    },
    @{
        Module   = "播放配置"
        Key      = "gpu-api"
        Property = "图形输出 API (gpu-api = d3d11)"
        Expected = "d3d11"
        Purpose  = "在 Windows 平台采用原生 Direct3D 11 图形接口"
        Impact   = "与 Windows 桌面窗口管理器 (DWM) 深度协同，减少画面撕裂与丢帧"
        Type     = "Config"
    },
    @{
        Module   = "播放配置"
        Key      = "sub-auto"
        Property = "智能同名字幕模糊匹配 (sub-auto = fuzzy)"
        Expected = "fuzzy"
        Purpose  = "自动加载同目录下名称相近的外挂字幕文件"
        Impact   = "看剧无需手动拖拽字幕文件，自动识别并加载"
        Type     = "Config"
    },
    @{
        Module   = "播放配置"
        Key      = "sub-font"
        Property = "字幕字体渲染固化 (sub-font = `"Microsoft YaHei`")"
        Expected = '"Microsoft YaHei"'
        Purpose  = "强制字幕文本采用系统内置微软雅黑字体渲染"
        Impact   = "彻底避免特殊汉字、标点与日文字符缺字乱码"
        Type     = "Config"
    },
    @{
        Module   = "播放配置"
        Key      = "save-position-on-quit"
        Property = "退出时断点记忆 (save-position-on-quit = yes)"
        Expected = "yes"
        Purpose  = "记录视频退出时的播放时间戳至 watch_later 目录"
        Impact   = "下次重新打开该视频时自动从上次观看中断处无缝续播"
        Type     = "Config"
    }
)

# ==============================================================================
# 3. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将注销系统媒体关联并彻底清理 mpv 播放器！" -ForegroundColor Yellow
        Write-Host "📌 【即将被物理抹除的高价值用户数据清单】:" -ForegroundColor Cyan
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "👉 执行清洁卸载将彻底清理配置目录。若需保留客制配置，请先手动备份。`n" -ForegroundColor Yellow

        $confirm = (Read-Host "确认注销系统媒体关联并彻底清理 mpv 及其配置? [y/N]").Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在注销系统关联并清理 mpv 环境..." -ForegroundColor Yellow

    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force

    if (Test-Path $AppExe) {
        Write-Host "   - 正在调用 mpv --unregister 注销系统级文件类型关联..." -ForegroundColor Gray
        Start-Process -FilePath $AppExe -ArgumentList "--unregister" -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }

    @(
        "HKCU:\Software\Classes\io.mpv.file",
        "HKLM:\SOFTWARE\Classes\io.mpv.file",
        "HKCU:\Software\Classes\Applications\mpv.exe",
        "HKLM:\SOFTWARE\Classes\Applications\mpv.exe"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "mpv" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "mpv" -ErrorAction SilentlyContinue

    $mediaExts = @(".mp4", ".mkv", ".avi", ".mov", ".flv", ".webm", ".wmv", ".mp3", ".flac", ".wav", ".m4a", ".aac")
    foreach ($ext in $mediaExts) {
        Remove-ItemProperty -Path "HKCU:\Software\Classes\$ext\OpenWithProgids" -Name "io.mpv.file" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Classes\$ext\OpenWithProgids" -Name "io.mpv.file" -ErrorAction SilentlyContinue
    }

    $mpvShortcuts = @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "mpv.lnk"),
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Scoop Apps" "mpv.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "mpv.lnk")
    )
    foreach ($sc in $mpvShortcuts) {
        if (Test-Path $sc) { Remove-Item -Path $sc -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path $ConfDir) {
        Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $PersistDir) {
        Remove-Item -Path $PersistDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Get-Command "scoop" -ErrorAction SilentlyContinue) {
        if (Test-Path (Join-Path $scoopRoot "apps\mpv")) {
            & scoop uninstall -p mpv
        }
    }
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`n✅ [清洁卸载完成] mpv 系统注册与本体已彻底清除。`n" -ForegroundColor Green
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
$regApp = (Get-ItemProperty "HKLM:\SOFTWARE\RegisteredApplications" -Name "mpv" -ErrorAction SilentlyContinue).mpv
if (-not $regApp) {
    $regApp = (Get-ItemProperty "HKCU:\Software\RegisteredApplications" -Name "mpv" -ErrorAction SilentlyContinue).mpv
}
$progId = (Test-Path "HKLM:\SOFTWARE\Classes\io.mpv.file") -or (Test-Path "HKCU:\Software\Classes\io.mpv.file")
$isRegistered = ($null -ne $regApp -and $progId)

$confRaw = if (Test-Path $ConfigFile) { Get-Content -Path $ConfigFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { "" }

function Get-MpvConfigValue([string]$raw, [string]$key) {
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    $escaped = [regex]::Escape($key)
    if ($raw -match "(?m)^[ \t]*$escaped[ \t]*=[ \t]*(.*?)[ \t]*$") {
        return $matches[1].Trim()
    }
    return $null
}

foreach ($spec in $ManagedSpecs) {
    $actualStr = ""
    $isMatch = $false

    if ($spec.Type -eq "Binary") {
        $actualStr = if ($isInstalled) { "已就绪" } else { "未安装" }
        $isMatch = $isInstalled
    } elseif ($spec.Type -eq "Integration") {
        $actualStr = if ($isRegistered) { "已注册" } else { "未注册" }
        $isMatch = $isRegistered
    } elseif ($spec.Type -eq "Config") {
        $val = Get-MpvConfigValue $confRaw $spec.Key
        $actualStr = if ($null -eq $val) { "<缺省未设>" } else { "$val" }
        $isMatch = ($actualStr -eq $spec.Expected)
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
            Spec     = $spec
            Actual   = $actualStr
            Expected = $spec.Expected
        })
    }
}

Write-Host "`n📊 [巡检看板] mpv 原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($Action -eq "Check") {
    if ($driftCount -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性均与工程黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $driftCount) -ForegroundColor Yellow
    }
    return
}

if ($driftCount -eq 0 -and $Action -ne "Upgrade") {
    Write-Host "✨ [状态合规] 所有受控属性均已符合工程黄金基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate - Shift-Left: 目的与影响结构化直出)
# ==============================================================================

# 5.1 运行态并发防覆写硬门禁
$runningMpv = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if ($runningMpv) {
    if (-not $Yes) {
        Write-Warning "检测到 mpv 播放器当前正在运行！外部修改会被退出时的内存状态覆写。"
        $confirmProc = (Read-Host "是否立即关闭正在运行的 mpv 进程以继续应用基线? [Y/n]").Trim()
        if ($confirmProc -match '^(n|no)$') {
            Write-Host "[-] 用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningMpv | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# 5.2 未安装审查门禁
if (-not $isInstalled) {
    if ($Action -eq "ResetConfig") {
        throw "未检测到 mpv 客户端安装！请先执行 -Action Sync 安装后再执行配置重置。"
    }

    if (-not $Yes) {
        $shouldInstall = (Read-Host "未检测到 mpv 播放器，是否立即调用 'scoop install extras/mpv' 进行安装？[Y/n]").Trim()
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
    foreach ($p in $PendingItems) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.Spec.Property) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.Actual, $p.Expected) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $p.Spec.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $p.Spec.Impact) -ForegroundColor Gray
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
    if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
        throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
    }

    if ($Action -eq "Upgrade") {
        Write-Host "`n📦 [覆盖升级] 正在调用 Scoop 升级 mpv 本体..." -ForegroundColor Cyan
        & scoop update mpv
        Write-Host "✅ [升级完成] mpv 客户端本体已完成升级。`n" -ForegroundColor Green
        return
    } else {
        Write-Host "`n🚀 正在通过 Scoop 安装 mpv..." -ForegroundColor Cyan
        & scoop bucket add extras 2>$null | Out-Null
        & scoop install extras/mpv

        if (Test-Path (Join-Path $InstallDir "mpv.exe")) {
            $AppExe = Join-Path $InstallDir "mpv.exe"
            $isInstalled = $true
        }
        if (-not $isInstalled) {
            throw "Scoop 安装完成，但未能定位到 $AppExe，请检查 Scoop 安装状态。"
        }
    }
}

# 6.2 注册系统关联与 RegisteredApplications
Write-Host "`n⚙️  正在调用原生 mpv --register 注册系统媒体协议与关联..." -ForegroundColor Cyan
try {
    Start-Process -FilePath $AppExe -ArgumentList "--register" -Wait -NoNewWindow
    Write-Host "✅ 系统文件类型关联与 RegisteredApplications 注册完成。" -ForegroundColor Green
} catch {
    Write-Warning "调用 mpv --register 注册遇到异常: $($_.Exception.Message)"
}

# 6.3 注入 mpv.conf 体验基线偏好
Write-Host "⚙️  正在对齐 mpv.conf 黄金画质与体验基线..." -ForegroundColor Cyan
Update-ManagedConfigFile -FilePath $ConfigFile -Tag "mpv-baseline" -NewContent $mpvBaseline
Write-Host "✅ mpv.conf 体验基线配置已原子落盘至: $ConfigFile" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与系统注册管理完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 渲染基线: 已启用 gpu-next 高质量渲染器与 auto-safe 硬件加速" -ForegroundColor Gray
Write-Host "   - 字体与字幕: 已固化 Microsoft YaHei 与智能同名模糊匹配" -ForegroundColor Gray
Write-Host "   - 进度记忆: 已开启退出自动断点记忆与无损 PNG 截屏收敛" -ForegroundColor Gray

$isDefaultVideo = $false
try {
    $mp4Choice = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.mp4\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    if ($mp4Choice -eq "io.mpv.file") { $isDefaultVideo = $true }
} catch { }

if (-not $isDefaultVideo) {
    Write-Host "`n--------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "📋 [手动收尾清单 (Actionable Handoff)]" -ForegroundColor Cyan
    Write-Host "  1. 设为默认: 在系统【默认应用】中将 mpv 设为视频播放器默认应用" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------`n" -ForegroundColor DarkGray
}

return
