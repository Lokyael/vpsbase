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
- **`res`（Resources）**：长期复利积累的基石资产，生命周期无限长，最高优先级备份。

---

## 工作站系统基线编排与加固（管理员 pwsh）

系统服务裁剪、隐私阻断、外壳交互与性能调优统一由编排门面 `scripts/setup-windows.ps1` 调度纳管，各模块解耦自治于 `scripts/windows/`。执行默认交互审查，支持定向模块与非交互流水线。

> **提权前提**：日常账号须为管理员组成员（Consent 提权），避免在标准用户下通过 OTS 提权导致 `HKCU` 配置写入错误用户。

```powershell
# 1. 远程一键调用编排门面（管理员 pwsh，内置远程内存沙盒自适应调度）
irm https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/setup-windows.ps1 | iex

# 2. 本地执行（管理员 pwsh）
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1                    # 交互式引导全流程
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile Full -Yes # 个人黄金基线一键全量
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile General -Yes # 通用稳健预设 (跳过激进深度优化项)
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Mode CheckOnly   # 全量只读体检巡检
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Modules shell,performance # 定向加固指定模块

# 3. 亦可单独单跑任一自治子模块 (100% 独立自闭合)
pwsh -ExecutionPolicy Bypass -File scripts\windows\shell.ps1 -Mode CheckOnly
```

---

## 独立配置与组件补充（管理员 pwsh）

### CLI 按需拉取硬件编解码扩展

微软商店后台自动更新与下载已由脚本策略阻断（`AutoDownload = 2`），未运行状态下零资源占用。系统保留其作为底层包管理管道，供 `winget` 按需拉取常用底层媒体扩展：

```powershell
winget install 9MVZQVXJBQ9V --source msstore --accept-source-agreements --accept-package-agreements # AV1 视频扩展
winget install 9PMMSR1CGPWG --source msstore --accept-source-agreements --accept-package-agreements # HEIF 图像扩展
winget install 9N4D0MSFG394 --source msstore --accept-source-agreements --accept-package-agreements # VP9 视频扩展
winget install 9N5TDP8VCMHS --source msstore --accept-source-agreements --accept-package-agreements # Web 媒体扩展
winget install 9MZ95KL8MR0L --source msstore --accept-source-agreements --accept-package-agreements # 微软截图 (Snipping Tool)
```

### 锁死 Windows 11 当前大版本（防止跨版本强升）

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

### DLSS 3 帧生成开启 HAGS

显卡为 NVIDIA RTX 40 系列且游戏需要 DLSS 3 帧生成时开启（重启生效）：

```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Type DWord -Value 2 -Force
```

### 恢复物理网卡 DNS 为自动获取 (DHCP)

若在酒店、公共 Wi-Fi 或校园网遇到 Web 认证弹窗受阻，恢复物理网卡为 DHCP 自动分发：

```powershell
Get-NetAdapter -Physical | Set-DnsClientServerAddress -ResetServerAddresses
```
