#requires -Version 7.0
<#
.SYNOPSIS
    小狼毫输入法 (Weasel / Rime)

.DESCRIPTION
    小狼毫输入法 (Weasel / Rime) 自动化纯净安装、雾凇拼音词库打底与现代体验配置脚本。
    1. 专为 PowerShell 7+ (pwsh) 编写，充分运用现代 pwsh 语法糖、强类型安全与原生无 BOM UTF-8 输出。
    2. 严格遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)：对二进制安装本体、实际用户目录、雾凇词库及 YAML 补丁全流程先检后配，避免重复下载与脏覆写。
    3. 纯拼音方案隔离：方案限定为 rime_ice 纯全拼，排除双拼、五笔、形码与字根方案，避免按键哈希碰撞与词库冲突。
    4. Control 键接管中英切换：Shift 设为 noop 避免误触，由 Control 键控制中英状态流转。
    5. 现代 GUI 视觉：启用 DirectWrite 矢量抗锯齿排版、横向 5 候选词与 Win11 原生深浅色亚克力磨砂视觉。
    6. 只纳管 Weasel 实际用户目录：读取 HKCU\Software\Rime\Weasel 的 REG_SZ RimeUserDir，未设置时使用 %APPDATA%\Rime；不修改目录设置、不迁移数据或管理目录链接。
    7. 自治管理中文显示语言与输入法 (WinUserLanguageList)：原子化安装 zh-CN 语言包（排除无关 FOD）并设为首选显示语言，将小狼毫 TIP 激活为中文唯一输入法，彻底杜绝系统自带微软拼音的激活与暴露；卸载时注销输入法，绝不主动引入系统自带输入法。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (只读比对受控属性 Diff)
    - Uninstall : 清洁卸载、注销系统 TSF 组件并移除本体 (默认保留用户词库)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制重新拉取安装包解包覆盖安装小狼毫本体并回正基线配置。

.PARAMETER Purge
    配合 Uninstall 使用，删除实际用户目录内的词库与配置；目录本身为链接时拒绝删除或解绑，交由用户处理。

.PARAMETER InstallDir
    小狼毫二进制本体安装目录，默认为受控基线 D:\prog\Rime。

.PARAMETER InstallerPath
    可选，小狼毫本地离线安装包路径（如 weasel-0.17.4.0-installer.exe）。指定后优先使用离线包，免除网络下载。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\desktop\apps\rime.ps1 -Action Check

    # 交互式全流程安装与配置
    pwsh -File .\desktop\apps\rime.ps1

    # 强制重新安装本体并对齐基线
    pwsh -File .\desktop\apps\rime.ps1 -Force

    # 安全清洁卸载 (保留用户词库)
    pwsh -File .\desktop\apps\rime.ps1 -Action Uninstall

    # 清理卸载 (连带删除用户词库)
    pwsh -File .\desktop\apps\rime.ps1 -Action Uninstall -Purge
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "Uninstall")]
    [string]$Action = "Sync",

    [switch]$Yes,
    [switch]$Force,
    [switch]$Purge,
    [string]$InstallDir = "D:\prog\Rime",
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
    throw "【权限错误】小狼毫属于系统 TSF 输入法组件，必须以管理员身份运行此脚本！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将用户配置错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
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

function Get-RimeUserDirectory {
    $defaultDirectory = Join-Path $env:APPDATA 'Rime'
    try {
        $key = Get-Item -LiteralPath 'HKCU:\Software\Rime\Weasel' -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $defaultDirectory
    }
    try {
        if ($key.GetValueNames() -notcontains 'RimeUserDir' -or
            $key.GetValueKind('RimeUserDir') -ne [Microsoft.Win32.RegistryValueKind]::String) {
            return $defaultDirectory
        }
        $directory = [string]$key.GetValue('RimeUserDir', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ([string]::IsNullOrEmpty($directory)) { return $defaultDirectory }
        if (-not [IO.Path]::IsPathFullyQualified($directory)) {
            throw 'Weasel RimeUserDir 不是绝对路径，无法确定实际用户目录；未修改目录设置。'
        }
        return [IO.Path]::GetFullPath($directory)
    } finally {
        $key.Dispose()
    }
}

function Remove-RimeUserDirectory {
    param([Parameter(Mandatory)][string]$Directory)
    try {
        $item = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return
    }
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "实际用户目录不是普通目录，未删除或解绑；请自行处理: $Directory"
    }
    $fullPath = [IO.Path]::GetFullPath($Directory)
    if ($fullPath.TrimEnd('\') -eq [IO.Path]::GetPathRoot($fullPath).TrimEnd('\')) {
        throw "实际用户目录为磁盘或共享根目录，拒绝删除: $Directory"
    }
    Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction Stop
    try {
        $null = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Host "   - [已删除] 实际用户目录: $Directory" -ForegroundColor Yellow
        return
    }
    throw "实际用户目录仍存在，删除未完成: $Directory"
}

$ConfDir = Get-RimeUserDirectory

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

function Get-RimeBuildStatus {
    param([Parameter(Mandatory)][string]$Directory)
    $defaultFile = Join-Path $Directory 'build\default.yaml'
    $prismFile = Join-Path $Directory 'build\rime_ice.prism.bin'
    $defaultItem = $null
    $prismItem = $null
    try {
        $defaultItem = Get-Item -LiteralPath $defaultFile -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] { }
    try {
        $prismItem = Get-Item -LiteralPath $prismFile -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] { }

    $schemaMatches = $false
    if ($null -ne $defaultItem -and -not $defaultItem.PSIsContainer) {
        $text = Get-Content -LiteralPath $defaultFile -Raw -ErrorAction Stop
        $schemaList = [regex]::Match([string]$text, '(?m)^schema_list:[ \t]*(?:#[^\r\n]*)?\r?\n(?:(?:[ \t]+[^\r\n]*|[ \t]*)(?:\r?\n|$))*')
        $schemaMatches = $schemaList.Success -and
            $schemaList.Value -match '(?m)^[ \t]+-[ \t]+schema:[ \t]*(?:rime_ice|"rime_ice"|''rime_ice'')[ \t]*(?:#[^\r\n]*)?\r?$'
    }
    $prismMatches = $null -ne $prismItem -and -not $prismItem.PSIsContainer -and $prismItem.Length -gt 10240
    return [PSCustomObject]@{
        SchemaMatches = $schemaMatches
        SchemaActual  = if ($schemaMatches) { 'rime_ice' } else { '<缺失或 schema_list 未声明 rime_ice>' }
        PrismMatches  = $prismMatches
        PrismActual   = if ($prismMatches) { '已就绪 ({0} KB)' -f [math]::Round($prismItem.Length / 1KB, 1) } else { '<缺失、非文件或不满足现有大小检查 (>10KB)>' }
    }
}

function Invoke-RimeDeployment {
    param(
        [Parameter(Mandatory)][string]$Deployer,
        [Parameter(Mandatory)][string]$Directory
    )
    $binary = Get-Item -LiteralPath $Deployer -Force -ErrorAction Stop
    if ($binary.PSIsContainer) { throw "部署器不是可执行文件: $Deployer" }
    $process = Start-Process -FilePath $Deployer -ArgumentList '/deploy' -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -ne 0) {
        throw "WeaselDeployer /deploy 失败 (退出码: $($process.ExitCode))；未启动 WeaselServer，已写入的配置保留。"
    }
    $status = Get-RimeBuildStatus -Directory $Directory
    if (-not $status.SchemaMatches -or -not $status.PrismMatches) {
        throw "部署命令退出成功，但产物检查未通过：default.yaml=$($status.SchemaActual)；Prism=$($status.PrismActual)；未启动 WeaselServer，已写入的配置保留。"
    }
    Write-Host '✅ /deploy 命令完成；方案声明与 Prism 文件大小检查通过。未验证输入法运行时加载或二进制索引完整性。' -ForegroundColor Green
}

# 权威输入法 TIP 标识符 (依据 Weasel TSF 注册及 Windows 语言列表规范)
$RimeTipHans = "0804:{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}{3D02CAB6-2B8E-4781-BA20-1C9267529467}"
$MsPinyinTip = "0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}"

function Find-ChineseLanguage {
    param($LanguageList)
    if ($null -eq $LanguageList) { return $null }
    foreach ($lang in @($LanguageList)) {
        if ($null -eq $lang) { continue }
        $lcid = $null
        try {
            $tag = $lang.LanguageTag
            if ($tag) {
                $lcid = ([System.Globalization.CultureInfo]::GetCultureInfo($tag).LCID).ToString('X4')
            }
        } catch { }
        if (($lang.LanguageTag -and $lang.LanguageTag -match '^(?i)zh(-|$)') -or $lcid -ieq '0804') {
            return $lang
        }
    }
    return $null
}

function Get-RimeInputMethodStatus {
    $langs = Get-WinUserLanguageList -ErrorAction Stop
    if ($null -eq $langs -or @($langs).Count -eq 0) {
        throw '无法确认当前用户语言列表。'
    }
    foreach ($lang in @($langs)) {
        if ($null -eq $lang.LanguageTag -or $null -eq $lang.InputMethodTips) {
            throw '当前用户语言属性不完整或无法确认。'
        }
    }

    $zhLang = Find-ChineseLanguage -LanguageList $langs
    if ($null -eq $zhLang) {
        return [PSCustomObject]@{
            HasChineseLanguage = $false
            HasRimeTip         = $false
            HasMsPinyin        = $false
            IsCompliant        = $false
            ActualStatus       = '未配置中文语言'
            Languages          = $langs
            TargetLanguage     = $null
        }
    }

    $tips = @($zhLang.InputMethodTips)
    $hasRime = $tips -icontains $RimeTipHans
    $hasPinyin = $tips -icontains $MsPinyinTip

    $isCompliant = $hasRime -and (-not $hasPinyin)
    $actual = if ($hasRime -and -not $hasPinyin) {
        '已激活小狼毫 (排除微软拼音)'
    } elseif ($hasRime -and $hasPinyin) {
        '已添加小狼毫但未移除微软拼音'
    } elseif ($hasPinyin) {
        '未激活小狼毫 (当前为微软拼音)'
    } elseif ($tips.Count -gt 0) {
        "未激活小狼毫 (当前为: $($tips -join ', '))"
    } else {
        '未激活小狼毫 (中文无可用输入法)'
    }

    return [PSCustomObject]@{
        HasChineseLanguage = $true
        HasRimeTip         = $hasRime
        HasMsPinyin        = $hasPinyin
        IsCompliant        = $isCompliant
        ActualStatus       = $actual
        Languages          = $langs
        TargetLanguage     = $zhLang
    }
}

function Set-RimeInputMethodActive {
    param(
        [Parameter(Mandatory = $true)]
        $Status
    )
    $langs = $Status.Languages
    $zhLang = $Status.TargetLanguage

    if ($null -eq $zhLang) {
        $zhLang = (New-WinUserLanguageList -Language 'zh-CN')[0]
    }

    # 确保中文语言项处于用户首选语言首位 (zh-CN > en-US)
    $reordered = [System.Collections.Generic.List[object]]::new()
    $reordered.Add($zhLang)
    foreach ($item in @($langs)) {
        if ($item -ne $zhLang) { $reordered.Add($item) }
    }
    $langs = $reordered

    $existingTips = @($zhLang.InputMethodTips)
    $filteredTips = [System.Collections.Generic.List[string]]::new()
    $changed = $false

    foreach ($tip in $existingTips) {
        if ($tip -ieq $MsPinyinTip) {
            $changed = $true
            continue
        }
        $filteredTips.Add($tip)
    }

    if ($filteredTips -inotcontains $RimeTipHans) {
        $filteredTips.Insert(0, $RimeTipHans)
        $changed = $true
    }

    if ($changed -or ($filteredTips.Count -ne $existingTips.Length)) {
        $zhLang.InputMethodTips.Clear()
        foreach ($tip in $filteredTips) {
            $zhLang.InputMethodTips.Add($tip)
        }
        Set-WinUserLanguageList -LanguageList $langs -Force -ErrorAction Stop
    }

    $after = Get-RimeInputMethodStatus
    if (-not $after.IsCompliant) {
        throw "小狼毫用户输入法激活后校验失败，当前状态：$($after.ActualStatus)"
    }
}

function Remove-RimeInputMethodRegistration {
    $langs = $null
    try {
        $langs = Get-WinUserLanguageList -ErrorAction Stop
    } catch {
        Write-Host "   - 无法读取用户语言列表，跳过输入法列表注销。" -ForegroundColor DarkGray
        return
    }

    $changed = $false
    foreach ($lang in @($langs)) {
        $tips = @($lang.InputMethodTips)
        if ($tips -icontains $RimeTipHans) {
            $remaining = [System.Collections.Generic.List[string]]::new()
            foreach ($tip in $tips) {
                if ($tip -ieq $RimeTipHans) { continue }
                $remaining.Add($tip)
            }
            $lang.InputMethodTips.Clear()
            foreach ($tip in $remaining) {
                $lang.InputMethodTips.Add($tip)
            }
            $changed = $true
        }
    }

    if ($changed) {
        Set-WinUserLanguageList -LanguageList $langs -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已从用户语言列表中注销小狼毫输入法（绝不主动添加微软自带输入法）。" -ForegroundColor Gray
    }
}

function Get-RimeLanguagePackStatus {
    $installed = $null
    try {
        $installed = @(Get-InstalledLanguage -ErrorAction Stop)
    } catch { }

    $hasZhCn = $false
    if ($null -ne $installed) {
        $hasZhCn = (@($installed | Where-Object { $_.LanguageId -ceq 'zh-CN' -or $_.Language -ceq 'zh-CN' }).Count -gt 0)
    }
    $override = $null
    try {
        $override = Get-WinUILanguageOverride -ErrorAction SilentlyContinue
    } catch { }

    $overrideMatch = $false
    if ($null -ne $override) {
        $overrideStr = if ($override -is [System.Globalization.CultureInfo]) { $override.Name } else { [string]$override }
        $overrideMatch = ($overrideStr -match '^(?i)zh(-Hans)?-CN$')
    }

    $isPreferredDisplay = $false
    if ($null -ne $override) {
        $overrideStr = if ($override -is [System.Globalization.CultureInfo]) { $override.Name } else { [string]$override }
        $isPreferredDisplay = ($overrideStr -match '^(?i)zh(-Hans)?-CN$')
    } else {
        # 当未显式配置 WindowsOverride 时，依层级探测首选 UI 语言列表、用户语言列表与当前 UI 文化
        $prefUIs = $null
        try {
            $prefUIs = @((Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'PreferredUILanguages' -ErrorAction SilentlyContinue).PreferredUILanguages)
        } catch { }

        if ($null -ne $prefUIs -and $prefUIs.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($prefUIs[0])) {
            $isPreferredDisplay = ($prefUIs[0] -match '^(?i)zh(-Hans)?-CN$')
        } else {
            $userLangs = $null
            try {
                $userLangs = @(Get-WinUserLanguageList -ErrorAction SilentlyContinue)
            } catch { }

            if ($null -ne $userLangs -and $userLangs.Count -gt 0 -and $null -ne $userLangs[0].LanguageTag) {
                $isPreferredDisplay = ($userLangs[0].LanguageTag -match '^(?i)zh(-Hans)?-CN$')
            } else {
                try {
                    $isPreferredDisplay = ((Get-UICulture).Name -match '^(?i)zh(-Hans)?-CN$')
                } catch { }
            }
        }
    }

    $isCompliant = $hasZhCn -and $isPreferredDisplay
    $actual = if ($isCompliant) {
        '已安装 zh-CN 语言包 (首选显示)'
    } elseif ($hasZhCn) {
        '已安装 zh-CN 语言包 (未覆盖首选)'
    } else {
        '未安装 zh-CN 语言包'
    }

    return [pscustomobject]@{
        HasLanguagePack    = $hasZhCn
        UIOverride         = $override
        IsPreferredDisplay = $isPreferredDisplay
        IsCompliant        = $isCompliant
        ActualStatus       = $actual
    }
}

function Install-RimeLanguagePack {
    $status = Get-RimeLanguagePackStatus
    if (-not $status.HasLanguagePack) {
        Write-Host "   - 正在安装简体中文语言包 (zh-CN，已排除按需功能)..." -ForegroundColor Gray
        Install-Language zh-CN -ExcludeFeatures -ErrorAction Stop
    }
    if (-not $status.IsCompliant) {
        Write-Host "   - 正在设置用户首选显示语言为 zh-CN..." -ForegroundColor Gray
        Set-WinUILanguageOverride -Language zh-CN -ErrorAction Stop
    }
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
            Write-Host "🔥 【检测到 -Purge 参数：以下用户数据将被清理】:" -ForegroundColor Red
            foreach ($d in $HighValueUserData) {
                Write-Host ("   - {0}" -f $d) -ForegroundColor DarkRed
            }
            Write-Host "👉 该操作不可逆，用户词库、短语与客制配置将被删除！`n" -ForegroundColor Red
        } else {
            Write-Host "🛡️  【数据安全保护：以下高价值用户数据将默认保留在实机】:" -ForegroundColor Green
            foreach ($d in $HighValueUserData) {
                Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
            }
            Write-Host "👉 默认卸载仅移除程序本体与系统 TSF 注册。若需连带清理词库，请指定 -Purge 开关。`n" -ForegroundColor Cyan
        }

        $promptText = if ($Purge) {
            "确认注销输入法组件并删除程序本体与词库目录? [y/N]"
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

    # 2. 调用官方反注册命令 (非阻塞脱钩与注销)
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

    # 3. 注销系统 TSF 组件注册表分支
    @(
        "HKLM:\SOFTWARE\Rime",
        "HKLM:\SOFTWARE\WOW6432Node\Rime",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Weasel",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Weasel"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "WeaselServer" -ErrorAction SilentlyContinue
    Write-Host "   - 已移除 Rime 注册表项与自启动项。" -ForegroundColor Gray

    # 4. 从当前用户语言列表中注销小狼毫输入法 (不主动添加微软自带输入法)
    Remove-RimeInputMethodRegistration

    # 5. 仅处理已探测的实际用户目录，保留 HKCU 原生目录设置与用户已有链接。
    if ($Purge) {
        Remove-RimeUserDirectory -Directory $ConfDir
    } else {
        Write-Host "   - [数据安全保护] 保留实际用户目录及原生目录设置: $ConfDir" -ForegroundColor Green
    }

    # 6. 清理安装根目录
    if (Test-Path $cleanInstallDir) {
        Remove-Item -Path $cleanInstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理基准安装目录: $cleanInstallDir" -ForegroundColor Gray
    }

    # 7. 清理快捷方式
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
Write-Host "  实际用户目录: $ConfDir" -ForegroundColor DarkGray
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
    状态     = if ($isServerMatch) { " ✔" } else { " ▲" }
    模块     = "本体"
    属性     = "WeaselServer 核心运行时"
    实机     = $actualServerStatus
    基线     = "已就绪于 $cleanInstallDir"
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
    状态     = if ($isDeployerReady) { " ✔" } else { " ▲" }
    模块     = "本体"
    属性     = "WeaselDeployer 编译部署器"
    实机     = $actualDepStatus
    基线     = "已就绪于版本子树"
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
    状态     = if ($isTsfMatch) { " ✔" } else { " ▲" }
    模块     = "系统"
    属性     = "系统 TSF 输入法注册 (Rime\Weasel)"
    实机     = $actualTsfStatus
    基线     = "已注册且关联至 $cleanInstallDir"
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

# 5.3.0 简体中文系统显示语言包 (zh-CN)
$langPackStatus = Get-RimeLanguagePackStatus
$isLangPackMatch = $langPackStatus.IsCompliant
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($isLangPackMatch) { " ✔" } else { " ▲" }
    模块     = "系统"
    属性     = "系统显示语言 (zh-CN 语言包)"
    实机     = $langPackStatus.ActualStatus
    基线     = "已安装 zh-CN 语言包 (首选显示)"
    状态判定 = if ($isLangPackMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isLangPackMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "系统环境"
        受控属性 = "系统显示语言 (zh-CN 语言包)"
        实机状态 = $langPackStatus.ActualStatus
        期望基线 = "已安装 zh-CN 语言包 (首选显示)"
        Purpose  = "安装简体中文语言包 (排除无关 FOD) 并设为首选界面语言，从源头闭环中文运行环境"
        Impact   = "Windows 界面将在下次登录或重启后切换为简体中文，全程不激活微软自带拼音"
    })
}

# 5.3.1 用户输入法激活 (WinUserLanguageList -> Rime)
$imeStatus = Get-RimeInputMethodStatus
$isImeMatch = $imeStatus.IsCompliant
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($isImeMatch) { " ✔" } else { " ▲" }
    模块     = "系统"
    属性     = "用户输入法激活 (WinUserLanguageList -> Rime)"
    实机     = $imeStatus.ActualStatus
    基线     = "已激活小狼毫 (排除微软拼音)"
    状态判定 = if ($isImeMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isImeMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "系统集成"
        受控属性 = "用户输入法激活 (WinUserLanguageList -> Rime)"
        实机状态 = $imeStatus.ActualStatus
        期望基线 = "已激活小狼毫 (排除微软拼音)"
        Purpose  = "将小狼毫 TIP 注册为当前用户中文首选输入法并移除系统自带微软拼音"
        Impact   = "中文语言由小狼毫独占接管，避免双输入法焦点冲突与系统自愈切回微软拼音"
    })
}

# 5.4 雾凇拼音词库核心文件
$iceSchema = Join-Path $ConfDir "rime_ice.schema.yaml"
$hasIceDict = Test-Path -LiteralPath $iceSchema
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($hasIceDict) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "雾凇拼音核心词库 (rime_ice.schema.yaml)"
    实机     = if ($hasIceDict) { "已就绪" } else { "缺失未就绪" }
    基线     = "已落地于 $ConfDir"
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
$defRaw       = if (Test-Path -LiteralPath $defCustom) { Get-Content -LiteralPath $defCustom -Raw -ErrorAction SilentlyContinue } else { "" }
$isSchemaMatch = ($defRaw -match '(?m)^\s*-\s*schema:\s*[''"]?rime_ice[''"]?' -or $defRaw -match 'schema:\s*[''"]?rime_ice[''"]?')
$actualSchemaStatus = if ($isSchemaMatch) {
    "rime_ice"
} elseif ($defRaw -match 'schema:\s*[''"]?([a-zA-Z0-9_\-]+)') {
    $matches[1]
} else {
    "<缺省未配>"
}
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($isSchemaMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "默认主方案 (default.custom.yaml -> schema)"
    实机     = $actualSchemaStatus
    基线     = "rime_ice"
    状态判定 = if ($isSchemaMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isSchemaMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "默认主方案 (default.custom.yaml -> schema)"
        实机状态 = $actualSchemaStatus
        期望基线 = "rime_ice"
        Purpose  = "锁定全局默认方案为 rime_ice 纯全拼，排除双拼与形码干扰"
        Impact   = "启动小狼毫直接进入纯全拼打字状态，避免多方案切换冲突"
    })
}

# 5.6 中英切换控制键 (default.custom.yaml -> Control_L: commit_code)
$ctrlVal = Get-YamlScalar -Content $defRaw -Key "Control_L"
$isCtrlMatch = ($ctrlVal -ieq "commit_code")
$actualCtrlStatus = if ($ctrlVal) { $ctrlVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($isCtrlMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "中英切换按键 (default.custom.yaml -> Control_L)"
    实机     = $actualCtrlStatus
    基线     = "commit_code"
    状态判定 = if ($isCtrlMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isCtrlMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "中英切换按键 (default.custom.yaml -> Control_L)"
        实机状态 = $actualCtrlStatus
        期望基线 = "commit_code"
        Purpose  = "单按 Control 键接管中英状态流转，上屏当前编码"
        Impact   = "使 Control 成为专属中英切换键，消除按键行为歧义"
    })
}

# 5.7 Shift 防误触屏蔽 (default.custom.yaml -> Shift_L: noop)
$shiftVal = Get-YamlScalar -Content $defRaw -Key "Shift_L"
$isShiftMatch = ($shiftVal -ieq "noop")
$actualShiftStatus = if ($shiftVal) { $shiftVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($isShiftMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "Shift 屏蔽防误触 (default.custom.yaml -> Shift_L)"
    实机     = $actualShiftStatus
    基线     = "noop"
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
$weaselRaw    = if (Test-Path -LiteralPath $weaselCustom) { Get-Content -LiteralPath $weaselCustom -Raw -ErrorAction SilentlyContinue } else { "" }
$horizVal = Get-YamlScalar -Content $weaselRaw -Key "style/horizontal"
if (-not $horizVal) { $horizVal = Get-YamlScalar -Content $weaselRaw -Key "horizontal" }
$isHorizMatch = ($horizVal -ieq "true")
$actualHorizStatus = if ($horizVal) { $horizVal } else { "<缺省未配>" }
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($isHorizMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "候选词横排布局 (weasel.custom.yaml -> style/horizontal)"
    实机     = $actualHorizStatus
    基线     = "true"
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
    状态     = if ($isCandMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "候选词单页数量 (weasel.custom.yaml -> max_number_of_candidates)"
    实机     = $actualCandStatus
    基线     = "5"
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
    状态     = if ($isAaMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "矢量平滑排版 (weasel.custom.yaml -> style/antialias_mode)"
    实机     = $actualAaStatus
    基线     = "directwrite"
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
    状态     = if ($isCsMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "视觉皮肤主题 (weasel.custom.yaml -> style/color_scheme)"
    实机     = $actualCsStatus
    基线     = "weasel_modern"
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

# 5.12 衍生方案声明检查 (build/default.yaml)
$buildStatus = Get-RimeBuildStatus -Directory $ConfDir
$isBuildDefMatch = $buildStatus.SchemaMatches
$actualBuildDefStatus = $buildStatus.SchemaActual
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($isBuildDefMatch) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "衍生方案声明 (build/default.yaml)"
    实机     = $actualBuildDefStatus
    基线     = "rime_ice"
    状态判定 = if ($isBuildDefMatch) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isBuildDefMatch) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "编译派生"
        受控属性 = "衍生方案声明 (build/default.yaml)"
        实机状态 = $actualBuildDefStatus
        期望基线 = "rime_ice"
        Purpose  = "检查 build/default.yaml 的 schema_list 是否声明 rime_ice"
        Impact   = "仅检查编译配置的方案声明，不代表输入法运行时已加载"
    })
}

# 5.13 衍生拼音 Prism 索引 (build/rime_ice.prism.bin)
$hasPrismBin = $buildStatus.PrismMatches
$actualPrismStatus = $buildStatus.PrismActual
$AuditBoard.Add([PSCustomObject]@{
    状态     = if ($hasPrismBin) { " ✔" } else { " ▲" }
    模块     = "配置"
    属性     = "衍生词库 Prism 索引 (build/rime_ice.prism.bin)"
    实机     = $actualPrismStatus
    基线     = "已就绪"
    状态判定 = if ($hasPrismBin) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $hasPrismBin) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "编译派生"
        受控属性 = "衍生词库 Prism 索引 (build/rime_ice.prism.bin)"
        实机状态 = $actualPrismStatus
        期望基线 = "已就绪"
        Purpose  = "调用 WeaselDeployer /deploy 编译生成二进制 prism 拼音查找树与词典索引"
        Impact   = "检查索引文件存在且大于 10KB，不验证二进制内容完整性"
    })
}

Write-Host "`n📊 [巡检看板] 小狼毫输入法受控属性基线审计清单:" -ForegroundColor Cyan
$AuditBoard | Select-Object 状态, 模块, 属性, 实机, 基线 | Format-Table -AutoSize | Out-String | Write-Host

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
function Assert-AppStopped {
    if (Get-Process -ErrorAction Stop | Where-Object ProcessName -in @('WeaselServer', 'WeaselDeployer', 'WeaselSetup')) {
        throw '小狼毫仍在运行，请切换输入法并自行退出小狼毫及部署工具后重新执行。'
    }
}
Assert-AppStopped

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
    if ($gateChoice -notin @('', 'Y', 'y', 'YES', 'yes', 'Q', 'q', 'QUIT', 'quit', 'N', 'n', 'NO', 'no')) {
        throw '无效授权输入；未执行本模块写入。'
    }
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 7. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 7.1 程序本体安装或覆盖升级
Assert-AppStopped
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

    Assert-AppStopped

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
        throw '小狼毫安装器在 90 秒内未退出；请确认安装结果后重试。'
    }
    if ($proc.ExitCode -ne 0) {
        throw "小狼毫安装程序异常退出 (退出码: $($proc.ExitCode))；未继续写入词库。"
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

if ((Get-RimeUserDirectory) -ine $ConfDir) {
    throw 'Weasel 实际用户目录在巡检后发生变化，未写入词库或补丁；请重新执行。'
}

# 7.2 部署雾凇拼音词库 (rime-ice)
Assert-AppStopped
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

        if (-not (Test-Path -LiteralPath $ConfDir)) {
            New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
        }

        Assert-AppStopped
        Copy-Item -Path "$unzippedDir\*" -Destination $ConfDir -Recurse -Force
        Write-Host "✅ 雾凇拼音词库资产已成功解压部署至: $ConfDir" -ForegroundColor Green
    } finally {
        if (Test-Path $iceZip) { Remove-Item -Path $iceZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $iceTemp) { Remove-Item -Path $iceTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# 7.3 注入声明式 YAML 补丁
Assert-AppStopped
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
if (Test-Path -LiteralPath $iceCustom) {
    Remove-Item -LiteralPath $iceCustom -Force -ErrorAction SilentlyContinue
}

# 7.4 调用 WeaselDeployer 编译部署
Write-Host "`n⚙️  正在调用 WeaselDeployer 进行词库编译与衍生状态收敛..." -ForegroundColor Cyan
if (-not $deployerExe -or -not (Test-Path -LiteralPath $deployerExe)) {
    $deployerExe = Find-WeaselExecutable -BaseDir $cleanInstallDir -ExeName "WeaselDeployer.exe"
}

if (-not $deployerExe) {
    throw '未定位到 WeaselDeployer.exe，无法完成衍生词库编译！'
}
Assert-AppStopped
Invoke-RimeDeployment -Deployer $deployerExe -Directory $ConfDir

# 7.5 用户输入法激活与系统显示语言原子收敛
Write-Host "`n⚙️  正在单向对齐当前用户输入法配置与中文语言环境 (WinUserLanguageList)..." -ForegroundColor Cyan
Set-RimeInputMethodActive -Status (Get-RimeInputMethodStatus)

$langPackCurrent = Get-RimeLanguagePackStatus
if (-not $langPackCurrent.IsCompliant) {
    Install-RimeLanguagePack
    Set-RimeInputMethodActive -Status (Get-RimeInputMethodStatus)
    Write-Information -Tags HumanHandoff -InformationAction Continue -MessageData '已安装简体中文语言包并锁定小狼毫为中文唯一输入法；请在部署完成后统一重启计算机以完全生效。'
}
Write-Host "✅ 当前用户输入法与显示语言已对齐：已激活小狼毫并排除系统自带微软拼音。" -ForegroundColor Green

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
Write-Host "   - 编译检查: /deploy 退出成功，rime_ice 方案声明与 Prism 文件大小检查通过；实际输入待验证" -ForegroundColor Gray
Write-Host "   - 语言环境: zh-CN 语言包已就绪且设为首选显示语言 (已排除语音手写按需功能)" -ForegroundColor Gray
Write-Host "   - 输入激活: WinUserLanguageList 已对齐小狼毫 (已排除系统自带微软拼音)" -ForegroundColor Gray
Write-Host "   - 切换按键: Control 接管中英切换 (Shift 设为 noop 防误触)" -ForegroundColor Gray
Write-Host "   - 视觉排版: 横向 5 候选词、DirectWrite 抗锯齿与 Win11 亚克力磨砂皮肤" -ForegroundColor Gray

return
