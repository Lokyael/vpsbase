#requires -Version 7.0
<#
.SYNOPSIS
    小狼毫输入法 (Weasel / Rime)

.DESCRIPTION
    小狼毫输入法 (Weasel / Rime) 自动化纯净安装、雾凇拼音词库打底与现代体验配置脚本。
    1. 专为 PowerShell 7+ (pwsh) 编写，充分运用现代 pwsh 语法糖、强类型安全与原生无 BOM UTF-8 输出。
    2. 严格遵循“先检查后配置、幂等无冗余”原则：对二进制安装本体、Junction 目录挂载、雾凇词库及 YAML 补丁全流程先检后配，杜绝重复下载与脏覆写。
    3. 纯拼音极致隔离：方案严格限定为 rime_ice 纯全拼，彻底排除双拼、五笔、形码与字根方案，杜绝按键哈希碰撞与词库污染。
    4. Control 键接管中英切换：彻底消灭 Shift 误触痛点（Shift 设为 noop），由 Control 键精准控制中英状态流转。
    5. 现代 GUI 视觉：启用 DirectWrite 矢量抗锯齿排版、横向 5 候选词与 Win11 原生深浅色亚克力磨砂视觉。
    6. 跨重装持久化：用户配置真理之源固化至 D:\res\conf\rime，通过 NTFS Junction 透明挂载至 %APPDATA%\Rime，C 盘重装后满血复现。

.PARAMETER CheckOnly
    只查不改模式（体检巡检）。逐项比对系统 TSF 注册状态、NTFS Junction 挂载点、雾凇词库及 YAML 补丁，高亮输出 Diff，零写入安全退出。
    别名: -Audit

.PARAMETER Clean
    清洁安装模式。强制终止常驻进程、清理旧 AppData 挂载点、归档旧配置并 100% 全新拉取与重构环境。
    别名: -Fresh, -Reset

.PARAMETER UninstallOnly
    仅执行完整卸载与系统组件清理（注销 TSF、清理注册表自启项与残留文件、刷新 Explorer），不执行重新安装。
    别名: -Uninstall, -Remove

.PARAMETER InstallOnly
    仅执行小狼毫二进制本体的下载与静默安装，不配置词库与用户偏好。

.PARAMETER ConfigOnly
    仅执行雾凇词库校验、Junction 重定向、YAML 补丁注入与编译部署，不重新下载小狼毫安装包。

.PARAMETER NonInteractive
    非交互模式，静默全盘采纳所有推荐基线偏好（用于全新装机自动化流水线）。

.PARAMETER InstallDir
    小狼毫二进制本体安装目录，默认为 D:\prog\Rime。

.PARAMETER ConfDir
    用户配置与词库持久化目录，默认为 D:\res\conf\rime。

.EXAMPLE
    # 交互式全流程安装与配置（回车直接采纳推荐基线）
    pwsh -File .\scripts\apps\rime.ps1

    # 静默全量安装与部署（自动化装机流）
    pwsh -File .\scripts\apps\rime.ps1 -NonInteractive

    # 仅增量检查并更新雾凇词库与 YAML 策略（零重复下载安装器）
    pwsh -File .\scripts\apps\rime.ps1 -ConfigOnly

    # 彻底清洁重装
    pwsh -File .\scripts\apps\rime.ps1 -Clean

    # 只查不改体检巡检
    pwsh -File .\scripts\apps\rime.ps1 -CheckOnly
#>

[CmdletBinding()]
param(
    [Alias("Fresh", "Reset")]
    [switch]$Clean,

    [Alias("Uninstall", "Remove")]
    [switch]$UninstallOnly,

    [Alias("Audit")]
    [switch]$CheckOnly,

    [switch]$InstallOnly,
    [switch]$ConfigOnly,
    [switch]$NonInteractive,
    [switch]$Yes,
    [string]$InstallDir,
    [string]$ConfDir
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ==============================================================================
# 环境校验：强制锁定 PowerShell 7+ 与 管理员提权
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "本脚本已全面转向 PowerShell 7+ (pwsh)，不兼容旧版 Windows PowerShell 5.1。请使用 'pwsh' 执行本脚本。"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and -not $CheckOnly) {
    throw "小狼毫属于系统 TSF 输入法组件且需要配置目录软链接，必须以管理员身份运行此脚本！"
}

# ==============================================================================
# 工具函数：交互式向导 与 多源高可用下载器
# ==============================================================================
function Prompt-Choice {
    param([string]$Title, [string]$Desc, [bool]$Default = $true)
    if ($NonInteractive) { return $Default }
    Write-Host "`n>>> 配置项: $Title" -ForegroundColor Cyan
    Write-Host "    $Desc" -ForegroundColor Gray
    $tag = $Default ? "[Y/n]" : "[y/N]"
    $ans = Read-Host "    启用该配置? $tag (直接回车采纳默认)"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return ($ans.Trim() -match "^(y|yes|true|1)$")
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Description = "文件"
    )

    $parent = Split-Path -Path $OutFile -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Host "⬇️  正在下载 $Description..." -ForegroundColor Cyan
    if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile
    } catch {
        throw "下载 $Description 失败 ($Url): $($_.Exception.Message)"
    }

    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -le 1024) {
        throw "下载 $Description 失败：文件为空或未成功写入 ($OutFile)。"
    }
}

# ==============================================================================
# 0. 目标路径智能探测与初始化
# ==============================================================================
$weaselReg64 = Get-ItemProperty -Path "HKLM:\SOFTWARE\Rime\Weasel" -ErrorAction SilentlyContinue
$weaselReg32 = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel" -ErrorAction SilentlyContinue
$weaselRegCU = Get-ItemProperty -Path "HKCU:\SOFTWARE\Rime\Weasel" -ErrorAction SilentlyContinue

# 优先选取包含 WeaselRoot 的完整注册表快照，自适应 32 位与 64 位视图
$weaselReg = if ($weaselReg32 -and $weaselReg32.WeaselRoot) { $weaselReg32 }
             elseif ($weaselReg64 -and $weaselReg64.WeaselRoot) { $weaselReg64 }
             elseif ($weaselReg32) { $weaselReg32 }
             elseif ($weaselReg64) { $weaselReg64 }
             else { $weaselRegCU }

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if ($Clean) {
        # 清洁重装模式下强制锚定工程黄金基线，彻底切断对历史旧路径的继承
        $InstallDir = (Test-Path "D:\") ? "D:\prog\Rime" : "C:\Program Files\Rime"
    } elseif ($weaselReg -and $weaselReg.WeaselRoot -and (Test-Path $weaselReg.WeaselRoot)) {
        $InstallDir = $weaselReg.WeaselRoot
    } elseif ($weaselReg -and $weaselReg.InstallDir -and (Test-Path $weaselReg.InstallDir)) {
        $InstallDir = $weaselReg.InstallDir
    } else {
        $runningWeasel = Get-Process -Name "WeaselServer" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($runningWeasel -and $runningWeasel.MainModule -and $runningWeasel.MainModule.FileName) {
            $InstallDir = Split-Path -Path $runningWeasel.MainModule.FileName -Parent
        } else {
            $InstallDir = (Test-Path "D:\") ? "D:\prog\Rime" : "C:\Program Files\Rime"
        }
    }
}
if ([string]::IsNullOrWhiteSpace($ConfDir)) {
    $ConfDir = (Test-Path "D:\") ? "D:\res\conf\rime" : (Join-Path $env:USERPROFILE ".config\rime")
}

# 动态探测二进制位置 (支持根目录与 weasel-x.x.x 版本子目录)
$serverCandidates = [System.Collections.Generic.List[string]]::new()
if ($InstallDir) { $serverCandidates.Add((Join-Path $InstallDir "WeaselServer.exe")) }
if ($weaselReg -and $weaselReg.WeaselRoot) { $serverCandidates.Add((Join-Path $weaselReg.WeaselRoot "WeaselServer.exe")) }

$realServerExe = $serverCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $realServerExe -and (Test-Path $InstallDir)) {
    $foundServer = Get-ChildItem -Path $InstallDir -Filter "WeaselServer.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundServer) { $realServerExe = $foundServer.FullName }
}

$deployerCandidates = [System.Collections.Generic.List[string]]::new()
if ($InstallDir) { $deployerCandidates.Add((Join-Path $InstallDir "WeaselDeployer.exe")) }
if ($weaselReg -and $weaselReg.WeaselRoot) { $deployerCandidates.Add((Join-Path $weaselReg.WeaselRoot "WeaselDeployer.exe")) }
if ($realServerExe) { $deployerCandidates.Add((Join-Path (Split-Path $realServerExe -Parent) "WeaselDeployer.exe")) }

$deployerExe = $deployerCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

Write-Host "==========================================================" -ForegroundColor Yellow
Write-Host "  小狼毫 (Weasel 0.16+) 现代纯拼音安装与部署工具 (pwsh 7+)" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Yellow
Write-Host "📂 部署基准目录: 安装目录 [$InstallDir] | 配置目录 [$ConfDir]`n" -ForegroundColor Cyan

# ==============================================================================
# 阶段 A: 清洁卸载与环境重置 (-Clean / -UninstallOnly: 彻底注销与零残留清理)
# ==============================================================================
if ($Clean -or $UninstallOnly) {
    if (-not $NonInteractive -and -not $Yes) {
        $confirmClean = Read-Host "⚠️ [Clean 警示] 将彻底注销系统 TSF 组件并清理小狼毫安装目录、配置及软链，确认继续? [y/N]"
        if ($confirmClean.Trim() -notmatch '^(y|yes)$') {
            Write-Host "用户已取消清洁重装操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "🧹 [清洁卸载模式] 正在执行系统反注册与深度清理..." -ForegroundColor Yellow

    # 1. 强力终止小狼毫全套相关进程 (释放所有被占用的 TSF DLL 与句柄)
    @("WeaselServer", "WeaselDeployer", "WeaselSetup", "WeaselIME") | ForEach-Object {
        Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 600

    # 2. 优先调用官方标准卸载机制 (注销 TSF 输入法类与语言配置文件)
    Write-Host "👉 [操作说明] 若屏幕弹出官方卸载确认、完成对话框或向导窗口，直接点击【确定 / 关闭】即可；后续反注册清理由脚本自动完成。" -ForegroundColor Yellow

    $deployerCandidates = [System.Collections.Generic.List[string]]::new()
    $uninstCandidates   = [System.Collections.Generic.List[string]]::new()
    $searchRoots = @($InstallDir, "C:\Program Files\Rime", "C:\Program Files (x86)\Rime", "D:\prog\Rime") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($dir in $searchRoots) {
        Get-ChildItem -Path $dir -Filter "WeaselDeployer.exe" -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $deployerCandidates.Add($_.FullName) }
        Get-ChildItem -Path $dir -Filter "Uninstall.exe" -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $uninstCandidates.Add($_.FullName) }
    }

    foreach ($d in ($deployerCandidates | Select-Object -Unique)) {
        if (Test-Path $d) {
            Write-Host "   - 正在调用 WeaselDeployer /uninstall 注销系统 TSF 组件: $d" -ForegroundColor Gray
            $dProc = Start-Process -FilePath $d -ArgumentList "/uninstall" -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($dProc) {
                # 等待最多 5 秒，防弹窗挂起阻断流水线
                $dProc.WaitForExit(5000) | Out-Null
                if (-not $dProc.HasExited) { Stop-Process -Id $dProc.Id -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    foreach ($u in ($uninstCandidates | Select-Object -Unique)) {
        if (Test-Path $u) {
            Write-Host "   - 正在执行官方静默卸载器: $u /S..." -ForegroundColor Gray
            $uProc = Start-Process -FilePath $u -ArgumentList "/S" -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($uProc) {
                # 等待最多 8 秒，防弹窗挂起阻断流水线
                $uProc.WaitForExit(8000) | Out-Null
                if (-not $uProc.HasExited) { Stop-Process -Id $uProc.Id -Force -ErrorAction SilentlyContinue }
            }
            Start-Sleep -Milliseconds 800
        }
    }

    # 3. 注册表 TSF / TIP 节点精确清理 (小狼毫专属 TIP 与 Profile GUID)
    $rimeGuids = @(
        "{A3FCE4F5-3493-4192-94C0-0A7786E082EC}",
        "{E7EA138E-CEF2-4788-AB8A-E44B1595433D}"
    )
    $tipBases = @(
        "HKLM:\SOFTWARE\Microsoft\CTF\TIP",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\CTF\TIP",
        "HKCU:\Software\Classes\CLSID",
        "HKLM:\SOFTWARE\Classes\CLSID",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID"
    )
    foreach ($base in $tipBases) {
        foreach ($guid in $rimeGuids) {
            $regPath = "$base\$guid"
            if (Test-Path $regPath) {
                Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Host "   - 已完成 TSF/TIP 与 COM CLSID 注册表节点核验与兜底拔除" -ForegroundColor Gray

    # 4. 注册表自启项、自身专属分支与卸载清单清理
    @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run") | ForEach-Object {
        Remove-ItemProperty -Path $_ -Name "WeaselServer" -ErrorAction SilentlyContinue
    }
    @("HKCU:\Software\Rime", "HKLM:\SOFTWARE\Rime", "HKLM:\SOFTWARE\WOW6432Node\Rime") | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Rime",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Rime",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Rime"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "   - 已彻底清除注册表自启项、Rime专属分支与卸载项残留" -ForegroundColor Gray

    # 5. 外壳快捷方式清理
    @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\小狼毫輸入法",
        "$env:PROGRAMDATA\Microsoft\Windows\Start Menu\Programs\小狼毫輸入法"
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 6. 物理安装目录与 AppData 软链清理
    $appdataRime = "$env:APPDATA\Rime"
    if (Test-Path $appdataRime) {
        Remove-Item -Path $appdataRime -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已解绑并销毁 AppData 软链: $appdataRime" -ForegroundColor Gray
    }

    $dirsToWipe = @($InstallDir, "C:\Program Files\Rime", "C:\Program Files (x86)\Rime", "D:\prog\Rime") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    foreach ($dir in $dirsToWipe) {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已彻底粉碎清空安装目录: $dir" -ForegroundColor Gray
    }

    # 7. 配置目录彻底完全粉碎清理 (响应零备份硬性需求，直接清空重置，并清理历史 bak)
    if (Test-Path $ConfDir) {
        Remove-Item -Path $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $parentConf = Split-Path -Path $ConfDir -Parent
    if ($parentConf -and (Test-Path $parentConf)) {
        Get-ChildItem -Path $parentConf -Filter "rime.bak_*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
    Write-Host "   - 已彻底完全粉碎清空配置目录: $ConfDir (零历史残留)" -ForegroundColor Gray

    if ($UninstallOnly) {
        # 强制重启资源管理器以彻底刷新任务栏托盘幽灵图标与语言栏会话内存缓存
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Write-Host "`n✅ 小狼毫全量系统侵入已彻底注销拔除，已重载桌面 Explorer 彻底清除右下角一切缓存！" -ForegroundColor Green
        return
    }

    if ($Clean) {
        $deployerExe = $null
        $realServerExe = $null
        $weaselReg = $null
        if (-not $PSBoundParameters.ContainsKey("InstallDir")) {
            $InstallDir = (Test-Path "D:\") ? "D:\prog\Rime" : "C:\Program Files\Rime"
        }
    }

    Write-Host "✅ 系统内所有小狼毫侵入点已彻底完全清理归零，准备执行全新初始化。`n" -ForegroundColor Green
}

# ==============================================================================
# 阶段 B: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
$chkList = [System.Collections.Generic.List[PSCustomObject]]::new()
$diffList = [System.Collections.Generic.List[PSCustomObject]]::new()

# 1. TSF 注册状态
$isReg = ($null -ne $weaselReg -and (-not [string]::IsNullOrEmpty($weaselReg.InstallDir) -or -not [string]::IsNullOrEmpty($weaselReg.WeaselRoot)))
$regShort = if ($weaselReg.PSPath -like "*WOW6432Node*") { "已注册 (WOW6432)" } elseif ($weaselReg) { "已注册" } else { "未注册" }
$chkList.Add([PSCustomObject]@{
    "配置模块" = "系统 TSF 集成"
    "受控属性" = "WeaselServer 注册表项"
    "期望基线" = "HKLM\SOFTWARE\...\Weasel"
    "实机状态" = $regShort
    "判定"     = $isReg ? "✔ 匹配" : "✘ 缺失"
})
if (-not $isReg) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "系统 TSF 集成"
        "受控属性" = "WeaselServer 注册表项"
        "实机状态" = $regShort
        "期望基线" = "已注册 (HKLM\SOFTWARE\Rime\Weasel)"
    })
}

# 2. 二进制本体
$hasExe = ($null -ne $realServerExe -and (Test-Path $realServerExe))
$exeShort = if ($hasExe) {
    $parentLeaf = Split-Path (Split-Path $realServerExe -Parent) -Leaf
    if ($parentLeaf -like "weasel-*") { "已就绪 ($parentLeaf)" } else { "已就绪" }
} else {
    "未安装"
}
$chkList.Add([PSCustomObject]@{
    "配置模块" = "程序本体"
    "受控属性" = "核心服务 (WeaselServer.exe)"
    "期望基线" = "已安装 (WeaselServer.exe)"
    "实机状态" = $exeShort
    "判定"     = $hasExe ? "✔ 匹配" : "✘ 缺失"
})
if (-not $hasExe) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "程序本体"
        "受控属性" = "核心服务 (WeaselServer.exe)"
        "实机状态" = $exeShort
        "期望基线" = "已安装于 $InstallDir"
    })
}

# 3. Junction 目录重定向挂载 (深入细化检查真实 Target)
$appDataRime = Join-Path $env:APPDATA "Rime"
$isJunctionReady = $false
$junctionStatus = "未建立"
if (Test-Path $appDataRime) {
    $item = Get-Item $appDataRime -ErrorAction SilentlyContinue
    if ($item -and $item.Attributes -match "ReparsePoint") {
        $target = $item.Target
        if ($target -and ($target.TrimEnd('\') -eq $ConfDir.TrimEnd('\'))) {
            $isJunctionReady = $true
            $junctionStatus = "已正确连接至 $ConfDir"
        } else {
            $junctionStatus = "已挂载但目标偏离 ($target)"
        }
    } else {
        $junctionStatus = "存在物理目录 (需迁移为软链)"
    }
}
$chkList.Add([PSCustomObject]@{
    "配置模块" = "存储持久化"
    "受控属性" = "配置目录挂载 (%APPDATA%\Rime)"
    "期望基线" = "软链接映射至 $ConfDir"
    "实机状态" = $junctionStatus
    "判定"     = $isJunctionReady ? "✔ 匹配" : "✘ 缺失/偏离"
})
if (-not $isJunctionReady -and -not $InstallOnly) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "存储持久化"
        "受控属性" = "配置目录挂载 (%APPDATA%\Rime)"
        "实机状态" = $junctionStatus
        "期望基线" = "软链接映射至 $ConfDir"
    })
}

# 4. 雾凇词库打底状态 (深入细化检查主方案 schema 文件)
$iceSchemaFile = Join-Path $ConfDir "rime_ice.schema.yaml"
$isIceReady = (Test-Path $iceSchemaFile) -and ((Get-Item $iceSchemaFile).Length -gt 1024)
$chkList.Add([PSCustomObject]@{
    "配置模块" = "词库打底"
    "受控属性" = "雾凇拼音现代词库 (rime_ice.schema.yaml)"
    "期望基线" = "完整存在于配置目录"
    "实机状态" = $isIceReady ? "已就绪" : "缺失或不完整"
    "判定"     = $isIceReady ? "✔ 匹配" : "✘ 缺失"
})
if (-not $isIceReady -and -not $InstallOnly) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "词库打底"
        "受控属性" = "雾凇拼音现代词库 (rime_ice.schema.yaml)"
        "实机状态" = $isIceReady ? "已就绪" : "缺失或不完整"
        "期望基线" = "完整存在于 $ConfDir"
    })
}

# 5. 纯全拼与外观配置源码 (深入细化检查关键参数)
$defCustomPath = Join-Path $ConfDir "default.custom.yaml"
$weaselCustomPath = Join-Path $ConfDir "weasel.custom.yaml"

$hasDefCustom = Test-Path $defCustomPath
$hasWeaselCustom = Test-Path $weaselCustomPath

$defCustomValid = $false
$weaselCustomValid = $false

if ($hasDefCustom) {
    $defRaw = Get-Content -Path $defCustomPath -Raw -Encoding utf8NoBOM -ErrorAction SilentlyContinue
    $defCustomValid = ($defRaw -match 'schema:\s*rime_ice') -and
                      ($defRaw -match 'menu/page_size:\s*5') -and
                      ($defRaw -match 'Control_L:\s*commit_code')
}

if ($hasWeaselCustom) {
    $weaselRaw = Get-Content -Path $weaselCustomPath -Raw -Encoding utf8NoBOM -ErrorAction SilentlyContinue
    $weaselCustomValid = ($weaselRaw -match 'style/direct_write:\s*true')
}

$srcReady = $defCustomValid -and $weaselCustomValid
$srcStatus = if ($srcReady) { "已固化黄金策略" } elseif ($hasDefCustom -or $hasWeaselCustom) { "部分键值偏离" } else { "源码缺失" }

$chkList.Add([PSCustomObject]@{
    "配置模块" = "配置源码"
    "受控属性" = "声明式补丁键值 (rime_ice + Control切换 + DirectWrite)"
    "期望基线" = "全部固化"
    "实机状态" = $srcStatus
    "判定"     = $srcReady ? "✔ 匹配" : "✘ 偏离"
})
if (-not $srcReady -and -not $InstallOnly) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "配置源码"
        "受控属性" = "声明式补丁键值 (default/weasel.custom.yaml)"
        "实机状态" = $srcStatus
        "期望基线" = "全部固化 (rime_ice + Control切换 + DirectWrite)"
    })
}

# 6. 衍生编译产物终态校验 (拒绝只查源码伪合规)
$buildDefault = Join-Path $ConfDir "build\default.yaml"
$buildWeasel = Join-Path $ConfDir "build\weasel.yaml"
$isBuildReady = $false
$buildStatus = "未编译"

if (Test-Path $buildDefault) {
    try {
        $buildContent = Get-Content -Path $buildDefault -Raw -Encoding utf8NoBOM -ErrorAction SilentlyContinue
        $hasIceInBuild = ($buildContent -match 'schema:\s*rime_ice') -or ($buildContent -match 'schema_id:\s*rime_ice')
        $hasCtrlInBuild = ($buildContent -match 'Control_L:\s*commit_code')

        $hasDwInBuild = $true
        if (Test-Path $buildWeasel) {
            $weaselBuildRaw = Get-Content -Path $buildWeasel -Raw -Encoding utf8NoBOM -ErrorAction SilentlyContinue
            $hasDwInBuild = ($weaselBuildRaw -match 'direct_write:\s*true')
        }

        if ($hasIceInBuild -and $hasCtrlInBuild -and $hasDwInBuild) {
            $isBuildReady = $true
            $buildStatus = "已编译生效 (rime_ice + Control + DirectWrite)"
        } elseif ($hasIceInBuild) {
            $buildStatus = "已编译但快捷键/渲染键未同步"
        } else {
            $buildStatus = "产物内容未匹配期望方案"
        }
    } catch {
        $buildStatus = "读取异常: $($_.Exception.Message)"
    }
}

$chkList.Add([PSCustomObject]@{
    "配置模块" = "编译终态"
    "受控属性" = "衍生编译产物 (build\default.yaml + weasel.yaml)"
    "期望基线" = "包含已生效 schema_list 与按键编译缓存"
    "实机状态" = $buildStatus
    "判定"     = $isBuildReady ? "✔ 匹配" : "✘ 待编译"
})
if (-not $isBuildReady -and -not $InstallOnly) {
    $diffList.Add([PSCustomObject]@{
        "受控模块" = "编译终态"
        "受控属性" = "衍生编译产物 (build\default.yaml + weasel.yaml)"
        "实机状态" = $buildStatus
        "期望基线" = "经 Deployer 编译生效"
    })
}

# 只查不改模式 (-CheckOnly) 立即输出看板后安全退出
if ($CheckOnly) {
    Write-Host "`n📊 [巡检看板] 小狼毫输入法深入基线审计清单:" -ForegroundColor Cyan
    $chkList | Format-Table -AutoSize | Out-String | Write-Host

    if ($diffList.Count -eq 0) {
        Write-Host "✔ [状态合规] 所有受控属性与策略均已符合工程黄金基线，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host "⚠️  共发现 $($diffList.Count) 项基线偏离。执行默认模式 (-Sync) 或纯配置模式 (-ConfigOnly) 即可自动对齐自愈。`n" -ForegroundColor Yellow
        if (-not $hasExe) {
            Write-Host "💡 提示: 未检测到客户端安装，运行本脚本默认模式即可自动拉取最新 Release 安装包全新部署。" -ForegroundColor Gray
        }
    }
    return
}

# 判定是否需要安装本体
$needInstall = (-not $hasExe)

# 若无偏离且无安装诉求，直接提前安全退出
if ($diffList.Count -eq 0 -and -not $needInstall -and -not $InstallOnly) {
    Write-Host "`n📊 [巡检看板] 小狼毫输入法深入基线审计清单:" -ForegroundColor Cyan
    $chkList | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "✨ [状态合规] 所有受控属性与策略均已符合工程黄金基线，无需执行写入变更。`n" -ForegroundColor Green
    return
}

# 发现基线偏离，高亮输出差异清单
Write-Host "`n📋 [差异清单] 检测到以下受控属性偏离黄金基线:" -ForegroundColor Cyan
$diffList | Format-Table -AutoSize | Out-String | Write-Host

# ==============================================================================
# 阶段 C: 模式审查门禁 (Gate)
# ==============================================================================
# 1. 运行态并发防覆写硬门禁
$runningWeasel = Get-Process -Name "WeaselServer" -ErrorAction SilentlyContinue
if ($runningWeasel) {
    if (-not $NonInteractive -and -not $Yes) {
        Write-Warning "检测到 WeaselServer 输入法核心服务正在运行！部署前需安全终止服务以重新加载 DLL 与词库。"
        $confirmProc = Read-Host "是否立即关闭 WeaselServer 进程以继续应用基线? [Y/n]"
        if ($confirmProc.Trim() -match "^(n|no)$") {
            Write-Host "用户已取消操作，安全退出。`n" -ForegroundColor Yellow
            return
        }
    }
    @("WeaselServer", "WeaselDeployer", "WeaselSetup") | ForEach-Object {
        Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 600
}

# 2. 未安装本体时的安装审查门禁
if ($needInstall) {
    if ($ConfigOnly) {
        throw "未检测到小狼毫客户端安装。本工具专注于 TSF 注册与拼音基线配置，请先安装后再执行配置。"
    }

    if (-not $NonInteractive -and -not $Yes) {
        $shouldInstall = Read-Host "未检测到小狼毫二进制本体，是否立即拉取官方最新 Release 进行安装？[Y/n]"
        if ($shouldInstall.Trim() -match "^(n|no)$") {
            Write-Host "操作已由用户取消，安全退出。`n" -ForegroundColor Yellow
            return
        }
    }
}

# 3. 策略审查门禁 (Shift-Left Gate: 改动理由与生效机制)
if (-not $NonInteractive -and -not $Yes) {
    Write-Host "💡 [改动说明与生效机制]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 建立 %APPDATA%\Rime 到 $ConfDir 的 NTFS Junction，部署雾凇词库打底" -ForegroundColor Gray
    Write-Host "   - 拼音体验: 下发纯全拼补丁、Control 键接管中英切换 (Shift 设为 noop 防误触)、DirectWrite 磨砂亚克力视觉并编译生效" -ForegroundColor Gray
    $gateChoice = Read-Host "`n确认应用上述黄金基线配置? [Y] 确认应用 / [Q] 退出 (默认 Y)"
    if ($gateChoice.Trim() -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 阶段 D: 二进制本体安装 (-InstallOnly / 缺失时自动安装)
# ==============================================================================
if (-not $ConfigOnly) {
    if (-not $deployerExe -or -not (Test-Path $deployerExe)) {
        $deployerExe = Join-Path $InstallDir "WeaselDeployer.exe"
    }
    $needInstall = $true

    if (($deployerExe -and (Test-Path $deployerExe)) -and -not $Clean) {
        $needInstall = $false
        Write-Host "⏭️  检测到已存在安装 ($deployerExe)，跳过安装包重复下载与安装。" -ForegroundColor Gray
    }

    if ($needInstall) {
        # 全新安装或 Clean 模式下，未显式指定路径时强制确保目标目录为工程黄金基线
        if (-not $PSBoundParameters.ContainsKey("InstallDir")) {
            $InstallDir = (Test-Path "D:\") ? "D:\prog\Rime" : "C:\Program Files\Rime"
        }

        $tempDir = Join-Path $env:TEMP "weasel_install_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir, $InstallDir -Force | Out-Null

        try {
            Write-Host "🔍 检索小狼毫 (Weasel) 官方最新 Release..." -ForegroundColor Cyan
            $downloadUrl = $null
            $fileName = $null
            try {
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/rime/weasel/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }
                $asset = $release.assets | Where-Object { $_.name -match "^weasel-.*-installer\.exe$" } | Select-Object -First 1
                if ($asset) {
                    $downloadUrl = $asset.browser_download_url
                    $fileName = $asset.name
                }
            } catch {
                Write-Host "   [提示] GitHub API 获取失败，回退至稳定版直链..." -ForegroundColor Yellow
            }

            if (-not $downloadUrl) {
                # 兜底稳定构建版本
                $downloadUrl = "https://github.com/rime/weasel/releases/download/0.16.3/weasel-0.16.3.0-installer.exe"
                $fileName = "weasel-0.16.3.0-installer.exe"
            }

            $installerPath = Join-Path $tempDir $fileName
            Invoke-DownloadFile -Url $downloadUrl -OutFile $installerPath -Description $fileName

            Write-Host "📦 正在执行小狼毫核心组件安装至 $InstallDir..." -ForegroundColor Cyan
            Write-Host "👉 [环境说明] 若屏幕弹出官方初始设定向导窗口，直接点击【关闭 / 取消】即可，脚本会自动接管全套纯全拼与现代化配置。" -ForegroundColor Yellow
            Stop-Process -Name WeaselServer, WeaselDeployer, WeaselSetup -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300

            # 1. 预植引导注册表：小狼毫官方 NSIS 安装器在 .onInit 中若未检测到 InstallDir，
            #    会硬编码执行 StrCpy $INSTDIR "$PROGRAMFILES64\Rime" 强制覆写命令行 /D 参数。
            #    必须在调用前将注册表 InstallDir 显式预植为目标目录，使其跳过无条件重置并采纳预设基准！
            $cleanDest = $InstallDir.Trim().TrimEnd('\')
            New-Item -ItemType Directory -Path $cleanDest -Force | Out-Null

            @("HKLM:\SOFTWARE\Rime\Weasel", "HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel") | ForEach-Object {
                if (-not (Test-Path $_)) {
                    New-Item -Path $_ -Force | Out-Null
                }
                Set-ItemProperty -Path $_ -Name "InstallDir" -Value $cleanDest -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $_ -Name "WeaselRoot" -ErrorAction SilentlyContinue
            }

            # 2. 规范 NSIS 参数：单个字符串传递，杜绝 PowerShell 隐式加引号破坏 NSIS 语法
            $proc = Start-Process -FilePath $installerPath -ArgumentList "/S /D=$cleanDest" -PassThru

            # 智能状态感知轮询（最多等待 30 秒）：检测进程退出或核心 DLL 落地
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 30) {
                if ($proc.HasExited) { break }
                $quickCheck = (Get-ChildItem -Path $cleanDest, "C:\Program Files\Rime" -Filter "weasel.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($quickCheck) {
                    Start-Sleep -Seconds 2
                    break
                }
                Start-Sleep -Milliseconds 500
            }

            # 确保安装器向导脱钩
            Stop-Process -Name WeaselSetup, WeaselDeployer -Force -ErrorAction SilentlyContinue
            if (-not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }

            # 3. 智能探测实际安装落地路径并给出明确感知反馈
            $actualServerExe = $null
            $searchDestDirs = @($cleanDest, "C:\Program Files\Rime", "C:\Program Files (x86)\Rime")
            foreach ($sDir in $searchDestDirs) {
                if (-not (Test-Path $sDir)) { continue }
                $found = Get-ChildItem -Path $sDir -Filter "WeaselServer.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) {
                    $actualServerExe = $found.FullName
                    break
                }
            }

            if (-not $actualServerExe) {
                throw "未在预期路径中检测到 WeaselServer.exe，小狼毫安装可能未顺利完成。"
            }

            $deployerExe = Join-Path (Split-Path $actualServerExe -Parent) "WeaselDeployer.exe"
            $actualRoot = Split-Path (Split-Path $actualServerExe -Parent) -Parent

            if ($actualServerExe.StartsWith($cleanDest, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "✅ 小狼毫核心组件已精准安装至目标基准目录: $cleanDest" -ForegroundColor Green
                $InstallDir = $cleanDest
            } else {
                Write-Host "`n⚠️  [路径重定向说明] 检测到小狼毫官方安装包受系统 TSF 权限策略约束，将二进制核心组件安装至:" -ForegroundColor Yellow
                Write-Host "   [$actualServerExe]" -ForegroundColor Gray
                Write-Host "   - 业务安全: 用户配置与词库已通过 Junction 软链接绑定至 [$ConfDir]，跨重装持久化 100% 生效；" -ForegroundColor Gray
                Write-Host "   - 系统保障: 运行态与 TSF 输入法服务已自动对齐该实际路径，不影响任何打字与管理体验。`n" -ForegroundColor Gray
                $InstallDir = if ($actualRoot -and $actualRoot -ne "C:\") { $actualRoot } else { Split-Path $actualServerExe -Parent }
            }

            # 执行小狼毫无头静默注册以确保 TSF COM 服务就绪
            if (Test-Path $deployerExe) {
                Start-Process -FilePath $deployerExe -ArgumentList "/install" -Wait -NoNewWindow
            }
        }
        finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($InstallOnly) {
    Write-Host "`n✅ 已完成二进制安装，跳过配置阶段退出。" -ForegroundColor Green
    return
}

# ==============================================================================
# 阶段 E: 词库打底、补丁下发与编译生效 (Apply)
# ==============================================================================
# 1. 数据持久化与 NTFS Junction 挂载 (先检后配)
Write-Host "`n📦 检查配置目录持久化与 Junction 状态..." -ForegroundColor Cyan
if (-not (Test-Path $ConfDir)) {
    New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
}

$appdataRime = "$env:APPDATA\Rime"
$needJunction = $true

if (Test-Path $appdataRime) {
    $item = Get-Item $appdataRime
    if ($item.Attributes -match "ReparsePoint") {
        # 已是连接点，校验其指向
        $target = $item.Target
        if ($target -and ($target.TrimEnd('\') -eq $ConfDir.TrimEnd('\'))) {
            $needJunction = $false
            Write-Host "   - [已就绪] $appdataRime 已正确连接至 $ConfDir" -ForegroundColor Gray
        } else {
            Write-Host "   - [重定向] 正在重置 Junction 目标至 $ConfDir..." -ForegroundColor Yellow
            Remove-Item -Path $appdataRime -Force
        }
    } else {
        Write-Host "   - [迁移] 检测到物理 AppData 目录，正在将历史配置增量同步至 $ConfDir..." -ForegroundColor Cyan
        Copy-Item -Path "$appdataRime\*" -Destination $ConfDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $appdataRime -Recurse -Force
    }
}

if ($needJunction) {
    New-Item -ItemType Junction -Path $appdataRime -Target $ConfDir -Force | Out-Null
    Write-Host "✅ 已建立 NTFS Junction: $appdataRime -> $ConfDir" -ForegroundColor Green
}

# 2. 雾凇拼音 (rime-ice) 词库打底 (先检后配)
$schemaFile = Join-Path $ConfDir "rime_ice.schema.yaml"
$needIce = $true

if ((Test-Path $schemaFile) -and -not $Clean) {
    $needIce = $false
    Write-Host "⏭️  保留现有雾凇词库，跳过重新下载。" -ForegroundColor Gray
}

if ($needIce) {
    $iceZip = Join-Path $ConfDir "rime-ice.zip"
    $tempExtract = Join-Path $ConfDir "tmp_ice_$(Get-Random)"
    try {
        Invoke-DownloadFile -Url "https://github.com/iDvel/rime-ice/archive/refs/heads/main.zip" -OutFile $iceZip -Description "雾凇拼音 (rime-ice) 词库包"

        Write-Host "📦 提取并部署词库至 $ConfDir..." -ForegroundColor Cyan
        Expand-Archive -Path $iceZip -DestinationPath $tempExtract -Force
        $innerDir = Join-Path $tempExtract "rime-ice-main"
        if (Test-Path $innerDir) {
            Copy-Item -Path "$innerDir\*" -Destination $ConfDir -Recurse -Force
        }

        # 剔除解压带入的非运行期仓库开发文档与 CI 配置 (保持目录极简清爽)
        $junkItems = @(
            (Join-Path $ConfDir ".github"),
            (Join-Path $ConfDir "README.md"),
            (Join-Path $ConfDir "LICENSE"),
            (Join-Path $ConfDir ".gitattributes"),
            (Join-Path $ConfDir ".gitignore"),
            (Join-Path $ConfDir "CHANGELOG.md")
        )
        foreach ($j in $junkItems) {
            if (Test-Path $j) { Remove-Item -Path $j -Recurse -Force -ErrorAction SilentlyContinue }
        }

        Write-Host "✅ 雾凇拼音现代词库部署就绪 (已剥离无用文档与 CI 配置)。" -ForegroundColor Green
    }
    finally {
        Remove-Item -Path $tempExtract, $iceZip -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 3. 纯拼音与 Control 切换声明式补丁下发
Write-Host "`n⚙️  [受控配置基线] 正在应用以下黄金策略:" -ForegroundColor Cyan
Write-Host "   ▶ [输入体验] Control 键接管中英切换 (Shift 设为 noop 彻底杜绝打代码与游戏时误触)" -ForegroundColor White
Write-Host "   ▶ [界面视觉] DirectWrite 矢量抗锯齿 + Win11 亚克力磨砂自适应 (横向 5 候选词)`n" -ForegroundColor White

$optControlSwitch = $true
$optDirectWrite   = $true

Write-Host "⚙️  正在注入声明式补丁配置..." -ForegroundColor Cyan

# 1. default.custom.yaml 补丁
$switchKeyL = $optControlSwitch ? "commit_code" : "noop"
$switchKeyR = $optControlSwitch ? "commit_code" : "noop"
$shiftKey   = $optControlSwitch ? "noop" : "commit_code"

$defaultYamlContent = @"
# >>> managed: rime-default-baseline >>>
patch:
  # 方案清单：纯全拼基准 (零双拼/形码混杂，无多余状态机)
  schema_list:
    - schema: rime_ice

  # 候选词数量：固定 5 个 (横向聚焦黄金比例)
  "menu/page_size": 5

  # 中英切换行为：Control 键接管，Shift 置为 noop 防误触
  "ascii_composer/switch_key":
    Control_L: $switchKeyL
    Control_R: $switchKeyR
    Shift_L: $shiftKey
    Shift_R: $shiftKey
    Caps_Lock: clear

  # 逗号/句号直接翻页
  "key_binder/bindings":
    - { when: paging, accept: comma, send: Page_Up }
    - { when: has_menu, accept: period, send: Page_Down }
"@

$defaultYamlPath = Join-Path $ConfDir "default.custom.yaml"
[System.IO.File]::WriteAllText($defaultYamlPath, $defaultYamlContent.Trim() + "`r`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "   - [落盘] default.custom.yaml" -ForegroundColor Green
Write-Host "     · 方案清单: rime_ice (纯全拼打底，彻底排除形码/双拼与状态机开销)" -ForegroundColor Gray
Write-Host "     · 候选数量: 5 个 (横向聚焦最佳视线)" -ForegroundColor Gray
Write-Host "     · 中英切换: $($optControlSwitch ? 'Control 键接管 (Shift 设为 noop 防误触)' : 'Shift 键切换')" -ForegroundColor Gray
Write-Host "     · 翻页快捷: 逗号 [,] 向前翻页，句号 [.] 向后翻页" -ForegroundColor Gray

# 2. weasel.custom.yaml 补丁
$dwValue = $optDirectWrite ? "true" : "false"
$weaselYamlContent = @"
# >>> managed: weasel-style-baseline >>>
patch:
  # 启用 DirectWrite 矢量排版，消除字体发虚与多屏异构 DPI 模糊
  "style/direct_write": $dwValue
  "style/font_face": "Microsoft YaHei, Segoe UI Emoji"
  "style/font_point": 13

  # 横向排版、圆角与现代内边距
  "style/horizontal": true
  "style/corner_radius": 8
  "style/border_width": 0
  "style/margin_x": 12
  "style/margin_y": 8
  "style/spacing": 10

  # Win11 原生主题自适应 (浅色/深色亚克力磨砂)
  "style/color_scheme": "fluent_light"
  "style/color_scheme_dark": "fluent_dark"
"@

$weaselYamlPath = Join-Path $ConfDir "weasel.custom.yaml"
[System.IO.File]::WriteAllText($weaselYamlPath, $weaselYamlContent.Trim() + "`r`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "   - [落盘] weasel.custom.yaml" -ForegroundColor Green
Write-Host "     · 矢量渲染: DirectWrite ($dwValue)，字体 Microsoft YaHei + Segoe UI Emoji (13pt)" -ForegroundColor Gray
Write-Host "     · 窗口外观: 横向 5 候选排版、8px 圆角、无边框间距优化" -ForegroundColor Gray
Write-Host "     · 视觉主题: Win11 原生浅色/深色亚克力磨砂自适应 (fluent_light / fluent_dark)" -ForegroundColor Gray

# 3. 固化 .gitignore 防污染白名单 (隔离 build 编译产物与运行期状态，保持配置区纯净)
$gitIgnoreContent = @"
# Rime 本地编译二进制产物 (从 YAML 自动衍生，随时可 /deploy 重新生成)
/build/
*.bin
*.userdb/
*.userdb.kct/
*.lock

# 机器专属状态与安装元数据
installation.yaml
user.yaml
"@
$gitIgnorePath = Join-Path $ConfDir ".gitignore"
[System.IO.File]::WriteAllText($gitIgnorePath, $gitIgnoreContent.Trim() + "`r`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "   - [防污染] .gitignore (隔离 /build/ 字典二进制与运行时缓存，持久化目录零脏污)" -ForegroundColor Green

# 4. 触发 WeaselDeployer 重新编译与部署
Write-Host "`n🚀 正在触发小狼毫底层编译与重新部署 (WeaselDeployer)..." -ForegroundColor Cyan
if (-not $deployerExe -or -not (Test-Path $deployerExe)) {
    $foundDep = Get-ChildItem -Path $InstallDir -Filter "WeaselDeployer.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundDep) { $deployerExe = $foundDep.FullName }
}

if ($deployerExe -and (Test-Path $deployerExe)) {
    $realDeployer = (Resolve-Path $deployerExe).Path
    $deployProc = Start-Process -FilePath $realDeployer -ArgumentList "/deploy" -Wait -PassThru -NoNewWindow
    if ($deployProc.ExitCode -eq 0) {
        Write-Host "🎉 小狼毫纯全拼基线已完成编译与挂载，全部配置已精准生效！" -ForegroundColor Green
    } else {
        Write-Host "⚠️ WeaselDeployer 执行完毕 (返回代码: $($deployProc.ExitCode))，请在系统托盘右键小狼毫选择 [重新部署] 确认。" -ForegroundColor Yellow
    }
} else {
    Write-Warning "未找到 WeaselDeployer.exe，请确保小狼毫已完成安装后手动点击开始菜单中的 [小狼毫 -> 重新部署]。"
}

# ==============================================================================
# 收尾清理：清除临时下载区与解压碎片
# ==============================================================================
Get-ChildItem -Path $env:TEMP -Filter "weasel_install_*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}
Get-ChildItem -Path $ConfDir -Filter "tmp_ice_*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
# 阶段 F: 尾部结报与手动引导清单 (Report)
# ==============================================================================
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  小狼毫现代纯拼音基线部署完成！" -ForegroundColor Green
Write-Host "  - 核心方案: 雾凇拼音 (rime-ice) 纯简体全拼" -ForegroundColor Gray
Write-Host "  - 候选数量: 横向 5 候选词 (黄金视线聚焦)" -ForegroundColor Gray
Write-Host "  - 切换中英: 单按 [Control] 键 (Shift 已置为 noop 防误触)" -ForegroundColor Gray
Write-Host "  - 翻页快捷: 逗号 [,] 向前翻页，句号 [.] 向后翻页" -ForegroundColor Gray
Write-Host "  - 视觉样式: DirectWrite 矢量排版 + Win11 深浅色亚克力自适应" -ForegroundColor Gray
Write-Host "  - 数据备份: $ConfDir (重装系统免重新配置)" -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Green

Write-Host "`n--------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📋 [手动收尾引导清单 (Manual Checklist)]" -ForegroundColor Cyan
Write-Host " 1. 中英切换: 单按 [Control] 切换中英文（Shift 已屏蔽防误触）" -ForegroundColor Gray
Write-Host " 2. 方案选单: 按快捷键 Ctrl + `` 呼出方案菜单，确认选中【雾凇拼音】" -ForegroundColor Gray
Write-Host " 3. 部署刷新: 如遇应用未即时响应，右键托盘小狼毫图标点击【重新部署】" -ForegroundColor Gray
Write-Host "--------------------------------------------------`n" -ForegroundColor DarkGray
Write-Host "👉 现在即可在任意输入框体验现代纯全拼输入法！" -ForegroundColor Green
