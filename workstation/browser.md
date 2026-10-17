# 浏览器

客户端浏览器选型基准、企业策略部署、隐私加固配置。

## 选型基准

工作站浏览器采用双核收敛方案：

- **Firefox 派（Gecko 内核）**：**Zen Browser**。因 Gecko 配置与程序安装路径绑定的哈希机制，采用独立目录原生维护（`D:\prog\zen-browser\`），由官方通道自更新，切勿使用 Scoop 托管。
- **Chrome 派（Chromium 内核）**：**Brave**。剥离 Google 账户与遥测服务，采用 Scoop 软件包管理器纳管：
  ```powershell
  scoop install extras/brave
  ```

---

## Zen Browser 部署与企业策略

安装目录规范为 `D:\prog\zen-browser\`。通过绿色解压避免安装后台维护服务（`MozillaMaintenance`）；通过企业策略 `distribution\policies.json` 与首选项 `defaults\pref\` 分发语言包、扩展（uBlock Origin、Bitwarden）、系统默认浏览器关联、WebRTC 防泄漏、反追踪及禁用应用层安全 DNS（`network.trr.mode = 5`，交由系统网络栈）：

- **禁用云端账号**：企业策略注入 `DisableFirefoxAccounts = true`，禁用账号登录与同步功能；
- **静默开屏与关末新建空白页**：注入 `zen.welcome-screen.seen = true` 跳过初次启动向导，开启 `zen.workspaces.open-new-tab-if-last-unpinned-tab-is-closed = true` 防止关完全部普通标签时回弹激活常驻固定网页；
- **默认下载目录**：保持系统默认 Downloads 目录（`C:\Users\<用户>\Downloads`），关闭重复下载提示。

### 自动化部署与策略配置（pwsh）

在 PowerShell 7（`pwsh`）中执行自动化脚本（支持五大通用操作模式与交互向导）：

```powershell
# 1. 全流程纯净部署与增量策略配置（交互式向导，回车直接采纳推荐基线）
pwsh -File scripts\apps\zen-browser.ps1

# 2. 状态体检巡检（只查不改，逐项输出 Diff，零磁盘与注册表写入）
pwsh -File scripts\apps\zen-browser.ps1 -CheckOnly

# 3. 仅更新企业策略、语言包与扩展（跳过程序下载）
pwsh -File scripts\apps\zen-browser.ps1 -ConfigOnly

# 4. 彻底清洁卸载（强制终止进程，注销系统关联并抹除安装目录与本地缓存）
pwsh -File scripts\apps\zen-browser.ps1 -Uninstall
```

---

## Brave 隐私与反追踪配置

进入 Brave 设置页固化安全基线：

1. **WebRTC 防护与常规隐私 (`brave://settings/privacy`)**：
   - `WebRTC IP handling policy`：设为 `Disable non-proxied UDP`（禁用非代理 UDP，阻断探测物理网卡与私有 IP）。
   - 开启「随浏览流量发送“不跟踪”请求 (Do Not Track)」。
   - 关闭诊断上报（Send diagnostic reports）与使用统计（daily usage ping）。
   - 关闭 Brave Rewards、Brave Wallet 及首页新闻流，剥离后台非必要网络活动。
2. **Shields 防护与指纹防御 (`brave://settings/shields`)**：
   - Trackers & ads blocking：设为 `Aggressive`（强效拦截）。
   - Block fingerprinting：设为 `Standard`（启用 Farbling 随机混淆扰动）。
   - Block third-party cookies：保持开启。
3. **安全 DNS (`brave://settings/security`)**：
   - 设为「使用系统设置」或关闭应用层独立安全 DNS，由操作系统网络栈统一解析。

---

## uBlock Origin 防护基线

全局拦截防护统一收敛至 uBlock Origin 扩展。核心策略涵盖阻断 WebRTC 本地 IP 泄漏、禁用超链接审计与页面预读取，并激活 EasyPrivacy 与 Block Outsider Intrusion into LAN（阻断外网探测局域网）规则集。

---

## 浏览器指纹防护与分层隔离

- **生产力基准**：
  - **Zen Browser (Gecko)**：开启 `privacy.fingerprintingProtection = true`（FPP），对 Canvas、AudioContext 与硬件并发数实施噪声微扰；
  - **Brave (Chromium)**：Shields 将 Fingerprinting 设为 `Standard`（Farbling 随机微扰）；
- **高风控业务隔离**：下沉至独立 Profile 或专属虚拟机环境，固化时钟、语言与字体，避免污染日常环境。

---

## 验证清单

1. **WebRTC 局域网泄漏**：[BrowserLeaks WebRTC](https://browserleaks.com/webrtc)，确认 `Local IP Address` 显示为空或被拦截。
2. **指纹抗追踪等级**：[EFF Cover Your Tracks](https://coveryourtracks.eff.org)，确认保护状态为 `Strong protection`。
3. **DNS 加密状态**：[DNSLeakTest](https://www.dnsleaktest.com)，确认上游解析归属已配置的安全 DNS，无本地明文劫持。
