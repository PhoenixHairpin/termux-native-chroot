# Termux Native Chroot

> 在 Android Termux 环境中使用原生 chroot 挂载系统全部分区，无需 proot-distro，支持完整 root 权限和编译环境。

## ✨ 核心特性

- **原生 chroot** - 不依赖 proot-distro，直接使用内核 chroot syscall
- **完整系统挂载** - 自动挂载 /system、/vendor、/product、/data、/sdcard 等全部分区
- **隔离命名空间** - 使用 unshare 创建私有 mount namespace，不影响宿主系统
- **SELinux 兼容** - 支持 `--permissive` 自动切换 SELinux 模式
- **安全清理** - 退出时自动卸载所有挂载点，恢复 SELinux 状态
- **MCP 友好** - 特别优化 MCP 工具部署和程序编译场景
- **交互式向导** - 支持交互模式选择发行版、下载 rootfs
- **多发行版支持** - Ubuntu/Debian/Arch/Fedora/Alpine

## 📋 系统要求

- Android 设备已获取 root 权限 (KernelSU / Magisk / su)
- Termux 应用 (最新版本)
- 已安装 `chroot` 命令 (`pkg install chroot` 或系统自带)

## 🚀 快速开始

### 方式一：交互式向导

```bash
# 直接运行，进入交互模式
su -c ./start-ubuntu-full.sh
```

向导会引导你：
1. 选择操作类型（启动已有 rootfs / 下载新 rootfs / 查看安装建议）
2. 选择发行版（Ubuntu/Debian/Arch/Fedora/Alpine）
3. 配置 SELinux 和挂载选项

### 方式二：命令行参数

```bash
# 使用默认 Ubuntu rootfs
su -c ./start-ubuntu-full.sh --permissive

# 指定发行版
su -c ./start-ubuntu-full.sh --distro debian --permissive

# 指定自定义 rootfs 路径
su -c ./start-ubuntu-full.sh --rootfs /data/local/chroot/my-linux --permissive

# 只读挂载 /data（防止误操作）
su -c ./start-ubuntu-full.sh --permissive --ro-data
```

## 📖 命令行参数

| 参数 | 说明 |
|------|------|
| `--interactive`, `-i` | 启动交互式向导 |
| `--distro <名称>` | 使用预设发行版 (ubuntu/debian/arch/fedora/alpine) |
| `--rootfs <目录>` | 指定 rootfs 目录路径 |
| `--permissive` | 临时设置 SELinux 为 Permissive，退出自动恢复 |
| `--ro-data` | 以只读方式挂载 /data 分区 |
| `--proot-fallback` | chroot 失败时回退到 proot-distro |
| `--no-proot-fallback` | 禁用 proot 回退 |
| `--print-install` | 打印发发行版安装建议 |
| `--help`, `-h` | 显示帮助信息 |

## 🔧 安装 rootfs

### 方法一：使用 proot-distro 获取 rootfs

```bash
# 安装 proot-distro（仅用于下载 rootfs）
pkg install proot-distro

# 下载 Ubuntu rootfs
proot-distro install ubuntu

# 使用脚本进入（会自动检测 proot-distro 的 rootfs）
su -c ./start-ubuntu-full.sh --distro ubuntu --permissive
```

### 方法二：手动下载 rootfs

```bash
# 创建目录
su -c 'mkdir -p /data/local/chroot/ubuntu'

# 下载 Ubuntu rootfs (arm64)
su -c 'cd /data/local/chroot/ubuntu && curl -L "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64-root.tar.xz" | tar -xJf -'

# 设置权限
su -c 'chown root:root /data/local/chroot/ubuntu && chmod 755 /data/local/chroot/ubuntu'

# 进入 chroot
su -c ./start-ubuntu-full.sh --rootfs /data/local/chroot/ubuntu --permissive
```

## 🗂️ 挂载点说明

进入 chroot 后，以下路径自动挂载：

| chroot 内路径 | 宿主路径 | 默认权限 | 用途 |
|--------------|---------|---------|------|
| `/android_root` | `/` | ro | Android 根目录 |
| `/android_data` | `/data` | rw (可设为 ro) | 用户数据分区 |
| `/android_system` | `/system` | ro | 系统分区 |
| `/android_vendor` | `/vendor` | ro | 厂商分区 |
| `/android_product` | `/product` | ro | 产品分区 |
| `/android_odm` | `/odm` | ro | ODM 分区 |
| `/android_boot` | `/boot` | ro | 启动分区 |
| `/sdcard` | `/storage/emulated/0` | rw | 内置存储 |
| `/dev` | `/dev` | bind | 设备节点 |
| `/proc` | `proc` | - | 进程信息 |
| `/sys` | `sysfs` | ro | 系统信息 |

## 🛠️ 编译环境配置

进入 chroot 后安装编译工具：

```bash
# Ubuntu/Debian
apt update && apt install -y build-essential clang lld cmake ninja-build git pkg-config python3 python3-pip gdb lldb rustc cargo golang

# Arch Linux
pacman -Syu --noconfirm base-devel clang lld cmake ninja git pkgconf python python-pip gdb lldb rust go

# Fedora
dnf groupinstall -y "Development Tools" && dnf install -y clang lld cmake ninja-build git pkgconf-pkg-config python3 python3-pip gdb lldb rust cargo golang

# Alpine
apk add --no-cache build-base clang lld cmake ninja git pkgconf python3 py3-pip gdb lldb rust cargo go
```

## 🔐 安全机制

### 命名空间隔离

脚本使用 `unshare --mount --propagation private` 创建独立的 mount namespace：

- 挂载操作不影响宿主系统
- 退出时自动清理所有挂载点
- 防止挂载点泄漏到其他进程

### 进程清理

退出时自动终止 chroot 内所有子进程：

1. 先发送 SIGTERM 优雅终止
2. 等待 1 秒后发送 SIGKILL 强制终止
3. 确保无残留进程

### SELinux 处理

- 自动检测当前 SELinux 状态
- `--permissive` 临时切换到 Permissive 模式
- 退出时自动恢复原始 SELinux 状态

### 防嵌套保护

检测是否已在 chroot 环境中运行，防止嵌套 chroot 导致的安全问题。

## 🧪 MCP 工具部署

本脚本特别优化了 MCP (Model Context Protocol) 工具的部署场景：

```bash
# 进入 chroot 后安装 MCP 相关工具
pip3 install anthropic-mcp

# 或部署其他 AI/LLM 工具
pip3 install openai langchain llama-index
```

## ⚠️ 注意事项

1. **必须以 root 执行**：使用 `su -c` 或在 root shell 中运行
2. **SELinux 问题**：如果 chroot 失败，尝试添加 `--permissive` 参数
3. **KernelSU 环境**：某些 KernelSU 配置可能需要调整 SELinux 策略
4. **数据安全**：修改 `/android_data` 前请备份重要数据
5. **系统分区只读**：`/android_system` 等默认只读，需手动 remount 才能修改

## 🔍 故障排除

### chroot 失败：Operation not permitted

```bash
# 方案 1：添加 --permissive
su -c ./start-ubuntu-full.sh --permissive

# 方案 2：检查 SELinux 状态
getenforce
# 如果是 Enforcing，手动设置为 Permissive
setenforce 0

# 方案 3：使用 adb shell su（更高权限上下文）
adb shell su 0 ./start-ubuntu-full.sh --permissive
```

### rootfs 目录权限问题

```bash
# 确保 rootfs 属主为 root
su -c 'chown -R root:root /data/local/chroot/ubuntu'
su -c 'chmod 755 /data/local/chroot/ubuntu'
```

### 缺少 chroot 命令

```bash
pkg install chroot
# 或使用系统自带
/system/bin/chroot
```

### 残留挂载点清理

```bash
# 查看残留挂载
cat /proc/self/mountinfo | grep chroot

# 手动卸载（按逆序）
umount -l /path/to/chroot/mountpoint
```

## 📝 日志文件

每次运行生成日志文件：
```
/data/data/com.termux/files/usr/tmp/chroot-mcp-<timestamp>.log
```

## 📄 许可证

MIT License

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！
