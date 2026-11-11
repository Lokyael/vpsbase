#requires -Version 7.0
<#
.SYNOPSIS
    mpv 播放器

.DESCRIPTION
    mpv 极简现代播放器 (Windows) 画质与体验偏好基线配置工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 基于 Scoop 纳管的二进制本体 (D:\prog\scoop\apps\mpv\current\mpv.exe)。本体生命周期与包集成由 Scoop 负责，脚本不自造系统 ProgID 与 RegisteredApplications。
    3. 在 portable_config\mpv.conf 末尾以 [default] 托管默认画质与体验基线，保留块外用户配置与命名 Profile。巡检及写后复验仅覆盖本文件默认作用域的受控标量，不解析 include、Profile 应用、命令行或运行期覆盖。
    4. 卸载生命周期遵循“先判断、后调用、再清理”：先核验运行态与目标实例，由 Scoop 卸载本体并独立核验终态；确认 Absent 后定点清理声明残留与 persist 目录；不强杀进程，不补删目录。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (只读比对受控属性 Diff)
    - Uninstall : 清洁卸载与清理声明残留 (退役本体并定点清理声明数据与 persist 目录)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\desktop\apps\mpv.ps1 -Action Check

    # 交互式检查并应用工程基线
    pwsh -File .\desktop\apps\mpv.ps1

    # 安全清洁卸载 (退役本体并清理声明残留)
    pwsh -File .\desktop\apps\mpv.ps1 -Action Uninstall
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

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防配置污染，请直接在 [$consoleUser] 桌面会话中执行。"
}

$console = Join-Path $PSScriptRoot "_console.ps1"
if (-not (Test-Path $console)) {
    throw "未在应用域定位到核心终端交互组件: _console.ps1，请确保仓库完整性！"
}

# ==============================================================================
# 2. 应用元数据与部署基准路径锁定 (Managed Baseline Paths)
# ==============================================================================
$AppId        = "mpv"
$AppName      = "mpv 极简现代播放器"
$ProcessName  = "mpv"
$ScoopBucket  = "extras"
$ScoopApp     = "mpv"

$scoopRoot    = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
$InstallDir   = Join-Path $scoopRoot "apps\$ScoopApp\current"
$AppExe       = Join-Path $InstallDir "mpv.exe"
$PersistDir   = Join-Path $scoopRoot "persist\$ScoopApp"
$ConfDir      = Join-Path $PersistDir "portable_config"
$ConfigFile   = Join-Path $ConfDir "mpv.conf"

$HighValueUserData = @(
    "播放器自定义配置与脚本: $ConfDir\mpv.conf, $ConfDir\scripts\",
    "视频断点记忆与观看历史: $ConfDir\watch_later\",
    "持久化目录: $PersistDir"
)

function Get-ScoopInstallRecord {
    param([string]$CurrentDir)
    foreach ($name in @('scoop-install.json', 'install.json')) {
        $path = Join-Path $CurrentDir $name
        if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) {
            $info = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
            if ($info -isnot [System.Management.Automation.PSCustomObject] -or
                ($null -ne $info.hold -and $info.hold -isnot [bool])) {
                throw "Scoop 安装记录格式无效: $path"
            }
            return [PSCustomObject]@{
                Path = $path
                Held = $info.hold -eq $true
                LastWriteTimeUtc = (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTimeUtc
            }
        }
    }
    if (Test-Path -LiteralPath (Split-Path $CurrentDir -Parent) -ErrorAction Stop) {
        throw "Scoop 应用目录存在但当前安装记录缺失，请先通过 Scoop 检查安装状态: $CurrentDir"
    }
    return $null
}

function Ensure-ScoopBucket {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BucketName,
        [string]$BucketRepo = ""
    )
    $bucketDir = Join-Path $scoopRoot "buckets\$BucketName"
    if (Test-Path $bucketDir) {
        return
    }

    $installedBuckets = @(& scoop bucket list 2>$null 3>$null | ForEach-Object {
        if ($_.Name) { $_.Name } else { ($_ -split '\s+')[0] }
    })
    if ($installedBuckets -contains $BucketName) {
        return
    }

    Write-Host "📦 正在添加 Scoop '$BucketName' bucket..." -ForegroundColor Cyan
    $global:LASTEXITCODE = $null
    if ($BucketRepo) {
        & scoop bucket add $BucketName $BucketRepo
    } else {
        & scoop bucket add $BucketName
    }
    $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "添加 Scoop bucket '$BucketName' 失败 (退出代码 $exitCode)，请检查网络连接与仓库地址。"
    }
}

function Read-MpvConfig {
    param([string]$FilePath)
    try { return [IO.File]::ReadAllText($FilePath, [Text.Encoding]::UTF8) }
    catch [IO.FileNotFoundException] { return '' }
    catch [IO.DirectoryNotFoundException] { return '' }
}

function Get-MpvConfigValue([string]$raw, [string]$key) {
    $section = 'default'
    $value = $null
    foreach ($line in ($raw -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $section = $matches[1]
            continue
        }
        if ($section -cne 'default') { continue }
        if ($line -cmatch ('^\s*(?:--)?(?<negated>no-)?' + [regex]::Escape($key) + '\s*(?:#.*)?$')) {
            $value = if ($matches['negated']) { 'no' } else { 'yes' }
        } elseif ($line -cmatch ('^\s*(?:--)?' + [regex]::Escape($key) + '\s*=\s*(.*)$')) {
            $text = $matches[1].Trim()
            if ($text.StartsWith('"') -or $text.StartsWith("'")) {
                $quote = $text[0]
                $end = $text.IndexOf($quote, 1)
                if ($end -lt 0 -or $text.Substring($end + 1).Trim() -notmatch '^(?:#.*)?$') {
                    throw "mpv 默认配置的 $key 引号或尾部内容无效。"
                }
                $value = $text.Substring(1, $end - 1)
            } elseif ($text.StartsWith('%')) {
                throw "mpv 默认配置的 $key 使用了未纳管的定长引用语法，请先改为普通标量或引号值。"
            } else {
                $value = ($text -split '#', 2)[0].Trim()
            }
        }
    }
    return $value
}

function Assert-MpvConfig {
    param([string]$Text, [System.Collections.IList]$Specs)
    foreach ($spec in $Specs) {
        if ($spec.Type -eq 'Config' -and (Get-MpvConfigValue $Text $spec.Key) -cne $spec.Expected) {
            throw "mpv 本文件默认配置检查失败: $($spec.Key)；未验证其他配置来源或运行态。"
        }
    }
}

function Assert-AppStopped {
    if (Get-Process -ErrorAction Stop | Where-Object ProcessName -in @('mpv')) {
        throw 'mpv 仍在运行，请自行退出后重新执行。'
    }
}

function Get-MpvManagedConfigContent {
    param([string]$existing, [string]$Tag, [string]$NewContent)
    $startMarker = "# >>> managed: $Tag >>>"
    $endMarker = "# <<< managed: $Tag <<<"
    $startEscaped = [regex]::Escape($startMarker)
    $endEscaped = [regex]::Escape($endMarker)
    $pattern = "(?ms)^[ \t]*$startEscaped[ \t]*\r?\n(?<body>.*?)^[ \t]*$endEscaped[ \t]*(?:\r?\n|$)"
    $blocks = [regex]::Matches($existing, $pattern)
    $markers = [regex]::Matches($existing, "(?m)^[ \t]*(?:$startEscaped|$endEscaped)[ \t]*\r?$")
    if ($markers.Count -ne 2 * $blocks.Count) { throw 'mpv 托管块边界不完整，未修改文件。' }
    foreach ($block in $blocks) {
        if ($block.Groups['body'].Value.Contains($startMarker)) { throw 'mpv 托管块嵌套，未修改文件。' }
        $sections = [regex]::Matches($block.Groups['body'].Value, '(?m)^\s*\[([^\]]+)\]\s*(?:#.*)?$')
        foreach ($section in $sections) {
            if ($section.Groups[1].Value -cne 'default') { throw 'mpv 托管块内存在用户 Profile，未修改文件。' }
        }
    }
    $unmanaged = [regex]::Replace($existing, $pattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        # 移动中间托管块时保留其已有作用域切换，避免改变块外选项归属。
        if ($match.Groups['body'].Value -match '(?m)^\s*\[default\]\s*(?:#.*)?$' -and
            -not [string]::IsNullOrWhiteSpace($existing.Substring($match.Index + $match.Length))) {
            return "[default]`r`n"
        }
        return ''
    })
    $prefix = $unmanaged.TrimEnd("`r", "`n")
    if ($prefix.Length) { $prefix += "`r`n`r`n" }
    return "$prefix$startMarker`r`n[default]`r`n$($NewContent.TrimEnd("`r", "`n"))`r`n$endMarker`r`n"
}

function Update-ManagedConfigFile {
    param([string]$FilePath, [string]$Tag, [string]$NewContent, [System.Collections.IList]$Specs)
    $existing = Read-MpvConfig $FilePath
    $updated = Get-MpvManagedConfigContent -existing $existing -Tag $Tag -NewContent $NewContent
    Assert-MpvConfig -Text $updated -Specs $Specs
    if ($existing -cne $updated) {
        $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($FilePath))
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        $temporary = Join-Path $parent ('.mpv-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporary, $FilePath, $true)
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    Assert-MpvConfig -Text (Read-MpvConfig $FilePath) -Specs $Specs
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
        Module   = "本体"
        Property = "主执行文件 (mpv.exe)"
        Expected = "已安装于 Scoop 环境"
        Purpose  = "部署极简现代画质播放器本体"
        Impact   = "若未就绪将自动调用 Scoop 从 extras bucket 安装"
        Type     = "Binary"
    },
    @{
        Module   = "配置"
        Property = "文件末尾唯一默认基线托管块"
        Expected = "末尾唯一 [default] 托管块"
        Purpose  = "将受控默认配置放在文件末尾，避免混入用户命名 Profile"
        Impact   = "保留块外配置；命名 Profile、include、命令行或运行期设置仍可能覆盖默认值"
        Type     = "ManagedBlock"
    },
    @{
        Module   = "配置"
        Key      = "vo"
        Property = "高质量视频渲染器 (vo = gpu-next)"
        Expected = "gpu-next"
        Purpose  = "启用 mpv 新一代基于 libplacebo 的高质量渲染器"
        Impact   = "提供更高的色彩精度与高质量色调映射，老旧核显若掉帧可切换回 gpu"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Key      = "hwdec"
        Property = "GPU 硬件加速解码 (hwdec = auto-safe)"
        Expected = "auto-safe"
        Purpose  = "优先调用 GPU 硬件解码器硬解 4K/HDR 视频流"
        Impact   = "大幅降低播放高码率视频时的 CPU 占用与发热，不兼容时自动安全回退软解"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Key      = "gpu-api"
        Property = "图形输出 API (gpu-api = d3d11)"
        Expected = "d3d11"
        Purpose  = "在 Windows 平台采用原生 Direct3D 11 图形接口"
        Impact   = "与 Windows 桌面窗口管理器 (DWM) 深度协同，减少画面撕裂与丢帧"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Key      = "sub-auto"
        Property = "智能同名字幕模糊匹配 (sub-auto = fuzzy)"
        Expected = "fuzzy"
        Purpose  = "自动加载同目录下名称相近的外挂字幕文件"
        Impact   = "自动识别并加载同目录下外挂字幕文件"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Key      = "sub-font"
        Property = "字幕字体渲染固化 (sub-font = `"Microsoft YaHei`")"
        Expected = 'Microsoft YaHei'
        Purpose  = "强制字幕文本采用系统内置微软雅黑字体渲染"
        Impact   = "避免汉字、标点与扩展字符缺字乱码"
        Type     = "Config"
    },
    @{
        Module   = "配置"
        Key      = "save-position-on-quit"
        Property = "退出时断点记忆 (save-position-on-quit = yes)"
        Expected = "yes"
        Purpose  = "记录视频退出时的播放时间戳至 watch_later 目录"
        Impact   = "下次重新打开该视频时自动从上次观看中断处无缝续播"
        Type     = "Config"
    }
)

# ==============================================================================
# 3. 独立流转分支：清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    Assert-AppStopped

    $appRoot = Join-Path $scoopRoot "apps\$ScoopApp"
    $record = Get-ScoopInstallRecord -CurrentDir $InstallDir
    $hasExe = Test-Path -LiteralPath $AppExe -PathType Leaf
    if ($record -and -not $hasExe) {
        throw "mpv Scoop 安装记录存在但核心执行文件缺失 (Broken 状态)；已阻断清理，请通过 Scoop 修复或排查。"
    }
    if (-not $record -and $hasExe) {
        throw "mpv 核心执行文件存在但 Scoop 安装记录缺失 (Conflict 状态)；已阻断清理，请检查安装渠道与实例。"
    }
    $isInstalled = ($null -ne $record) -and $hasExe

    if (-not (& $console -Task ConfirmUninstall -AppName $AppName -UserDataList $HighValueUserData -Yes:$Yes)) {
        return
    }

    Assert-AppStopped

    if ($isInstalled) {
        Write-Host "`n🧹 [清洁卸载] 正在调用 Scoop 退役 mpv 本体..." -ForegroundColor Yellow
        if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
            throw "未检测到 scoop 命令，无法执行本体卸载；请先就绪 Scoop 环境。"
        }

        $global:LASTEXITCODE = $null
        & scoop uninstall mpv
        $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw "Scoop 卸载 mpv 失败 (退出代码 $exitCode)；未清理声明残留与持久化数据。"
        }

        $afterRecord = Get-ScoopInstallRecord -CurrentDir $InstallDir
        $afterExe = Test-Path -LiteralPath $AppExe -PathType Leaf
        if ($afterRecord -or $afterExe) {
            throw "Scoop 卸载命令已执行，但 mpv 安装记录或核心执行文件仍存在；请检查 Scoop 状态。"
        }
        Write-Host "✔ mpv 本体已由 Scoop 安全卸载。" -ForegroundColor Green
    } else {
        Write-Host "`nℹ️  未检测到活动的 mpv Scoop 安装实例，跳过包管理器卸载。" -ForegroundColor Gray
    }

    # 终态核验后：定点清理声明的历史残留对象（快捷方式及历史自建关联）
    @(
        "HKCU:\Software\Classes\io.mpv.file",
        "HKLM:\SOFTWARE\Classes\io.mpv.file",
        "HKCU:\Software\Classes\Applications\mpv.exe",
        "HKLM:\SOFTWARE\Classes\Applications\mpv.exe",
        "HKLM:\SOFTWARE\Clients\Media\mpv"
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

    # 默认清洁卸载：受控配置与持久化目录随软件退役清理
    if (Test-Path -LiteralPath $PersistDir) {
        $persistItem = Get-Item -LiteralPath $PersistDir -Force -ErrorAction Stop
        if ($persistItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "mpv persist 目录为重解析点，拒绝递归删除: $PersistDir"
        }
        Remove-Item -LiteralPath $PersistDir -Recurse -Force -ErrorAction Stop
        Write-Host "   - [已清理] 声明的持久化配置与缓存数据: $PersistDir" -ForegroundColor Red
    }

    Write-Host "`n✅ [清洁卸载完成] mpv 本体已退役，声明残留已审计清理。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 部署路径: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $InstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$isInstalled = Test-Path $AppExe
$confRaw = Read-MpvConfig $ConfigFile
$isManagedBlockAligned = $confRaw -ceq (Get-MpvManagedConfigContent -existing $confRaw -Tag 'mpv-baseline' -NewContent $mpvBaseline)
Write-Host '  配置检查范围: 本文件默认作用域的受控标量；不解析 include、Profile 应用、命令行或运行期覆盖。' -ForegroundColor DarkGray

$Specs = foreach ($spec in $ManagedSpecs) {
    $actualStr = ""
    $isMatch = $false

    if ($spec.Type -eq "Binary") {
        $actualStr = if ($isInstalled) { "已安装于 Scoop 环境" } else { "未安装" }
        $isMatch = $isInstalled
    } elseif ($spec.Type -eq 'ManagedBlock') {
        $actualStr = if ($isManagedBlockAligned) { '末尾唯一 [default] 托管块' } else { '托管块缺失、位置或内容偏离' }
        $isMatch = $isManagedBlockAligned
    } elseif ($spec.Type -eq "Config") {
        $val = Get-MpvConfigValue $confRaw $spec.Key
        $actualStr = if ($null -eq $val) { "<缺省未设>" } else { "$val" }
        $isMatch = ($actualStr -ceq $spec.Expected)
    }

    [PSCustomObject]@{
        Module   = $spec.Module
        Property = $spec.Property
        Expected = $spec.Expected
        Actual   = $actualStr
        IsMatch  = $isMatch
        Purpose  = $spec.Purpose
        Impact   = $spec.Impact
        Type     = $spec.Type
    }
}

# 委派 _console.ps1 渲染差异矩阵
& $console -Task RenderDiff -Specs $Specs -Yes:$Yes

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发安全 (Gate)
# ==============================================================================

# 5.1 状态体检与合规性判定
$diffs = @($Specs | Where-Object { -not $_.IsMatch })

if ($Action -eq "Check") {
    if ($diffs.Count -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性均与工程基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $diffs.Count) -ForegroundColor Yellow
    }
    return
}

if ($diffs.Count -eq 0 -and $isInstalled) {
    Write-Host "✨ [状态合规] 所有受控属性均已符合工程基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# 5.2 运行态并发防覆写硬门禁
Assert-AppStopped

# 5.3 门禁授权放行
if (-not (& $console -Task ConfirmGate -Specs $diffs -Action $Action -Yes:$Yes -AppName $AppName)) {
    return
}

$needBinaryDeploy = (-not $isInstalled)

# ==============================================================================
# 6. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 6.1 程序本体安装或强制重装
Assert-AppStopped
if ($needBinaryDeploy) {
    if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
        throw "未检测到 scoop 命令，请先就绪 Scoop 包管理器环境。"
    }

    $beforeInstall = Get-ScoopInstallRecord -CurrentDir $InstallDir
    if ($beforeInstall -and $beforeInstall.Held) {
        throw "Scoop 应用 mpv 已 hold，未执行部署；如需更新，请先自行执行 scoop unhold mpv。"
    }
    Ensure-ScoopBucket $ScoopBucket
    $scoopArgs = if ($beforeInstall) { @('update', $ScoopApp, '--force') } else { @('install', "$ScoopBucket/$ScoopApp") }
    $global:LASTEXITCODE = $null
    & scoop @scoopArgs
    $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Scoop 部署 $ScoopApp 失败 (退出代码 $exitCode)，未继续写入配置。"
    }
    $afterInstall = Get-ScoopInstallRecord -CurrentDir $InstallDir
    if (-not $afterInstall -or ($beforeInstall -and $afterInstall.Path -eq $beforeInstall.Path -and
        $afterInstall.LastWriteTimeUtc -eq $beforeInstall.LastWriteTimeUtc)) {
        throw "Scoop 未生成或刷新 $ScoopApp 安装记录，无法确认部署完成；请检查 Scoop 的跳过或错误输出。"
    }
    $AppExe = Join-Path $InstallDir 'mpv.exe'
    $isInstalled = Test-Path -LiteralPath $AppExe -PathType Leaf
    if (-not $isInstalled) {
        throw "Scoop 安装完成，但未能定位到 $AppExe，请检查 Scoop 安装状态。"
    }
}

# 6.2 注入 mpv.conf 体验基线偏好
Assert-AppStopped
Write-Host "⚙️  正在对齐 mpv.conf 画质与体验基线..." -ForegroundColor Cyan
Update-ManagedConfigFile -FilePath $ConfigFile -Tag "mpv-baseline" -NewContent $mpvBaseline -Specs $ManagedSpecs
Write-Host "✅ mpv.conf 默认作用域的受控标量已写入并复验: $ConfigFile" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线与配置管理完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 默认渲染配置: gpu-next 与 auto-safe 受控值检查通过；实际渲染与其他配置来源待验证" -ForegroundColor Gray
Write-Host "   - 字体与字幕默认配置: Microsoft YaHei 与智能同名模糊匹配" -ForegroundColor Gray
Write-Host "   - 进度与截屏默认配置: 退出自动断点记忆与无损 PNG；运行态效果未验证" -ForegroundColor Gray

$isDefaultVideo = $false
try {
    $mp4Choice = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.mp4\UserChoice" -Name "ProgId" -ErrorAction SilentlyContinue).ProgId
    if ($mp4Choice -eq "io.mpv.file") { $isDefaultVideo = $true }
} catch { }

if (-not $isDefaultVideo) {
    Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData '如需默认使用 mpv，请在 Windows 设置 → 应用 → 默认应用中将其设为视频播放器。'
}

return
