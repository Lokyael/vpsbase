# Windows 新装配置

适用 Windows 11 Pro en-US **26H2 或更新版本**、PowerShell 7+。

## 1. 离线准备

- **全盘删除**：备份数据、配置、授权材料与 BitLocker 恢复密钥到其他介质并抽查可读性。
- **介质准备**：便携 PowerShell 7+（pwsh）、本仓完整源码、驱动安装包。
- **断网约束**：步骤 2–4 全程断网；音频外设待声卡驱动重启后接入，蓝牙待驱动就绪后配对。

## 2. 安装与分区（断网）

1. BIOS 设混合显卡模式（Hybrid/Dynamic）、保持 Secure Boot 启用（不刷 BIOS/EC）。
2. UEFI 启动选择 Pro、自定义安装：仅删目标盘分区，选未分配空间安装。
3. OOBE 按 `Shift+F10` 执行：
   ```cmd
   start ms-cxh:localonly
   ```
   输入纯英文用户名，密码留空，隐私与诊断全选 **关闭 / 否** 直达桌面。
4. 磁盘管理划分 C/D 盘：
   - **压缩 C 盘**：主分区物理容量设为 **`131076`** MB（对齐 128 GB 显示）。
   - **新建 D 盘**：剩余未分配空间格式化为 NTFS。

## 3. 驱动安装（断网）

按目录顺序安装、按需重启（保持混合显卡模式）：

| 介质目录 | 操作 |
| :--- | :--- |
| `00-固件与BIOS[仅存档-禁止执行]` | 不执行 |
| `01-主板芯片组` | AMD 芯片组 |
| `02-有线网卡`、`03-无线网卡`、`04-蓝牙` | 安装驱动（仍不联网/配对） |
| `05-底层与电源` | ACPI、电源、Fn 组件 |
| `06-核心显卡` | 纯 INF 驱动（不装控制台外壳） |
| `07-独立显卡` | 仅驱动/清洁安装 |
| `08-显示器驱动` | 对应面板 INF/DisplayHDR |
| `09-声卡`、`10-摄像头` | 对应设备驱动 |
| `11-屏幕校色` | 拷贝 `.icm` 至 `C:\Windows\System32\spool\drivers\color\`，Win+R 运行 `colorcpl` 设为默认 |

完成后重启，核对设备管理器无异常或未知设备。

## 4. 首轮基线（断网）`[管理员 pwsh]`

使用桌面账号启动 U 盘 pwsh（管理员），保存工作并确认脚本提示后在仓库根目录执行。

**基线会禁止自动加密并完全解密系统卷及固定数据卷，失去 BitLocker 离线保护；先备份数据与恢复材料，断开不希望解密的外接固定盘，移动卷不纳管。**

```powershell
pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1
```

**联网前核对**：七大模块须全量合规退出（退出码 0），且 `ExcludeWUDriversInQualityUpdate = 1` 已生效；若网络或无线属性报告未知且无法离线解决，先评估风险再决定是否联网。

## 5. 应用底座与运行库（联网）`[管理员 pwsh]`

联网后在仓库根目录执行（自动创建 D 盘目录并安装 Scoop、基础工具与 VC++/.NET 10/WebView2）：

```powershell
pwsh -File desktop\apps\setup.ps1 -Action Sync -Apps runtimes
```

完成后退出并拔出 U 盘，打开本地普通 pwsh 核验入口均来自 `D:\prog\scoop`：

```powershell
$PSVersionTable.PSVersion
Get-Command pwsh, scoop, git, 7z, aria2c | Select-Object Name, Source
scoop list
scoop bucket list
```

| D 盘目录 | 用途 |
| :--- | :--- |
| `D:\act` | 活跃项目（结项清理缓存后移入 `D:\arc`） |
| `D:\arc` | 只读归档项目 |
| `D:\prog` | 应用与 Scoop |
| `D:\res` | 独立配置、文档与媒体资产（优先备份） |

Git 配置见 [Git 基础配置](../../tools/git/git.md#基础配置)。

## 6. 账户密码、语言与核心应用 `[管理员 pwsh]`

1. 设置本地登录密码（为锁屏与 Windows Hello 打底）：
   ```powershell
   Set-LocalUser -Name $env:USERNAME -Password (Read-Host -AsSecureString "请设置本地账户登录密码")
   ```
2. 部署浏览器与中文输入环境（Rime 自动拉取 zh-CN 语言包并设为唯一中文输入法；安装器若自启应用，退出后重跑）：
   ```powershell
   pwsh -File desktop\apps\setup.ps1 -Action Sync -Apps zen-browser,rime
   ```
3. 按需在**普通 pwsh** 安装 Lenovo Legion Toolkit：
   ```powershell
   scoop install extras/lenovolegiontoolkit
   ```
4. **统一重启计算机**，并在设置 → 账户 → 登录选项配置 PIN/指纹与默认浏览器。

## 7. 收敛与验收 `[管理员 pwsh]`

```powershell
pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1
pwsh -ExecutionPolicy Bypass -File desktop\os\setup.ps1 -Action Check -Modules all
pwsh -File desktop\apps\setup.ps1 -Action Check -Apps runtimes,zen-browser,rime
```

**结果核验**：
- 核对看板无未知、偏离、失败或剩余待办（Check 退出 0 不等于合规）。
- 实测浏览器、Rime、显示、音频、网络、蓝牙、摄像头与 Fn 键。
- 核验激活、安全更新、Defender、防火墙，并在事件查看器 `Windows Logs -> System` 核验本次启动 WinInit 事件 12 与 LSASS 保护级别 4。
- 确认受控固定卷均为 `FullyDecrypted`、0%、保护关闭（解密进行中须待完成后复查）。
- 确认重要数据已备份至外部介质（同盘 D 分区不算备份）。
