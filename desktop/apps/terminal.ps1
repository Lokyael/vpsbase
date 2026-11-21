#requires -Version 7.0
<#
.SYNOPSIS
    Windows Terminal 与现代 PowerShell 7 终端底座

.DESCRIPTION
    Windows Terminal 生产力终端底座与现代 PowerShell 7 (pwsh) 统筹编排工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 深度纳管 Windows Terminal 全局生产力策略：
       - 默认 Shell 绑定为 PowerShell 7 (pwsh) 为唯一受控现代 Shell；
       - 默认启动路径自适应绑定工程活动区 (D:\act 优先)；
       - 固化亚克力磨砂 (Acrylic)、历史行数扩容 (20,000 行)、选中即复制与平滑关闭确认；
       - 探测并注入工作站等宽字体基线 (Maple Mono NL NFMono CN)；
       - 隐藏 Azure Cloud Shell、旧版 Windows PowerShell 5.1 与 CMD 等系统干扰项。
    3. PowerShell 7 统一集成与 Terminal Profile 纳管：
       - PowerShell 7 (pwsh): 优先探测 Scoop 持久化路径，注入 -NoLogo 与遥测禁用；
       - 菜单 newTabMenu 纯化收敛为唯一默认生产力终端。
    4. 终端交互体验基线对齐：
       - pwsh: 固化 $PROFILE 的 PSReadLine 历史按键与行内预测。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (只读比对受控属性 Diff)
    - Uninstall : 恢复 Windows Terminal 默认配置，剥离托管配置块

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制重新装配等宽字体并全量覆写终端与 PowerShell 7 配置块。

.PARAMETER Purge
    预留参数契约 (终端配置剥离后无用户独立数据目录)。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\desktop\apps\terminal.ps1 -Action Check

    # 交互式检查并应用工程基线
    pwsh -File .\desktop\apps\terminal.ps1

    # 强制重新覆写并对齐基线
    pwsh -File .\desktop\apps\terminal.ps1 -Force

    # 清洁卸载并剥离托管配置
    pwsh -File .\desktop\apps\terminal.ps1 -Action Uninstall
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
    throw "【权限错误】Windows Terminal 终端底座配置涉及系统级环境变量与文件关联，请在提升的管理员 pwsh 会话中执行！"
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

$regHklm = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
$regHkcu = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"

$testFontInstalled = {
    $fontFile = Join-Path $env:SystemRoot "Fonts\MapleMonoNL-NFMono-CN-Regular.ttf"
    if (Test-Path $fontFile) { return $true }
    $hklm = Get-ItemProperty -Path $regHklm -ErrorAction SilentlyContinue
    if ($hklm) {
        $found = $hklm.PSObject.Properties | Where-Object {
            ($_.Name -like "*Maple*Mono*NL*" -or $_.Name -like "*MapleMonoNL*") -and $_.Name -like "*CN*"
        }
        if ($found) { return $true }
    }
    return $false
}
$hasMapleFont = (& $testFontInstalled)

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

function Install-MapleFontKit {
    Write-Host "[*] 正在从 assets 资产分支拉取工作站等宽字体预编译包 (Maple Mono NL NFMono CN)..." -ForegroundColor Cyan
    $tempZip = Join-Path $env:TEMP "MapleMonoNL-autoinstall.zip"
    $tempSandboxDir = Join-Path $env:TEMP ("MapleMonoNL-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempSandboxDir -Force | Out-Null

    try {
        # 工作站等宽字体定制编译产物 (托管于 assets 独立分支)
        $fontZipUrl = "https://raw.githubusercontent.com/Lokyael/vpsbase/assets/latest-maple-mono-nl.zip"
        Invoke-DownloadFile -Url $fontZipUrl -OutFile $tempZip -Description "Maple Mono NL 等宽字体包" -TimeoutSec 300
        Write-Host "   - 正在解包字体压缩包并筛选工作站等宽字体 (NL NFMono CN)..." -ForegroundColor Gray
        Expand-Archive -Path $tempZip -DestinationPath $tempSandboxDir -Force

        $fontFiles = Get-ChildItem -Path $tempSandboxDir -Recurse -Include "*.ttf", "*.otf" |
                     Where-Object { $_.Name -like "*MapleMonoNL*CN*.ttf" }

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
    [DllImport("gdi32.dll", EntryPoint="RemoveFontResourceW", SetLastError=true)]
    public static extern int RemoveFontResource([In, MarshalAs(UnmanagedType.LPWStr)] string lpFileName);
    [DllImport("user32.dll")]
    public static extern int SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@ -ErrorAction SilentlyContinue

        # 规范字体注册表 Typography 全名映射
        $faceDisplayNames = @{
            "Regular"    = "Maple Mono NL NFMono CN (TrueType)"
            "Bold"       = "Maple Mono NL NFMono CN Bold (TrueType)"
            "Italic"     = "Maple Mono NL NFMono CN Italic (TrueType)"
            "BoldItalic" = "Maple Mono NL NFMono CN Bold Italic (TrueType)"
        }

        foreach ($f in $fontFiles) {
            $dest = Join-Path $fontsTargetDir $f.Name
            Copy-Item -Path $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue

            $styleKey = "Regular"
            if ($f.BaseName -match "BoldItalic$") { $styleKey = "BoldItalic" }
            elseif ($f.BaseName -match "Bold$") { $styleKey = "Bold" }
            elseif ($f.BaseName -match "Italic$") { $styleKey = "Italic" }

            $regName = if ($faceDisplayNames.ContainsKey($styleKey)) { $faceDisplayNames[$styleKey] } else { "$($f.BaseName) (TrueType)" }
            Set-ItemProperty -Path $regPath -Name $regName -Value $f.Name -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $regPath -Name "$($f.BaseName) (TrueType)" -Value $f.Name -Force -ErrorAction SilentlyContinue
            [FontManager]::AddFontResource($dest) | Out-Null
        }
        [FontManager]::SendMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null

        for ($i = 0; $i -lt 10; $i++) {
            if (& $testFontInstalled) { break }
            Start-Sleep -Milliseconds 500
        }

        Write-Host "  [+] Maple Mono NL NFMono CN 等宽字体基线已成功装配至系统字体库" -ForegroundColor Green
        Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData '若 Windows Terminal 处于打开状态，请保存终端工作并自行退出、重新打开，使 DirectWrite 加载新字体。'
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

function Get-TerminalShellProfiles {
    param([string]$PwshPath)
    if ([string]::IsNullOrWhiteSpace($PwshPath)) {
        throw "未定位到内置磁盘上的 PowerShell 7，无法配置默认 Shell；未写入终端配置或安装字体。"
    }
    return ,@(
        [PSCustomObject]@{
            guid = $GUID_PWSH; name = "PowerShell 7"; commandline = "`"$PwshPath`" -NoLogo"
            hidden = $false; icon = "ms-appx:///ProfileIcons/$GUID_PWSH.png"
        }
    )
}

function Test-TerminalShellProfile {
    param([object[]]$Profiles, $Expected)
    $matches = @($Profiles | Where-Object { $_.guid -eq $Expected.guid })
    return ($matches.Count -eq 1 -and $matches[0].hidden -eq $false -and
        $matches[0].commandline -ceq $Expected.commandline)
}

function Test-TerminalShellMenu {
    param([object[]]$Menu, [object[]]$ExpectedProfiles)
    if ($Menu.Count -ne $ExpectedProfiles.Count) { return $false }
    for ($i = 0; $i -lt $ExpectedProfiles.Count; $i++) {
        if ($Menu[$i].type -ne 'profile' -or $Menu[$i].profile -ne $ExpectedProfiles[$i].guid) { return $false }
    }
    return $true
}

function Sync-TerminalShellProfiles {
    param($Settings, [object[]]$ExpectedProfiles)
    if ($Settings -isnot [System.Management.Automation.PSCustomObject] -or
        ($null -ne $Settings.profiles -and $Settings.profiles -isnot [System.Management.Automation.PSCustomObject])) {
        throw "Terminal 配置根节点及 profiles 必须为对象。"
    }
    if ($null -ne $Settings.profiles.list -and $Settings.profiles.list -isnot [array]) {
        throw "Terminal profiles.list 必须为数组。"
    }
    foreach ($expected in $ExpectedProfiles) {
        if (@($Settings.profiles.list | Where-Object { $_.guid -eq $expected.guid }).Count -gt 1) {
            throw "Terminal 受控 Profile GUID 重复: $($expected.guid)，未写入配置。"
        }
    }
    if ($null -eq $Settings.profiles) { Set-OrAddProperty $Settings 'profiles' ([PSCustomObject]@{}) }
    if ($null -eq $Settings.profiles.list) { Set-OrAddProperty $Settings.profiles 'list' @() }
    foreach ($expected in $ExpectedProfiles) {
        $profile = $Settings.profiles.list | Where-Object { $_.guid -eq $expected.guid }
        if ($null -eq $profile) {
            $Settings.profiles.list = @($Settings.profiles.list) + @($expected.PSObject.Copy())
        } else {
            Set-OrAddProperty $profile 'commandline' $expected.commandline
            Set-OrAddProperty $profile 'hidden' $false
            if (-not $profile.icon) { Set-OrAddProperty $profile 'icon' $expected.icon }
        }
    }
    Set-OrAddProperty $Settings 'defaultProfile' $GUID_PWSH
    Set-OrAddProperty $Settings 'newTabMenu' @($ExpectedProfiles | ForEach-Object {
        [PSCustomObject]@{ type = 'profile'; profile = $_.guid }
    })
}

$pwshProfilePath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "PowerShell\Microsoft.PowerShell_profile.ps1"

$HighValueUserData = @(
    "PowerShell 个人配置文件: $pwshProfilePath",
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

$GUID_PWSH   = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
$GUID_AZURE  = @("{b453ae62-4e3d-5e58-b989-0a998ec441b3}", "{b453ae62-4e3d-5e58-b989-0a998ec441b8}")
$GUID_LEGACY = @("{61c54bbd-c2c6-5271-96e7-009a87ff44bf}", "{0caa0dad-35be-5f56-a8ff-afceeeaa6101}")

# ==============================================================================
# 3. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将重置 Windows Terminal 托管配置并剥离 PowerShell 7 配置文件托管块！" -ForegroundColor Yellow
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

    Write-Host "`n🧹 正在剥离受控托管配置块..." -ForegroundColor Yellow
    Remove-ManagedConfigBlock $pwshProfilePath "pwsh-history-search"

    if (Test-Path $wtSettings) {
        try {
            $json = Get-Content -Path $wtSettings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.profiles -and $json.profiles.defaults) {
                $json.profiles.defaults.PSObject.Properties.Remove("useAcrylic")
                $json.profiles.defaults.PSObject.Properties.Remove("acrylicOpacity")
                $json.profiles.defaults.PSObject.Properties.Remove("opacity")
                $json.profiles.defaults.PSObject.Properties.Remove("startingDirectory")
            }
            if ($json.defaultProfile -eq $GUID_PWSH) {
                $json.PSObject.Properties.Remove("defaultProfile")
            }
            [System.IO.File]::WriteAllText($wtSettings, ($json | ConvertTo-Json -Depth 100 -WarningAction Stop -ErrorAction Stop), [System.Text.UTF8Encoding]::new($false))
            Write-Host "   - 已剥离 Windows Terminal 中的受控默认项与个性化 defaults。" -ForegroundColor Gray
        } catch { }
    }

    Write-Host "`n✅ [清洁卸载完成] 终端底座与受控托管块已安全剥离。`n" -ForegroundColor Green
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

$expectedShellProfiles = Get-TerminalShellProfiles -PwshPath $pwshExe

$wtJson = $null
$isWtFileReady = Test-Path $wtSettings
$targetStartDir = if (Test-Path "D:\act") { "D:\act" } else { $env:USERPROFILE }

$isDefaultPwsh = $false
$isDirMatch = $false
$isAcrylicMatch = $false
$isFontMatch = $false
$isLegacyHidden = $false
$isPwshProfileReady = $false

if ($isWtFileReady) {
    try {
        $rawContent = [System.IO.File]::ReadAllText($wtSettings, [System.Text.UTF8Encoding]::new($false))
        if ([string]::IsNullOrWhiteSpace($rawContent)) {
            throw "Windows Terminal 配置文件 [$wtSettings] 内容为空，拒绝初始化。"
        }
        $wtJson = ConvertFrom-Json -InputObject $rawContent -NoEnumerate -Depth 100 -ErrorAction Stop
        if ($wtJson -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Windows Terminal 配置文件 [$wtSettings] 根结构必须为对象。"
        }
        $isDefaultPwsh = ($wtJson.defaultProfile -eq $GUID_PWSH)
        $defaults = $wtJson.profiles.defaults
        if ($defaults) {
            $isDirMatch = ($defaults.startingDirectory -eq $targetStartDir)
            $isAcrylicMatch = ($defaults.useAcrylic -eq $true -and ($defaults.acrylicOpacity -eq 0.85 -or $defaults.opacity -eq 85))
            $isFontMatch = ($null -ne $defaults.font -and $defaults.font.face -eq "Maple Mono NL NFMono CN")
        }

        $azureList = @($wtJson.profiles.list | Where-Object { $GUID_AZURE -contains $_.guid -or $_.name -match 'Azure Cloud Shell' })
        $legacyList = @($wtJson.profiles.list | Where-Object { $GUID_LEGACY -contains $_.guid -or $_.name -match 'Windows PowerShell 5|Command Prompt|命令提示符' })
        $allHidden = $true
        foreach ($p in ($azureList + $legacyList)) {
            if ($p.hidden -ne $true) { $allHidden = $false; break }
        }
        $isLegacyHidden = $allHidden

        $isPwshProfileReady = Test-TerminalShellProfile -Profiles @($wtJson.profiles.list) -Expected $expectedShellProfiles[0]
    } catch {
        throw "Windows Terminal 配置文件 [$wtSettings] 存在但读取或解析失败: $($_.Exception.Message)"
    }
}

# 4.1 等宽字体基线
$chkList.Add([PSCustomObject]@{
    状态     = if ($hasMapleFont) { " ✔" } else { " ▲" }
    模块     = "依赖"
    属性     = "等宽字体装配 (Maple Mono NL NFMono CN)"
    实机     = if ($hasMapleFont) { "已安装并注册至系统字体库" } else { "未安装" }
    基线     = "已安装并注册至系统字体库"
    状态判定 = if ($hasMapleFont) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $hasMapleFont) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "依赖"
        受控属性 = "等宽字体装配 (Maple Mono NL NFMono CN)"
        实机状态 = "未安装"
        期望基线 = "已安装并注册至系统字体库"
        Purpose  = "装配工作站标准开源等宽编程字体 Maple Mono NL NFMono CN"
        Impact   = "为 Terminal、代码编辑器与终端应用提供无连字、中英文 1:2 比例等宽与单字符宽度 Nerd Font 图标排版"
    })
}

# 4.2 Terminal 默认 Profile 与配置注册
$isPwshHealthy = ($isDefaultPwsh -and $isPwshProfileReady)
$chkList.Add([PSCustomObject]@{
    状态     = if ($isPwshHealthy) { " ✔" } else { " ▲" }
    模块     = "集成"
    属性     = "默认终端Shell (defaultProfile)"
    实机     = if ($isPwshHealthy) { "PowerShell 7 ($GUID_PWSH)" } else { if ($wtJson) { "$($wtJson.defaultProfile)" } else { "未绑定或文件缺失" } }
    基线     = "PowerShell 7 ($GUID_PWSH)"
    状态判定 = if ($isPwshHealthy) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isPwshHealthy) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "集成"
        受控属性 = "默认终端Shell (defaultProfile)"
        实机状态 = if ($wtJson) { "$($wtJson.defaultProfile)" } else { "缺失" }
        期望基线 = "PowerShell 7 ($GUID_PWSH)"
        Purpose  = "在 Windows Terminal 注册并绑定 PowerShell 7 (pwsh) 为默认会话"
        Impact   = "每次点击打开终端默认直接进入现代 pwsh 会话，避免启动旧版 Windows PowerShell 5.1"
    })
}

$isMenuMatch = Test-TerminalShellMenu -Menu @($wtJson.newTabMenu) -ExpectedProfiles $expectedShellProfiles
$menuNames = $expectedShellProfiles.name -join ', '
$chkList.Add([PSCustomObject]@{
    状态     = if ($isMenuMatch) { " ✔" } else { " ▲" }
    模块     = "集成"
    属性     = "新建标签页菜单 (newTabMenu)"
    实机     = if ($isMenuMatch) { $menuNames } else { "缺失或入口偏离" }
    基线     = $menuNames
    状态判定 = if ($isMenuMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isMenuMatch) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "集成"; 受控属性 = "新建标签页菜单 (newTabMenu)"
        实机状态 = "缺失或入口偏离"; 期望基线 = $menuNames
        Purpose = "菜单仅引用已探测到的受控 Shell Profile"
        Impact = "替换受控新建菜单，不删除菜单外的个人 Profile；缺失的可选 Shell 不生成菜单入口"
    })
}

# 4.3 Terminal 渲染字体与视效细项
$chkList.Add([PSCustomObject]@{
    状态     = if ($isFontMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "终端渲染字体 (defaults.font.face)"
    实机     = if ($wtJson -and $wtJson.profiles.defaults -and $wtJson.profiles.defaults.font -and $wtJson.profiles.defaults.font.face) { "$($wtJson.profiles.defaults.font.face)" } else { "<未配置>" }
    基线     = "Maple Mono NL NFMono CN"
    状态判定 = if ($isFontMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isFontMatch) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "配置"
        受控属性 = "终端渲染字体 (defaults.font.face)"
        实机状态 = if ($wtJson -and $wtJson.profiles.defaults -and $wtJson.profiles.defaults.font -and $wtJson.profiles.defaults.font.face) { "$($wtJson.profiles.defaults.font.face)" } else { "<未配置>" }
        期望基线 = "Maple Mono NL NFMono CN"
        Purpose  = "将 Windows Terminal 默认渲染字体锁定为 Maple Mono NL NFMono CN"
        Impact   = "提供清晰高辨识度的中英文等宽与单字符宽度 Nerd Font 图标排版"
    })
}

# 4.3 Terminal 起始目录与视效细项
$chkList.Add([PSCustomObject]@{
    状态     = if ($isDirMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "默认起始目录 (defaults.startingDirectory)"
    实机     = if ($wtJson -and $wtJson.profiles.defaults -and $wtJson.profiles.defaults.startingDirectory) { "$($wtJson.profiles.defaults.startingDirectory)" } else { "<未配置>" }
    基线     = "$targetStartDir"
    状态判定 = if ($isDirMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isDirMatch) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "配置"
        受控属性 = "默认起始目录 (defaults.startingDirectory)"
        实机状态 = if ($wtJson -and $wtJson.profiles.defaults -and $wtJson.profiles.defaults.startingDirectory) { "$($wtJson.profiles.defaults.startingDirectory)" } else { "<未配置>" }
        期望基线 = "$targetStartDir"
        Purpose  = "自适应将终端默认工作目录锚定至工作区 ($targetStartDir)"
        Impact   = "打开终端无需手动 cd 切换路径，直接聚焦活跃工程"
    })
}

$chkList.Add([PSCustomObject]@{
    状态     = if ($isAcrylicMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "亚克力磨砂效果 (useAcrylic / 0.85)"
    实机     = if ($isAcrylicMatch) { "Acrylic=True (0.85)" } else { "未配置/已关闭" }
    基线     = "Acrylic=True (0.85)"
    状态判定 = if ($isAcrylicMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isAcrylicMatch) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "配置"
        受控属性 = "亚克力磨砂效果 (useAcrylic / 0.85)"
        实机状态 = if ($wtJson -and $wtJson.profiles.defaults) { "useAcrylic=$($wtJson.profiles.defaults.useAcrylic)" } else { "<未配置>" }
        期望基线 = "Acrylic=True (0.85)"
        Purpose  = "开启 Terminal 窗口亚克力磨砂半透明背景 (0.85)"
        Impact   = "提升现代桌面美感与背景视效通透度"
    })
}

# 4.4 旧版与云端干扰项净化
$chkList.Add([PSCustomObject]@{
    状态     = if ($isLegacyHidden) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "旧版与云端干扰项隐藏 (Azure/CMD/PS5.1)"
    实机     = if ($isLegacyHidden) { "全部 hidden=true" } else { "存在未隐藏项" }
    基线     = "全部 hidden=true"
    状态判定 = if ($isLegacyHidden) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isLegacyHidden) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "配置"
        受控属性 = "旧版与云端干扰项隐藏 (Azure/CMD/PS5.1)"
        实机状态 = "存在未隐藏项"
        期望基线 = "全部 hidden=true"
        Purpose  = "在终端新建下拉菜单中隐藏 Azure Cloud Shell、旧版 CMD 与 PS 5.1"
        Impact   = "下拉菜单极简纯净，仅保留生产力现代 Shell"
    })
}

# 4.5 PowerShell 7 前缀历史检索托管块
$pwshHasBlock = (Test-Path $pwshProfilePath) -and (Get-Content $pwshProfilePath -Raw -ErrorAction SilentlyContinue | Select-String "pwsh-history-search")
$chkList.Add([PSCustomObject]@{
    状态     = if ($pwshHasBlock) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "PowerShell 7 PSReadLine 历史回溯"
    实机     = if ($pwshHasBlock) { "已托管注入 ($pwshProfilePath)" } else { "未注入" }
    基线     = "已托管注入 ($pwshProfilePath)"
    状态判定 = if ($pwshHasBlock) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $pwshHasBlock) {
    $diffList.Add([PSCustomObject]@{
        分层模块 = "配置"
        受控属性 = "PowerShell 7 PSReadLine 历史回溯"
        实机状态 = "未注入"
        期望基线 = "已托管注入 ($pwshProfilePath)"
        Purpose  = "固化 PSReadLine 的 Up/Down 键按已键入前缀模糊匹配历史与行内预测"
        Impact   = "打命令时仅需输入前几个字母按 Up 键即可秒级回溯历史"
    })
}

if (-not $Yes) {
    Write-Host "`n📊 [巡检看板] Windows Terminal 与 PowerShell 7 基线审计清单:" -ForegroundColor Cyan
    $chkList | Select-Object 状态, 模块, 属性, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host
}

if ($Action -eq "Check") {
    if ($diffList.Count -eq 0) {
        Write-Host "✨ [状态合规] Windows Terminal 与 Shell 配置均与工程基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $diffList.Count) -ForegroundColor Yellow
    }
    return
}

if ($diffList.Count -eq 0 -and -not $Force) {
    Write-Host "✨ [状态合规] 所有受控属性与策略均已符合工程基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

if ($diffList.Count -gt 0) {
    Write-Host "`n📋 [差异清单] 检测到以下受控属性偏离工程基线:" -ForegroundColor Cyan
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

# 6.1 装配等宽字体
if (-not $hasMapleFont -or $Force) {
    Install-MapleFontKit
    $hasMapleFont = $true
}

# 6.2 注入并调优 Windows Terminal settings.json
Write-Host "`n⚙️  正在单向对齐 Windows Terminal 工程基线策略..." -ForegroundColor Cyan
if (Test-Path $wtSettings) {
    # 在分支内赋值，避免 if 的输出管道再次展开根数组。
    $jsonObj = ConvertFrom-Json -InputObject (Get-Content -Path $wtSettings -Raw -Encoding UTF8 -ErrorAction Stop) -NoEnumerate -Depth 100 -ErrorAction Stop
} else {
    $jsonObj = [PSCustomObject]@{ '$schema' = 'https://aka.ms/terminal-profiles-schema' }
}
Sync-TerminalShellProfiles -Settings $jsonObj -ExpectedProfiles $expectedShellProfiles

# 顶层全局设置
Set-OrAddProperty $jsonObj "copyOnSelect" $true
Set-OrAddProperty $jsonObj "confirmCloseAllTabs" $false

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

# 隐藏旧版与云端干扰项；Shell 创建不依赖既有列表非空。
foreach ($p in $jsonObj.profiles.list) {
    if ($GUID_AZURE -contains $p.guid -or $p.name -match 'Azure Cloud Shell') {
        Set-OrAddProperty $p "hidden" $true
    }
    if ($GUID_LEGACY -contains $p.guid -or $p.name -match 'Windows PowerShell 5|Command Prompt|命令提示符') {
        Set-OrAddProperty $p "hidden" $true
    }
}

$finalJsonStr = $jsonObj | ConvertTo-Json -Depth 100 -WarningAction Stop -ErrorAction Stop
$parent = Split-Path -Path $wtSettings -Parent
if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[System.IO.File]::WriteAllText($wtSettings, $finalJsonStr, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ Windows Terminal 策略已写入: $wtSettings" -ForegroundColor Green

# 6.3 注入 PowerShell 7 历史按键与行内预测托管块
Write-Host "⚙️  正在注入 PowerShell 7 前缀历史智能检索与行内预测基线..." -ForegroundColor Cyan
Update-ManagedConfigFile -FilePath $pwshProfilePath -BlockTag "pwsh-history-search" -BlockContent $pwshBlock
Write-Host "✅ PowerShell 7 历史检索体验基线对齐完毕。" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 基线配置已全部闭环自愈！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 默认终端: PowerShell 7 ($GUID_PWSH)" -ForegroundColor Gray
Write-Host "   - 启动目录: $targetStartDir (Acrylic 0.85 磨砂开启)" -ForegroundColor Gray
Write-Host "   - 渲染字体: Maple Mono NL NFMono CN (12pt)" -ForegroundColor Gray
Write-Host "   - 体验统一: pwsh 已固化 PSReadLine 前缀历史智能检索与行内预测" -ForegroundColor Gray

return
