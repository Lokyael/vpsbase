# Windows 纯净安装与冷启动打底

Windows 11 专业版无保留纯净安装、驱动按序打底与冷启动基础设施自举。

---

## 阶段零：前置运行时与介质准备

### 1. 便携运维工具（置于 U 盘介质）

- **便携版 PowerShell 7+ (`pwsh.exe`)**：绿色免安装自包含目录，作为装机冷启动的 Shell 运行时载体。
- **离线驱动打底包**：按依赖顺位提前放置于物理存储介质。

### 2. 引导介质准备

使用 Ventoy 制作 UEFI 启动 U 盘，置入最新 Windows 11 专业版官方美版原版 ISO 镜像（`en-us`）。

### 3. 外设接入时序策略

- **键盘与鼠标（USB / 2.4G 接收器）**：全程接入。装机打底阶段（阶段一至阶段三）必须严格保持物理断网，切断厂商设备元数据（Device Metadata）检索与协同安装器（Co-Installer）下载通道，防止厂商全家桶静默注入。
- **耳机与音频设备（3.5mm 模拟 / USB DAC / 外置声卡）**：待阶段二声卡驱动部署完成并重启系统后再行接入。避免声卡底层驱动重构音频总线与功放校准时，因插孔阻抗侦测（Jack Detection）抢占默认音频终结点（Audio Endpoint）导致输出通道错乱。
- **蓝牙外设**：待阶段二无线网卡与蓝牙驱动部署完成、进入系统主环境后再行配对。

---

## 阶段一：固件配置与磁盘重建

### 1. BIOS 关键设置

- 开启计算机按快捷键（如 `F2`）进入 BIOS 界面。
- **显卡供电策略**：切换为 **混合模式（Dynamic Graphics / Hybrid Mode）**。打底阶段必须确保集成核显与独立显卡均处于通电握手状态，避免显卡驱动打底阶段遗漏核显底层总线识别；待全部驱动部署完毕后，再按需切回独显直连。
- **安全启动**：保持 `Secure Boot: Enabled`。
- 保存退出，进入引导菜单（如 `F12`），选择 Ventoy UEFI 启动项。

### 2. 磁盘全盘重建（自定义安装）

- 安装程序选中 Win11 专业版 ISO，进入“自定义：仅安装 Windows（高级）”。
- 认准内置系统 NVMe 固态硬盘，删除现有所有旧分区，归一为单一未分配空间，直接点击下一步执行安装。

### 3. OOBE 阶段离线绕过与本地账号

进入 OOBE 网络连接环节，按 `Shift + F10` 呼出命令提示符，执行本地账户直达路由：

```cmd
start ms-cxh:localonly
```

- **免密保**：输入纯英文字符本地用户名，**密码框直接留空回车**（跳过密保提问，待阶段四交接时设置）。
- 隐私与诊断选项全部置为 **关闭 / 否** 直达桌面。

### 4. 科学分区划分

进入桌面后，右键开始菜单打开“磁盘管理”：

- **压缩 C 盘**：保留主分区物理容量为 **`131076`** MB（对齐 128 GB 整数显示，含 4 MB 元数据补偿）。
- **新建 D 盘**：将剩余全部连续未分配空间格式化为 NTFS 数据盘，盘符指定为 `D:`。

---

## 阶段二：硬件驱动离线打底（断网环境）

在接入任何网络前，严格依拓扑依赖次序从离线存储介质中执行安装包：

|  顺位  | 驱动层级            | 安装目标与说明                                                                         |
| :----: | :------------------ | :------------------------------------------------------------------------------------- |
| **00** | **底层固件与 BIOS** | **跳过**。若驱动包内含主板 BIOS 固件刷写程序，跳过不安装，避免非必要刷写风险与配置复位 |
| **01** | **主板芯片组**      | 优先全选安装，建立 PCI-E、总线拓扑与 SMBus 基础识别                                    |
| **02** | **网络与蓝牙**      | 无线网卡、蓝牙与千兆/万兆有线网卡驱动（安装驱动后先不连网）                            |
| **03** | **硬件底层与电源**  | ACPI 虚拟电源管理驱动，为 Fn 功耗墙与模式切换建立基础                                  |
| **04** | **核心显卡**        | CPU 集成核显驱动（需在混合供电模式下识别总线握手）                                     |
| **05** | **独立显卡**        | 独立显卡公版驱动，选“仅显卡驱动”，勾选“清洁安装”                                       |
| **06** | **显示面板**        | 面板驱动 INF 与 DisplayHDR 色彩签名支持                                                |
| **07** | **色彩校准**        | 原生校色配置文件或辅助校色程序（加载 sRGB 色彩空间）                                   |
| **08** | **音频与功放**      | 声卡底层驱动与机载扬声器功放调优组件                                                   |
| **09** | **摄像头与外设**    | 机载摄像头驱动及指纹/传感器等集成外设                                                  |

驱动全部安装完毕后，重启计算机。

---

## 阶段三：系统防覆盖与离线基线加固

驱动全部部署完毕并重启进入桌面后，**仍保持物理断网**。

> **时序红线**：严禁在驱动安装过程中并发执行系统加固，必须待全部驱动部署完毕并重启系统后方可进行（系统加固包含 `DisableCoInstallers` 与驱动防覆盖策略，提前执行会导致驱动依赖被组策略阻断）。

插入 U 盘，以管理员身份运行便携版 `pwsh.exe`，切换至 U 盘根目录执行全量系统加固：

```powershell
pwsh -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Profile Full -Yes
```

---

## 阶段四：网络接入、数据盘初始化与包管理器自举

### 1. 数据盘初始化与包管理器自举（一键流水线）

接入网络，在便携 `pwsh` 中一键完成 D 盘工作区初始化与包管理器自举（将 Scoop 固化至 `D:\prog\scoop`，自动适配全新部署与旧盘复原）：

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

---

### 2. 环境交接与硬件模式复位（冷启动终态）

基础运行时与核心基石工具链就绪后，拔出 U 盘退出便携运维环境，在系统主环境中以管理员身份启动正式 `pwsh`，完成收尾配置：

#### 1. 设置本地账户登录密码

通过 PowerShell 原生命令设置本地登录密码，为锁屏防御与 Windows Hello（PIN / 指纹）打底：

```powershell
Set-LocalUser -Name $env:USERNAME -Password (Read-Host -AsSecureString "请设置本地账户登录密码")
```

> 设置密码后，即可按需在 Windows“设置 → 账户 → 登录选项”中录入 PIN 码或指纹（Windows Hello）实现日常秒速解锁。

#### 2. 硬件模式复位与独显直连

针对具备独显直连与电池管理特性的机型（如拯救者），通过 Scoop 安装轻量控制台并切换为“独显直连 / Discrete Only”（重启生效，释放低延迟与 G-Sync 性能，闭环阶段一的供电策略）：

```powershell
scoop install extras/lenovolegiontoolkit
```
