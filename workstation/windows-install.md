# Windows 纯净安装与冷启动打底

Windows 11 专业版无保留纯净安装、驱动按序打底与冷启动基础设施自举。

---

## 阶段零：前置运行时与介质准备

### 1. 便携运维工具箱（置于 U 盘介质）
在装机进入桌面后、本地环境就绪前，所有运维指令在 U 盘便携环境中以管理员身份启动：

- **便携版 PowerShell 7+ (`pwsh.exe`)**：绿色免安装自包含目录，作为装机流程的 Shell 执行载体。
- **离线驱动打底包**：驱动按序放置于物理介质。

### 2. 引导介质准备
使用 Ventoy 制作 UEFI 启动 U 盘，置入最新 Windows 11 专业版官方原版 ISO 镜像：
- **常规使用**：直接选择简体中文版（`zh-cn`）。
- **隐私与防指纹画像优先**：推荐美版原版（`en-us`）。底层安装语言（`InstallLanguage: 0409`）物理固化且原生仅含纯 US 键盘，杜绝输入法云端词库上报并提升系统底层一致性。

---

## 阶段一：固件配置与磁盘重建

### 1. BIOS 关键设置
- 开启计算机按快捷键（如 `F2`）进入 BIOS 界面。
- **双显卡供电策略**：切换为 **混合模式（Dynamic Graphics / Hybrid Mode）**。装机打底阶段必须确保集成核显与独立显卡均处于通电握手状态，避免显卡驱动打底阶段遗漏核显底层总线识别；待全部驱动部署完毕后，再按需切回独显直连。
- **安全启动**：保持 `Secure Boot: Enabled`。
- 保存退出，进入引导菜单（如 `F12`），选择 Ventoy UEFI 启动项。

### 2. 磁盘全盘重建（自定义安装）
- 安装程序选中 Win11 专业版 ISO，进入“自定义：仅安装 Windows（高级）”。
- **全盘清空**：认准内置系统 NVMe 固态硬盘，依次删除现有所有旧分区，归一为单一未分配空间。
- 选中该未分配空间直接点击下一步执行安装。

### 3. OOBE 阶段离线绕过与本地账号
进入 OOBE 欢迎界面的网络连接环节，按 `Shift + F10` 呼出命令提示符，执行本地账户一键直达（首选）：
```cmd
start ms-cxh:localonly
```
> 激活本地账户路由（免重启且无注册表绕过留痕）。

- 若上述协议未响应，执行经典命令重启兜底：
  ```cmd
  oobe\BypassNRO
  ```
  重启后重新进入网络页，点击 **我没有 Internet 连接** -> **继续执行受限设置**。
- **免密保创建**：输入纯英文字符本地用户名后，密码框直接留空回车，跳过 3 个强制密保问题；隐私与诊断选项全部置为 **关闭 / 否** 直达桌面。进入桌面后再按需设置密码。

### 4. 科学分区划分
进入桌面后，右键开始菜单打开“磁盘管理”：
- **压缩 C 盘**：在“输入压缩空间量”中反算出期望的保留大小，保留主分区物理容量为 **`131076`** MB（对齐 128 GB 整数显示，含 4 MB 元数据补偿）。
- **新建 D 盘**：将剩余全部连续未分配空间全部分配并格式化为 NTFS 数据盘，盘符指定为 `D:`。

---

## 阶段二：硬件驱动离线打底（断网环境）

在接入任何网络前，严格依拓扑依赖次序从离线存储介质中执行安装包：

| 顺位 | 驱动层级 | 安装目标与说明 |
| :---: | :--- | :--- |
| **00** | **底层固件与 BIOS** | **跳过**。若驱动包内含主板 BIOS 固件刷写程序，跳过不安装，避免非必要刷写风险与配置复位 |
| **01** | **主板芯片组** | 优先全选安装，建立 PCI-E、总线拓扑与 SMBus 基础识别 |
| **02** | **网络与蓝牙** | 无线网卡、蓝牙与千兆/万兆有线网卡驱动（安装驱动后先不连网） |
| **03** | **硬件底层与电源** | ACPI 虚拟电源管理驱动，为 Fn 功耗墙与模式切换建立基础 |
| **04** | **核心显卡** | CPU 集成核显驱动（需在混合供电模式下识别总线握手） |
| **05** | **独立显卡** | 独立显卡公版驱动，选“仅显卡驱动”，勾选“清洁安装” |
| **06** | **显示面板** | 面板驱动 INF 与 DisplayHDR 色彩签名支持 |
| **07** | **色彩校准** | 原生校色配置文件或辅助校色程序（加载 sRGB 色彩空间） |
| **08** | **音频与功放** | 声卡底层驱动与机载扬声器功放调优组件 |
| **09** | **摄像头与外设** | 机载摄像头驱动及指纹/传感器等集成外设 |

驱动全部安装完毕后，重启计算机。

---

## 阶段三：系统防覆盖与驱动策略锁定

重启进入桌面后，**仍保持断网**。插入 U 盘，以管理员身份运行 U 盘内的便携版 `pwsh.exe`，注入策略阻断 Windows Update 自动覆盖公版驱动与外设推广：

```powershell
# 驱动权限锁定与外设推广阻断 (管理员 pwsh)

# ---------- 1. 禁用 Windows Update 驱动覆盖 ----------
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

# ---------- 2. 禁用驱动搜索联网 ----------
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" `
    -Name "SearchOrderConfig" -Type DWord -Value 0

# ---------- 3. 阻止设备元数据（厂商推广）从网络下载 ----------
$devMetaKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"
if (-not (Test-Path $devMetaKey)) { New-Item -Path $devMetaKey -Force | Out-Null }
Set-ItemProperty -Path $devMetaKey -Name "PreventDeviceMetadataFromNetwork" `
    -Type DWord -Value 1 -Force

# ---------- 4. 禁用共同安装器（Co-Installer） ----------
$deviceInstallKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings"
if (-not (Test-Path $deviceInstallKey)) { New-Item -Path $deviceInstallKey -Force | Out-Null }
Set-ItemProperty -Path $deviceInstallKey -Name "DisableCoInstallers" `
    -Type DWord -Value 1 -Force

# ---------- 5. IFEO 阻断静默外设安装器 ----------
$ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RazerInstaller.exe"
if (-not (Test-Path $ifeoKey)) { New-Item -Path $ifeoKey -Force | Out-Null }
Set-ItemProperty -Path $ifeoKey -Name "Debugger" `
    -Value "systray.exe" -Type String -Force
```

---

## 阶段四：网络接入与永久数字激活

1. 接入网络，确保网络通畅。
2. 在管理员便携 pwsh 中调用官方激活服务脚本（按提示键入 `1` 永久绑定 HWID 数字许可证）：
   ```powershell
   irm https://get.activated.win | iex
   ```

---

## 阶段五：数据盘初始化与包管理器自举

在管理员便携 pwsh 中一键完成 D 盘基础目录初始化、包管理器部署（或旧盘无损复原）与核心工具链自举：

### 1. 数据盘初始化与包管理器自举（一键流水线）
将 Scoop 根目录固化至数据盘（`D:\prog\scoop`），遵循纯单用户免提权模型（不设 `SCOOP_GLOBAL`）。脚本自动探测历史环境：旧盘秒级无损复原，新盘自动化安装并拉取核心工具链与并发加速引擎：

```powershell
# 1. D 盘生命周期工作区初始化
New-Item -ItemType Directory -Path "D:\act", "D:\arc", "D:\prog", "D:\res" -Force | Out-Null

# 2. 固化 SCOOP 持久化用户环境变量
$scoopPath = "D:\prog\scoop"
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
if ([Environment]::GetEnvironmentVariable('SCOOP', 'User') -ne $scoopPath) {
    [Environment]::SetEnvironmentVariable('SCOOP', $scoopPath, 'User')
}
$env:SCOOP = $scoopPath

# 3. 智能探测：旧盘无损复原 vs 全新初始化
if (Test-Path "$scoopPath\shims") {
    # 历史系统重装复原：重新注入用户 PATH 并重置全局软链接
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $shimsPath = "$scoopPath\shims"
    if ($userPath -notmatch [regex]::Escape($shimsPath)) {
        [Environment]::SetEnvironmentVariable('Path', "$shimsPath;$userPath", 'User')
        $env:Path = "$shimsPath;$env:Path"
    }
    scoop reset *
    Write-Host "✔ 检测到历史 Scoop 环境，应用软链接与 PATH 已秒级无损复原" -ForegroundColor Green
} else {
    # 全新系统初始化安装
    irm get.scoop.sh | iex
}

# 4. 核心基石 CLI 工具自举与并发加速配置
scoop install git 7zip aria2 pwsh
scoop config aria2-enabled true
scoop config aria2-warning-enabled false
scoop config aria2-max-connection-per-server 16
scoop config aria2-split 16
scoop config aria2-min-split-size 1M
scoop bucket add extras

# 5. Git 现代跨平台与中文防乱码基础基线
git config --global init.defaultBranch main
git config --global push.autoSetupRemote true
git config --global pull.rebase false
git config --global fetch.prune true
git config --global core.autocrlf false
git config --global core.eol lf
git config --global core.safecrlf warn
git config --global core.quotepath false
```

> 可拔出 U 盘退出便携运维环境，转入系统主环境运行正式管理员 pwsh。

### 2. 硬件控制台与工作模式复位（按需）
针对具备独显直连与电池管理特性的机型（如拯救者），通过 Scoop 安装轻量控制台：
```powershell
scoop install extras/lenovolegiontoolkit
```
- **显卡复位**：控制台切换为“独显直连 / Discrete Only”（重启生效，释放低延迟与 G-Sync 性能）。

### 3. 常用工具选配（按需，pwsh）

```powershell
# Nushell、极简播放器与快速看图
scoop install nu extras/mpv extras/picview bulk-crap-uninstaller everything brave

# （可选）mpv 在线串流解析与混流后端
scoop install yt-dlp ffmpeg

# （可选）安装 zedg（Zed 社区中文版）
scoop bucket add zedg https://github.com/x6nux/scoop-zedg
scoop install zedg
```
