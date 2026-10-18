# Windows 基础

Windows 11 专业版系统服务裁剪、注册表精简与性能隐私调优。

## 数据盘目录规范（D 盘）

基于生命周期与流动性的工作区文件层级划分：

```text
D:\
├── act/          # 活跃任务与进行中工程 (动态流动)
│   └── <project> # 进行中的开发、学习或创作项目
├── arc/          # 静态归档与历史资产 (只读封存)
│   └── <year>/   # 按年份或领域归档已结项资产
├── prog/         # 软件生态与运行时集中区 (隔离系统盘)
│   ├── scoop/    # Scoop 包管理器及工具链
│   ├── steam/    # Steam 平台及游戏库
│   └── wsl/      # WSL 虚拟磁盘镜像 (.vhdx)
└── res/          # 通用基石资产与数字资产 (持久沉淀)
    ├── conf/     # 配置文件备份 / Dotfiles
    ├── doc/      # 电子书与参考文档资料
    └── media/    # 多媒体素材库 (pic, music, video)
```

### 维护准则

- **`act`（Active）**：生命周期内的高频动态工程。结项后清理构建缓存并迁入 `arc`。
- **`arc`（Archive）**：冷档案与历史交付物，原则上只读不改，作为历史资产检索库。
- **`prog`（Programs）**：统一软件集中区与运行环境。收敛非系统级应用本体以隔离系统盘，免整盘备份；非便携应用的状态与配置按各自原生机制托管。
- **`res`（Resources）**：长期复利积累的基石资产，生命周期无限长，最高优先级备份。独立于软件生命周期之外，由用户按需沉淀与手动维护。

---

## 工作站系统基线编排与加固（管理员 pwsh）

系统服务裁剪、隐私阻断、外壳交互与性能调优统一由编排门面 `scripts/setup-windows.ps1` 调度纳管，各模块解耦自治于 `scripts/windows/`（涵盖遥测、外壳、搜索、服务、网络、组件与性能 7 大领域）。执行默认交互审查，支持定向模块与非交互流水线。

> **提权前提**：日常账号须为管理员组成员（Consent 提权），避免在标准用户下通过 OTS 提权导致 `HKCU` 配置写入错误用户。加固细节、受控属性比对与潜在兼容风险均由脚本在事前门禁（Gate）与控制台中实时白盒直出。

```powershell
# 1. 远程一键调用编排门面（管理员 pwsh，内置远程内存沙盒自适应调度）
irm https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/setup-windows.ps1 | iex

# 2. 本地执行（管理员 pwsh）
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1                    # 交互式引导全流程
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile Full -Yes # 个人黄金基线一键全量
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile General -Yes # 通用稳健预设 (跳过激进深度优化项)
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Action Check    # 全量只读体检巡检
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Modules shell,performance # 定向加固指定模块

# 3. 亦可单独单跑任一自治子模块 (100% 独立自闭合)
pwsh -ExecutionPolicy Bypass -File scripts\windows\shell.ps1 -Action Check
```

---

## 操作系统版本锁定（管理员 pwsh）

针对生产力工作站，通过企业组策略将系统锚定在当前稳定分支，正常接收每月安全累积更新（B 类），阻断跨年度版本静默强升：

```powershell
$releaseId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
if (-not $releaseId) {
    $releaseId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").ReleaseId
}

$wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
if (-not (Test-Path $wuKey)) { New-Item -Path $wuKey -Force | Out-Null }
Set-ItemProperty -Path $wuKey -Name "TargetReleaseVersion" -Type DWord -Value 1 -Force
Set-ItemProperty -Path $wuKey -Name "TargetReleaseVersionInfo" -Type String -Value $releaseId -Force
Set-ItemProperty -Path $wuKey -Name "ProductVersion" -Type String -Value "Windows 11" -Force
```

> **解除锁定恢复跨版本升级**：
> ```powershell
> $wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
> @("TargetReleaseVersion", "TargetReleaseVersionInfo", "ProductVersion") | ForEach-Object {
>     Remove-ItemProperty -Path $wuKey -Name $_ -ErrorAction SilentlyContinue
> }
> ```

---

## 网络安全与 DNS 泄漏审计（管理员 pwsh）

系统原生 DoH 模板（`223.5.5.5` / `223.6.6.6`）与网络加固已由 `scripts/windows/network.ps1` 自动下发。执行以下基线审计，验证 DNS 加密状态与多网卡解析防泄漏：

### 1. 终端自动化批量探测（pwsh）

```powershell
$id = (Invoke-RestMethod -Uri "https://bash.ws/dnsleak/test").Trim()
1..10 | ForEach-Object { Resolve-DnsName -Name "$_.$id.bash.ws" -Type A -ErrorAction SilentlyContinue | Out-Null }
Invoke-RestMethod -Uri "https://bash.ws/dnsleak/test/$id" | Format-Table type, ip, country_name, asn
```

### 2. 物理网卡底层端口抓包审计（管理员 pwsh）

通过 Windows 原生包监视器验证活动物理网卡是否存在未经加密的 53 端口明文请求：

```powershell
pktmon start --capture --pkt-size 64 --comp nics
Resolve-DnsName -Name "www.bing.com"
pktmon stop; pktmon etl2txt PktMon.etl
Select-String -Path PktMon.txt -Pattern "port 53"
```

### 3. 在线漏失与指纹核验

- **DNS 泄漏与上游归属**：[DNSLeakTest](https://www.dnsleaktest.com) / [BrowserLeaks DNS](https://browserleaks.com/dns)
- **WebRTC 局域网与公网直连泄漏**：[BrowserLeaks WebRTC](https://browserleaks.com/webrtc)

### 4. 恢复物理网卡 DNS 为自动获取 (DHCP)（管理员 pwsh）

在酒店、机场或校园网遇到 Web 认证弹窗（Captive Portal）受阻时，临时恢复物理网卡为 DHCP 自动分发：

```powershell
Get-NetAdapter -Physical | Set-DnsClientServerAddress -ResetServerAddresses
```

> **恢复 DoH 黄金基线**：完成网络认证后，执行 `pwsh -File scripts\windows\network.ps1` 即可一键重新下发阿里 DoH 安全模板。

### 5. 按需开启物理网卡 IPv6（管理员 pwsh）

系统加固脚本 `scripts/windows/network.ps1` 默认对物理网卡解绑 IPv6，并在协议栈底层固化了 RFC 6724 优先 IPv4 前缀策略（消除 GFW `2001::1` 旁路投毒与 Happy Eyeballs 双栈卡顿）。

若后续因 **PT/BT 保种刷流、公网 IPv6 远程桌面直连或校园网免流** 需使用 IPv6，仅需恢复网卡绑定即可即时生效（由于系统底层已提前固化 IPv4 优先，开箱即免受投毒干扰）：

```powershell
Get-NetAdapter -Physical | Enable-NetAdapterBinding -ComponentID ms_tcpip6
```

> **重新关闭物理网卡 IPv6**：
> ```powershell
> Get-NetAdapter -Physical | Disable-NetAdapterBinding -ComponentID ms_tcpip6
> ```

