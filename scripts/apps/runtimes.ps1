#requires -Version 7.0
<#
.SYNOPSIS
    系统基础运行库

.DESCRIPTION
    Windows 11 桌面与应用底层三大通用运行库声明式校验与自动化补齐工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 只读扫描本机 64 位与 32 位卸载表、.NET 共享程序集与 WebView2 核心目录，高精度探测运行库落地与版本状态。
    3. 涵盖三大核心基础依赖：
       - Visual C++ 2015-2022 Redistributable (x64 与 x86 成对运行库)；
       - .NET 10.0 Desktop Runtime (x64 最新 LTS 桌面运行时)；
       - Microsoft Edge WebView2 Runtime (Evergreen 独立常青渲染运行时)。
    4. 依托官方包管理器 winget 实施非破坏性增量补齐（静默、免交互授权协议）。
    5. 具备终态确定性二次校验与 Fail-Fast 硬阻断保障，确保应用底层动态链接库与渲染底座 100% 就绪。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量补齐缺失的基础运行库 (默认，缺失则装)
    - Check     : 只查不改体检巡检 (零写入)
    - Uninstall : 运行库安全保护阻断 (底层共享依赖禁止自动化粉碎)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制重新调用包管理器安装/更新最新版本运行库。

.PARAMETER Purge
    预留参数契约 (运行库属于共享依赖，不触碰数据)。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\runtimes.ps1 -Action Check

    # 交互式检查并增量补齐运行库
    pwsh -File .\scripts\apps\runtimes.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\apps\runtimes.ps1 -Yes

    # 强制重新拉取/升级全部运行库
    pwsh -File .\scripts\apps\runtimes.ps1 -Force
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
    throw "【权限错误】系统底层基础运行库补齐需管理员特权，请在提升的 pwsh 会话中重新执行！"
}

# ==============================================================================
# 2. 应用元数据与辅助函数
# ==============================================================================
$AppId   = "runtimes"
$AppName = "系统基础运行库 (VC++ / .NET / WebView2)"

function Get-RuntimeInventory {
    $inventory = [ordered]@{}

    # 1. 查询 64 位与 32 位卸载表
    $uninstKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $uninstEntries = Get-ChildItem -Path $uninstKeys -ErrorAction SilentlyContinue |
                     ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue }

    # 1.1 VC++ 2015-2022 x64
    $vc64Entry = $uninstEntries | Where-Object { $_.DisplayName -match "Visual C\+\+ 2015-.*x64" } | Select-Object -First 1
    $inventory["vc64"] = [PSCustomObject]@{
        Name      = "Visual C++ 2015-2022 Redistributable (x64)"
        Installed = ($null -ne $vc64Entry)
        Version   = if ($vc64Entry) { ($vc64Entry.DisplayVersion ?? "已安装") } else { "未安装" }
        WingetId  = "Microsoft.VCRedist.2015+.x64"
        Purpose   = "装配 64 位 C/C++ 核心动态链接库运行底座 (MSVCP140.dll 等)"
        Impact    = "保障现代 64 位原生应用（如 Python、Rust 工具、输入法）正常链接运行"
    }

    # 1.2 VC++ 2015-2022 x86
    $vc86Entry = $uninstEntries | Where-Object { $_.DisplayName -match "Visual C\+\+ 2015-.*x86" } | Select-Object -First 1
    $inventory["vc86"] = [PSCustomObject]@{
        Name      = "Visual C++ 2015-2022 Redistributable (x86)"
        Installed = ($null -ne $vc86Entry)
        Version   = if ($vc86Entry) { ($vc86Entry.DisplayVersion ?? "已安装") } else { "未安装" }
        WingetId  = "Microsoft.VCRedist.2015+.x86"
        Purpose   = "装配 32 位 C/C++ 核心动态链接库兼容底座"
        Impact    = "保障部分依然依赖 32 位底层组件的第三方工具、游戏或安装器正常启动"
    }

    # 2. 查询 .NET 10.0 Desktop Runtime
    $net10Base = "C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App"
    $net10Dirs = if (Test-Path $net10Base) {
        Get-ChildItem -Path $net10Base -Directory -Filter "10.*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    } else { $null }
    $net10Installed = ($net10Dirs -and $net10Dirs.Count -gt 0)
    $net10Ver = if ($net10Installed) { $net10Dirs[0].Name } else { "未安装" }
    $inventory["net10"] = [PSCustomObject]@{
        Name      = ".NET 10.0 Desktop Runtime (x64)"
        Installed = $net10Installed
        Version   = $net10Ver
        WingetId  = "Microsoft.DotNet.DesktopRuntime.10"
        Purpose   = "装配微软最新 .NET 10 LTS 桌面应用程序运行时框架"
        Impact    = "为现代 C# / WPF / WinForms 桌面客户端提供高性能托管运行环境"
    }

    # 3. 查询 Microsoft Edge WebView2 Runtime
    $wv2Installed = $false
    $wv2Ver = "未安装"
    $wv2Key = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -Name "pv" -ErrorAction SilentlyContinue).pv
    if (-not $wv2Key) {
        $wv2Key = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -Name "pv" -ErrorAction SilentlyContinue).pv
    }
    if ($wv2Key -and $wv2Key -ne "0.0.0.0") {
        $wv2Installed = $true
        $wv2Ver = $wv2Key
    } else {
        $wv2Dir = "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"
        if (Test-Path $wv2Dir) {
            $sub = Get-ChildItem -Path $wv2Dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.' } | Sort-Object Name -Descending | Select-Object -First 1
            if ($sub) {
                $wv2Installed = $true
                $wv2Ver = $sub.Name
            }
        }
    }
    $inventory["wv2"] = [PSCustomObject]@{
        Name      = "Microsoft Edge WebView2 Runtime (Evergreen)"
        Installed = $wv2Installed
        Version   = $wv2Ver
        WingetId  = "Microsoft.EdgeWebView2Runtime"
        Purpose   = "装配独立常青版 Chromium 渲染运行时底座"
        Impact    = "支持微信、飞书、QQ、输入法等第三方应用内嵌网页交互渲染，完全解耦于 Edge 浏览器本体"
    }

    return $inventory
}

# ==============================================================================
# 3. 独立流转分支：清洁卸载安全阻断 (-Action Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    Write-Warning "【安全保护阻断】基础运行库为系统多个桌面应用与系统的底层共享运行时依赖！"
    Write-Warning "强行自动化卸载会导致依赖这些运行库的应用（如浏览器、输入法、终端等）全部崩溃瘫痪。"
    Write-Host "💡 若确需移除特定运行库，请前往系统【设置 -> 应用 -> 安装的应用】中手动选择卸载。`n" -ForegroundColor Yellow
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与差异呈现 (Plan & Diff)
# ==============================================================================
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  应用生命周期管理与基线巡检: $AppName (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 授权放行: {1}" -f $Action, ($Yes ? "自动放行 (-Yes)" : "交互审查")) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$inv = Get-RuntimeInventory
$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$DiffList   = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($key in $inv.Keys) {
    $item = $inv[$key]
    $AuditBoard.Add([PSCustomObject]@{
        分层模块 = "底层运行库"
        受控属性 = $item.Name
        期望基线 = "已就绪"
        实机状态 = if ($item.Installed) { "已安装 ($($item.Version))" } else { "未安装" }
        状态判定 = if ($item.Installed) { "✔ 匹配" } else { "✘ 缺失" }
    })

    if (-not $item.Installed -or $Force) {
        $DiffList.Add([PSCustomObject]@{
            Key       = $key
            Name      = $item.Name
            WingetId  = $item.WingetId
            Installed = $item.Installed
            Version   = $item.Version
            Purpose   = $item.Purpose
            Impact    = $item.Impact
        })
    }
}

Write-Host "`n📊 [巡检看板] 系统底层运行库基线审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

# 检查模式立即安全退出
if ($Action -eq "Check") {
    $missingCount = ($DiffList | Where-Object { -not $_.Installed }).Count
    if ($missingCount -eq 0) {
        Write-Host "✨ [状态合规] 三大核心运行库均已完整就绪，无需补齐。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项核心运行库缺失。执行默认模式 (-Action Sync) 即可自动补齐。`n" -f $missingCount) -ForegroundColor Yellow
    }
    return
}

$missingItems = @($DiffList | Where-Object { -not $_.Installed })
if ($missingItems.Count -eq 0 -and -not $Force) {
    Write-Host "✨ [状态合规] 三大核心运行库均已在机就绪，无需安装补齐。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁 (Gate - Shift-Left: 目的与影响结构化直出)
# ==============================================================================
$targetItems = if ($Force) { $DiffList } else { $missingItems }

if (-not $Yes) {
    Write-Host "`n💡 [改动意图与技术边界审查 (Gate)]" -ForegroundColor Cyan
    Write-Host "   本次即将对齐以下偏离项，请逐项评估改动 [目的] 与 [影响]:" -ForegroundColor Gray
    $idx = 1
    foreach ($m in $targetItems) {
        Write-Host ("`n   [{0}] {1} [{2}]" -f $idx, $m.Name, $m.WingetId) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: 已安装" -f ($m.Installed ? "已安装 ($($m.Version))" : "未安装")) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $m.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $m.Impact) -ForegroundColor Gray
        $idx++
    }
    $gateChoice = (Read-Host "`n确认对齐上述运行库组件? [Y] 确认执行 / [Q] 退出 (默认 Y)").Trim()
    if ($gateChoice -match '^(q|quit|n|no)$') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 6. 阶段 3: 单向原子补齐 (Apply)
# ==============================================================================
if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
    throw "未检测到 winget 命令！Windows 11 应用安装程序 (App Installer) 缺失，无法执行自动补齐。"
}

$wingetArgsBase = @(
    "--exact",
    "--silent",
    "--accept-package-agreements",
    "--accept-source-agreements",
    "--disable-interactivity"
)

foreach ($m in $targetItems) {
    Write-Host "`n🚀 正在对齐运行库: $($m.Name)..." -ForegroundColor Cyan
    $args = if ($Force -and $m.Installed) {
        @("upgrade", "--id", $m.WingetId) + $wingetArgsBase
    } else {
        @("install", "--id", $m.WingetId) + $wingetArgsBase
    }

    try {
        & winget.exe @args
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010 -or $LASTEXITCODE -eq -1978335189) {
            Write-Host "   ✔ $($m.Name) 对齐成功" -ForegroundColor Green
        } else {
            Write-Host "   ✘ $($m.Name) 对齐失败 (ExitCode: $LASTEXITCODE)" -ForegroundColor Red
        }
    } catch {
        Write-Host "   ✘ $($m.Name) 执行异常: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ==============================================================================
# 7. 阶段 4: 终态校验与尾部简报 (Report)
# ==============================================================================
$afterInv = Get-RuntimeInventory
$stillMissing = [System.Collections.Generic.List[string]]::new()
foreach ($k in $afterInv.Keys) {
    if (-not $afterInv[$k].Installed) {
        $stillMissing.Add($afterInv[$k].Name)
    }
}

Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host "  ✅ [$AppName] 运行库环境基线对齐完成！" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green

if ($stillMissing.Count -gt 0) {
    throw "运行库补齐后仍有以下组件未就绪: $($stillMissing -join ', ')。请检查网络连接或手动安装。"
} else {
    Write-Host "✨ 全部三大基础运行库底座均已 100% 就绪。`n" -ForegroundColor Green
}

return
