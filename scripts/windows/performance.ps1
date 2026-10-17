#requires -Version 7.0
<#
.SYNOPSIS
    硬件调度与性能底层基准

.DESCRIPTION
    Windows 11 硬件底层调度、电源计划巡检、快速启动禁用与系统基础运行库补齐模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线。
    2. 巡检活动电源计划（锁定平衡方案，杜绝单核睿频被压制与待机积热）与 HAGS 状态。
    3. 禁用快速启动（彻底关机，杜绝内核驱动脏缓存跨重启污染）。
    4. 解除 MAX_PATH 260 字符长路径限制，禁用 NTFS 写入访问时间戳。
    5. SysMain 硬件门禁检测与停用（满足 NVMe SSD + >=16GB 内存时停用后台预读）。
    6. 大内存工作站优化（物理内存 >= 32GB 时停用 MMAgent 内存压缩与页面合并以释放算力）。
    7. 固化硬件时钟为 UTC (RealTimeIsUniversal) 并禁用自动时区，消除双系统/装机时钟漂移。
    8. 校验并依托 winget 补齐系统底层三大运行库（VC++ 2015-2022 成对库、.NET 10 Desktop Runtime、WebView2）。
    9. 启用精简休眠模式 (powercfg -h -type reduced)，释放 10GB+ C 盘物理空间。

.PARAMETER Mode
    操作动词: Sync (执行加固/默认) 或 CheckOnly (只查不改/体检巡检)。

.PARAMETER Profile
    配置预设: Full (黄金深度基线/默认) 或 General (通用稳健基线)。

.PARAMETER Yes
    非交互自动确认放行。

.PARAMETER NonInteractive
    非交互模式，遇到确认直接放行执行。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\scripts\windows\performance.ps1 -Mode CheckOnly

    # 交互式检查与加固
    pwsh -File .\scripts\windows\performance.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\performance.ps1 -Yes
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "CheckOnly")]
    [string]$Mode = "Sync",

    [ValidateSet("Full", "General")]
    [string]$Profile = "Full",

    [switch]$Yes,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# 环境校验：强制锁定 PowerShell 7+ 与 管理员权限
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "【版本错误】此脚本针对 PowerShell 7 (pwsh) 现代运行时深度定制，严禁在 Windows PowerShell 5.1 下执行！"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin) {
    throw "【权限错误】此脚本必须以管理员身份运行！请右键 pwsh 选择 [以管理员身份运行] 后重新执行。"
}

# ==============================================================================
# 内部辅助函数
# ==============================================================================
function Ensure-Key([string]$path) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}

function Test-RegDword([string]$Path, [string]$Name, [int]$Expected) {
    if (-not (Test-Path $Path)) { return $false }
    $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    return ($null -ne $val -and [int]$val -eq $Expected)
}

# ==============================================================================
# 阶段 1: 全量只读嗅探与状态比对 (Plan & Diff)
# ==============================================================================
$items = @(
    [PSCustomObject]@{
        Name   = "检查活动电源计划 (期望: 平衡)"
        Check  = {
            $activeScheme = powercfg /getactivescheme 2>&1 | Out-String
            return ($activeScheme -match "381b4222-f694-41f0-9685-ff5bb260df2e")
        }
        Action = {
            powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e 2>&1 | Out-Null
        }
    },
    [PSCustomObject]@{
        Name   = "检查硬件加速 GPU 调度 HAGS (期望: 默认关闭)"
        Check  = {
            $hags = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -ErrorAction SilentlyContinue).HwSchMode
            return ($hags -ne 2)
        }
        Action = {
            Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Name   = "禁用快速启动 (保持系统干净关机，杜绝内核缓存污染)"
        Check  = {
            return Test-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0
        }
        Action = {
            Ensure-Key "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "解除 MAX_PATH 260 字符路径限制"
        Check  = {
            return Test-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled" 1
        }
        Action = {
            Ensure-Key "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Type DWord -Value 1 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "巡检并禁用文件系统写入访问时间戳"
        Check  = {
            $accessQuery = fsutil behavior query disablelastaccess 2>&1 | Out-String
            return ($accessQuery -notmatch "=\s*0")
        }
        Action = {
            fsutil behavior set disablelastaccess 2 2>&1 | Out-Null
        }
    },
    [PSCustomObject]@{
        Name   = "SysMain 硬件门禁检测与停用 (NVMe + 16GB)"
        Check  = {
            $isNvme = (Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'NVMe' -and $_.MediaType -eq 'SSD' }).Count -gt 0
            $physMem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            $ramGB = [math]::Round($physMem / 1GB)
            if ($isNvme -and $ramGB -ge 16) {
                return (Get-Service SysMain -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            }
            return $true
        }
        Action = {
            $isNvme = (Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'NVMe' -and $_.MediaType -eq 'SSD' }).Count -gt 0
            $physMem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            $ramGB = [math]::Round($physMem / 1GB)
            if ($isNvme -and $ramGB -ge 16) {
                Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
                Set-Service -Name SysMain -StartupType Disabled
            }
        }
    },
    [PSCustomObject]@{
        Name   = "大内存工作站调整内存压缩与页面合并 (MMAgent 物理内存 >= 32GB 智能感知)"
        Check  = {
            $physMem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            if ($physMem -lt 30GB) { return $true }
            $agent = Get-MMAgent -ErrorAction SilentlyContinue
            return ($null -ne $agent -and -not $agent.MemoryCompression -and -not $agent.PageCombining)
        }
        Action = {
            $physMem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            if ($physMem -ge 30GB) {
                Disable-MMAgent -mc -PageCombining -ErrorAction SilentlyContinue
            }
        }
    },
    [PSCustomObject]@{
        Name   = "固化硬件时钟为 UTC (RealTimeIsUniversal) 与禁用自动时区更新 (tzautoupdate)"
        Check  = {
            $rtc = Test-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" "RealTimeIsUniversal" 1
            $tzSvc = (Get-Service tzautoupdate -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            return ($rtc -and $tzSvc)
        }
        Action = {
            Ensure-Key "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation"
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" -Name "RealTimeIsUniversal" -Type DWord -Value 1 -Force
            Stop-Service -Name tzautoupdate -Force -ErrorAction SilentlyContinue
            Set-Service -Name tzautoupdate -StartupType Disabled
        }
    },
    [PSCustomObject]@{
        Name   = "系统底层基础运行库校验与补齐 (VC++ 2015-2022 x64/x86, .NET 10.0, WebView2)"
        Check  = {
            $uninst = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
                      ForEach-Object { Get-ItemProperty $_.PSPath }
            $vc64 = ($uninst | Where-Object { $_.DisplayName -match "Visual C\+\+ 2015-.*x64" }).Count -gt 0
            $vc86 = ($uninst | Where-Object { $_.DisplayName -match "Visual C\+\+ 2015-.*x86" }).Count -gt 0
            $net10 = (Test-Path "C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App\10.*")
            $wv2 = (Test-Path "C:\Program Files (x86)\Microsoft\EdgeWebView\Application")
            return ($vc64 -and $vc86 -and $net10 -and $wv2)
        }
        Action = {
            $uninst = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
                      ForEach-Object { Get-ItemProperty $_.PSPath }
            $vc64 = ($uninst | Where-Object { $_.DisplayName -match "Visual C\+\+ 2015-.*x64" }).Count -gt 0
            $vc86 = ($uninst | Where-Object { $_.DisplayName -match "Visual C\+\+ 2015-.*x86" }).Count -gt 0
            $net10 = (Test-Path "C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App\10.*")
            $wv2 = (Test-Path "C:\Program Files (x86)\Microsoft\EdgeWebView\Application")

            if (-not $vc64 -or -not $vc86) {
                Write-Host "  [+] 正在通过 winget 补齐 Visual C++ 2015-2022 (x64 与 x86 成对运行库)..." -ForegroundColor Cyan
                winget install Microsoft.VCRedist.2015+.x64 Microsoft.VCRedist.2015+.x86 --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
            }
            if (-not $net10) {
                Write-Host "  [+] 正在通过 winget 补齐 .NET 10.0 Desktop Runtime (最新 LTS)..." -ForegroundColor Cyan
                winget install Microsoft.DotNet.DesktopRuntime.10 --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
            }
            if (-not $wv2) {
                Write-Host "  [+] 正在通过 winget 补齐 Microsoft Edge WebView2 Runtime..." -ForegroundColor Cyan
                winget install Microsoft.EdgeWebView2Runtime --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
            }
        }
    },
    [PSCustomObject]@{
        Name   = "启用精简休眠模式 (释放 10GB+ C 盘物理空间)"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $hiber = Get-Item "C:\hiberfil.sys" -Force -ErrorAction SilentlyContinue
            if (-not $hiber) { return $true }
            $mem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            return (($hiber.Length / $mem) -lt 0.30)
        }
        Action = {
            if ($Profile -eq 'General') { return }
            powercfg -h -type reduced
        }
    }
)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  硬件调度与性能底层基准巡检 (pwsh 7+)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$chkList = [System.Collections.Generic.List[PSCustomObject]]::new()
$pendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($item in $items) {
    $isReady = $false
    try {
        $isReady = [bool](& $item.Check)
    } catch {
        $isReady = $false
    }

    $chkList.Add([PSCustomObject]@{
        受控项目 = $item.Name
        当前状态 = if ($isReady) { "已就绪" } else { "待优化" }
        判定     = if ($isReady) { "✔ 合规" } else { "✘ 偏离" }
    })

    if (-not $isReady) {
        $pendingItems.Add($item)
    }
}

$chkList | Format-Table -AutoSize | Out-String | Write-Host
$driftCount = $pendingItems.Count

if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 硬件调度与性能底层基准全部合规，无需调整。`n" -ForegroundColor Green
    return
}

Write-Host "⚠️  共发现 $driftCount 项性能/硬件基线偏离。" -ForegroundColor Yellow

if ($Mode -eq "CheckOnly") {
    Write-Host "💡 当前处于 -Mode CheckOnly 只查不改模式，未执行任何系统改动。`n" -ForegroundColor Gray
    return
}

# ==============================================================================
# 阶段 2: 审查门禁 (Gate)
# ==============================================================================
if (-not $Yes -and -not $NonInteractive) {
    Write-Host "💡 [改动说明与硬件影响]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 激活平衡电源方案底层细粒度调优、开启 NTFS 260 字符长路径、关闭快速启动防双系统蓝屏" -ForegroundColor Gray
    Write-Host "   - 内存策略: 针对 32GB+ 内存机型禁用内存压缩以释放 CPU 算力，大容量物理内存建议禁用休眠释放 C 盘空间" -ForegroundColor Gray
    $choice = Read-Host "`n是否立即对齐上述 $driftCount 项性能与硬件基线？[Y/n/q] (回车确认)"
    if ($choice -match '^[Qq]') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
    if ($choice -match '^[Nn]') {
        Write-Host "[-] 跳过本模块基准对齐。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================
Write-Host "`n🚀 正在单向对齐性能底层与硬件基线..." -ForegroundColor Cyan
$successCount = 0

foreach ($it in $pendingItems) {
    Write-Host -NoNewline ("   - 正在配置: {0} ... " -f $it.Name)
    try {
        & $it.Action
        Write-Host -ForegroundColor Green "[OK]"
        $successCount++
    } catch {
        Write-Host -ForegroundColor Red "[FAIL]"
        Write-Warning "执行 [$($it.Name)] 失败: $($_.Exception.Message)"
    }
}

# ==============================================================================
# 阶段 4: 尾部简报 (Report)
# ==============================================================================
Write-Host "`n✅ [性能调优完成] 成功对齐 $successCount / $driftCount 项基线配置。`n" -ForegroundColor Green
