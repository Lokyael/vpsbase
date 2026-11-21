# Windows 新装配置

适用 Windows 11 Pro en-US **26H2 或更新版本**、PowerShell 7+。

## 1. 准备

- **全盘删除**。备份数据、应用配置、授权材料和 BitLocker 恢复密钥到其他介质并抽查可读性。
- **离线介质准备**：准备可直接启动的 PowerShell 7+（pwsh）便携环境、本仓完整环境、驱动安装包。

阶段 2–4 保持断网：不插网线、不连接 Wi-Fi。键鼠可接入；音频外设在声卡驱动安装并重启后接入，蓝牙设备在驱动就绪后配对。

## 2. 安装与分区（断网）

1. BIOS 选择混合显卡模式（Hybrid／Dynamic），保持 Secure Boot 启用；不刷 BIOS／EC。
2. 从 UEFI 介质启动，选择 Pro、自定义安装；仅删除目标盘分区，选择未分配空间安装。
3. OOBE 按 `Shift+F10` 执行：

```cmd
start ms-cxh:localonly
```

- 输入纯英文字符本地用户名，密码留空免密保。
- 隐私与诊断选项全部置为 **关闭 / 否** 直达桌面。

4. 磁盘管理规划 C／D：
- **压缩 C 盘**：保留主分区物理容量为 **`131076`** MB（对齐 128 GB 整数显示，含 4 MB 元数据补偿）。
- **新建 D 盘**：将剩余未分配空间格式化为 NTFS 数据盘。

## 3. 驱动

按对应机型安装器要求安装、重启；保持混合显卡模式。

| 介质目录 | 操作 |
| :--- | :--- |
| `00-固件与BIOS[仅存档-禁止执行]` | 不执行 |
| `01-主板芯片组` | AMD 芯片组 |
| `02-有线网卡`、`03-无线网卡`、`04-蓝牙` | 安装驱动，仍不联网／配对 |
| `05-底层与电源` | ACPI、电源、Fn 组件 |
| `06-核心显卡` | 纯 INF 驱动（不装控制台外壳） |
| `07-独立显卡` | 仅驱动／清洁安装 |
| `08-显示器驱动` | 对应面板 INF／DisplayHDR |
| `09-声卡`、`10-摄像头` | 对应设备驱动 |
| `11-屏幕校色` | 配置正确屏幕的 ICC |

### 配置屏幕 ICC
- 拷贝屏幕校色文件 icm 到 `C:\Windows\System32\spool\drivers\color\`
- 复制完成后，Win+R 输入 `colorcpl` 并回车；
- 选择内置显示器，启用自行配置，添加并设为默认配置文件。

完成后重启，检查设备管理器，确认驱动正常且无未知设备。

## 4. 首轮基线（断网，管理员 pwsh）

驱动完成并重启后，用桌面登录账号提权启动 U 盘 pwsh。保存工作、退出相关应用，确认脚本展示的 Purpose／Impact 后执行。

**基线会禁止自动加密并完全解密系统卷及固定数据卷，失去 BitLocker 离线保护；先备份数据与恢复材料，断开不希望解密的外接固定盘，移动卷不纳管。**

在仓库根目录执行：

```powershell
pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1
```

执行后查看看板与待办：
- **全量基线合规**：七大模块（telemetry, shell, search, services, network, components, performance）均已调度，外壳模块就绪原生 US 键盘且不引入自带输入法，正常情况下全量合规退出（退出码 0）。任何模块未知、偏离或执行失败均需排查，不能视作正常。
- **联网前门禁核对**：
  - 确认网络模块无未知阻断且执行通过，驱动更新排除策略（`ExcludeWUDriversInQualityUpdate = 1`）已写入（此策略阻断质量更新推送驱动，不阻断手动安装公版驱动）；
  - 若无线网卡高级属性或 WMI 节点在网络模块中报告未知且无法离线解决，停止并由用户明确评估联网风险；无未知阻断且确认后方可进入步骤 5 联网。

## 5. 应用底座与运行库（联网，管理员 pwsh）

打开**管理员 pwsh**，并联网。

在仓库根目录执行：

```powershell
pwsh -File desktop\apps\setup.ps1 -Action Sync -Apps runtimes
```

- 该步骤将自动就绪 D 盘基础目录（`D:\act`, `D:\arc`, `D:\prog`, `D:\res`）、Scoop 包管理器与核心工具链（`git`, `7zip`, `aria2`, `pwsh` 及 `extras` bucket 与 aria2 高并发切片配置），并通过官方权威直链安装 Visual C++ 2015-2022 (x64/x86)、.NET 10 Desktop Runtime 与 Evergreen WebView2 运行库。
- 完成后退出当前会话，拔出 U 盘，从本地打开新的普通 pwsh 验证入口来自 `D:\prog\scoop`：

```powershell
$PSVersionTable.PSVersion
Get-Command pwsh, scoop, git, 7z, aria2c | Select-Object Name, Source
scoop list
scoop bucket list
```

数据盘目录按生命周期区分：

| 路径 | 用途与维护约定 |
| :--- | :--- |
| `D:\act` | 活跃项目；结项后人工清理构建缓存并迁入 `D:\arc` |
| `D:\arc` | 已结项归档，原则上只读封存 |
| `D:\prog` | 应用、Scoop 与 WSL |
| `D:\res` | 独立于软件生命周期的配置、文档与媒体资产，优先备份 |

Git 设置见 [Git 基础配置](../../tools/git/git.md#基础配置)。

## 6. 语言与应用

### 本地密码与显示语言（管理员 pwsh，仅首次）

使用同一桌面账号打开**管理员 pwsh**。通过 PowerShell 原生命令设置本地登录密码，为锁屏防御与 Windows Hello（PIN / 指纹）打底：

```powershell
Set-LocalUser -Name $env:USERNAME -Password (Read-Host -AsSecureString "请设置本地账户登录密码")
```

### 核心应用与中文环境部署（管理员 pwsh）

准备含所需应用脚本及辅助文件的同源本地脚本，在同一管理员会话中从根目录执行核心应用部署（Rime 脚本自动拉取 zh-CN 语言包并设为首选显示语言、锁定小狼毫为中文唯一输入法，从源头彻底杜绝系统自带微软拼音的激活与暴露）：

```powershell
pwsh -File desktop\apps\setup.ps1 -Action Sync -Apps zen-browser,rime
```

安装器若启动应用，退出后重跑配置；设置默认浏览器。其他应用按需部署。

机型需要 Lenovo Legion Toolkit 时在**普通 pwsh** 安装；按需切换独显直连：

```powershell
scoop install extras/lenovolegiontoolkit
```

部署完成后**统一重启计算机**（使 LSA 保护、中文界面语言及小狼毫系统常驻服务一次性生效；重启后在系统设置 → 账户 → 登录选项配置 PIN／指纹）。

## 7. 收敛与验收（管理员 pwsh）

按待办重启／注销后，在本地脚本根目录执行：

```powershell
pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1
pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1 -Action Check -Modules all
pwsh -File desktop\apps\setup.ps1 -Action Check -Apps runtimes,zen-browser,rime
```

- 查看七模块和所选应用的状态，处理未知、失败、偏离与新增待办；**Check 退出成功不等于合规**。
- 实测浏览器链接、Rime、显示、音频、网络、蓝牙、摄像头与 Fn。
- 检查激活、安全更新、Defender、防火墙、各卷加密与恢复密钥；LSA 重启后，在事件查看器 Windows Logs → System 核验本次启动的 WinInit 事件 12、LSASS 保护级别 4，并实际测试所用认证方式。
- 确认 BitLocker 禁止自动加密值已就绪，受控固定卷均为 FullyDecrypted、0%、保护关闭；解密进行中先等待再 Check，不以 Protection Off 或命令成功代替完成。锁定或自动解锁密钥依赖按错误处理，不清 TPM 或停用 BitLocker 服务。
- 确认数据与备份可用；同盘 D 分区不算备份。
