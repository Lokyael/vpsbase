#requires -Version 7.0
<#
.SYNOPSIS
    硬件调度与性能底层基准

.DESCRIPTION
    Windows 11 硬件底层调度、电源计划巡检、快速启动禁用与内核性能优化模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 巡检活动电源计划（锁定平衡方案，杜绝单核睿频被压制与待机积热）。
    3. 禁用快速启动（彻底关机，杜绝内核驱动脏缓存跨重启污染）。
    4. 解除 MAX_PATH 260 字符长路径限制，禁用 NTFS 写入访问时间戳。
    5. SysMain 硬件门禁检测与停用（满足 NVMe SSD + >=16GB 内存时停用后台预读）。
    6. 大内存工作站优化（物理内存 >= 32GB 时停用 MMAgent 内存压缩与页面合并以释放算力）。
    7. 固化硬件时钟为 UTC (RealTimeIsUniversal) 并禁用自动时区，消除双系统/装机时钟漂移。
    8. 启用精简休眠模式 (powercfg -h -type reduced)，释放 10GB+ C 盘物理空间 (仅 Full)。

.PARAMETER Action
    操作模式:
    - Sync  : 增量收敛加固 (默认，仅修复实机偏离项，保持合规项不动)
    - Check : 状态体检巡检 (100% 只读诊断受控属性对比，零写入安全退出)

.PARAMETER Profile
    加固预设:
    - Full    : 个人黄金深度基线 (默认，极致性能与全域深度加固)
    - General : 通用稳健基线 (保守兼容，跳过精简休眠等激进项)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行单向收敛。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\scripts\windows\performance.ps1 -Action Check

    # 交互式检查与加固
    pwsh -File .\scripts\windows\performance.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\performance.ps1 -Yes
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "Check")]
    [string]$Action = "Sync",

    [ValidateSet("Full", "General")]
    [string]$Profile = "Full",

    [switch]$Yes
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# 1. 运行时环境硬门禁与权限安全防御
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "【版本错误】此脚本针对 PowerShell 7 (pwsh) 现代运行时深度定制，严禁在 Windows PowerShell 5.1 下执行！"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin -and $Action -ne "Check") {
    throw "【权限错误】此脚本必须以管理员身份运行！请右键 pwsh 选择 [以管理员身份运行] 后重新执行。"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】当前终端运行身份 [$currentUser] 与桌面登录用户 [$consoleUser] 不一致！为防配置污染，请直接在桌面登录用户会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 内置原生轻量辅助函数库 (Self-Contained Mini-Kit)
# ==============================================================================
function Ensure-RegKey {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
}

function Set-RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    Ensure-RegKey $Path
    $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($cur -ne $Value) {
        try {
            Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value -Force -ErrorAction Stop
        } catch {
            $regPath = $Path -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
            & reg.exe add $regPath /v $Name /t REG_DWORD /d $Value /f *>$null
        }
    }
}

function Get-RegVal {
    param([string]$Path, [string]$Name, [string]$Default = "<未配置>")
    if (-not (Test-Path $Path)) { return $Default }
    $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    return if ($null -ne $val) { "$val" } else { $Default }
}

# ==============================================================================
# 3. 声明式规则矩阵清单 (最小细项原子化拆解: 作用与风险明确分离)
# ==============================================================================
$Rules = @(
    [PSCustomObject]@{
        Id      = "power-scheme-balanced"
        Name    = "锁定活动电源计划为平衡方案 (Balanced)"
        Profile = "General"
        Purpose = "锁定平衡电源计划，保留系统根据 CPU 负载动态调度单核睿频机制，消除待机积热"
        Impact  = "某些希望无视发热与能耗、强行压榨最高持续全核主频的极限超频跑分场景不适用"
        Check   = {
            $activeScheme = powercfg /getactivescheme 2>&1 | Out-String
            $isPass = ($activeScheme -match "381b4222-f694-41f0-9685-ff5bb260df2e")
            return @{
                Actual      = if ($isPass) { "平衡方案" } else { "非平衡方案" }
                Expected    = "平衡方案 (381b4222-...)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e 2>&1 | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "disable-fast-startup"
        Name    = "快速启动禁用 (HiberbootEnabled = 0)"
        Profile = "General"
        Purpose = "关机时彻底清理内核会话与驱动堆栈，杜绝双系统时钟错乱与跨开机内核脏状态污染"
        Impact  = "机械硬盘或老旧 SATA 固态的系统冷启动时间可能略微增加 2~5 秒（NVMe 固态几乎无感）"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled"
            return @{ Actual = $val; Expected = "0"; IsCompliant = ($val -eq "0") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0
        }
    },
    [PSCustomObject]@{
        Id      = "enable-long-paths"
        Name    = "MAX_PATH 260 字符文件路径限制解除 (LongPathsEnabled = 1)"
        Profile = "General"
        Purpose = "突破 Win32 260 字符限制，保障深层嵌套工程正常读写与编译构建"
        Impact  = "极少数 20 年前未适配长路径 API 的上古老旧 32 位工具可能无法正确处理超长路径"
        Check   = {
            $val = Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled"
            return @{ Actual = $val; Expected = "1"; IsCompliant = ($val -eq "1") }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled" 1
        }
    },
    [PSCustomObject]@{
        Id      = "disable-last-access-timestamp"
        Name    = "NTFS 写入访问时间戳禁用 (disablelastaccess >= 1)"
        Profile = "General"
        Purpose = "每次读取文件时不再产生静默磁盘写操作，延长固态硬盘寿命并提升海量小文件遍历速度"
        Impact  = "极少数依赖 NTFS 访问时间戳进行冷热数据归档的特种备份工具将无法以访问时间作为筛选依据"
        Check   = {
            $accessQuery = fsutil behavior query disablelastaccess 2>&1 | Out-String
            $isPass = ($accessQuery -notmatch "=\s*0")
            return @{
                Actual      = if ($isPass) { "已禁用 (>=1)" } else { "未禁用 (0)" }
                Expected    = "已禁用 (>=1)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            fsutil behavior set disablelastaccess 2 2>&1 | Out-Null
        }
    },
    [PSCustomObject]@{
        Id      = "disable-sysmain-nvme-ram"
        Name    = "SysMain 预读服务硬件门禁停用 (NVMe SSD + 16GB+ RAM)"
        Profile = "General"
        Purpose = "在高速 NVMe 与充裕内存环境下停用 Superfetch 预读服务，消除后台磁盘静默读写抖动"
        Impact  = "机械硬盘系统停用后热点应用冷启动时间会有所延长（本规则内置 NVMe + 16GB 硬件门禁保护，机械盘不会触发）"
        Check   = {
            $isNvme = (Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'NVMe' -and $_.MediaType -eq 'SSD' }).Count -gt 0
            $physMem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            $ramGB = [math]::Round($physMem / 1GB)
            if ($isNvme -and $ramGB -ge 16) {
                $status = (Get-Service SysMain -ErrorAction SilentlyContinue).StartType ?? "NotFound"
                $isPass = ($status -eq 'Disabled')
                return @{ Actual = "$status"; Expected = "Disabled"; IsCompliant = $isPass }
            }
            return @{ Actual = "未满足硬件门禁(保持默认)"; Expected = "保持默认"; IsCompliant = $true }
        }
        Apply   = {
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
        Id      = "disable-mmagent-large-ram"
        Name    = "大内存工作站内存压缩与页面合并调整 (物理内存 >= 32GB 智能感知)"
        Profile = "General"
        Purpose = "物理内存 >= 30GB 时停用 MMAgent 内存压缩与页面合并，释放 CPU 压缩算力，消除微卡顿"
        Impact  = "内存占用接近上限时，系统将直接落盘虚拟内存 pagefile 而不再压缩内存，低内存设备不适用（内置 >=30GB 硬件门禁）"
        Check   = {
            $physMem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            if ($physMem -lt 30GB) {
                return @{ Actual = "内存 < 30GB (保持默认)"; Expected = "保持默认"; IsCompliant = $true }
            }
            $agent = Get-MMAgent -ErrorAction SilentlyContinue
            $isPass = ($null -ne $agent -and -not $agent.MemoryCompression -and -not $agent.PageCombining)
            return @{
                Actual      = if ($isPass) { "Compression=Disabled, Combining=Disabled" } else { "未完全停用" }
                Expected    = "Compression=Disabled, Combining=Disabled"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            $physMem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            if ($physMem -ge 30GB) {
                Disable-MMAgent -mc -PageCombining -ErrorAction SilentlyContinue
            }
        }
    },
    [PSCustomObject]@{
        Id      = "hardware-clock-utc-timezone"
        Name    = "固化硬件时钟为 UTC 与禁用自动时区更新 (RealTimeIsUniversal = 1)"
        Profile = "General"
        Purpose = "将主板 CMOS 硬件时钟锚定为国际标准 UTC 时间，消除 Linux/Windows 双系统与离线开机时间漂移"
        Impact  = "若主板电池耗尽且处于离线无网环境，开机时间可能不会自动与本地时区同步"
        Check   = {
            $rtc = (Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" "RealTimeIsUniversal") -eq "1"
            $tzSvc = (Get-Service tzautoupdate -ErrorAction SilentlyContinue).StartType -eq 'Disabled'
            $isPass = ($rtc -and $tzSvc)
            return @{
                Actual      = if ($isPass) { "UTC=1, tzautoupdate=Disabled" } else { "未配置" }
                Expected    = "UTC=1, tzautoupdate=Disabled"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" "RealTimeIsUniversal" 1
            Stop-Service -Name tzautoupdate -Force -ErrorAction SilentlyContinue
            Set-Service -Name tzautoupdate -StartupType Disabled
        }
    },
    [PSCustomObject]@{
        Id      = "powercfg-hibernation-reduced"
        Name    = "启用精简休眠模式 (释放 10GB+ C 盘物理空间)"
        Profile = "Full"
        Purpose = "将休眠文件体积从 100% 内存大小压缩至 20%~30%，即刻返还 10GB~20GB+ C 盘物理可用空间"
        Impact  = "仅保留支持快速唤醒所需的精简内核会话，不再支持将数十 GB 完整用户工作集完全断电休眠（仅 Full 生效）"
        Check   = {
            $hiber = Get-Item "C:\hiberfil.sys" -Force -ErrorAction SilentlyContinue
            if (-not $hiber) { return @{ Actual = "休眠文件不存在"; Expected = "Reduced"; IsCompliant = $true } }
            $mem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
            $ratio = $hiber.Length / $mem
            $isPass = ($ratio -lt 0.30)
            return @{
                Actual      = "$([math]::Round($ratio * 100))% 内存容量"
                Expected    = "< 30% 内存容量 (Reduced)"
                IsCompliant = $isPass
            }
        }
        Apply   = {
            powercfg -h -type reduced
        }
    }
)

# ==============================================================================
# 4. 驱动执行管线 (Five-Stage Declarative Pipeline Engine)
# ==============================================================================

# 阶段 1: Plan & Diff
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  硬件调度与性能底层基准巡检 (pwsh 7+)" -ForegroundColor Cyan
Write-Host ("  操作意图: {0} | 加固预设: {1} | 授权放行: {2}" -f $Action, $Profile, ($Yes ? "自动放行 (-Yes)" : "交互审查")) -ForegroundColor DarkGray
Write-Host "====================================================================" -ForegroundColor Cyan

$ActiveRules = @($Rules | Where-Object {
    if ($Profile -eq "General") { $_.Profile -eq "General" } else { $true }
})

$AuditBoard = [System.Collections.Generic.List[PSCustomObject]]::new()
$PendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($rule in $ActiveRules) {
    $res = $null
    try {
        $res = & $rule.Check
    } catch {
        $res = @{
            Actual      = "<探测异常: $($_.Exception.Message)>"
            Expected    = "<未知>"
            IsCompliant = $false
        }
    }

    $isPass = [bool]$res.IsCompliant
    $actualStr = "$($res.Actual)"
    $expectedStr = "$($res.Expected)"

    $AuditBoard.Add([PSCustomObject]@{
        受控规则 = $rule.Name
        预设级别 = $rule.Profile
        实机状态 = $actualStr
        期望基线 = $expectedStr
        状态判定 = if ($isPass) { "✔ 合规" } else { "✘ 偏离" }
    })

    if (-not $isPass) {
        $PendingItems.Add([PSCustomObject]@{
            Rule        = $rule
            Actual      = $actualStr
            Expected    = $expectedStr
        })
    }
}

Write-Host "`n📊 [巡检看板] 性能底层原子受控属性审计清单:" -ForegroundColor Cyan
$AuditBoard | Format-Table -AutoSize | Out-String | Write-Host

$driftCount = $PendingItems.Count
if ($driftCount -eq 0) {
    Write-Host "✨ [状态合规] 硬件调度与性能底层基准全部合规，无需调整。`n" -ForegroundColor Green
    return
}

Write-Host ("⚠️  共检测到 {0} 项原子受控属性偏离工程基线。" -f $driftCount) -ForegroundColor Yellow

if ($Action -eq "Check") {
    Write-Host "💡 当前处于 -Action Check 只读巡检模式，未执行任何系统改动。`n" -ForegroundColor DarkGray
    return
}

# 阶段 2: Gate (Shift-Left: 目的与影响结构化直出)
if (-not $Yes) {
    Write-Host "`n💡 [改动意图与技术边界审查 (Gate)]" -ForegroundColor Cyan
    Write-Host "   本次即将对齐以下偏离项，请逐项评估改动 [目的] 与 [影响]:" -ForegroundColor Gray
    $idx = 1
    foreach ($p in $PendingItems) {
        Write-Host ("`n   [{0}] {1}" -f $idx, $p.Rule.Name) -ForegroundColor Yellow
        Write-Host ("       - 当前实机值: {0}  ==>  期望基线值: {1}" -f $p.Actual, $p.Expected) -ForegroundColor DarkGray
        Write-Host ("       - [目的] {0}" -f $p.Rule.Purpose) -ForegroundColor White
        Write-Host ("       - [影响] {0}" -f $p.Rule.Impact) -ForegroundColor Gray
        $idx++
    }

    $gateInput = (Read-Host "`n确认对齐上述 $driftCount 项性能与硬件基线？[Y] 确认执行 / [N] 跳过本模块 / [Q] 退出 (默认 Y)").Trim()
    if ($gateInput -match '^[Qq]') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
    if ($gateInput -match '^[Nn]') {
        Write-Host "[-] 跳过本模块基准对齐。`n" -ForegroundColor DarkGray
        return
    }
}

# 阶段 3: Apply
Write-Host "`n🚀 正在单向对齐硬件调度与性能基线..." -ForegroundColor Cyan
$appliedCount = 0

foreach ($p in $PendingItems) {
    Write-Host -NoNewline ("   - 正在配置: {0} ... " -f $p.Rule.Name)
    try {
        & $p.Rule.Apply
        Write-Host -ForegroundColor Green "[OK]"
        $appliedCount++
    } catch {
        Write-Host -ForegroundColor Red "[FAIL]"
        Write-Warning "执行规则 [$($p.Rule.Name)] 失败: $($_.Exception.Message)"
    }
}

# 阶段 4: Report
Write-Host "`n====================================================================" -ForegroundColor Green
Write-Host ("  ✅ [性能优化完成] 成功对齐 {0} / {1} 项基线配置 (预设: {2})" -f $appliedCount, $driftCount, $Profile) -ForegroundColor Green
Write-Host "====================================================================`n" -ForegroundColor Green
return
