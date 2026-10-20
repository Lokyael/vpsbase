#requires -Version 7.0
<#
.SYNOPSIS
    Brave Browser

.DESCRIPTION
    Brave 浏览器 (Windows) 自动化部署与 Chromium 企业策略基线管理工具。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线 (Plan -> Diff -> Gate -> Apply -> Report)。
    2. 基于 Scoop 纳管的二进制本体 (D:\prog\scoop\apps\brave\current\brave.exe)。
    3. 网络安全零规则模型 (Zero-Rule)：纯出站客户端，通过企业组策略彻底禁用 Media Router (EnableMediaRouter = 0) 与 IPFS P2P，从源头消灭入站端口监听与 mDNS 广播，杜绝 Windows 拦截弹窗，依托全局基线天然兜底。
    4. 企业组策略顶层覆盖 (HKLM:\SOFTWARE\Policies\BraveSoftware\Brave):
       - 激活 Brave Shields 严格防指纹模式 (Farbling 动态伪随机加噪，彻底粉碎 Canvas/Audio/WebGL 唯一特征)；
       - 裁剪 Brave 专属商业与网络开销组件 (禁用 Rewards、Wallet 钱包、内置 VPN、Leo AI 助手与 IPFS P2P 节点)；
       - 禁用本地字体探测 API (DefaultLocalFontsSetting = 2) 与地理位置请求 (DefaultGeolocationSetting = 2)；
       - 禁用硬件侧信道探测 (禁用物理传感器 Sensors、WebUSB、WebHID、WebBluetooth)；
       - 强制 WebRTC 停用非代理 UDP 探测 (WebRtcIPHandlingPolicy = disable_non_proxied_udp)，消除真实网卡 IP 泄漏；
       - 禁用链接后台预加载 (NetworkPredictionOptions = 2) 并关闭内置 DoH 抢跑，完全遵从系统原生 DoH 与代理分流；
       - 界面语言与请求基准锁定 en-US，切断 Chromium 遥测、搜索联想与云端拼写检查，强制退出后台常驻；
       - 声明式静默预装 Bitwarden、uBlock Origin 与 uBlacklist 核心扩展。
    5. 终端矩阵呈现与决策交互统一委派内部辅助算子 _console.ps1 闭环承接。

.PARAMETER Action
    指定生命周期操作模式，可选值:
    - Sync      : 增量对齐受控基线 (默认，缺失则装、偏离则修)
    - Check     : 只查不改体检巡检 (100% 只读比对受控属性 Diff)
    - Uninstall : 清洁卸载、注销企业策略并移除安装目录 (默认保留用户持久化配置)

.PARAMETER Yes
    免交互全量确认放行开关。跳过审查门禁交互，直接执行流水线。

.PARAMETER Force
    配合 Sync 使用，强制调用 Scoop 重新安装覆盖本体并全量重写配置。

.PARAMETER Purge
    配合 Uninstall 使用，深度粉碎用户 Profile 数据目录与 Scoop 持久化缓存。

.EXAMPLE
    # 只查不改体检巡检
    pwsh -File .\scripts\apps\brave.ps1 -Action Check

    # 交互式检查并应用工程基线
    pwsh -File .\scripts\apps\brave.ps1

    # 强制重新部署覆盖本体并回正基线
    pwsh -File .\scripts\apps\brave.ps1 -Force

    # 安全清洁卸载 (保留用户数据)
    pwsh -File .\scripts\apps\brave.ps1 -Action Uninstall

    # 深度粉碎卸载 (全抹除)
    pwsh -File .\scripts\apps\brave.ps1 -Action Uninstall -Purge
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
    throw "【权限错误】Brave 浏览器下发企业策略需管理员特权，请在提升的 pwsh 会话中重新执行！"
}

$currentUser = [Environment]::UserName
$rawConsoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$consoleUser = if ($rawConsoleUser) { ($rawConsoleUser -replace '.*\\') } else { $currentUser }
if (-not $consoleUser) { $consoleUser = $currentUser }

if ($currentUser -ne $consoleUser -and $Action -ne "Check") {
    throw "【跨账号提权阻断】检测到终端运行身份 [$currentUser] 与当前桌面登录用户 [$consoleUser] 不一致！为防止将受控配置错误写入 [$currentUser] 账户，请直接在 [$consoleUser] 桌面会话中以管理员身份运行。"
}

# ==============================================================================
# 2. 应用元数据与辅助算子定位
# ==============================================================================
$AppId       = "brave"
$AppName     = "Brave Browser"
$ProcessName = "brave"

$scoopRoot = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
$AppDir    = Join-Path $scoopRoot "apps\brave\current"
$AppExe    = Join-Path $AppDir "brave.exe"
$ShimExe   = Join-Path $scoopRoot "shims\brave.exe"

$HighValueUserData = @(
    "Scoop 持久化用户数据目录: $scoopRoot\persist\brave\User Data",
    "持久化配置目录: $scoopRoot\persist\brave"
)

$consoleHelper = Join-Path $PSScriptRoot "_console.ps1"
if (-not (Test-Path $consoleHelper)) {
    throw "未在应用域定位到通用控制台渲染算子: _console.ps1，请确保仓库完整性！"
}

function Invoke-Console {
    param([string]$Task, [hashtable]$Params = @{})
    & $consoleHelper -Task $Task @Params
}

# ==============================================================================
# 3. 操作模式分流: 清洁卸载 (Uninstall)
# ==============================================================================
if ($Action -eq "Uninstall") {
    $canProceed = Invoke-Console -Task "ConfirmUninstall" -Params @{
        Yes          = $Yes
        Purge        = $Purge
        AppName      = $AppName
        UserDataList = $HighValueUserData
    }
    if (-not $canProceed) { return }

    Write-Host "`n🧹 [清洁卸载模式] 正在执行系统反注册与环境清理..." -ForegroundColor Yellow

    # 1. 强杀常驻进程
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 600

    # 2. 清理企业策略注册表
    @(
        "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave",
        "HKLM:\SOFTWARE\Policies\BraveSoftware"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "   - 已注销企业组策略: $_" -ForegroundColor Gray
        }
    }

    # 3. 委托 Scoop 卸载二进制
    $scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
    if ($scoopCmd) {
        Write-Host "   - 正在调用 Scoop 原生管道卸载应用本体..." -ForegroundColor Gray
        & scoop uninstall brave 2>&1 | Out-Null
    }

    # 4. 若指定 -Purge，深度物理粉碎持久化数据
    if ($Purge) {
        $userDataPaths = @(
            (Join-Path $scoopRoot "persist\brave"),
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser"
        )
        foreach ($p in $userDataPaths) {
            if (Test-Path $p) {
                Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   - [已粉碎] 用户数据目录: $p" -ForegroundColor Red
            }
        }
    }

    Write-Host "`n✅ [清洁卸载完成] Brave 浏览器二进制本体与策略关联已安全清除。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 4. 阶段 1: 全量只读嗅探与差异收集 (Plan & Diff)
# ==============================================================================
$startTime = [System.Diagnostics.Stopwatch]::StartNew()
$ManagedSpecs = [System.Collections.Generic.List[PSCustomObject]]::new()

# 4.1 程序本体层 (Binary Runtime)
$isExeExist = Test-Path -LiteralPath $AppExe -PathType Leaf
$ManagedSpecs.Add([PSCustomObject]@{
    Module   = "程序本体"
    Property = "Brave 核心二进制文件"
    Expected = "已部署于 Scoop 目录 ($AppExe)"
    Actual   = if ($isExeExist) { "已就绪" } else { "未安装" }
    IsMatch  = $isExeExist
    Purpose  = "保障 Brave 浏览器二进制本体由 Scoop 原生维护池管理，隔离系统盘"
    Impact   = "若缺失则自动通过 Scoop 管道进行部署或修复"
})

# 4.2 企业策略与防指纹基线层 (Policies Priority - GPO)
$policyKey = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
$currentPolicies = if (Test-Path $policyKey) { Get-ItemProperty -Path $policyKey -ErrorAction SilentlyContinue } else { $null }

$expectedPolicies = @(
    # --- 1. Brave 专属特性与商业推广裁剪 ---
    @{ Name = "BraveShieldsFingerprintingProtection"; Type = "String"; Expected = "strict";
       Desc = "Brave Shields 严格防指纹模式 (Farbling 动态加噪)";
       Purpose = "向 Canvas/AudioContext/WebGL 注入不可感知的伪随机扰动，粉碎跨站特征哈希唯一性";
       Impact = "网页每次计算的 Canvas/WebGL 指纹均不同，彻底瓦解设备画像追踪" },

    @{ Name = "BraveShieldsTrackersAndAds"; Type = "String"; Expected = "strict";
       Desc = "Brave Shields 严格广告与跟踪器拦截";
       Purpose = "企业策略级强制以最高强度拦截侵入式广告与第三方分析跟踪代码";
       Impact = "大幅提升页面加载速度与浏览纯净度" },

    @{ Name = "BraveRewardsDisabled"; Type = "DWord"; Expected = "1";
       Desc = "Brave Rewards 激励与代币系统剥离";
       Purpose = "彻底禁用 Rewards 广告返利与代币体系，消除后台静默网络轮询与区块链握手";
       Impact = "界面完全隐藏 Rewards 图标与提示，浏览体验纯净化" },

    @{ Name = "BraveWalletDisabled"; Type = "DWord"; Expected = "1";
       Desc = "Brave 内置加密货币钱包彻底禁用";
       Purpose = "停用内置 Web3 钱包及其 DOM 注入，节约内存并消除潜在钱包攻击面";
       Impact = "需要 Web3 时建议使用独立冷钱包或受控外部扩展" },

    @{ Name = "BraveVPNDisabled"; Type = "DWord"; Expected = "1";
       Desc = "Brave 内置付费 VPN 服务与推广切断";
       Purpose = "彻底剔除内置 VPN 商业推广与后台服务组件";
       Impact = "消除 VPN 推销弹窗与后台常驻网络组件" },

    @{ Name = "BraveAIChatEnabled"; Type = "DWord"; Expected = "0";
       Desc = "Brave Leo AI 侧栏助手与分析切断";
       Purpose = "停用内置 AI 侧边栏与模型交互，杜绝页面上下文内容被传至 AI 云端";
       Impact = "不使用内置 Leo AI，保护页面敏感数据" },

    @{ Name = "IPFSEnabled"; Type = "DWord"; Expected = "0";
       Desc = "IPFS 分布式节点协议彻底禁用";
       Purpose = "禁止浏览器在后台自动拉取并启动 go-ipfs 节点，切断 P2P 端口监听";
       Impact = "无法直接通过 ipfs:// 原生协议解析网关，杜绝 P2P 流量异常" },

    # --- 2. 字体、定位与硬件侧信道防护 ---
    @{ Name = "DefaultLocalFontsSetting"; Type = "DWord"; Expected = "2";
       Desc = "本地字体枚举 API 硬阻断 (BlockLocalFonts)";
       Purpose = "彻底禁用 window.queryLocalFonts() API，严禁网页刺探系统已安装字体";
       Impact = "网页无法通过直接枚举获知本地字体列表，彻底阻断基于字体特征的跨站指纹画像" },

    @{ Name = "DefaultGeolocationSetting"; Type = "DWord"; Expected = "2";
       Desc = "地理位置 API 全局静默阻断 (BlockGeolocation)";
       Purpose = "由浏览器底层静默拒绝所有网页的地理位置查询，杜绝物理坐标泄露";
       Impact = "网页请求位置时直接返回不可用，不再触发任何位置权限授权打扰弹窗" },

    @{ Name = "DefaultSensorsSetting"; Type = "DWord"; Expected = "2";
       Desc = "环境光与物理陀螺仪传感器阻断 (BlockSensors)";
       Purpose = "关闭系统物理传感器调用接口，消除移动/旋转状态下的侧信道探测";
       Impact = "网页无法读取设备倾斜角与环境光线变化" },

    @{ Name = "DefaultWebUsbGuardSetting"; Type = "DWord"; Expected = "2";
       Desc = "WebUSB 设备直连访问全局阻断";
       Purpose = "禁止网页调用 navigator.usb 探测并连接本地插入的物理 USB 设备";
       Impact = "网页无法枚举物理 USB 外设，杜绝硬件指纹探测" },

    @{ Name = "DefaultWebHidGuardSetting"; Type = "DWord"; Expected = "2";
       Desc = "WebHID 人机接口设备直连访问全局阻断";
       Purpose = "禁止网页调用 navigator.hid 枚举键盘/鼠标/游戏手柄等人机接口硬件";
       Impact = "网页无法识别外接键鼠厂商与型号特征" },

    @{ Name = "DefaultBluetoothGuardSetting"; Type = "DWord"; Expected = "2";
       Desc = "WebBluetooth 蓝牙直连访问全局阻断";
       Purpose = "禁止网页调用 navigator.bluetooth 扫描或配对周边物理蓝牙设备";
       Impact = "消除基于蓝牙 MAC 与广播名称的近场追踪" },

    # --- 3. 网络协议、DNS 与连接抢跑阻断 ---
    @{ Name = "EnableMediaRouter"; Type = "DWord"; Expected = "0";
       Desc = "Chromecast 局域网投屏与媒体路由彻底禁用";
       Purpose = "彻底关闭 Media Router 局域网设备探测与 mDNS 广播，消除入站端口监听";
       Impact = "无法使用 Chrome Cast 投屏功能，从根源杜绝 Windows 防火墙拦截弹窗" },

    @{ Name = "WebRtcIPHandlingPolicy"; Type = "String"; Expected = "disable_non_proxied_udp";
       Desc = "WebRTC 私网 IP 与非代理 UDP 泄露阻断";
       Purpose = "禁止 WebRTC 通过非代理接口发起 UDP 探测，杜绝泄漏物理网卡 IP 与局域网拓扑";
       Impact = "彻底消除 WebRTC 穿透代理导致真实 IP 泄露的高危风险" },

    @{ Name = "DnsOverHttpsMode"; Type = "String"; Expected = "off";
       Desc = "内置 DoH 抢跑彻底停用 (委托系统原生 DoH)";
       Purpose = "强制关闭 Chromium 内置独立 DoH，DNS 解析完全遵从 Windows 11 原生安全模板与本地网络栈";
       Impact = "消除双重 DoH 冲突与网络分流死锁" },

    @{ Name = "NetworkPredictionOptions"; Type = "DWord"; Expected = "2";
       Desc = "网络预测与 DNS/链接预取彻底禁用";
       Purpose = "彻底关闭网页在后台对链接的提前解析与预加载，杜绝未点击时静默发起网络连接";
       Impact = "消除用户意图提前泄露风险，节省网络带宽" },

    # --- 4. 遥测、搜索与云端分析剥离 ---
    @{ Name = "MetricsReportingEnabled"; Type = "DWord"; Expected = "0";
       Desc = "Chromium 遥测诊断与崩溃报告上传切断";
       Purpose = "禁止浏览器向 Brave/Google 云端回传日常使用指标与错误采样";
       Impact = "切断后台静默遥测网络心跳" },

    @{ Name = "SearchSuggestEnabled"; Type = "DWord"; Expected = "0";
       Desc = "地址栏实时搜索联想建议彻底停用";
       Purpose = "禁止在地址栏每键入一个字符就向搜索引擎后台实时发送 keystroke 采样";
       Impact = "地址栏输入完全本地化，仅匹配本地书签与历史" },

    @{ Name = "SpellcheckEnabled"; Type = "DWord"; Expected = "0";
       Desc = "云端拼写检查上传切断";
       Purpose = "关闭在线拼写检查器，杜绝键入文本经由拼写分析通道被回传";
       Impact = "输入框不再提示拼写波浪线" },

    @{ Name = "PasswordManagerEnabled"; Type = "DWord"; Expected = "0";
       Desc = "内置密码保存提示停用 (统一由 Bitwarden 纳管)";
       Purpose = "关闭浏览器内置的弱加密密码库与保存弹窗";
       Impact = "凭据统一交由专业密码管理器托管，杜绝本地明文外泄隐患" },

    @{ Name = "AutofillAddressEnabled"; Type = "DWord"; Expected = "0";
       Desc = "地址表单自动填充切断";
       Purpose = "禁止浏览器缓存与自动填充真实物理住址，消除被钓鱼表单探测风险";
       Impact = "需手动填充收货地址或由专业密码器代填" },

    @{ Name = "AutofillCreditCardEnabled"; Type = "DWord"; Expected = "0";
       Desc = "信用卡支付表单自动填充切断";
       Purpose = "禁止在浏览器内存和磁盘中保留信用卡卡号与安全码信息";
       Impact = "支付信息统一由 Bitwarden 动态安全填充" },

    # --- 5. 语言、生命周期与下载安全 ---
    @{ Name = "ApplicationLocaleValue"; Type = "String"; Expected = "en-US";
       Desc = "浏览器界面语言与请求基准锁定 en-US";
       Purpose = "将浏览器文化与请求头对齐为全球最大基数的 en-US，降到最低指纹熵";
       Impact = "多语言自适应网站优先呈现英文界面，与系统基线 100% 同构" },

    @{ Name = "BackgroundModeEnabled"; Type = "DWord"; Expected = "0";
       Desc = "关闭所有窗口后后台常驻彻底禁用";
       Purpose = "关闭最后一个标签页时立即彻底终止 Chromium 进程树，释放全部系统内存";
       Impact = "系统托盘不留常驻图标，杜绝后台隐蔽运行" },

    # --- 6. 核心企业安全扩展强制声明 ---
    @{ Name = "Extension.Bitwarden"; Type = "Special"; Expected = "已声明";
       Desc = "Bitwarden 密码管理器强制声明 (ExtensionInstallForcelist)";
       Purpose = "通过企业策略静默为所有 Profile 强制安装 Bitwarden 官方扩展";
       Impact = "账号密码凭据统一由 Bitwarden 托管，杜绝在浏览器内部明文留存" },

    @{ Name = "Extension.uBlock"; Type = "Special"; Expected = "已声明";
       Desc = "uBlock Origin 广告拦截器强制声明 (ExtensionInstallForcelist)";
       Purpose = "通过企业策略静默安装 uBlock Origin，配合 Brave Shields 形成双层高级网络过滤";
       Impact = "增强复杂规则语法与脚本重定向拦截能力" },

    @{ Name = "Extension.uBlacklist"; Type = "Special"; Expected = "已声明";
       Desc = "uBlacklist 搜索结果净化扩展声明 (ExtensionInstallForcelist)";
       Purpose = "通过企业策略强制安装 uBlacklist 扩展，从源头物理抹除 CSDN、机翻爬虫站与 SEO 内容农场";
       Impact = "Google/Bing/Brave 搜索结果自动过滤内容农场与低质条目" }
)

$extForceKey = "$policyKey\ExtensionInstallForcelist"
$extForceProps = if (Test-Path $extForceKey) { Get-ItemProperty -Path $extForceKey -ErrorAction SilentlyContinue } else { $null }

foreach ($p in $expectedPolicies) {
    $actVal = "<未配置>"
    if ($p.Type -eq "Special") {
        if ($extForceProps) {
            $vals = $extForceProps.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') } | ForEach-Object { "$($_.Value)" }
            if ($p.Name -eq "Extension.Bitwarden" -and ($vals -match "nngceckbapebfimnlniiiahkandclblb")) { $actVal = "已声明" }
            if ($p.Name -eq "Extension.uBlock" -and ($vals -match "cjpalhdlnbpafiamejdnhcphjbkeiagm")) { $actVal = "已声明" }
            if ($p.Name -eq "Extension.uBlacklist" -and ($vals -match "pncfbmialoiaghdehhbnbhkkgmjanegk")) { $actVal = "已声明" }
        }
    } else {
        if ($currentPolicies) {
            $raw = $currentPolicies.$($p.Name)
            if ($null -ne $raw) { $actVal = "$raw" }
        }
    }

    $isMatch = ($actVal.ToLower() -eq $p.Expected.ToLower())
    $ManagedSpecs.Add([PSCustomObject]@{
        Module   = "企业策略"
        Property = "$($p.Desc) [$($p.Name)]"
        Expected = $p.Expected
        Actual   = $actVal
        IsMatch  = $isMatch
        Purpose  = $p.Purpose
        Impact   = $p.Impact
    })
}

# 渲染控制台 Diff 看板
Invoke-Console -Task "RenderDiff" -Params @{ Specs = $ManagedSpecs }

$driftList = @($ManagedSpecs | Where-Object { -not $_.IsMatch })
if ($Action -eq "Check") {
    if ($driftList.Count -eq 0) {
        Write-Host "✨ [状态合规] Brave 所有受控属性与策略均符合工程基线，无需调整。`n" -ForegroundColor Green
    } else {
        Write-Host ("⚠️  共发现 {0} 项基线偏离。执行默认模式 (-Action Sync) 即可自动增量对齐。`n" -f $driftList.Count) -ForegroundColor Yellow
    }
    return
}

if ($driftList.Count -eq 0 -and $isExeExist -and -not $Force) {
    Write-Host "✨ [状态合规] Brave 受控基线均已符合终态，无需写入变更。`n" -ForegroundColor Green
    return
}

# ==============================================================================
# 5. 阶段 2: 审查门禁与并发保护 (Gate - Shift-Left Transparency)
# ==============================================================================
$runningProc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if ($runningProc) {
    if (-not $Yes) {
        Write-Warning "检测到 Brave 浏览器当前正在运行！策略更新需重启浏览器生效。"
        $confirmProc = (Read-Host "是否立即关闭正在运行的 brave 进程以继续应用基线? [Y/n]").Trim()
        if ($confirmProc -match '^(n|no)$') {
            Write-Host "[-] 用户已取消操作，安全退出。`n" -ForegroundColor DarkGray
            return
        }
    }
    $runningProc | Stop-Process -Force
    Start-Sleep -Milliseconds 600
}

$canApply = Invoke-Console -Task "ConfirmGate" -Params @{
    Action = $Action
    Yes    = $Yes
    Specs  = $ManagedSpecs
}
if (-not $canApply) { return }

# ==============================================================================
# 6. 阶段 3: 单向语义与原子落盘 (Apply)
# ==============================================================================
Write-Host "`n🚀 正在单向对齐 Brave 浏览器工程基线..." -ForegroundColor Cyan
$appliedCount = 0

# 6.1 程序本体部署 (委托 Scoop 原生管道)
if (-not $isExeExist -or $Force) {
    Write-Host "📦 正在通过 Scoop 管道部署 Brave 浏览器..." -ForegroundColor Yellow
    $scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $scoopCmd) {
        throw "未检测到 Scoop 包管理器环境！请先完成包管理器自举后再行部署应用。"
    }

    if ($Force) {
        & scoop install --force brave
    } else {
        & scoop install brave
    }

    if (-not (Test-Path $AppExe)) {
        throw "Brave 部署后可执行文件未命中目标路径: [$AppExe]。"
    }
    $appliedCount++
    Write-Host "✅ Brave 浏览器本体部署完成: $AppExe" -ForegroundColor Green
}

# 6.2 注入企业组策略 (HKLM:\SOFTWARE\Policies\BraveSoftware\Brave)
Write-Host "⚙️  正在向系统注册表注入 Brave 企业级防指纹与隐私组策略..." -ForegroundColor Yellow
if (-not (Test-Path $policyKey)) { New-Item -Path $policyKey -Force | Out-Null }

foreach ($p in $expectedPolicies) {
    if ($p.Type -eq "Special") { continue }
    $curVal = (Get-ItemProperty -Path $policyKey -Name $p.Name -ErrorAction SilentlyContinue).$($p.Name)
    $needWrite = ($null -eq $curVal -or "$curVal".ToLower() -ne $p.Expected.ToLower())
    if ($needWrite) {
        if ($p.Type -eq "DWord") {
            Set-ItemProperty -Path $policyKey -Name $p.Name -Value ([int]$p.Expected) -Type DWord -Force
        } else {
            Set-ItemProperty -Path $policyKey -Name $p.Name -Value $p.Expected -Type String -Force
        }
        $appliedCount++
    }
}

# 注入 ExtensionInstallForcelist
$extKey = "$policyKey\ExtensionInstallForcelist"
if (-not (Test-Path $extKey)) { New-Item -Path $extKey -Force | Out-Null }
$targetExtensions = @(
    "nngceckbapebfimnlniiiahkandclblb;https://clients2.google.com/service/update2/crx", # Bitwarden
    "cjpalhdlnbpafiamejdnhcphjbkeiagm;https://clients2.google.com/service/update2/crx", # uBlock Origin
    "pncfbmialoiaghdehhbnbhkkgmjanegk;https://clients2.google.com/service/update2/crx"  # uBlacklist
)
for ($i = 0; $i -lt $targetExtensions.Count; $i++) {
    $valName = "$($i + 1)"
    $curExt = (Get-ItemProperty -Path $extKey -Name $valName -ErrorAction SilentlyContinue).$valName
    if ($curExt -ne $targetExtensions[$i]) {
        Set-ItemProperty -Path $extKey -Name $valName -Value $targetExtensions[$i] -Type String -Force
        $appliedCount++
    }
}
Write-Host "✅ Brave 企业组策略已全量对齐至: $policyKey" -ForegroundColor Green

# ==============================================================================
# 7. 阶段 4: 尾部简报与闭环度量 (Report)
# ==============================================================================
$startTime.Stop()
Invoke-Console -Task "Summary" -Params @{
    AppName      = $AppName
    Duration     = $startTime.Elapsed
    AppliedCount = $appliedCount
}

Write-Host "   - 部署模式: Scoop 托管本体 ($AppDir)" -ForegroundColor Gray
Write-Host "   - 防指纹策略: 已强制开启 Farbling 严格模式、LocalFonts 阻断与 WebRTC 防泄露" -ForegroundColor Gray
Write-Host "   - 网络安全: 零规则纯出站客户端，Media Router 局域网监听已从底层物理切断" -ForegroundColor Gray

Write-Host "`n--------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📋 [手动收尾清单 (Actionable Handoff)]" -ForegroundColor Cyan
Write-Host "  1. uBlacklist 搜索净化订阅 (扩展图标 → 选项 → 添加订阅，粘贴后每日自动更新):" -ForegroundColor Cyan
Write-Host "     - 中文技术社区与采集站 (屏蔽 CSDN/脚本之家/代码抄袭/机翻站):" -ForegroundColor Gray
Write-Host "       https://raw.githubusercontent.com/cobaltdisco/Google-Chinese-Results-Blocklist/master/uBlacklist_subscription.txt" -ForegroundColor DarkCyan
Write-Host "     - 中文泛生活与内容农场 (大体量清洗生活/健康/娱乐类内容农场):" -ForegroundColor Gray
Write-Host "       https://raw.githubusercontent.com/dallaslu/penzai-list/main/uBlacklist.txt" -ForegroundColor DarkCyan
Write-Host "     - 全球 AI/SEO 垃圾农场 (屏蔽自动化 AI 生成垃圾文章与点击诱饵站):" -ForegroundColor Gray
Write-Host "       https://raw.githubusercontent.com/laylavish/uBlockOrigin-HUGE-AI-Blocklist/main/list_uBlacklist.txt" -ForegroundColor DarkCyan
Write-Host "     - 技术问答机翻镜像专杀 (精准抹除 StackOverflow 中文机翻倒卖站):" -ForegroundColor Gray
Write-Host "       https://raw.githubusercontent.com/arosh/ublacklist-stackoverflow-translation/master/uBlacklist.txt" -ForegroundColor DarkCyan
Write-Host "--------------------------------------------------------------------`n" -ForegroundColor DarkGray
return
