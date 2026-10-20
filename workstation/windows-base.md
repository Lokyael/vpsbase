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
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile Full -Yes # 全量工程基线一键应用
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile General -Yes # 通用基线一键应用 (跳过深度裁剪项)
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

## 隐私加固、区域时区与防指纹基线（管理员 pwsh）

操作系统底层物理位置、墨迹击键遥测、区域时区与编码基准已由加固体系（`telemetry.ps1`、`network.ps1`、`performance.ps1`、`shell.ps1`）原生纳管收敛：

| 领域 | 受控基准 | 技术目的与防指纹意图 |
| :--- | :--- | :--- |
| **地理位置与传感器** | 组策略阻断 `DisableLocation=1` / `LetAppsAccessLocation=2`，停用 `lfsvc` 服务 | 物理切断 Wi-Fi BSSID 与 IP 定位探测，应用权限硬拒绝且永不弹窗打扰 |
| **键入与墨迹隐私** | 阻断 `TabletPC` / `InputPersonalization` / 撤销隐私协议 | 切断笔迹样本与击键文本云端上传，禁止通讯录人脉挖掘与键入画像分析 |
| **时间同步协议 (NTP)** | `time.cloudflare.com,0x9 pool.ntp.org,0x9 time.apple.com,0x9` | 替换微软官方节点为 Anycast 高可用集群，消除握手超时与存活心跳遥测 |
| **系统时区与自更新** | 锁定 `Singapore Standard Time` (UTC+8)，禁用 `tzautoupdate` | 通用低熵东八区画像（无夏令时干扰），消除位置轮询且避免与出站网络冲突 |
| **时间格式与制式** | 锁定标准 24 小时制 (`sShortTime = HH:mm`, `sTimeFormat = HH:mm:ss`) | 杜绝上下午 (AM/PM) 语义歧义，净化任务栏与时钟显示，保留标准 Locale 定义 |
| **编码与底层代码页** | 全局启用 Unicode UTF-8 (`ACP/OEMCP/MACCP = 65001`) | 彻底解决终端与现代开发工具链中文乱码（重启系统后生效） |
| **国家、格式与键盘** | 国家设为 United States (GeoID 244)，格式 `en-US`，纯 US 键盘 | 契合全球基数最大基准画像，切断特定营销组件与输入法焦点抢占 |

### 只读审计实机状态（pwsh）

```powershell
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Action Check
```

---

## 网络安全与 DNS 泄漏审计（管理员 pwsh）

系统原生 DoH 模板（`223.5.5.5` / `223.6.6.6`）与网络加固已由 `scripts/windows/network.ps1` 自动下发。

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

> **恢复 DoH 工程基线**：完成网络认证后，执行 `pwsh -File scripts\windows\network.ps1` 即可一键重新下发阿里 DoH 安全模板。

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

