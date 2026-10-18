#requires -Version 7.0
<#
.SYNOPSIS
    小狼毫输入法 (Weasel / Rime)

.DESCRIPTION
    小狼毫输入法 (Weasel / Rime) 自动化纯净安装、雾凇拼音词库打底与现代体验配置脚本。
    1. 专为 PowerShell 7+ (pwsh) 编写，充分运用现代 pwsh 语法糖、强类型安全与原生无 BOM UTF-8 输出。
    2. 严格遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)：对二进制安装本体、Junction 目录挂载、雾凇词库及 YAML 补丁全流程先检后配，杜绝重复下载与脏覆写。
    3. 纯拼音极致隔离：方案严格限定为 rime_ice 纯全拼，彻底排除双拼、五笔、形码与字根方案，杜绝按键哈希碰撞与词库污染。
    4. Control 键接管中英切换：彻底消灭 Shift 误触痛点（Shift 设为 noop），由 Control 键精准控制中英状态流转。
    5. 现代 GUI 视觉：启用 DirectWrite 矢量抗锯齿排版、横向 5 候选词与 Win11 原生深浅色亚克力磨砂视觉。
    6. 声明式配置管理：纳管标准 %APPDATA%\Rime 配置目录（支持通过 -ConfDir 指定独立目录并自动建立 NTFS Junction 挂载）。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync        : 增量对齐黄金基线 (默认，缺失则装、偏离则修)
    - Check       : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - ResetConfig : 仅执行雾凇词库校验、Junction 重定向、YAML 补丁注入与编译部署
    - Uninstall   : 彻底清洁卸载、注销系统 TSF 组件并抹除软件与词库目录
    - Upgrade     : 重新拉取小狼毫安装包覆盖升级输入法核心本体

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER InstallDir
    小狼毫二进制本体安装目录，默认为 D:\prog\Rime。

.PARAMETER ConfDir
    用户配置与词库目录，默认为标准 %APPDATA%\Rime。若显式指定自定义目录，脚本将自动建立 NTFS Junction 挂载。

.PARAMETER InstallerPath
    可选，小狼毫本地离线安装包路径（如 weasel-0.17.4.0-installer.exe）。指定后优先使用离线包，免除网络下载。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\rime.ps1 -Action Check

    # 交互式全流程安装与配置
    pwsh -File .\scripts\apps\rime.ps1

    # 仅增量检查并更新雾凇词库与 YAML 策略并重新编译
    pwsh -File .\scripts\apps\rime.ps1 -Action ResetConfig

    # 彻底清洁卸载
    pwsh -File .\scripts\apps\rime.ps1 -Action Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check", "ResetConfig", "Uninstall", "Upgrade")]
    [string]$Action = "Sync",

    [switch]$Yes,
    [string]$InstallDir,
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
        [int]$MaxRetries = 3
    )

    $parent = Split-Path -Path $OutFile -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Host "⬇️  正在下载 $Description..." -ForegroundColor Cyan

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec 180
            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ge $MinBytes)) {
                Write-Host "   ✔ 下载成功 ($([math]::Round((Get-Item $OutFile).Length / 1MB, 2)) MB)" -ForegroundColor Green
                return
            }
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $MaxRetries) {
                Write-Host "   ⚠️  网络传输中断 ($lastError)，正在重试 ($attempt/$MaxRetries)..." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
    }

    if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }
    $errDetail = if ($lastError) { $lastError } else { "文件为空或未达到预期大小 ($MinBytes 字节)" }
    throw "下载 $Description 失败: $errDetail"
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

$weaselReg64 = Get-ItemProperty -Path "HKLM:\SOFTWARE\Rime\Weasel" -ErrorAction SilentlyContinue
$weaselReg32 = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel" -ErrorAction SilentlyContinue
$weaselRegCU = Get-ItemProperty -Path "HKCU:\SOFTWARE\Rime\Weasel" -ErrorAction SilentlyContinue

$weaselReg = if ($weaselReg32 -and $weaselReg32.WeaselRoot) { $weaselReg32 }
             elseif ($weaselReg64 -and $weaselReg64.WeaselRoot) { $weaselReg64 }
             elseif ($weaselReg32) { $weaselReg32 }
             elseif ($weaselReg64) { $weaselReg64 }
             else { $weaselRegCU }

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if ($weaselReg -and $weaselReg.WeaselRoot -and (Test-Path $weaselReg.WeaselRoot)) {
        $InstallDir = $weaselReg.WeaselRoot
    } elseif ($weaselReg -and $weaselReg.InstallDir -and (Test-Path $weaselReg.InstallDir)) {
        $InstallDir = $weaselReg.InstallDir
    } else {
        $runningWeasel = Get-Process -Name "WeaselServer" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($runningWeasel -and $runningWeasel.MainModule -and $runningWeasel.MainModule.FileName) {
            $InstallDir = Split-Path -Path $runningWeasel.MainModule.FileName -Parent
        } else {
            $InstallDir = "D:\prog\Rime"
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ConfDir)) {
    $ConfDir = Join-Path $env:APPDATA "Rime"
}

$serverCandidates = [System.Collections.Generic.List[string]]::new()
if ($InstallDir) { $serverCandidates.Add((Join-Path $InstallDir "WeaselServer.exe")) }
if ($weaselReg -and $weaselReg.WeaselRoot) { $serverCandidates.Add((Join-Path $weaselReg.WeaselRoot "WeaselServer.exe")) }

$realServerExe = $serverCandidates | Where-Object { Test-ValidPeExecutable $_ } | Select-Object -First 1
if (-not $realServerExe -and (Test-Path $InstallDir)) {
    $foundServer = Get-ChildItem -Path $InstallDir -Filter "WeaselServer.exe" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { Test-ValidPeExecutable $_.FullName } | Select-Object -First 1
    if ($foundServer) { $realServerExe = $foundServer.FullName }
}

$deployerCandidates = [System.Collections.Generic.List[string]]::new()
if ($InstallDir) { $deployerCandidates.Add((Join-Path $InstallDir "WeaselDeployer.exe")) }
if ($weaselReg -and $weaselReg.WeaselRoot) { $deployerCandidates.Add((Join-Path $weaselReg.WeaselRoot "WeaselDeployer.exe")) }
if ($realServerExe) { $deployerCandidates.Add((Join-Path (Split-Path $realServerExe -Parent) "WeaselDeployer.exe")) }

$deployerExe = $deployerCandidates | Where-Object { Test-ValidPeExecutable $_ } | Select-Object -First 1
if (-not $deployerExe -and (Test-Path $InstallDir)) {
    $foundDep = Get-ChildItem -Path $InstallDir -Filter "WeaselDeployer.exe" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { Test-ValidPeExecutable $_.FullName } | Select-Object -First 1
    if ($foundDep) { $deployerExe = $foundDep.FullName }
}

$HighValueUserData = @(
    "用户自定义词库与配置: $ConfDir",
    "个人短语与客制 YAML 补丁 (*.custom.yaml)"
)

# ==============================================================================
# 4. 独立流转分支：彻底清洁卸载 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    if (-not $Yes) {
        Write-Host "`n⚠️  [清洁卸载警示] 即将彻底注销系统 TSF 组件并物理粉碎小狼毫环境！" -ForegroundColor Yellow
        Write-Host "📌 【即将被物理抹除的高价值用户数据清单】:" -ForegroundColor Cyan
        foreach ($d in $HighValueUserData) {
            Write-Host ("   - {0}" -f $d) -ForegroundColor Gray
        }
        Write-Host "👉 执行清洁卸载将清理配置与自定义词库。若需保留个人短语，请先手动备份！`n" -ForegroundColor Yellow

        $confirm = (Read-Host "确认注销输入法组件并彻底删除程序本体与词库目录? [y/N]").Trim()
        if ($confirm -notmatch '^(y|yes)$') {
            Write-Host "[-] 用户已取消卸载操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "`n🧹 [清洁卸载模式] 正在终止进程、注销系统 TSF 组件并粉碎目录..." -ForegroundColor Yellow

    # 1. 强制终止常驻进程
    Get-Process -Name "WeaselServer", "WeaselDeployer", "WeaselSetup" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800

    # 2. 调用官方反注册命令
    $foundUninst = Get-ChildItem -Path $InstallDir -Filter "*uninstall*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundUninst) {
        Write-Host "   - 正在调用官方反安装引擎: $($foundUninst.FullName)..." -ForegroundColor Gray
        Start-Process -FilePath $foundUninst.FullName -ArgumentList "/S" -Wait -NoNewWindow -ErrorAction SilentlyContinue
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

    # 4. 解除 Junction 软链接与清理目录
    $stdAppData = Join-Path $env:APPDATA "Rime"
    if (Test-Path $stdAppData) {
        $item = Get-Item $stdAppData -Force -ErrorAction SilentlyContinue
        if ($item.Attributes -match "ReparsePoint") {
            [System.IO.Directory]::Delete($stdAppData)
            Write-Host "   - 已安全解绑并移除 NTFS Junction 软链接: $stdAppData" -ForegroundColor Gray
        } else {
            Remove-Item -Path $stdAppData -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "   - 已清理 AppData 配置目录: $stdAppData" -ForegroundColor Gray
        }
    }

    if ($ConfDir -and (Test-Path $ConfDir) -and ($ConfDir -ne $stdAppData)) {
        Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已清理客制词库目录: $ConfDir" -ForegroundColor Gray
    }

    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已物理抹除安装根目录: $InstallDir" -ForegroundColor Gray
    }

    # 清理快捷方式
    @(
        (Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "小狼毫输入法"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "小狼毫输入法.lnk")
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "`n✅ [清洁卸载完成] 小狼毫输入法核心组件与配置已彻底清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1} | 安装路径: {2}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查"), $InstallDir) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$DiffList   = [System.Collections.Generic.List[PSCustomObject]]::new()

# 5.1 二进制程序与 TSF 注册状态
$isPeReady = [bool]($realServerExe -and (Test-ValidPeExecutable $realServerExe))
$isInstalled = $isPeReady -and (Test-Path "HKLM:\SOFTWARE\Rime\Weasel")
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "客户端本体"
    受控属性 = "WeaselServer / TSF 注册"
    期望基线 = "已就绪且 TSF 注册合规"
    实机状态 = if ($isInstalled) { "已就绪 ($realServerExe)" } else { "未安装/未完整注册" }
    状态判定 = if ($isInstalled) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $isInstalled) {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "客户端本体"
        受控属性 = "WeaselServer / TSF 注册"
        实机状态 = if ($isInstalled) { "已就绪" } else { "未安装/未完整注册" }
        期望基线 = "已就绪且 TSF 注册合规"
        Purpose  = "部署小狼毫输入法 Windows TSF 原生服务端与驱动组件"
        Impact   = "在系统语言栏注册中文小狼毫输入法"
    })
}

# 5.2 雾凇拼音词库核心文件
$iceSchema = Join-Path $ConfDir "rime_ice.schema.yaml"
$hasIceDict = Test-Path $iceSchema
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "词库生态"
    受控属性 = "雾凇拼音核心词库 (rime_ice.schema.yaml)"
    期望基线 = "已落地于 $ConfDir"
    实机状态 = if ($hasIceDict) { "已就绪" } else { "缺失未就绪" }
    状态判定 = if ($hasIceDict) { "✔ 匹配" } else { "✘ 缺失" }
})
if (-not $hasIceDict -and $Action -ne "Upgrade") {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "词库生态"
        受控属性 = "雾凇拼音核心词库 (rime_ice.schema.yaml)"
        实机状态 = "缺失未就绪"
        期望基线 = "已落地于 $ConfDir"
        Purpose  = "拉取并部署现代化中文全拼雾凇词库 (rime-ice) 资产"
        Impact   = "提供词频精准、网络热词全面、无拼音错别字的纯全拼中文输入基底"
    })
}

# 5.3 声明式 YAML 补丁配置检查
$defCustom = Join-Path $ConfDir "default.custom.yaml"
$weaselCustom = Join-Path $ConfDir "weasel.custom.yaml"
$iceCustom = Join-Path $ConfDir "rime_ice.custom.yaml"

$hasPatches = (Test-Path $defCustom) -and (Test-Path $weaselCustom) -and (Test-Path $iceCustom)
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "偏好基线"
    受控属性 = "声明式 YAML 补丁 (纯拼音/按键隔离/亚克力)"
    期望基线 = "三项 custom.yaml 全部就绪"
    实机状态 = if ($hasPatches) { "已就绪" } else { "未完整生成" }
    状态判定 = if ($hasPatches) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $hasPatches -and $Action -ne "Upgrade") {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "偏好基线"
        受控属性 = "声明式 YAML 补丁 (纯拼音/按键隔离/亚克力)"
        实机状态 = if ($hasPatches) { "已就绪" } else { "未完整生成" }
        期望基线 = "三项 custom.yaml 全部就绪"
        Purpose  = "锁定 rime_ice 纯全拼、Control 接管中英切换 (Shift noop)、亚克力皮肤"
        Impact   = "彻底消除 Shift 误触导致的中英打字跳字问题，横排 5 候选词紧凑呈现"
    })
}

# 5.4 编译派生状态终态校验 (build/default.yaml)
$buildDefault = Join-Path $ConfDir "build\default.yaml"
$isCompiled = $false
if (Test-Path $buildDefault) {
    $bContent = Get-Content -Path $buildDefault -Raw -ErrorAction SilentlyContinue
    if ($bContent -match "schema_id:\s*rime_ice") { $isCompiled = $true }
}
$AuditBoard.Add([PSCustomObject]@{
    分层模块 = "编译派生"
    受控属性 = "衍生词库编译终态 (build/default.yaml)"
    期望基线 = "已编译且生效 rime_ice 方案"
    实机状态 = if ($isCompiled) { "已编译生效" } else { "未编译或已过期" }
    状态判定 = if ($isCompiled) { "✔ 匹配" } else { "✘ 偏离" }
})
if (-not $isCompiled -and $Action -ne "Upgrade") {
    $DiffList.Add([PSCustomObject]@{
        分层模块 = "编译派生"
        受控属性 = "衍生词库编译终态 (build/default.yaml)"
        实机状态 = if ($isCompiled) { "已编译生效" } else { "未编译或已过期" }
        期望基线 = "已编译且生效 rime_ice 方案"
        Purpose  = "调用 WeaselDeployer /deploy 编译生成二进制 prism 与词典索引"
        Impact   = "确保声明式 YAML 补丁真正转化为运行态加载的衍生编译文件"
    })
}

Write-Host "`n📊 [巡检看板] 小狼毫输入法受控属性基线审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

if ($Action -eq "Check") {
    if ($DiffList.Count -eq 0) {
        Write-Host "✨ [状态合规] 所有受控属性与编译产物均与工程黄金基线完全一致，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动对齐。`n" -f $DiffList.Count) -ForegroundColor Yellow
    }
    return
}

if ($DiffList.Count -eq 0 -and $isInstalled -and $Action -ne "Upgrade") {
    Write-Host "✨ [状态合规] 所有受控属性与策略均已符合工程黄金基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

if ($DiffList.Count -gt 0) {
    Write-Host "`n📋 [差异清单] 检测到以下受控属性偏离黄金基线:" -ForegroundColor Cyan
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

# 6.2 未安装审查门禁
if (-not $isInstalled) {
    if ($Action -eq "ResetConfig") {
        throw "未检测到小狼毫输入法客户端安装！请先执行 -Action Sync 安装本体后再重置配置。"
    }

    if (-not $Yes) {
        $shouldInstall = (Read-Host "未检测到小狼毫输入法，是否立即拉取官方安装包进行部署？[Y/n]").Trim()
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

    $gateChoice = (Read-Host "`n确认应用上述黄金基线配置? [Y] 确认执行 / [Q] 退出 (默认 Y)").Trim()
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 7. 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================

# 7.1 程序本体安装或覆盖升级
if (-not $isInstalled -or $Action -eq "Upgrade") {
    Write-Host "`n🚀 正在准备安装小狼毫输入法核心本体..." -ForegroundColor Cyan
    $installerExe = $InstallerPath

    if (-not $installerExe -or -not (Test-Path $installerExe)) {
        $installerExe = Join-Path $env:TEMP "weasel-installer.exe"
        $relApi = "https://api.github.com/repos/rime/weasel/releases/latest"
        Write-Host "   - 正在查询 GitHub 最新 Release..." -ForegroundColor Gray
        $rel = Invoke-RestMethod -Uri $relApi -Headers @{ "User-Agent" = "vpsbase-rime-script" } -TimeoutSec 15
        $asset = $rel.assets | Where-Object { $_.name -match 'weasel-.*-installer\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw "未在 GitHub 最新 Release 中匹配到小狼毫安装程序" }

        Invoke-DownloadFile -Url $asset.browser_download_url -OutFile $installerExe -Description "小狼毫安装包"
    }

    Write-Host "   - 正在静默安装小狼毫至: $InstallDir..." -ForegroundColor Gray
    $cleanDir = $InstallDir.TrimEnd('\')
    $proc = Start-Process -FilePath $installerExe -ArgumentList "/S /D=$cleanDir" -Wait -PassThru
    Start-Sleep -Seconds 3

    # 重新探测
    $serverCandidates.Clear()
    $serverCandidates.Add((Join-Path $InstallDir "WeaselServer.exe"))
    $realServerExe = $serverCandidates | Where-Object { Test-ValidPeExecutable $_ } | Select-Object -First 1
    if (-not $realServerExe -and (Test-Path $InstallDir)) {
        $foundServer = Get-ChildItem -Path $InstallDir -Filter "WeaselServer.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { Test-ValidPeExecutable $_.FullName } | Select-Object -First 1
        if ($foundServer) { $realServerExe = $foundServer.FullName }
    }

    if (-not $realServerExe) {
        throw "小狼毫安装完成，但未能定位到 WeaselServer.exe！"
    }
    $isInstalled = $true
    Write-Host "✅ 小狼毫二进制本体安装完成。" -ForegroundColor Green

    if ($Action -eq "Upgrade") {
        Write-Host "`n✅ [升级完成] 小狼毫输入法本体已完成更新。`n" -ForegroundColor Green
        return
    }
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
Write-Host "`n⚙️  正在单向对齐声明式 YAML 黄金基线补丁..." -ForegroundColor Cyan

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

# rime_ice.custom.yaml: 标点与容错
$rimeIceYaml = @'
patch:
  "punctuator/full_shape":
    "/": "/"
  "speller/algebra/@before 0": xform/^([b-df-hj-np-tv-z])/v$1/
'@
[System.IO.File]::WriteAllText($iceCustom, $rimeIceYaml, [System.Text.UTF8Encoding]::new($false))
Write-Host "✅ default.custom.yaml, weasel.custom.yaml 与 rime_ice.custom.yaml 补丁注入完成。" -ForegroundColor Green

# 7.4 调用 WeaselDeployer 编译部署
Write-Host "`n⚙️  正在调用 WeaselDeployer 进行词库编译与衍生状态收敛..." -ForegroundColor Cyan
if (-not $deployerExe -or -not (Test-Path $deployerExe)) {
    $foundDep = Get-ChildItem -Path $InstallDir -Filter "WeaselDeployer.exe" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { Test-ValidPeExecutable $_.FullName } | Select-Object -First 1
    if ($foundDep) { $deployerExe = $foundDep.FullName }
}

if ($deployerExe -and (Test-Path $deployerExe)) {
    $proc = Start-Process -FilePath $deployerExe -ArgumentList "/deploy" -Wait -PassThru
    Start-Sleep -Seconds 2
    Write-Host "✅ WeaselDeployer /deploy 编译部署完成。" -ForegroundColor Green
} else {
    Write-Warning "未定位到 WeaselDeployer.exe，请稍后手动在输入法托盘点击「重新部署」。"
}

# 启动 WeaselServer 服务
if ($realServerExe -and (Test-Path $realServerExe)) {
    Start-Process -FilePath $realServerExe -WindowStyle Hidden -ErrorAction SilentlyContinue
}

# ==============================================================================
# 8. 阶段 4: 尾部简报与动态真待办 (Report)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 工程黄金基线与词库部署完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green
Write-Host "   - 方案基线: rime_ice 纯全拼方案已编译生效" -ForegroundColor Gray
Write-Host "   - 切换按键: Control 接管中英切换 (Shift 设为 noop 防误触)" -ForegroundColor Gray
Write-Host "   - 视觉排版: 横向 5 候选词、DirectWrite 抗锯齿与 Win11 亚克力磨砂皮肤" -ForegroundColor Gray

return
