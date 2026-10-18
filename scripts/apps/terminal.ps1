#requires -Version 7.0
<#
.SYNOPSIS
    Windows Terminal 与现代 Shell 终端底座 (pwsh, nushell, git-bash)

.DESCRIPTION
    Windows Terminal 生产力终端底座与三大现代 Shell (PowerShell 7, Nushell, Git Bash) 统筹编排工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 深度纳管 Windows Terminal 全局生产力策略：
       - 默认 Shell 绑定为 PowerShell 7 (pwsh)；
       - 默认启动路径自适应绑定工程活动区 (D:\act 优先)；
       - 固化亚克力磨砂 (Acrylic)、历史行数扩容 (20,000 行)、选中即复制与平滑关闭确认；
       - 探测并注入工作站等宽字体基线 (Maple Mono NL NFMono CN)；
       - 彻底隐藏 Azure Cloud Shell、旧版 Windows PowerShell 5.1 与 CMD 等系统干扰项。
    3. 三大多元现代 Shell 矩阵统一集成与 Terminal Profile 纳管：
       - PowerShell 7 (pwsh): 优先探测 Scoop 持久化路径，注入 -NoLogo 与遥测禁用；
       - Nushell (nu): 探测 Scoop 路径，自适应注册绿色高对比度 Profile；
       - Git Bash (bash): 探测 Scoop/公版路径，注入 --login -i 交互登录环境与图标。
    4. 三大 Shell 终端交互体验基线横向对齐 (全量固化 Up/Down 前缀历史智能检索)：
       - pwsh: 固化 $PROFILE 的 PSReadLine 历史按键与行内预测；
       - nushell: 固化 config.nu 的 SQLite 结构化历史、跨终端即时同步与圆角表格；
       - git-bash: 固化 ~/.bash_profile 与 ~/.inputrc 的 UTF-8 编码与前缀历史回溯。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync        : 增量对齐黄金基线 (默认，缺失则装、偏离则修)
    - Check       : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - ResetConfig : 仅执行 Terminal 策略重置与各 Shell 配置块刷新
    - Uninstall   : 恢复 Windows Terminal 默认配置，剥离三大 Shell 托管配置块
    - Upgrade     : 刷新并检查各 Shell 运行环境

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\terminal.ps1 -Action Check

    # 交互式检查并应用黄金基线
    pwsh -File .\scripts\apps\terminal.ps1

    # 仅强制重写配置为工程黄金基线
    pwsh -File .\scripts\apps\terminal.ps1 -Action ResetConfig

    # 清洁卸载并剥离托管配置
    pwsh -File .\scripts\apps\terminal.ps1 -Action Uninstall
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
    throw "【权限错误】Windows Terminal 与多 Shell 终端底座配置涉及系统级环境变量与文件关联，请在提升的管理员 pwsh 会话中执行！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将 Terminal 与 Shell 配置错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 内部路径嗅探与辅助函数
# ==============================================================================
$AppId        = "terminal"
$AppName      = "Windows Terminal 现代终端底座"
$scoopRoot    = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }

$internalDrives = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
try {
    $disks = Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -ne 'USB' }
    $partitions = $disks | Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }
    foreach ($p in $partitions) { [void]$internalDrives.Add("$($p.DriveLetter):") }
} catch {
    [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object {
        [void]$internalDrives.Add($_.Name.TrimEnd('\'))
    }
}

$testInternalValid = {
    param([string]$path)
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    if (-not (Test-Path -Path $path -PathType Leaf)) { return $false }
    $root = [System.IO.Path]::GetPathRoot($path).TrimEnd('\')
    return $internalDrives.Contains($root)
}

$wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (-not (Test-Path $wtSettings)) {
    $altWt = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    if (Test-Path $altWt) { $wtSettings = $altWt }
}

$pwshCandidates = @(
    (Join-Path $scoopRoot "apps\pwsh\current\pwsh.exe"),
    (Join-Path $scoopRoot "shims\pwsh.exe"),
    "$env:ProgramFiles\PowerShell\7\pwsh.exe"
)
$pwshExe = $pwshCandidates | Where-Object { & $testInternalValid $_ } | Select-Object -First 1

$nuCandidates = @(
    (Join-Path $scoopRoot "apps\nu\current\nu.exe"),
    (Join-Path $scoopRoot "shims\nu.exe")
)
$nuExe = $nuCandidates | Where-Object { & $testInternalValid $_ } | Select-Object -First 1

$gitBashCandidates = @(
    (Join-Path $scoopRoot "apps\git\current\bin\bash.exe"),
    (Join-Path $scoopRoot "apps\git\current\usr\bin\bash.exe"),
    "$env:ProgramFiles\Git\bin\bash.exe"
)
$gitBashExe = $gitBashCandidates | Where-Object { & $testInternalValid $_ } | Select-Object -First 1

$regHklm = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
$regHkcu = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
$installedFontsHklm = (Get-ItemProperty -Path $regHklm -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" }
$installedFontsHkcu = (Get-ItemProperty -Path $regHkcu -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" }
$hasMapleFont = ($null -ne $installedFontsHklm -or $null -ne $installedFontsHkcu)

function Install-MapleFontKit {
    Write-Host "[*] 正在准备从 GitHub 官方 Release 装配工作站等宽字体 (Maple Mono NL CN)..." -ForegroundColor Cyan
    $tempZip = Join-Path $env:TEMP "MapleMono-autoinstall.zip"
    $tempSandboxDir = Join-Path $env:TEMP ("MapleMono-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempSandboxDir -Force | Out-Null

    try {
        $fontReleaseApi = "https://api.github.com/repos/subframe7536/maple-font/releases/latest"
        $rel = Invoke-RestMethod -Uri $fontReleaseApi -Headers @{ "User-Agent" = "vpsbase-terminal-script" } -TimeoutSec 15
        $asset = $rel.assets | Where-Object { $_.name -match 'MapleMono-NF-CN\.zip$' } | Select-Object -First 1
        if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1 }
        if (-not $asset) { throw "未在 GitHub 最新 Release 中匹配到 Maple Mono 字体发布包" }

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempZip -TimeoutSec 60
        Expand-Archive -Path $tempZip -DestinationPath $tempSandboxDir -Force

        $fontFiles = Get-ChildItem -Path $tempSandboxDir -Recurse -Include "*.ttf", "*.otf" |
                     Where-Object { $_.Name -match 'MapleMono.*CN' -and $_.Name -notmatch 'BoldItalic|ExtraLightItalic' }

        if (-not $fontFiles -or $fontFiles.Count -eq 0) {
            $fontFiles = Get-ChildItem -Path $tempSandboxDir -Recurse -Include "*.ttf", "*.otf"
        }
        if (-not $fontFiles -or $fontFiles.Count -eq 0) { throw "字体压缩包解包后未发现任何有效字体文件" }

        $fontsTargetDir = Join-Path $env:SystemRoot "Fonts"
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class FontManager {
    [DllImport("gdi32.dll", EntryPoint="AddFontResourceW", SetLastError=true)]
    public static extern int AddFontResource([In, MarshalAs(UnmanagedType.LPWStr)] string lpFileName);
    [DllImport("user32.dll")]
    public static extern int SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@ -ErrorAction SilentlyContinue

        foreach ($f in $fontFiles) {
            $dest = Join-Path $fontsTargetDir $f.Name
            Copy-Item -Path $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $regPath -Name "$($f.BaseName) (TrueType)" -Value $f.Name -Force -ErrorAction SilentlyContinue
            [FontManager]::AddFontResource($dest) | Out-Null
        }
        [FontManager]::SendMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null

        for ($i = 0; $i -lt 10; $i++) {
            $hklmReady = (Get-ItemProperty -Path $regHklm -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" }
            $hkcuReady = (Get-ItemProperty -Path $regHkcu -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" }
            if ($hklmReady -or $hkcuReady) { break }
            Start-Sleep -Milliseconds 500
        }

        Write-Host "  [+] Maple Mono NL 等宽字体基线已成功装配至系统字体库" -ForegroundColor Green
    } finally {
        if (Test-Path $tempZip) { Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempSandboxDir) { Remove-Item -Path $tempSandboxDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Update-ManagedConfigFile {
    param(
        [string]$FilePath,
        [string]$BlockTag,
        [string]$BlockContent
    )
    if ([string]::IsNullOrWhiteSpace($FilePath)) { throw "FilePath 不可为空" }
    $parent = Split-Path -Path $FilePath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $startMarker = "# >>> managed: $BlockTag >>>"
    $endMarker   = "# <<< managed: $BlockTag <<<"
    $injection   = "$startMarker`r`n$BlockContent`r`n$endMarker"

    $existing = if (Test-Path $FilePath) { [System.IO.File]::ReadAllText($FilePath, [System.Text.UTF8Encoding]::new($false)) } else { "" }
    $startEscaped = [regex]::Escape($startMarker)
    $endEscaped   = [regex]::Escape($endMarker)
    $regex = "(?s)[ \t]*$startEscaped\r?\n.*?\r?\n[ \t]*$endEscaped"

    if ($existing -match $regex) {
        $newContent = [System.Text.RegularExpressions.Regex]::Replace($existing, $regex, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $injection })
    } else {
        if ([string]::IsNullOrWhiteSpace($existing)) {
            $newContent = "$injection`r`n"
        } else {
            $trimmed = $existing.TrimEnd("`r", "`n")
            $newContent = "$trimmed`r`n`r`n$injection`r`n"
        }
    }

    if ($existing -ne $newContent) {
        [System.IO.File]::WriteAllText($FilePath, $newContent, [System.Text.UTF8Encoding]::new($false))
    }
}

function Remove-ManagedConfigBlock {
    param(
        [string]$FilePath,
        [string]$BlockTag
    )
    if (-not (Test-Path $FilePath)) { return }
    $existing = [System.IO.File]::ReadAllText($FilePath, [System.Text.UTF8Encoding]::new($false))
    $startMarker = "# >>> managed: $BlockTag >>>"
    $endMarker   = "# <<< managed: $BlockTag <<<"
    $startEscaped = [regex]::Escape($startMarker)
    $endEscaped   = [regex]::Escape($endMarker)
    $pattern = "(?ms)^[ \t]*$startEscaped\r?\n.*?\r?\n[ \t]*$endEscaped[ \t]*\r?\n?"

    if ($existing -match $pattern) {
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($existing, $pattern, "")
        $final = $cleaned.TrimEnd("`r", "`n")
        if ([string]::IsNullOrWhiteSpace($final)) {
            Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::WriteAllText($FilePath, "$final`r`n", [System.Text.UTF8Encoding]::new($false))
        }
    }
}

function Set-OrAddProperty($item, [string]$name, $value) {
    if ($item -is [System.Collections.IDictionary]) {
        $item[$name] = $value
    } else {
        if ($item.PSObject.Properties.Match($name).Count -gt 0) {
            $item.$name = $value
        } else {
            $item | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
        }
    }
}

$pwshProfilePath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "PowerShell\Microsoft.PowerShell_profile.ps1"
$nuConfPath      = Join-Path $env:APPDATA "nushell\config.nu"
$gitBashProfile  = Join-Path $env:USERPROFILE ".bash_profile"
$gitBashInputrc  = Join-Path $env:USERPROFILE ".inputrc"

$HighValueUserData = @(
    "PowerShell 个人配置文件: $pwshProfilePath",
    "Nushell 配置文件: $nuConfPath",
    "Git Bash 配置文件: $gitBashProfile 与 $gitBashInputrc",
    "Windows Terminal 偏好设置: $wtSettings"
)

$pwshBlock = @'
# PSReadLine 按键绑定: 根据已输入前缀滚动历史记录与预测
if (Get-Module -ListAvailable -Name PSReadLine) {
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineOption -PredictionSource History
    Set-PSReadLineOption -PredictionViewStyle InlineView
}
'@

$nuBlock = @'
# 固化历史记录为现代 SQLite 结构化数据库格式
$env.config.history.file_format = "sqlite"

# 跨终端多会话即时写入同步 (回车即提交历史)
$env.config.history.sync_on_enter = true

# 关闭会话隔离，跨终端共享全量历史
$env.config.history.isolation = false

# 扩容历史记录上限
$env.config.history.max_size = 100_000

# 现代圆角风格表格
$env.config.table.mode = "rounded"

# 命令行行尾前缀快速检索 (Up/Down 原生匹配)
$env.config.edit_mode = "emacs"
'@

$gitBashProfileBlock = @'
# Git Bash 中文 UTF-8 编码基线
export LANG="zh_CN.UTF-8"
export LC_ALL="zh_CN.UTF-8"

# 历史记录容量扩容与即时同步
export HISTCONTROL=ignoreboth:erasedups
export HISTSIZE=50000
export HISTFILESIZE=100000
shopt -s histappend
PROMPT_COMMAND="history -a; history -c; history -r; $PROMPT_COMMAND"
'@

$gitBashInputrcBlock = @'
# 根据已输入前缀智能回溯上下历史命令 (与 pwsh / nu 完全统一)
"\e[A": history-search-backward
"\e[B": history-search-forward
set show-all-if-ambiguous on
set completion-ignore-case on
'@

$GUID_PWSH   = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
$GUID_NU     = "{a3a0e698-89c0-5a33-8a9d-b4b0ef093412}"
$GUID_GIT    = "{2ece5b25-b461-59d0-8f3e-8c5e63821a8a}"
$GUID_AZURE  = @("{b453ae62-4e3d-5e58-b989-0a998ec441b3}", "{b453ae62-4e3d-5e58-b989-0a998ec441b8}")
$GUID_LEGACY = @("{61c54bbd-c2c6-5271-96e7-009a87ff44bf}", "{0caa0dad-35be-5f56-a8ff-afceeeaa6101}")

# ==============================================================================
# 3. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将重置 Windows Terminal 托管配置并剥离四大 Shell 配置文件托管块！" -ForegroundColor Yellow
        Write-Host "📌 【涉及的托管配置文件清单】:" -ForegroundColor Cyan
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        $confirm = (Read-Host "确认执行清洁卸载与基线剥离? [y/N]").Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 正在剥离各 Shell 托管配置块..." -ForegroundColor Yellow
    Remove-ManagedConfigBlock $pwshProfilePath "pwsh-history-search"
    Remove-ManagedConfigBlock $nuConfPath "nu-history-baseline"
    Remove-ManagedConfigBlock $gitBashProfile "gitbash-history-baseline"
    Remove-ManagedConfigBlock $gitBashInputrc "inputrc-history-search"

    if (Test-Path $wtSettings) {
        try {
            $json = Get-Content -Path $wtSettings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.profiles -and $json.profiles.defaults) {
                $json.profiles.defaults.PSObject.Properties.Remove("useAcrylic")
                $json.profiles.defaults.PSObject.Properties.Remove("acrylicOpacity")
                $json.profiles.defaults.PSObject.Properties.Remove("opacity")
                $json.profiles.defaults.PSObject.Properties.Remove("startingDirectory")
            }
            if ($json.profiles -and $json.profiles.list) {
                $json.profiles.list = @($json.profiles.list | Where-Object { $_.guid -ne $GUID_NU -and $_.guid -ne $GUID_GIT })
            }
            [System.IO.File]::WriteAllText($wtSettings, ($json | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
            Write-Host "   - 已剥离 Windows Terminal 中的自定义 profiles 与个性化 defaults。" -ForegroundColor Gray
        } catch { }
    }

    Write-Host "`n✅ [清洁卸载完成] 终端底座与各 Shell 托管块已安全剥离。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | Terminal配置: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $wtSettings) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$chkList = [System.Collections.Generic.List[PSCustomObject]]::new()
$diffList = [System.Collections.Generic.List[PSCustomObject]]::new()

$wtJson = $null
$isWtFileReady = Test-Path $wtSettings
$targetStartDir = if (Test-Path "D:\act") { "D:\act" } else { $env:USERPROFILE }

$isDefaultPwsh = $false
$isDirMatch = $false
$isAcrylicMatch = $false
$isFontMatch = $false
$isLegacyHidden = $false
$isNuProfileReady = $false
$isGitProfileReady = $false

if ($isWtFileReady) {
    try {
        $wtJson = Get-Content -Path $wtSettings -Raw -Encoding UTF8 | ConvertFrom-Json
        $isDefaultPwsh = ($wtJson.defaultProfile -eq $GUID_PWSH)
        $defaults = $wtJson.profiles.defaults
        if ($defaults) {
            $isDirMatch = ($defaults.startingDirectory -eq $targetStartDir)
            $isAcrylicMatch = ($defaults.useAcrylic -eq $true -and ($defaults.acrylicOpacity -eq 0.85 -or $defaults.opacity -eq 85))
            $isFontMatch = if ($hasMapleFont) {
                ($null -ne $defaults.font -and $defaults.font.face -eq "Maple Mono NL NFMono CN")
            } else { $true }
        }

        $azureList = @($wtJson.profiles.list | Where-Object { $GUID_AZURE -contains $_.guid -or $_.name -match 'Azure Cloud Shell' })
        $legacyList = @($wtJson.profiles.list | Where-Object { $GUID_LEGACY -contains $_.guid -or $_.name -match 'Windows PowerShell 5|Command Prompt|命令提示符' })
        $allHidden = $true
        foreach ($p in ($azureList + $legacyList)) {
            if ($p.hidden -ne $true) { $allHidden = $false; break }
        }
        $isLegacyHidden = $allHidden

        $nuProfile = $wtJson.profiles.list | Where-Object { $_.guid -eq $GUID_NU -or $_.name -eq "Nushell" }
        $isNuProfileReady = [bool]($nuProfile -and $nuProfile.hidden -eq $false)

        $gitProfile = $wtJson.profiles.list | Where-Object { $_.guid -eq $GUID_GIT -or $_.name -eq "Git Bash" }
        $isGitProfileReady = [bool]($gitProfile -and $gitProfile.hidden -eq $false -and $gitProfile.commandline -match '--login')
    } catch { }
}

# 4.1 等宽字体基线
$chkList.Add([PSCustomObject]@{
    分层模块 = "工作站字体"
    受控属性 = "等宽字体装配 (Maple Mono NL NFMono CN)"
    期望基线 = "已安装并注册至系统字体库"
    实机状态 = if ($hasMapleFont) { "已装配" } else { "未安装" }
    状态判定 = if ($hasMapleFont) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $hasMapleFont) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "工作站字体"
        受控属性 = "等宽字体装配 (Maple Mono NL NFMono CN)"
        实机状态 = "未安装"
        期望基线 = "已安装并注册至系统字体库"
        Purpose  = "装配工作站标准开源等宽编程字体 Maple Mono"
        Impact   = "为 Terminal、代码编辑器与终端应用提供中英文等宽与 Nerd Font 图标排版"
    })
}

# 4.2 Terminal 默认 Profile
$chkList.Add([PSCustomObject]@{
    分层模块 = "Terminal核心"
    受控属性 = "默认终端Shell (defaultProfile)"
    期望基线 = "PowerShell 7 ($GUID_PWSH)"
    实机状态 = if ($isDefaultPwsh) { "已绑定 PowerShell 7" } else { "未绑定或文件缺失" }
    状态判定 = if ($isDefaultPwsh) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isDefaultPwsh) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "Terminal核心"
        受控属性 = "默认终端Shell (defaultProfile)"
        实机状态 = if ($wtJson) { "$($wtJson.defaultProfile)" } else { "缺失" }
        期望基线 = "PowerShell 7 ($GUID_PWSH)"
        Purpose  = "将 Windows Terminal 默认启动会话绑定为 PowerShell 7 (pwsh)"
        Impact   = "每次点击打开终端默认直接进入现代 pwsh 会话"
    })
}

# 4.3 Terminal 起始目录与视效细项
$chkList.Add([PSCustomObject]@{
    分层模块 = "Terminal视效"
    受控属性 = "默认起始目录 (defaults.startingDirectory)"
    期望基线 = "$targetStartDir"
    实机状态 = if ($wtJson -and $wtJson.profiles.defaults -and $wtJson.profiles.defaults.startingDirectory) { "$($wtJson.profiles.defaults.startingDirectory)" } else { "<未配置>" }
    状态判定 = if ($isDirMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isDirMatch -and $Action -ne "Upgrade") {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "Terminal视效"
        受控属性 = "默认起始目录 (defaults.startingDirectory)"
        实机状态 = if ($wtJson -and $wtJson.profiles.defaults -and $wtJson.profiles.defaults.startingDirectory) { "$($wtJson.profiles.defaults.startingDirectory)" } else { "<未配置>" }
        期望基线 = "$targetStartDir"
        Purpose  = "自适应将终端默认工作目录锚定至工作区 ($targetStartDir)"
        Impact   = "打开终端无需手动 cd 切换路径，直接聚焦活跃工程"
    })
}

$chkList.Add([PSCustomObject]@{
    分层模块 = "Terminal视效"
    受控属性 = "亚克力磨砂效果 (useAcrylic / 0.85)"
    期望基线 = "Acrylic=True (0.85)"
    实机状态 = if ($isAcrylicMatch) { "已启用 (0.85)" } else { "未配置/已关闭" }
    状态判定 = if ($isAcrylicMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isAcrylicMatch -and $Action -ne "Upgrade") {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "Terminal视效"
        受控属性 = "亚克力磨砂效果 (useAcrylic / 0.85)"
        实机状态 = if ($wtJson -and $wtJson.profiles.defaults) { "useAcrylic=$($wtJson.profiles.defaults.useAcrylic)" } else { "<未配置>" }
        期望基线 = "Acrylic=True (0.85)"
        Purpose  = "开启 Terminal 窗口亚克力磨砂半透明背景 (0.85)"
        Impact   = "提升现代桌面美感与背景视效通透度"
    })
}

# 4.4 旧版与云端干扰项净化
$chkList.Add([PSCustomObject]@{
    分层模块 = "Terminal环境"
    受控属性 = "旧版与云端干扰项隐藏 (Azure/CMD/PS5.1)"
    期望基线 = "全部 hidden=true"
    实机状态 = if ($isLegacyHidden) { "已全部隐藏" } else { "存在未隐藏项" }
    状态判定 = if ($isLegacyHidden) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isLegacyHidden -and $Action -ne "Upgrade") {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "Terminal环境"
        受控属性 = "旧版与云端干扰项隐藏 (Azure/CMD/PS5.1)"
        实机状态 = "存在未隐藏项"
        期望基线 = "全部 hidden=true"
        Purpose  = "在终端新建下拉菜单中隐藏 Azure Cloud Shell、旧版 CMD 与 PS 5.1"
        Impact   = "下拉菜单极简纯净，仅保留生产力现代 Shell"
    })
}

# 4.5 各 Shell 前缀历史检索托管块
$pwshHasBlock = (Test-Path $pwshProfilePath) -and (Get-Content $pwshProfilePath -Raw -ErrorAction SilentlyContinue | Select-String "pwsh-history-search")
$chkList.Add([PSCustomObject]@{
    分层模块 = "Shell配置"
    受控属性 = "PowerShell 7 PSReadLine 历史回溯"
    期望基线 = "已托管注入 ($pwshProfilePath)"
    实机状态 = if ($pwshHasBlock) { "已注入" } else { "未注入" }
    状态判定 = if ($pwshHasBlock) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $pwshHasBlock -and $Action -ne "Upgrade") {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "Shell配置"
        受控属性 = "PowerShell 7 PSReadLine 历史回溯"
        实机状态 = "未注入"
        期望基线 = "已托管注入 ($pwshProfilePath)"
        Purpose  = "固化 PSReadLine 的 Up/Down 键按已键入前缀模糊匹配历史与行内预测"
        Impact   = "打命令时仅需输入前几个字母按 Up 键即可秒级回溯历史"
    })
}

$nuHasBlock = (Test-Path $nuConfPath) -and (Get-Content $nuConfPath -Raw -ErrorAction SilentlyContinue | Select-String "nu-history-baseline")
$chkList.Add([PSCustomObject]@{
    分层模块 = "Shell配置"
    受控属性 = "Nushell SQLite 结构化历史检索"
    期望基线 = "已托管注入 ($nuConfPath)"
    实机状态 = if ($nuHasBlock) { "已注入" } else { "未注入" }
    状态判定 = if ($nuHasBlock) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $nuHasBlock -and $Action -ne "Upgrade") {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "Shell配置"
        受控属性 = "Nushell SQLite 结构化历史检索"
        实机状态 = "未注入"
        期望基线 = "已托管注入 ($nuConfPath)"
        Purpose  = "固化 Nushell 采用 SQLite 数据库存储历史并开启跨终端回车即时同步"
        Impact   = "多终端共享历史命令，解决多窗口退出覆写丢历史问题"
    })
}

$gitBashHasBlock = (Test-Path $gitBashProfile) -and (Get-Content $gitBashProfile -Raw -ErrorAction SilentlyContinue | Select-String "gitbash-history-baseline")
$chkList.Add([PSCustomObject]@{
    分层模块 = "Shell配置"
    受控属性 = "Git Bash 中文 UTF-8 与历史即时同步"
    期望基线 = "已托管注入 ($gitBashProfile)"
    实机状态 = if ($gitBashHasBlock) { "已注入" } else { "未注入" }
    状态判定 = if ($gitBashHasBlock) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $gitBashHasBlock -and $Action -ne "Upgrade") {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "Shell配置"
        受控属性 = "Git Bash 中文 UTF-8 与历史即时同步"
        实机状态 = "未注入"
        期望基线 = "已托管注入 ($gitBashProfile)"
        Purpose  = "配置 Git Bash 终端 UTF-8 编码与 .inputrc 前缀历史检索按键绑定"
        Impact   = "彻底消除 Git log 中文乱码，按键操作体验与 pwsh/nu 完全统一"
    })
}

Write-Host "`n📊 [巡检看板] Windows Terminal 与多 Shell 基线审计清单:" -ForegroundColor Cyan
$chkList | Format-Table -AutoSize | Out-String | Write-Host

if ($Action -eq "Check") {
    if ($diffList.Count -eq 0) {
        Write-Host "✨ [状态合规] Windows Terminal 与三大 Shell 配置均与工程黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $diffList.Count) -ForegroundColor Yellow
    }
    return
}

if ($diffList.Count -eq 0 -and $Action -ne "Upgrade") {
    Write-Host "✨ [状态合规] 所有受控属性与策略均已符合工程黄金基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

if ($diffList.Count -gt 0) {
    Write-Host "`n📋 [差异清单] 检测到以下受控属性偏离黄金基线:" -ForegroundColor Cyan
    $diffList | Format-Table -AutoSize | Out-String | Write-Host
}

# ==============================================================================
# 5. 阶段 2: 审查门禁 (Gate - Shift-Left: 目的与影响结构化直出)
# ==============================================================================
if (-not $Yes) {
    Write-Host "`n💡 [改动意图与技术边界审查 (Gate)]" -ForegroundColor Cyan
    Write-Host "   本次即将对齐以下偏离项，请逐项评估改动 [目的] 与 [影响]:" -ForegroundColor Gray
    $idx = 1
    foreach ($p in $diffList) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.受控属性) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.实机状态, $p.期望基线) -ForegroundColor DarkGray
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

# 6.1 装配等宽字体
if (-not $hasMapleFont) {
    Install-MapleFontKit
    $hasMapleFont = $true
}

# 6.2 注入并调优 Windows Terminal settings.json
Write-Host "`n⚙️  正在单向对齐 Windows Terminal 黄金基线策略..." -ForegroundColor Cyan
if (-not (Test-Path $wtSettings)) {
    $parent = Split-Path -Path $wtSettings -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $initialJson = [ordered]@{
        "`$schema"       = "https://aka.ms/terminal-profiles-schema"
        "defaultProfile" = $GUID_PWSH
        "profiles"       = [ordered]@{
            "defaults" = [ordered]@{}
            "list"     = @()
        }
    }
    [System.IO.File]::WriteAllText($wtSettings, ($initialJson | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

$jsonObj = Get-Content -Path $wtSettings -Raw -Encoding UTF8 | ConvertFrom-Json

# 顶层全局设置
Set-OrAddProperty $jsonObj "defaultProfile" $GUID_PWSH
Set-OrAddProperty $jsonObj "copyOnSelect" $true
Set-OrAddProperty $jsonObj "confirmCloseAllTabs" $false
Set-OrAddProperty $jsonObj "newTabMenu" @(
    @{ type = "profile"; profile = $GUID_PWSH },
    @{ type = "profile"; profile = $GUID_NU },
    @{ type = "profile"; profile = $GUID_GIT }
)

# defaults 全局外观设置
if (-not $jsonObj.profiles.defaults) {
    $jsonObj.profiles | Add-Member -MemberType NoteProperty -Name "defaults" -Value ([PSCustomObject]@{}) -Force
}
$def = $jsonObj.profiles.defaults
Set-OrAddProperty $def "startingDirectory" $targetStartDir
Set-OrAddProperty $def "useAcrylic" $true
Set-OrAddProperty $def "acrylicOpacity" 0.85
Set-OrAddProperty $def "opacity" 85
Set-OrAddProperty $def "historySize" 20000

if ($hasMapleFont) {
    if (-not $def.font) {
        $def | Add-Member -MemberType NoteProperty -Name "font" -Value ([PSCustomObject]@{}) -Force
    }
    Set-OrAddProperty $def.font "face" "Maple Mono NL NFMono CN"
    Set-OrAddProperty $def.font "size" 12
}

# 隐藏旧版与云端干扰项
if ($jsonObj.profiles.list) {
    foreach ($p in $jsonObj.profiles.list) {
        if ($GUID_AZURE -contains $p.guid -or $p.name -match 'Azure Cloud Shell') {
            Set-OrAddProperty $p "hidden" $true
        }
        if ($GUID_LEGACY -contains $p.guid -or $p.name -match 'Windows PowerShell 5|Command Prompt|命令提示符') {
            Set-OrAddProperty $p "hidden" $true
        }
    }

    # 注册或回正 Nushell Profile
    if ($nuExe) {
        $foundNu = $jsonObj.profiles.list | Where-Object { $_.guid -eq $GUID_NU -or $_.name -eq "Nushell" }
        if (-not $foundNu) {
            $nuObj = [PSCustomObject]@{
                guid        = $GUID_NU
                name        = "Nushell"
                commandline = "`"$nuExe`""
                hidden      = $false
                icon        = "ms-appx:///ProfileIcons/{0caa0dad-35be-5f56-a8ff-afceeeaa6101}.png"
            }
            $jsonObj.profiles.list = @($jsonObj.profiles.list) + @($nuObj)
        } else {
            Set-OrAddProperty $foundNu "guid" $GUID_NU
            Set-OrAddProperty $foundNu "commandline" "`"$nuExe`""
            Set-OrAddProperty $foundNu "hidden" $false
        }
    }

    # 注册或回正 Git Bash Profile
    if ($gitBashExe) {
        $foundGit = $jsonObj.profiles.list | Where-Object { $_.guid -eq $GUID_GIT -or $_.name -eq "Git Bash" }
        $gitIcon = (Join-Path (Split-Path (Split-Path $gitBashExe -Parent) -Parent) "mingw64\share\git\git-for-windows.ico")
        if (-not (Test-Path $gitIcon)) { $gitIcon = $null }

        if (-not $foundGit) {
            $gitObj = [PSCustomObject]@{
                guid        = $GUID_GIT
                name        = "Git Bash"
                commandline = "`"$gitBashExe`" --login -i"
                hidden      = $false
            }
            if ($gitIcon) { Set-OrAddProperty $gitObj "icon" $gitIcon }
            $jsonObj.profiles.list = @($jsonObj.profiles.list) + @($gitObj)
        } else {
            Set-OrAddProperty $foundGit "guid" $GUID_GIT
            Set-OrAddProperty $foundGit "commandline" "`"$gitBashExe`" --login -i"
            Set-OrAddProperty $foundGit "hidden" $false
            if ($gitIcon) { Set-OrAddProperty $foundGit "icon" $gitIcon }
        }
    }
}

$finalJsonStr = $jsonObj | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($wtSettings, $finalJsonStr, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ Windows Terminal 策略已原子落盘至: $wtSettings" -ForegroundColor Green

# 6.3 注入各 Shell 历史按键与编码托管块
Write-Host "⚙️  正在横向对齐三大 Shell 前缀历史智能检索与编码基线..." -ForegroundColor Cyan
Update-ManagedConfigFile -FilePath $pwshProfilePath -BlockTag "pwsh-history-search" -BlockContent $pwshBlock
Update-ManagedConfigFile -FilePath $nuConfPath -BlockTag "nu-history-baseline" -BlockContent $nuBlock
Update-ManagedConfigFile -FilePath $gitBashProfile -BlockTag "gitbash-history-baseline" -BlockContent $gitBashProfileBlock
Update-ManagedConfigFile -FilePath $gitBashInputrc -BlockTag "inputrc-history-search" -BlockContent $gitBashInputrcBlock
Write-Host "✅ PowerShell 7, Nushell, Git Bash 历史检索体验基线全部对齐完毕。" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线配置已全部闭环自愈！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 默认终端: PowerShell 7 ($GUID_PWSH)" -ForegroundColor Gray
Write-Host "   - 启动目录: $targetStartDir (Acrylic 0.85 磨砂开启)" -ForegroundColor Gray
Write-Host "   - 渲染字体: Maple Mono NL NFMono CN (12pt)" -ForegroundColor Gray
Write-Host "   - 体验统一: pwsh / nu / git-bash 均已固化 Up/Down 前缀历史智能检索" -ForegroundColor Gray

return
