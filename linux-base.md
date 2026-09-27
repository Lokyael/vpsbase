# Linux 基础

Linux 文件系统目录结构、命令行常用操作（文件 / 权限 / 进程 / 压缩归档）及网络基础概念笔记。

## 目录结构

| 目录 | 说明与用途 |
| :--- | :--- |
| `/` | 根目录，整个文件系统的起点 |
| `/home` | 普通用户家目录 |
| `/root` | root 超级管理员家目录 |
| `/boot` | 引导文件与系统启动所需文件 |
| `/usr` | 存放系统软件、共享库和只读数据 (User System Resources) |
| `/bin` | 系统的基础二进制命令（如 `ls`, `cp` 等） |
| `/sbin` | 系统管理与维护相关的二进制命令 (system binary) |
| `/etc` | 系统全局配置文件 |
| `/var` | 运行期产生的可变数据（如日志、缓存等） |
| `/opt` | 可选的第三方附加软件包 (optional) |
| `/tmp` | 临时文件存放目录，系统定期清理 |

## 文件与目录操作

```sh
# 查看当前工作目录
pwd

# 列出目录内容
ls
ls -a               # 包含隐藏文件（以 . 开头）
ls -l               # 详细列表（权限、属主、大小、修改时间等）
ls -la              # 组合使用

# 切换目录
cd [HERE_PATH]      # 切换到指定路径
cd ~                # 切换到当前用户家目录（或直接 cd）
cd -                # 切换到上一次所在目录
cd ..               # 切换到上一级目录

# 创建目录
mkdir [HERE_DIR]
mkdir -p [HERE_DIR] # 递归创建多级目录

# 复制文件或目录
cp [HERE_SRC] [HERE_DEST]
cp -r [HERE_SRC_DIR] [HERE_DEST_DIR] # 递归复制目录

# 移动或重命名
mv [HERE_SRC] [HERE_DEST]

# 删除文件或目录
rm [HERE_FILE]
rm -r [HERE_DIR]     # 递归删除目录
rm -f [HERE_FILE]    # 强制删除，不提示确认
rm -rf [HERE_DIR]    # 强制递归删除目录

# 查看文件内容
cat [HERE_FILE]
cat -n [HERE_FILE]   # 显示行号（含空行）

# 查看文件尾部内容
tail [HERE_FILE]                 # 默认查看末尾 10 行
tail -n [HERE_LINES] [HERE_FILE] # 查看末尾指定行数（如 -n 5）
tail -f [HERE_FILE]              # 实时追踪文件变动
```

## 用户与权限管理

### 权限模型

Linux 文件与目录的访问权限分为三类角色与三种权限：

- **角色划分**：属主 `u` (user)、属组 `g` (group)、其他用户 `o` (other)、全部 `a` (all)。
- **权限类型**：读 `r` (4)、写 `w` (2)、执行 `x` (1)。
- **权限字符串**：9 位字符表示（如 `rwxr-xr--`），每 3 位一组，分别对应属主、属组、其他用户。

| 权限字符 | 二进制 | 八进制数值 | 说明 |
| :--- | :--- | :--- | :--- |
| `r--` | 100 | 4 | 读权限 |
| `-w-` | 010 | 2 | 写权限 |
| `--x` | 001 | 1 | 执行权限 |
| `rw-` | 110 | 6 | 读 + 写 |
| `r-x` | 101 | 5 | 读 + 执行 |
| `rwx` | 111 | 7 | 读 + 写 + 执行 |

### 用户与组管理

```sh
# 创建新用户
useradd [HERE_USERNAME]

# 查看用户所属组
groups [HERE_USERNAME]

# 修改用户所属组
usermod -g [HERE_GROUP] [HERE_USERNAME]
```

### 权限与归属修改

```sh
# chmod：修改文件或目录权限
chmod u+x [HERE_FILE]               # 属主增加执行权限
chmod g+x [HERE_FILE]               # 属组增加执行权限
chmod u-x,o+x [HERE_FILE]           # 属主移除执行权限，其他用户增加执行权限
chmod 777 [HERE_FILE]               # 八进制设置：所有角色均为可读可写可执行
chmod -R 777 [HERE_DIR]             # -R 递归修改目录及内部所有文件

# chown：修改文件或目录的所有者与所属组
chown [HERE_USERNAME] [HERE_FILE]                 # 修改文件所有者
chown -R [HERE_USERNAME]:[HERE_GROUP] [HERE_DIR] # -R 递归修改目录所有者与所属组
```

## 进程管理

### 查看进程

- **`ps aux`**（BSD 风格）：查看系统中所有进程。常用字段包括 `USER`（启动用户）、`PID`（进程 ID）、`%CPU`、`%MEM`、`COMMAND`。
- **`ps -ef`**（标准 UNIX 风格）：查看进程及父子关系。常用字段包括 `UID`、`PID`、`PPID`（父进程 ID）、`CMD`。

```sh
# 查看运行中的进程
ps aux
ps -ef

# 配合管道符 | 与 grep 过滤指定进程
ps -ef | grep [HERE_KEYWORD]
```

### 终止进程

```sh
# 终止进程
kill [HERE_PID]

# 强制终止进程
kill -9 [HERE_PID]
```

## 压缩与归档

### zip / unzip

```sh
# 压缩文件
zip [HERE_ARCHIVE].zip [HERE_FILE1] [HERE_FILE2]

# 压缩目录（-r 递归）
zip -r [HERE_ARCHIVE].zip [HERE_DIR]

# 解压到指定目录（-d 目标路径）
unzip [HERE_ARCHIVE].zip -d [HERE_DEST_DIR]
```

### tar 归档与压缩

常用参数：
- `-c`：打包
- `-x`：解包
- `-z`：打包或解包时进行 gzip 压缩/解压
- `-v`：显示处理过程
- `-f`：指定包名
- `-C`：解包到指定目录

```sh
# 打包文件
tar -cvf [HERE_ARCHIVE].tar [HERE_FILE1] [HERE_FILE2]

# 打包并压缩为 .tar.gz
tar -zcvf [HERE_ARCHIVE].tar.gz [HERE_FILE1] [HERE_FILE2]

# 解包并解压到指定目录
tar -zxvf [HERE_ARCHIVE].tar.gz -C [HERE_DEST_DIR]
```

## 虚拟机网络基础

### 网络模式

- **桥接模式**：虚拟机通过主机物理网卡直连主机所在局域网。
  - *痛点*：主机断网时无法互通；更换网络后主机与虚拟机 IP 均会改变。
- **NAT 模式**：虚拟机通过宿主机网络地址转换访问外部网络，避免外部网络环境变更导致的 IP 变动。

### 核心网络服务

- **DHCP（Dynamic Host Configuration Protocol，动态主机配置协议）**：为联网设备自动分配私网 IP 地址及网络配置。
- **NAT（Network Address Translation，网络地址转换）**：实现多个局域网私网 IP 共享单个公网 IP 访问互联网。
